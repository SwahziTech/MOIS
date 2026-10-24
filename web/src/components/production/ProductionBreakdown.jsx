import { qtyText } from '../../lib/inventory';

const r2 = n => Math.round(n * 100) / 100;

/**
 * Materials in Stumarcot's format (SwahziTech, 2026-10-24): short name on
 * top, the amount big, its unit small — side by side, in material order.
 * materials: [{ id, label, name, qty, unit, rank }]
 */
export function MaterialStrip({ materials, muted = false }) {
  if (!materials.length) return <span className="pl-help">—</span>;
  // two different materials with the same short name (three sands) show their full names
  const seen = {};
  for (const m of materials) (seen[m.label] ||= new Set()).add(m.id);
  const labelOf = m => (seen[m.label].size > 1 ? m.name : m.label);
  return (
    <div className={`pb-strip${muted ? ' is-muted' : ''}`}>
      {materials.map(m => (
        <span key={`${m.id}|${m.unit}`} className="pb-mat" title={m.name}>
          <span className="pb-mat-label">{labelOf(m)}</span>
          <span className="pb-mat-val"><strong>{qtyText(r2(m.qty))}</strong> <span className="pb-mat-unit">{m.unit}</span></span>
        </span>
      ))}
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
 * Each product's share of a mixed batch: by the cement its pieces take
 * (pieces ÷ its pieces per bag, as the weighted yield does), or by pieces
 * when a product has no pieces-per-bag figure.
 */
function shares(outputs) {
  const known = outputs.every(o => Number(o.perBag) > 0);
  const w = outputs.map(o => (known ? (Number(o.pieces) || 0) / Number(o.perBag) : Number(o.pieces) || 0));
  const total = w.reduce((s, x) => s + x, 0);
  return w.map(x => (total > 0 ? x / total : 1 / outputs.length));
}

/**
 * Production in Stumarcot's format (SwahziTech, 2026-10-24):
 *   Batch 1 · bags
 *     product + colour | pieces | materials used | pieces per bag
 *     product + colour | pieces | materials used | pieces per bag
 *     Batch 1 total    | pieces | materials used | pieces per bag
 *   …
 *   Day total          | pieces | materials used | bags
 * A batch's materials are shared among its products by the cement each takes.
 *
 * batches: [{ n, bags, stage?, outputs: [{ name, pieces, passed?, residual, perBag }],
 *             materials: [{ id, label, name, qty, unit, rank }] }]
 */
export default function ProductionBreakdown({ batches, dayTotal = true, stageBadge }) {
  const live = batches.filter(b => b.stage !== 'Void');
  const pcs = b => b.outputs.reduce((s, o) => s + (Number(o.pieces) || 0), 0);
  return (
    <div className="pb">
      {batches.map(b => {
        const sh = shares(b.outputs);
        const mats = [...b.materials].sort(byRank);
        const several = b.outputs.length > 1;
        return (
          <section key={b.n} className={`pb-batch${b.stage === 'Void' ? ' is-void' : ''}`}>
            <div className="pb-head">
              <strong>Batch {b.n}</strong>
              <span className="pl-help">{qtyText(r2(b.bags))} bags</span>
              {b.stage && stageBadge?.(b.stage)}
            </div>
            {b.outputs.map((o, i) => (
              <div key={i} className="pb-row">
                <span className="pb-name">{o.residual ? '+ ' : ''}{o.name}</span>
                <span className="pb-pcs"><strong>{qtyText(o.pieces)}</strong> <span className="pb-mat-unit">pcs</span>
                  {o.passed != null && <span className="pl-help"> · {qtyText(o.passed)} passed</span>}</span>
                <MaterialStrip materials={mats.map(m => ({ ...m, qty: m.qty * sh[i] }))} muted={several} />
                <span className="pb-avg">{b.bags > 0 ? <><strong>{qtyText(r2((Number(o.pieces) || 0) / (b.bags * sh[i])))}</strong> <span className="pb-mat-unit">pcs/bag</span></> : '—'}</span>
              </div>
            ))}
            {several && (
              <div className="pb-row pb-total">
                <span className="pb-name">Batch {b.n} total</span>
                <span className="pb-pcs"><strong>{qtyText(pcs(b))}</strong> <span className="pb-mat-unit">pcs</span></span>
                <MaterialStrip materials={mats} />
                <span className="pb-avg">{b.bags > 0 ? <><strong>{qtyText(r2(pcs(b) / b.bags))}</strong> <span className="pb-mat-unit">pcs/bag</span></> : '—'}</span>
              </div>
            )}
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
          </div>
        </section>
      )}
    </div>
  );
}
