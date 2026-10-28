import { useEffect, useState } from 'react';
import { Plus, X, ShieldCheck } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatAmount } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import { orgToday } from '../../lib/inventory';

export const RATE_NAME = { paye: 'PAYE', nssf_employee: 'NSSF — employee', nssf_employer: 'NSSF — employer', wcf: 'WCF', sdl: 'SDL' };
const RATE_HELP = {
  paye: 'Income tax taken from pay, by monthly bands, on pay after the employee NSSF.',
  nssf_employee: 'Taken from the employee’s gross pay.',
  nssf_employer: 'Paid by the employer on top of gross pay.',
  wcf: 'Workers Compensation Fund — paid by the employer.',
  sdl: 'Skills Development Levy — paid by the employer, only from a number of employees.',
};
const ORDER = ['paye', 'nssf_employee', 'nssf_employer', 'wcf', 'sdl'];

/*
 * Statutory rates (Staff (HR) Part 2, migration 088): PAYE bands and the
 * NSSF/WCF/SDL percents, each from a date. Filled with the usual published
 * figures, marked "to verify"; the Technical admin or a director checks them
 * with TRA / NSSF / WCF and confirms. A pay sheet can't be approved while a
 * rate it uses is unconfirmed. Everyone who sees pay sees the rates.
 */
export default function StatutoryRatesCard() {
  const { organization, can } = useAuth();
  const canSet = can('payroll.rates');
  const [rates, setRates] = useState(null);
  const [editing, setEditing] = useState(null);   // a rate row, or { code } for a new one
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const { data, error: err } = await supabase.from('statutory_rates').select('*').eq('status', 'active').order('effective_from', { ascending: false });
    if (err) { setRates(false); return; }
    setRates(data || []);
  }
  useEffect(() => { load(); }, []);
  async function run(q) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return false; }
    await load();
    return true;
  }

  if (rates === false) return null;   // before 088
  const toVerify = (rates || []).filter(r => !r.verified_at).length;
  const bandsText = b => (b || []).map(x => `${x.rate}% from ${formatAmount(Number(x.from))}`).join(' · ');

  return (
    <section className="card">
      <div className="card-header" style={{ gap: 8 }}>
        <h2 className="card-title">Statutory rates</h2>
        {toVerify > 0 && <span className="badge badge-warning">{toVerify} to verify</span>}
        {canSet && <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setEditing({ code: 'paye' })}><Plus size={14} /> New rate</button>}
      </div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">
          Filled with the usual published figures — <strong>check each with TRA, NSSF and WCF</strong>, then confirm. A pay sheet can’t be approved while a rate it uses isn’t confirmed.
          {canSet ? ' A changed rate needs confirming again.' : ' The Technical admin or a director sets and confirms them.'}
        </p>
        {rates === null ? <span className="skeleton" />
        : rates.length === 0 ? (
          <p className="text-sm text-muted">No rates yet.{canSet && <> <button type="button" className="link-btn" disabled={busy} onClick={() => run(supabase.rpc('fill_my_statutory_rates'))}>Fill the usual rates (to verify)</button></>}</p>
        ) : (
          <div className="table-container">
            <table>
              <thead><tr><th>Rate</th><th>From</th><th>Figure</th><th>Status</th><th>Notes</th>{canSet && <th />}</tr></thead>
              <tbody>
                {ORDER.flatMap(code => rates.filter(r => r.code === code)).map(r => (
                  <tr key={r.id}>
                    <td><strong>{RATE_NAME[r.code]}</strong><div className="pl-help">{RATE_HELP[r.code]}</div></td>
                    <td>{r.effective_from}</td>
                    <td>{r.code === 'paye' ? <span className="text-sm">{bandsText(r.bands)}</span>
                      : <><strong>{Number(r.rate)}%</strong>{r.code === 'sdl' && <div className="pl-help">from {r.min_employees ?? 0} employees · casuals {r.count_casuals ? 'count' : 'don’t count'}</div>}</>}</td>
                    <td>{r.verified_at ? <span className="badge badge-success" title={`Confirmed ${r.verified_at.slice(0, 10)}`}><ShieldCheck size={12} /> Confirmed</span>
                      : <span className="badge badge-warning">To verify</span>}</td>
                    <td className="pl-help" style={{ maxWidth: 260 }}>{r.notes}</td>
                    {canSet && (
                      <td style={{ whiteSpace: 'nowrap' }}>
                        {!r.verified_at && <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => run(supabase.rpc('verify_statutory_rate', { p_rate: r.id, p_ok: true }))}>Confirm</button>}
                        {r.verified_at && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => run(supabase.rpc('verify_statutory_rate', { p_rate: r.id, p_ok: false }))}>Take back</button>}
                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => setEditing(r)}>Edit</button>
                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy} title="Remove this rate" aria-label={`Remove ${RATE_NAME[r.code]} from ${r.effective_from}`}
                          onClick={() => run(supabase.rpc('void_statutory_rate', { p_rate: r.id }))}><X size={13} /></button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {error && <p className="text-xs text-error">{error}</p>}
        {editing && <RateForm rate={editing} today={orgToday(organization?.timezone)} busy={busy}
          onCancel={() => setEditing(null)}
          onSave={async p => { if (await run(supabase.rpc('save_statutory_rate', { p }))) setEditing(null); }} />}
      </div>
    </section>
  );
}

function RateForm({ rate, today, busy, onCancel, onSave }) {
  const isNew = !rate.id;
  const [f, setF] = useState({
    code: rate.code, effective_from: rate.effective_from ?? today, rate: rate.rate ?? '', notes: rate.notes ?? '',
    min_employees: rate.min_employees ?? '', count_casuals: !!rate.count_casuals,
    bands: (rate.bands || [{ from: 0, rate: 0 }]).map(b => ({ from: String(b.from), rate: String(b.rate) })),
  });
  const set = patch => setF(x => ({ ...x, ...patch }));
  const setBand = (i, patch) => set({ bands: f.bands.map((b, j) => (j === i ? { ...b, ...patch } : b)) });
  const save = () => onSave({
    ...(isNew ? { code: f.code } : { id: rate.id }), effective_from: f.effective_from, notes: f.notes,
    ...(f.code === 'paye' ? { bands: f.bands.filter(b => b.from !== '' || b.rate !== '').map(b => ({ from: Number(b.from), rate: Number(b.rate) })) } : { rate: f.rate }),
    ...(f.code === 'sdl' ? { min_employees: f.min_employees, count_casuals: f.count_casuals } : {}),
  });
  return (
    <div className="sr-form">
      <div className="form-row">
        <label className="pe-field"><span>Rate</span>
          <select className="form-input" value={f.code} disabled={!isNew} onChange={e => set({ code: e.target.value })}>
            {ORDER.map(c => <option key={c} value={c}>{RATE_NAME[c]}</option>)}
          </select></label>
        <label className="pe-field"><span>Applies from</span><input type="date" className="form-input" value={f.effective_from} onChange={e => set({ effective_from: e.target.value })} /></label>
        {f.code !== 'paye' && <label className="pe-field"><span>Percent of gross pay</span><input className="form-input" inputMode="decimal" value={f.rate} onChange={e => set({ rate: e.target.value })} /></label>}
        {f.code === 'sdl' && <label className="pe-field"><span>From how many employees</span><input className="form-input" inputMode="numeric" value={f.min_employees} onChange={e => set({ min_employees: e.target.value })} /></label>}
      </div>
      {f.code === 'sdl' && <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={f.count_casuals} onChange={e => set({ count_casuals: e.target.checked })} /> Casual labourers count as employees (and their pay carries SDL) — ask TRA</label>}
      {f.code === 'paye' && (
        <div className="sr-bands">
          <span className="pl-help">Monthly bands: the percent taxed on pay above each amount (the first band starts at 0).</span>
          {f.bands.map((b, i) => (
            <div key={i} className="flex items-center gap-8">
              <span className="text-sm">From</span>
              <input className="form-input" style={{ width: 130 }} inputMode="numeric" aria-label={`Band ${i + 1} from`} value={b.from} onChange={e => setBand(i, { from: e.target.value })} />
              <input className="form-input" style={{ width: 70 }} inputMode="decimal" aria-label={`Band ${i + 1} percent`} value={b.rate} onChange={e => setBand(i, { rate: e.target.value })} />
              <span className="text-sm">%</span>
              {f.bands.length > 1 && <button type="button" className="btn btn-ghost btn-sm" aria-label="Remove band" onClick={() => set({ bands: f.bands.filter((_, j) => j !== i) })}><X size={13} /></button>}
            </div>
          ))}
          <button type="button" className="link-btn" onClick={() => set({ bands: [...f.bands, { from: '', rate: '' }] })}>+ Band</button>
        </div>
      )}
      <label className="pe-field"><span>Notes (where it was checked)</span><input className="form-input" value={f.notes} onChange={e => set({ notes: e.target.value })} /></label>
      <div className="flex items-center gap-8">
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save (to verify)</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}
