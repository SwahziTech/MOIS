import { Fragment, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { qtyText, materialStockValue } from '../../lib/inventory';
import { formatMoney } from '../../lib/format';
import Modal from '../Modal';
import { ItemHistoryList } from '../inventory/ItemHistory';
import { EntityFlags, EntityHistory } from './EntityPanels';

/**
 * A material at a glance, read-only (SwahziTech, 2026-10-23): a single
 * click shows it; editing is a double click or the Edit button. Its units
 * and conversions, stock and value at the branch, recent purchases, the
 * recipes using it, review flags and history.
 */
export default function MaterialInfo({ material: m, category, unitById, branchName, branchId, onHand, avgCost, currencyCode, suppliers, canEdit, onEdit, onClose }) {
  const [fifo, setFifo] = useState(null);     // value and cost layers left (052)
  const [recipes, setRecipes] = useState(null);
  const st = unitById[m.stock_unit_id]?.symbol ?? '';
  const money = v => formatMoney(v, currencyCode);
  // the main unit (051): stock is shown in it, the stock unit beside it
  const main = m.main_unit_id && m.main_unit_id !== m.stock_unit_id ? m.conversions.find(c => c.unit_id === m.main_unit_id) : null;
  const mf = main ? Number(main.factor_to_stock_unit) : 1;
  const ms = main ? unitById[main.unit_id]?.symbol ?? '' : st;

  useEffect(() => {
    let live = true;
    Promise.all([
      branchId ? materialStockValue(branchId, m.id) : Promise.resolve(null),
      supabase.from('recipe_items').select('quantity, unit_id, recipe:recipe_versions!inner(status, branch_id, variant_label, color:color_palette(name), category:product_categories(name))')
        .eq('material_id', m.id).eq('recipe.status', 'active'),
    ]).then(([v, r]) => {
      if (!live) return;
      setFifo(v);
      setRecipes((r.data || []).filter(x => !branchId || x.recipe.branch_id === branchId));
    });
    return () => { live = false; };
  }, [m.id, branchId]);

  return (
    <Modal title={m.name} onClose={onClose} size="lg"
      footer={<>
        {canEdit && <button type="button" className="btn btn-outline" onClick={onEdit}>Edit</button>}
        <button type="button" className="btn btn-primary" onClick={onClose}>Close</button>
      </>}>
      <div className="mi">
        <p className="text-sm text-muted">
          {category?.name ?? 'No category'} · {m.branch_id ? `${branchName(m.branch_id)} only` : 'All branches'} ·{' '}
          <span className={`badge ${m.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{m.status}</span>
        </p>

        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">On hand{branchId ? '' : ' (all branches)'}</span><strong>{qtyText(Math.round(((onHand ?? 0) / mf) * 100) / 100)} {ms}</strong>{main && <span className="pl-help">{qtyText(Math.round((onHand ?? 0) * 100) / 100)} {st}</span>}</div>
          <div className="mm-stat"><span className="pl-label">Value of stock left</span><strong className="mm-money">{fifo?.value != null ? money(fifo.value) : avgCost != null && onHand != null ? money(onHand * avgCost) : '—'}</strong>
            <span className="pl-help">oldest stock is used first</span></div>
          <div className="mm-stat"><span className="pl-label">Latest cost</span><strong className="mm-money">{fifo?.last_cost != null ? `${money(fifo.last_cost * mf)}/${ms}` : '—'}</strong>
            {fifo?.unit_cost != null && <span className="pl-help">average of stock left {money(fifo.unit_cost * mf)}/{ms}</span>}</div>
        </div>

        <ItemHistoryList item={{ kind: 'material', id: m.id, name: m.name }} branchId={branchId} mode="all" suppliers={suppliers}
          unit={{ factor: mf, symbol: ms, stockSymbol: st }} />

        <details className="pe-more">
          <summary>More about {m.name} — units, cost layers, recipes, notes</summary>
          <div className="pe-more-body">
        <section>
          <h3 className="modal-section-title">Units</h3>
          <dl className="rd-dl">
            <dt>Stock unit</dt><dd>{unitById[m.stock_unit_id]?.name ?? '—'} ({st || '—'})</dd>
            {main && <><dt>Main unit</dt><dd>{ms} — stock is counted and shown in it</dd></>}
            {m.conversions.map(c => {
              const f = Number(c.factor_to_stock_unit);
              const u = unitById[c.unit_id]?.symbol;
              return (
                <Fragment key={c.unit_id}><dt>Also counted in</dt>
                  <dd>{f >= 1 ? `1 ${u} = ${qtyText(f)} ${st}` : `1 ${st} = ${qtyText(Math.round((1 / f) * 100) / 100)} ${u}`}{c.notes ? <span className="pl-help"> — {c.notes}</span> : null}</dd></Fragment>
              );
            })}
          </dl>
        </section>

        {fifo?.layers?.length > 0 && (
          <section>
            <h3 className="modal-section-title">Stock left, by cost — oldest is used first</h3>
            <table className="rd-table">
              <thead><tr><th>In on</th><th className="num">Quantity left</th><th className="num">Cost</th><th className="num">Value</th></tr></thead>
              <tbody>
                {fifo.layers.map((l, i) => (
                  <tr key={i}><td>{l.date}</td>
                    <td className="num">{qtyText(Math.round((l.quantity / mf) * 100) / 100)} {ms}</td>
                    <td className="num">{l.cost != null ? `${money(l.cost * mf)}/${ms}` : 'no cost'}</td>
                    <td className="num">{l.cost != null ? money(l.cost * l.quantity) : '—'}</td></tr>
                ))}
              </tbody>
            </table>
          </section>
        )}

        <section>
          <h3 className="modal-section-title">Used in recipes{branchId ? ` at ${branchName(branchId)}` : ''}</h3>
          {recipes === null ? <span className="skeleton" /> : recipes.length === 0 ? <p className="pl-help">Not in any active recipe.</p> : (
            <div className="pl-tags">
              {recipes.map((r, i) => (
                <span key={i} className="pl-tag">{r.recipe.category?.name} {r.recipe.color?.name ?? r.recipe.variant_label ?? ''} · {qtyText(r.quantity)} {unitById[r.unit_id]?.symbol}/bag</span>
              ))}
            </div>
          )}
        </section>

        {m.notes && <section><h3 className="modal-section-title">Notes</h3><p className="text-sm" style={{ whiteSpace: 'pre-wrap' }}>{m.notes}</p></section>}
        <EntityFlags entityType="material" entityId={m.id} canResolve={false} canRaise={false} />
        <EntityHistory entityType="material" entityId={m.id} />
          </div>
        </details>
      </div>
    </Modal>
  );
}
