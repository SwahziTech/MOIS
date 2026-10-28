import { useEffect, useMemo, useState } from 'react';
import { Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { formatAmount, formatMoneyShort } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

/*
 * Advances and loans (Staff (HR) Part 2, migration 090): given once — paid
 * out as a Wages expense that day — and taken back on the pay sheets made
 * from attendance: the instalment each sheet, or all that's left, never more
 * than the pay left. Newest first.
 */
export default function AdvancesPanel({ staff, branchId, today, money, currency, canRecord, canApprove, inBranch }) {
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [adding, setAdding] = useState(false);
  const [voiding, setVoiding] = useState(null);   // { id, reason }
  const [busy, setBusy] = useState(false);
  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('staff_advance_balances').select('*').order('given_on', { ascending: false });
    if (err) { console.error(err); setError("We couldn't load advances."); setRows([]); return; }
    setRows(data || []);
  }
  useEffect(() => { load(); }, []);
  const nameOf = id => staff.find(s => s.id === id)?.full_name ?? '';
  const here = useMemo(() => (rows || []).filter(r => inBranch(r.branch_id)), [rows, inBranch]);
  const live = here.filter(r => r.status === 'active');
  const owing = live.filter(r => Number(r.outstanding) > 0);
  const short = v => formatMoneyShort(v, currency);
  const given = live.filter(r => r.given_on.slice(0, 7) === today.slice(0, 7));

  async function voidIt() {
    setBusy(true); setError('');
    const { error: err } = await supabase.rpc('void_staff_advance', { p_advance: voiding.id, p_reason: voiding.reason });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setVoiding(null); load();
  }

  return (
    <>
      {rows !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Still owed</span><strong>{short(owing.reduce((t, r) => t + Number(r.outstanding), 0))}</strong>
            <span className="pl-help">{owing.length} {owing.length === 1 ? 'person' : 'people'} owing</span></div>
          <div className="mm-stat"><span className="pl-label">Given this month</span><strong>{short(given.reduce((t, r) => t + Number(r.amount), 0))}</strong>
            <span className="pl-help">{given.length} advance{given.length === 1 ? '' : 's'}</span></div>
          <div className="mm-stat"><span className="pl-label">On draft sheets</span><strong>{short(live.reduce((t, r) => t + Number(r.on_drafts), 0))}</strong>
            <span className="pl-help" title="Taken back on pay sheets not yet approved">to take back next pay</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        {canRecord && <button type="button" className="btn btn-primary btn-sm" onClick={() => setAdding(true)}><Plus size={14} /> New advance or loan</button>}
        <span className="pl-help" title="Paid out as a Wages expense the day it is given. Each pay sheet takes back the instalment (or all that's left), never more than the pay left after NSSF, PAYE and other deductions.">Taken back automatically on the next pay sheets.</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Given on</th><th>Name</th><th className="num">Amount (TZS)</th><th className="num">A pay sheet (TZS)</th><th className="num">Taken back (TZS)</th><th className="num">Left (TZS)</th><th>Reason</th><th /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={8}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={8} className="text-muted">No advances or loans yet.</td></tr>
            : here.map(r => (
              <tr key={r.id} className={r.status === 'void' ? 'is-inactive' : ''}>
                <td>{r.given_on}</td>
                <td><strong>{nameOf(r.staff_id)}</strong></td>
                <td className="num">{formatAmount(Number(r.amount))}</td>
                <td className="num">{r.installment ? formatAmount(Number(r.installment)) : <span className="pl-help">all at once</span>}</td>
                <td className="num">{formatAmount(Number(r.recovered))}{Number(r.on_drafts) > 0 && <div className="pl-help">+{formatAmount(Number(r.on_drafts))} on drafts</div>}</td>
                <td className="num"><strong>{r.status === 'void' ? '' : formatAmount(Number(r.outstanding))}</strong></td>
                <td>{r.status === 'void' ? <span className="badge badge-error">Void</span> : r.reason || ''}</td>
                <td>{canApprove && r.status === 'active' && Number(r.recovered) === 0 && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding({ id: r.id, reason: '' })}>Void…</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div></div>
      {adding && <AdvanceModal staff={staff.filter(s => s.status === 'active' && inBranch(s.branch_id))} branchId={branchId} today={today} money={money}
        onClose={() => setAdding(false)} onSaved={() => { setAdding(false); load(); }} />}
      {voiding && (
        <Modal title="Void advance" onClose={() => setVoiding(null)}
          footer={<><button type="button" className="btn btn-outline" onClick={() => setVoiding(null)}>Cancel</button>
            <button type="button" className="btn btn-danger" disabled={busy || !voiding.reason.trim()} onClick={voidIt}>Void (its Wages expense too)</button></>}>
          <label className="pe-field"><span>Why?</span><input className="form-input" autoFocus value={voiding.reason} onChange={e => setVoiding({ ...voiding, reason: e.target.value })} /></label>
        </Modal>
      )}
    </>
  );
}

function AdvanceModal({ staff, branchId, today, money, onClose, onSaved }) {
  const [f, setF] = useState({ staff_id: '', given_on: today, amount: '', installment: '', account_id: '', reason: '' });
  const [accounts, setAccounts] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = patch => setF(x => ({ ...x, ...patch }));
  useEffect(() => {
    if (!branchId) return;
    supabase.from('payment_accounts').select('id, name, status').eq('branch_id', branchId).order('display_order')
      .then(({ data }) => setAccounts((data || []).filter(a => a.status === 'active')));
  }, [branchId]);
  async function save() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('record_staff_advance', { p: f });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  const amt = Number(f.amount) || 0; const ins = Number(f.installment) || 0;
  return (
    <Modal title="New advance or loan" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !branchId || !f.staff_id || !amt} onClick={save}>Save</button></>}>
      <div className="modal-form">
        {!branchId && <div className="alert alert-warning">Choose a branch first.</div>}
        <label className="pe-field"><span>Who</span>
          <select className="form-input" value={f.staff_id} onChange={e => set({ staff_id: e.target.value })}>
            <option value="">Choose…</option>{[...staff].sort((a, b) => a.full_name.localeCompare(b.full_name)).map(s => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select></label>
        <div className="form-row">
          <label className="pe-field"><span>Given on</span><input type="date" className="form-input" max={today} value={f.given_on} onChange={e => set({ given_on: e.target.value })} /></label>
          <label className="pe-field"><span>Amount</span><NumberInput step="any" min="0" className="form-input" value={f.amount} onChange={e => set({ amount: e.target.value })} /></label>
          <label className="pe-field"><span>Take back a pay sheet</span><NumberInput step="any" min="0" className="form-input" placeholder="all at once" value={f.installment} onChange={e => set({ installment: e.target.value })} /></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Paid from</span>
            <select className="form-input" value={f.account_id} onChange={e => set({ account_id: e.target.value })}>
              <option value="">Cash</option>{accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
            </select></label>
          <label className="pe-field" style={{ flex: 2 }}><span>Reason</span><input className="form-input" placeholder="e.g. school fees" value={f.reason} onChange={e => set({ reason: e.target.value })} /></label>
        </div>
        {amt > 0 && <p className="pl-help">{ins > 0 && ins < amt ? `${money(ins)} taken back on each pay sheet — about ${Math.ceil(amt / ins)} sheets.` : `${money(amt)} taken back on the next pay sheet (as much as the pay allows).`} Recorded now as a Wages expense.</p>}
      </div>
    </Modal>
  );
}
