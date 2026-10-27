import { useEffect, useMemo, useState } from 'react';
import { Layers } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { formatMoney, formatMoneyShort, formatAmount } from '../../lib/format';
import { materialStockValue, qtyText } from '../../lib/inventory';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';

const daysAgo = n => new Date(Date.now() - n * 864e5).toISOString().slice(0, 10);
const r2 = n => Math.round(n * 100) / 100;

/*
 * Materials on Costing (1e, 2026-10-27): what production used — pulled from
 * Production (each batch's materials, costed oldest stock first, VAT
 * included, 055) — per material for a period: quantity, cost, its share of
 * all material cost, and the cost a unit; beside it what the store holds at
 * cost (052). Locked layout for materials: category above the name.
 */
export default function MaterialsCosting({ branchId, refs, currency }) {
  const money = v => formatMoney(v, currency);
  const [period, setPeriod] = useState('30');
  const [used, setUsed] = useState(null);
  const [stock, setStock] = useState({});
  const [error, setError] = useState('');

  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('production_batch_materials')
      .select('material_id, stock_quantity, cost, batch:production_batches!inner(batch_date, branch_id, status)')
      .eq('batch.branch_id', branchId).neq('batch.status', 'void').gte('batch.batch_date', daysAgo(Number(period)));
    if (err) { console.error(err); setError("We couldn't load material costs."); return; }
    setUsed(data || []);
  }
  useEffect(() => { setUsed(null); load(); }, [branchId, period]); // eslint-disable-line react-hooks/exhaustive-deps

  // what the store holds at cost, per material (oldest stock first, 052)
  const mats = useMemo(() => Object.values(refs?.items || {}).filter(i => i.kind === 'material' && i.status === 'active' && (!i.branchId || i.branchId === branchId)), [refs, branchId]);
  useEffect(() => {
    let live = true;
    Promise.all(mats.map(async m => [m.id, await materialStockValue(branchId, m.id)])).then(rows => { if (live) setStock(Object.fromEntries(rows)); });
    return () => { live = false; };
  }, [mats, branchId]);

  const rows = useMemo(() => {
    if (!used) return [];
    const by = {};
    for (const u of used) {
      const x = by[u.material_id] ??= { qty: 0, cost: 0, uncosted: false };
      x.qty += Number(u.stock_quantity); x.cost += Number(u.cost || 0); if (u.cost == null) x.uncosted = true;
    }
    const total = Object.values(by).reduce((t, x) => t + x.cost, 0);
    return mats.map(m => {
      const x = by[m.id] ?? { qty: 0, cost: 0, uncosted: false };
      const main = m.mainUnitId ? m.units.find(u => u.id === m.mainUnitId) : null;   // shown in its main unit (051)
      const unitId = main ? main.id : m.stockUnitId;
      const factor = main ? main.factor : 1;
      const sv = stock[m.id];
      return { m, qty: x.qty / factor, unit: refs.unitById[unitId]?.symbol ?? '', cost: r2(x.cost), share: total > 0 ? x.cost / total : 0,
        perUnit: x.qty > 0 ? x.cost / (x.qty / factor) : null, uncosted: x.uncosted,
        stockValue: sv?.value != null ? Number(sv.value) : null, stockQty: sv?.on_hand != null ? Number(sv.on_hand) / factor : null,
        unitCost: sv?.unit_cost != null ? Number(sv.unit_cost) * factor : null };
    }).filter(r => r.qty > 0 || (r.stockValue ?? 0) > 0)
      .sort((a, b) => b.cost - a.cost || a.m.rank - b.m.rank || a.m.name.localeCompare(b.m.name));
  }, [used, mats, stock, refs]);

  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (used === null) return <div className="card"><span className="skeleton" /></div>;
  const totalUsed = rows.reduce((t, r) => t + r.cost, 0);
  const top = rows.find(r => r.cost > 0);
  const stockTotal = rows.reduce((t, r) => t + (r.stockValue || 0), 0);
  const label = { 7: 'last 7 days', 30: 'last 30 days', 90: 'last 90 days', 365: 'last 12 months' }[period];

  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Materials used</span><strong>{money(r2(totalUsed))}</strong><span className="pl-help">{label} · into production</span></div>
        <div className="mm-stat"><span className="pl-label">Biggest cost</span><strong>{top ? top.m.name : '—'}</strong><span className="pl-help">{top ? `${Math.round(top.share * 100)}% · ${formatMoneyShort(top.cost, currency)}` : 'nothing used yet'}</span></div>
        <div className="mm-stat"><span className="pl-label">In store at cost</span><strong>{money(r2(stockTotal))}</strong><span className="pl-help">oldest stock first</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8 }}>
        <select className="form-input" style={{ width: 150, marginLeft: 'auto' }} aria-label="Period" value={period} onChange={e => setPeriod(e.target.value)}>
          <option value="7">Last 7 days</option><option value="30">Last 30 days</option><option value="90">Last 90 days</option><option value="365">Last 12 months</option>
        </select>
      </div>
      {rows.length === 0 ? <div className="card"><EmptyState icon={Layers} title="Nothing used in this period" description="Materials taken by production batches show here, with their cost." /></div> : (
        <div className="card"><div className="table-container">
          <table>
            <thead><tr><th>Material</th><th className="num">Used</th><th className="num">Cost (TZS)</th><th className="num">Share</th><th className="num">A unit used (TZS)</th><th className="num">In store</th><th className="num">A unit in store (TZS)</th><th className="num">Store value (TZS)</th></tr></thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.m.id}>
                  <td><span className="pl-help">{r.m.materialCategory ?? ''}</span><div><strong>{r.m.name}</strong></div></td>{/* materials: category above the name (locked) */}
                  <td className="num">{r.qty > 0 ? <>{qtyText(r2(r.qty))} <span className="pl-help">{r.unit}</span></> : ''}</td>
                  <td className="num"><strong>{r.cost ? formatAmount(r.cost) : ''}</strong>{r.uncosted && <div className="pl-help text-warning">part without a cost</div>}</td>
                  <td className="num">{r.share > 0 ? `${Math.round(r.share * 1000) / 10}%` : ''}</td>
                  <td className="num">{r.perUnit != null ? <>{formatAmount(r.perUnit)} <span className="pl-help">/{r.unit}</span></> : ''}</td>
                  <td className="num">{r.stockQty != null ? <>{qtyText(r2(r.stockQty))} <span className="pl-help">{r.unit}</span></> : ''}</td>
                  <td className="num">{r.unitCost != null ? formatAmount(r.unitCost) : ''}</td>
                  <td className="num">{r.stockValue != null ? formatAmount(r.stockValue) : ''}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td><strong>Total</strong></td><td /><td className="num"><strong>{money(r2(totalUsed))}</strong></td><td colSpan={4} /><td className="num"><strong>{money(r2(stockTotal))}</strong></td></tr></tfoot>
          </table>
        </div></div>
      )}
      <p className="pl-help" style={{ marginTop: 8 }}>From Production: each batch's materials, costed oldest stock first with VAT included — the material part of every product's production cost. Purchases › Material costs shows prices paid.</p>
    </>
  );
}
