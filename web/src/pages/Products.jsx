import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { Package, Search, Tag } from 'lucide-react';

export default function Products() {
  const [categories,  setCategories]  = useState([]);
  const [products,    setProducts]    = useState([]);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState('');
  const [search,      setSearch]      = useState('');
  const [activeCategory, setActiveCategory] = useState(null);

  async function load() {
    setLoading(true);
    setError('');
    const [catRes, prodRes] = await Promise.all([
      supabase
        .from('product_categories')
        .select('id, name, category_id_ref, display_format, stock_unit, sort_order')
        .order('sort_order'),
      supabase
        .from('products')
        .select(`
          id, product_id_ref, canonical_name, size_cm,
          pcs_per_sqm, wastani_per_bag, status, notes,
          category:product_categories(id, name, display_format, stock_unit)
        `)
        .order('product_id_ref'),
    ]);
    if (catRes.error) { setError(catRes.error.message); setLoading(false); return; }
    if (prodRes.error) { setError(prodRes.error.message); setLoading(false); return; }
    setCategories(catRes.data || []);
    setProducts(prodRes.data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // Filter
  const filtered = products.filter(p => {
    const matchCat  = !activeCategory || p.category?.id === activeCategory;
    const matchSearch = !search ||
      p.canonical_name.toLowerCase().includes(search.toLowerCase()) ||
      p.product_id_ref.toLowerCase().includes(search.toLowerCase());
    return matchCat && matchSearch;
  });

  return (
    <PageShell
      title="Products"
      subtitle="Master Data"
      actions={
        <div className="flex items-center gap-8">
          <div className="search-wrapper">
            <Search size={14} className="search-icon" />
            <input
              id="products-search"
              type="search"
              className="search-input"
              placeholder="Search products…"
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
        </div>
      }
    >
      {/* Category filter tabs */}
      {!loading && !error && categories.length > 0 && (
        <div style={{
          display: 'flex', gap: 6, flexWrap: 'wrap',
          marginBottom: 20, overflowX: 'auto', paddingBottom: 4,
        }}>
          <button
            className={`badge ${!activeCategory ? 'badge-accent' : 'badge-neutral'}`}
            style={{ cursor: 'pointer', padding: '5px 12px', fontSize: 'var(--text-xs)', fontWeight: 600, border: 'none' }}
            onClick={() => setActiveCategory(null)}
          >
            All
          </button>
          {categories.map(cat => (
            <button
              key={cat.id}
              className={`badge ${activeCategory === cat.id ? 'badge-accent' : 'badge-neutral'}`}
              style={{ cursor: 'pointer', padding: '5px 12px', fontSize: 'var(--text-xs)', fontWeight: 500, border: 'none' }}
              onClick={() => setActiveCategory(cat.id === activeCategory ? null : cat.id)}
            >
              {cat.name}
            </button>
          ))}
        </div>
      )}

      {/* Products table */}
      <div className="card">
        {error ? (
          <ErrorState message={error} onRetry={load} />
        ) : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Product ID</th>
                  <th>Name</th>
                  <th>Category</th>
                  <th>Size</th>
                  <th>Pcs / SQM</th>
                  <th>Wastani / Bag</th>
                  <th>Stock Unit</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 8 }).map((_, i) => <SkeletonRow key={i} cols={8} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={8}>
                      <EmptyState
                        icon={Package}
                        title="No products found"
                        description={
                          search
                            ? `No products match "${search}".`
                            : 'No products have been seeded yet.'
                        }
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(p => (
                    <tr key={p.id}>
                      <td style={{ fontFamily: 'monospace', fontSize: 'var(--text-xs)', color: 'var(--text-muted)' }}>
                        {p.product_id_ref}
                      </td>
                      <td style={{ fontWeight: 500 }}>{p.canonical_name}</td>
                      <td>
                        <span className="badge badge-neutral">{p.category?.name || '—'}</span>
                      </td>
                      <td>{p.size_cm || <span style={{ color: 'var(--text-muted)' }}>—</span>}</td>
                      <td>
                        {p.pcs_per_sqm != null
                          ? p.pcs_per_sqm
                          : <span style={{ color: 'var(--color-warning)' }} title="Not yet confirmed">?</span>}
                      </td>
                      <td>
                        {p.wastani_per_bag != null
                          ? p.wastani_per_bag
                          : <span style={{ color: 'var(--color-warning)' }} title="Not yet confirmed">?</span>}
                      </td>
                      <td>
                        <span className={`badge ${p.category?.stock_unit === 'SQM' ? 'badge-info' : 'badge-neutral'}`}>
                          {p.category?.stock_unit || '—'}
                        </span>
                      </td>
                      <td>
                        <span className={`badge ${p.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                          {p.status}
                        </span>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>

            {!loading && filtered.length > 0 && (
              <div style={{
                padding: '10px 14px',
                borderTop: '1px solid var(--border)',
                fontSize: 'var(--text-xs)',
                color: 'var(--text-muted)',
              }}>
                {filtered.length} product{filtered.length !== 1 ? 's' : ''}
                {activeCategory || search ? ` (filtered from ${products.length})` : ''}
              </div>
            )}
          </div>
        )}
      </div>
    </PageShell>
  );
}
