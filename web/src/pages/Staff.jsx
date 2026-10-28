import { useEffect, useMemo, useState } from 'react';
import { HardHat, Plus, RefreshCw } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatAmount, formatMoneyShort } from '../lib/format';
import { orgToday } from '../lib/inventory';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import { ListToolbar, PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';

const LOAD_ERROR = "We couldn't load staff. Please try again.";
const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));

// dates as 'YYYY-MM-DD', counted in UTC so a day is always a day
const addDays = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const mondayOf = d => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return addDays(d, -((w + 6) % 7)); };
const dayName = d => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', timeZone: 'UTC' });
const monthEnd = d => { const x = new Date(`${d.slice(0, 7)}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };

const KIND = { employed: 'Employed', casual: 'Casual' };
const CYCLE = { weekly: 'Weekly', fortnightly: 'Every 2 weeks', monthly: 'Monthly' };
const STATUS = { draft: 'Draft', approved: 'Approved', paid: 'Paid', void: 'Void' };
const STATUS_BADGE = { draft: 'badge-neutral', approved: 'badge-info', paid: 'badge-success', void: 'badge-error' };
// unset kind/pay follow the kind (as the pay sheet does, 071)
const basisOf = s => s.pay_basis || (s.kind === 'employed' ? 'monthly' : 'daily');
const cycleOf = s => s.pay_cycle || (s.kind === 'employed' ? 'fortnightly' : 'weekly');

/*
 * Staff & pay (1e, migration 071): the branch's staff — employed and casual —
 * with their pay; a week's attendance; and pay sheets (weekly for day-rate
 * casuals, every two weeks for monthly salaries) prepared, approved and paid.
 * A paid sheet becomes one Wages expense. Pay is seen by the Technical admin,
 * directors, branch managers and secretaries.
 *
 * 2026-10-28 (087): Employees and Casuals on their own tabs; no team on a
 * staff member — teams change day to day, so who worked is ticked on each batch.
 */
export default function Staff() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [tab, setTab] = useState('employed');
  const [staff, setStaff] = useState(null);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState(null);
  const [viewing, setViewing] = useState(null);
  const canManage = !!branchId && canAt('staff.manage', branchId);
  const canRecord = !!branchId && canAt('payroll.record', branchId);
  const canApprove = !!branchId && canAt('payroll.approve', branchId);

  async function load() {
    setError('');
    const s = await supabase.from('staff').select('*').order('full_name');
    if (s.error) { console.error(s.error); setError(LOAD_ERROR); return; }
    setStaff(s.data || []);
  }
  useEffect(() => { load(); }, []);

  const here = useMemo(() => (staff || []).filter(s => inBranch(s.branch_id)), [staff, inBranch]);
  // Employees: employed; Casuals: casual, and anyone whose kind isn't set yet (they're paid by the day until it is)
  const ofTab = s => (tab === 'employed' ? s.kind === 'employed' : s.kind !== 'employed');
  const inTab = useMemo(() => here.filter(ofTab), [here, tab]); // eslint-disable-line react-hooks/exhaustive-deps
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return inTab.filter(s => !q || `${s.full_name} ${s.job_title ?? ''} ${s.phone ?? ''}`.toLowerCase().includes(q))
      .sort((a, b) => (a.status === b.status ? 0 : a.status === 'active' ? -1 : 1));
  }, [inTab, search]);
  const working = inTab.filter(s => s.status === 'active');
  const payTotal = working.reduce((t, s) => t + Number(s.pay_rate || 0), 0);
  const noPay = working.filter(s => s.pay_rate == null).length;
  const noKind = working.filter(s => !s.kind).length;
  const inCost = working.filter(s => s.in_production_cost).length;
  const payText = s => (s.pay_rate == null ? null : `${money(s.pay_rate)} ${basisOf(s) === 'daily' ? 'a day' : 'a month'}`);

  return (
    <PageShell title="Staff" subtitle="HR"
      description={branchId ? `Employees and casual labourers at ${branchName}, and who worked each day.` : 'Staff at every branch — choose a branch to add staff or mark attendance.'}
      primaryAction={tab !== 'attendance' && canManage && <button type="button" className="btn btn-primary" onClick={() => setEditing({ kind: tab })}><Plus size={15} /> {tab === 'employed' ? 'New employee' : 'New casual'}</button>}>
      <PageTabs tabs={[['employed', 'Employees'], ['casual', 'Casuals'], ['attendance', 'Attendance']]} value={tab} onChange={t => { setTab(t); setSearch(''); }} />
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : tab !== 'attendance' ? (
        <>
          {staff !== null && (
            <div className="mm-stats">
              <div className="mm-stat"><span className="pl-label">{tab === 'employed' ? 'Employees' : 'Casuals'}</span><strong>{working.length} working</strong>
                <span className="pl-help">{tab === 'employed' ? `${inCost} in product cost` : noKind ? `${noKind} not set employed/casual` : 'paid by the day'}</span></div>
              <div className="mm-stat"><span className="pl-label">{tab === 'employed' ? 'Salaries a month' : 'Wages a full day'}</span><strong>{formatMoneyShort(payTotal, organization?.currency_code)}</strong>
                <span className="pl-help">{tab === 'employed' ? 'paid every 2 weeks' : 'all casuals at work'}</span></div>
              <div className="mm-stat"><span className="pl-label">Pay not set</span><strong className={noPay ? 'text-warning' : ''}>{noPay}</strong>
                <span className="pl-help">{noPay ? 'double-click to set' : 'everyone has pay'}</span></div>
            </div>
          )}
          <ListToolbar id="staff-search" search={search} onSearch={setSearch} placeholder="Search name, job or phone…" />
          <section className="sk">
            <div className="sk-head"><span>{tab === 'employed' ? 'Employees' : 'Casual labourers'} ({working.length} working)</span></div>
            {staff === null ? Array.from({ length: 4 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
            : shown.length === 0 ? <div className="card"><EmptyState icon={HardHat} title={tab === 'employed' ? 'No employees yet' : 'No casual labourers yet'}
                description={tab === 'employed' ? 'Add employed staff — monthly salary, paid every 2 weeks.' : 'Add casual labourers — a day rate, paid weekly. People added on a production batch appear here.'} /></div>
            : shown.map(s => (
              <div key={s.id} className={`sk-card lk-card${s.status !== 'active' ? ' is-inactive' : ''}`} onClick={() => setViewing(s)}
                onDoubleClick={() => { if (canManage) { setViewing(null); setEditing(s); } }} title="Click for details · double-click to edit">
                <div className="sk-name">
                  <strong>{s.full_name}</strong>
                  <span className="pl-help">{s.job_title || (s.kind ? KIND[s.kind] : 'kind not set')}</span>
                </div>
                <div className="sk-total">
                  {payText(s) ? <span><strong>{money(s.pay_rate)}</strong></span> : <span className="text-warning">Pay not set</span>}
                  <span className="sk-sub">{s.pay_rate == null ? '' : basisOf(s) === 'daily' ? 'a day' : 'a month'}</span>
                </div>
                <div className="co-details">
                  <span>{s.kind ? KIND[s.kind] : <span className="text-warning">Employed or casual?</span>}</span>
                  <span className="pl-help">paid {CYCLE[cycleOf(s)].toLowerCase()}</span>
                  {s.status !== 'active' && <span className="pl-help">left{s.left_on ? ` ${s.left_on}` : ''}</span>}
                </div>
              </div>
            ))}
          </section>
        </>
      ) : (
        <AttendanceWeek staff={here.filter(s => s.status === 'active')} branchId={branchId} today={today} canRecord={canRecord} />
      )}

      {viewing && (
        <Modal title={viewing.full_name} onClose={() => setViewing(null)}
          footer={<>{canManage && <button type="button" className="btn btn-outline" onClick={() => { setEditing(viewing); setViewing(null); }}>Edit</button>}
            <button type="button" className="btn btn-primary" onClick={() => setViewing(null)}>Close</button></>}>
          <dl className="detail-list text-sm">
            <dt>Kind</dt><dd>{viewing.kind ? KIND[viewing.kind] : 'Not set'}</dd>
            <dt>Job</dt><dd>{viewing.job_title || '—'}</dd>
            <dt>Pay</dt><dd>{payText(viewing) || 'Not set'}, paid {CYCLE[cycleOf(viewing)].toLowerCase()}</dd>
            <dt>In product cost</dt><dd>{viewing.in_production_cost ? 'Yes' : 'No — a running cost'}</dd>
            <dt>Phone</dt><dd>{viewing.phone || '—'}</dd>
            <dt>NSSF no.</dt><dd>{viewing.nssf_no || '—'}</dd>
            <dt>Started</dt><dd>{viewing.started_on || '—'}</dd>
            {viewing.status !== 'active' && <><dt>Left</dt><dd>{viewing.left_on || 'yes'}</dd></>}
            {viewing.notes && <><dt>Notes</dt><dd>{viewing.notes}</dd></>}
          </dl>
        </Modal>
      )}
      {editing && <StaffModal person={editing.id ? editing : null} kind={editing.id ? undefined : editing.kind} organizationId={organization?.id} branchId={editing.branch_id || branchId}
        onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />}
    </PageShell>
  );
}

function StaffModal({ person, kind: newKind, organizationId, branchId, onClose, onSaved }) {
  const [f, setF] = useState({
    full_name: person?.full_name ?? '', phone: person?.phone ?? '', kind: person?.kind ?? newKind ?? '', job_title: person?.job_title ?? '',
    pay_basis: person?.pay_basis ?? '', pay_rate: person?.pay_rate ?? '', pay_cycle: person?.pay_cycle ?? '',
    in_production_cost: person?.in_production_cost ?? true, started_on: person?.started_on ?? '', left_on: person?.left_on ?? '',
    notes: person?.notes ?? '', status: person?.status ?? 'active', nssf_no: person?.nssf_no ?? '',
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const set = patch => setF(x => ({ ...x, ...patch }));
  // choosing the kind sets the usual pay: casual → a day rate, weekly; employed → a monthly salary, every 2 weeks
  const setKind = kind => set({ kind, ...(kind === 'casual' ? { pay_basis: 'daily', pay_cycle: 'weekly' } : kind === 'employed' ? { pay_basis: 'monthly', pay_cycle: 'fortnightly' } : {}) });
  async function save() {
    setError('');
    if (!f.full_name.trim()) { setError('Enter the name.'); return; }
    if (f.pay_rate !== '' && (num(f.pay_rate) === null || num(f.pay_rate) < 0)) { setError('Enter the pay as a number.'); return; }
    if (f.status === 'left' && !f.left_on) { setError('Enter the day they left.'); return; }
    const row = {
      full_name: f.full_name.trim(), phone: f.phone.trim() || null, kind: f.kind || null, job_title: f.job_title.trim() || null,
      pay_basis: f.pay_basis || null, pay_rate: num(f.pay_rate), pay_cycle: f.pay_cycle || null,
      in_production_cost: f.in_production_cost, started_on: f.started_on || null, left_on: f.status === 'left' ? f.left_on : null,
      notes: f.notes.trim() || null, status: f.status, nssf_no: f.nssf_no.trim() || null,
    };
    setBusy(true);
    const { error: err } = person
      ? await supabase.from('staff').update(row).eq('id', person.id)
      : await supabase.from('staff').insert({ ...row, organization_id: organizationId, branch_id: branchId });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={person ? `Edit ${person.full_name}` : 'New staff member'} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        <label className="pe-field"><span>Name</span><input className="form-input" autoFocus value={f.full_name} onChange={e => set({ full_name: e.target.value })} /></label>
        <div className="form-row">
          <label className="pe-field"><span>Employed or casual</span>
            <select className="form-input" value={f.kind} onChange={e => setKind(e.target.value)}>
              <option value="">Not set</option><option value="employed">Employed</option><option value="casual">Casual</option>
            </select></label>
          <label className="pe-field"><span>Job</span><input className="form-input" placeholder="e.g. Team leader, Driver" value={f.job_title} onChange={e => set({ job_title: e.target.value })} /></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Pay</span>
            <select className="form-input" value={f.pay_basis} onChange={e => set({ pay_basis: e.target.value })}>
              <option value="">{f.kind === 'employed' ? 'A monthly salary' : 'A day rate'} (usual)</option>
              <option value="daily">A day rate</option><option value="monthly">A monthly salary</option>
            </select></label>
          <label className="pe-field"><span>Amount ({(f.pay_basis || (f.kind === 'employed' ? 'monthly' : 'daily')) === 'daily' ? 'a day' : 'a month'})</span>
            <NumberInput step="any" min="0" className="form-input" value={f.pay_rate} onChange={e => set({ pay_rate: e.target.value })} /></label>
          <label className="pe-field"><span>Paid</span>
            <select className="form-input" value={f.pay_cycle} onChange={e => set({ pay_cycle: e.target.value })}>
              <option value="">{f.kind === 'employed' ? 'Every 2 weeks' : 'Weekly'} (usual)</option>
              {Object.entries(CYCLE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select></label>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Phone</span><input className="form-input" inputMode="tel" value={f.phone} onChange={e => set({ phone: e.target.value })} /></label>
          <label className="pe-field"><span>NSSF no.</span><input className="form-input" value={f.nssf_no} onChange={e => set({ nssf_no: e.target.value })} /></label>
          <label className="pe-field"><span>Started</span><input type="date" className="form-input" value={f.started_on} onChange={e => set({ started_on: e.target.value })} /></label>
        </div>
        <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={f.in_production_cost} onChange={e => set({ in_production_cost: e.target.checked })} /> Their pay is part of product cost (untick for office/running staff)</label>
        <label className="pe-field"><span>Notes</span><input className="form-input" value={f.notes} onChange={e => set({ notes: e.target.value })} /></label>
        {person && (
          <div className="form-row">
            <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={f.status === 'left'} onChange={e => set({ status: e.target.checked ? 'left' : 'active' })} /> Has left</label>
            {f.status === 'left' && <label className="pe-field"><span>Left on</span><input type="date" className="form-input" value={f.left_on} onChange={e => set({ left_on: e.target.value })} /></label>}
          </div>
        )}
      </div>
    </Modal>
  );
}

/* A week of attendance: click a day to cycle — worked a full day, half a day, not there */
function AttendanceWeek({ staff, branchId, today, canRecord }) {
  const [monday, setMonday] = useState(() => mondayOf(today));
  const [marks, setMarks] = useState(null);       // `${staff_id}|${date}` → day_fraction
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const days = Array.from({ length: 7 }, (_, i) => addDays(monday, i));
  const sunday = days[6];

  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('staff_attendance').select('staff_id, work_date, day_fraction')
      .gte('work_date', monday).lte('work_date', sunday);
    if (err) { console.error(err); setError("We couldn't load attendance."); return; }
    setMarks(Object.fromEntries((data || []).map(a => [`${a.staff_id}|${a.work_date}`, Number(a.day_fraction)])));
  }
  useEffect(() => { load(); }, [monday]);

  async function mark(staffId, date, fraction) {
    setBusy(`${staffId}|${date}`); setError('');
    const { error: err } = await supabase.rpc('set_attendance', { p: { staff_id: staffId, work_date: date, day_fraction: fraction } });
    setBusy('');
    if (err) { setError(dbErrorMessage(err)); return; }
    setMarks(m => { const n = { ...m }; if (fraction) n[`${staffId}|${date}`] = fraction; else delete n[`${staffId}|${date}`]; return n; });
  }
  const next = v => (v === 1 ? 0.5 : v === 0.5 ? 0 : 1);

  // who worked on a day, from that day's batches (the people ticked on each, 087)
  async function fillFromProduction(date) {
    setError('');
    const { data: batches, error: err } = await supabase.from('production_batches').select('worker_ids')
      .eq('branch_id', branchId).eq('batch_date', date).neq('status', 'void');
    if (err) { setError(dbErrorMessage(err)); return; }
    const ids = new Set((batches || []).flatMap(b => b.worker_ids || []));
    if (!ids.size) { setError(`No production with people ticked on ${date}.`); return; }
    for (const id of ids) if (!marks?.[`${id}|${date}`] && staff.some(s => s.id === id)) await mark(id, date, 1);
  }

  const totalOf = id => days.reduce((t, d) => t + (marks?.[`${id}|${d}`] || 0), 0);
  return (
    <>
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        <button type="button" className="btn btn-outline btn-sm" onClick={() => setMonday(addDays(monday, -7))}>‹ Week before</button>
        <strong>{monday} – {sunday}</strong>
        <button type="button" className="btn btn-outline btn-sm" disabled={addDays(monday, 7) > today} onClick={() => setMonday(addDays(monday, 7))}>Week after ›</button>
        <span className="pl-help" style={{ marginLeft: 'auto' }}>{canRecord ? 'Click a day: ✓ full day → ½ half day → empty.' : branchId ? 'You can see attendance here.' : 'Choose a branch to mark attendance.'}</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="card"><div className="table-container">
        <table className="at-table">
          <thead><tr><th>Name</th>{days.map(d => (
            <th key={d} className="at-day">{dayName(d)}
              {canRecord && d <= today && <button type="button" className="at-fill" title="Tick everyone who worked in that day's production" onClick={() => fillFromProduction(d)}>from production</button>}
            </th>))}<th className="num">Days</th></tr></thead>
          <tbody>
            {staff.length === 0 ? <tr><td colSpan={9} className="text-muted">No staff yet — add them under Staff.</td></tr>
            : [...staff].sort((a, b) => (a.kind === b.kind ? a.full_name.localeCompare(b.full_name) : a.kind === 'casual' ? -1 : 1)).map(s => (
              <tr key={s.id}>
                <td><strong>{s.full_name}</strong><div className="pl-help">{s.kind ? KIND[s.kind] : ''}{s.job_title ? ` · ${s.job_title}` : ''}</div></td>
                {days.map(d => {
                  const v = marks?.[`${s.id}|${d}`]; const k = `${s.id}|${d}`;
                  return (
                    <td key={d} className="at-cell">
                      <button type="button" className={`at-mark${v === 1 ? ' is-full' : v === 0.5 ? ' is-half' : ''}`} disabled={!canRecord || d > today || busy === k || marks === null}
                        onClick={() => mark(s.id, d, next(v))} aria-label={`${s.full_name} ${d}`}>{v === 1 ? '✓' : v === 0.5 ? '½' : ''}</button>
                    </td>
                  );
                })}
                <td className="num"><strong>{totalOf(s.id) || ''}</strong></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div></div>
    </>
  );
}

/* Pay sheets: prepared from the staff list and attendance, then approved and paid */
function PaySheets({ staff, branchId, today, money, canRecord, canApprove, inBranch }) {
  const [sheets, setSheets] = useState(null);
  const [error, setError] = useState('');
  const [preparing, setPreparing] = useState(false);
  const [openId, setOpenId] = useState(null);
  async function load() {
    setError('');
    const { data, error: err } = await supabase.from('pay_sheets').select('*, pay_sheet_lines(count)')
      .order('period_start', { ascending: false }).order('created_at', { ascending: false });
    if (err) { console.error(err); setError("We couldn't load pay sheets."); return; }
    setSheets(data || []);
  }
  useEffect(() => { load(); }, []);
  const here = (sheets || []).filter(s => inBranch(s.branch_id));
  return (
    <>
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        {canRecord && <button type="button" className="btn btn-primary btn-sm" onClick={() => setPreparing(true)}><Plus size={14} /> Prepare pay sheet</button>}
        <span className="pl-help">Casuals: days worked × day rate, weekly. Employed: half the monthly salary every 2 weeks. A paid sheet is recorded as one Wages expense.</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Period</th><th>Pay</th><th className="num">People</th><th className="num">Total (TZS)</th><th>Status</th><th>Paid on</th></tr></thead>
          <tbody>
            {sheets === null ? <tr><td colSpan={6}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={6} className="text-muted">No pay sheets yet.</td></tr>
            : here.map(s => (
              <tr key={s.id} className={`clickable-row${s.status === 'void' ? ' is-inactive' : ''}`} onClick={() => setOpenId(s.id)}>
                <td>{s.period_start} – {s.period_end}</td>
                <td>{CYCLE[s.cycle]}</td>
                <td className="num">{s.pay_sheet_lines?.[0]?.count ?? ''}</td>
                <td className="num">{formatAmount(Number(s.total))}</td>
                <td><span className={`badge ${STATUS_BADGE[s.status]}`}>{STATUS[s.status]}</span></td>
                <td>{s.paid_on || ''}</td>
              </tr>
            ))}
          </tbody>
          {here.some(s => s.status === 'paid') && (
            <tfoot><tr><td colSpan={3}><strong>Paid</strong></td><td className="num"><strong>{money(here.filter(s => s.status === 'paid').reduce((t, s) => t + Number(s.total), 0))}</strong></td><td colSpan={2} /></tr></tfoot>
          )}
        </table>
      </div></div>
      {preparing && <PrepareModal branchId={branchId} today={today} onClose={() => setPreparing(false)}
        onMade={async id => { setPreparing(false); await load(); setOpenId(id); }} />}
      {openId && <SheetModal id={openId} staff={staff} money={money} today={today} canRecord={canRecord} canApprove={canApprove}
        onClose={() => setOpenId(null)} onChanged={load} />}
    </>
  );
}

function PrepareModal({ branchId, today, onClose, onMade }) {
  const periodOf = (cycle, d) => {
    if (cycle === 'weekly') { const m = mondayOf(d); return [m, addDays(m, 6)]; }
    if (cycle === 'monthly') return [`${d.slice(0, 7)}-01`, monthEnd(d)];
    return Number(d.slice(8)) <= 15 ? [`${d.slice(0, 7)}-01`, `${d.slice(0, 7)}-15`] : [`${d.slice(0, 7)}-16`, monthEnd(d)];
  };
  const [cycle, setCycle] = useState('weekly');
  const [[start, end], setPeriod] = useState(() => periodOf('weekly', today));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function make() {
    setError(''); setBusy(true);
    const { data, error: err } = await supabase.rpc('prepare_pay_sheet', { p_branch: branchId, p_cycle: cycle, p_start: start, p_end: end });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onMade(data);
  }
  return (
    <Modal title="Prepare pay sheet" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !branchId} onClick={make}>Prepare</button></>}>
      <div className="modal-form">
        {!branchId && <div className="alert alert-warning">Choose a branch first.</div>}
        <label className="pe-field"><span>Who it pays</span>
          <select className="form-input" value={cycle} onChange={e => { setCycle(e.target.value); setPeriod(periodOf(e.target.value, today)); }}>
            <option value="weekly">Weekly — staff paid weekly (casuals)</option>
            <option value="fortnightly">Every 2 weeks — staff paid every 2 weeks (employed)</option>
            <option value="monthly">Monthly — staff paid monthly</option>
          </select></label>
        <div className="form-row">
          <label className="pe-field"><span>From</span><input type="date" className="form-input" value={start} onChange={e => setPeriod([e.target.value, end])} /></label>
          <label className="pe-field"><span>To</span><input type="date" className="form-input" value={end} onChange={e => setPeriod([start, e.target.value])} /></label>
        </div>
        <p className="pl-help">Everyone paid {CYCLE[cycle].toLowerCase()} is put on it: day-rate staff with the days marked in Attendance, salaried staff with their share of the salary. You can add or deduct amounts before approving.</p>
      </div>
    </Modal>
  );
}

function SheetModal({ id, staff, money, today, canRecord, canApprove, onClose, onChanged }) {
  const [sheet, setSheet] = useState(null);
  const [lines, setLines] = useState([]);
  const [accounts, setAccounts] = useState([]);
  const [edits, setEdits] = useState({});       // line id → { additions, deductions, note }
  const [pay, setPay] = useState({ paid_on: today, account_id: '' });
  const [voidReason, setVoidReason] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function load() {
    const [s, l] = await Promise.all([
      supabase.from('pay_sheets').select('*').eq('id', id).single(),
      supabase.from('pay_sheet_lines').select('*').eq('sheet_id', id),
    ]);
    if (s.error) { setError(dbErrorMessage(s.error)); return; }
    setSheet(s.data); setLines(l.data || []); setEdits({});
    const a = await supabase.from('payment_accounts').select('id, name, status').eq('branch_id', s.data.branch_id).order('display_order');
    setAccounts((a.data || []).filter(x => x.status === 'active'));
  }
  useEffect(() => { load(); }, [id]);
  const nameOf = sid => staff.find(s => s.id === sid)?.full_name ?? '';
  const draft = sheet?.status === 'draft';
  const run = async (fn, after) => {
    setError(''); setBusy(true);
    const { error: err } = await fn();
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return false; }
    await load(); onChanged(); after?.();
    return true;
  };
  async function saveEdits() {
    for (const [lineId, e] of Object.entries(edits)) {
      const ok = await run(() => supabase.rpc('update_pay_sheet_line', { p_line: lineId, p: e }));
      if (!ok) return false;
    }
    return true;
  }
  const val = (l, k) => edits[l.id]?.[k] ?? (k === 'note' ? l.note ?? '' : String(Number(l[k]) || ''));
  const setVal = (l, k, v) => setEdits(m => ({ ...m, [l.id]: { ...(m[l.id] || {}), [k]: v } }));
  const amountOf = l => Math.max(Number(l.base) + (num(val(l, 'additions')) || 0) - (num(val(l, 'deductions')) || 0), 0);
  const total = lines.reduce((t, l) => t + amountOf(l), 0);
  const sorted = [...lines].sort((a, b) => (a.pay_basis === b.pay_basis ? nameOf(a.staff_id).localeCompare(nameOf(b.staff_id)) : a.pay_basis === 'daily' ? -1 : 1));
  const missing = lines.filter(l => l.rate == null);
  if (!sheet) return <Modal title="Pay sheet" onClose={onClose}>{error ? <div className="alert alert-error">{error}</div> : <span className="skeleton" />}</Modal>;
  return (
    <Modal title={`${CYCLE[sheet.cycle]} pay · ${sheet.period_start} – ${sheet.period_end}`} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        {sheet.status !== 'void' && (sheet.status === 'draft' ? canRecord : canApprove) && voidReason === null &&
          <button type="button" className="btn btn-ghost" onClick={() => setVoidReason('')}>Void…</button>}
        {draft && canRecord && <button type="button" className="btn btn-outline" disabled={busy} onClick={async () => { if (await saveEdits()) run(() => supabase.rpc('refresh_pay_sheet', { p_sheet: id })); }}><RefreshCw size={14} /> Refresh from attendance</button>}
        {draft && canRecord && Object.keys(edits).length > 0 && <button type="button" className="btn btn-outline" disabled={busy} onClick={saveEdits}>Save changes</button>}
        {draft && canApprove && <button type="button" className="btn btn-primary" disabled={busy || missing.length > 0} onClick={async () => { if (await saveEdits()) run(() => supabase.rpc('approve_pay_sheet', { p_sheet: id })); }}>Approve {money(total)}</button>}
        {sheet.status === 'approved' && canApprove && <button type="button" className="btn btn-primary" disabled={busy} onClick={() => run(() => supabase.rpc('pay_pay_sheet', { p_sheet: id, p: pay }))}>Mark paid {money(Number(sheet.total))}</button>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button></>}>
      <div className="modal-form">
        <p className="text-sm">Status: <strong>{STATUS[sheet.status]}</strong>{sheet.paid_on ? ` on ${sheet.paid_on} — recorded as a Wages expense` : ''}{sheet.void_reason ? ` — ${sheet.void_reason}` : ''}</p>
        {missing.length > 0 && <div className="alert alert-warning">Pay not set for {missing.map(l => nameOf(l.staff_id)).join(', ')} — set it under Staff, then Refresh.</div>}
        <div className="table-container">
          <table className="ps-table">
            <thead><tr><th>Name</th><th className="num">Days</th><th className="num">Rate (TZS)</th><th className="num">Pay (TZS)</th><th className="num">Add (TZS)</th><th className="num">Deduct (TZS)</th><th className="num">Amount (TZS)</th><th>Note</th></tr></thead>
            <tbody>
              {sorted.length === 0 ? <tr><td colSpan={8} className="text-muted">No one on this sheet — mark attendance or set staff pay, then Refresh.</td></tr>
              : sorted.map(l => (
                <tr key={l.id}>
                  <td><strong>{nameOf(l.staff_id)}</strong></td>
                  <td className="num">{l.pay_basis === 'daily' ? Number(l.days || 0) : <span className="pl-help">salary</span>}</td>
                  <td className="num">{l.rate == null ? <span className="text-warning">not set</span> : <>{formatAmount(Number(l.rate))}<span className="pl-help"> {l.pay_basis === 'daily' ? '/day' : '/month'}</span></>}</td>
                  <td className="num">{formatAmount(Number(l.base))}</td>
                  {draft && canRecord ? <>
                    <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} value={val(l, 'additions')} onChange={e => setVal(l, 'additions', e.target.value)} /></td>
                    <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} value={val(l, 'deductions')} onChange={e => setVal(l, 'deductions', e.target.value)} /></td>
                  </> : <>
                    <td className="num">{Number(l.additions) ? formatAmount(Number(l.additions)) : ''}</td>
                    <td className="num">{Number(l.deductions) ? formatAmount(Number(l.deductions)) : ''}</td>
                  </>}
                  <td className="num"><strong>{formatAmount(amountOf(l))}</strong></td>
                  <td>{draft && canRecord ? <input className="form-input" style={{ width: 140 }} placeholder="e.g. advance" value={val(l, 'note')} onChange={e => setVal(l, 'note', e.target.value)} /> : l.note || ''}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td colSpan={6}><strong>Total</strong></td><td className="num"><strong>{money(total)}</strong></td><td /></tr></tfoot>
          </table>
        </div>
        {sheet.status === 'approved' && canApprove && (
          <div className="form-row">
            <label className="pe-field"><span>Paid on</span><input type="date" className="form-input" max={today} value={pay.paid_on} onChange={e => setPay({ ...pay, paid_on: e.target.value })} /></label>
            <label className="pe-field"><span>Paid from</span>
              <select className="form-input" value={pay.account_id} onChange={e => setPay({ ...pay, account_id: e.target.value })}>
                <option value="">Cash</option>{accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
              </select></label>
          </div>
        )}
        {voidReason !== null && (
          <div className="form-row">
            <label className="pe-field" style={{ flex: 1 }}><span>Why void it?{sheet.status === 'paid' ? ' (its Wages expense is voided too)' : ''}</span>
              <input className="form-input" autoFocus value={voidReason} onChange={e => setVoidReason(e.target.value)} /></label>
            <button type="button" className="btn btn-danger" disabled={busy || !voidReason.trim()} onClick={() => run(() => supabase.rpc('void_pay_sheet', { p_sheet: id, p_reason: voidReason }), () => setVoidReason(null))}>Void sheet</button>
            <button type="button" className="btn btn-ghost" onClick={() => setVoidReason(null)}>Cancel</button>
          </div>
        )}
      </div>
    </Modal>
  );
}
