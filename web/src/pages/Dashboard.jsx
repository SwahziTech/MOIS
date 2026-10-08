import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';

/** One card per master-data table. `filter` narrows the count query. */
const STATS = [
  { key: 'categories', label: 'Product Categories', sub: 'Active categories',    table: 'product_categories',     to: '/products'  },
  { key: 'products',   label: 'Products',           sub: 'In product master',    table: 'products',               to: '/products'  },
  { key: 'recipes',    label: 'Recipes / BOM',      sub: 'Active recipes',       table: 'recipe_versions',        to: '/recipes',
    filter: q => q.eq('status', 'active') },
  { key: 'materials',  label: 'Materials',          sub: 'Raw materials tracked', table: 'materials',             to: '/materials' },
  { key: 'branches',   label: 'Branches',           sub: 'Active locations',     table: 'branches',               to: '/branches',
    filter: q => q.eq('status', 'active') },
  { key: 'pricing',    label: 'Price Entries',      sub: 'Across all branches',  table: 'product_branch_pricing', to: '/pricing'   },
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

      <section className="info-card">
        <h2 className="info-card-title">Phase 1a — Foundation</h2>
        <p className="info-card-desc">
          Master data seeded. Auth and org structure active. Next phase: inventory
          transaction tables, production logs, and sales flow.
        </p>
      </section>
    </PageShell>
  );
}
