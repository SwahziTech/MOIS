import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { BookCheck, Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';
import Modal from '../Modal';
import { SkeletonRow } from '../LoadingSpinner';
import { tableDate } from '../../lib/format';

const LOAD_ERROR = "We couldn't load the decisions. Please try again.";

const SUBJECTS = { product: 'Product', color: 'Colour', category: 'Category', material: 'Material', supplier: 'Supplier' };
const DECISIONS = {
  same_as:       'is the same as',
  new_record:    'was added as',
  distinct_from: 'is not',
  not_tracked:   'is not stocked',
};
const SOURCES = { import: 'stock import', review_queue: 'review queue', product_edit: 'product edit', merge: 'product merge', chat: 'chat', source_records: 'project records' };
const TARGET_COL = { product: 'product_id', color: 'color_id', category: 'category_id', material: 'material_id', supplier: 'supplier_id' };

/** Evidence as a person would say it (older entries cite internal file names) */
export const plainEvidence = e => String(e ?? '')
  .replace(/^_decisions_log:\s*/i, 'Recorded in the project notes: ')
  .replace(/product_master\.json alt_names of (.+?)\.?$/i, 'Recorded as another name for $1 in the original product list.')
  .replace(/\s*\(supersedes product_master\.json naming_resolutions[^)]*\)/i, ' (this replaces an earlier note in the original product list)')
  .replace(/\(migrated from import_aliases\)/i, '')
  .replace(/merged via alias/gi, 'recorded under another name')
  .replace(/press_\d+[a-z]?|floor_tiles_\d+|wall_tiles_\d+/gi, '')
  .replace(/\s{2,}/g, ' ').trim();

const targetName = d => d.product?.canonical_name ?? d.color?.name ?? d.category?.name ?? d.material?.name ?? d.supplier?.name ?? null;

/*
 * The identity decision log (migration 026): every recorded answer to "is X
 * the same as Y". Imports and matching use the active ones; a correction
 * replaces an answer everywhere at once and keeps the old one as history.
 */
export default function Decisions() {
  const { organization, canManage } = useAuth();
  const canEdit = canManage('products.manage') || canManage('materials.manage');
  const [rows,    setRows]    = useState([]);
  const [targets, setTargets] = useState({ product: [], color: [], category: [], material: [], supplier: [] });
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [status,  setStatus]  = useState('active');
  const [subject, setSubject] = useState('');
  const [params] = useSearchParams();
  const [search,  setSearch]  = useState(params.get('q') ?? '');
  const [editing, setEditing] = useState(null);    // { mode: 'new'|'correct'|'revoke', row }

  async function load() {
    setError('');
    const [d, p, c, k, m, s] = await Promise.all([
      supabase.from('identity_decisions').select(`
          id, subject_type, term, context, decision, evidence, source, decided_by_label, decided_at, status, status_note, superseded_by,
          product_id, color_id, category_id, material_id, supplier_id,
          product:products(canonical_name), color:color_palette(name), category:product_categories(name),
          material:materials(name), supplier:suppliers(name)`)
        .order('decided_at', { ascending: false }),
      supabase.from('products').select('id, canonical_name, status, category:product_categories(name)').order('canonical_name'),
      supabase.from('color_palette').select('id, name, is_active').order('display_order'),
      supabase.from('product_categories').select('id, name, status').order('sort_order'),
      supabase.from('materials').select('id, name, status').order('name'),
      supabase.from('suppliers').select('id, name, status').order('name'),
    ]);
    const err = [d, p, c, k, m, s].find(r => r.error)?.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setRows(d.data || []);
    setTargets({
      product:  p.data.map(x => ({ id: x.id, name: `${x.canonical_name} — ${x.category?.name ?? ''}${x.status !== 'active' ? ' (inactive)' : ''}` })),
      color:    c.data.map(x => ({ id: x.id, name: `${x.name}${x.is_active ? '' : ' (discontinued)'}` })),
      category: k.data.map(x => ({ id: x.id, name: x.name })),
      material: m.data.map(x => ({ id: x.id, name: x.name })),
      supplier: s.data.map(x => ({ id: x.id, name: x.name })),
    });
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const q = search.trim().toLowerCase();
  const shown = rows.filter(r => (status === 'all' || (status === 'active' ? r.status === 'active' : r.status !== 'active'))
    && (!subject || r.subject_type === subject)
    && (!q || r.term.toLowerCase().includes(q) || (targetName(r) || '').toLowerCase().includes(q) || plainEvidence(r.evidence).toLowerCase().includes(q)));
  const counts = useMemo(() => ({ active: rows.filter(r => r.status === 'active').length, history: rows.filter(r => r.status !== 'active').length }), [rows]);
  const cols = canEdit ? 5 : 4;

  return (
    <>
      <p className="text-sm text-muted mb-16">
        Answers to "is this name the same as that item?". Imports and matching use them, so a question answered here is never asked again.
        A correction replaces the answer everywhere; the old one stays below as history.
      </p>
      <div className="flex items-center gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Status" value={status} onChange={e => setStatus(e.target.value)}>
          <option value="active">Standing ({counts.active})</option>
          <option value="history">Replaced or withdrawn ({counts.history})</option>
          <option value="all">All</option>
        </select>
        <select className="form-input" style={{ width: 'auto' }} aria-label="Kind" value={subject} onChange={e => setSubject(e.target.value)}>
          <option value="">All kinds</option>
          {Object.entries(SUBJECTS).map(([k, l]) => <option key={k} value={k}>{l}s</option>)}
        </select>
        <input type="search" className="form-input" style={{ width: 220 }} placeholder="Search names or evidence…" aria-label="Search decisions"
          value={search} onChange={e => setSearch(e.target.value)} />
        {canEdit && (
          <button type="button" className="btn btn-primary" style={{ marginLeft: 'auto' }} onClick={() => setEditing({ mode: 'new' })}>
            <Plus size={14} /> Record a decision
          </button>
        )}
      </div>

      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead><tr><th>Name</th><th>Answer</th><th>Why</th><th>Decided</th>{canEdit && <th aria-label="Actions" />}</tr></thead>
              <tbody>
                {loading ? Array.from({ length: 5 }).map((_, i) => <SkeletonRow key={i} cols={cols} />)
                : shown.length === 0 ? (
                  <tr><td colSpan={cols}><EmptyState icon={BookCheck} title="No decisions in this view"
                    description="Names resolved in imports, merges and here are listed once decided." /></td></tr>
                ) : shown.map(r => (
                  <tr key={r.id} className={r.status !== 'active' ? 'row-muted' : ''}>
                    <td style={{ verticalAlign: 'top' }}>
                      <div style={{ fontWeight: 500 }}>{r.term}</div>
                      <div className="text-xs text-muted">{SUBJECTS[r.subject_type]}{r.context ? ` · under "${r.context}"` : ''}</div>
                    </td>
                    <td className="text-sm" style={{ verticalAlign: 'top' }}>
                      {DECISIONS[r.decision]}{targetName(r) ? <> <strong>{targetName(r)}</strong></> : ''}
                      {r.status !== 'active' && <div className="text-xs text-muted">{r.status === 'superseded' ? 'replaced' : 'withdrawn'}{r.status_note ? ` — ${r.status_note}` : ''}</div>}
                    </td>
                    <td className="text-xs text-muted" style={{ verticalAlign: 'top', maxWidth: 380 }}>{plainEvidence(r.evidence)}</td>
                    <td className="text-xs text-muted" style={{ verticalAlign: 'top' }}>
                      {r.decided_by_label}<br />{tableDate(r.decided_at, organization?.timezone)} · {SOURCES[r.source] ?? r.source}
                    </td>
                    {canEdit && (
                      <td style={{ textAlign: 'right', verticalAlign: 'top', whiteSpace: 'nowrap' }}>
                        {r.status === 'active' && <>
                          <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing({ mode: 'correct', row: r })}>Correct</button>{' '}
                          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing({ mode: 'revoke', row: r })}>Withdraw</button>
                        </>}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {editing && (
        <DecisionModal {...editing} targets={targets} organizationId={organization.id}
          onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />
      )}
    </>
  );
}

function DecisionModal({ mode, row, targets, organizationId, onClose, onSaved }) {
  const { session, profile } = useAuth();
  const [subjectType, setSubjectType] = useState(row?.subject_type ?? 'product');
  const [term,     setTerm]     = useState(row?.term ?? '');
  const [context,  setContext]  = useState(row?.context ?? '');
  const [decision, setDecision] = useState(row?.decision ?? 'same_as');
  const [targetId, setTargetId] = useState(row ? (row[TARGET_COL[row.subject_type]] ?? '') : '');
  const [evidence, setEvidence] = useState('');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const needsTarget = decision !== 'not_tracked';

  async function save(e) {
    e.preventDefault();
    setError('');
    if (!evidence.trim()) { setError(mode === 'new' ? 'Say why — the evidence or who confirmed it.' : 'Say why.'); return; }
    if (mode !== 'revoke' && needsTarget && !targetId) { setError('Choose what it refers to.'); return; }
    setBusy(true);
    let err;
    if (mode === 'revoke') {
      ({ error: err } = await supabase.rpc('revoke_identity_decision', { p_id: row.id, p_reason: evidence.trim() }));
    } else if (mode === 'correct') {
      ({ error: err } = await supabase.rpc('correct_identity_decision', {
        p_id: row.id, p_new: { decision, ...(needsTarget ? { [TARGET_COL[row.subject_type]]: targetId } : {}) }, p_evidence: evidence.trim(),
      }));
    } else {
      const me = [profile?.first_name, profile?.last_name].filter(Boolean).join(' ') || session?.user?.email || 'a user';
      ({ error: err } = await supabase.from('identity_decisions').insert({
        organization_id: organizationId, subject_type: subjectType, term: term.trim(), context: context.trim(), decision,
        ...(needsTarget ? { [TARGET_COL[subjectType]]: targetId } : {}),
        evidence: evidence.trim(), source: 'review_queue', decided_by: session.user.id, decided_by_label: me,
      }));
    }
    setBusy(false);
    if (err) {
      setError(err.code === '23505' ? 'This name already has a standing answer — correct that one instead.' : dbErrorMessage(err));
      return;
    }
    onSaved();
  }

  const title = mode === 'new' ? 'Record a decision' : mode === 'correct' ? `Correct "${row.term}"` : `Withdraw "${row.term}"`;
  return (
    <Modal title={title} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="decision-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>
          {mode === 'revoke' ? 'Withdraw' : 'Save'}
        </button>
      </>}>
      <form id="decision-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        {mode === 'new' && (
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="dec-term">Name as written</label>
              <input id="dec-term" className="form-input" required autoFocus value={term} onChange={e => setTerm(e.target.value)} placeholder="e.g. 8 GONE" />
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="dec-ctx">Where it appears (optional)</label>
              <input id="dec-ctx" className="form-input" value={context} onChange={e => setContext(e.target.value)} placeholder="e.g. FLOOR TILES — blank means anywhere" />
            </div>
          </div>
        )}
        {mode !== 'revoke' && (
          <div className="form-row">
            {mode === 'new' && (
              <div className="form-group">
                <label className="form-label" htmlFor="dec-kind">Kind</label>
                <select id="dec-kind" className="form-input" value={subjectType} onChange={e => { setSubjectType(e.target.value); setTargetId(''); }}>
                  {Object.entries(SUBJECTS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                </select>
              </div>
            )}
            <div className="form-group">
              <label className="form-label" htmlFor="dec-dec">Answer</label>
              <select id="dec-dec" className="form-input" value={decision} onChange={e => setDecision(e.target.value)}>
                {Object.entries(DECISIONS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
              </select>
            </div>
          </div>
        )}
        {mode !== 'revoke' && needsTarget && (
          <div className="form-group">
            <label className="form-label" htmlFor="dec-target">{SUBJECTS[subjectType]}</label>
            <select id="dec-target" className="form-input" value={targetId} onChange={e => setTargetId(e.target.value)}>
              <option value="">Choose…</option>
              {(targets[subjectType] || []).map(t => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </div>
        )}
        {mode !== 'new' && (
          <p className="text-sm text-muted">
            Currently: "{row.term}" {DECISIONS[row.decision]} {targetName(row) ?? ''}. {mode === 'correct'
              ? 'The new answer applies everywhere from now on; this one stays as history. Stock already posted is not changed — reverse a wrong import under Movements.'
              : 'Withdrawn answers stop being used; the name will be asked about again next time.'}
          </p>
        )}
        <div className="form-group">
          <label className="form-label" htmlFor="dec-why">{mode === 'new' ? 'Why / evidence' : 'Reason'}</label>
          <input id="dec-why" className="form-input" required value={evidence} onChange={e => setEvidence(e.target.value)}
            placeholder={mode === 'new' ? 'e.g. confirmed by the Dodoma store manager' : 'e.g. it is the 80x40 Combo, not 40 Combo'} />
        </div>
      </form>
    </Modal>
  );
}
