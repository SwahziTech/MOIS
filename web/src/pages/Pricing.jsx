import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { DollarSign, Search } from 'lucide-react';

const tzs = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const money = v => (v == null ? '—' : `TZS ${tzs.format(v)}`);

export default function Pricing() {
  const [rows,     setRows]     = useState([]);
  const [branches, setBranches] = useState([]);
  const [loading,  setLoading]  = useState(true);
  const [error,    setError]    = useState('');
  const [search,   setSearch]   = useState('');
  const [branchId, setBranchId] = useState('all');

  async function load() {
    setLoading(true);
    setError('');
    const [priceRes, branchRes] = await Promise.all([
      supabase
        .from('product_branch_pricing')
        .select(`
          id, color, is_available, price_consistent_across_branches,
          price_per_unit_exclusive, price_per_unit_inclusive,
          price_per_sqm_inclusive, pcs_per_sqm_at_pricing, source_item_no,
          product:products(canonical_name, product_id_ref),
          branch:branches(id, name)
        `)
        .order('source_item_no', { nullsFirst: false }),
      supabase.from('branches').select('id, name').order('name'),
    ]);
    if (priceRes.error)  { setError(priceRes.error.message);  setLoading(false); return; }
    if (branchRes.error) { setError(branchRes.error.message); setLoading(false); return; }
    setRows(priceRes.data || []);
    setBranches(branchRes.data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return rows.filter(r =>
      (branchId === 'all' || r.branch?.id === branchId) &&
      (!q ||
        (r.product?.canonical_name || '').toLowerCase().includes(q) ||
        (r.color || '').toLowerCase().includes(q))
    );
  }, [rows, search, branchId]);

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
                      <td>{r.color ? <span className="badge badge-accent">{r.color}</span> : <span className="text-muted">Plain</span>}</td>
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
    </PageShell>
  );
}
