import { useEffect, useMemo, useState } from 'react';
import { Zap } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatMoney, formatAmount } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import { orgToday } from '../../lib/inventory';
import { PageTabs } from '../ListControls';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

const units = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);
const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const when = t => new Date(t).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const avg = xs => (xs.length ? xs.reduce((t, x) => t + x, 0) / xs.length : null);

/*
 * Electricity under Expenses (1e, migration 072): each LUKU meter read in
 * the morning and the evening, as in the daily report — day use (working
 * hours) and night use (lights); tokens are Electricity expenses. Over time
 * each meter's days show what its use is made of: production days against
 * idle days, nights, and units per cement bag on its machines. Costing
 * charges day use to the batches on the meter's machines (073).
 */
export default function ElectricityPanel({ branchId, tabs }) {
  const { organization, canAt } = useAuth();
  const money = v => formatMoney(v, organization?.currency_code);
  const today = orgToday(organization?.timezone);
  const [tab, setTab] = useState('days');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [reading, setReading] = useState(false);
  const [voiding, setVoiding] = useState(null);
  const canRecord = !!branchId && (canAt('procurement.receive', branchId) || canAt('production.create', branchId));

  async function load() {
    setError('');
    if (!branchId) { setData(null); return; }
    const [m, d, r, t] = await Promise.all([
      supabase.from('power_meters').select('*').eq('branch_id', branchId).order('name'),
      supabase.from('power_daily').select('*').eq('branch_id', branchId).order('day', { ascending: false }).limit(400),
      supabase.from('power_readings').select('*').eq('branch_id', branchId).order('read_at', { ascending: false }).limit(400),
      supabase.from('power_tokens').select('*').eq('branch_id', branchId).order('loaded_at', { ascending: false }).limit(200),
    ]);
    if (m.error) { console.error(m.error); setError("We couldn't load electricity. Please try again."); return; }
    setData({ meters: m.data || [], days: d.data || [], readings: r.data || [], tokens: t.data || [] });
  }
  useEffect(() => { load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // what each meter's days show so far (the last 60 days)
  const learnt = useMemo(() => {
    if (!data) return [];
    const since = new Date(Date.now() - 60 * 864e5).toISOString().slice(0, 10);
    return data.meters.filter(m => m.status === 'active').map(m => {
      const ds = data.days.filter(d => d.meter_id === m.id && d.day >= since);
      const working = ds.filter(d => d.day_units != null && Number(d.cement_bags) > 0);
      const idle = ds.filter(d => d.day_units != null && !(Number(d.cement_bags) > 0));
      return {
        m, days: ds.length,
        workDay: avg(working.map(d => Number(d.day_units))), idleDay: avg(idle.map(d => Number(d.day_units))),
        night: avg(ds.filter(d => d.night_units != null).map(d => Number(d.night_units))),
        perBag: working.length ? working.reduce((t, d) => t + Number(d.day_units), 0) / working.reduce((t, d) => t + Number(d.cement_bags), 0) : null,
        workN: working.length, idleN: idle.length,
      };
    });
  }, [data]);

  if (!branchId) return <>{tabs}<div className="card"><EmptyState icon={Zap} title="Pick a branch" description="Meters are per branch — pick one in the sidebar." /></div></>;
  if (error) return <>{tabs}<div className="card"><ErrorState message={error} onRetry={load} /></div></>;
  if (data === null) return <>{tabs}<div className="card"><span className="skeleton" /></div></>;
  if (data.meters.length === 0) return <>{tabs}<div className="card"><EmptyState icon={Zap} title="No meters yet" description="Add the branch's LUKU meters under ⚙ (beside the heading), with the machines each one feeds." /></div></>;
  const meterName = id => data.meters.find(m => m.id === id)?.name ?? '';

  return (
    <>
      <section className="sk">
        {learnt.map(x => (
          <div key={x.m.id} className="sk-card lk-card">
            <div className="sk-name"><strong>{x.m.name}</strong><span className="pl-help">last 60 days · {x.workN} working, {x.idleN} idle days</span></div>
            <div className="sk-total">
              <span><strong>{x.perBag != null ? units(x.perBag) : '—'}</strong></span>
              <span className="sk-sub">units a cement bag</span>
            </div>
            <div className="co-details">
              <span>{x.workDay != null ? `${units(x.workDay)} units a working day` : 'no working day yet'}</span>
              <span className="pl-help">{x.idleDay != null ? `${units(x.idleDay)} on idle days · ` : ''}{x.night != null ? `${units(x.night)} a night (lights)` : ''}</span>
            </div>
          </div>
        ))}
      </section>
      {tabs}
      <div className="flex items-center gap-8" style={{ margin: '4px 0 12px', flexWrap: 'wrap' }}>
        {canRecord && <button type="button" className="btn btn-primary btn-sm" onClick={() => setReading(true)}>Record readings</button>}
        <span className="pl-help">Morning (asubuhi) and evening (jioni) on each meter. Tokens: Record expense → Electricity.</span>
      </div>
      <PageTabs tabs={[['days', 'Days'], ['readings', 'Readings'], ['tokens', 'Tokens']]} value={tab} onChange={setTab} />
      <div className="card"><div className="table-container">
        {tab === 'days' ? (
          <table>
            <thead><tr><th>Day</th><th>Meter</th><th className="num">Day use</th><th className="num">Day (TZS)</th><th className="num">Night use</th><th className="num">Night (TZS)</th><th className="num">Batches</th><th className="num">Cement bags</th><th className="num">Units a bag</th></tr></thead>
            <tbody>
              {data.days.length === 0 ? <tr><td colSpan={9} className="text-muted">Days show once a meter has two readings.</td></tr>
              : data.days.map(d => (
                <tr key={`${d.meter_id}|${d.day}`}>
                  <td>{d.day}{d.gap_units != null && <div className="pl-help text-warning">a reading missing: {units(Number(d.gap_units))} units not split</div>}</td>
                  <td>{d.meter_name}</td>
                  <td className="num"><strong>{d.day_units != null ? units(Number(d.day_units)) : ''}</strong></td>
                  <td className="num">{d.day_cost != null ? formatAmount(Number(d.day_cost)) : ''}</td>
                  <td className="num">{d.night_units != null ? units(Number(d.night_units)) : ''}</td>
                  <td className="num">{d.night_cost != null ? formatAmount(Number(d.night_cost)) : ''}</td>
                  <td className="num">{Number(d.batches) || ''}</td>
                  <td className="num">{Number(d.cement_bags) ? units(Number(d.cement_bags)) : ''}</td>
                  <td className="num">{d.units_per_bag != null ? units(Number(d.units_per_bag)) : Number(d.cement_bags) ? '' : <span className="pl-help">idle</span>}</td>
                </tr>
              ))}
            </tbody>
            {data.days.length > 0 && (
              <tfoot><tr><td colSpan={2}><strong>Total</strong></td>
                <td className="num"><strong>{units(data.days.reduce((t, d) => t + Number(d.day_units || 0), 0))}</strong></td>
                <td className="num"><strong>{money(data.days.reduce((t, d) => t + Number(d.day_cost || 0), 0))}</strong></td>
                <td className="num"><strong>{units(data.days.reduce((t, d) => t + Number(d.night_units || 0), 0))}</strong></td>
                <td className="num"><strong>{money(data.days.reduce((t, d) => t + Number(d.night_cost || 0), 0))}</strong></td>
                <td colSpan={3} /></tr></tfoot>
            )}
          </table>
        ) : tab === 'readings' ? (
          <table>
            <thead><tr><th>Day</th><th></th><th>Meter</th><th className="num">Units left</th><th>Note</th><th /></tr></thead>
            <tbody>
              {data.readings.length === 0 ? <tr><td colSpan={6} className="text-muted">No readings yet.</td></tr>
              : data.readings.map(r => (
                <tr key={r.id} className={r.status === 'void' ? 'is-inactive' : ''}>
                  <td>{r.read_on}</td><td>{r.slot === 'morning' ? 'Morning' : 'Evening'}</td><td>{meterName(r.meter_id)}</td><td className="num">{units(Number(r.reading))}</td>
                  <td>{r.status === 'void' ? <span className="text-muted">Void — {r.void_reason}</span> : r.note || ''}</td>
                  <td>{r.status === 'recorded' && canRecord && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(r)}>Void…</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <table>
            <thead><tr><th>Loaded</th><th>Meter</th><th className="num">Units</th><th className="num">Paid (TZS)</th><th className="num">VAT (TZS)</th><th className="num">EWURA (TZS)</th><th className="num">REA (TZS)</th><th className="num">Old debt (TZS)</th><th className="num">A unit (TZS)</th><th>Token no.</th></tr></thead>
            <tbody>
              {data.tokens.length === 0 ? <tr><td colSpan={10} className="text-muted">No tokens yet — Record expense → Electricity.</td></tr>
              : data.tokens.map(t => (
                <tr key={t.id} className={t.status === 'void' ? 'is-inactive' : ''}>
                  <td>{when(t.loaded_at)}</td><td>{meterName(t.meter_id)}</td><td className="num">{units(Number(t.units))}</td>
                  <td className="num">{formatAmount(Number(t.amount))}</td>
                  {['vat_amount', 'ewura_levy', 'rea_levy', 'debt_deducted'].map(k => <td key={k} className="num">{t[k] != null ? formatAmount(Number(t[k])) : ''}</td>)}
                  <td className="num">{formatAmount((Number(t.amount) - Number(t.debt_deducted || 0)) / Number(t.units))}</td>
                  <td>{t.status === 'void' ? <span className="text-muted">Void — {t.void_reason}</span> : [t.token_no, t.receipt_ref].filter(Boolean).join(' · ')}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>Day use = morning − evening; night use = evening − next morning (lights). Tokens loaded in between are added. Units are priced oldest token first. Costing charges day use to that day's batches on the meter's machines, by cement bags; nights are a running cost.</p>
      {reading && <ReadingsModal meters={data.meters.filter(m => m.status === 'active')} readings={data.readings} today={today}
        onClose={() => setReading(false)} onSaved={async () => { setReading(false); await load(); }} />}
      {voiding && <VoidModal row={voiding} onClose={() => setVoiding(null)} onDone={async () => { setVoiding(null); await load(); }} />}
    </>
  );
}

/* A day's readings: morning and evening for each meter (either can wait until later) */
function ReadingsModal({ meters, readings, today, onClose, onSaved }) {
  const [day, setDay] = useState(today);
  const [vals, setVals] = useState({});       // `${meter}|${slot}` → text
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const had = (m, slot) => readings.find(r => r.meter_id === m && r.read_on === day && r.slot === slot && r.status === 'recorded');
  const val = (m, slot) => (had(m, slot) ? String(Number(had(m, slot).reading)) : vals[`${m}|${slot}`] ?? '');
  async function save() {
    setError('');
    const list = meters.flatMap(m => ['morning', 'evening'].filter(s => !had(m.id, s) && num(vals[`${m.id}|${s}`]) !== null)
      .map(s => ({ meter_id: m.id, slot: s, reading: num(vals[`${m.id}|${s}`]) })));
    if (!list.length) { setError('Enter a reading.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('record_power_readings', { p: { read_on: day, readings: list } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title="Meter readings" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        <label className="pe-field" style={{ maxWidth: 200 }}><span>Day</span><input type="date" className="form-input" max={today} value={day} onChange={e => { setDay(e.target.value); setVals({}); }} /></label>
        <table className="rd-table">
          <thead><tr><th>Meter</th><th className="num">Morning (asubuhi)</th><th className="num">Evening (jioni)</th><th className="num">Used</th></tr></thead>
          <tbody>
            {meters.map(m => {
              const a = num(val(m.id, 'morning')), b = num(val(m.id, 'evening'));
              return (
                <tr key={m.id}>
                  <td><strong>{m.name}</strong></td>
                  {['morning', 'evening'].map(s => (
                    <td key={s} className="num">
                      <NumberInput step="any" min="0" className="form-input" style={{ width: 100 }} disabled={!!had(m.id, s)}
                        value={val(m.id, s)} onChange={e => setVals(v => ({ ...v, [`${m.id}|${s}`]: e.target.value }))} />
                    </td>
                  ))}
                  <td className="num">{a !== null && b !== null ? <strong>{units(a - b)}</strong> : ''}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <p className="pl-help">The units left on each meter. Read in the morning before work and in the evening after — the evening can be added later. A token loaded during the day: enter it first (Record expense → Electricity).</p>
      </div>
    </Modal>
  );
}

function VoidModal({ row, onClose, onDone }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function go() {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('void_power_reading', { p_id: row.id, p_reason: reason });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onDone();
  }
  return (
    <Modal title="Void reading" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className="btn btn-danger" disabled={busy || !reason.trim()} onClick={go}>Void</button></>}>
      <label className="pe-field"><span>Why?</span><input className="form-input" autoFocus value={reason} onChange={e => setReason(e.target.value)} /></label>
    </Modal>
  );
}
