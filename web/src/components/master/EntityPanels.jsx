import { useEffect, useState } from 'react';
import { Flag, CheckCircle2, XCircle, History } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { auditValue, dbErrorMessage } from '../../lib/masterData';

function formatWhen(ts) {
  return new Date(ts).toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

/**
 * Review flags on any master-data entity. Admins (canResolve) can mark a flag
 * resolved or dismissed with a note; flags are never deleted.
 */
export function EntityFlags({ entityType, entityId, canResolve, onChanged }) {
  const { session } = useAuth();
  const [flags, setFlags]   = useState([]);
  const [note,  setNote]    = useState({});
  const [busy,  setBusy]    = useState(null);
  const [error, setError]   = useState('');

  async function load() {
    const { data, error: err } = await supabase
      .from('review_flags')
      .select('id, reason_code, reason, status, created_at, resolved_at, resolution_note')
      .eq('entity_type', entityType)
      .eq('entity_id', String(entityId))
      .order('created_at', { ascending: false });
    if (err) { console.error(err); return; }
    setFlags(data || []);
  }

  useEffect(() => { if (entityId) load(); }, [entityType, entityId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function close(flag, status) {
    setError('');
    setBusy(flag.id);
    const { error: err } = await supabase.from('review_flags').update({
      status,
      resolved_at:     new Date().toISOString(),
      resolved_by:     session?.user?.id ?? null,
      resolution_note: note[flag.id]?.trim() || null,
    }).eq('id', flag.id);
    setBusy(null);
    if (err) { setError(dbErrorMessage(err)); return; }
    await load();
    onChanged?.();
  }

  const open = flags.filter(f => f.status === 'open');
  const closed = flags.filter(f => f.status !== 'open');
  if (!flags.length) return null;

  return (
    <section className="entity-panel">
      <h3 className="modal-section-title flex items-center gap-8">
        <Flag size={14} /> Needs review {open.length > 0 && <span className="badge badge-warning">{open.length} open</span>}
      </h3>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <ul className="flag-list">
        {open.map(f => (
          <li key={f.id} className="flag-item flag-open">
            <p className="text-sm">{f.reason}</p>
            {canResolve && (
              <div className="flag-actions">
                <input className="form-input" placeholder="Note (optional) — what was decided"
                  aria-label="Resolution note"
                  value={note[f.id] || ''} onChange={e => setNote(n => ({ ...n, [f.id]: e.target.value }))} />
                <button type="button" className="btn btn-outline btn-sm" disabled={busy === f.id} onClick={() => close(f, 'resolved')}>
                  <CheckCircle2 size={13} /> Resolved
                </button>
                <button type="button" className="btn btn-ghost btn-sm" disabled={busy === f.id} onClick={() => close(f, 'dismissed')}>
                  <XCircle size={13} /> Dismiss
                </button>
              </div>
            )}
          </li>
        ))}
        {closed.map(f => (
          <li key={f.id} className="flag-item flag-closed">
            <p className="text-sm text-muted">{f.reason}</p>
            <p className="text-xs text-muted">
              {f.status === 'resolved' ? 'Resolved' : 'Dismissed'} {formatWhen(f.resolved_at)}{f.resolution_note ? ` — ${f.resolution_note}` : ''}
            </p>
          </li>
        ))}
      </ul>
    </section>
  );
}

const FIELD_LABELS = {
  name: 'Name', canonical_name: 'Name', status: 'Status', is_active: 'Active', display_order: 'Order',
  sort_order: 'Order', default_unit_id: 'Default unit', stock_unit_id: 'Stock unit', unit_id: 'Unit',
  category_id: 'Category', display_format: 'Layout', notes: 'Notes', source_name: 'Source',
  purchase_unit_id: 'Purchase unit', is_primary: 'Primary', factor_to_stock_unit: 'Factor',
};

/** Field-level change history for any entity (readable with org.manage). */
export function EntityHistory({ entityType, entityId }) {
  const { canManage } = useAuth();
  const [rows, setRows] = useState(null);

  useEffect(() => {
    if (!entityId || !canManage('org.manage')) return;
    supabase
      .from('audit_log')
      .select('id, action, field, old_value, new_value, changed_by, changed_via, changed_at')
      .eq('entity_type', entityType)
      .eq('entity_id', String(entityId))
      .order('changed_at', { ascending: false })
      .limit(50)
      .then(async ({ data, error }) => {
        if (error) { console.error(error); setRows([]); return; }
        const ids = [...new Set((data || []).map(r => r.changed_by).filter(Boolean))];
        let names = {};
        if (ids.length) {
          const { data: people } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
          names = Object.fromEntries((people || []).map(p =>
            [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email]));
        }
        setRows((data || []).map(r => ({ ...r, who: names[r.changed_by] })));
      });
  }, [entityType, entityId]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!canManage('org.manage') || !rows?.length) return null;
  return (
    <details className="entity-panel">
      <summary className="modal-section-title flex items-center gap-8"><History size={14} /> Change history ({rows.length})</summary>
      <ul className="history-list">
        {rows.map(r => (
          <li key={r.id} className="text-sm">
            <span className="text-muted">{formatWhen(r.changed_at)}</span>{' · '}
            {r.action === 'update'
              ? <>{FIELD_LABELS[r.field] || r.field}: {auditValue(r.old_value)} → <strong>{auditValue(r.new_value)}</strong></>
              : r.action === 'insert' ? 'Created' : 'Deleted'}
            <span className="text-muted"> — {r.changed_via === 'app' ? (r.who || 'a user') : r.changed_via === 'service' ? 'data import' : 'system'}</span>
          </li>
        ))}
      </ul>
    </details>
  );
}
