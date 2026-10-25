import { useEffect, useMemo, useState } from 'react';
import { Flag, CheckCircle2, XCircle } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { ENTITY_LABELS, dbErrorMessage } from '../lib/masterData';
import { useBranch } from '../hooks/useBranch';
import { categoryTools } from '../lib/categories';
import { loadFlagBranches } from '../lib/flagBranch';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import Decisions from '../components/master/Decisions';
import FlagChoices from '../components/master/FlagChoices';
import { useSearchParams, Link } from 'react-router-dom';

const LOAD_ERROR = "We couldn't load the review queue. Please try again.";

// How to name each flagged entity: table and display column
const ENTITY_NAMES = {
  product:          ['products', 'canonical_name'],
  material:         ['materials', 'name'],
  product_category: ['product_categories', 'name'],
  color:            ['color_palette', 'name'],
  unit:             ['units', 'symbol'],
  supplier:         ['suppliers', 'name'],
  identity_decision: ['identity_decisions', 'term'],
};

// Where an admin goes to act on a flag
const OPEN_LINK = {
  product:           f => `/products?edit=${f.entity_id}`,
  material:          () => '/materials',
  product_category:  () => '/categories',
  color:             () => '/colours',
  supplier:          () => '/suppliers',
  identity_decision: (f, name) => `/review?tab=decisions&q=${encodeURIComponent(name ?? '')}`,
  production_batch:  () => '/production',
};

/**
 * Every open "needs review" flag in the organization, across all master
 * data. Admins resolve or dismiss each with a note; closed flags stay on the
 * record's own history.
 */
export default function ReviewQueue() {
  const { session, profile, canManage } = useAuth();
  const [params, setParams] = useSearchParams();
  const tab = params.get('tab') === 'decisions' ? 'decisions' : 'flags';
  const canResolve = canManage('products.manage') || canManage('materials.manage');
  const [flags,   setFlags]   = useState([]);
  const [names,   setNames]   = useState({});
  const [filter,  setFilter]  = useState('all');
  const [note,    setNote]    = useState({});
  const [busy,    setBusy]    = useState(null);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [actionError, setActionError] = useState('');
  const [refs, setRefs] = useState(null);
  const { inBranch } = useBranch();
  const [branchOf, setBranchOf] = useState(() => () => null);   // flag → its branch, null = shared

  async function load() {
    setError('');
    const { data, error: err } = await supabase
      .from('review_flags')
      .select('id, entity_type, entity_id, reason_code, reason, created_at, admin_explanation')
      .eq('status', 'open')
      .order('entity_type').order('created_at', { ascending: false });   // newest on top (2026-10-25)
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }

    const byType = {};
    for (const f of data || []) (byType[f.entity_type] ??= []).push(f.entity_id);
    const lookups = await Promise.all(Object.entries(byType)
      .filter(([type]) => ENTITY_NAMES[type])
      .map(async ([type, ids]) => {
        const [table, col] = ENTITY_NAMES[type];
        const { data: rows } = await supabase.from(table).select(`id, ${col}`).in('id', ids);
        return (rows || []).map(r => [`${type}:${r.id}`, r[col]]);
      }));
    setNames(Object.fromEntries(lookups.flat()));
    const of = await loadFlagBranches(data || []);
    setBranchOf(() => of);
    setFlags(data || []);
    setLoading(false);
    loadRefs();
  }

  // What the choices need: products, categories, stores, colours, units
  async function loadRefs() {
    const [pr, ca, co, un, wh, tx] = await Promise.all([
      supabase.from('products').select('id, canonical_name, category_id, status').order('canonical_name'),
      supabase.from('product_categories').select('id, name, status, sort_order, parent_category_id').order('sort_order'),
      supabase.from('color_palette').select('id, name'),
      supabase.from('units').select('id, symbol'),
      supabase.from('warehouses').select('id, name, branch:branches(name)'),
      supabase.from('inventory_transactions').select('product_id, transaction_date').not('product_id', 'is', null),
    ]);
    const first = {};
    for (const t of tx.data || []) if (!first[t.product_id] || t.transaction_date < first[t.product_id]) first[t.product_id] = t.transaction_date;
    setRefs({
      products: (pr.data || []).map(x => ({ id: x.id, name: x.canonical_name, categoryId: x.category_id, status: x.status })),
      // groups (038) hold no products, so they aren't offered; names show the group
      categories: categoryTools(ca.data || []).leaves.filter(c => c.status === 'active').map(c => ({ ...c, name: categoryTools(ca.data || []).label(c) })),
      categoryName: Object.fromEntries((ca.data || []).map(c => [c.id, categoryTools(ca.data || []).label(c)])),
      colorName: Object.fromEntries((co.data || []).map(c => [c.id, c.name])),
      unitSymbol: Object.fromEntries((un.data || []).map(u => [u.id, u.symbol])),
      storeName: Object.fromEntries((wh.data || []).map(w => [w.id, `${w.branch?.name} — ${w.name}`])),
      firstStockDate: first,
      me: { id: session?.user?.id, name: [profile?.first_name, profile?.last_name].filter(Boolean).join(' ') || session?.user?.email || 'an admin' },
    });
  }

  useEffect(() => { load(); }, []);

  async function close(flag, status) {
    setActionError('');
    setBusy(flag.id);
    const { error: err } = await supabase.from('review_flags').update({
      status,
      resolved_at:     new Date().toISOString(),
      resolved_by:     session?.user?.id ?? null,
      resolution_note: note[flag.id]?.trim() || null,
    }).eq('id', flag.id);
    setBusy(null);
    if (err) { setActionError(dbErrorMessage(err)); return; }
    setFlags(fs => fs.filter(f => f.id !== flag.id));
  }

  // The picked branch's flags plus flags on shared records
  const inView = flags.filter(f => { const b = branchOf(f); return b == null || inBranch(b); });
  const types = useMemo(() => [...new Set(inView.map(f => f.entity_type))], [inView]); // eslint-disable-line react-hooks/exhaustive-deps
  const shown = filter === 'all' ? inView : inView.filter(f => f.entity_type === filter);
  const cols = canResolve ? 3 : 2;

  return (
    <PageShell title="Review queue" subtitle="Master Data"
      description="Records with missing or uncertain data, and the standing name decisions imports follow.">
      <PageTabs value={tab} onChange={k => setParams(k === 'decisions' ? { tab: 'decisions' } : {})}
        tabs={[['flags', `Open flags (${inView.length})`], ['decisions', 'Decisions']]} />
      {tab === 'decisions' ? <Decisions /> : <>
      {types.length > 1 && (
        <div className="flex items-center gap-8 mb-16">
          <label className="text-sm text-muted" htmlFor="rq-filter">Show</label>
          <select id="rq-filter" className="form-input" style={{ width: 'auto' }} value={filter} onChange={e => setFilter(e.target.value)}>
            <option value="all">All ({flags.length})</option>
            {types.map(t => (
              <option key={t} value={t}>{ENTITY_LABELS[t] || t} ({inView.filter(f => f.entity_type === t).length})</option>
            ))}
          </select>
        </div>
      )}
      {actionError && <div className="alert alert-error mb-16" role="alert">{actionError}</div>}
      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead>
                <tr><th>What</th><th>What's uncertain</th>{canResolve && <th>Your choices</th>}</tr>
              </thead>
              <tbody>
                {loading ? Array.from({ length: 5 }).map((_, i) => <SkeletonRow key={i} cols={cols} />)
                : shown.length === 0 ? (
                  <tr><td colSpan={cols}>
                    <EmptyState icon={Flag} title="Nothing to review" description="Records with missing or uncertain data appear here." />
                  </td></tr>
                ) : shown.map(f => (
                  <tr key={f.id}>
                    <td style={{ verticalAlign: 'top' }}>
                      <div style={{ fontWeight: 500 }}>{names[`${f.entity_type}:${f.entity_id}`] || '—'}</div>
                      <div className="text-xs text-muted">{ENTITY_LABELS[f.entity_type] || f.entity_type}</div>
                      {OPEN_LINK[f.entity_type] && (
                        <Link className="btn btn-ghost btn-sm" style={{ paddingLeft: 0 }} to={OPEN_LINK[f.entity_type](f, names[`${f.entity_type}:${f.entity_id}`])}>
                          Open
                        </Link>
                      )}
                    </td>
                    <td className="text-sm" style={{ verticalAlign: 'top', maxWidth: 420 }}>{f.reason}</td>
                    {canResolve && (
                      <td style={{ verticalAlign: 'top' }}>
                        {refs ? <FlagChoices flag={f} name={names[`${f.entity_type}:${f.entity_id}`]} refs={refs} onDone={load} />
                              : <span className="text-xs text-muted">Loading…</span>}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      </>}
    </PageShell>
  );
}
