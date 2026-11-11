import { useEffect, useMemo, useState } from 'react';
import { Upload, FileImage, Banknote, Eye } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import ShareButton from '../ShareButton';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';
import { orgToday } from '../../lib/inventory';
import { formatMoney, dateText, tableDate } from '../../lib/format';
import NumberInput from '../NumberInput';
import Modal from '../Modal';
import ProofBox from '../ProofBox';
import { proofName, extOf } from '../../lib/proofName';

/*
 * What directors pay (106, 2026-11-04, the user): one Pay window — choose what
 * is paid (supplier, expense or bill, weekly cash, salaries) or type it, the
 * amount, the account and the proof (photo/PDF or the SMS), required with the
 * payment. Supplier, weekly cash and salaries go through MOIS's own payment
 * step first (record_purchase_payment, cash_request_step 'pay', pay_pay_sheet);
 * then the proof is kept. The branch manager, the secretary and the other
 * directors could mark it Seen; 2026-11-06 the user: no reminder notes — the paid
 * transaction shows its own status and slip where it lives (e.g. the purchase).
 */
const KINDS = [['supplier', 'Supplier'], ['expense', 'Expense / bill'], ['weekly_cash', 'Weekly cash'], ['salaries', 'Salaries'], ['other', 'Other']];
const KIND_LABEL = Object.fromEntries(KINDS);
const num = v => (String(v ?? '').trim() === '' ? null : Number(String(v).replace(/,/g, '')));
const r2 = n => Math.round(n * 100) / 100;

export function PayModal({ onClose, onSaved }) {
  const { organization } = useAuth();
  const { branchId, branches } = useBranch();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [br, setBr] = useState(branchId || '');
  const [kind, setKind] = useState('supplier');
  const [options, setOptions] = useState(null);   // what can be paid, for the kind and branch
  const [ref, setRef] = useState('');
  const [desc, setDesc] = useState('');
  const [amount, setAmount] = useState('');
  const [accounts, setAccounts] = useState([]);
  const [accountId, setAccountId] = useState('');
  const [paidOn, setPaidOn] = useState(today);
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState('');
  const [sms, setSms] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!br) return;
    supabase.from('payment_accounts').select('id, name, status').eq('branch_id', br).order('display_order').order('name')
      .then(({ data }) => setAccounts((data || []).filter(a => a.status === 'active')));
  }, [br]);
  // the things of this kind still to pay at the branch, each with what it owes
  useEffect(() => {
    setOptions(null); setRef(''); setAmount('');
    if (!br) return;
    (async () => {
      if (kind === 'supplier') {
        const [p, t, s] = await Promise.all([
          supabase.from('purchases').select('id, purchase_date, invoice_reference, supplier_id, status').eq('branch_id', br).order('purchase_date', { ascending: false }).limit(200),
          supabase.from('purchase_totals').select('purchase_id, total, balance'),
          supabase.from('suppliers').select('id, name'),
        ]);
        const bal = Object.fromEntries((t.data || []).map(x => [x.purchase_id, x]));
        const sup = Object.fromEntries((s.data || []).map(x => [x.id, x.name]));
        setOptions((p.data || []).filter(x => x.status !== 'void' && Number(bal[x.id]?.balance) > 0.004)
          .map(x => ({ id: x.id, who: sup[x.supplier_id], owes: Number(bal[x.id].balance), label: `${tableDate(x.purchase_date)} · ${sup[x.supplier_id] ?? 'Supplier'}${x.invoice_reference ? ` · ${x.invoice_reference}` : ''} · owes ${money(Number(bal[x.id].balance))}` })));
      } else if (kind === 'expense') {
        const { data } = await supabase.from('expenses').select('id, expense_date, description, amount, amount_paid, status').eq('branch_id', br).neq('status', 'void').order('expense_date', { ascending: false }).limit(100);
        setOptions((data || []).map(x => ({ id: x.id, who: x.description, owes: Math.max(Number(x.amount) - Number(x.amount_paid || 0), 0) || Number(x.amount),
          label: `${tableDate(x.expense_date)} · ${x.description ?? 'Expense'} · ${money(Number(x.amount))}` })));
      } else if (kind === 'weekly_cash') {
        const { data } = await supabase.from('cash_requests').select('id, week_ending, status, lines:cash_request_lines(amount, approved_amount)').eq('branch_id', br).eq('status', 'approved').order('week_ending', { ascending: false });
        setOptions((data || []).map(x => { const a = (x.lines || []).reduce((t, l) => t + Number(l.approved_amount ?? l.amount), 0);
          return { id: x.id, owes: a, label: `Week ending ${tableDate(x.week_ending)} · approved ${money(a)}` }; }));
      } else if (kind === 'salaries') {
        const { data } = await supabase.from('pay_sheets').select('id, cycle, period_start, period_end, total, status').eq('branch_id', br).eq('status', 'approved').order('period_end', { ascending: false });
        setOptions((data || []).map(x => ({ id: x.id, owes: Number(x.total), label: `${tableDate(x.period_start)} – ${tableDate(x.period_end)} · ${money(Number(x.total))}` })));
      } else setOptions([]);
    })();
  }, [kind, br]); // eslint-disable-line react-hooks/exhaustive-deps
  function pickRef(id) {
    setRef(id);
    const o = (options || []).find(x => x.id === id);
    if (o) setAmount(String(r2(o.owes)));
  }
  function pick(e) {
    const f = e.target.files?.[0]; e.target.value = '';
    if (!f) { setFile(null); return; }   // removed in the proof box
    if (f.size > 10 * 1024 * 1024) { setError('That file is over 10 MB.'); return; }
    setError(''); setFile(f); setPreview(f.type.startsWith('image/') ? URL.createObjectURL(f) : '');
  }
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);

  const needsRef = ['supplier', 'weekly_cash', 'salaries'].includes(kind);
  async function save() {
    setError('');
    if (!br) { setError('Choose the branch.'); return; }
    if (needsRef && !ref) { setError('Choose what is paid.'); return; }
    if ((kind === 'other' || (kind === 'expense' && !ref)) && !desc.trim()) { setError('Write what was paid.'); return; }
    if (!(num(amount) > 0)) { setError('Enter the amount.'); return; }
    if (!file && !sms.trim()) { setError('Add the proof: a photo or the SMS.'); return; }
    setBusy(true);
    try {
      // 1. the payment, through MOIS's own step
      let r = { error: null };
      if (kind === 'supplier') r = await supabase.rpc('record_purchase_payment', { p_purchase: ref, p: { amount: num(amount), paid_on: paidOn, account_id: accountId || null, method: accountId ? null : 'bank', reference: null } });
      if (kind === 'weekly_cash') r = await supabase.rpc('cash_request_step', { p_id: ref, p_step: 'pay', p: { amount: num(amount), paid_on: paidOn, reference: null } });
      if (kind === 'salaries') r = await supabase.rpc('pay_pay_sheet', { p_sheet: ref, p: { paid_on: paidOn, account_id: accountId || null } });
      if (r.error) throw r.error;
      // 2. the proof, kept with it
      let path = null;
      try {
        if (file) {
          const ext = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
          path = `${organization.id}/${br}/dp/${Date.now()}.${ext}`;
          const up = await supabase.storage.from('director-proofs').upload(path, file, { contentType: file.type || undefined, upsert: false });
          if (up.error) throw up.error;
        }
        const { error: err } = await supabase.rpc('post_director_payment', { p: { branch_id: br, kind, ref_id: ref || null, description: desc.trim() || null,
          amount: num(amount), account_id: accountId || null, paid_on: paidOn, file_path: path, file_name: file ? proofName({ kind: `Paid-${{ supplier: 'Supplier', expense: 'Expense', weekly_cash: 'WeeklyCash', salaries: 'Salaries', other: 'Other' }[kind]}`,
          who: (options || []).find(o => o.id === ref)?.who || desc.trim() || (branches || []).find(b => b.id === br)?.name, amount: num(amount), date: paidOn }, extOf(file)) : null, sms_text: sms.trim() || null } });
        if (err) throw err;
      } catch (e) {
        throw new Error(`${needsRef ? 'Paid, but the proof was not kept: ' : ''}${dbErrorMessage(e)}`);
      }
      onSaved();
    } catch (e) {
      setError(e.message || dbErrorMessage(e));
    } finally { setBusy(false); }
  }

  return (
    <Modal title="Pay" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Pay and post proof</button></>}>
      <div className="modal-form">
        {!branchId && (
          <label className="pe-field"><span>Branch</span>
            <select className="form-input" value={br} onChange={e => setBr(e.target.value)}>
              <option value="">Choose…</option>
              {(branches || []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select></label>
        )}
        <div className="filter-chips" role="group" aria-label="What is paid">
          {KINDS.map(([k, l]) => <button key={k} type="button" className={`filter-chip${kind === k ? ' is-on' : ''}`} onClick={() => setKind(k)}>{l}</button>)}
        </div>
        {kind !== 'other' && (
          <label className="pe-field"><span>{kind === 'expense' ? 'Which expense (or type it below)' : 'Which one'}</span>
            <select className="form-input" value={ref} onChange={e => pickRef(e.target.value)}>
              <option value="">{options === null ? 'Loading…' : options.length ? 'Choose…' : 'Nothing to pay'}</option>
              {(options || []).map(o => <option key={o.id} value={o.id}>{o.label}</option>)}
            </select></label>
        )}
        {(kind === 'other' || (kind === 'expense' && !ref)) && (
          <label className="pe-field"><span>What was paid</span><input className="form-input" value={desc} onChange={e => setDesc(e.target.value)} placeholder="Water bill, October" /></label>
        )}
        <div className="form-row">
          <label className="pe-field"><span>Amount</span><NumberInput className="form-input" min="0" value={amount} disabled={kind === 'salaries'} onChange={e => setAmount(e.target.value)} /></label>
          {kind !== 'weekly_cash' && (
            <label className="pe-field"><span>From account</span>
              <select className="form-input" value={accountId} onChange={e => setAccountId(e.target.value)}>
                <option value="">{accounts.length ? 'Choose…' : 'No accounts'}</option>
                {accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
              </select></label>
          )}
          <label className="pe-field"><span>Date</span><input type="date" className="form-input" max={today} value={paidOn} onChange={e => setPaidOn(e.target.value)} /></label>
        </div>
        <ProofBox file={file} onFile={f => pick({ target: { files: f ? [f] : [], value: '' } })} text={sms} onText={setSms} />
      </div>
    </Modal>
  );
}

/* Paid by directors: each payment and its proof, newest first */
export function PaidList({ days = 60 }) {
  const { organization, session } = useAuth();
  const { inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const me = session?.user?.id;
  const [rows, setRows] = useState(null);
  const [seen, setSeen] = useState([]);
  const [people, setPeople] = useState({});
  const [viewing, setViewing] = useState(null);
  const [error, setError] = useState('');
  async function load() {
    const since = new Date(new Date(`${today}T00:00:00Z`).getTime() - days * 864e5).toISOString().slice(0, 10);
    const [d, s] = await Promise.all([
      supabase.from('director_payments').select('*').gte('paid_on', since).order('paid_on', { ascending: false }).order('created_at', { ascending: false }),
      supabase.from('director_payment_seen').select('payment_id, user_id, seen_at'),
    ]);
    if (d.error) { setRows([]); return; }
    setRows(d.data || []); setSeen(s.data || []);
    const ids = [...new Set((s.data || []).map(x => x.user_id))];
    if (ids.length) {
      const { data } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
      setPeople(Object.fromEntries((data || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
    }
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const shown = useMemo(() => (rows || []).filter(r => inBranch(r.branch_id)), [rows, inBranch]);
  const seenBy = id => seen.filter(s => s.payment_id === id);
  async function markSeen(id) {
    setError('');
    const { error: err } = await supabase.rpc('mark_director_payment_seen', { p_id: id });
    if (err) { setError(dbErrorMessage(err)); return; }
    load();
  }
  return (
    <>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>For</th><th className="num">Amount (TZS)</th><th>Proof</th></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={4}><span className="skeleton" /></td></tr>
            : shown.length === 0 ? <tr><td colSpan={4} className="text-muted">No payments yet.</td></tr>
            : shown.map(r => {
              return (
                <tr key={r.id}>
                  <td>{tableDate(r.paid_on)}</td>
                  <td>{KIND_LABEL[r.kind]}{r.description ? ` · ${r.description}` : ''}</td>
                  <td className="num">{Number(r.amount).toLocaleString('en-US')}</td>
                  <td><button type="button" className="btn btn-ghost btn-sm" onClick={() => setViewing(r)}><Eye size={13} /> {r.file_path ? 'Slip' : 'SMS'}</button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div></div>
      {viewing && <ProofView row={viewing} onClose={() => setViewing(null)} />}
    </>
  );
}

export function ProofView({ row, onClose }) {
  const { organization } = useAuth();
  const [url, setUrl] = useState('');
  const [saveUrl, setSaveUrl] = useState('');
  useEffect(() => {
    if (!row.file_path) return;
    supabase.storage.from('director-proofs').createSignedUrl(row.file_path, 600).then(({ data }) => setUrl(data?.signedUrl ?? ''));
    supabase.storage.from('director-proofs').createSignedUrl(row.file_path, 600, { download: row.file_name || `Paid_${row.paid_on}.jpg` })
      .then(({ data }) => setSaveUrl(data?.signedUrl ?? ''));
  }, [row.file_path]); // eslint-disable-line react-hooks/exhaustive-deps
  const isPdf = /\.pdf$/i.test(row.file_path ?? '');
  return (
    <Modal title={`${KIND_LABEL[row.kind]} · ${formatMoney(Number(row.amount), organization?.currency_code)}`} onClose={onClose}
      footer={<>{(url || row.sms_text) && <ShareButton deps={[url]} name={row.file_name || `Paid_${row.paid_on}`}
          text={`${KIND_LABEL[row.kind]} · ${formatMoney(Number(row.amount), organization?.currency_code)} · paid ${dateText(row.paid_on)}${row.description ? ` · ${row.description}` : ''}${!row.file_path && row.sms_text ? `\n${row.sms_text}` : ''}`}
          getBlob={async () => (url ? (await fetch(url)).blob() : new Blob([row.sms_text], { type: 'text/plain' }))} />}
        {saveUrl && <a href={saveUrl} className="btn btn-ghost" download>Save to device</a>}<button type="button" className="btn btn-outline" onClick={onClose}>Close</button></>}>
      <div className="modal-form">
        <p className="pl-help">Paid {dateText(row.paid_on)}{row.description ? ` · ${row.description}` : ''}</p>
        {row.file_path && (isPdf ? <a href={url} target="_blank" rel="noopener noreferrer" className="btn btn-outline btn-sm">Open the PDF</a>
          : url ? <img src={url} alt="Proof of payment" className="pp-photo" /> : <span className="skeleton" />)}
        {row.sms_text && <pre className="pp-sms">{row.sms_text}</pre>}
      </div>
    </Modal>
  );
}

/* On Home for the branch manager and the secretary: director payments they haven't seen */
export function PaidReminder({ branchId, inBranch }) {
  const { session, canAt } = useAuth();
  const [n, setN] = useState(0);
  const [open, setOpen] = useState(false);
  const me = session?.user?.id;
  const can = !!branchId && !canAt('finance.pay', branchId, null);
  async function load() {
    if (!can) return;
    const [d, s] = await Promise.all([
      supabase.from('director_payments').select('id, branch_id').order('paid_on', { ascending: false }).limit(200),
      supabase.from('director_payment_seen').select('payment_id').eq('user_id', me),
    ]);
    if (d.error) return;
    const mine = new Set((s.data || []).map(x => x.payment_id));
    setN((d.data || []).filter(x => inBranch(x.branch_id) && !mine.has(x.id)).length);
  }
  useEffect(() => { load(); }, [branchId, can]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!can || (!n && !open)) return null;
  return (
    <>
      {n > 0 && <div className="alert alert-info pp-reminder" role="note">
        <Banknote size={16} aria-hidden="true" />
        <span><strong>{n} paid by directors</strong> · not seen yet</span>
        <button type="button" className="btn btn-outline btn-sm" onClick={() => setOpen(true)}>Open</button>
      </div>}
      {open && <Modal title="Paid by directors" size="xl" onClose={() => { setOpen(false); load(); }}><PaidList /></Modal>}
    </>
  );
}
