import { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { ScrollText, Search } from 'lucide-react';

/*
 * Recipes are shared per category + colour (see migration 011),
 * so each row here is one recipe_version, with its materials and
 * the number of products that use it.
 */
export default function Recipes() {
  const [recipes, setRecipes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [status,  setStatus]  = useState('active');

  async function load() {
    setLoading(true);
    setError('');
    const { data, error: err } = await supabase
      .from('recipe_versions')
      .select(`
        id, color_label, version_number, effective_date, status, notes,
        category:product_categories(name, sort_order),
        items:recipe_items(
          quantity, quantity_confirmed,
          material:materials(name),
          unit:units(symbol)
        ),
        products:recipe_version_products(count)
      `)
      .order('color_label');
    if (err) { setError(err.message); setLoading(false); return; }
    const sorted = (data || []).sort((a, b) =>
      (a.category?.sort_order ?? 0) - (b.category?.sort_order ?? 0) ||
      (a.category?.name || '').localeCompare(b.category?.name || '')
    );
    setRecipes(sorted);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return recipes.filter(r =>
      (status === 'all' || r.status === status) &&
      (!q ||
        (r.category?.name || '').toLowerCase().includes(q) ||
        r.color_label.toLowerCase().includes(q))
    );
  }, [recipes, search, status]);

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
                  <th>Category</th>
                  <th>Colour</th>
                  <th>Version</th>
                  <th>Materials (per batch)</th>
                  <th>Products</th>
                  <th>Effective</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 6 }).map((_, i) => <SkeletonRow key={i} cols={7} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={7}>
                      <EmptyState
                        icon={ScrollText}
                        title="No recipes found"
                        description={search ? `No recipes match "${search}".` : 'No recipes seeded yet.'}
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(r => (
                    <tr key={r.id}>
                      <td style={{ fontWeight: 500 }}>{r.category?.name || '—'}</td>
                      <td><span className="badge badge-accent">{r.color_label}</span></td>
                      <td>v{r.version_number}</td>
                      <td style={{ fontSize: 'var(--text-xs)' }}>
                        {r.items?.length ? (
                          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                            {r.items.map((it, idx) => (
                              <span key={idx} className="badge badge-neutral" title={it.quantity_confirmed ? '' : 'Quantity not yet confirmed'}>
                                {it.material?.name}: {it.quantity}{it.unit?.symbol ? ` ${it.unit.symbol}` : ''}
                                {!it.quantity_confirmed && ' *'}
                              </span>
                            ))}
                          </div>
                        ) : <span className="text-muted">—</span>}
                      </td>
                      <td>{r.products?.[0]?.count ?? 0}</td>
                      <td className="text-muted">{r.effective_date}</td>
                      <td>
                        <span className={`badge ${r.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                          {r.status}
                        </span>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
            {!loading && filtered.length > 0 && (
              <div style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', fontSize: 'var(--text-xs)', color: 'var(--text-muted)' }}>
                {filtered.length} recipe version{filtered.length !== 1 ? 's' : ''} · * quantity not yet confirmed
              </div>
            )}
          </div>
        )}
      </div>
    </PageShell>
  );
}
