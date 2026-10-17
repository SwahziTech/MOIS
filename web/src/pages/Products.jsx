import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Package, Search, Plus, Flag } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityFlags, EntityHistory } from '../components/master/EntityPanels';

const LOAD_ERROR = "We couldn't load this page. Please try again.";
const sameName = (a, b) => a.trim().toLowerCase().replace(/\s+/g, ' ') === b.trim().toLowerCase().replace(/\s+/g, ' ');

/**
 * Sort key for a size like "40x40", "20x10x8", "200x13.3x80mm", "40x40x2in":
 * footprint first (first two dimensions, mm → cm), then each dimension.
 * No size sorts last.
 */
function sizeKey(size) {
  if (!size) return [Infinity];
  const mm = /mm/i.test(size);
  const nums = (String(size).match(/\d+(?:\.\d+)?/g) || []).map(Number).map(n => (mm ? n / 10 : n));
  if (!nums.length) return [Infinity];
  return [nums.length >= 2 ? nums[0] * nums[1] : nums[0], ...nums];
}
const compareKeys = (a, b) => {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? -1, y = b[i] ?? -1;
    if (x !== y) return x - y;
  }
  return 0;
};

export default function Products() {
  const { organization, canManage, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const canWrite = canManage('products.manage');   // shared product details: org admins
  // A branch's own catalogue: its managers add and remove products (031/032)
  const canCatalogue = !!branchId && canAt('products.manage', branchId, null);
  const [categories, setCategories] = useState([]);
  const [products,   setProducts]   = useState([]);
  const [units,      setUnits]      = useState([]);
  const [openFlags,  setOpenFlags]  = useState({});   // product id → open flag count
  const [specs,      setSpecs]      = useState({});   // product id → effective pcs/m² and yield (031)
  const [stock,      setStock]      = useState([]);   // stock_balances rows for products
  const [whBranch,   setWhBranch]   = useState({});   // warehouse id → branch id
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [categoryId,      setCategoryId]      = useState('');
  const [statusFilter,    setStatusFilter]    = useState('active');    // active | inactive | review | all
  const [catalogueFilter, setCatalogueFilter] = useState('carried');   // carried | not_carried | all (one branch picked)
  const [stockFilter,     setStockFilter]     = useState('');          // '' | in_stock | none
  const [editing,  setEditing]  = useState(null);   // product row, or {} for new
  const [viewing,  setViewing]  = useState(null);   // product row in the details window
  const [selected, setSelected] = useState(null);   // highlighted row
  const [carried, setCarried] = useState({});       // product id → { branch id → branch_products row }
  const [branchNames, setBranchNames] = useState({});

  async function load() {
    setError('');
    const [catRes, prodRes, unitRes, flagRes, bpRes, brRes, specRes, stockRes, whRes] = await Promise.all([
      supabase
        .from('product_categories')
        .select('id, name, category_id_ref, display_format, sort_order, status, default_unit_id')
        .order('sort_order'),
      supabase
        .from('products')
        .select(`
          id, product_id_ref, canonical_name, size_cm, category_id, unit_id,
          pcs_per_sqm, wastani_per_bag, status, notes, strength_class,
          category:product_categories(id, name, display_format, sort_order),
          unit:units(symbol, name),
          recipes:recipe_version_products(count)
        `),
      supabase.from('units').select('id, symbol, name, status').order('symbol'),
      supabase.from('review_flags').select('entity_id').eq('entity_type', 'product').eq('status', 'open'),
      supabase.from('branch_products').select('id, branch_id, product_id, status'),
      supabase.from('branches').select('id, name'),
      supabase.from('product_specs').select('product_id, pcs_per_sqm, pcs_source, average_yield_per_bag, yield_source, yield_tolerance'),
      supabase.from('stock_balances').select('warehouse_id, product_id, color_id, quantity').not('product_id', 'is', null),
      supabase.from('warehouses').select('id, name, branch_id'),
    ]);
    const err = [catRes, prodRes, unitRes, flagRes, bpRes, brRes, specRes, stockRes, whRes].find(r => r.error)?.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    const counts = {};
    for (const f of flagRes.data || []) counts[f.entity_id] = (counts[f.entity_id] || 0) + 1;
    setCategories(catRes.data || []);
    setProducts(prodRes.data || []);
    setUnits(unitRes.data || []);
    setOpenFlags(counts);
    const bp = {};
    for (const r of bpRes.data || []) (bp[r.product_id] ||= {})[r.branch_id] = r;
    setCarried(bp);
    setBranchNames(Object.fromEntries((brRes.data || []).map(b => [b.id, b.name])));
    setSpecs(Object.fromEntries((specRes.data || []).map(s => [s.product_id, s])));
    setStock(stockRes.data || []);
    setWhBranch(Object.fromEntries((whRes.data || []).map(w => [w.id, w.branch_id])));
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const carriedHere = id => carried[id]?.[branchId]?.status === 'active';
  // On hand for the picked branch (all branches on "All branches")
  const onHand = useMemo(() => {
    const m = {};
    for (const s of stock) if (inBranch(whBranch[s.warehouse_id])) m[s.product_id] = (m[s.product_id] || 0) + Number(s.quantity);
    return m;
  }, [stock, whBranch, branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Links from the Review queue open a product directly (?edit=<id>)
  const [params, setParams] = useSearchParams();
  useEffect(() => {
    const id = params.get('edit');
    if (!id || !products.length) return;
    const p = products.find(x => x.id === id);
    if (p) { setStatusFilter('all'); setEditing(p); }
    setParams({}, { replace: true });
  }, [params, products]); // eslint-disable-line react-hooks/exhaustive-deps

  // Category order is the organization's own (Categories → order), then
  // size smallest to largest, then name
  const sorted = useMemo(() => [...products].sort((a, b) =>
    (a.category?.sort_order ?? 999) - (b.category?.sort_order ?? 999)
    || (a.category?.name || '').localeCompare(b.category?.name || '')
    || compareKeys(sizeKey(a.size_cm), sizeKey(b.size_cm))
    || a.canonical_name.localeCompare(b.canonical_name, undefined, { numeric: true })), [products]);

  const q = search.trim().toLowerCase();
  const passesCatalogue = p => !branchId || catalogueFilter === 'all' || carriedHere(p.id) === (catalogueFilter === 'carried');
  const filtered = sorted.filter(p => {
    if (categoryId && p.category_id !== categoryId) return false;
    if (statusFilter === 'review' ? !openFlags[p.id] : statusFilter !== 'all' && p.status !== statusFilter) return false;
    if (!passesCatalogue(p)) return false;
    if (stockFilter && (Number(onHand[p.id] ?? 0) !== 0) !== (stockFilter === 'in_stock')) return false;
    return !q || p.canonical_name.toLowerCase().includes(q) || p.product_id_ref.toLowerCase().includes(q);
  });
  const reviewCount = products.filter(p => openFlags[p.id] && passesCatalogue(p)).length;
  const carriedCount = branchId ? products.filter(p => carriedHere(p.id)).length : 0;

  // Coverage and yield are optional, industry-specific measures: show their
  // columns only when some product in view has one
  const showCoverage = filtered.some(p => specs[p.id]?.pcs_per_sqm != null);
  const showYield    = filtered.some(p => specs[p.id]?.average_yield_per_bag != null);
  const cols = 5 + (showCoverage ? 1 : 0) + (showYield ? 1 : 0);

  return (
    <PageShell
      title="Products"
      subtitle="Master Data"
      actions={
        <div className="flex items-center gap-8">
          <div className="search-wrapper">
            <Search size={14} className="search-icon" />
            <input id="products-search" type="search" className="search-input" placeholder="Search products…"
              value={search} onChange={e => setSearch(e.target.value)} />
          </div>
          {(canWrite || canCatalogue) && (
            <button type="button" className="btn btn-primary" onClick={() => setEditing({})}>
              <Plus size={14} /> Add product
            </button>
          )}
        </div>
      }
    >
      {!loading && !error && (
        <div className="flex items-center gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
          <select className="form-input" style={{ width: 'auto' }} aria-label="Category" value={categoryId} onChange={e => setCategoryId(e.target.value)}>
            <option value="">All categories</option>
            {categories.filter(c => c.status === 'active' || products.some(p => p.category_id === c.id)).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          {branchId && (
            <select className="form-input" style={{ width: 'auto' }} aria-label="Catalogue" value={catalogueFilter} onChange={e => setCatalogueFilter(e.target.value)}>
              <option value="carried">In {branchName}'s list ({carriedCount})</option>
              <option value="not_carried">Not in {branchName}'s list</option>
              <option value="all">All products</option>
            </select>
          )}
          <select className="form-input" style={{ width: 'auto' }} aria-label="Stock" value={stockFilter} onChange={e => setStockFilter(e.target.value)}>
            <option value="">Any stock</option>
            <option value="in_stock">In stock</option>
            <option value="none">No stock</option>
          </select>
          <select className="form-input" style={{ width: 'auto' }} aria-label="Show" value={statusFilter} onChange={e => setStatusFilter(e.target.value)}>
            <option value="active">Active</option>
            <option value="review">Needs review ({reviewCount})</option>
            <option value="inactive">Inactive</option>
            <option value="all">All</option>
          </select>
        </div>
      )}

      <div className="card">
        {error ? (
          <ErrorState message={error} onRetry={load} />
        ) : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Product</th>
                  <th>Size</th>
                  {showCoverage && <th title="Pieces needed to cover one square metre">Pieces per m²</th>}
                  {showYield && <th title="Average pieces from one 50 kg bag of cement">Yield per bag</th>}
                  <th>Stock unit</th>
                  <th style={{ textAlign: 'right' }} title={branchId ? `On hand at ${branchName}` : 'On hand across all branches'}>
                    Stock qty{branchId ? '' : ' (all)'}
                  </th>
                  <th aria-label="Actions" />
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 8 }).map((_, i) => <SkeletonRow key={i} cols={cols} />)
                ) : filtered.length === 0 ? (
                  <tr><td colSpan={cols}>
                    <EmptyState icon={Package} title="No products found"
                      description={search ? `No products match "${search}".` : 'No products in this view.'} />
                  </td></tr>
                ) : filtered.map(p => {
                  const sp = specs[p.id];
                  const qty = onHand[p.id];
                  return (
                    <tr key={p.id} className={`clickable-row${selected === p.id ? ' is-selected' : ''}`}
                      onClick={() => setSelected(p.id)} onDoubleClick={() => setViewing(p)} title="Double-click for details">
                      <td>
                        <div style={{ fontWeight: 500 }}>
                          {p.canonical_name}
                          {p.status !== 'active' && <span className="text-muted"> (inactive)</span>}
                          {openFlags[p.id] > 0 && (
                            <span className="badge badge-warning" style={{ marginLeft: 8 }} title="Open review flags"><Flag size={11} /> needs review</span>
                          )}
                        </div>
                        <div className="text-xs text-muted">{p.category?.name || '—'}</div>
                      </td>
                      <td>{p.size_cm || <span className="text-muted">—</span>}</td>
                      {showCoverage && <td>{sp?.pcs_per_sqm != null ? +Number(sp.pcs_per_sqm).toPrecision(6) : <span className="text-muted" title="Not recorded yet">—</span>}</td>}
                      {showYield && <td>{sp?.average_yield_per_bag != null ? +Number(sp.average_yield_per_bag).toPrecision(6) : <span className="text-muted" title="Not recorded yet">—</span>}</td>}
                      <td><span className="badge badge-neutral" title={p.unit?.name}>{p.unit?.symbol || '—'}</span></td>
                      <td style={{ textAlign: 'right', fontWeight: qty ? 600 : 400 }} className={qty ? '' : 'text-muted'}>
                        {qty ? new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(qty) : '—'}
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        <button type="button" className="btn btn-ghost btn-sm" onClick={e => { e.stopPropagation(); setViewing(p); }}>Open</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>

            {!loading && filtered.length > 0 && (
              <div className="table-footer-note">
                {filtered.length} product{filtered.length !== 1 ? 's' : ''}
                {filtered.length !== products.length ? ` (of ${products.length})` : ''} · double-click a row (or Open) for its details
              </div>
            )}
          </div>
        )}
      </div>

      {viewing && (
        <ProductDetail
          product={products.find(x => x.id === viewing.id) ?? viewing}
          spec={specs[viewing.id]}
          stock={stock.filter(s => s.product_id === viewing.id && inBranch(whBranch[s.warehouse_id]))}
          carried={carried[viewing.id] || {}}
          branchId={branchId} branchName={branchName} branchNames={branchNames}
          canWrite={canWrite} canCatalogue={canCatalogue} organization={organization} openFlagCount={openFlags[viewing.id] || 0}
          onEdit={() => { setEditing(products.find(x => x.id === viewing.id)); setViewing(null); }}
          onClose={() => setViewing(null)}
          onChanged={load}
        />
      )}

      {editing && (
        <ProductModal
          product={editing}
          organization={organization}
          categories={categories}
          units={units}
          products={products}
          branchId={branchId} branchName={branchName}
          onClose={() => setEditing(null)}
          onSaved={async (close = true) => { if (close) setEditing(null); await load(); }}
        />
      )}
    </PageShell>
  );
}

/**
 * Everything about a product in one place: its details, this branch's
 * stock, prices and recipes, and whether the branch carries it. Adding or
 * removing it from the branch's list always asks first — a stray click
 * shouldn't change a catalogue.
 */
function ProductDetail({ product: p, spec, stock, carried, branchId, branchName, branchNames, canWrite, canCatalogue, organization, openFlagCount, onEdit, onClose, onChanged }) {
  const money = v => formatMoney(v, organization?.currency_code);
  const [prices,  setPrices]  = useState(null);
  const [recipes, setRecipes] = useState(null);
  const [names,   setNames]   = useState({ wh: {}, color: {} });
  const [confirm, setConfirm] = useState(false);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const row = branchId ? carried[branchId] : null;
  const isCarried = row?.status === 'active';

  useEffect(() => {
    let live = true;
    (async () => {
      const byBranch = q => (branchId ? q.eq('branch_id', branchId) : q);
      const [pr, rv, wh, co] = await Promise.all([
        byBranch(supabase.from('product_branch_pricing')
          .select('branch_id, color_id, price_per_sqm_inclusive, price_per_unit_inclusive, pcs_per_sqm_at_pricing, is_available')
          .eq('product_id', p.id)),
        supabase.from('recipe_version_products')
          .select('recipe:recipe_versions(id, branch_id, status, version_number, variant_label, color:color_palette(name), category:product_categories(name))')
          .eq('product_id', p.id),
        supabase.from('warehouses').select('id, name, branch:branches(name)'),
        supabase.from('color_palette').select('id, name'),
      ]);
      if (!live) return;
      setPrices(pr.data || []);
      setRecipes((rv.data || []).map(r => r.recipe).filter(r => r && r.status === 'active' && (!branchId || r.branch_id === branchId)));
      setNames({
        wh: Object.fromEntries((wh.data || []).map(w => [w.id, `${w.branch?.name} — ${w.name}`])),
        color: Object.fromEntries((co.data || []).map(c => [c.id, c.name])),
      });
    })();
    return () => { live = false; };
  }, [p.id, branchId]);

  async function setCarried(on) {
    setError('');
    setBusy(true);
    const { error: err } = row
      ? await supabase.from('branch_products').update({ status: on ? 'active' : 'inactive' }).eq('id', row.id)
      : await supabase.from('branch_products').insert({ organization_id: organization.id, branch_id: branchId, product_id: p.id });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setConfirm(false);
    onChanged();
  }

  const unit = p.unit?.symbol ?? '';
  const total = stock.reduce((s, r) => s + Number(r.quantity), 0);
  const fmt = n => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(n);
  const priceText = r => (r.price_per_sqm_inclusive != null ? `${money(r.price_per_sqm_inclusive)} /m²` : r.price_per_unit_inclusive != null ? `${money(r.price_per_unit_inclusive)} each` : 'category colour pricing');
  const sourceText = s => (s === 'size' ? 'from its size' : s === 'product' ? "this product's own figure" : '');

  return (
    <Modal title={p.canonical_name} onClose={onClose} size="lg"
      footer={<>
        {canWrite && <button type="button" className="btn btn-outline" onClick={onEdit}>Edit details</button>}
        <button type="button" className="btn btn-primary" onClick={onClose}>Close</button>
      </>}>
      <div className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <p className="text-sm text-muted">
          {p.category?.name}{p.strength_class ? ` · ${p.strength_class}` : ''} ·{' '}
          <span className={`badge ${p.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{p.status}</span>
          {openFlagCount > 0 && <span className="badge badge-warning" style={{ marginLeft: 6 }}><Flag size={11} /> {openFlagCount} to review</span>}
        </p>

        <dl className="detail-list text-sm">
          <dt>Size</dt><dd>{p.size_cm || '—'}</dd>
          <dt>Stock unit</dt><dd>{unit || '—'}</dd>
          <dt>Pieces per m²</dt><dd>{spec?.pcs_per_sqm != null ? <>{+Number(spec.pcs_per_sqm).toPrecision(6)} <span className="text-muted">({sourceText(spec.pcs_source)})</span></> : '—'}</dd>
          <dt>Yield per bag</dt><dd>{spec?.average_yield_per_bag != null ? <>{+Number(spec.average_yield_per_bag).toPrecision(6)}{spec.yield_tolerance != null ? ` ± ${+spec.yield_tolerance}` : ''} <span className="text-muted">({sourceText(spec.yield_source)})</span></> : '—'}</dd>
          {p.notes && <><dt>Notes</dt><dd style={{ whiteSpace: 'pre-wrap' }}>{p.notes}</dd></>}
        </dl>

        <section>
          <h3 className="modal-section-title">{branchId ? `${branchName}'s product list` : 'Carried by'}</h3>
          {branchId ? (
            confirm ? (
              <div className="confirm-box">
                <p className="text-sm">{isCarried ? `Remove ${p.canonical_name} from ${branchName}'s catalogue?` : `Add ${p.canonical_name} to ${branchName}'s catalogue?`}</p>
                {isCarried && total !== 0 && <p className="text-xs text-muted">{branchName} still holds {fmt(total)} {unit}. Removing it only hides it from {branchName}'s list; the stock stays.</p>}
                <div className="flex gap-8">
                  <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => setCarried(!isCarried)}>{isCarried ? 'Yes, remove it' : 'Yes, add it'}</button>
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setConfirm(false)}>Cancel</button>
                </div>
              </div>
            ) : (
              <p className="text-sm flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
                {isCarried ? <span className="badge badge-success">In {branchName}'s list</span> : <span className="badge badge-neutral">Not in {branchName}'s list</span>}
                {canCatalogue && p.status === 'active' && (
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setConfirm(true)}>
                    {isCarried ? `Remove from ${branchName}'s list…` : `Add to ${branchName}'s list…`}
                  </button>
                )}
              </p>
            )
          ) : (
            <p className="text-sm">{Object.values(carried).filter(r => r.status === 'active').map(r => branchNames[r.branch_id]).sort().join(', ') || 'No branch'}</p>
          )}
        </section>

        <section>
          <h3 className="modal-section-title">Stock on hand{branchId ? ` at ${branchName}` : ''}</h3>
          {stock.filter(s => Number(s.quantity) !== 0).length === 0 ? <p className="text-sm text-muted">None.</p> : (
            <ul className="history-list">
              {stock.filter(s => Number(s.quantity) !== 0).map(s => (
                <li key={`${s.warehouse_id}|${s.color_id}`} className="text-sm">
                  {names.wh[s.warehouse_id] ?? '…'}{s.color_id ? ` · ${names.color[s.color_id] ?? ''}` : ''}: <strong>{fmt(s.quantity)}</strong> {unit}
                </li>
              ))}
              <li className="text-sm text-muted">Total {fmt(total)} {unit}</li>
            </ul>
          )}
        </section>

        <section>
          <h3 className="modal-section-title">Prices{branchId ? ` at ${branchName}` : ''}</h3>
          {prices == null ? <p className="text-sm text-muted">Loading…</p> : prices.length === 0 ? <p className="text-sm text-muted">No price yet.</p> : (
            <ul className="history-list">
              {[...prices].sort((a, b) => (a.color_id ? 1 : 0) - (b.color_id ? 1 : 0)).map((r, i) => (
                <li key={i} className="text-sm">
                  {!branchId && <span className="text-muted">{branchNames[r.branch_id]}: </span>}
                  {r.color_id ? `${names.color[r.color_id] ?? 'Colour'}: ` : 'Base: '}{priceText(r)}
                  {!r.is_available && <span className="text-muted"> (not sold here)</span>}
                </li>
              ))}
            </ul>
          )}
        </section>

        <section>
          <h3 className="modal-section-title">Recipes using it{branchId ? ` at ${branchName}` : ''}</h3>
          {recipes == null ? <p className="text-sm text-muted">Loading…</p> : recipes.length === 0 ? <p className="text-sm text-muted">None linked.</p> : (
            <ul className="history-list">
              {recipes.map(r => (
                <li key={r.id} className="text-sm">
                  {!branchId && <span className="text-muted">{branchNames[r.branch_id]}: </span>}
                  {r.category?.name} — {r.color?.name ?? r.variant_label} (v{r.version_number})
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </Modal>
  );
}

/** Next free '<category ref>_NN' product reference */
function nextProductRef(categoryRef, products) {
  const taken = new Set(products.map(p => p.product_id_ref));
  let n = products.filter(p => p.product_id_ref.startsWith(`${categoryRef}_`)).length + 1;
  let ref;
  do { ref = `${categoryRef}_${String(n++).padStart(2, '0')}`; } while (taken.has(ref));
  return ref;
}

const numOrNull = v => (String(v).trim() === '' ? null : Number(v));

function ProductModal({ product, organization, categories, units, products, branchId, branchName, onClose, onSaved }) {
  const isNew = !product.id;
  const [name,     setName]     = useState(product.canonical_name ?? '');
  const [category, setCategory] = useState(product.category_id ?? '');
  const [unitId,   setUnitId]   = useState(product.unit_id ?? '');
  const [size,     setSize]     = useState(product.size_cm ?? '');
  const [coverage, setCoverage] = useState(product.pcs_per_sqm ?? '');
  const [yieldPer, setYieldPer] = useState(product.wastani_per_bag ?? '');
  const [notes,    setNotes]    = useState(product.notes ?? '');
  const [merging,  setMerging]  = useState(false);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const recipeLinks = product.recipes?.[0]?.count ?? 0;

  const choosableCategories = categories.filter(c => c.status === 'active' || c.id === product.category_id);
  const choosableUnits = units.filter(u => u.status === 'active' || u.id === product.unit_id);

  function chooseCategory(id) {
    setCategory(id);
    // The category's default unit is only a suggestion for a new product
    const suggested = categories.find(c => c.id === id)?.default_unit_id;
    if (isNew && suggested && !unitId) setUnitId(suggested);
  }

  async function save(e) {
    e.preventDefault();
    setError('');
    const clash = products.find(p => p.id !== product.id && p.status === 'active'
      && p.category_id === category && sameName(p.canonical_name, name));
    if (clash) { setError(`"${clash.canonical_name}" already exists in this category.`); return; }
    for (const [label, v] of [['Pieces per m²', coverage], ['Yield per batch', yieldPer]]) {
      const n = numOrNull(v);
      if (n !== null && !(n > 0)) { setError(`${label} must be a positive number, or blank if not recorded.`); return; }
    }

    const row = {
      canonical_name: name.trim(), category_id: category, unit_id: unitId,
      size_cm: size.trim() || null, pcs_per_sqm: numOrNull(coverage), wastani_per_bag: numOrNull(yieldPer),
      notes: notes.trim() || null,
    };
    setBusy(true);
    const { data: created, error: err } = isNew
      ? await supabase.from('products').insert({
          ...row, organization_id: organization.id,
          product_id_ref: nextProductRef(categories.find(c => c.id === category).category_id_ref, products),
        }).select('id').single()
      : await supabase.from('products').update(row).eq('id', product.id).select('id').single();
    if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    // A new product goes straight into the picked branch's list
    if (isNew && branchId) {
      const { error: bpErr } = await supabase.from('branch_products')
        .insert({ organization_id: organization.id, branch_id: branchId, product_id: created.id });
      if (bpErr) { setBusy(false); setError(`Saved, but not added to ${branchName}'s list: ${dbErrorMessage(bpErr)}`); return; }
    }
    setBusy(false);
    onSaved();
  }

  async function toggleStatus() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('products')
      .update({ status: product.status === 'active' ? 'inactive' : 'active' }).eq('id', product.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Add product' : `Edit ${product.canonical_name}`} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="product-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`}
          disabled={busy || !name.trim() || !category || !unitId}>Save</button>
      </>}>
      <form id="product-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <div className="form-group">
          <label className="form-label" htmlFor="prod-name">Name</label>
          <input id="prod-name" className="form-input" required autoFocus value={name} onChange={e => setName(e.target.value)} />
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="prod-cat">Category</label>
            <select id="prod-cat" className="form-input" required value={category}
              disabled={!isNew && recipeLinks > 0} onChange={e => chooseCategory(e.target.value)}>
              <option value="" disabled>Choose…</option>
              {choosableCategories.map(c => <option key={c.id} value={c.id}>{c.name}{c.status !== 'active' ? ' (inactive)' : ''}</option>)}
            </select>
            {!isNew && recipeLinks > 0 && (
              <span className="form-hint">Linked to {recipeLinks} recipe{recipeLinks === 1 ? '' : 's'} of this category — unlink them under Recipes to move it.</span>
            )}
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="prod-unit">Stock unit</label>
            <select id="prod-unit" className="form-input" required value={unitId} onChange={e => setUnitId(e.target.value)}>
              <option value="" disabled>Choose…</option>
              {choosableUnits.map(u => <option key={u.id} value={u.id}>{u.symbol} — {u.name}</option>)}
            </select>
          </div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="prod-size">Size</label>
            <input id="prod-size" className="form-input" placeholder="e.g. 40x40" value={size} onChange={e => setSize(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="prod-cov">Pieces per m²</label>
            <input id="prod-cov" type="number" step="any" min="0" className="form-input" placeholder="Not recorded"
              value={coverage} onChange={e => setCoverage(e.target.value)} />
          </div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="prod-yield">Yield per batch</label>
            <input id="prod-yield" type="number" step="any" min="0" className="form-input" placeholder="Not recorded"
              value={yieldPer} onChange={e => setYieldPer(e.target.value)} />
            <span className="form-hint">Pieces from one batch of the recipe. Leave blank if unknown — never estimate.</span>
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="prod-notes">Notes</label>
            <textarea id="prod-notes" className="form-input" rows={2} value={notes} onChange={e => setNotes(e.target.value)} />
          </div>
        </div>

        {!isNew && (
          <section>
            <h3 className="modal-section-title">Status</h3>
            <p className="text-sm text-muted" style={{ marginBottom: 8 }}>
              {product.status === 'active'
                ? 'Deactivating hides it from new work. Its prices, recipes and history are kept.'
                : 'Inactive — kept for history, not offered for new work.'}
            </p>
            <div className="flex gap-8" style={{ flexWrap: 'wrap' }}>
              <button type="button" className="btn btn-outline" disabled={busy} onClick={toggleStatus}>
                {product.status === 'active' ? 'Deactivate product' : 'Reactivate product'}
              </button>
              {product.status === 'active' && !merging && (
                <button type="button" className="btn btn-outline" disabled={busy} onClick={() => setMerging(true)}>
                  Merge into another product…
                </button>
              )}
            </div>
          </section>
        )}
        {merging && (
          <MergePanel product={product} products={products} currencyCode={organization.currency_code}
            onCancel={() => setMerging(false)} onMerged={() => onSaved()} />
        )}
        {!isNew && <EntityFlags entityType="product" entityId={product.id} canResolve canRaise onChanged={() => onSaved(false)} />}
        {!isNew && <EntityHistory entityType="product" entityId={product.id} />}
      </form>
    </Modal>
  );
}

/**
 * Merge a duplicate into the product that stays: the duplicate is
 * deactivated (never deleted) and its open flags are resolved with a note
 * naming the survivor. Prices are not copied — the comparison shows where
 * they differ so the admin can correct the survivor's prices deliberately.
 */
function MergePanel({ product, products, currencyCode, onCancel, onMerged }) {
  const { session, organization, profile } = useAuth();
  const me = [profile?.first_name, profile?.last_name].filter(Boolean).join(' ') || session?.user?.email || 'a user';
  const candidates = products
    .filter(p => p.id !== product.id && p.status === 'active' && p.category_id === product.category_id)
    .sort((a, b) => a.canonical_name.localeCompare(b.canonical_name));
  const [targetId, setTargetId] = useState('');
  const [prices,   setPrices]   = useState(null);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const target = candidates.find(p => p.id === targetId);

  useEffect(() => {
    if (!targetId) { setPrices(null); return; }
    supabase
      .from('product_branch_pricing')
      .select('product_id, branch_id, color_id, price_per_unit_inclusive, price_per_sqm_inclusive, branch:branches(name), color:color_palette(name)')
      .in('product_id', [product.id, targetId])
      .then(({ data, error: err }) => {
        if (err) { console.error(err); setPrices([]); return; }
        const rows = {};
        for (const r of data || []) {
          const key = `${r.branch_id}|${r.color_id ?? ''}`;
          rows[key] ??= { label: [r.branch?.name, r.color?.name].filter(Boolean).join(' · ') };
          rows[key][r.product_id === product.id ? 'dup' : 'keep'] = r.price_per_sqm_inclusive ?? r.price_per_unit_inclusive;
        }
        setPrices(Object.values(rows).sort((a, b) => a.label.localeCompare(b.label)));
      });
  }, [product.id, targetId]);

  const differences = useMemo(() => (prices || []).filter(r => r.dup !== r.keep).length, [prices]);

  async function merge() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('products').update({ status: 'inactive' }).eq('id', product.id);
    if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    const { error: flagErr } = await supabase.from('review_flags').update({
      status: 'resolved',
      resolved_at: new Date().toISOString(),
      resolved_by: session?.user?.id ?? null,
      resolution_note: `Merged into ${target.canonical_name}; this product was retired.`,
    }).eq('entity_type', 'product').eq('entity_id', product.id).eq('status', 'open');
    setBusy(false);
    if (flagErr) { setError(`Deactivated, but its flags could not be closed: ${dbErrorMessage(flagErr)}`); return; }
    // The merge answers "is X the same as Y" for good (migration 026). If the
    // name already has an answer (e.g. an import placeholder), correct it.
    const evidence = `Merged into ${target.canonical_name} in the Products screen`;
    const { data: existing } = await supabase.from('identity_decisions').select('id, product_id')
      .eq('subject_type', 'product').eq('status', 'active').eq('context_normalized', '')
      .eq('term_normalized', product.canonical_name.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ''))
      .in('decision', ['same_as', 'new_record']).maybeSingle();
    if (existing && existing.product_id !== target.id) {
      const { error: corrErr } = await supabase.rpc('correct_identity_decision',
        { p_id: existing.id, p_new: { decision: 'same_as', product_id: target.id }, p_evidence: evidence });
      if (corrErr) { setError(`Merged, but the decision could not be updated: ${dbErrorMessage(corrErr)}`); return; }
      onMerged();
      return;
    }
    const { error: decErr } = existing ? { error: null } : await supabase.from('identity_decisions').insert({
      organization_id: organization.id, subject_type: 'product', term: product.canonical_name, context: '',
      decision: 'same_as', product_id: target.id, source: 'merge',
      evidence,
      decided_by: session?.user?.id, decided_by_label: me,
    });
    if (decErr && decErr.code !== '23505') { setError(`Merged, but the decision could not be recorded: ${dbErrorMessage(decErr)}`); return; }
    onMerged();
  }

  return (
    <section className="modal-subform">
      <h3 className="modal-section-title">Merge {product.canonical_name} into…</h3>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {candidates.length === 0 ? (
        <p className="text-sm text-muted">No other active product in this category to merge into.</p>
      ) : (
        <select className="form-input" aria-label="Product that stays" value={targetId} onChange={e => setTargetId(e.target.value)}>
          <option value="">Choose the product that stays…</option>
          {candidates.map(p => <option key={p.id} value={p.id}>{p.canonical_name}{p.size_cm ? ` (${p.size_cm})` : ''}</option>)}
        </select>
      )}
      {target && prices && (
        <>
          {prices.length === 0 ? (
            <p className="text-sm text-muted">Neither product has prices.</p>
          ) : (
            <div className="table-container">
              <table>
                <thead><tr><th>Price</th><th>{product.canonical_name}</th><th>{target.canonical_name} (stays)</th></tr></thead>
                <tbody>
                  {prices.map(r => (
                    <tr key={r.label}>
                      <td>{r.label}</td>
                      <td>{formatMoney(r.dup, currencyCode)}</td>
                      <td style={r.dup !== r.keep ? { fontWeight: 600 } : undefined}>{formatMoney(r.keep, currencyCode)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <p className="text-sm text-muted">
            {product.canonical_name} will be deactivated and its open flags resolved; its prices and history are kept.
            {differences > 0 && ` ${differences} price${differences === 1 ? ' differs' : 's differ'} — correct ${target.canonical_name}'s prices under Pricing if needed.`}
          </p>
        </>
      )}
      <div className="flex gap-8">
        <button type="button" className="btn btn-primary" disabled={busy || !target} onClick={merge}>Merge</button>
        <button type="button" className="btn btn-ghost" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </section>
  );
}
