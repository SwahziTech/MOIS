import { Fragment, useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { qtyText } from '../../lib/inventory';
import { formatMoney } from '../../lib/format';
import Modal from '../Modal';
import { EntityFlags, EntityHistory } from './EntityPanels';

/**
 * A material at a glance, read-only (SwahziTech, 2026-10-23): a single
 * click shows it; editing is a double click or the Edit button. Its units
 * and conversions, stock and value at the branch, recent purchases, the
 * recipes using it, review flags and history.
 */
export default function MaterialInfo({ material: m, category, unitById, branchName, branchId, onHand, avgCost, currencyCode, suppliers, canEdit, onEdit, onClose }) {
  const [buys, setBuys] = useState(null);
  const [recipes, setRecipes] = useState(null);
  const st = unitById[m.stock_unit_id]?.symbol ?? '';
  const money = v => formatMoney(v, currencyCode);

  useEffect(() => {
    let live = true;
    Promise.all([
      supabase.from('purchase_line_costs').select('purchase_date, supplier_id, branch_id, stock_quantity, unit_price, entered_quantity, entered_unit_id, cost_per_stock_unit')
        .eq('material_id', m.id).order('purchase_date', { ascending: false }).limit(5),
      supabase.from('recipe_items').select('quantity, unit_id, recipe:recipe_versions!inner(status, branch_id, variant_label, color:color_palette(name), category:product_categories(name))')
        .eq('material_id', m.id).eq('recipe.status', 'active'),
    ]).then(([p, r]) => {
      if (!live) return;
      setBuys((p.data || []).filter(x => !branchId || x.branch_id === branchId));
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
          <div className="mm-stat"><span className="pl-label">On hand{branchId ? '' : ' (all branches)'}</span><strong>{qtyText(Math.round((onHand ?? 0) * 100) / 100)} {st}</strong></div>
          <div className="mm-stat"><span className="pl-label">Average cost</span><strong className="mm-money">{avgCost != null ? `${money(avgCost)}/${st}` : '—'}</strong></div>
          <div className="mm-stat"><span className="pl-label">Value</span><strong className="mm-money">{avgCost != null && onHand != null ? money(onHand * avgCost) : '—'}</strong></div>
        </div>

        <section>
          <h3 className="modal-section-title">Units</h3>
          <dl className="rd-dl">
            <dt>Stock unit</dt><dd>{unitById[m.stock_unit_id]?.name ?? '—'} ({st || '—'})</dd>
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

        <section>
          <h3 className="modal-section-title">Recent purchases{branchId ? ` at ${branchName(branchId)}` : ''}</h3>
          {buys === null ? <span className="skeleton" /> : buys.length === 0 ? <p className="pl-help">None recorded yet.</p> : (
            <table className="rd-table">
              <thead><tr><th>Date</th><th>Supplier</th><th className="num">Quantity</th><th className="num">Landed cost</th></tr></thead>
              <tbody>
                {buys.map((b, i) => (
                  <tr key={i}><td>{b.purchase_date}</td><td>{suppliers.find(s => s.id === b.supplier_id)?.name ?? '—'}</td>
                    <td className="num">{qtyText(b.entered_quantity)} {unitById[b.entered_unit_id]?.symbol}</td>
                    <td className="num">{b.cost_per_stock_unit != null ? `${money(b.cost_per_stock_unit)}/${st}` : '—'}</td></tr>
                ))}
              </tbody>
            </table>
          )}
        </section>

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
    </Modal>
  );
}
