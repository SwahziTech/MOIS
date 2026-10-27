import { useEffect, useMemo, useState } from 'react';
import { Zap } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatAmount } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';
import ProductionSettings from '../components/production/ProductionSettings';

const LOAD_ERROR = "We couldn't load electricity. Please try again.";
const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const units = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);
// a datetime-local value for now, in the browser's clock
const nowLocal = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };
const when = t => new Date(t).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

/*
 * Electricity (1e, migration 072): each LUKU meter's readings (the units
 * left) and the tokens loaded; the units used between readings, their cost
 * at the latest token's price, and the share that is production (the rest —
 * the office — is a running cost). Meters are kept under ⚙.
 */
export default function Power() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const money = v => formatMoney(v, organization?.currency_code);
  const [tab, setTab] = useState('use');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [modal, setModal] = useState(null);         // { kind: 'reading' | 'token', meter }
  const [voiding, setVoiding] = useState(null);     // { kind, row }
  const [settings, setSettings] = useState(false);

  async function load() {
    setError('');
    const [m, u, r, t, mm, x] = await Promise.all([
      supabase.from('power_meters').select('*').order('name'),
      supabase.from('power_use').select('*').order('to_at', { ascending: false }).limit(400),
      supabase.from('power_readings').select('*').order('read_at', { ascending: false }).limit(400),
      supabase.from('power_tokens').select('*').order('loaded_at', { ascending: false }).limit(200),
      supabase.from('power_meter_machines').select('meter_id, machine_id'),
      supabase.from('machines').select('id, name'),
    ]);
    if (m.error) { console.error(m.error); setError(LOAD_ERROR); return; }
    setData({ meters: m.data || [], use: u.data || [], readings: r.data || [], tokens: t.data || [], links: mm.data || [], machines: x.data || [] });
  }
  useEffect(() => { load(); }, []);

  const meters = useMemo(() => (data?.meters || []).filter(m => inBranch(m.branch_id) && m.status === 'active'), [data, inBranch]);
  const meterName = id => data?.meters.find(m => m.id === id)?.name ?? '';
  const fedBy = id => (data?.links || []).filter(l => l.meter_id === id).map(l => data.machines.find(x => x.id === l.machine_id)?.name).filter(Boolean);
  const use = (data?.use || []).filter(u => inBranch(u.branch_id));
  const canRecord = m => canAt('production.create', m.branch_id) || false;
  const canToken = m => canAt('production.create', m.branch_id) || canAt('procurement.receive', m.branch_id);

  // the last 7 days of use per meter
  const weekOf = id => {
    const since = new Date(Date.now() - 7 * 864e5).toISOString();
    return use.filter(u => u.meter_id === id && u.to_at >= since).reduce((t, u) => ({ units: t.units + Number(u.units_used), cost: t.cost + Number(u.cost || 0), prod: t.prod + Number(u.production_cost || 0) }), { units: 0, cost: 0, prod: 0 });
  };
  const lastReading = id => (data?.readings || []).find(r => r.meter_id === id && r.status === 'recorded');

  return (
    <PageShell title="Electricity" subtitle="Production" onSettings={() => setSettings(true)}
      description={branchId ? `LUKU meters at ${branchName}: readings, tokens, and what each day's power cost.` : 'LUKU meters at every branch: readings, tokens, and what each day’s power cost.'}>
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : data === null ? <div className="card"><span className="skeleton" /></div>
      : meters.length === 0 ? <div className="card"><EmptyState icon={Zap} title="No meters yet" description="Add the branch's LUKU meters under ⚙ (Electricity meters), with the machines each one feeds." /></div>
      : (
        <>
          <section className="sk">
            {meters.map(m => {
              const w = weekOf(m.id); const last = lastReading(m.id);
              return (
                <div key={m.id} className="sk-card lk-card">
                  <div className="sk-name">
                    <strong>{m.name}</strong>
                    <span className="pl-help">{fedBy(m.id).join(', ') || 'no machine yet'}{Number(m.office_share_pct) > 0 ? ` · ${Number(m.office_share_pct)}% office` : ''}</span>
                  </div>
                  <div className="sk-total">
                    <span><strong>{units(w.units)}</strong> units</span>
                    <span className="sk-sub">last 7 days · {money(w.cost)}</span>
                  </div>
                  <div className="co-details">
                    <span>{last ? `${units(Number(last.reading))} left` : 'no reading yet'}</span>
                    {last && <span className="pl-help">{when(last.read_at)}</span>}
                  </div>
                  <div className="flex items-center gap-8">
                    {canRecord(m) && <button type="button" className="btn btn-primary btn-sm" onClick={() => setModal({ kind: 'reading', meter: m })}>Reading</button>}
                    {canToken(m) && <button type="button" className="btn btn-outline btn-sm" onClick={() => setModal({ kind: 'token', meter: m })}>Token</button>}
                  </div>
                </div>
              );
            })}
          </section>
          <PageTabs tabs={[['use', 'Use by day'], ['readings', 'Readings'], ['tokens', 'Tokens']]} value={tab} onChange={setTab} />
          <div className="card"><div className="table-container">
            {tab === 'use' ? (
              <table>
                <thead><tr><th>Day</th><th>Meter</th><th className="num">From</th><th className="num">Loaded</th><th className="num">To</th><th className="num">Units used</th><th className="num">Per unit (TZS)</th><th className="num">Cost (TZS)</th><th className="num">Production (TZS)</th><th className="num">Office (TZS)</th></tr></thead>
                <tbody>
                  {use.length === 0 ? <tr><td colSpan={10} className="text-muted">Use shows from the second reading of a meter.</td></tr>
                  : use.map(u => (
                    <tr key={u.reading_id}>
                      <td>{u.day}{u.from_day !== u.day && Number(new Date(u.day)) - Number(new Date(u.from_day)) > 864e5 && <div className="pl-help">since {u.from_day}</div>}</td>
                      <td>{u.meter_name}</td>
                      <td className="num">{units(Number(u.from_reading))}</td>
                      <td className="num">{Number(u.units_loaded) ? `+${units(Number(u.units_loaded))}` : ''}</td>
                      <td className="num">{units(Number(u.to_reading))}</td>
                      <td className="num"><strong>{units(Number(u.units_used))}</strong></td>
                      <td className="num">{u.price_per_unit == null ? <span className="text-warning">no token</span> : formatAmount(Number(u.price_per_unit))}</td>
                      <td className="num">{u.cost == null ? '' : formatAmount(Number(u.cost))}</td>
                      <td className="num">{u.production_cost == null ? '' : formatAmount(Number(u.production_cost))}</td>
                      <td className="num">{u.cost == null ? '' : formatAmount(Number(u.cost) - Number(u.production_cost))}</td>
                    </tr>
                  ))}
                </tbody>
                {use.length > 0 && (
                  <tfoot><tr><td colSpan={5}><strong>Total</strong></td><td className="num"><strong>{units(use.reduce((t, u) => t + Number(u.units_used), 0))}</strong></td><td />
                    <td className="num"><strong>{money(use.reduce((t, u) => t + Number(u.cost || 0), 0))}</strong></td>
                    <td className="num"><strong>{money(use.reduce((t, u) => t + Number(u.production_cost || 0), 0))}</strong></td>
                    <td className="num"><strong>{money(use.reduce((t, u) => t + Number(u.cost || 0) - Number(u.production_cost || 0), 0))}</strong></td></tr></tfoot>
                )}
              </table>
            ) : tab === 'readings' ? (
              <table>
                <thead><tr><th>When</th><th>Meter</th><th className="num">Units left</th><th>Note</th><th /></tr></thead>
                <tbody>
                  {data.readings.filter(r => inBranch(r.branch_id)).map(r => (
                    <tr key={r.id} className={r.status === 'void' ? 'is-inactive' : ''}>
                      <td>{when(r.read_at)}</td><td>{meterName(r.meter_id)}</td><td className="num">{units(Number(r.reading))}</td>
                      <td>{r.status === 'void' ? <span className="text-muted">Void — {r.void_reason}</span> : r.note || ''}</td>
                      <td>{r.status === 'recorded' && canAt('production.create', r.branch_id) && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding({ kind: 'reading', row: r })}>Void…</button>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            ) : (
              <table>
                <thead><tr><th>Loaded</th><th>Meter</th><th className="num">Units</th><th className="num">Paid (TZS)</th><th className="num">Per unit (TZS)</th><th>Token no.</th><th /></tr></thead>
                <tbody>
                  {data.tokens.filter(t => inBranch(t.branch_id)).map(t => (
                    <tr key={t.id} className={t.status === 'void' ? 'is-inactive' : ''}>
                      <td>{when(t.loaded_at)}</td><td>{meterName(t.meter_id)}</td><td className="num">{units(Number(t.units))}</td>
                      <td className="num">{formatAmount(Number(t.amount))}</td><td className="num">{formatAmount(Number(t.amount) / Number(t.units))}</td>
                      <td>{t.status === 'void' ? <span className="text-muted">Void — {t.void_reason}</span> : t.token_no || ''}</td>
                      <td>{t.status === 'recorded' && (canAt('production.create', t.branch_id) || canAt('procurement.receive', t.branch_id)) && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding({ kind: 'token', row: t })}>Void…</button>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div></div>
          <p className="pl-help" style={{ marginTop: 8 }}>Units used = the reading before + tokens loaded since − this reading, priced at the latest token. Each token is also recorded as an Electricity expense.</p>
        </>
      )}
      {modal && <RecordModal {...modal} last={lastReading(modal.meter.id)} onClose={() => setModal(null)} onSaved={async () => { setModal(null); await load(); }} />}
      {voiding && <VoidModal {...voiding} onClose={() => setVoiding(null)} onDone={async () => { setVoiding(null); await load(); }} />}
      {settings && <ProductionSettings onClose={() => { setSettings(false); load(); }} />}
    </PageShell>
  );
}

function RecordModal({ kind, meter, last, onClose, onSaved }) {
  const [f, setF] = useState({ at: nowLocal(), reading: '', units: '', amount: '', token_no: '', note: '', paid_from: 'cash' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = patch => setF(x => ({ ...x, ...patch }));
  async function save() {
    setError('');
    const at = new Date(f.at).toISOString();
    let res;
    if (kind === 'reading') {
      if (num(f.reading) === null || num(f.reading) < 0) { setError('Enter the units left on the meter.'); return; }
      setBusy(true);
      res = await supabase.rpc('record_power_reading', { p: { meter_id: meter.id, reading: num(f.reading), read_at: at, note: f.note } });
    } else {
      if (!(num(f.units) > 0)) { setError('Enter the units bought.'); return; }
      if (num(f.amount) === null || num(f.amount) < 0) { setError('Enter what was paid.'); return; }
      setBusy(true);
      res = await supabase.rpc('record_power_token', { p: { meter_id: meter.id, units: num(f.units), amount: num(f.amount), loaded_at: at, token_no: f.token_no, paid_from: f.paid_from } });
    }
    setBusy(false);
    if (res.error) { setError(dbErrorMessage(res.error)); return; }
    onSaved();
  }
  return (
    <Modal title={kind === 'reading' ? `Reading — ${meter.name}` : `Token loaded — ${meter.name}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        {kind === 'reading' ? (
          <>
            <div className="form-row">
              <label className="pe-field"><span>Units left on the meter</span><NumberInput step="any" min="0" className="form-input" autoFocus value={f.reading} onChange={e => set({ reading: e.target.value })} /></label>
              <label className="pe-field"><span>When</span><input type="datetime-local" className="form-input" value={f.at} onChange={e => set({ at: e.target.value })} /></label>
            </div>
            {last && <p className="pl-help">Last reading: {units(Number(last.reading))} on {when(last.read_at)}. Load a token first if one went in since.</p>}
            <label className="pe-field"><span>Note (optional)</span><input className="form-input" value={f.note} onChange={e => set({ note: e.target.value })} /></label>
          </>
        ) : (
          <>
            <div className="form-row">
              <label className="pe-field"><span>Units bought</span><NumberInput step="any" min="0" className="form-input" autoFocus value={f.units} onChange={e => set({ units: e.target.value })} /></label>
              <label className="pe-field"><span>Paid (TZS)</span><NumberInput step="any" min="0" className="form-input" value={f.amount} onChange={e => set({ amount: e.target.value })} /></label>
            </div>
            <div className="form-row">
              <label className="pe-field"><span>Loaded</span><input type="datetime-local" className="form-input" value={f.at} onChange={e => set({ at: e.target.value })} /></label>
              <label className="pe-field"><span>Paid by</span>
                <select className="form-input" value={f.paid_from} onChange={e => set({ paid_from: e.target.value })}>
                  <option value="cash">Cash</option><option value="mobile_money">Mobile money</option><option value="bank">Bank</option>
                </select></label>
            </div>
            <label className="pe-field"><span>Token no. (optional)</span><input className="form-input" value={f.token_no} onChange={e => set({ token_no: e.target.value })} /></label>
            <p className="pl-help">Load it on the meter, then record it here at the time it went in — before the next reading. It is also recorded as an Electricity expense.</p>
          </>
        )}
      </div>
    </Modal>
  );
}

function VoidModal({ kind, row, onClose, onDone }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function go() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc(kind === 'reading' ? 'void_power_reading' : 'void_power_token', { p_id: row.id, p_reason: reason });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onDone();
  }
  return (
    <Modal title={kind === 'reading' ? 'Void reading' : 'Void token'} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className="btn btn-danger" disabled={busy || !reason.trim()} onClick={go}>Void</button></>}>
      <label className="pe-field"><span>Why?{kind === 'token' ? ' (its Electricity expense is voided too)' : ''}</span><input className="form-input" autoFocus value={reason} onChange={e => setReason(e.target.value)} /></label>
    </Modal>
  );
}
