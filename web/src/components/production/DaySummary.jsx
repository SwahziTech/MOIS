import { qtyText } from '../../lib/inventory';
import ProductionBreakdown, { MaterialStrip } from './ProductionBreakdown';

const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;
const STAGE_BADGE = { Curing: 'badge-accent', Ready: 'badge-warning', Released: 'badge-success', Void: 'badge-neutral' };

/**
 * A day's production at a glance: each batch's products with the materials
 * they used in Stumarcot's format (ProductionBreakdown), the day's total,
 * and — before saving — what is left in the store.
 *
 * day: { date, branchName, curingUntil, curingDays?,
 *        batches: [{ n, bags, factor?, outOfBand?, stage?, outputs: [{ name, pieces, residual, passed?, perBag }], materials: [{ id, label, name, qty, unit, rank }] }],
 *        materials?: [{ name, label?, left, leftUnit, short?, rank? }] }
 */
export default function DaySummary({ day, currency }) {
  return (
    <div className="ds">
      <div className="ds-head">
        <span><strong>{day.date}</strong> · {day.branchName}</span>
        <span>{day.batches.length} batch{day.batches.length === 1 ? '' : 'es'} · {qtyText(round(day.batches.reduce((s, b) => s + b.bags, 0)))} bags</span>
        {day.people != null && (
          <span className="ds-people" title="Each person counted once for the day, whichever batches they worked on">
            <strong>{day.people}</strong> {day.people === 1 ? 'person' : 'people'}
            {day.norm && (day.norm.max > 0) && <span className={`pl-help${day.people < day.norm.min ? ' text-warning' : ''}`}> · norm {day.norm.min === day.norm.max ? day.norm.min : `${day.norm.min}–${day.norm.max}`}{day.norm.missing ? ` (${day.norm.missing} batch${day.norm.missing === 1 ? '' : 'es'} without a norm)` : ''}</span>}
          </span>
        )}
        {day.curingUntil && <span className="ds-cure">Curing until <strong>{day.curingUntil}</strong>{day.curingDays ? ` (${day.curingDays} days)` : ''}</span>}
      </div>

      <ProductionBreakdown batches={day.batches} currency={currency} stageBadge={st => <span className={`badge ${STAGE_BADGE[st]}`}>{st}</span>} />

      {day.materials?.some(m => m.left !== undefined) && (
        <section className="pb-left">
          <span className="pl-label">Left in store after this</span>
          <MaterialStrip materials={day.materials.map(m => ({ id: m.name, label: m.label ?? m.name, name: m.name, qty: m.left, unit: m.leftUnit, rank: m.rank }))} />
          {day.materials.some(m => m.short) && <span className="text-xs text-error">Short: {day.materials.filter(m => m.short).map(m => m.name).join(', ')}</span>}
        </section>
      )}
    </div>
  );
}
