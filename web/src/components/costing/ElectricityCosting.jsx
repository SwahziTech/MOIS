import { Fragment, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Zap, ChevronDown, ChevronRight } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { formatMoney, formatAmount, dateText } from '../../lib/format';
import { PageTabs } from '../ListControls';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';

const units = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);
const r2 = n => Math.round(n * 100) / 100;
const daysAgo = n => new Date(Date.now() - n * 864e5).toISOString().slice(0, 10);

/*
 * Electricity on Costing (1e, 2026-10-27): the direct production cost of
 * electricity, pulled from where it is recorded — the meters' day use
 * (Purchases › Electricity, 072) and the batches made on each meter's
 * machines (Production). Each day's use is shared over that day's batches on
 * the meter's machines by cement bags (as batch_power_cost, 073), and within
 * a batch over its products by cement taken. Nights are a running cost.
 */
export default function ElectricityCosting({ branchId, refs, currency, tabs }) {
  const money = v => formatMoney(v, currency);
  const [period, setPeriod] = useState('30');
  const [view, setView] = useState('days');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [openDay, setOpenDay] = useState(null);

  async function load() {
    setError('');
    const since = daysAgo(Number(period));
    const [m, mm, d, b, sp] = await Promise.all([
      supabase.from('power_meters').select('id, name, status').eq('branch_id', branchId).order('name'),
      supabase.from('power_meter_machines').select('meter_id, machine_id'),
      supabase.from('power_daily').select('*').eq('branch_id', branchId).gte('day', since).order('day', { ascending: false }),
      supabase.from('production_batches').select('id, batch_date, machine_id, cement_bags, outputs:production_batch_outputs(product_id, color_id, pieces_cast, cement_share)')
        .eq('branch_id', branchId).gte('batch_date', since).neq('status', 'void'),
      supabase.from('product_specs').select('product_id, pcs_per_sqm'),
    ]);
    if (m.error || d.error) { console.error(m.error || d.error); setError("We couldn't load electricity costs."); return; }
    setData({ meters: m.data || [], links: mm.data || [], days: d.data || [], batches: b.data || [],
      perSqm: Object.fromEntries((sp.data || []).map(x => [x.product_id, Number(x.pcs_per_sqm) || null])) });
  }
  useEffect(() => { setData(null); load(); }, [branchId, period]); // eslint-disable-line react-hooks/exhaustive-deps

  const nameOf = (pid, cid) => `${refs?.items[`p:${pid}`]?.name ?? '—'}${cid ? ` ${refs?.colorById[cid]?.name ?? ''}` : ''}`;
  const isSqm = pid => (refs?.unitById[refs?.items[`p:${pid}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM';

  // each day and meter: its batches with their share of the day use
  const days = useMemo(() => {
    if (!data) return [];
    const meterOf = Object.fromEntries(data.links.map(l => [l.machine_id, l.meter_id]));
    return data.days.filter(d => d.day_units != null).map(d => {
      const bs = data.batches.filter(b => b.batch_date === d.day && meterOf[b.machine_id] === d.meter_id);
      const bags = bs.reduce((t, b) => t + Number(b.cement_bags), 0);
      const cost = Number(d.day_cost || 0);
      return { ...d, bags, batches: bs.map(b => {
        const share = bags > 0 ? r2(cost * Number(b.cement_bags) / bags) : 0;
        return { ...b, share, outputs: (b.outputs || []).filter(o => Number(o.pieces_cast) > 0).map(o => ({ ...o, share: r2(share * Number(o.cement_share || 0)) })) };
      }) };
    });
  }, [data]);

  // per product: electricity charged, per bag, per m² or piece
  const products = useMemo(() => {
    const by = {};
    for (const d of days) for (const b of d.batches) for (const o of b.outputs) {
      const k = `${o.product_id}|${o.color_id ?? ''}`;
      const x = by[k] ??= { k, pid: o.product_id, cid: o.color_id, batches: new Set(), bags: 0, pieces: 0, cost: 0, last: null };
      x.batches.add(b.id); x.bags += Number(b.cement_bags) * Number(o.cement_share || 0); x.pieces += Number(o.pieces_cast); x.cost += o.share;
      if (!x.last || d.day > x.last) x.last = d.day;
    }
    return Object.values(by).map(x => {
      const sqm = isSqm(x.pid) && data?.perSqm[x.pid] ? x.pieces / data.perSqm[x.pid] : null;
      return { ...x, batches: x.batches.size, qty: sqm ?? x.pieces, unit: sqm != null ? 'm²' : 'pc', perUnit: (sqm ?? x.pieces) > 0 ? x.cost / (sqm ?? x.pieces) : null, perBag: x.bags > 0 ? x.cost / x.bags : null };
    }).sort((a, b) => b.cost - a.cost);
  }, [days, data]); // eslint-disable-line react-hooks/exhaustive-deps

  if (error) return <>{tabs}<div className="card"><ErrorState message={error} onRetry={load} /></div></>;
  if (data === null) return <>{tabs}<div className="card"><span className="skeleton" /></div></>;
  if (data.meters.length === 0) return <>{tabs}<div className="card"><EmptyState icon={Zap} title="No meters yet" description="Electricity is recorded under Purchases: meters (⚙), tokens (Record expense → Electricity) and morning/evening readings." /></div></>;
  const tot = days.reduce((t, d) => ({ units: t.units + Number(d.day_units || 0), cost: t.cost + Number(d.day_cost || 0), night: t.night + Number(d.night_cost || 0),
    unused: t.unused + (d.bags > 0 ? 0 : Number(d.day_cost || 0)) }), { units: 0, cost: 0, night: 0, unused: 0 });

  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Into products</span><strong>{money(r2(tot.cost - tot.unused))}</strong><span className="pl-help">day use on days with batches</span></div>
        <div className="mm-stat"><span className="pl-label">Day use, no batches</span><strong className={tot.unused > 0 ? 'text-warning' : ''}>{money(r2(tot.unused))}</strong><span className="pl-help">idle days — not charged</span></div>
        <div className="mm-stat"><span className="pl-label">Nights (lights)</span><strong>{money(r2(tot.night))}</strong><span className="pl-help">running cost</span></div>
        <div className="mm-stat"><span className="pl-label">Day units</span><strong>{units(tot.units)}</strong><span className="pl-help">{days.length} meter-days</span></div>
      </div>
      {tabs}
      <div className="flex items-center gap-8" style={{ marginBottom: 8, flexWrap: 'wrap' }}>
        <PageTabs nested tabs={[['days', 'By day'], ['products', 'By product']]} value={view} onChange={setView} />
        <select className="form-input" style={{ width: 150, marginLeft: 'auto' }} aria-label="Period" value={period} onChange={e => setPeriod(e.target.value)}>
          <option value="7">Last 7 days</option><option value="30">Last 30 days</option><option value="90">Last 90 days</option><option value="365">Last 12 months</option>
        </select>
        <Link to="/purchases?tab=electricity" className="btn btn-ghost btn-sm">Readings & tokens ›</Link>
      </div>
      <div className="card"><div className="table-container">
        {view === 'days' ? (
          <table>
            <thead><tr><th>Day</th><th>Meter</th><th className="num">Day units</th><th className="num">Cost (TZS)</th><th className="num">Batches</th><th className="num">Cement bags</th><th className="num">Units a bag</th><th className="num">A bag (TZS)</th></tr></thead>
            <tbody>
              {days.length === 0 ? <tr><td colSpan={8} className="text-muted">No day use in this period — readings are entered under Purchases › Electricity.</td></tr>
              : days.map(d => {
                const k = `${d.meter_id}|${d.day}`; const isOpen = openDay === k;
                return (
                  <Fragment key={k}>
                    <tr className={d.batches.length ? 'clickable-row' : ''} onClick={() => d.batches.length && setOpenDay(isOpen ? null : k)}>
                      <td>{d.batches.length ? (isOpen ? <ChevronDown size={13} /> : <ChevronRight size={13} />) : null} {dateText(d.day)}</td>
                      <td>{d.meter_name}</td>
                      <td className="num">{units(Number(d.day_units))}</td>
                      <td className="num"><strong>{formatAmount(Number(d.day_cost || 0))}</strong></td>
                      <td className="num">{d.batches.length || <span className="pl-help">idle</span>}</td>
                      <td className="num">{d.bags ? units(d.bags) : ''}</td>
                      <td className="num">{d.bags ? units(Number(d.day_units) / d.bags) : ''}</td>
                      <td className="num">{d.bags ? formatAmount(Number(d.day_cost || 0) / d.bags) : ''}</td>
                    </tr>
                    {isOpen && d.batches.flatMap(b => b.outputs.map((o, i) => (
                      <tr key={`${b.id}|${i}`} className="ec-sub">
                        <td />
                        <td colSpan={2}>{nameOf(o.product_id, o.color_id)} <span className="pl-help">· {units(Number(o.pieces_cast))} pcs</span></td>
                        <td className="num">{formatAmount(o.share)}</td>
                        <td />
                        <td className="num">{i === 0 ? units(Number(b.cement_bags)) : ''}</td>
                        <td colSpan={2} className="num pl-help">{(() => { const sq = isSqm(o.product_id) && data.perSqm[o.product_id] ? Number(o.pieces_cast) / data.perSqm[o.product_id] : null;
                          return sq ? `${formatAmount(o.share / sq)} /m²` : `${formatAmount(o.share / Number(o.pieces_cast))} /pc`; })()}</td>
                      </tr>
                    )))}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        ) : (
          <table>
            <thead><tr><th>Product</th><th className="num">Batches</th><th className="num">Cement bags</th><th className="num">Made</th><th className="num">Electricity (TZS)</th><th className="num">A bag (TZS)</th><th className="num">A unit (TZS)</th><th>Latest</th></tr></thead>
            <tbody>
              {products.length === 0 ? <tr><td colSpan={8} className="text-muted">No batches on metered machines in this period.</td></tr>
              : products.map(x => (
                <tr key={x.k}>
                  <td><strong>{nameOf(x.pid, x.cid)}</strong></td>
                  <td className="num">{x.batches}</td>
                  <td className="num">{units(x.bags)}</td>
                  <td className="num">{units(x.qty)} {x.unit === 'm²' ? 'm²' : 'pcs'}</td>
                  <td className="num"><strong>{formatAmount(x.cost)}</strong></td>
                  <td className="num">{x.perBag != null ? formatAmount(x.perBag) : ''}</td>
                  <td className="num">{x.perUnit != null ? <>{formatAmount(x.perUnit)} <span className="pl-help">/{x.unit}</span></> : ''}</td>
                  <td>{x.last}</td>
                </tr>
              ))}
            </tbody>
            {products.length > 0 && <tfoot><tr><td colSpan={4}><strong>Total</strong></td><td className="num"><strong>{money(r2(products.reduce((t, x) => t + x.cost, 0)))}</strong></td><td colSpan={3} /></tr></tfoot>}
          </table>
        )}
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>From Purchases › Electricity (each meter's day use, morning → evening) and Production (the batches on that meter's machines). A day's cost is shared over its batches by cement bags, and within a batch over its products by cement taken — the same figure that goes into each product's production cost. Idle days and nights are not charged to products.</p>
    </>
  );
}
