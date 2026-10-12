import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';

/** One card per master-data table. `filter` narrows the count query. */
const active = q => q.eq('status', 'active');
const STATS = [
  { key: 'categories', label: 'Product Categories', sub: 'Active categories',    table: 'product_categories',     to: '/categories', filter: active },
  { key: 'products',   label: 'Products',           sub: 'Active products',      table: 'products',               to: '/products',   filter: active },
  { key: 'recipes',    label: 'Recipes / BOM',      sub: 'Active recipes',       table: 'recipe_versions',        to: '/recipes',    filter: active },
  { key: 'materials',  label: 'Materials',          sub: 'Active materials',     table: 'materials',              to: '/materials',  filter: active },
  { key: 'branches',   label: 'Branches',           sub: 'Active locations',     table: 'branches',               to: '/branches',   filter: active },
  { key: 'pricing',    label: 'Price Entries',      sub: 'Across all branches',  table: 'product_branch_pricing', to: '/pricing'   },
  { key: 'review',     label: 'Needs Review',       sub: 'Open review flags',    table: 'review_flags',           to: '/review',
    filter: q => q.eq('status', 'open') },
];

const fmt = new Intl.NumberFormat('en-US');

export default function Dashboard() {
  const [counts,  setCounts]  = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      setError('');
      try {
        const results = await Promise.all(
          STATS.map(s => {
            let q = supabase.from(s.table).select('*', { count: 'exact', head: true });
            if (s.filter) q = s.filter(q);
            return q;
          })
        );
        if (cancelled) return;

        const next = {};
        let failed = false;
        results.forEach((res, i) => {
          if (res.error) { failed = true; console.error(STATS[i].table, res.error); return; }
          next[STATS[i].key] = res.count ?? 0;
        });
        setCounts(next);
        if (failed) setError('Failed to load dashboard data.');
      } catch (e) {
        console.error(e);
        if (!cancelled) setError('Failed to load dashboard data.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    load();
    return () => { cancelled = true; };
  }, []);

  return (
    <PageShell title="Dashboard">
      {error && (
        <div className="alert alert-error mb-16" role="alert">{error}</div>
      )}

      <section className="stat-grid mb-24" aria-label="Master data summary">
        {STATS.map(s => (
          <Link key={s.key} id={`stat-${s.key}`} to={s.to} className="stat-card">
            <div className="stat-card-label">{s.label}</div>
            <div className="stat-card-value">
              {loading
                ? <span className="skeleton" />
                : counts[s.key] != null ? fmt.format(counts[s.key]) : '—'}
            </div>
            <div className="stat-card-sub">{s.sub}</div>
          </Link>
        ))}
      </section>
    </PageShell>
  );
}
