import { useMemo } from 'react';
import { FileText, Layers } from 'lucide-react';
import PeriodBar from '../PeriodBar';
import EmptyState from '../EmptyState';
import { useSessionPeriod } from '../../lib/sessionPeriod';
import { periodRange } from '../../lib/periods';
import { qtyText, materialShortName, byMaterialOrder } from '../../lib/inventory';
import { formatAmount, formatMoney, tableDate } from '../../lib/format';

const r2 = n => Math.round(n * 100) / 100;

/*
 * Material variance as a table of batches (2026-11-21, the user: "no job card for several batches — that can be
 * viewed as a table under material variance"): one row a batch, newest first —
 * Date · Batch · Product · Pcs · each main material (the quantity used, its cost small below) · Material cost ·
 * Cost a piece · its job card. Consumables (138) are indirect and left out of the material columns.
 * Totals at the foot; a period bar on top.
 */
export default function BatchCostTable({ batches, refs, inBranch, today, currency, loading }) {
  const [period, setPeriod] = useSessionPeriod('variance-batches');
  const [from, to] = periodRange(period, today);
  const money = v => formatMoney(v, currency);

  const rows = useMemo(() => {
    const live = (batches || []).filter(b => b.status !== 'void' && inBranch(b.branch_id) && b.batch_date >= from && b.batch_date <= to);
    // batch n of the day, as recorded (the job card's number)
    const dayIds = {};
    for (const b of [...live].sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)))) (dayIds[`${b.branch_id}|${b.batch_date}`] ||= []).push(b.id);
    return live.map(b => {
      const mats = (b.materials || []).filter(m => m.source !== 'consumable' && Number(m.quantity) > 0);
      const outs = [...(b.outputs || [])].sort((x, y) => y.is_primary - x.is_primary);
      const main = outs[0];
      const name = o => `${refs?.items[`p:${o.product_id}`]?.name ?? '—'}${o.color_id ? ` ${refs?.colorById[o.color_id]?.name ?? ''}` : ''}`;
      const cons = (b.materials || []).filter(m => m.source === 'consumable').reduce((t, m) => t + Number(m.cost || 0), 0);
      return { b, n: dayIds[`${b.branch_id}|${b.batch_date}`].indexOf(b.id) + 1, mats,
        product: main ? name(main) : '—', extra: outs.slice(1).map(name),
        pcs: outs.reduce((t, o) => t + Number(o.pieces_cast || 0), 0),
        cost: b.material_cost != null ? Number(b.material_cost) - cons : null,
        perPiece: main?.cost_per_piece != null ? Number(main.cost_per_piece) : null };
    }).sort((a, b) => b.b.batch_date.localeCompare(a.b.batch_date) || String(b.b.created_at).localeCompare(String(a.b.created_at)));
  }, [batches, refs, inBranch, from, to]);

  // the main materials used in the period, in material order; one column each (same material, same unit)
  const cols = useMemo(() => {
    const m = {};
    for (const r of rows) for (const x of r.mats) {
      const k = `${x.material_id}|${x.unit_id}`;
      const it = refs?.items[`m:${x.material_id}`];
      m[k] ??= { k, id: x.material_id, unit: refs?.unitById[x.unit_id]?.symbol ?? '', label: materialShortName(it), name: it?.name ?? '—', rank: it?.rank ?? 999 };
    }
    const list = Object.values(m).sort((a, b) => byMaterialOrder(a, b) || a.unit.localeCompare(b.unit));
    const seen = {};
    for (const c of list) (seen[c.label] ||= new Set()).add(c.id);
    return list.map(c => ({ ...c, label: seen[c.label].size > 1 ? c.name : c.label }));
  }, [rows, refs]);

  const cell = (r, c) => r.mats.filter(x => `${x.material_id}|${x.unit_id}` === c.k);
  const sumOf = (list, f) => list.reduce((t, x) => t + f(x), 0);
  const total = c => {
    const xs = rows.flatMap(r => cell(r, c));
    return { qty: sumOf(xs, x => Number(x.quantity)), cost: sumOf(xs, x => Number(x.cost || 0)) };
  };

  return (
    <>
      <div className="flex items-center gap-8" style={{ padding: '12px 16px 0' }}>
        <PeriodBar value={period} onChange={setPeriod} today={today} />
      </div>
      {loading ? <div className="card-body"><span className="skeleton" /></div>
      : rows.length === 0 ? <EmptyState icon={Layers} title="No batches in this period" description="Each production batch shows here with the materials it used and their cost." />
      : (
        <div className="table-container">
          <table className="bc-table">
            <thead><tr>
              <th>Date</th><th className="num">Batch</th><th>Product</th><th className="num">Pcs</th>
              {cols.map(c => <th key={c.k} className="num" title={c.name}>{c.label} <span className="pb-mat-unit">{c.unit}</span></th>)}
              <th className="num">Material cost (TZS)</th><th className="num">Cost /pc (TZS)</th><th aria-label="Job card" />
            </tr></thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.b.id}>
                  <td>{tableDate(r.b.batch_date)}</td>
                  <td className="num">{r.n}</td>
                  <td><strong>{r.product}</strong>{r.extra.length > 0 && <div className="pl-help">+ {r.extra.join(', ')}</div>}</td>
                  <td className="num">{qtyText(r.pcs)}</td>
                  {cols.map(c => { const xs = cell(r, c); const q = sumOf(xs, x => Number(x.quantity)); const k = sumOf(xs, x => Number(x.cost || 0)); return (
                    <td key={c.k} className="num">{xs.length ? <><strong>{qtyText(r2(q))}</strong>{xs.some(x => x.cost != null) && <div className="pb-cell-cost">{formatAmount(r2(k))}</div>}</> : ''}</td>); })}
                  <td className="num"><strong>{r.cost != null ? formatAmount(r2(r.cost)) : '—'}</strong></td>
                  <td className="num">{r.perPiece != null ? formatAmount(r2(r.perPiece)) : '—'}</td>
                  <td><button type="button" className="icon-btn" aria-label={`Job card, batch ${r.n} of ${tableDate(r.b.batch_date)}`} title="View job card"
                    onClick={() => window.open(`/print/job-card/${r.b.id}`, '_blank', 'noopener')}><FileText size={15} /></button></td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr>
              <td><strong>Total</strong></td><td className="num">{rows.length}</td><td /><td className="num"><strong>{qtyText(sumOf(rows, r => r.pcs))}</strong></td>
              {cols.map(c => { const t = total(c); return <td key={c.k} className="num"><strong>{qtyText(r2(t.qty))}</strong><div className="pb-cell-cost">{formatAmount(r2(t.cost))}</div></td>; })}
              <td className="num"><strong>{money(r2(sumOf(rows, r => r.cost ?? 0)))}</strong></td><td /><td />
            </tr></tfoot>
          </table>
        </div>
      )}
    </>
  );
}
