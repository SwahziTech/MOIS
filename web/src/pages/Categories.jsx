import { useEffect, useMemo, useState } from 'react';
import { FolderTree, Plus } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dbErrorMessage, slugify } from '../lib/masterData';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityFlags, EntityHistory } from '../components/master/EntityPanels';

const LOAD_ERROR = "We couldn't load this page. Please try again.";
const LAYOUTS = { colored: 'By colour', plain: 'Single price' };

/**
 * Product categories: name, layout, suggested unit and the colours products
 * in the category come in. Deactivate-only; a category with active products
 * cannot be deactivated.
 */
export default function Categories() {
  const { organization, canManage } = useAuth();
  const canWrite = canManage('products.manage');
  const [categories, setCategories] = useState([]);
  const [palette,    setPalette]    = useState([]);
  const [units,      setUnits]      = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [editing, setEditing] = useState(null);   // category row, or {} for new

  async function load() {
    setError('');
    const [catRes, palRes, unitRes] = await Promise.all([
      supabase
        .from('product_categories')
        .select(`id, category_id_ref, name, display_format, sort_order, status, default_unit_id, default_yield_tolerance,
                 unit:units(symbol, name),
                 colors:product_category_colors(color_id, display_order),
                 products(count)`)
        .eq('products.status', 'active')
        .order('sort_order').order('name'),
      supabase.from('color_palette').select('id, name, display_order, is_active').order('display_order').order('name'),
      supabase.from('units').select('id, symbol, name, status').order('symbol'),
    ]);
    const err = catRes.error || palRes.error || unitRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setCategories(catRes.data || []);
    setPalette(palRes.data || []);
    setUnits(unitRes.data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const colourName = useMemo(() => Object.fromEntries(palette.map(c => [c.id, c.name])), [palette]);
  const cols = canWrite ? 7 : 6;

  return (
    <PageShell
      title="Categories"
      subtitle="Master Data"
      actions={canWrite && (
        <button type="button" className="btn btn-primary" onClick={() => setEditing({})}>
          <Plus size={14} /> Add category
        </button>
      )}
    >
      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Category</th><th>Layout</th><th>Default unit</th><th>Colours</th>
                  <th>Active products</th><th>Status</th>{canWrite && <th aria-label="Actions" />}
                </tr>
              </thead>
              <tbody>
                {loading ? Array.from({ length: 5 }).map((_, i) => <SkeletonRow key={i} cols={cols} />)
                : categories.length === 0 ? (
                  <tr><td colSpan={cols}>
                    <EmptyState icon={FolderTree} title="No categories yet" description="Group your products into categories." />
                  </td></tr>
                ) : categories.map(c => (
                  <tr key={c.id}>
                    <td style={{ fontWeight: 500 }}>{c.name}</td>
                    <td className="text-muted">{LAYOUTS[c.display_format] || c.display_format}</td>
                    <td className="text-muted">{c.unit?.symbol || '—'}</td>
                    <td className="text-muted">
                      {[...c.colors].sort((a, b) => a.display_order - b.display_order)
                        .map(x => colourName[x.color_id]).filter(Boolean).join(', ') || '—'}
                    </td>
                    <td className="text-muted">{c.products?.[0]?.count ?? 0}</td>
                    <td><span className={`badge ${c.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{c.status}</span></td>
                    {canWrite && (
                      <td style={{ textAlign: 'right' }}>
                        <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing(c)}>Edit</button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {editing && (
        <CategoryModal
          category={editing}
          organizationId={organization.id}
          palette={palette}
          units={units}
          takenRefs={new Set(categories.map(c => c.category_id_ref))}
          nextOrder={Math.max(0, ...categories.map(c => c.sort_order)) + 1}
          onClose={() => setEditing(null)}
          onSaved={async () => { setEditing(null); await load(); }}
        />
      )}
    </PageShell>
  );
}

function uniqueRef(name, taken) {
  const base = slugify(name);
  let ref = base;
  for (let i = 2; taken.has(ref); i++) ref = `${base}_${i}`;
  return ref;
}

function CategoryModal({ category, organizationId, palette, units, takenRefs, nextOrder, onClose, onSaved }) {
  const isNew = !category.id;
  const initialColours = useMemo(() => new Set((category.colors || []).map(x => x.color_id)), [category]);
  const [name,    setName]    = useState(category.name ?? '');
  const [order,   setOrder]   = useState(category.sort_order ?? nextOrder);
  const [layout,  setLayout]  = useState(category.display_format ?? 'colored');
  const [unitId,  setUnitId]  = useState(category.default_unit_id ?? '');
  const [tolerance, setTolerance] = useState(category.default_yield_tolerance ?? '');
  const [colours, setColours] = useState(initialColours);
  const [usedColours, setUsedColours] = useState(new Set());   // colours with recipes/prices in this category
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const activeProducts = category.products?.[0]?.count ?? 0;

  // Colours this category's recipes or colour prices depend on can't be removed here
  useEffect(() => {
    if (isNew) return;
    Promise.all([
      supabase.from('recipe_versions').select('color_id').eq('category_id', category.id).eq('status', 'active').not('color_id', 'is', null),
      supabase.from('category_color_pricing_rules').select('base_color_id, items:category_color_price_items(color_id)').eq('category_id', category.id),
    ]).then(([rv, rules]) => {
      const used = new Set();
      for (const r of rv.data || []) used.add(r.color_id);
      for (const r of rules.data || []) {
        used.add(r.base_color_id);
        for (const i of r.items || []) used.add(i.color_id);
      }
      setUsedColours(used);
    });
  }, [category.id, isNew]);

  // Inactive colours stay visible only where the category already uses them
  const choosable = palette.filter(c => c.is_active || initialColours.has(c.id));
  const choosableUnits = units.filter(u => u.status === 'active' || u.id === category.default_unit_id);

  function toggleColour(id) {
    setColours(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  async function save(e) {
    e.preventDefault();
    setError('');
    if (layout === 'colored' && colours.size === 0) { setError('Choose at least one colour, or use the single-price layout.'); return; }
    if (layout === 'plain' && colours.size > 0) { setError('A single-price category has no colours — remove them first.'); return; }
    setBusy(true);

    const tol = String(tolerance).trim() === '' ? null : Number(tolerance);
    if (tol !== null && !(tol >= 0)) { setError('Default yield tolerance must be zero or more, or blank for the organization default.'); return; }
    const row = { name: name.trim(), sort_order: Number(order) || 0, display_format: layout, default_unit_id: unitId || null, default_yield_tolerance: tol };
    let categoryId = category.id;
    if (isNew) {
      const { data, error: err } = await supabase.from('product_categories')
        .insert({ ...row, organization_id: organizationId, category_id_ref: uniqueRef(row.name, takenRefs) })
        .select('id').single();
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
      categoryId = data.id;
    } else {
      const { error: err } = await supabase.from('product_categories').update(row).eq('id', categoryId);
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }

    const added   = [...colours].filter(id => !initialColours.has(id));
    const removed = [...initialColours].filter(id => !colours.has(id));
    const orderOf = Object.fromEntries(palette.map(c => [c.id, c.display_order]));
    if (added.length) {
      const { error: err } = await supabase.from('product_category_colors').insert(added.map(color_id => ({
        organization_id: organizationId, category_id: categoryId, color_id, display_order: orderOf[color_id] ?? 0,
      })));
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }
    if (removed.length) {
      const { error: err } = await supabase.from('product_category_colors')
        .delete().eq('category_id', categoryId).in('color_id', removed);
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }
    setBusy(false);
    onSaved();
  }

  async function toggleStatus() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('product_categories')
      .update({ status: category.status === 'active' ? 'inactive' : 'active' }).eq('id', category.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Add category' : `Edit ${category.name}`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="category-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !name.trim()}>Save</button>
      </>}>
      <form id="category-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="cat-name">Name</label>
            <input id="cat-name" className="form-input" required autoFocus value={name} onChange={e => setName(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="cat-order">Display order</label>
            <input id="cat-order" type="number" className="form-input" value={order} onChange={e => setOrder(e.target.value)} />
          </div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="cat-layout">Price layout</label>
            <select id="cat-layout" className="form-input" value={layout} onChange={e => setLayout(e.target.value)}>
              {Object.entries(LAYOUTS).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="cat-unit">Default unit for new products</label>
            <select id="cat-unit" className="form-input" value={unitId} onChange={e => setUnitId(e.target.value)}>
              <option value="">None</option>
              {choosableUnits.map(u => <option key={u.id} value={u.id}>{u.symbol} — {u.name}</option>)}
            </select>
          </div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="cat-tol">Default yield tolerance (± pieces per bag)</label>
            <input id="cat-tol" type="number" step="any" min="0" className="form-input" placeholder="Organization default"
              value={tolerance} onChange={e => setTolerance(e.target.value)} />
            <span className="form-hint">For this category's products unless a product sets its own. 0 means exactly the average yield.</span>
          </div>
        </div>

        {(layout === 'colored' || colours.size > 0) && (
          <section>
            <h3 className="modal-section-title">Colours</h3>
            {choosable.length === 0 ? (
              <p className="text-sm text-muted">No colours in the palette yet — add them under Colours.</p>
            ) : (
              <div className="choice-chips">
                {choosable.map(c => {
                  const locked = colours.has(c.id) && usedColours.has(c.id);
                  return (
                    <label key={c.id} className={`choice-chip${colours.has(c.id) ? ' is-on' : ''}${locked ? ' is-locked' : ''}`}
                      title={locked ? 'Used by a recipe or colour price in this category' : undefined}>
                      <input type="checkbox" checked={colours.has(c.id)} disabled={locked} onChange={() => toggleColour(c.id)} />
                      {c.name}{!c.is_active && ' (inactive)'}
                    </label>
                  );
                })}
              </div>
            )}
            {[...colours].some(id => usedColours.has(id)) && (
              <p className="text-xs text-muted mt-8">Locked colours are used by this category's recipes or colour prices.</p>
            )}
          </section>
        )}

        {!isNew && (
          <section>
            <h3 className="modal-section-title">Status</h3>
            {category.status === 'active' && activeProducts > 0 ? (
              <p className="text-sm text-muted">
                {activeProducts} active product{activeProducts === 1 ? ' is' : 's are'} in this category. Deactivate or move them first.
              </p>
            ) : (
              <>
                <p className="text-sm text-muted" style={{ marginBottom: 8 }}>
                  {category.status === 'active' ? 'Deactivating hides it when adding products.' : 'Inactive — not offered when adding products.'}
                </p>
                <button type="button" className="btn btn-outline" disabled={busy} onClick={toggleStatus}>
                  {category.status === 'active' ? 'Deactivate category' : 'Reactivate category'}
                </button>
              </>
            )}
          </section>
        )}
        {!isNew && <EntityFlags entityType="product_category" entityId={category.id} canResolve />}
        {!isNew && <EntityHistory entityType="product_category" entityId={category.id} />}
      </form>
    </Modal>
  );
}
