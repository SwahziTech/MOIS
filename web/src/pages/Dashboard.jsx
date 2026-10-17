import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { useBranch } from '../hooks/useBranch';
import { loadFlagBranches } from '../lib/flagBranch';
import PageShell from '../components/PageShell';

/*
 * One card per master-data table, counted for the branch picked in the
 * sidebar (b) — or the whole organization on "All branches" (b = '').
 * Categories and branches have no branch dimension.
 */
const active = q => q.eq('status', 'active');
const STATS = [
  { key: 'categories', label: 'Product Categories', sub: () => 'Active categories', table: () => 'product_categories', to: '/categories', filter: active },
  { key: 'products',   label: 'Products', to: '/products',
    sub: (b, n) => (b ? `In ${n}'s list` : 'Active products'),
    table: b => (b ? 'branch_products' : 'products'),
    filter: (q, b) => (b ? active(q).eq('branch_id', b) : active(q)) },
  { key: 'recipes',    label: 'Recipes / BOM', to: '/recipes',
    sub: (b, n) => (b ? `Active at ${n}` : 'Active recipes'), table: () => 'recipe_versions',
    filter: (q, b) => (b ? active(q).eq('branch_id', b) : active(q)) },
  { key: 'materials',  label: 'Materials', to: '/materials',
    sub: (b, n) => (b ? `Shared + ${n}'s own` : 'Active materials'), table: () => 'materials',
    filter: (q, b) => (b ? active(q).or(`branch_id.is.null,branch_id.eq.${b}`) : active(q)) },
  { key: 'branches',   label: 'Branches', sub: () => 'Active locations', table: () => 'branches', to: '/branches', filter: active },
  { key: 'pricing',    label: 'Price Entries', to: '/pricing',
    sub: (b, n) => (b ? `At ${n}` : 'Across all branches'), table: () => 'product_branch_pricing',
    filter: (q, b) => (b ? q.eq('branch_id', b) : q) },
];

const fmt = new Intl.NumberFormat('en-US');

export default function Dashboard() {
  const { branchId, branchName, inBranch } = useBranch();
  const [counts,  setCounts]  = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      setError('');
      try {
        const [results, flags] = await Promise.all([
          Promise.all(STATS.map(s => {
            let q = supabase.from(s.table(branchId)).select('*', { count: 'exact', head: true });
            if (s.filter) q = s.filter(q, branchId);
            return q;
          })),
          supabase.from('review_flags').select('entity_type, entity_id').eq('status', 'open'),
        ]);
        if (cancelled) return;
        // open flags: the branch's own plus those on shared records
        const of = await loadFlagBranches(flags.data || []);
        if (cancelled) return;

        const next = {};
        let failed = false;
        results.forEach((res, i) => {
          if (res.error) { failed = true; console.error(STATS[i].table, res.error); return; }
          next[STATS[i].key] = res.count ?? 0;
        });
        if (flags.error) { failed = true; console.error(flags.error); }
        else next.review = (flags.data || []).filter(f => { const b = of(f); return b == null || inBranch(b); }).length;
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
  }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const cards = [...STATS, { key: 'review', label: 'Needs Review', sub: () => (branchId ? `${branchName}'s and shared` : 'Open review flags'), to: '/review' }];

  return (
    <PageShell title="Dashboard">
      {error && (
        <div className="alert alert-error mb-16" role="alert">{error}</div>
      )}

      <section className="stat-grid mb-24" aria-label="Master data summary">
        {cards.map(s => (
          <Link key={s.key} id={`stat-${s.key}`} to={s.to} className="stat-card">
            <div className="stat-card-label">{s.label}</div>
            <div className="stat-card-value">
              {loading
                ? <span className="skeleton" />
                : counts[s.key] != null ? fmt.format(counts[s.key]) : '—'}
            </div>
            <div className="stat-card-sub">{s.sub(branchId, branchName)}</div>
          </Link>
        ))}
      </section>
    </PageShell>
  );
}
