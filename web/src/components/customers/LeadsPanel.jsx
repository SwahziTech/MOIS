import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Target, Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatAmount, formatMoneyShort, dateText, tableDate } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import EmptyState from '../EmptyState';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

export const STAGE = { new: 'New', contacted: 'Contacted', quoted: 'Quoted', won: 'Won', lost: 'Lost' };
const STAGE_BADGE = { new: 'badge-info', contacted: 'badge-neutral', quoted: 'badge-warning', won: 'badge-success', lost: 'badge-error' };
const SOURCE = { walk_in: 'Walk-in', phone: 'Phone call', whatsapp: 'WhatsApp', referral: 'Referral', site_visit: 'Site visit', social: 'Social media', other: 'Other' };
const KIND = { call: 'Call', visit: 'Visit', whatsapp: 'WhatsApp', meeting: 'Meeting', other: 'Other' };
const fullName = p => [p?.first_name, p?.last_name].filter(Boolean).join(' ') || 'Someone';

/*
 * Leads (CRM, migration 095, 2026-10-30): prospects — contractors, sites,
 * enquiries — before they buy. Each has who follows up and when; recording a
 * follow-up (call, visit, WhatsApp…) sets the next date. "Make quotation"
 * turns the lead into a customer and opens a new quotation for it; when that
 * quotation becomes an order or invoice the lead shows as won. Newest first;
 * the ones due today or late are counted on top and on the dashboard.
 */
export default function LeadsPanel({ branchId, inBranch, today, currency, search, toolbar }) {
  const { session, canAt } = useAuth();
  const user = session?.user;
  const navigate = useNavigate();
  const canEdit = !!branchId && canAt('sales.create', branchId);
  const [leads, setLeads] = useState(null);
  const [people, setPeople] = useState([]);
  const [sales, setSales] = useState({});
  const [error, setError] = useState('');
  const [stage, setStage] = useState('open');
  const [editing, setEditing] = useState(null);
  const [viewingId, setViewingId] = useState(null);

  async function load() {
    setError('');
    const [l, p] = await Promise.all([
      supabase.from('leads').select('*').order('created_at', { ascending: false }),
      supabase.from('profiles').select('id, first_name, last_name, status'),
    ]);
    if (l.error) { console.error(l.error); setError("We couldn't load leads."); setLeads([]); return; }
    setLeads(l.data || []); setPeople(p.data || []);
    const ids = (l.data || []).map(x => x.sale_id).filter(Boolean);
    if (ids.length) {
      const s = await supabase.from('sales').select('id, sale_no, stage, total').in('id', ids);
      setSales(Object.fromEntries((s.data || []).map(x => [x.id, x])));
    }
  }
  useEffect(() => { load(); }, []);

  // a lead whose quotation became an order or invoice is won
  const stageOf = l => (l.stage !== 'lost' && ['order', 'invoice'].includes(sales[l.sale_id]?.stage) ? 'won' : l.stage);
  const here = useMemo(() => (leads || []).filter(l => inBranch(l.branch_id)), [leads, inBranch]);
  const open = here.filter(l => !['won', 'lost'].includes(stageOf(l)));
  const due = open.filter(l => l.next_follow_up && l.next_follow_up <= today);
  const month = today.slice(0, 7);
  const wonMonth = here.filter(l => stageOf(l) === 'won' && (l.updated_at || '').slice(0, 7) === month);
  const shown = here.filter(l => {
    const st = stageOf(l);
    if (stage === 'open' && ['won', 'lost'].includes(st)) return false;
    if (stage === 'due' && !(l.next_follow_up && l.next_follow_up <= today && !['won', 'lost'].includes(st))) return false;
    if (!['open', 'due', 'all'].includes(stage) && st !== stage) return false;
    const q = (search || '').trim().toLowerCase();
    return !q || `${l.name} ${l.contact_person ?? ''} ${l.phone ?? ''} ${l.site ?? ''} ${l.interest ?? ''}`.toLowerCase().includes(q);
  });
  const short = v => formatMoneyShort(v, currency);
  const personOf = id => people.find(p => p.id === id);
  const viewing = here.find(l => l.id === viewingId);

  async function makeQuotation(l) {
    setError('');
    const { data: cid, error: err } = await supabase.rpc('lead_to_customer', { p_lead: l.id });
    if (err) { setError(dbErrorMessage(err)); return; }
    navigate(`/sales?quote_for=${cid}&lead=${l.id}`);
  }

  return (
    <>
      {leads !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Open leads</span><strong>{open.length}</strong><span className="pl-help">worth about {short(open.reduce((t, l) => t + Number(l.estimated_value || 0), 0))}</span></div>
          <div className="mm-stat"><span className="pl-label">Follow-ups due</span><strong className={due.length ? 'text-warning' : ''}>{due.length}</strong><span className="pl-help">{due.length ? `${due.filter(l => l.next_follow_up < today).length} late` : 'none today'}</span></div>
          <div className="mm-stat"><span className="pl-label">Won this month</span><strong>{wonMonth.length}</strong><span className="pl-help">{here.filter(l => stageOf(l) === 'lost').length} lost in all</span></div>
        </div>
      )}
      {toolbar}
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        {[['open', 'Open'], ['due', `Due (${due.length})`], ['new', 'New'], ['contacted', 'Contacted'], ['quoted', 'Quoted'], ['won', 'Won'], ['lost', 'Lost'], ['all', 'All']].map(([k, label]) => (
          <button key={k} type="button" className={`btn btn-sm ${stage === k ? 'btn-primary' : 'btn-ghost'}`} onClick={() => setStage(k)}>{label}</button>
        ))}
        {canEdit && <button type="button" className="btn btn-primary btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setEditing({})}><Plus size={14} /> New lead</button>}
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <section className="sk">
        {leads === null ? Array.from({ length: 3 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
        : shown.length === 0 ? <div className="card"><EmptyState icon={Target} title="No leads here" description="Add contractors, sites and enquiries before they buy — with who follows up and when." /></div>
        : shown.map(l => {
          const st = stageOf(l);
          const late = l.next_follow_up && l.next_follow_up < today && !['won', 'lost'].includes(st);
          const isDue = l.next_follow_up && l.next_follow_up <= today && !['won', 'lost'].includes(st);
          return (
            <div key={l.id} className="sk-card lk-card ld-card" onClick={() => setViewingId(l.id)} onDoubleClick={() => { if (canEdit) { setViewingId(null); setEditing(l); } }}
              title="Click for details and follow-ups · double-click to edit">
              <div className="sk-name">
                <strong>{l.name}</strong>
                <span className="pl-help">{[l.contact_person, l.site].filter(Boolean).join(' · ') || SOURCE[l.source] || ''}</span>
              </div>
              <div className="sk-total">
                <span><strong>{l.estimated_value ? formatAmount(Number(l.estimated_value)) : '—'}</strong></span>
                <span className="sk-sub">{l.interest || 'interest not noted'}</span>
              </div>
              <div className="co-details">
                <span><span className={`badge ${STAGE_BADGE[st]}`}>{STAGE[st]}</span>{l.sale_id && sales[l.sale_id] ? <span className="pl-help"> · {sales[l.sale_id].sale_no}</span> : null}</span>
                <span className={late ? 'text-error' : isDue ? 'text-warning' : 'pl-help'}>
                  {['won', 'lost'].includes(st) ? (st === 'lost' ? l.lost_reason : '') : l.next_follow_up ? `Follow up ${l.next_follow_up === today ? 'today' : dateText(l.next_follow_up)}${late ? ' (late)' : ''}` : 'no follow-up planned'}
                </span>
                <span className="pl-help">{l.assigned_to ? fullName(personOf(l.assigned_to)) : 'not assigned'}</span>
              </div>
            </div>
          );
        })}
      </section>
      {editing && <LeadModal lead={editing.id ? editing : null} branchId={editing.branch_id || branchId} people={people} me={user?.id} today={today}
        onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />}
      {viewing && <LeadView lead={viewing} stage={stageOf(viewing)} sale={sales[viewing.sale_id]} people={people} canEdit={canEdit} me={user?.id} today={today} currency={currency}
        onClose={() => setViewingId(null)} onEdit={() => { setViewingId(null); setEditing(viewing); }} onChanged={load} onQuote={() => makeQuotation(viewing)} />}
    </>
  );
}

function LeadModal({ lead, branchId, people, me, today, onClose, onSaved }) {
  const [f, setF] = useState({
    name: lead?.name ?? '', contact_person: lead?.contact_person ?? '', phone: lead?.phone ?? '', email: lead?.email ?? '', site: lead?.site ?? '',
    source: lead?.source ?? '', interest: lead?.interest ?? '', estimated_value: lead?.estimated_value ?? '', assigned_to: lead?.assigned_to ?? me ?? '',
    next_follow_up: lead?.next_follow_up ?? today, notes: lead?.notes ?? '',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = patch => setF(x => ({ ...x, ...patch }));
  async function save() {
    setError('');
    if (!f.name.trim()) { setError('Enter who the lead is.'); return; }
    if (!branchId) { setError('Choose a branch first.'); return; }
    const row = {
      name: f.name.trim(), contact_person: f.contact_person.trim() || null, phone: f.phone.trim() || null, email: f.email.trim() || null, site: f.site.trim() || null,
      source: f.source || null, interest: f.interest.trim() || null, estimated_value: f.estimated_value === '' ? null : Number(f.estimated_value),
      assigned_to: f.assigned_to || null, next_follow_up: f.next_follow_up || null, notes: f.notes.trim() || null,
    };
    setBusy(true);
    const { data: org } = lead ? { data: null } : await supabase.from('branches').select('organization_id').eq('id', branchId).single();
    const { error: err } = lead ? await supabase.from('leads').update(row).eq('id', lead.id)
      : await supabase.from('leads').insert({ ...row, organization_id: org?.organization_id, branch_id: branchId, created_by: me });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={lead ? `Edit ${lead.name}` : 'New lead'} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        <div className="form-row">
          <label className="pe-field" style={{ flex: 2 }}><span>Who (person or company)</span><input className="form-input" autoFocus value={f.name} onChange={e => set({ name: e.target.value })} /></label>
          <label className="pe-field"><span>Contact person</span><input className="form-input" value={f.contact_person} onChange={e => set({ contact_person: e.target.value })} /></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Phone</span><input className="form-input" inputMode="tel" value={f.phone} onChange={e => set({ phone: e.target.value })} /></label>
          <label className="pe-field"><span>Email</span><input className="form-input" inputMode="email" value={f.email} onChange={e => set({ email: e.target.value })} /></label>
          <label className="pe-field"><span>Site</span><input className="form-input" placeholder="where the work is" value={f.site} onChange={e => set({ site: e.target.value })} /></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Came from</span>
            <select className="form-input" value={f.source} onChange={e => set({ source: e.target.value })}>
              <option value="">—</option>{Object.entries(SOURCE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select></label>
          <label className="pe-field" style={{ flex: 2 }}><span>Wants</span><input className="form-input" placeholder="e.g. 500 m² red paving, 2,000 Tofali 5&quot;" value={f.interest} onChange={e => set({ interest: e.target.value })} /></label>
          <label className="pe-field"><span>About (TZS)</span><NumberInput step="any" min="0" className="form-input" value={f.estimated_value} onChange={e => set({ estimated_value: e.target.value })} /></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Who follows up</span>
            <select className="form-input" value={f.assigned_to} onChange={e => set({ assigned_to: e.target.value })}>
              <option value="">Not assigned</option>
              {people.filter(p => p.status !== 'inactive' || p.id === f.assigned_to).map(p => <option key={p.id} value={p.id}>{fullName(p)}{p.id === me ? ' (me)' : ''}</option>)}
            </select></label>
          <label className="pe-field"><span>Next follow-up</span><input type="date" className="form-input" value={f.next_follow_up} onChange={e => set({ next_follow_up: e.target.value })} /></label>
        </div>
        <label className="pe-field"><span>Notes</span><input className="form-input" value={f.notes} onChange={e => set({ notes: e.target.value })} /></label>
      </div>
    </Modal>
  );
}

function LeadView({ lead, stage, sale, people, canEdit, me, today, currency, onClose, onEdit, onChanged, onQuote }) {
  const navigate = useNavigate();
  const [history, setHistory] = useState(null);
  const [fu, setFu] = useState({ kind: 'call', note: '', done_on: today, next_follow_up: '' });
  const [lost, setLost] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function loadHistory() {
    const { data } = await supabase.from('lead_follow_ups').select('*').eq('lead_id', lead.id).order('done_on', { ascending: false }).order('created_at', { ascending: false });
    setHistory(data || []);
  }
  useEffect(() => { loadHistory(); }, [lead.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const nameOf = id => fullName(people.find(p => p.id === id));
  async function run(q, after) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    await loadHistory(); await onChanged(); after?.();
  }
  const closed = ['won', 'lost'].includes(stage);
  return (
    <Modal title={lead.name} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        {canEdit && !closed && lost === null && <button type="button" className="btn btn-ghost" onClick={() => setLost('')}>Mark lost…</button>}
        {canEdit && stage === 'lost' && <button type="button" className="btn btn-ghost" disabled={busy} onClick={() => run(supabase.from('leads').update({ stage: 'contacted', lost_reason: null }).eq('id', lead.id))}>Reopen</button>}
        {canEdit && <button type="button" className="btn btn-outline" onClick={onEdit}>Edit</button>}
        {sale ? <button type="button" className="btn btn-outline" onClick={() => navigate('/sales')}>Quotation {sale.sale_no} ›</button>
          : canEdit && !closed && <button type="button" className="btn btn-primary" onClick={onQuote}>Make quotation</button>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button></>}>
      <div className="modal-form">
        <dl className="detail-list text-sm">
          <dt>Stage</dt><dd>{STAGE[stage]}{stage === 'lost' && lead.lost_reason ? ` — ${lead.lost_reason}` : ''}</dd>
          <dt>Contact</dt><dd>{[lead.contact_person, lead.phone, lead.email].filter(Boolean).join(' · ') || '—'}</dd>
          <dt>Site</dt><dd>{lead.site || '—'}</dd>
          <dt>Wants</dt><dd>{lead.interest || '—'}{lead.estimated_value ? ` · about ${formatMoneyShort(Number(lead.estimated_value), currency)}` : ''}</dd>
          <dt>Came from</dt><dd>{SOURCE[lead.source] || '—'}</dd>
          <dt>Follows up</dt><dd>{lead.assigned_to ? nameOf(lead.assigned_to) : 'Not assigned'}{lead.next_follow_up && !closed ? ` — next ${dateText(lead.next_follow_up)}` : ''}</dd>
          {lead.notes && <><dt>Notes</dt><dd>{lead.notes}</dd></>}
        </dl>
        {lost !== null && (
          <div className="form-row">
            <label className="pe-field" style={{ flex: 1 }}><span>Why was it lost?</span><input className="form-input" autoFocus placeholder="e.g. bought elsewhere, price, project stopped" value={lost} onChange={e => setLost(e.target.value)} /></label>
            <button type="button" className="btn btn-danger btn-sm" style={{ alignSelf: 'flex-end' }} disabled={busy || !lost.trim()}
              onClick={() => run(supabase.from('leads').update({ stage: 'lost', lost_reason: lost.trim() }).eq('id', lead.id), () => setLost(null))}>Mark lost</button>
            <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-end' }} onClick={() => setLost(null)}>Cancel</button>
          </div>
        )}
        {canEdit && !closed && (
          <div className="ld-fu">
            <span className="pl-label">Record a follow-up</span>
            <div className="form-row">
              <label className="pe-field"><span>How</span>
                <select className="form-input" value={fu.kind} onChange={e => setFu({ ...fu, kind: e.target.value })}>
                  {Object.entries(KIND).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                </select></label>
              <label className="pe-field"><span>On</span><input type="date" className="form-input" max={today} value={fu.done_on} onChange={e => setFu({ ...fu, done_on: e.target.value })} /></label>
              <label className="pe-field" style={{ flex: 2 }}><span>What was said</span><input className="form-input" value={fu.note} onChange={e => setFu({ ...fu, note: e.target.value })} /></label>
              <label className="pe-field"><span>Next follow-up</span><input type="date" className="form-input" min={today} value={fu.next_follow_up} onChange={e => setFu({ ...fu, next_follow_up: e.target.value })} /></label>
            </div>
            <button type="button" className="btn btn-primary btn-sm" disabled={busy || !fu.note.trim()}
              onClick={() => run(supabase.from('lead_follow_ups').insert({ organization_id: lead.organization_id, lead_id: lead.id, done_on: fu.done_on, kind: fu.kind, note: fu.note.trim(), next_follow_up: fu.next_follow_up || null, done_by: me }),
                () => setFu({ kind: 'call', note: '', done_on: today, next_follow_up: '' }))}>Save follow-up</button>
          </div>
        )}
        <div>
          <span className="pl-label">Follow-ups</span>
          <div className="table-container" style={{ marginTop: 6 }}>
            <table>
              <thead><tr><th>On</th><th>How</th><th>What was said</th><th>By</th><th>Next</th></tr></thead>
              <tbody>
                {history === null ? <tr><td colSpan={5}><span className="skeleton" /></td></tr>
                : history.length === 0 ? <tr><td colSpan={5} className="text-muted">No follow-ups yet.</td></tr>
                : history.map(h => <tr key={h.id}><td>{tableDate(h.done_on)}</td><td>{KIND[h.kind]}</td><td>{h.note}</td><td>{nameOf(h.done_by)}</td><td>{h.next_follow_up || ''}</td></tr>)}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Modal>
  );
}
