import { useEffect, useState } from 'react';
import { CheckSquare } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import RequestDetail from '../components/approvals/RequestDetail';
import { loadInventoryRefs } from '../lib/inventory';

const LOAD_ERROR = "We couldn't load approvals. Please try again.";

const KIND = {
  price:          { label: 'Price change',     perm: 'products.manage' },
  color_rule:     { label: 'Colour pricing',   perm: 'products.manage' },
  production_day: { label: 'Production (earlier date)', perm: 'inventory.adjust' },
  stock_movement: { label: 'Stock correction', perm: 'inventory.adjust' },
  stock_reversal: { label: 'Reversal',         perm: 'inventory.adjust' },
  stock_import:   { label: 'Opening stock',    perm: 'inventory.adjust' },
  purchase:       { label: 'Purchase (earlier date)', perm: 'inventory.adjust' },
};
const STATUS_BADGE = { pending: 'badge-warning', approved: 'badge-success', rejected: 'badge-neutral', withdrawn: 'badge-neutral' };

/*
 * Branch managers' price changes and corrective stock entries wait here
 * until an org admin approves them (migration 033). Approving applies the
 * change exactly as submitted, through the normal checks; if it no longer
 * fits, it stays waiting with the reason.
 */
export default function Approvals() {
  const { session, canManage } = useAuth();
  const { inBranch } = useBranch();
  const [rows,    setRows]    = useState([]);
  const [people,  setPeople]  = useState({});
  const [branches, setBranches] = useState({});
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [tab,     setTab]     = useState('pending');
  const [busy,    setBusy]    = useState(null);
  const [notes,   setNotes]   = useState({});    // request id → admin's note
  const [rowError, setRowError] = useState({});  // request id → message
  const [open,    setOpen]    = useState(null);  // request id in the details window
  const [refs,    setRefs]    = useState(null);  // names for the details (loaded on first open)

  async function load() {
    setError('');
    const [pc, br] = await Promise.all([
      supabase.from('pending_changes')
        .select('id, branch_id, kind, summary, payload, status, requested_by, requested_at, decided_by, decided_at, decision_note, last_error')
        .order('requested_at', { ascending: false }).limit(300),
      supabase.from('branches').select('id, name'),
    ]);
    if (pc.error || br.error) { console.error(pc.error || br.error); setError(LOAD_ERROR); setLoading(false); return; }
    const ids = [...new Set((pc.data || []).flatMap(r => [r.requested_by, r.decided_by]).filter(Boolean))];
    if (ids.length) {
      const { data: ppl } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
      setPeople(Object.fromEntries((ppl || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
    }
    setRows(pc.data || []);
    setBranches(Object.fromEntries((br.data || []).map(b => [b.id, b.name])));
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  function openRequest(r) {
    setOpen(r.id);
    if (!refs) loadInventoryRefs().then(setRefs).catch(() => setRefs(null));
  }

  async function decide(r, approve) {
    setRowError(e => ({ ...e, [r.id]: '' }));
    setBusy(r.id);
    const { data, error: err } = await supabase.rpc('decide_change', { p_id: r.id, p_approve: approve, p_note: notes[r.id] || null });
    window.dispatchEvent(new Event('mois:approvals-changed'));
    setBusy(null);
    if (err) { setRowError(e => ({ ...e, [r.id]: dbErrorMessage(err) })); return; }
    if (data?.status === 'pending') {
      setRowError(e => ({ ...e, [r.id]: `Couldn't apply it: ${data.error}` }));
    } else setOpen(null);
    await load();
  }

  async function withdraw(r) {
    setBusy(r.id);
    const { error: err } = await supabase.rpc('withdraw_change', { p_id: r.id });
    window.dispatchEvent(new Event('mois:approvals-changed'));
    setBusy(null);
    if (err) { setRowError(e => ({ ...e, [r.id]: dbErrorMessage(err) })); return; }
    setOpen(null);
    await load();
  }

  const inView = rows.filter(r => inBranch(r.branch_id));
  const shown = inView.filter(r => (tab === 'pending' ? r.status === 'pending' : r.status !== 'pending'));
  const waiting = inView.filter(r => r.status === 'pending').length;
  const when = ts => new Date(ts).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

  return (
    <PageShell title="Approvals" subtitle="Overview"
      description="Price changes and stock corrections waiting for an admin, and those already settled.">
      <PageTabs value={tab} onChange={setTab} tabs={[['pending', `Waiting (${waiting})`], ['settled', 'Settled']]} />

      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead><tr><th>Request</th><th>Branch</th><th>Asked by</th><th>Status</th><th aria-label="Actions" /></tr></thead>
              <tbody>
                {loading ? Array.from({ length: 4 }).map((_, i) => <SkeletonRow key={i} cols={5} />)
                : shown.length === 0 ? (
                  <tr><td colSpan={5}>
                    <EmptyState icon={CheckSquare} title={tab === 'pending' ? 'Nothing waiting' : 'Nothing settled yet'}
                      description={tab === 'pending' ? 'Price changes and stock corrections from branch managers appear here until an admin approves them.' : ''} />
                  </td></tr>
                ) : shown.map(r => {
                  const canDecide = canManage(KIND[r.kind]?.perm);
                  const mine = r.requested_by === session?.user?.id;
                  return (
                    <tr key={r.id} className="clickable-row" onClick={() => openRequest(r)} title="Open to review">
                      <td style={{ maxWidth: 520 }}>
                        <div className="text-xs text-muted">{KIND[r.kind]?.label ?? r.kind}</div>
                        <div>{r.summary}</div>
                        {r.status === 'pending' && r.last_error && (
                          <div className="text-xs text-error mt-4">Last approval couldn't be applied: {r.last_error}</div>
                        )}
                        {r.decision_note && <div className="text-xs text-muted mt-4">Note: {r.decision_note}</div>}
                        {rowError[r.id] && <div className="text-xs text-error mt-4">{rowError[r.id]}</div>}
                      </td>
                      <td className="text-muted">{branches[r.branch_id] ?? '—'}</td>
                      <td className="text-sm">
                        {people[r.requested_by] ?? '—'}
                        <div className="text-xs text-muted">{when(r.requested_at)}</div>
                      </td>
                      <td>
                        <span className={`badge ${STATUS_BADGE[r.status]}`}>{r.status}</span>
                        {r.decided_at && r.status !== 'withdrawn' && (
                          <div className="text-xs text-muted">{people[r.decided_by] ?? ''} · {when(r.decided_at)}</div>
                        )}
                      </td>
                      <td style={{ textAlign: 'right', minWidth: 220 }} onClick={e => e.stopPropagation()}>
                        {r.status === 'pending' && canDecide && (
                          <div className="flex flex-col gap-4" style={{ alignItems: 'flex-end' }}>
                            <input className="form-input" style={{ padding: '4px 8px' }} placeholder="Note (optional)" aria-label="Note"
                              value={notes[r.id] ?? ''} onChange={e => setNotes(n => ({ ...n, [r.id]: e.target.value }))} />
                            <div className="flex gap-4">
                              <button type="button" className="btn btn-primary btn-sm" disabled={busy === r.id} onClick={() => decide(r, true)}>Approve</button>
                              <button type="button" className="btn btn-outline btn-sm" disabled={busy === r.id} onClick={() => decide(r, false)}>Reject</button>
                            </div>
                          </div>
                        )}
                        {r.status === 'pending' && !canDecide && mine && (
                          <button type="button" className="btn btn-ghost btn-sm" disabled={busy === r.id} onClick={() => withdraw(r)}>Withdraw</button>
                        )}
                        <button type="button" className="btn btn-ghost btn-sm" onClick={() => openRequest(r)}>Review</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {(() => {
        const r = rows.find(x => x.id === open);
        if (!r) return null;
        return (
          <RequestDetail request={r} kindLabel={KIND[r.kind]?.label ?? r.kind} branchName={branches[r.branch_id]} askedBy={people[r.requested_by]} refs={refs}
            canDecide={canManage(KIND[r.kind]?.perm)} mine={r.requested_by === session?.user?.id} busy={busy === r.id} error={rowError[r.id]}
            note={notes[r.id] ?? ''} onNote={v => setNotes(n => ({ ...n, [r.id]: v }))}
            onDecide={approve => decide(r, approve)} onWithdraw={() => withdraw(r)} onClose={() => setOpen(null)} />
        );
      })()}
    </PageShell>
  );
}
