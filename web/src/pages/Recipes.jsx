import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityHistory } from '../components/master/EntityPanels';
import { ScrollText, Search, Plus, Trash2 } from 'lucide-react';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

/** A recipe is either for a palette colour or a named variant (e.g. a press mix). */
const variantName = r => r.color?.name ?? r.variant_label ?? '—';
/** Versions of the same recipe share branch + category + colour/variant (031) */
const recipeKey = r => `${r.branch_id}|${r.category_id}|${r.color_id ?? ''}|${r.variant_label ?? ''}`;
const today = () => new Date().toISOString().slice(0, 10);

/*
 * Recipes belong to a branch, and within it are shared per category +
 * colour or variant (migrations 011, 016, 031). A branch can start from
 * another branch's recipe (copy_recipe_to_branch); the copy is its own.
 * A saved version is never edited: changing ingredients saves a new version
 * and archives the old one (create_recipe_version, migration 020). Which
 * products use the recipe can change in place.
 */
export default function Recipes() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  // A branch's recipes: its managers and org admins (031)
  const canWriteAt = id => !!id && canAt('products.manage', id, null);
  const canWrite = canWriteAt(branchId);
  const [branchNames, setBranchNames] = useState({});
  const [carried,     setCarried]     = useState([]);   // branch_products rows
  const [recipes,    setRecipes]    = useState([]);
  const [categories, setCategories] = useState([]);
  const [materials,  setMaterials]  = useState([]);
  const [units,      setUnits]      = useState([]);
  const [products,   setProducts]   = useState([]);
  const [people,     setPeople]     = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [status,  setStatus]  = useState('active');
  const [editing, setEditing] = useState(null);   // { recipe } to change, or { recipe: null } to add

  async function load() {
    setError('');
    const [rvRes, catRes, matRes, unitRes, prodRes, brRes, bpRes] = await Promise.all([
      supabase
        .from('recipe_versions')
        .select(`
          id, branch_id, copied_from_version_id, category_id, color_id, variant_label, version_number, effective_date, status, notes, created_by, created_at,
          color:color_palette(name, display_order),
          category:product_categories(name, sort_order),
          items:recipe_items(
            material_id, quantity, unit_id, quantity_confirmed, notes,
            material:materials(name),
            unit:units(symbol)
          ),
          links:recipe_version_products(product_id)
        `)
        .order('version_number'),
      supabase.from('product_categories')
        .select('id, name, sort_order, status, colors:product_category_colors(color_id, display_order, color:color_palette(name, is_active))')
        .order('sort_order'),
      supabase.from('materials')
        .select('id, name, status, stock_unit_id, branch_id, conversions:material_unit_conversions(unit_id)')
        .order('name'),
      supabase.from('units').select('id, symbol, name'),
      supabase.from('products').select('id, canonical_name, product_id_ref, size_cm, category_id, status').order('canonical_name'),
      supabase.from('branches').select('id, name'),
      supabase.from('branch_products').select('branch_id, product_id, status'),
    ]);
    const err = rvRes.error || catRes.error || matRes.error || unitRes.error || prodRes.error || brRes.error || bpRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }

    const sorted = (rvRes.data || []).sort((a, b) =>
      (a.category?.sort_order ?? 0) - (b.category?.sort_order ?? 0) ||
      (a.category?.name || '').localeCompare(b.category?.name || '') ||
      (a.color?.display_order ?? 999) - (b.color?.display_order ?? 999) ||
      (a.variant_label || '').localeCompare(b.variant_label || '') ||
      b.version_number - a.version_number
    );
    const authorIds = [...new Set(sorted.map(r => r.created_by).filter(Boolean))];
    if (authorIds.length) {
      const { data: ppl } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', authorIds);
      setPeople(Object.fromEntries((ppl || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
    }
    setRecipes(sorted);
    setCategories(catRes.data || []);
    setMaterials(matRes.data || []);
    setUnits(unitRes.data || []);
    setProducts(prodRes.data || []);
    setBranchNames(Object.fromEntries((brRes.data || []).map(b => [b.id, b.name])));
    setCarried(bpRes.data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return recipes.filter(r =>
      inBranch(r.branch_id) &&
      (status === 'all' || r.status === status) &&
      (!q ||
        (r.category?.name || '').toLowerCase().includes(q) ||
        variantName(r).toLowerCase().includes(q))
    );
  }, [recipes, search, status, branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const cols = 8 + (branchId ? 0 : 1);

  return (
    <PageShell
      title="Recipes / BOM"
      subtitle="Master Data"
      actions={
        <>
          <select
            id="recipes-status"
            className="form-input"
            style={{ width: 130, height: 34 }}
            value={status}
            onChange={e => setStatus(e.target.value)}
            aria-label="Filter by status"
          >
            <option value="active">Active</option>
            <option value="archived">Archived</option>
            <option value="all">All versions</option>
          </select>
          <div className="search-wrapper">
            <Search size={14} className="search-icon" />
            <input
              id="recipes-search"
              type="search"
              className="search-input"
              placeholder="Search category or colour…"
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
          {canWrite ? (
            <button type="button" className="btn btn-primary" onClick={() => setEditing({ recipe: null })}>
              <Plus size={14} /> Add recipe
            </button>
          ) : !branchId && (
            <span className="text-xs text-muted">Pick a branch in the sidebar to add a recipe</span>
          )}
        </>
      }
    >
      <div className="card">
        {error ? (
          <ErrorState message={error} onRetry={load} />
        ) : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  {!branchId && <th>Branch</th>}
                  <th>Category</th>
                  <th>Colour / variant</th>
                  <th>Version</th>
                  <th>Materials (per batch)</th>
                  <th>Products</th>
                  <th>Effective</th>
                  <th>Status</th>
                  <th aria-label="Actions" />
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 6 }).map((_, i) => <SkeletonRow key={i} cols={cols} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={cols}>
                      <EmptyState
                        icon={ScrollText}
                        title="No recipes found"
                        description={search ? `No recipes match "${search}".` : 'No recipes in this view.'}
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(r => (
                    <tr key={r.id}>
                      {!branchId && <td className="text-muted">{branchNames[r.branch_id] ?? '—'}</td>}
                      <td style={{ fontWeight: 500 }}>{r.category?.name || '—'}</td>
                      <td><span className="badge badge-accent">{variantName(r)}</span></td>
                      <td>v{r.version_number}</td>
                      <td style={{ fontSize: 'var(--text-xs)' }}>
                        <IngredientBadges items={r.items} />
                      </td>
                      <td>{r.links?.length ?? 0}</td>
                      <td className="text-muted">{r.effective_date}</td>
                      <td>
                        <span className={`badge ${r.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                          {r.status}
                        </span>
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        {canWriteAt(r.branch_id) && (
                          <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing({ recipe: r })}>
                            {r.status === 'active' ? 'Change' : 'View'}
                          </button>
                        )}
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
            {!loading && filtered.length > 0 && (
              <div className="table-footer-note">
                {filtered.length} recipe version{filtered.length !== 1 ? 's' : ''} · * quantity not yet confirmed
              </div>
            )}
          </div>
        )}
      </div>

      {editing && (
        <RecipeModal
          recipe={editing.recipe}
          versions={editing.recipe ? recipes.filter(r => recipeKey(r) === recipeKey(editing.recipe)) : []}
          allRecipes={recipes}
          categories={categories}
          materials={materials}
          units={units}
          products={products}
          people={people}
          organizationId={organization.id}
          branchId={editing.recipe?.branch_id ?? branchId}
          branchName={branchNames[editing.recipe?.branch_id ?? branchId] ?? branchName}
          branchNames={branchNames}
          carriedIds={new Set(carried.filter(c => c.branch_id === (editing.recipe?.branch_id ?? branchId) && c.status === 'active').map(c => c.product_id))}
          onClose={() => setEditing(null)}
          onSaved={async () => { setEditing(null); await load(); }}
        />
      )}
    </PageShell>
  );
}

function IngredientBadges({ items }) {
  if (!items?.length) return <span className="text-muted">—</span>;
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
      {items.map((it, idx) => (
        <span key={idx} className="badge badge-neutral" title={it.quantity_confirmed ? '' : 'Quantity not yet confirmed'}>
          {it.material?.name}: {it.quantity}{it.unit?.symbol ? ` ${it.unit.symbol}` : ''}
          {!it.quantity_confirmed && ' *'}
        </span>
      ))}
    </div>
  );
}

const toRows = items => (items || []).map(it => ({
  material_id: it.material_id, quantity: String(it.quantity), unit_id: it.unit_id ?? '',
  quantity_confirmed: it.quantity_confirmed, notes: it.notes ?? null,
}));
const sameItems = (rows, items) => {
  const norm = list => list.map(r => `${r.material_id}|${Number(r.quantity)}|${r.unit_id || ''}|${!!r.quantity_confirmed}`).sort().join(';');
  return norm(rows) === norm(toRows(items));
};

function RecipeModal({ recipe, versions, allRecipes, categories, materials, units, products, people, branchId, branchName, branchNames, carriedIds, onClose, onSaved }) {
  const isNew = !recipe;
  const active = versions.find(v => v.status === 'active') ?? null;
  const readOnly = !isNew && !active;          // every version archived: recipe retired
  const [categoryId, setCategoryId] = useState(recipe?.category_id ?? '');
  const [kind,       setKind]       = useState('color');   // new recipe: 'color' | 'variant'
  const [colorId,    setColorId]    = useState('');
  const [variant,    setVariant]    = useState('');
  const [rows,       setRows]       = useState(toRows((active ?? recipe)?.items));
  const [linked,     setLinked]     = useState(new Set((active ?? recipe)?.links?.map(l => l.product_id) ?? []));
  const [effective,  setEffective]  = useState(today());
  const [notes,      setNotes]      = useState('');
  const [viewing,    setViewing]    = useState(null);  // archived version shown read-only
  const [confirmRetire, setConfirmRetire] = useState(false);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  const unitSymbol = useMemo(() => Object.fromEntries(units.map(u => [u.id, u.symbol])), [units]);
  const materialById = useMemo(() => Object.fromEntries(materials.map(m => [m.id, m])), [materials]);
  const category = categories.find(c => c.id === categoryId);
  // Products this branch carries (031), plus any already linked
  const categoryProducts = products.filter(p => p.category_id === categoryId
    && ((p.status === 'active' && carriedIds.has(p.id)) || linked.has(p.id)));
  // Materials: shared ones and this branch's own (032)
  const usableMaterial = m => !m.branch_id || m.branch_id === branchId;

  // New recipe: colours of the category with no active recipe in this branch yet
  const takenColours = new Set(allRecipes.filter(r => r.branch_id === branchId && r.category_id === categoryId && r.status === 'active' && r.color_id).map(r => r.color_id));
  // Other branches' current recipes for the same category + colour/variant: a starting point
  const otherBranches = isNew ? allRecipes.filter(r => r.branch_id !== branchId && r.status === 'active' && r.category_id === categoryId
    && (kind === 'color' ? colorId && r.color_id === colorId : variant.trim() && (r.variant_label || '').toLowerCase() === variant.trim().toLowerCase())) : [];
  const freeColours = (category?.colors || [])
    .filter(c => c.color?.is_active && !takenColours.has(c.color_id))
    .sort((a, b) => a.display_order - b.display_order);

  const unitChoices = materialId => {
    const m = materialById[materialId];
    if (!m) return [];
    return [...new Set([m.stock_unit_id, ...m.conversions.map(c => c.unit_id)].filter(Boolean))];
  };

  function setRow(i, patch) {
    setRows(rs => rs.map((r, j) => {
      if (j !== i) return r;
      const next = { ...r, ...patch };
      // a new material keeps the unit only if that material allows it
      if (patch.material_id !== undefined && !unitChoices(patch.material_id).includes(next.unit_id)) {
        next.unit_id = materialById[patch.material_id]?.stock_unit_id ?? '';
      }
      return next;
    }));
  }

  function toggleProduct(id) {
    setLinked(prev => { const n = new Set(prev); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  }

  async function save(e) {
    e.preventDefault();
    setError('');
    if (rows.length === 0) { setError('A recipe needs at least one ingredient.'); return; }
    const ids = rows.map(r => r.material_id);
    if (ids.some(id => !id)) { setError('Choose a material for every ingredient line.'); return; }
    if (new Set(ids).size !== ids.length) { setError('Each material can appear only once in a recipe.'); return; }
    if (rows.some(r => r.quantity.trim() === '' || !(Number(r.quantity) >= 0))) { setError('Every quantity must be zero or more.'); return; }
    if (rows.some(r => !r.unit_id)) { setError('Choose a unit for every ingredient — add the material\'s units under Materials first.'); return; }
    if (isNew && kind === 'color' && !colorId) { setError('Choose the colour this recipe is for.'); return; }
    if (isNew && kind === 'variant' && !variant.trim()) { setError('Name the variant, e.g. the mix name.'); return; }

    const items = rows.map(r => ({
      material_id: r.material_id, quantity: Number(r.quantity), unit_id: r.unit_id,
      quantity_confirmed: r.quantity_confirmed, notes: r.notes,
    }));
    const productIds = [...linked];
    setBusy(true);

    // Only the products changed: update the links of the current version in place
    if (!isNew && sameItems(rows, active.items)) {
      const before = new Set(active.links.map(l => l.product_id));
      const add = productIds.filter(id => !before.has(id));
      const remove = [...before].filter(id => !linked.has(id));
      if (!add.length && !remove.length) { setBusy(false); setError('Nothing has changed.'); return; }
      if (add.length) {
        const { error: err } = await supabase.from('recipe_version_products')
          .insert(add.map(product_id => ({ recipe_version_id: active.id, product_id })));
        if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
      }
      if (remove.length) {
        const { error: err } = await supabase.from('recipe_version_products')
          .delete().eq('recipe_version_id', active.id).in('product_id', remove);
        if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
      }
      setBusy(false);
      onSaved();
      return;
    }

    const { error: err } = await supabase.rpc('create_recipe_version', {
      p_branch_id:      isNew ? branchId : null,
      p_replaces:       active?.id ?? null,
      p_category_id:    isNew ? categoryId : null,
      p_color_id:       isNew && kind === 'color' ? colorId : null,
      p_variant_label:  isNew && kind === 'variant' ? variant.trim() : null,
      p_items:          items,
      p_product_ids:    productIds,
      p_effective_date: effective || null,
      p_notes:          notes.trim() || null,
    });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  // Start this branch's recipe as an independent copy of another branch's
  async function copyFrom(src) {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.rpc('copy_recipe_to_branch', {
      p_version_id: src.id, p_branch_id: branchId, p_notes: `Started from ${branchNames[src.branch_id] ?? 'another branch'}'s recipe`,
    });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  async function retire() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('recipe_versions').update({ status: 'archived' }).eq('id', active.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  const title = `${isNew ? 'Add recipe' : `${recipe.category?.name} — ${variantName(recipe)}`}${branchName ? ` · ${branchName}` : ''}`;
  const willVersion = !isNew && active && !sameItems(rows, active.items);

  return (
    <Modal title={title} onClose={onClose} size="lg"
      footer={readOnly ? (
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
      ) : <>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="recipe-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>
          {isNew ? 'Add recipe' : willVersion ? `Save as v${Math.max(...versions.map(v => v.version_number)) + 1}` : 'Save'}
        </button>
      </>}>
      <form id="recipe-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}

        {isNew && (
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="rec-cat">Category</label>
              <select id="rec-cat" className="form-input" required value={categoryId}
                onChange={e => { setCategoryId(e.target.value); setColorId(''); setLinked(new Set()); }}>
                <option value="" disabled>Choose…</option>
                {categories.filter(c => c.status === 'active').map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="rec-kind">For</label>
              <div className="flex gap-8">
                <select id="rec-kind" className="form-input" style={{ width: 'auto' }} value={kind} onChange={e => setKind(e.target.value)}>
                  <option value="color">A colour</option>
                  <option value="variant">A named variant</option>
                </select>
                {kind === 'color' ? (
                  <select className="form-input" aria-label="Colour" value={colorId} onChange={e => setColorId(e.target.value)} disabled={!categoryId}>
                    <option value="">{!categoryId ? 'Choose a category first' : freeColours.length ? 'Choose…' : 'All colours have a recipe'}</option>
                    {freeColours.map(c => <option key={c.color_id} value={c.color_id}>{c.color.name}</option>)}
                  </select>
                ) : (
                  <input className="form-input" aria-label="Variant name" placeholder="e.g. Press mix" value={variant} onChange={e => setVariant(e.target.value)} />
                )}
              </div>
            </div>
          </div>
        )}

        {otherBranches.length > 0 && (
          <div className="alert alert-info" role="note">
            {otherBranches.map(o => (
              <div key={o.id} className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
                {branchNames[o.branch_id]} already has this recipe (v{o.version_number}).
                <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={() => copyFrom(o)}>
                  Copy it to {branchName}
                </button>
              </div>
            ))}
            <div className="text-xs mt-4">The copy becomes {branchName}'s own: later changes in either branch don't carry over.</div>
          </div>
        )}

        {readOnly ? (
          <p className="text-sm text-muted">This recipe is retired — all its versions are archived. Version history is below.</p>
        ) : (
          <>
            <section>
              <h3 className="modal-section-title">Ingredients (per batch)</h3>
              <div className="ingredient-list">
                {rows.map((r, i) => (
                  <div key={i} className="ingredient-row">
                    <select className="form-input" aria-label="Material" value={r.material_id}
                      onChange={e => setRow(i, { material_id: e.target.value })}>
                      <option value="" disabled>Material…</option>
                      {materials.filter(m => (m.status === 'active' && usableMaterial(m)) || m.id === r.material_id).map(m => (
                        <option key={m.id} value={m.id}>{m.name}{m.status !== 'active' ? ' (inactive)' : ''}</option>
                      ))}
                    </select>
                    <input type="number" step="any" min="0" className="form-input" aria-label="Quantity"
                      value={r.quantity} onChange={e => setRow(i, { quantity: e.target.value })} />
                    <select className="form-input" aria-label="Unit" value={r.unit_id} onChange={e => setRow(i, { unit_id: e.target.value })}>
                      <option value="" disabled>Unit…</option>
                      {unitChoices(r.material_id).map(u => <option key={u} value={u}>{unitSymbol[u]}</option>)}
                    </select>
                    <label className="text-xs flex items-center gap-4" title="Untick if this quantity still needs confirming">
                      <input type="checkbox" checked={r.quantity_confirmed} onChange={e => setRow(i, { quantity_confirmed: e.target.checked })} />
                      confirmed
                    </label>
                    <button type="button" className="icon-btn" aria-label="Remove ingredient" onClick={() => setRows(rs => rs.filter((_, j) => j !== i))}>
                      <Trash2 size={14} />
                    </button>
                  </div>
                ))}
              </div>
              <button type="button" className="btn btn-ghost btn-sm mt-8"
                onClick={() => setRows(rs => [...rs, { material_id: '', quantity: '', unit_id: '', quantity_confirmed: true, notes: null }])}>
                <Plus size={13} /> Add ingredient
              </button>
            </section>

            {(isNew || willVersion) && (
              <div className="form-row">
                <div className="form-group">
                  <label className="form-label" htmlFor="rec-date">Effective from</label>
                  <input id="rec-date" type="date" className="form-input" value={effective} onChange={e => setEffective(e.target.value)} />
                </div>
                <div className="form-group">
                  <label className="form-label" htmlFor="rec-notes">What changed and why</label>
                  <input id="rec-notes" className="form-input" placeholder="Optional" value={notes} onChange={e => setNotes(e.target.value)} />
                </div>
              </div>
            )}
            {willVersion && (
              <p className="text-xs text-muted">
                Saving creates version {Math.max(...versions.map(v => v.version_number)) + 1}; v{active.version_number} is archived unchanged.
              </p>
            )}

            {categoryId && (
              <section>
                <h3 className="modal-section-title">Products using this recipe ({linked.size})</h3>
                {categoryProducts.length === 0 ? (
                  <p className="text-sm text-muted">No products of this category in {branchName}'s list — add them on the Products page first.</p>
                ) : (
                  <div className="choice-chips">
                    {categoryProducts.map(p => (
                      <label key={p.id} className={`choice-chip${linked.has(p.id) ? ' is-on' : ''}`} title={p.size_cm ? `Size ${p.size_cm}` : undefined}>
                        <input type="checkbox" checked={linked.has(p.id)} onChange={() => toggleProduct(p.id)} />
                        {p.canonical_name}{p.status !== 'active' ? ' (inactive)' : ''}
                      </label>
                    ))}
                  </div>
                )}
              </section>
            )}

            {!isNew && active && (
              <section>
                <h3 className="modal-section-title">Retire</h3>
                {confirmRetire ? (
                  <div className="confirm-box">
                    <p className="text-sm">Archive v{active.version_number} with no replacement? Its {active.links.length} product{active.links.length === 1 ? '' : 's'} will have no active recipe for {variantName(recipe)}.</p>
                    <div className="flex gap-8">
                      <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={retire}>Retire recipe</button>
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setConfirmRetire(false)}>Keep it</button>
                    </div>
                  </div>
                ) : (
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setConfirmRetire(true)}>Retire this recipe…</button>
                )}
              </section>
            )}
          </>
        )}

        {versions.length > 0 && (
          <section className="entity-panel">
            <h3 className="modal-section-title">Versions</h3>
            <ul className="history-list">
              {[...versions].sort((a, b) => b.version_number - a.version_number).map(v => (
                <li key={v.id} className="text-sm">
                  <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
                    <strong>v{v.version_number}</strong>
                    <span className={`badge ${v.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{v.status}</span>
                    <span className="text-muted">from {v.effective_date}{v.created_by ? ` · ${people[v.created_by] || 'a user'}` : ' · data import'}</span>
                    {v.status !== 'active' && (
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setViewing(viewing === v.id ? null : v.id)}>
                        {viewing === v.id ? 'Hide' : 'Show'}
                      </button>
                    )}
                    {v.status !== 'active' && active && (
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRows(toRows(v.items))}>
                        Start from this version
                      </button>
                    )}
                  </div>
                  {v.notes && <p className="text-xs text-muted">{v.notes}</p>}
                  {v.copied_from_version_id && (() => {
                    const src = allRecipes.find(x => x.id === v.copied_from_version_id);
                    return src ? <p className="text-xs text-muted">Started from {branchNames[src.branch_id] ?? 'another branch'}'s v{src.version_number}</p> : null;
                  })()}
                  {(viewing === v.id || (readOnly && v === versions.at(-1))) && <div className="mt-8 text-xs"><IngredientBadges items={v.items} /></div>}
                </li>
              ))}
            </ul>
          </section>
        )}
        {active && <EntityHistory entityType="recipe_version" entityId={active.id} />}
      </form>
    </Modal>
  );
}
