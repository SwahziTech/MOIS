import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney } from '../lib/format';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { DollarSign, Search, Palette } from 'lucide-react';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

const RULE_TYPE = {
  delta_over_base_color:   'Added to the base-colour price',
  absolute_price_per_sqmt: 'Price per m²',
};

export default function Pricing() {
  const { organization } = useAuth();
  const money = v => formatMoney(v, organization?.currency_code);

  const [rows,     setRows]     = useState([]);
  const [rules,    setRules]    = useState([]);
  const [colouredCategories, setColouredCategories] = useState(new Set());
  const [branches, setBranches] = useState([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState('');
  const [search,   setSearch]   = useState('');
  const [branchId, setBranchId] = useState('all');

  async function load() {
    setLoading(true);
    setError('');
    const [priceRes, branchRes, ruleRes, catColourRes] = await Promise.all([
      supabase
        .from('product_branch_pricing')
        .select(`
          id, is_available, price_consistent_across_branches,
          price_per_unit_exclusive, price_per_unit_inclusive,
          price_per_sqm_inclusive, pcs_per_sqm_at_pricing, source_item_no,
          color:color_palette(name),
          product:products(canonical_name, product_id_ref, category_id),
          branch:branches(id, name)
        `)
        .order('source_item_no', { nullsFirst: false }),
      supabase.from('branches').select('id, name').order('name'),
      supabase
        .from('category_color_pricing_rules')
        .select(`
          id, category_id, pricing_type,
          base:color_palette(name),
          items:category_color_price_items(amount, color:color_palette(name, display_order)),
          category:product_categories(name, sort_order),
          branch:branches(id, name)
        `),
      supabase.from('product_category_colors').select('category_id'),
    ]);
    const err = priceRes.error || branchRes.error || ruleRes.error || catColourRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setRows(priceRes.data || []);
    setBranches(branchRes.data || []);
    setRules((ruleRes.data || []).sort((a, b) =>
      (a.category?.sort_order ?? 0) - (b.category?.sort_order ?? 0) ||
      (a.branch?.name || '').localeCompare(b.branch?.name || '')
    ));
    setColouredCategories(new Set((catColourRes.data || []).map(c => c.category_id)));
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // Base colour name per category+branch, from that category's pricing rule
  const baseColour = useMemo(() => {
    const m = {};
    for (const r of rules) if (r.base?.name) m[`${r.category_id}|${r.branch?.id}`] = r.base.name;
    return m;
  }, [rules]);

  /**
   * A NULL colour is the base price: the category's base colour (named by
   * its pricing rule) for coloured categories, the only colour otherwise.
   */
  function colourLabel(row) {
    if (row.color?.name) return row.color.name;
    const base = baseColour[`${row.product?.category_id}|${row.branch?.id}`];
    if (base) return `${base} (base)`;
    return colouredCategories.has(row.product?.category_id) ? 'Base colour' : null;
  }

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return rows.filter(r =>
      (branchId === 'all' || r.branch?.id === branchId) &&
      (!q ||
        (r.product?.canonical_name || '').toLowerCase().includes(q) ||
        (colourLabel(r) || '').toLowerCase().includes(q))
    );
    // colourLabel depends on rules/colouredCategories
  }, [rows, search, branchId, baseColour, colouredCategories]); // eslint-disable-line react-hooks/exhaustive-deps

  const visibleRules = rules.filter(r => branchId === 'all' || r.branch?.id === branchId);
  // Area pricing is shown only when some visible product is priced by area
  const showArea = filtered.some(r => r.price_per_sqm_inclusive != null);
  const cols = showArea ? 7 : 6;

  return (
    <PageShell
      title="Pricing"
      subtitle="Master Data"
      actions={
        <>
          <select
            id="pricing-branch"
            className="form-input"
            style={{ width: 160, height: 34 }}
            value={branchId}
            onChange={e => setBranchId(e.target.value)}
            aria-label="Filter by branch"
          >
            <option value="all">All branches</option>
            {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
          <div className="search-wrapper">
            <Search size={14} className="search-icon" />
            <input
              id="pricing-search"
              type="search"
              className="search-input"
              placeholder="Search product or colour…"
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
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
                  <th>Product</th>
                  <th>Colour</th>
                  <th>Branch</th>
                  <th style={{ textAlign: 'right' }}>Unit (ex VAT)</th>
                  <th style={{ textAlign: 'right' }}>Unit (inc VAT)</th>
                  {showArea && <th style={{ textAlign: 'right' }}>Per m² (inc VAT)</th>}
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 8 }).map((_, i) => <SkeletonRow key={i} cols={cols} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={cols}>
                      <EmptyState
                        icon={DollarSign}
                        title="No price entries found"
                        description={search ? `No prices match "${search}".` : 'No prices set yet.'}
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(r => (
                    <tr key={r.id}>
                      <td style={{ fontWeight: 500 }}>{r.product?.canonical_name || '—'}</td>
                      <td>{colourLabel(r) ? <span className="badge badge-accent">{colourLabel(r)}</span> : <span className="text-muted">—</span>}</td>
                      <td>
                        {r.branch?.name || '—'}
                        {!r.price_consistent_across_branches && (
                          <span className="badge badge-warning" style={{ marginLeft: 6 }} title="Price differs between branches">varies</span>
                        )}
                      </td>
                      <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{money(r.price_per_unit_exclusive)}</td>
                      <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontWeight: 500 }}>{money(r.price_per_unit_inclusive)}</td>
                      {showArea && (
                        <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                          {money(r.price_per_sqm_inclusive)}
                          {r.price_per_sqm_inclusive != null && r.pcs_per_sqm_at_pricing && (
                            <div className="text-muted" style={{ fontSize: 'var(--text-xs)' }}>{r.pcs_per_sqm_at_pricing} pcs per m²</div>
                          )}
                        </td>
                      )}
                      <td>
                        <span className={`badge ${r.is_available ? 'badge-success' : 'badge-neutral'}`}>
                          {r.is_available ? 'available' : 'unavailable'}
                        </span>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
            {!loading && filtered.length > 0 && (
              <div style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', fontSize: 'var(--text-xs)', color: 'var(--text-muted)' }}>
                {filtered.length} price entr{filtered.length !== 1 ? 'ies' : 'y'}
              </div>
            )}
          </div>
        )}
      </div>

      {!loading && !error && visibleRules.length > 0 && (
        <section className="card mt-24" aria-labelledby="colour-pricing-title">
          <div className="card-header">
            <h2 id="colour-pricing-title" className="card-title flex items-center gap-8">
              <Palette size={16} strokeWidth={1.8} /> Colour pricing
            </h2>
            <span className="text-muted text-sm">Prices above are for each category's base colour</span>
          </div>
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Category</th>
                  <th>Branch</th>
                  <th>Base colour</th>
                  <th>Rule</th>
                  <th>Other colours</th>
                </tr>
              </thead>
              <tbody>
                {visibleRules.map(rule => (
                  <tr key={rule.id}>
                    <td style={{ fontWeight: 500 }}>{rule.category?.name || '—'}</td>
                    <td>{rule.branch?.name || '—'}</td>
                    <td>{rule.base?.name || '—'}</td>
                    <td className="text-muted">{RULE_TYPE[rule.pricing_type] || rule.pricing_type}</td>
                    <td>
                      <div className="flex gap-4" style={{ flexWrap: 'wrap' }}>
                        {[...(rule.items || [])]
                          .sort((a, b) => (a.color?.display_order ?? 0) - (b.color?.display_order ?? 0))
                          .map(item => (
                            <span key={item.color?.name} className="badge badge-neutral">
                              {item.color?.name}: {rule.pricing_type === 'delta_over_base_color' ? '+' : ''}{money(item.amount)}
                            </span>
                          ))}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </PageShell>
  );
}
