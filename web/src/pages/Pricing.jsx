import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { DollarSign, Search, Palette } from 'lucide-react';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

const tzs = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const money = v => (v == null ? '—' : `TZS ${tzs.format(v)}`);

const RULE_TYPE = {
  delta_per_sqmt_over_offwhite: 'Surcharge per SQM over base',
  absolute_price_per_sqmt:      'Price per SQM',
};

/**
 * Price-list rows carry no colour of their own: a NULL colour is the base
 * price — the base colour for coloured categories, the only colour otherwise.
 */
function colourLabel(row) {
  if (row.color) return row.color;
  return row.product?.category?.display_format === 'colored' ? 'OffWhite (base)' : null;
}

export default function Pricing() {
  const [rows,     setRows]     = useState([]);
  const [rules,    setRules]    = useState([]);
  const [branches, setBranches] = useState([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState('');
  const [search,   setSearch]   = useState('');
  const [branchId, setBranchId] = useState('all');

  async function load() {
    setLoading(true);
    setError('');
    const [priceRes, branchRes, ruleRes] = await Promise.all([
      supabase
        .from('product_branch_pricing')
        .select(`
          id, color, is_available, price_consistent_across_branches,
          price_per_unit_exclusive, price_per_unit_inclusive,
          price_per_sqm_inclusive, pcs_per_sqm_at_pricing, source_item_no,
          product:products(canonical_name, product_id_ref,
            category:product_categories(display_format)),
          branch:branches(id, name)
        `)
        .order('source_item_no', { nullsFirst: false }),
      supabase.from('branches').select('id, name').order('name'),
      supabase
        .from('category_color_pricing_rules')
        .select(`
          id, base_color, pricing_type, color_prices,
          category:product_categories(name, sort_order),
          branch:branches(id, name)
        `),
    ]);
    if (priceRes.error)  { console.error(priceRes.error); setError(LOAD_ERROR);  setLoading(false); return; }
    if (branchRes.error) { console.error(branchRes.error); setError(LOAD_ERROR); setLoading(false); return; }
    if (ruleRes.error)   { console.error(ruleRes.error); setError(LOAD_ERROR);   setLoading(false); return; }
    setRows(priceRes.data || []);
    setBranches(branchRes.data || []);
    setRules((ruleRes.data || []).sort((a, b) =>
      (a.category?.sort_order ?? 0) - (b.category?.sort_order ?? 0) ||
      (a.branch?.name || '').localeCompare(b.branch?.name || '')
    ));
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return rows.filter(r =>
      (branchId === 'all' || r.branch?.id === branchId) &&
      (!q ||
        (r.product?.canonical_name || '').toLowerCase().includes(q) ||
        (colourLabel(r) || '').toLowerCase().includes(q))
    );
  }, [rows, search, branchId]);

  const visibleRules = rules.filter(r => branchId === 'all' || r.branch?.id === branchId);

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
                  <th style={{ textAlign: 'right' }}>Per SQM (inc VAT)</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 8 }).map((_, i) => <SkeletonRow key={i} cols={7} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={7}>
                      <EmptyState
                        icon={DollarSign}
                        title="No price entries found"
                        description={search ? `No prices match "${search}".` : 'No prices seeded yet.'}
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
                      <td style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                        {money(r.price_per_sqm_inclusive)}
                        {r.pcs_per_sqm_at_pricing && (
                          <div className="text-muted" style={{ fontSize: 'var(--text-xs)' }}>{r.pcs_per_sqm_at_pricing} pcs/sqm</div>
                        )}
                      </td>
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
            <span className="text-muted text-sm">Prices above are for the base colour</span>
          </div>
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Category</th>
                  <th>Branch</th>
                  <th>Base</th>
                  <th>Rule</th>
                  <th>Other colours</th>
                </tr>
              </thead>
              <tbody>
                {visibleRules.map(rule => (
                  <tr key={rule.id}>
                    <td style={{ fontWeight: 500 }}>{rule.category?.name || '—'}</td>
                    <td>{rule.branch?.name || '—'}</td>
                    <td>{rule.base_color}</td>
                    <td className="text-muted">{RULE_TYPE[rule.pricing_type] || rule.pricing_type}</td>
                    <td>
                      <div className="flex gap-4" style={{ flexWrap: 'wrap' }}>
                        {Object.entries(rule.color_prices || {}).map(([colour, amount]) => (
                          <span key={colour} className="badge badge-neutral">
                            {colour}: {rule.pricing_type === 'delta_per_sqmt_over_offwhite' ? '+' : ''}{money(amount)}
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
