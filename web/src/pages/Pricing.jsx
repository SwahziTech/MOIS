import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { categoryTools } from '../lib/categories';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, PageTabs, categoryChipItems } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityFlags, EntityHistory } from '../components/master/EntityPanels';
import { DollarSign, Search, Palette, Plus } from 'lucide-react';
import NumberInput from '../components/NumberInput';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

const RULE_TYPE = {
  delta_over_base_color:   'Added to the base-colour price',
  absolute_price_per_sqmt: 'Price per m²',
};

const round2 = n => Math.round(n * 100) / 100;
const numOrNull = v => (String(v ?? '').trim() === '' ? null : Number(v));
/** VAT rate (%) implied by a price row's own figures, or null */
const impliedVatRate = r => (r?.price_per_unit_exclusive > 0 && r?.price_per_unit_inclusive != null
  ? round2((r.price_per_unit_inclusive / r.price_per_unit_exclusive - 1) * 100) : null);

/*
 * Prices per product per branch (product_branch_pricing; color_id NULL =
 * the base price) and colour pricing rules per category per branch
 * (category_color_pricing_rules + category_color_price_items). Edits change
 * the row in place; audit_log keeps every old value.
 */
export default function Pricing() {
  const { organization, canManage, canAt } = useAuth();
  const { branchId, inBranch } = useBranch();
  const [carried, setCarried] = useState(new Set());   // 'branch|product' the branch carries (031)
  const canWrite = canManage('products.manage');
  // A branch's managers may propose its prices; an org admin approves (033)
  const canProposeAt = b => !canWrite && canAt('products.manage', b.id, null);
  const money = v => formatMoney(v, organization?.currency_code);

  const [tab,        setTab]        = useState('prices');
  const [prices,     setPrices]     = useState([]);
  const [rules,      setRules]      = useState([]);
  const [products,   setProducts]   = useState([]);
  const [allBranches, setBranches]  = useState([]);
  const [categories, setCategories] = useState([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState('');
  const [search,   setSearch]   = useState('');
  const [categoryId, setCategoryId] = useState(null);
  const [unpricedOnly, setUnpricedOnly] = useState(false);
  const [sortBy, setSortBy] = useState('category');   // category | name | price_desc | price_asc
  const [editingPrice, setEditingPrice] = useState(null);   // { product, branch, row }
  const [editingRule,  setEditingRule]  = useState(null);   // { category, branch, rule }

  async function load() {
    setError('');
    const PRICE_COLS = 'id, product_id, branch_id, color_id, is_available, price_per_unit_exclusive, vat_per_unit, price_per_unit_inclusive, price_per_sqm_inclusive, pcs_per_sqm_at_pricing, raw_notes';
    // the price's own VAT rate (061) when the database has it
    const loadPrices = async () => {
      const withVat = await supabase.from('product_branch_pricing').select(`${PRICE_COLS}, vat_rate`);
      return withVat.error ? supabase.from('product_branch_pricing').select(PRICE_COLS) : withVat;
    };
    const [priceRes, branchRes, ruleRes, prodRes, catRes, bpRes] = await Promise.all([
      loadPrices(),
      supabase.from('branches').select('id, name, status, vat_rate').order('name'),
      supabase
        .from('category_color_pricing_rules')
        .select('id, category_id, branch_id, pricing_type, base_color_id, items:category_color_price_items(color_id, amount)'),
      supabase.from('products')
        .select('id, canonical_name, product_id_ref, category_id, status, pcs_per_sqm, unit:units(symbol), category:product_categories(name)')
        .order('canonical_name'),
      supabase.from('product_categories')
        .select('id, name, sort_order, status, parent_category_id, colors:product_category_colors(color_id, display_order, color:color_palette(name, is_active))')
        .order('sort_order'),
      supabase.from('branch_products').select('branch_id, product_id').eq('status', 'active'),
    ]);
    const err = priceRes.error || branchRes.error || ruleRes.error || prodRes.error || catRes.error || bpRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setPrices(priceRes.data || []);
    setBranches((branchRes.data || []).filter(b => b.status === 'active'));
    setRules(ruleRes.data || []);
    setProducts(prodRes.data || []);
    setCategories(catRes.data || []);
    setCarried(new Set((bpRes.data || []).map(r => `${r.branch_id}|${r.product_id}`)));
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // The branch picked in the sidebar ('' = all)
  const branches = allBranches.filter(b => inBranch(b.id));

  // Base price row per product × branch
  const basePrice = useMemo(() => {
    const m = {};
    for (const p of prices) if (!p.color_id) m[`${p.product_id}|${p.branch_id}`] = p;
    return m;
  }, [prices]);
  // Product-specific colour prices (a row with no price = follows the category's colour pricing)
  const colourPrices = useMemo(() => {
    const m = {};
    for (const p of prices) {
      if (!p.color_id || (p.price_per_sqm_inclusive == null && p.price_per_unit_inclusive == null)) continue;
      (m[`${p.product_id}|${p.branch_id}`] ||= []).push(p);
    }
    return m;
  }, [prices]);

  // Most common VAT rate in this organization's own prices: a starting
  // suggestion for a brand-new price, always shown and editable
  const usualVatRate = useMemo(() => {
    const counts = {};
    for (const p of prices) { const r = impliedVatRate(p); if (r != null) counts[r] = (counts[r] || 0) + 1; }
    const best = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
    return best ? Number(best[0]) : null;
  }, [prices]);

  const q = search.trim().toLowerCase();
  // Groups (038): picking a group shows all of its categories
  const catTools = categoryTools(categories);
  const inPickedCategory = id => !categoryId || id === categoryId || catTools.byId[id]?.parent_category_id === categoryId;
  // With a branch picked: its own list — products it carries or has a price for
  const inList = p => !branchId || carried.has(`${branchId}|${p.id}`) || !!basePrice[`${p.id}|${branchId}`];
  const shownProducts = products.filter(p => inList(p) &&
    (p.status === 'active' || branches.some(b => basePrice[`${p.id}|${b.id}`])) &&
    inPickedCategory(p.category_id) &&
    (!q || p.canonical_name.toLowerCase().includes(q) || p.product_id_ref.toLowerCase().includes(q)) &&
    (!unpricedOnly || (p.status === 'active' && branches.some(b => !basePrice[`${p.id}|${b.id}`])))
  );
  // Price sorts use the one branch in view (a price per m² and a price each
  // are compared as shown)
  const shownPrice = p => { const r = branches.length === 1 ? basePrice[`${p.id}|${branches[0].id}`] : null; return r ? Number(r.price_per_sqm_inclusive ?? r.price_per_unit_inclusive ?? 0) : null; };
  const orderedProducts = [...shownProducts].sort((a, b) => {
    const byName = a.canonical_name.localeCompare(b.canonical_name, undefined, { numeric: true });
    if (sortBy === 'name') return byName;
    if (sortBy === 'price_desc' || sortBy === 'price_asc') {
      const x = shownPrice(a), y = shownPrice(b);
      if (x == null || y == null) return (x == null) - (y == null) || byName;
      return (sortBy === 'price_desc' ? y - x : x - y) || byName;
    }
    const ca = catTools.byId[a.category_id], cb = catTools.byId[b.category_id];
    return (ca && cb ? catTools.compare(ca, cb) : 0) || byName;
  });
  const unpricedCount = products.filter(p => inList(p) && p.status === 'active' && branches.every(b => !basePrice[`${p.id}|${b.id}`])).length;

  const colouredCategories = catTools.ordered.filter(c => c.colors.length > 0 && inPickedCategory(c.id));
  const colourName = Object.fromEntries(categories.flatMap(c => c.colors.map(x => [x.color_id, x.color?.name])));

  return (
    <PageShell
      title="Pricing"
      subtitle="Master Data"
      description="Each branch's prices incl. VAT, and how other colours are priced per category."
    >
      <PageTabs value={tab} onChange={setTab} tabs={[['prices', 'Product prices'], ['colours', 'Colour pricing']]} />
      {tab === 'prices' && (
        <ListToolbar id="pricing-search" search={search} onSearch={setSearch} placeholder="Search products…"
          sort={{ value: sortBy, onChange: setSortBy, options: [
            { value: 'category', label: 'By category (default)' },
            { value: 'name',     label: 'Name: A → Z' },
            ...(branches.length === 1 ? [
              { value: 'price_desc', label: `Price at ${branches[0].name}: highest → lowest` },
              { value: 'price_asc',  label: `Price at ${branches[0].name}: lowest → highest` },
            ] : []),
          ] }}
          filters={[{ key: 'priced', label: 'Prices', value: unpricedOnly ? 'missing' : '', onChange: v => setUnpricedOnly(v === 'missing'),
            options: [{ value: '', label: 'All products' }, { value: 'missing', label: `Missing a price (${unpricedCount} with none)` }] }]} />
      )}
      {!loading && (
        <ChipRow value={categoryId ?? ''} onChange={v => setCategoryId(v || null)}
          items={categoryChipItems(catTools, c => c.status === 'active')} />
      )}

      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : tab === 'prices' ? (
        <div className="card">
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Product</th>
                  {branches.map(b => <th key={b.id}>{b.name}</th>)}
                </tr>
              </thead>
              <tbody>
                {loading ? Array.from({ length: 8 }).map((_, i) => <SkeletonRow key={i} cols={branches.length + 1 || 4} />)
                : shownProducts.length === 0 ? (
                  <tr><td colSpan={branches.length + 1}>
                    <EmptyState icon={DollarSign} title="No products in this view" description={search ? `No products match "${search}".` : ''} />
                  </td></tr>
                ) : orderedProducts.map(p => (
                  <tr key={p.id}>
                    <td>
                      <div style={{ fontWeight: 500 }}>{p.canonical_name}{p.status !== 'active' && <span className="text-muted"> (inactive)</span>}</div>
                      <div className="text-xs text-muted">{catTools.label(p.category_id)}</div>
                    </td>
                    {branches.map(b => {
                      const row = basePrice[`${p.id}|${b.id}`];
                      const cell = row ? (
                        <>
                          <div className={row.is_available ? '' : 'text-muted'}>
                            {row.price_per_sqm_inclusive != null ? `${money(row.price_per_sqm_inclusive)} /m²` : money(row.price_per_unit_inclusive)}
                          </div>
                          <div className="text-xs text-muted">
                            {!row.is_available ? 'not sold here'
                              : row.price_per_sqm_inclusive != null ? (row.price_per_unit_inclusive != null && row.pcs_per_sqm_at_pricing ? `${money(row.price_per_unit_inclusive)} each · ${row.pcs_per_sqm_at_pricing} per m²` : 'per-piece price not set')
                              : Number(row.vat_rate ?? impliedVatRate(row)) === 0 ? 'no VAT' : 'incl. VAT'}
                            {row.is_available && row.price_per_sqm_inclusive != null && Number(row.vat_rate ?? impliedVatRate(row)) === 0 && ' · no VAT'}
                          </div>
                          {colourPrices[`${p.id}|${b.id}`] && (
                            <div className="text-xs text-muted">+ {colourPrices[`${p.id}|${b.id}`].length} colour price{colourPrices[`${p.id}|${b.id}`].length === 1 ? '' : 's'}</div>
                          )}
                        </>
                      ) : <span className="text-muted">—</span>;
                      return (
                        <td key={b.id}>
                          {(canWrite || canProposeAt(b)) && (p.status === 'active' || row) ? (
                            <button type="button" className="price-cell" title={row ? 'Click to change this price' : 'Click to add a price'} onClick={() => setEditingPrice({ product: p, branch: b, row })}
                              aria-label={`${row ? 'Edit' : 'Add'} ${p.canonical_name} price in ${b.name}`}>
                              {row ? cell : <span className="text-muted flex items-center gap-4"><Plus size={12} /> Add</span>}
                            </button>
                          ) : cell}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
            {!loading && (
              <div className="table-footer-note">
                Prices include VAT and are the base price. Other colours follow the category's colour pricing, unless the product has its own colour prices (open a price to set them).
              </div>
            )}
          </div>
        </div>
      ) : (
        <div className="flex flex-col gap-16">
          {loading ? <div className="card"><table><tbody><SkeletonRow cols={4} /></tbody></table></div>
          : colouredCategories.length === 0 ? (
            <div className="card"><EmptyState icon={Palette} title="No coloured categories" description="Give a category colours under Categories to price colours." /></div>
          ) : colouredCategories.map(cat => (
            <div key={cat.id} className="card">
              <div className="card-header"><h2 className="card-title">{catTools.label(cat)}</h2></div>
              <div className="table-container">
                <table>
                  <thead><tr><th>Branch</th><th>Base colour</th><th>Rule</th><th>Other colours</th>{canWrite && <th aria-label="Actions" />}</tr></thead>
                  <tbody>
                    {branches.map(b => {
                      const rule = rules.find(r => r.category_id === cat.id && r.branch_id === b.id);
                      return (
                        <tr key={b.id}>
                          <td style={{ fontWeight: 500 }}>{b.name}</td>
                          {rule ? <>
                            <td>{colourName[rule.base_color_id] || '—'}</td>
                            <td className="text-muted">{RULE_TYPE[rule.pricing_type] || rule.pricing_type}</td>
                            <td>
                              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                                {[...rule.items]
                                  .sort((x, y) => (cat.colors.find(c => c.color_id === x.color_id)?.display_order ?? 0) - (cat.colors.find(c => c.color_id === y.color_id)?.display_order ?? 0))
                                  .map(i => (
                                    <span key={i.color_id} className="badge badge-neutral">
                                      {colourName[i.color_id]}: {rule.pricing_type === 'delta_over_base_color' ? '+' : ''}{money(i.amount)}
                                    </span>
                                  ))}
                                {rule.items.length === 0 && <span className="text-muted">—</span>}
                              </div>
                            </td>
                          </> : <td colSpan={3} className="text-muted">No colour pricing — colours other than the base have no price here.</td>}
                          {(canWrite || canProposeAt(b)) && (
                            <td style={{ textAlign: 'right' }}>
                              <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditingRule({ category: cat, branch: b, rule })}>
                                {rule ? 'Edit' : 'Add'}
                              </button>
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          ))}
        </div>
      )}

      {editingPrice && (
        <PriceModal {...editingPrice} organization={organization} usualVatRate={usualVatRate} vatColumn={prices.some(x => 'vat_rate' in x)}
          colours={categories.find(c => c.id === editingPrice.product.category_id)?.colors ?? []}
          baseColourId={rules.find(r => r.category_id === editingPrice.product.category_id && r.branch_id === editingPrice.branch.id)?.base_color_id ?? null}
          colourRows={prices.filter(x => x.color_id && x.product_id === editingPrice.product.id && x.branch_id === editingPrice.branch.id)}
          viaApproval={!canWrite}
          onClose={() => setEditingPrice(null)} onSaved={async () => { setEditingPrice(null); await load(); }} />
      )}
      {editingRule && (
        <RuleModal {...editingRule} organization={organization} viaApproval={!canWrite} colourName={colourName} catLabel={catTools.label(editingRule.category)}
          onClose={() => setEditingRule(null)} onSaved={async () => { setEditingRule(null); await load(); }} />
      )}
    </PageShell>
  );
}

function PriceModal({ product, branch, row, organization, usualVatRate, vatColumn = false, colours, baseColourId, colourRows, viaApproval, onClose, onSaved }) {
  const isNew = !row;
  const money = v => formatMoney(v, organization?.currency_code);
  // Most prices are per m²; per piece is the exception
  // the product's unit decides (2026-10-25): counted in m² → priced per m²; otherwise per piece. Set in Products.
  const byArea = (product.unit?.symbol ?? '').toUpperCase() === 'SQM';
  const [perSqm,    setPerSqm]    = useState(row?.price_per_sqm_inclusive ?? '');
  const [pcs,       setPcs]       = useState(row?.pcs_per_sqm_at_pricing ?? product.pcs_per_sqm ?? '');
  const [perUnit,   setPerUnit]   = useState(row?.price_per_unit_inclusive ?? '');
  const [vatRate,   setVatRate]   = useState(row ? row.vat_rate ?? impliedVatRate(row) ?? usualVatRate ?? '' : usualVatRate ?? '');   // 061: kept on the price; 0 = sold without VAT
  const [available, setAvailable] = useState(row?.is_available ?? true);
  const [notes,     setNotes]     = useState(row?.raw_notes ?? '');
  const [submitted, setSubmitted] = useState(false);
  // Product-specific colour prices, in the same unit as the base price
  const otherColours = [...colours].sort((a, b) => a.display_order - b.display_order).filter(c => c.color_id !== baseColourId);
  const colourRowById = Object.fromEntries(colourRows.map(r => [r.color_id, r]));
  const shownColourPrice = r => (r ? (byArea ? r.price_per_sqm_inclusive : r.price_per_unit_inclusive) ?? '' : '');
  const [colourAmounts, setColourAmounts] = useState(() =>
    Object.fromEntries(otherColours.map(c => [c.color_id, String(shownColourPrice(colourRowById[c.color_id]))])));
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  // Prices may be typed with or without VAT (2026-10-25); they are kept with VAT, as before
  const [exVat, setExVat] = useState(false);
  const vatTag = exVat ? 'excl. VAT' : 'incl. VAT';
  const factor = () => 1 + (numOrNull(vatRate) ?? 0) / 100;
  const toInc = v => (v == null ? null : exVat ? v * factor() : v);
  function switchVat(next) {
    if (next === exVat) return;
    if (next && numOrNull(vatRate) == null) { setError('Enter the VAT rate first, to type prices without VAT.'); return; }
    setError('');
    const conv = v => { const n = numOrNull(v); return n == null ? v : String(round2(next ? n / factor() : n * factor())); };
    setPerSqm(conv); setPerUnit(conv);
    setColourAmounts(a => Object.fromEntries(Object.entries(a).map(([k, v]) => [k, conv(v)])));
    setExVat(next);
  }

  // Per-unit price incl. VAT: entered directly, or per m² ÷ pieces per m²
  // (per m² without pieces per m²: no per-piece price)
  const perPiece = (sqm, each) => (byArea
    ? (numOrNull(sqm) != null && Number(pcs) > 0 ? toInc(numOrNull(sqm)) / Number(pcs) : null)
    : toInc(numOrNull(each)));
  const unitInc = perPiece(perSqm, perUnit);
  const rate = numOrNull(vatRate);
  const unitEx = unitInc != null && rate != null ? unitInc / (1 + rate / 100) : null;

  async function save(e) {
    e.preventDefault();
    setError('');
    if (byArea) {
      if (!(numOrNull(perSqm) > 0)) { setError('Enter the price per m².'); return; }
      if (numOrNull(pcs) != null && (!Number.isInteger(Number(pcs)) || !(Number(pcs) > 0))) { setError('Pieces per m² must be a whole number above zero, or left blank.'); return; }
    } else if (!(unitInc > 0)) { setError('Enter the price.'); return; }
    if (rate != null && !(rate >= 0 && rate < 100)) { setError('VAT rate must be between 0 and 100.'); return; }
    if (exVat && rate == null) { setError('Enter the VAT rate — the price is typed without VAT.'); return; }
    for (const c of otherColours) {
      const v = numOrNull(colourAmounts[c.color_id]);
      if (v != null && !(v > 0)) { setError(`${c.color?.name}: enter a price above zero, or leave blank.`); return; }
    }

    const priceFields = (sqm, each) => {
      const inc = perPiece(sqm, each);
      const ex = inc != null && rate != null ? inc / (1 + rate / 100) : null;
      return {
        price_per_unit_inclusive: inc != null ? round2(inc) : null,
        price_per_unit_exclusive: ex != null ? round2(ex) : null,
        vat_per_unit:             ex != null ? round2(inc - ex) : null,
        ...(vatColumn ? { vat_rate: rate } : {}),   // 061
        price_per_sqm_inclusive:  byArea && numOrNull(sqm) != null ? (exVat ? round2(toInc(numOrNull(sqm))) : numOrNull(sqm)) : null,
        pcs_per_sqm_at_pricing:   byArea && numOrNull(pcs) != null ? Number(pcs) : null,
      };
    };

    const fields = {
      ...priceFields(perSqm, perUnit),
      is_available:             available,
      raw_notes:                notes.trim() || null,
    };
    // Price and VAT rate untouched: keep the stored figures exactly as they
    // are (no rounding drift, and no silent "correction" of source rows)
    if (row && unitInc != null && rate === impliedVatRate(row) && round2(unitInc) === round2(row.price_per_unit_inclusive)) {
      fields.price_per_unit_inclusive = row.price_per_unit_inclusive;
      fields.price_per_unit_exclusive = row.price_per_unit_exclusive;
      fields.vat_per_unit             = row.vat_per_unit;
    }
    const changes = [{ color_id: null, existingId: row?.id, fields }];

    // Colour prices: add, change, or blank out. Rows are never deleted — a
    // row with no price follows the category's colour pricing again.
    for (const c of otherColours) {
      const existing = colourRowById[c.color_id];
      const v = numOrNull(colourAmounts[c.color_id]);
      if (v == null && (!existing || shownColourPrice(existing) === '' && existing.price_per_unit_inclusive == null)) continue;
      const cf = v == null
        ? { price_per_unit_inclusive: null, price_per_unit_exclusive: null, vat_per_unit: null, price_per_sqm_inclusive: null, pcs_per_sqm_at_pricing: null }
        : { ...priceFields(byArea ? v : null, byArea ? null : v), is_available: available };
      if (existing && v != null && round2(Number(shownColourPrice(existing))) === round2(toInc(v))
          && (existing.price_per_sqm_inclusive != null) === byArea
          && existing.pcs_per_sqm_at_pricing === cf.pcs_per_sqm_at_pricing
          && existing.is_available === available) continue;
      changes.push({ color_id: c.color_id, existingId: existing?.id, fields: cf, colourName: c.color?.name });
    }

    setBusy(true);
    if (viaApproval) {
      const shown = f => (f.price_per_sqm_inclusive != null ? `${money(f.price_per_sqm_inclusive)} /m²` : f.price_per_unit_inclusive != null ? `${money(f.price_per_unit_inclusive)} each` : 'colour pricing');
      const summary = `${product.canonical_name} at ${branch.name}: ` + changes.map(ch => `${ch.colourName ? `${ch.colourName} ` : ''}${shown(ch.fields)}`).join(', ')
        + (row ? ` (was ${shown(row)})` : ' (new price)');
      const { error: err } = await supabase.rpc('request_change', {
        p_kind: 'price', p_branch_id: branch.id, p_summary: summary,
        p_payload: { rows: changes.map(ch => ({ product_id: product.id, color_id: ch.color_id, ...ch.fields })) },
      });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err, "We couldn't send this for approval. Please try again.")); return; }
      setSubmitted(true);
      return;
    }
    for (const ch of changes) {
      const { error: err } = ch.existingId
        ? await supabase.from('product_branch_pricing').update(ch.fields).eq('id', ch.existingId)
        : await supabase.from('product_branch_pricing').insert({
            ...ch.fields, organization_id: organization.id, product_id: product.id, branch_id: branch.id, color_id: ch.color_id,
          });
      if (err) { setBusy(false); setError(`${ch.colourName ? `${ch.colourName}: ` : ''}${dbErrorMessage(err)}`); return; }
    }
    setBusy(false);
    onSaved();
  }

  if (submitted) {
    return (
      <Modal title={`${product.canonical_name} — ${branch.name}`} onClose={onClose}
        footer={<button type="button" className="btn btn-primary" onClick={onClose}>Done</button>}>
        <p className="text-sm">Sent for an admin's approval. The price changes once it is approved — follow it under <strong>Approvals</strong>.</p>
      </Modal>
    );
  }

  return (
    <Modal title={`${product.canonical_name} — ${branch.name}`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="price-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>
          {viaApproval ? 'Submit for approval' : isNew ? 'Add price' : 'Save'}
        </button>
      </>}>
      <form id="price-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        {viaApproval && <div className="alert alert-info" role="note">Price changes need an admin's approval: this is sent to the Approvals queue.</div>}
        <p className="text-sm text-muted">Base price{product.unit?.symbol ? ` · stocked in ${product.unit.symbol}` : ''}{otherColours.length ? ". Other colours follow the category's colour pricing unless you set them below." : '.'}</p>
        <div className="flex items-center gap-8" role="group" aria-label="Price typed with or without VAT">
          <span className="text-sm">The price I type</span>
          <button type="button" className={`filter-chip${!exVat ? ' is-on' : ''}`} aria-pressed={!exVat} onClick={() => switchVat(false)}>includes VAT</button>
          <button type="button" className={`filter-chip${exVat ? ' is-on' : ''}`} aria-pressed={exVat} onClick={() => switchVat(true)}>excludes VAT</button>
        </div>
        <p className="text-xs text-muted">{byArea ? 'Counted in m²: priced per m².' : 'Counted in pieces: priced per piece.'} The unit is set on the product (Products).</p>
        {byArea ? (
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="pr-sqm">Price per m² ({vatTag})</label>
              <NumberInput id="pr-sqm" step="any" min="0" className="form-input" autoFocus value={perSqm} onChange={e => setPerSqm(e.target.value)} />
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="pr-pcs">Pieces per m² <span className="text-muted">(optional)</span></label>
              <NumberInput id="pr-pcs" step="1" min="1" className="form-input" placeholder="Not known" value={pcs} onChange={e => setPcs(e.target.value)} />
              <span className="form-hint">Only needed to work out a price per piece.</span>
            </div>
          </div>
        ) : (
          <div className="form-group">
            <label className="form-label" htmlFor="pr-unit">Price each ({vatTag})</label>
            <NumberInput id="pr-unit" step="any" min="0" className="form-input" autoFocus value={perUnit} onChange={e => setPerUnit(e.target.value)} />
          </div>
        )}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="pr-vat">VAT rate (%)</label>
            <NumberInput id="pr-vat" step="any" min="0" className="form-input" placeholder="Not recorded" value={vatRate} onChange={e => setVatRate(e.target.value)} />
            <span className="flex items-center gap-4 mt-4">
              {usualVatRate != null && Number(usualVatRate) > 0 && <button type="button" className={`filter-chip${numOrNull(vatRate) === Number(usualVatRate) ? ' is-on' : ''}`} onClick={() => setVatRate(String(usualVatRate))}>VAT {usualVatRate}%</button>}
              <button type="button" className={`filter-chip${numOrNull(vatRate) === 0 ? ' is-on' : ''}`} onClick={() => setVatRate('0')}>No VAT</button>
            </span>
            <span className="form-hint">{numOrNull(vatRate) === 0 ? 'Sold without VAT: the price is the same with and without VAT.' : 'The VAT in this price. Pick No VAT for a product sold without VAT.'}</span>
          </div>
          <div className="form-group">
            <span className="form-label">Works out to</span>
            <p className="text-sm">
              {byArea && numOrNull(perSqm) != null && rate != null && <>{money(round2(toInc(numOrNull(perSqm))))} /m² incl. VAT · {money(round2(toInc(numOrNull(perSqm)) / (1 + rate / 100)))} excl.<br /></>}
              {unitInc != null ? <>{money(round2(unitInc))} each incl. VAT{unitEx != null && <><br />{money(round2(unitEx))} excl. VAT</>}</>
                : byArea && numOrNull(perSqm) != null ? 'No price per piece — add pieces per m² if you need one.' : '—'}
            </p>
          </div>
        </div>
        <label className="text-sm flex items-center gap-8">
          <input type="checkbox" checked={available} onChange={e => setAvailable(e.target.checked)} />
          Sold at {branch.name}
        </label>
        {otherColours.length > 0 && (
          <section>
            <h3 className="modal-section-title">Colour prices for this product <span className="text-muted">(optional)</span></h3>
            <p className="text-xs text-muted mb-8">
              {byArea ? 'Price per m²' : 'Price each'} ({vatTag}) for {product.canonical_name} in each colour at {branch.name}.
              Blank follows the category's colour pricing.
            </p>
            <div className="flex flex-col gap-8">
              {otherColours.map(c => (
                <div key={c.color_id} className="form-row" style={{ alignItems: 'center' }}>
                  <label className="text-sm" htmlFor={`pc-${c.color_id}`}>{c.color?.name}{c.color?.is_active === false ? ' (discontinued)' : ''}</label>
                  <NumberInput id={`pc-${c.color_id}`} step="any" min="0" className="form-input" placeholder="Category pricing"
                    value={colourAmounts[c.color_id] ?? ''} onChange={e => setColourAmounts(a => ({ ...a, [c.color_id]: e.target.value }))} />
                </div>
              ))}
            </div>
          </section>
        )}
        <div className="form-group">
          <label className="form-label" htmlFor="pr-notes">Notes</label>
          <input id="pr-notes" className="form-input" value={notes} onChange={e => setNotes(e.target.value)} />
        </div>
        {!isNew && <EntityFlags entityType="product_price" entityId={row.id} canResolve />}
        {!isNew && <EntityHistory entityType="product_price" entityId={row.id} />}
      </form>
    </Modal>
  );
}

function RuleModal({ category, branch, rule, organization, viaApproval, colourName, catLabel, onClose, onSaved }) {
  const isNew = !rule;
  const colours = [...category.colors].sort((a, b) => a.display_order - b.display_order);
  const [baseId, setBaseId] = useState(rule?.base_color_id ?? colours[0]?.color_id ?? '');
  const [type,   setType]   = useState(rule?.pricing_type ?? 'delta_over_base_color');
  const [amounts, setAmounts] = useState(Object.fromEntries((rule?.items || []).map(i => [i.color_id, String(i.amount)])));
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [submitted, setSubmitted] = useState(false);
  const money = v => formatMoney(v, organization?.currency_code);
  const others = colours.filter(c => c.color_id !== baseId);
  // Amounts may be typed with or without VAT (2026-10-25); kept with VAT at the branch's rate, as before
  const [exVat, setExVat] = useState(false);
  const f = 1 + (Number(branch.vat_rate ?? 0) / 100);
  const incAmt = id => { const v = numOrNull(amounts[id]); return v == null ? null : exVat ? round2(v * f) : v; };
  function switchVat(next) {
    if (next === exVat) return;
    setAmounts(a => Object.fromEntries(Object.entries(a).map(([k, v]) => { const n = numOrNull(v); return [k, n == null ? v : String(round2(next ? n / f : n * f))]; })));
    setExVat(next);
  }

  async function save(e) {
    e.preventDefault();
    setError('');
    for (const c of others) {
      const v = numOrNull(amounts[c.color_id]);
      if (v != null && !(v >= 0)) { setError(`${c.color?.name}: enter zero or more, or leave blank.`); return; }
    }
    setBusy(true);
    // A branch manager's change waits for an org admin (039)
    if (viaApproval) {
      const items = others.filter(c => incAmt(c.color_id) != null)
        .map(c => ({ color_id: c.color_id, amount: incAmt(c.color_id) }));
      const what = items.map(i => `${colourName[i.color_id]} ${type === 'delta_over_base_color' ? '+' : ''}${money(i.amount)}`).join(', ') || 'no other colours priced';
      const { error: err } = await supabase.rpc('request_change', {
        p_kind: 'color_rule', p_branch_id: branch.id,
        p_payload: { category_id: category.id, base_color_id: baseId, pricing_type: type, items },
        p_summary: `Colour pricing for ${catLabel} at ${branch.name}: base ${colourName[baseId] ?? ''}; ${what}`,
      });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err, "We couldn't send this for approval. Please try again.")); return; }
      setSubmitted(true);
      return;
    }
    let ruleId = rule?.id;
    if (isNew) {
      const { data, error: err } = await supabase.from('category_color_pricing_rules')
        .insert({ organization_id: organization.id, category_id: category.id, branch_id: branch.id, base_color_id: baseId, pricing_type: type })
        .select('id').single();
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
      ruleId = data.id;
    } else if (rule.base_color_id !== baseId || rule.pricing_type !== type) {
      const { error: err } = await supabase.from('category_color_pricing_rules')
        .update({ base_color_id: baseId, pricing_type: type }).eq('id', ruleId);
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }

    const current = Object.fromEntries((rule?.items || []).map(i => [i.color_id, Number(i.amount)]));
    const upserts = others
      .filter(c => incAmt(c.color_id) != null && round2(incAmt(c.color_id)) !== round2(current[c.color_id]))
      .map(c => ({ organization_id: organization.id, rule_id: ruleId, color_id: c.color_id, amount: incAmt(c.color_id) }));
    // Blank amounts, and the base colour itself, have no item
    const removals = Object.keys(current).filter(id => id === baseId || numOrNull(amounts[id]) == null);
    if (upserts.length) {
      const { error: err } = await supabase.from('category_color_price_items').upsert(upserts, { onConflict: 'rule_id,color_id' });
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }
    if (removals.length) {
      const { error: err } = await supabase.from('category_color_price_items').delete().eq('rule_id', ruleId).in('color_id', removals);
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
    }
    setBusy(false);
    onSaved();
  }

  return (
    submitted ? (
      <Modal title={`${catLabel} — ${branch.name} colour pricing`} onClose={onClose}
        footer={<button type="button" className="btn btn-primary" onClick={onClose}>Done</button>}>
        <p className="text-sm">Sent for an admin's approval. The colour pricing changes once it is approved — follow it under <strong>Approvals</strong>.</p>
      </Modal>
    ) :
    <Modal title={`${catLabel} — ${branch.name} colour pricing`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="rule-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !baseId}>
          {viaApproval ? 'Submit for approval' : isNew ? 'Add colour pricing' : 'Save'}
        </button>
      </>}>
      <form id="rule-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        {viaApproval && <div className="alert alert-info" role="note">Colour pricing changes need an admin's approval: this is sent to the Approvals queue.</div>}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="rule-base">Base colour</label>
            <select id="rule-base" className="form-input" value={baseId} onChange={e => setBaseId(e.target.value)}>
              {colours.map(c => <option key={c.color_id} value={c.color_id}>{c.color?.name}{c.color?.is_active === false ? ' (discontinued)' : ''}</option>)}
            </select>
            <span className="form-hint">Products' own prices are for this colour.</span>
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="rule-type">Other colours are priced as</label>
            <select id="rule-type" className="form-input" value={type} onChange={e => setType(e.target.value)}>
              {Object.entries(RULE_TYPE).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </div>
        </div>
        <section>
          <h3 className="modal-section-title">{type === 'delta_over_base_color' ? 'Amount added per m²' : 'Price per m²'} ({exVat ? 'excl.' : 'incl.'} VAT)</h3>
          <div className="flex items-center gap-8 mb-8" role="group" aria-label="Amounts typed with or without VAT">
            <span className="text-sm">The amounts I type</span>
            <button type="button" className={`filter-chip${!exVat ? ' is-on' : ''}`} aria-pressed={!exVat} onClick={() => switchVat(false)}>include VAT</button>
            <button type="button" className={`filter-chip${exVat ? ' is-on' : ''}`} aria-pressed={exVat} onClick={() => switchVat(true)}>exclude VAT</button>
            <span className="text-xs text-muted">VAT {Number(branch.vat_rate ?? 0)}% at {branch.name}</span>
          </div>
          <div className="flex flex-col gap-8">
            {others.map(c => (
              <div key={c.color_id} className="form-row" style={{ alignItems: 'center' }}>
                <label className="text-sm" htmlFor={`amt-${c.color_id}`}>{c.color?.name}{c.color?.is_active === false ? ' (discontinued)' : ''}</label>
                <NumberInput id={`amt-${c.color_id}`} step="any" min="0" className="form-input" placeholder="No price"
                  value={amounts[c.color_id] ?? ''} onChange={e => setAmounts(a => ({ ...a, [c.color_id]: e.target.value }))} />
              </div>
            ))}
          </div>
          <p className="text-xs text-muted mt-8">
            Blank means that colour has no price at {branch.name}.
            {type === 'delta_over_base_color' && others[0] && numOrNull(amounts[others[0].color_id]) != null &&
              ` e.g. ${others[0].color?.name} = base price + ${money(numOrNull(amounts[others[0].color_id]))} per m².`}
          </p>
        </section>
        {!isNew && <EntityHistory entityType="color_pricing_rule" entityId={rule.id} />}
      </form>
    </Modal>
  );
}
