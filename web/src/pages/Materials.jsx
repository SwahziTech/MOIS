import { useEffect, useMemo, useState } from 'react';
import { Layers, Plus, Search, Flag, Trash2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { loadInventoryRefs, qtyText } from '../lib/inventory';
import { formatMoney } from '../lib/format';
import MovementModal from '../components/inventory/MovementModal';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage, slugify } from '../lib/masterData';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityFlags, EntityHistory } from '../components/master/EntityPanels';
import NumberInput from '../components/NumberInput';

const LOAD_ERROR = "We couldn't load this page. Please try again.";
const numOrNull = v => (String(v ?? '').trim() === '' ? null : Number(v));

/*
 * Materials master (migration 019): category, stock unit, unit conversions.
 * A material is shared by every branch, or is one branch's own (a local
 * input only it uses — migration 032): that branch edits and uses it until
 * an org admin makes it shared. Suppliers are recorded on each purchase,
 * never fixed on a material (031); old fixed sources show as history.
 */
export default function Materials() {
  const { organization, canManage, canAt, can } = useAuth();
  const { branchId, inBranch } = useBranch();
  const canWriteMaterials = canManage('materials.manage');
  // Shared materials: org-wide admins. A branch's own: that branch's managers.
  // shared materials: anyone with materials.manage — org admins and branch managers (050); sharing one stays with org admins
  const canEditMaterial = m => (m.branch_id ? canAt('materials.manage', m.branch_id, null) : can('materials.manage'));
  const canAddMaterial = canWriteMaterials || (!!branchId && canAt('materials.manage', branchId, null));
  const canWriteUnits = canManage('materials.manage') || canManage('products.manage');

  const [tab, setTab] = useState('materials');
  const [materials,  setMaterials]  = useState([]);
  const [categories, setCategories] = useState([]);
  const [units,      setUnits]      = useState([]);
  const [allBranches, setBranches]  = useState([]);
  // The branch picked in the sidebar ('' = all)
  const branches = allBranches.filter(b => inBranch(b.id));
  const [suppliers,  setSuppliers]  = useState([]);
  const [usage,      setUsage]      = useState({});   // material id → { active, any }
  const [unitUse,    setUnitUse]    = useState({});   // unit id → count of uses
  const [openFlags,  setOpenFlags]  = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [filter,  setFilter]  = useState('active');
  const [categoryId, setCategoryId] = useState('');
  const [sortBy,     setSortBy]     = useState('category');   // category (the agreed material order) | name_asc | name_desc
  const [editing, setEditing] = useState(null);       // { kind: 'material'|'category'|'unit', row }
  // On hand, value and baseline for the picked branch (2026-10-23 layout)
  const [onHand,   setOnHand]   = useState({});   // material id → quantity in the branch's raw stores
  const [avgCost,  setAvgCost]  = useState({});   // material id → average cost per stock unit at the branch
  const [lastFrom, setLastFrom] = useState({});   // material id → supplier last bought from
  const [opened,   setOpened]   = useState({});   // material id → has an opening balance at the branch
  const [refs,     setRefs]     = useState(null); // for receiving from a card
  const [posting,  setPosting]  = useState(null); // { type, key }

  async function load() {
    setError('');
    const [matRes, catRes, unitRes, branchRes, itemRes, flagRes, prodRes, supRes] = await Promise.all([
      supabase.from('materials').select(`
          id, name, material_id_ref, category_id, stock_unit_id, status, notes, branch_id,
          conversions:material_unit_conversions(unit_id, factor_to_stock_unit, notes),
          sources:material_branch_sources(id, branch_id, source_name, purchase_unit_id, supplier_id, is_primary, status, notes)
        `).order('name'),
      supabase.from('material_categories').select('*').order('display_order').order('name'),
      supabase.from('units').select('id, symbol, name, notes, status').order('symbol'),
      supabase.from('branches').select('id, name, status').order('name'),
      supabase.from('recipe_items').select('material_id, unit_id, recipe:recipe_versions(status)'),
      supabase.from('review_flags').select('entity_id').eq('entity_type', 'material').eq('status', 'open'),
      supabase.from('products').select('unit_id'),
      supabase.from('suppliers').select('id, name, status').order('name'),
    ]);
    const err = matRes.error || catRes.error || unitRes.error || branchRes.error || itemRes.error || flagRes.error || prodRes.error || supRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }

    const use = {};
    const uUse = {};
    const bump = id => { if (id) uUse[id] = (uUse[id] || 0) + 1; };
    for (const it of itemRes.data || []) {
      const u = (use[it.material_id] ??= { active: 0, any: 0 });
      u.any++;
      if (it.recipe?.status === 'active') u.active++;
      bump(it.unit_id);
    }
    for (const m of matRes.data || []) {
      bump(m.stock_unit_id);
      m.conversions.forEach(c => bump(c.unit_id));
      m.sources.forEach(s => bump(s.purchase_unit_id));
    }
    (prodRes.data || []).forEach(p => bump(p.unit_id));
    const flags = {};
    for (const f of flagRes.data || []) flags[f.entity_id] = (flags[f.entity_id] || 0) + 1;

    setMaterials(matRes.data || []);
    setCategories(catRes.data || []);
    setUnits(unitRes.data || []);
    setBranches((branchRes.data || []).filter(b => b.status === 'active'));
    setSuppliers(supRes.data || []);
    setUsage(use);
    setUnitUse(uUse);
    setOpenFlags(flags);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  async function loadStock() {
    const [wh, bal, op, pl] = await Promise.all([
      supabase.from('warehouses').select('id, branch_id, type, status'),
      supabase.from('stock_balances').select('warehouse_id, material_id, quantity').not('material_id', 'is', null),
      supabase.from('inventory_transactions').select('material_id, warehouse_id').eq('transaction_type', 'opening_balance').not('material_id', 'is', null),
      supabase.from('purchase_line_costs').select('material_id, branch_id, supplier_id, purchase_date').order('purchase_date', { ascending: false }),
    ]);
    const raw = new Set((wh.data || []).filter(w => w.type !== 'finished_goods' && w.type !== 'wip' && inBranch(w.branch_id)).map(w => w.id));
    const q = {};
    for (const b of bal.data || []) if (raw.has(b.warehouse_id)) q[b.material_id] = (q[b.material_id] ?? 0) + Number(b.quantity);
    setOnHand(q);
    const o = {};
    for (const t of op.data || []) if (raw.has(t.warehouse_id)) o[t.material_id] = true;
    setOpened(o);
    const last = {};
    for (const l of pl.data || []) if (inBranch(l.branch_id) && !last[l.material_id]) last[l.material_id] = l.supplier_id;
    setLastFrom(last);
    // average cost needs one branch (moving average per branch, 035)
    if (!branchId) { setAvgCost({}); return; }
    const ids = Object.keys(q);
    const costs = await Promise.all(ids.map(id => supabase.rpc('material_average_cost', { p_branch_id: branchId, p_material_id: id })));
    setAvgCost(Object.fromEntries(ids.map((id, i) => [id, costs[i].data?.[0]?.average_cost ?? costs[i].data?.[0]?.last_purchase_cost ?? null])));
  }
  useEffect(() => { loadStock(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  async function intake(type, key) {
    const rf = refs ?? await loadInventoryRefs().catch(() => null);
    if (!rf) return;
    setRefs(rf);
    // into the branch's raw-materials store
    const wh = rf.warehouses.find(w => w.status === 'active' && w.type === 'raw_materials' && (!branchId || w.branch_id === branchId));
    setPosting({ type, key, wh: wh?.id ?? '' });
  }

  const unitById = useMemo(() => Object.fromEntries(units.map(u => [u.id, u])), [units]);
  const catById = useMemo(() => Object.fromEntries(categories.map(c => [c.id, c])), [categories]);
  const q = search.trim().toLowerCase();
  const branchName = id => allBranches.find(b => b.id === id)?.name ?? '—';
  const shown = materials.filter(m =>
    (!m.branch_id || inBranch(m.branch_id)) &&
    (!categoryId || (categoryId === 'none' ? !m.category_id : m.category_id === categoryId)) &&
    (filter === 'all' || (filter === 'review' ? openFlags[m.id] : m.status === filter)) &&
    (!q || m.name.toLowerCase().includes(q) || (m.material_id_ref || '').toLowerCase().includes(q)));
  // Counts from the materials in view: shared + the picked branch's own (032)
  const inViewMaterials = materials.filter(m => !m.branch_id || inBranch(m.branch_id));
  const catOrder = Object.fromEntries(categories.map(c => [c.id, [c.display_order, c.name]]));
  const sortedShown = [...shown].sort((a, b) => {
    if (sortBy === 'name_desc') return b.name.localeCompare(a.name);
    if (sortBy === 'category') {
      const x = catOrder[a.category_id] ?? [1e9, ''], y = catOrder[b.category_id] ?? [1e9, ''];
      return x[0] - y[0] || x[1].localeCompare(y[1]) || a.name.localeCompare(b.name);
    }
    return a.name.localeCompare(b.name);   // name_asc
  });
  const reviewCount = inViewMaterials.filter(m => openFlags[m.id]).length;

  const canAdd = tab === 'units' ? canWriteUnits : tab === 'materials' ? canAddMaterial : canWriteMaterials;
  const close = () => setEditing(null);
  const saved = async () => { setEditing(null); await load(); };

  const money = v => formatMoney(v, organization?.currency_code);
  const valueOf = m => (onHand[m.id] != null && avgCost[m.id] != null ? onHand[m.id] * avgCost[m.id] : null);
  const total = inViewMaterials.filter(m => m.status === 'active').reduce((n, m) => n + (valueOf(m) ?? 0), 0);
  const uncosted = inViewMaterials.filter(m => m.status === 'active' && (onHand[m.id] ?? 0) > 0 && avgCost[m.id] == null).length;
  const out = inViewMaterials.filter(m => m.status === 'active' && !((onHand[m.id] ?? 0) > 0));
  const noOpening = inViewMaterials.filter(m => m.status === 'active' && !opened[m.id]);
  const altQty = m => {
    const c = [...m.conversions].sort((x, y) => Math.abs(Math.log(y.factor_to_stock_unit)) - Math.abs(Math.log(x.factor_to_stock_unit)))[0];   // the same unit as the conversion shown
    return c && onHand[m.id] ? `${qtyText(Math.round((onHand[m.id] / Number(c.factor_to_stock_unit)) * 100) / 100)} ${unitById[c.unit_id]?.symbol}` : null;
  };

  return (
    <PageShell
      title="Materials"
      subtitle="Master Data"
      description="Raw materials, the units they're counted and bought in, and which branch uses them."
      primaryAction={canAdd && (
        <button type="button" className="btn btn-primary"
          onClick={() => setEditing({ kind: { materials: 'material', categories: 'category', units: 'unit' }[tab], row: {} })}>
          <Plus size={14} /> {{ materials: 'New Material', categories: 'New Category', units: 'New Unit' }[tab]}
        </button>
      )}
    >
      {tab === 'materials' && !error && (
        <>
          <div className="mm-stats">
            <div className="mm-stat"><span className="pl-label">Materials</span><strong>{inViewMaterials.filter(m => m.status === 'active').length} items</strong></div>
            <div className="mm-stat"><span className="pl-label">Stock value</span><strong className="mm-money">{branchId ? money(total) : '—'}</strong>
              <span className="pl-help">{branchId ? (uncosted ? `${uncosted} without a purchase price` : 'at average purchase cost') : 'Pick a branch'}</span></div>
            <div className="mm-stat"><span className="pl-label">Out of stock</span><strong className={out.length ? 'text-error' : ''}>{out.length}</strong></div>
            <div className="mm-stat"><span className="pl-label">Opening stock</span><strong className={noOpening.length ? 'text-warning' : ''}>{noOpening.length ? `${noOpening.length} not set` : 'All set'}</strong></div>
          </div>
          {noOpening.length > 0 && (
            <div className="mm-banner">
              <span><strong>Opening stock not set:</strong> <span className="pl-help">{noOpening.map(m => m.name).join(', ')}</span></span>
              {canAt('inventory.adjust', branchId || null, null) && <button type="button" className="btn btn-primary btn-sm" onClick={() => intake('opening_balance', `m:${noOpening[0].id}`)}>Set opening stock</button>}
            </div>
          )}
        </>
      )}
      <PageTabs value={tab} onChange={setTab}
        tabs={[['materials', 'Materials'], ['categories', 'Material categories'], ['units', 'Units']]} />
      {tab === 'materials' && (
        <>
          <ListToolbar id="materials-search" search={search} onSearch={setSearch} placeholder="Search materials…"
            sort={{ value: sortBy, onChange: setSortBy, options: [
              { value: 'category',  label: 'Material order (default)' },
              { value: 'name_asc',  label: 'Name: A → Z' },
              { value: 'name_desc', label: 'Name: Z → A' },
            ] }}
            filters={[{ key: 'status', label: 'Status', value: filter, onChange: setFilter, options: [
              { value: 'active', label: 'Active' }, { value: 'review', label: `Needs review (${reviewCount})` },
              { value: 'inactive', label: 'Inactive' }, { value: 'all', label: 'All' }] }]} />
          {!loading && (
            <ChipRow value={categoryId} onChange={setCategoryId}
              items={[...categories.filter(c => c.status === 'active' || inViewMaterials.some(m => m.category_id === c.id)).map(c => ({ id: c.id, label: `${c.name} (${inViewMaterials.filter(m => m.category_id === c.id && m.status === 'active').length})` })),
                      ...(inViewMaterials.some(m => !m.category_id) ? [{ id: 'none', label: 'No category' }] : [])]} />
          )}
        </>
      )}

      {tab === 'materials' && (error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (() => {
        return (
          <>
            <section className="sk">
              <div className="sk-head"><span>{categoryId ? catById[categoryId]?.name ?? 'No category' : 'All materials'} ({sortedShown.length})</span></div>
              {loading ? Array.from({ length: 5 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
              : sortedShown.length === 0 ? <div className="card"><EmptyState icon={Layers} title="No materials in this view" description={search ? `No materials match "${search}".` : ''} /></div>
              : sortedShown.map((m, i) => {
                const st = unitById[m.stock_unit_id]?.symbol ?? '';
                const v = valueOf(m);
                const sup = suppliers.find(x => x.id === lastFrom[m.id])?.name;
                return (
                  <div key={m.id} className={`mm-card${m.status !== 'active' ? ' is-inactive' : ''}`} title="Open for its units, conversions and sources"
                    onClick={e => { if (!e.target.closest('button')) setEditing({ kind: 'material', row: m }); }}>
                    <div className="mm-top">
                      <span className="mm-n">#{i + 1}</span>
                      {catById[m.category_id] && <span className="pl-tag">{catById[m.category_id].name}</span>}
                      <strong className="mm-name">{m.name}</strong>
                      {sup && <span className="pl-help">· last from {sup}</span>}
                      {m.branch_id && <span className="badge badge-accent">{branchName(m.branch_id)} only</span>}
                      {openFlags[m.id] > 0 && <span className="badge badge-warning"><Flag size={11} /> needs review</span>}
                      {m.status !== 'active' && <span className="pl-tag">inactive</span>}
                    </div>
                    <div className="mm-bottom">
                      <span className="mm-qty"><strong className={(onHand[m.id] ?? 0) < 0 ? 'text-error' : ''}>{qtyText(Math.round((onHand[m.id] ?? 0) * 100) / 100)} {st}</strong>
                        {altQty(m) && <span className="sk-sub"> ({altQty(m)})</span>}</span>
                    </div>
                    {branchId && (
                      <span className="mm-value">
                        <span>Value: <strong className="mm-money">{v != null ? money(v) : '—'}</strong></span>
                        {avgCost[m.id] != null && <span className="pl-help">@ {money(avgCost[m.id])}/{st}</span>}
                      </span>
                    )}
                    <span className="mm-actions">
                      {canEditMaterial(m) && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing({ kind: 'material', row: m })}>Edit</button>}
                      {m.status === 'active' && canAt('inventory.receive', branchId || null, null) && (
                        <button type="button" className="btn btn-primary btn-sm" onClick={() => intake('receipt', `m:${m.id}`)}>Intake {st}</button>
                      )}
                    </span>
                  </div>
                );
              })}
            </section>
          </>
        );
      })())}

      {tab !== 'materials' && <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            {tab === 'categories' && (
              <table>
                <thead><tr><th>Category</th><th>Order</th><th>Materials</th><th>Status</th>{canWriteMaterials && <th aria-label="Actions" />}</tr></thead>
                <tbody>
                  {loading ? <SkeletonRow cols={5} /> : categories.length === 0 ? (
                    <tr><td colSpan={5}><EmptyState icon={Layers} title="No material categories yet" description="Group materials, e.g. aggregates or pigments." /></td></tr>
                  ) : categories.map(c => (
                    <tr key={c.id}>
                      <td style={{ fontWeight: 500 }}>{c.name}{c.used_in_recipes === false && <span className="badge badge-neutral" style={{ marginLeft: 6 }}>Not in recipes</span>}</td>
                      <td className="text-muted">{c.display_order}</td>
                      <td className="text-muted">{inViewMaterials.filter(m => m.category_id === c.id && m.status === 'active').length}</td>
                      <td><span className={`badge ${c.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{c.status}</span></td>
                      {canWriteMaterials && <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing({ kind: 'category', row: c })}>Edit</button></td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            {tab === 'units' && (
              <table>
                <thead><tr><th>Symbol</th><th>Name</th><th>Notes</th><th title="Units are shared by every branch">In use (all branches)</th><th>Status</th>{canWriteUnits && <th aria-label="Actions" />}</tr></thead>
                <tbody>
                  {loading ? <SkeletonRow cols={6} /> : units.map(u => (
                    <tr key={u.id}>
                      <td style={{ fontWeight: 500 }}>{u.symbol}</td>
                      <td>{u.name}</td>
                      <td className="text-xs text-muted">{u.notes || '—'}</td>
                      <td className="text-muted">{unitUse[u.id] ? `${unitUse[u.id]}×` : '—'}</td>
                      <td><span className={`badge ${u.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{u.status}</span></td>
                      {canWriteUnits && <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing({ kind: 'unit', row: u })}>Edit</button></td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        )}
      </div>}

      {posting && refs && (
        <MovementModal type={posting.type} refs={refs} balances={{}} defaultItemKey={posting.key} defaultWarehouseId={posting.wh}
          onClose={() => setPosting(null)} onPosted={async () => { setPosting(null); await loadStock(); }} />
      )}

      {editing?.kind === 'material' && (
        <MaterialModal material={materials.find(m => m.id === editing.row.id) ?? editing.row} organizationId={organization.id} materials={materials}
          categories={categories} units={units} branches={allBranches} suppliers={suppliers} usage={usage[editing.row.id] ?? { active: 0, any: 0 }} key={editing.row.id ?? 'new'}
          canShare={canWriteMaterials} ownBranchChoices={allBranches.filter(b => canAt('materials.manage', b.id, null))} defaultBranchId={canWriteMaterials ? '' : branchId}
          onClose={close} onSaved={saved} onChanged={load} />
      )}
      {editing?.kind === 'category' && (
        <SimpleModal title="material category" table="material_categories" entityType="material_category"
          row={editing.row} organizationId={organization.id}
          fields={[{ key: 'name', label: 'Name', required: true }, { key: 'display_order', label: 'Display order', type: 'number', default: Math.max(0, ...categories.map(c => c.display_order)) + 1 },
            ...('used_in_recipes' in (editing.row.id ? editing.row : (categories[0] ?? {})) ? [{ key: 'used_in_recipes', label: 'Used in recipes (a mix ingredient)', type: 'checkbox', default: true }] : [])]}
          inactiveNote="Inactive — not offered when choosing a category. Materials already in it keep it."
          onClose={close} onSaved={saved} />
      )}
      {editing?.kind === 'unit' && (
        <SimpleModal title="unit" table="units" entityType="unit" row={editing.row} organizationId={organization.id}
          fields={[{ key: 'symbol', label: 'Symbol', required: true }, { key: 'name', label: 'Name', required: true }, { key: 'notes', label: 'Notes' }]}
          inactiveNote={`Inactive — not offered for new choices.${unitUse[editing.row.id] ? ` Everything already using it (${unitUse[editing.row.id]}×) keeps it.` : ''}`}
          onClose={close} onSaved={saved} />
      )}
    </PageShell>
  );
}

/** Name-style master records with a status column: material categories, units */
function SimpleModal({ title, table, entityType, row, organizationId, fields, inactiveNote, onClose, onSaved }) {
  const isNew = !row.id;
  const [values, setValues] = useState(Object.fromEntries(fields.map(f => [f.key, row[f.key] ?? f.default ?? ''])));
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  async function save(e) {
    e.preventDefault();
    setError('');
    const out = Object.fromEntries(fields.map(f => [f.key,
      f.type === 'checkbox' ? !!values[f.key] : f.type === 'number' ? Number(values[f.key]) || 0 : (String(values[f.key]).trim() || null)]));
    setBusy(true);
    const { error: err } = isNew
      ? await supabase.from(table).insert({ ...out, organization_id: organizationId })
      : await supabase.from(table).update(out).eq('id', row.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  async function toggle() {
    setBusy(true);
    const { error: err } = await supabase.from(table).update({ status: row.status === 'active' ? 'inactive' : 'active' }).eq('id', row.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? `Add ${title}` : `Edit ${row.name || row.symbol}`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="simple-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`}
          disabled={busy || fields.some(f => f.required && !String(values[f.key] ?? '').trim())}>Save</button>
      </>}>
      <form id="simple-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        {fields.map((f, i) => f.type === 'checkbox' ? (
          <label key={f.key} className="text-sm flex items-center gap-8">
            <input type="checkbox" checked={!!values[f.key]} onChange={e => setValues(v => ({ ...v, [f.key]: e.target.checked }))} /> {f.label}
          </label>
        ) : (
          <div key={f.key} className="form-group">
            <label className="form-label" htmlFor={`sf-${f.key}`}>{f.label}</label>
            <input id={`sf-${f.key}`} className="form-input" type={f.type || 'text'} required={f.required} autoFocus={i === 0}
              value={values[f.key]} onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))} />
          </div>
        ))}
        {!isNew && (
          <section>
            <h3 className="modal-section-title">Status</h3>
            <p className="text-sm text-muted" style={{ marginBottom: 8 }}>{row.status === 'active' ? 'Deactivating hides it from new choices.' : inactiveNote}</p>
            <button type="button" className="btn btn-outline" disabled={busy} onClick={toggle}>
              {row.status === 'active' ? 'Deactivate' : 'Reactivate'}
            </button>
          </section>
        )}
        {!isNew && <EntityHistory entityType={entityType} entityId={row.id} />}
      </form>
    </Modal>
  );
}

function uniqueRef(name, taken) {
  const base = slugify(name);
  let ref = base;
  for (let i = 2; taken.has(ref); i++) ref = `${base}_${i}`;
  return ref;
}

function MaterialModal({ material, organizationId, materials, categories, units, branches, suppliers, usage, canShare, ownBranchChoices, defaultBranchId, onClose, onSaved, onChanged }) {
  const isNew = !material.id;
  // '' = shared by every branch; otherwise the one branch that uses it
  const [scope, setScope] = useState(isNew ? (defaultBranchId || (canShare ? '' : ownBranchChoices[0]?.id ?? '')) : material.branch_id ?? '');
  const [name,     setName]     = useState(material.name ?? '');
  const [category, setCategory] = useState(material.category_id ?? '');
  const [stockId,  setStockId]  = useState(material.stock_unit_id ?? '');
  const [notes,    setNotes]    = useState(material.notes ?? '');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  const unitById = Object.fromEntries(units.map(u => [u.id, u]));
  const conversions = material.conversions ?? [];
  const sources = material.sources ?? [];
  // 021: the stock unit is fixed once anything is expressed relative to it
  const stockLocked = !!material.stock_unit_id && (conversions.length > 0 || sources.length > 0 || usage.any > 0);
  const branchName = id => branches.find(b => b.id === id)?.name ?? '—';
  const activeUnits = units.filter(u => u.status === 'active' || u.id === material.stock_unit_id);
  const choosableCategories = categories.filter(c => c.status === 'active' || c.id === material.category_id);

  async function save(e) {
    e.preventDefault();
    setError('');
    const clash = materials.find(m => m.id !== material.id && m.name.trim().toLowerCase() === name.trim().toLowerCase());
    if (clash) { setError(`A material called "${clash.name}" already exists.`); return; }
    const row = { name: name.trim(), category_id: category || null, stock_unit_id: stockId || null, notes: notes.trim() || null };
    setBusy(true);
    const { error: err } = isNew
      ? await supabase.from('materials').insert({
          ...row, organization_id: organizationId, status: 'active', branch_id: scope || null,
          material_id_ref: uniqueRef(row.name, new Set(materials.map(m => m.material_id_ref).filter(Boolean))),
        })
      : await supabase.from('materials').update(row).eq('id', material.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  async function makeShared() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('materials').update({ branch_id: null }).eq('id', material.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  async function toggleStatus() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('materials')
      .update({ status: material.status === 'active' ? 'inactive' : 'active' }).eq('id', material.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Add material' : `Edit ${material.name}`} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
        <button type="submit" form="material-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !name.trim()}>
          {isNew ? 'Add material' : 'Save details'}
        </button>
      </>}>
      <form id="material-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        {!isNew && <p className="text-xs text-muted" style={{ fontFamily: 'monospace' }}>{material.material_id_ref}</p>}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="mat-name">Name</label>
            <input id="mat-name" className="form-input" required autoFocus value={name} onChange={e => setName(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="mat-cat">Category</label>
            <select id="mat-cat" className="form-input" value={category} onChange={e => setCategory(e.target.value)}>
              <option value="">None</option>
              {choosableCategories.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </div>
        </div>
        {isNew ? (
          <div className="form-group">
            <label className="form-label" htmlFor="mat-scope">Used by</label>
            <select id="mat-scope" className="form-input" value={scope} onChange={e => setScope(e.target.value)}>
              {canShare && <option value="">All branches (shared)</option>}
              {ownBranchChoices.map(b => <option key={b.id} value={b.id}>{b.name} only</option>)}
            </select>
            <span className="form-hint">A branch's own material is for a local input only that branch uses. An org admin can make it shared later.</span>
          </div>
        ) : material.branch_id && (
          <p className="text-sm">
            <span className="badge badge-accent">{branchName(material.branch_id)} only</span>{' '}
            <span className="text-muted">Only {branchName(material.branch_id)} edits and uses it.</span>
            {canShare && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={makeShared}>Make shared with all branches</button>}
          </p>
        )}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="mat-stock">Stock unit</label>
            <select id="mat-stock" className="form-input" value={stockId} disabled={stockLocked} onChange={e => setStockId(e.target.value)}>
              <option value="">Not set yet</option>
              {activeUnits.map(u => <option key={u.id} value={u.id}>{u.symbol} — {u.name}</option>)}
            </select>
            <span className="form-hint">
              {stockLocked ? 'Fixed: conversions, sources or recipes are expressed in it.' : 'The unit stock of this material is counted in. Add a unit under Units if it is missing.'}
            </span>
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="mat-notes">Notes</label>
            <textarea id="mat-notes" className="form-input" rows={2} value={notes} onChange={e => setNotes(e.target.value)} />
          </div>
        </div>
      </form>

      {!isNew && (
        <div className="modal-form mt-16">
          <ConversionsEditor material={material} organizationId={organizationId} units={activeUnits} unitById={unitById} onChanged={onChanged} />
          <FormerSources material={material} branches={branches} suppliers={suppliers} unitById={unitById} />
          <section>
            <h3 className="modal-section-title">Status</h3>
            {material.status === 'active' && usage.active > 0 ? (
              <p className="text-sm text-muted">Used by {usage.active} active recipe line{usage.active === 1 ? '' : 's'}. Save those recipes without it before deactivating.</p>
            ) : (
              <>
                <p className="text-sm text-muted" style={{ marginBottom: 8 }}>
                  {material.status === 'active' ? 'Deactivating hides it from new recipes and sources. History is kept.' : 'Inactive — kept for history, not offered for new recipes.'}
                </p>
                <button type="button" className="btn btn-outline" disabled={busy} onClick={toggleStatus}>
                  {material.status === 'active' ? 'Deactivate material' : 'Reactivate material'}
                </button>
              </>
            )}
          </section>
          <EntityFlags entityType="material" entityId={material.id} canResolve canRaise onChanged={onChanged} />
          <EntityHistory entityType="material" entityId={material.id} />
        </div>
      )}
    </Modal>
  );
}

/** 1 <unit> = factor × stock unit. Saved one line at a time. */
function ConversionsEditor({ material, organizationId, units, unitById, onChanged }) {
  const stock = unitById[material.stock_unit_id];
  const [rows, setRows] = useState((material.conversions ?? []).map(c => ({ ...c, factor: String(c.factor_to_stock_unit), saved: true })));
  const [busy,  setBusy]  = useState(null);
  const [error, setError] = useState('');
  const used = new Set([material.stock_unit_id, ...rows.map(r => r.unit_id)]);

  async function saveRow(i) {
    const r = rows[i];
    setError('');
    const f = numOrNull(r.factor);
    if (!r.unit_id) { setError('Choose a unit.'); return; }
    if (!(f > 0)) { setError('The factor must be a number above zero.'); return; }
    setBusy(i);
    const { error: err } = await supabase.from('material_unit_conversions').upsert(
      { organization_id: organizationId, material_id: material.id, unit_id: r.unit_id, factor_to_stock_unit: f, notes: r.notes?.trim() || null },
      { onConflict: 'material_id,unit_id' });
    setBusy(null);
    if (err) { setError(dbErrorMessage(err)); return; }
    setRows(rs => rs.map((x, j) => (j === i ? { ...x, factor_to_stock_unit: f, saved: true } : x)));
    onChanged();
  }

  async function removeRow(i) {
    const r = rows[i];
    setError('');
    if (!r.saved) { setRows(rs => rs.filter((_, j) => j !== i)); return; }
    setBusy(i);
    const { error: err } = await supabase.from('material_unit_conversions').delete()
      .eq('material_id', material.id).eq('unit_id', r.unit_id);
    setBusy(null);
    if (err) { setError(dbErrorMessage(err)); return; }
    setRows(rs => rs.filter((_, j) => j !== i));
    onChanged();
  }

  return (
    <section className="entity-panel">
      <h3 className="modal-section-title">Also counted in</h3>
      {!stock ? (
        <p className="text-sm text-muted">Set the stock unit first — conversions are expressed in it.</p>
      ) : (
        <>
          {error && <div className="alert alert-error" role="alert">{error}</div>}
          <div className="ingredient-list">
            {rows.map((r, i) => {
              const dirty = !r.saved || Number(r.factor) !== Number(r.factor_to_stock_unit);
              return (
                <div key={r.saved ? r.unit_id : `new-${i}`} className="conversion-row">
                  <span className="text-sm">1</span>
                  <select className="form-input" aria-label="Unit" value={r.unit_id} disabled={r.saved}
                    onChange={e => setRows(rs => rs.map((x, j) => (j === i ? { ...x, unit_id: e.target.value } : x)))}>
                    <option value="" disabled>Unit…</option>
                    {(r.saved ? [unitById[r.unit_id]] : units.filter(u => !used.has(u.id) || u.id === r.unit_id)).filter(Boolean)
                      .map(u => <option key={u.id} value={u.id}>{u.symbol}</option>)}
                  </select>
                  <span className="text-sm">=</span>
                  <NumberInput step="any" min="0" className="form-input" aria-label="Factor" value={r.factor}
                    onChange={e => setRows(rs => rs.map((x, j) => (j === i ? { ...x, factor: e.target.value } : x)))} />
                  <span className="text-sm">{stock.symbol}</span>
                  {dirty
                    ? <button type="button" className="btn btn-outline btn-sm" disabled={busy === i} onClick={() => saveRow(i)}>Save</button>
                    : <span />}
                  <button type="button" className="icon-btn" aria-label="Remove conversion" disabled={busy === i} onClick={() => removeRow(i)}>
                    <Trash2 size={14} />
                  </button>
                </div>
              );
            })}
          </div>
          <button type="button" className="btn btn-ghost btn-sm mt-8"
            onClick={() => setRows(rs => [...rs, { unit_id: '', factor: '', notes: null, saved: false }])}>
            <Plus size={13} /> Add a unit
          </button>
        </>
      )}
    </section>
  );
}

/**
 * Fixed per-branch sources were retired in migration 031: the supplier is
 * recorded on each purchase (receipt). What was recorded before is kept,
 * read-only, as history.
 */
function FormerSources({ material, branches, suppliers, unitById }) {
  const sources = material.sources ?? [];
  if (!sources.length) return null;
  const branchName = id => branches.find(b => b.id === id)?.name ?? '—';
  const supplierName = id => suppliers.find(x => x.id === id)?.name;
  return (
    <section>
      <h3 className="modal-section-title">Where it was bought (history)</h3>
      <p className="text-xs text-muted mb-8">Suppliers are now recorded on each receipt, so these are no longer edited.</p>
      <ul className="history-list">
        {sources.map(x => (
          <li key={x.id} className="text-sm">
            <span className="text-muted">{branchName(x.branch_id)}:</span> {supplierName(x.supplier_id) || x.source_name}
            {x.purchase_unit_id && <span className="text-muted"> · bought in {unitById[x.purchase_unit_id]?.symbol}</span>}
            {x.status !== 'active' && <span className="text-muted"> (inactive)</span>}
          </li>
        ))}
      </ul>
    </section>
  );
}
