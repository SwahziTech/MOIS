import { qtyText } from '../../lib/inventory';

const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;
const STAGE_BADGE = { Curing: 'badge-accent', Ready: 'badge-warning', Released: 'badge-success', Void: 'badge-neutral' };

/**
 * A day's production at a glance (2026-10-21): the batches, what each
 * product adds to stock (main products and residuals each on their own
 * line, never added together), the materials used and — before saving —
 * what is left in the store, and when curing ends. Sized to fit one screen.
 *
 * day: { date, branchName, curingUntil, curingDays?,
 *        batches: [{ n, label, bags, factor, outOfBand, stage?, outputs: [{ name, pieces, sqm, residual, passed? }] }],
 *        products: [{ name, pieces, sqm }],
 *        materials: [{ name, used, unit, left?, leftUnit?, short? }] }
 */
export default function DaySummary({ day }) {
  return (
    <div className="ds">
      <div className="ds-head">
        <span><strong>{day.date}</strong> · {day.branchName}</span>
        <span>{day.batches.length} batch{day.batches.length === 1 ? '' : 'es'} · {qtyText(round(day.batches.reduce((s, b) => s + b.bags, 0)))} bags</span>
        {day.curingUntil && <span className="ds-cure">Curing until <strong>{day.curingUntil}</strong>{day.curingDays ? ` (${day.curingDays} days)` : ''}</span>}
      </div>

      <div className="ds-grid">
        <section className="ds-col">
          <h4 className="ds-title">Batches</h4>
          <table className="ds-table">
            <tbody>
              {day.batches.map(b => (
                <tr key={b.n}>
                  <td className="ds-n">{b.n}</td>
                  <td>
                    {b.outputs.map((o, i) => (
                      <div key={i} className={o.residual ? 'ds-res' : ''}>
                        {o.residual ? '+ ' : ''}{o.name} <strong>{qtyText(o.pieces)}</strong> pcs
                        {o.passed != null && <span className="ds-muted"> · {qtyText(o.passed)} passed</span>}
                      </div>
                    ))}
                  </td>
                  <td className="ds-num">{qtyText(b.bags)} bags</td>
                  <td className="ds-num">
                    {b.stage && <span className={`badge ${STAGE_BADGE[b.stage]}`}>{b.stage}</span>}
                    {b.factor != null && <span className={`pl-badge${b.outOfBand ? ' is-out' : ''}`}>{Math.round(b.factor * 1000) / 10}%</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        <section className="ds-col">
          <h4 className="ds-title">Into stock (curing)</h4>
          <table className="ds-table">
            <tbody>
              {day.products.map(p => (
                <tr key={p.name}>
                  <td>{p.name}</td>
                  <td className="ds-num"><strong>{qtyText(p.pieces)}</strong> pcs</td>
                  <td className="ds-num ds-muted">{p.sqm != null ? `${qtyText(round(p.sqm))} m²` : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>

          <h4 className="ds-title">Materials used</h4>
          <table className="ds-table">
            <tbody>
              {day.materials.map(m => (
                <tr key={m.name} className={m.short ? 'ds-short' : ''}>
                  <td>{m.name}</td>
                  <td className="ds-num"><strong>{qtyText(round(m.used, 3))}</strong> {m.unit}</td>
                  {m.left !== undefined && <td className="ds-num ds-muted">left {qtyText(round(m.left, 3))} {m.leftUnit}</td>}
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </div>
    </div>
  );
}
