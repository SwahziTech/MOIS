import { useEffect, useState } from 'react';
import { Zap } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatMoney, formatAmount } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import { PageTabs } from '../ListControls';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';
import Modal from '../Modal';

const units = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);
const when = t => new Date(t).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

/*
 * Electricity on Costing (1e, migration 072): each LUKU meter's use between
 * readings — priced oldest token first — split into production (into product
 * cost, 073) and office/period use; the readings and tokens behind it.
 * Tokens are entered as Electricity expenses (Purchases); readings come from
 * the daily report; meters are kept under Purchases ⚙.
 */
export default function ElectricityUse({ branchId }) {
  const { organization, canAt } = useAuth();
  const money = v => formatMoney(v, organization?.currency_code);
  const [tab, setTab] = useState('use');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [voiding, setVoiding] = useState(null);     // { kind, row }

  async function load() {
    setError('');
    const [m, u, r, t] = await Promise.all([
      supabase.from('power_meters').select('*').eq('branch_id', branchId).order('name'),
      supabase.from('power_use').select('*').eq('branch_id', branchId).order('to_at', { ascending: false }).limit(400),
      supabase.from('power_readings').select('*').eq('branch_id', branchId).order('read_at', { ascending: false }).limit(400),
      supabase.from('power_tokens').select('*').eq('branch_id', branchId).order('loaded_at', { ascending: false }).limit(200),
    ]);
    if (m.error) { console.error(m.error); setError("We couldn't load electricity. Please try again."); return; }
    setData({ meters: m.data || [], use: u.data || [], readings: r.data || [], tokens: t.data || [] });
  }
  useEffect(() => { setData(null); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (data === null) return <div className="card"><span className="skeleton" /></div>;
  if (data.meters.length === 0) return <div className="card"><EmptyState icon={Zap} title="No meters yet" description="Add the branch's LUKU meters under Purchases ⚙, with the machines each one feeds." /></div>;
  const meterName = id => data.meters.find(m => m.id === id)?.name ?? '';
  const sum = k => data.use.reduce((t, u) => t + Number(u[k] || 0), 0);

  return (
    <>
      <PageTabs tabs={[['use', 'Use by day'], ['readings', 'Readings'], ['tokens', 'Tokens']]} value={tab} onChange={setTab} />
      <div className="card"><div className="table-container">
        {tab === 'use' ? (
          <table>
            <thead><tr><th>Day</th><th>Meter</th><th className="num">From</th><th className="num">Loaded</th><th className="num">To</th><th className="num">Units used</th><th className="num">Office / period</th><th className="num">Production</th><th className="num">Per unit (TZS)</th><th className="num">Cost (TZS)</th><th className="num">Into products (TZS)</th></tr></thead>
            <tbody>
              {data.use.length === 0 ? <tr><td colSpan={11} className="text-muted">Use shows from a meter's second reading (the daily report).</td></tr>
              : data.use.map(u => (
                <tr key={u.reading_id}>
                  <td>{u.day}{u.days > 1 && <div className="pl-help">{u.days} days, since {u.from_day}</div>}</td>
                  <td>{u.meter_name}</td>
                  <td className="num">{units(Number(u.from_reading))}</td>
                  <td className="num">{Number(u.units_loaded) ? `+${units(Number(u.units_loaded))}` : ''}</td>
                  <td className="num">{units(Number(u.to_reading))}</td>
                  <td className="num"><strong>{units(Number(u.units_used))}</strong></td>
                  <td className="num">{u.split_mode === 'baseline' ? units(Number(u.period_units)) : ''}</td>
                  <td className="num">{units(Number(u.production_units))}</td>
                  <td className="num">{u.price_per_unit == null ? (u.cost == null ? <span className="text-warning">no token</span> : '') : formatAmount(Number(u.price_per_unit))}</td>
                  <td className="num">{u.cost == null ? '' : formatAmount(Number(u.cost))}</td>
                  <td className="num"><strong>{u.cost == null ? '' : formatAmount(Number(u.production_cost))}</strong></td>
                </tr>
              ))}
            </tbody>
            {data.use.length > 0 && (
              <tfoot><tr><td colSpan={5}><strong>Total</strong></td><td className="num"><strong>{units(sum('units_used'))}</strong></td>
                <td className="num">{units(sum('period_units'))}</td><td className="num">{units(sum('production_units'))}</td><td />
                <td className="num"><strong>{money(sum('cost'))}</strong></td><td className="num"><strong>{money(sum('production_cost'))}</strong></td></tr></tfoot>
            )}
          </table>
        ) : tab === 'readings' ? (
          <table>
            <thead><tr><th>When</th><th>Meter</th><th className="num">Units left</th><th>Note</th><th /></tr></thead>
            <tbody>
              {data.readings.length === 0 ? <tr><td colSpan={5} className="text-muted">No readings yet — they come from the daily report.</td></tr>
              : data.readings.map(r => (
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
            <thead><tr><th>Loaded</th><th>Meter</th><th className="num">Units</th><th className="num">Paid (TZS)</th><th className="num">Per unit (TZS)</th><th>Token no.</th></tr></thead>
            <tbody>
              {data.tokens.length === 0 ? <tr><td colSpan={6} className="text-muted">No tokens yet — enter them as Electricity expenses (Purchases).</td></tr>
              : data.tokens.map(t => (
                <tr key={t.id} className={t.status === 'void' ? 'is-inactive' : ''}>
                  <td>{when(t.loaded_at)}</td><td>{meterName(t.meter_id)}</td><td className="num">{units(Number(t.units))}</td>
                  <td className="num">{formatAmount(Number(t.amount))}</td><td className="num">{formatAmount(Number(t.amount) / Number(t.units))}</td>
                  <td>{t.status === 'void' ? <span className="text-muted">Void — {t.void_reason}</span> : t.token_no || ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>Units used = the reading before + tokens loaded since − this reading, priced oldest token first. On a baseline meter that many units a day are office/period use; the rest goes into the cost of that day's batches on the meter's machines, by cement bags.</p>
      {voiding && <VoidModal {...voiding} onClose={() => setVoiding(null)} onDone={async () => { setVoiding(null); await load(); }} />}
    </>
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
