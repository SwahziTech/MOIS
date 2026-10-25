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
 * batches: [{ n, bags, stage?, cost?, costComplete?, estimate?, outputs: [{ name, pieces, passed?, residual, perBag, perPiece?, perSqm? }],
 *             materials: [{ id, label, name, qty, unit, rank }] }]
 */
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
              <span className="pl-help">{qtyText(r2(b.bags))} bags{residuals.length ? ` · ${qtyText(pcs(b))} pcs` : ''}</span>
              {b.cost != null && <span className="pb-cost-head" title={b.costComplete === false ? 'A material had no cost known — left out' : b.estimate ? 'Estimate from today\'s stock costs — fixed when saved' : 'Materials at cost, oldest stock first, VAT included'}>
                material cost <strong>{b.estimate ? '≈ ' : ''}{money(b.cost)}</strong>{b.costComplete === false && ' · part not costed'}</span>}
              {b.stage && stageBadge?.(b.stage)}
            </div>
            {main && (
              <div className="pb-row">
                <span className="pb-name">{main.name}</span>
                <span className="pb-pcs"><strong>{qtyText(main.pieces)}</strong> <span className="pb-mat-unit">pcs</span>
                  {main.passed != null && <span className="pb-passed">{qtyText(main.passed)} passed</span>}</span>
                <MaterialStrip materials={mats} soft />
                <span className="pb-avg">{b.bags > 0 ? <><strong>{qtyText(r2((Number(main.pieces) || 0) / b.bags))}</strong> <span className="pb-mat-unit">pcs/bag</span></> : '—'}</span>
                {costed && <span className="pb-cost">{unitCost(main, b.estimate)}</span>}
              </div>
            )}
            {residuals.map((o, i) => (
              <div key={i} className="pb-row pb-res">
                <span className="pb-name">+ {o.name}</span>
                <span className="pb-pcs"><strong>{qtyText(o.pieces)}</strong> <span className="pb-mat-unit">pcs</span>
                  {o.passed != null && <span className="pb-passed">{qtyText(o.passed)} passed</span>}</span>
                <span className="pl-help">residual · same mix as {main?.name}</span>
                <span />
                {costed && <span className="pb-cost">{unitCost(o, b.estimate)}</span>}
              </div>
            ))}
          </section>
        );
      })}
      {dayTotal && batches.length > 1 && (
        <section className="pb-batch pb-day">
          <div className="pb-row pb-total">
            <span className="pb-name">Day total · {live.length} batch{live.length === 1 ? '' : 'es'}</span>
            <span className="pb-pcs"><strong>{qtyText(live.reduce((s, b) => s + pcs(b), 0))}</strong> <span className="pb-mat-unit">pcs</span></span>
            <MaterialStrip materials={sumMaterials(live.map(b => b.materials))} />
            <span className="pb-avg"><strong>{qtyText(r2(live.reduce((s, b) => s + (Number(b.bags) || 0), 0)))}</strong> <span className="pb-mat-unit">bags</span></span>
            {costed && <span className="pb-cost"><strong>{live.some(b => b.estimate) ? '≈ ' : ''}{money(live.reduce((s, b) => s + (Number(b.cost) || 0), 0))}</strong></span>}
          </div>
        </section>
      )}
    </div>
  );
}
