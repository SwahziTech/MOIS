import { useEffect, useMemo, useState } from 'react';
import { Flag, CheckCircle2, XCircle } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { ENTITY_LABELS, dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import Decisions from '../components/master/Decisions';
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
};

/**
 * Every open "needs review" flag in the organization, across all master
 * data. Admins resolve or dismiss each with a note; closed flags stay on the
 * record's own history.
 */
export default function ReviewQueue() {
  const { session, canManage } = useAuth();
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

  async function load() {
    setError('');
    const { data, error: err } = await supabase
      .from('review_flags')
      .select('id, entity_type, entity_id, reason_code, reason, created_at')
      .eq('status', 'open')
      .order('entity_type').order('created_at');
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
    setFlags(data || []);
    setLoading(false);
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

  const types = useMemo(() => [...new Set(flags.map(f => f.entity_type))], [flags]);
  const shown = filter === 'all' ? flags : flags.filter(f => f.entity_type === filter);
  const cols = canResolve ? 3 : 2;

  return (
    <PageShell title="Review queue" subtitle="Master Data">
      <div className="filter-chips mb-16">
        <button type="button" className={`filter-chip${tab === 'flags' ? ' is-on' : ''}`} onClick={() => setParams({})}>Open flags ({flags.length})</button>
        <button type="button" className={`filter-chip${tab === 'decisions' ? ' is-on' : ''}`} onClick={() => setParams({ tab: 'decisions' })}>Decisions</button>
      </div>
      {tab === 'decisions' ? <Decisions /> : <>
      {types.length > 1 && (
        <div className="flex items-center gap-8 mb-16">
          <label className="text-sm text-muted" htmlFor="rq-filter">Show</label>
          <select id="rq-filter" className="form-input" style={{ width: 'auto' }} value={filter} onChange={e => setFilter(e.target.value)}>
            <option value="all">All ({flags.length})</option>
            {types.map(t => (
              <option key={t} value={t}>{ENTITY_LABELS[t] || t} ({flags.filter(f => f.entity_type === t).length})</option>
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
                <tr><th>Record</th><th>What needs review</th>{canResolve && <th>Decision</th>}</tr>
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
                        <div className="flag-actions">
                          <input className="form-input" placeholder="Note (optional)" aria-label="Resolution note"
                            value={note[f.id] || ''} onChange={e => setNote(n => ({ ...n, [f.id]: e.target.value }))} />
                          <button type="button" className="btn btn-outline btn-sm" disabled={busy === f.id} onClick={() => close(f, 'resolved')}>
                            <CheckCircle2 size={13} /> Resolved
                          </button>
                          <button type="button" className="btn btn-ghost btn-sm" disabled={busy === f.id} onClick={() => close(f, 'dismissed')}>
                            <XCircle size={13} /> Dismiss
                          </button>
                        </div>
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
