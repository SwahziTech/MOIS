import { FileText } from 'lucide-react';
import { qtyText } from '../../lib/inventory';
import { formatMoney } from '../../lib/format';

const r2 = n => Math.round(n * 100) / 100;

/**
 * Materials in Stumarcot's format (SwahziTech, 2026-10-24): short name on
 * top, the amount big, its unit small — side by side, in material order.
 * materials: [{ id, label, name, qty, unit, rank }]
 */
// soft: in batch rows, every material after the first (cement) is shown softer, so cement and pieces stand out
export function MaterialStrip({ materials, muted = false, soft = false }) {
  if (!materials.length) return <span className="pl-help">—</span>;
  // two different materials with the same short name (three sands) show their full names
  const seen = {};
  for (const m of materials) (seen[m.label] ||= new Set()).add(m.id);
  const labelOf = m => (seen[m.label].size > 1 ? m.name : m.label);
  // one row of materials (locked 2026-10-25, at the developing screen's width); steel on its own row below
  const row = materials.filter(m => !m.steel);
  const steel = materials.filter(m => m.steel);
  const tile = m => (
        <span key={`${m.id}|${m.unit}`} className="pb-mat" title={m.name}>
          <span className="pb-mat-label">{labelOf(m)}</span>
          <span className="pb-mat-val"><strong>{qtyText(r2(m.qty))}</strong> <span className="pb-mat-unit">{m.unit}</span></span>
        </span>
  );
  return (
    <div className={`pb-strip${muted ? ' is-muted' : ''}${soft ? ' is-soft' : ''}`} style={{ '--pb-n': Math.max(row.length, steel.length, 1) }}>
      <div className="pb-strip-row">{row.map(tile)}</div>
      {steel.length > 0 && <div className="pb-strip-row is-steel">{steel.map(tile)}</div>}
    </div>
  );
}


const byRank = (a, b) => (a.rank ?? 999) - (b.rank ?? 999) || String(a.name).localeCompare(String(b.name));
function sumMaterials(lists) {
  const m = {};
  for (const list of lists) for (const x of list) {
    const k = `${x.id}|${x.unit}`;
    m[k] ??= { ...x, qty: 0 };
    m[k].qty += Number(x.qty) || 0;
  }
  return Object.values(m).sort(byRank);
}

/**
 * Production in Stumarcot's format (SwahziTech, 2026-10-24):
 *   Batch 1 · bags
 *     main product + colour | pieces | the batch's materials | pieces per bag
 *     + residual + colour   | pieces | same mix
 *   …
 *   Day total             | pieces | materials used | bags
 * As the production form is filled: the batch's materials belong to its main
 * product; residuals are cast from the same mix and are not given a share.
 *
 * Material cost (055): the batch's cost in its head (≈ an estimate before it is saved),
 * each product's cost per piece (and per m²) at the row's end — main and
 * residuals alike, shared by the cement each takes.
 *
 * Tracking (056): the team and machine in the batch head; anything thrown
 * away and the quality tags/note on soft lines under the batch.
 *
 * batches: [{ n, bags, stage?, cost?, costComplete?, estimate?, team?, machine?, waste?: [{ name, qty, unit, reason, cost? }], qc?: { tags, note }, outputs: [{ name, pieces, passed?, residual, perBag, perPiece?, perSqm? }],
 *             materials: [{ id, label, name, qty, unit, rank }] }]
 */
// a batch as a table (2026-11-20, the user): the main materials across as headers, each cell the quantity used with its cost small below
function MaterialTable({ mats, rows, costed, money }) {
  const seen = {};
  for (const m of mats) (seen[m.label] ||= new Set()).add(m.id);
  const labelOf = m => (seen[m.label].size > 1 ? m.name : m.label);
  return (
    <div className="pb-table-wrap"><table className="pb-table">
      <thead><tr><th>Product</th><th className="num">Qty</th>
        {mats.map(m => <th key={`${m.id}|${m.unit}`} className="num" title={m.name}>{labelOf(m)} <span className="pb-mat-unit">{m.unit}</span></th>)}
        <th className="num">Pcs/bag</th>{costed && <th className="num">Cost</th>}</tr></thead>
      <tbody>{rows.map((r, i) => (
        <tr key={i} className={r.cls || ''}>
          <td className="pb-name">{r.name}</td>
          <td className="num"><strong>{qtyText(r.pieces)}</strong> <span className="pb-mat-unit">pcs</span>{r.passed != null && <div className="pb-passed">{qtyText(r.passed)} passed</div>}</td>
          {r.sameMix ? (mats.length > 0 && <td colSpan={mats.length} className="pl-help">{r.sameMix}</td>)
            : mats.map(m => { const x = r.mats?.find(y => y.id === m.id && y.unit === m.unit); return (
              <td key={`${m.id}|${m.unit}`} className="num">{x ? <><strong>{qtyText(r2(x.qty))}</strong>{x.cost != null && <div className="pb-cell-cost">{money(x.cost)}</div>}</> : ''}</td>); })}
          <td className="num">{r.perBag != null ? <strong>{qtyText(r2(r.perBag))}</strong> : ''}</td>
          {costed && <td className="num">{r.cost}</td>}
        </tr>
      ))}</tbody>
    </table></div>
  );
}

export default function ProductionBreakdown({ batches, dayTotal = true, stageBadge, currency }) {
  const costed = batches.some(b => b.cost != null);
  const money = v => formatMoney(Number(v), currency);
  const unitCost = (o, est) => (o.perPiece == null ? <span className="pl-help">—</span> : (
    <span className="pb-cost-val"><strong>{est ? '≈ ' : ''}{money(o.perPiece)}</strong> <span className="pb-mat-unit">/pc</span>
      {o.perSqm != null && <span className="pb-cost-sqm">{money(o.perSqm)} <span className="pb-mat-unit">/m²</span></span>}</span>
  ));
  const live = batches.filter(b => b.stage !== 'Void');
  const pcs = b => b.outputs.reduce((s, o) => s + (Number(o.pieces) || 0), 0);
  return (
    <div className={`pb${costed ? ' has-cost' : ''}`}>
      {batches.map(b => {
        const mats = [...b.materials].sort(byRank);
        const main = b.outputs.find(o => !o.residual) ?? b.outputs[0];
        const residuals = b.outputs.filter(o => o !== main);
        return (
          <section key={b.n} className={`pb-batch${b.stage === 'Void' ? ' is-void' : ''}`}>
            <div className="pb-head">
              <strong>Batch {b.n}</strong>
              {/* the team's name and how many worked — not their names (2026-11-20, the user) */}
              <span className="pl-help">{qtyText(r2(b.bags))} bags{residuals.length ? ` · ${qtyText(pcs(b))} pcs` : ''}{b.team ? ` · ${String(b.team).split(' (')[0]}` : ''}{b.people != null ? ` · ${b.people} ${b.people === 1 ? 'person' : 'people'}` : ''}{b.machine ? ` · ${b.machine}` : ''}</span>
              {b.cost != null && <span className="pb-cost-head" title={b.costComplete === false ? 'A material had no cost known — left out' : b.estimate ? 'Estimate from today\'s stock costs — fixed when saved' : 'Materials at cost, oldest stock first, VAT included'}>
                material cost <strong>{b.estimate ? '≈ ' : ''}{money(b.cost)}</strong>{b.costComplete === false && ' · part not costed'}
                {b.consumables > 0 && <span className="pl-help" title="Indirect materials (mould oil, soap): production overhead, in the cost a piece"> · consumables {money(b.consumables)}</span>}</span>}
              {b.stage && stageBadge?.(b.stage)}
              {/* a saved batch's job card, A4 (2026-11-20, the user): one card a batch */}
              {b.id && <button type="button" className="icon-btn" aria-label={`Job card for batch ${b.n}`} title="View job card — materials used and their cost, products made"
                onClick={() => window.open(`/print/job-card/${b.id}`, '_blank', 'noopener')}><FileText size={16} /></button>}
            </div>
            {main && <MaterialTable mats={mats} costed={costed} money={money} rows={[
              { name: main.name, pieces: main.pieces, passed: main.passed, mats, perBag: b.bags > 0 ? (Number(main.pieces) || 0) / b.bags : null, cost: unitCost(main, b.estimate) },
              ...residuals.map(o => ({ name: `+ ${o.name}`, pieces: o.pieces, passed: o.passed, cls: 'pb-res', sameMix: `residual · same mix as ${main.name}`, cost: unitCost(o, b.estimate) })),
            ]} />}
            {(b.waste || []).length > 0 && (
              <div className="pb-extra">wasted {b.waste.map((w, i) => <span key={i}>{i ? ' · ' : ''}<strong>{qtyText(r2(w.qty))}</strong> {w.unit} {w.name} ({w.reason}){w.cost != null ? ` ${money(w.cost)}` : ''}</span>)}</div>
            )}
            {b.qc && (b.qc.tags?.length || b.qc.note) && (
              <div className="pb-extra">QC {b.qc.tags?.length ? <strong>{b.qc.tags.join(', ')}</strong> : null}{b.qc.note ? ` — ${b.qc.note}` : ''}</div>
            )}
          </section>
        );
      })}
      {dayTotal && batches.length > 1 && (
        <section className="pb-batch pb-day">
          {(() => { const all = sumMaterials(live.map(b => b.materials)).map(m => ({ ...m, cost: live.every(b => b.materials.every(x => x.cost != null)) ? live.reduce((s, b) => s + b.materials.filter(x => x.id === m.id && x.unit === m.unit).reduce((t, x) => t + x.cost, 0), 0) : null }));
            return <MaterialTable mats={all} costed={costed} money={money} rows={[{ name: `Day total · ${live.length} batch${live.length === 1 ? '' : 'es'}`, cls: 'pb-total', pieces: live.reduce((s, b) => s + pcs(b), 0), mats: all,
              perBag: null, cost: <strong>{live.some(b => b.estimate) ? '≈ ' : ''}{money(live.reduce((s, b) => s + (Number(b.cost) || 0), 0))}</strong> }]} />; })()}
        </section>
      )}
    </div>
  );
}
