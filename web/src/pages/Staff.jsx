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
import StatutoryRatesCard, { RATE_NAME } from '../components/staff/StatutoryRatesCard';
import AdvancesPanel from '../components/staff/AdvancesPanel';
import StatutoryReturns from '../components/staff/StatutoryReturns';

const LOAD_ERROR = "We couldn't load staff. Please try again.";
const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));

// dates as 'YYYY-MM-DD', counted in UTC so a day is always a day
const addDays = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const mondayOf = d => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return addDays(d, -((w + 6) % 7)); };
const dayName = d => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', timeZone: 'UTC' });

const KIND = { employed: 'Employed', casual: 'Casual' };
const CYCLE = { weekly: 'Weekly', fortnightly: 'Every 2 weeks', monthly: 'Monthly' };
const STATUS = { draft: 'Draft', approved: 'Approved', paid: 'Paid', void: 'Void' };
const STATUS_BADGE = { draft: 'badge-neutral', approved: 'badge-info', paid: 'badge-success', void: 'badge-error' };
// unset kind/pay follow the kind (as the pay sheet does, 071)
const basisOf = s => s.pay_basis || (s.kind === 'employed' ? 'monthly' : 'daily');
const cycleOf = s => s.pay_cycle || (s.kind === 'employed' ? 'fortnightly' : 'weekly');
// a monthly salary counted by the day: working days a month (089 setting; 26 until set)
const WORK_DAYS_DEFAULT = 26;

/*
 * Staff & pay (1e, migration 071): the branch's staff — employed and casual —
 * with their pay; a week's attendance; and pay sheets (weekly for day-rate
 * casuals, every two weeks for monthly salaries) prepared, approved and paid.
 * A paid sheet becomes one Wages expense. Pay is seen by the Technical admin,
 * directors, branch managers and secretaries.
 *
 * 2026-10-28 (087): Employees and Casuals on their own tabs; no team on a
 * staff member — teams change day to day, so who worked is ticked on each batch.
 * Part 2 (088): pay sheets with NSSF, PAYE, WCF and SDL from the statutory
 * rates (⚙, confirmed by the Technical admin or a director), and payslips.
 * 090: Advances (taken back on the sheets) and Returns (PAYE, NSSF, SDL, WCF
 * of the month's paid sheets).
 * 089: pay sheets make themselves from attendance — everyone paid by the days
 * attended (a salary ÷ working days a month); they are approved and paid.
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
  const [settings, setSettings] = useState(false);   // ⚙: statutory rates (088)
  const [att, setAtt] = useState({});   // `${staff_id}|${date}` → day fraction, this week and month (the cards)
  const [attBusy, setAttBusy] = useState('');
  const [workDays, setWorkDays] = useState(WORK_DAYS_DEFAULT);
  useEffect(() => {
    supabase.from('payroll_settings').select('work_days_a_month').maybeSingle()
      .then(({ data }) => { if (data?.work_days_a_month) setWorkDays(Number(data.work_days_a_month)); });
  }, [settings]);
  const monday = mondayOf(today);
  const week = Array.from({ length: 7 }, (_, i) => addDays(monday, i));
  const attFrom = [monday, `${today.slice(0, 7)}-01`].sort()[0];
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
  async function loadAtt() {
    const { data } = await supabase.from('staff_attendance').select('staff_id, work_date, day_fraction').gte('work_date', attFrom).lte('work_date', addDays(monday, 6));
    setAtt(Object.fromEntries((data || []).map(a => [`${a.staff_id}|${a.work_date}`, Number(a.day_fraction)])));
  }
  useEffect(() => { if (tab === 'employed' || tab === 'casual') loadAtt(); }, [tab, attFrom]); // eslint-disable-line react-hooks/exhaustive-deps
  // a day on the card: ✓ full → ½ half → empty (as on Attendance)
  async function markDay(e, sid, d) {
    e.stopPropagation();
    const k = `${sid}|${d}`; const v = att[k]; const fr = v === 1 ? 0.5 : v === 0.5 ? 0 : 1;
    setAttBusy(k); setError('');
    const { error: err } = await supabase.rpc('set_attendance', { p: { staff_id: sid, work_date: d, day_fraction: fr } });
    setAttBusy('');
    if (err) { setError(dbErrorMessage(err)); return; }
    setAtt(m => { const n = { ...m }; if (fr) n[k] = fr; else delete n[k]; return n; });
  }
  const daysIn = (sid, from, to) => Object.entries(att).reduce((t, [k, v]) => { const [id, d] = k.split('|'); return id === sid && d >= from && d <= to ? t + v : t; }, 0);

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
    <PageShell title="Staff" subtitle="HR" onSettings={() => setSettings(true)}
      description={branchId ? `Employees and casual labourers at ${branchName}, and who worked each day.` : 'Staff at every branch — choose a branch to add staff or mark attendance.'}
      primaryAction={(tab === 'employed' || tab === 'casual') && canManage && <button type="button" className="btn btn-primary" onClick={() => setEditing({ kind: tab })}><Plus size={15} /> {tab === 'employed' ? 'New employee' : 'New casual'}</button>}>
      <PageTabs tabs={[['employed', 'Employees'], ['casual', 'Casuals'], ['attendance', 'Attendance'], ['pay', 'Pay sheets'], ['advances', 'Advances'], ['returns', 'Returns']]} value={tab} onChange={t => { setTab(t); setSearch(''); }} />
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : tab === 'advances' ? (
        <AdvancesPanel staff={staff || []} branchId={branchId} today={today} money={money} currency={organization?.currency_code} canRecord={canRecord} canApprove={canApprove} inBranch={inBranch} />
      ) : tab === 'returns' ? (
        <StatutoryReturns staff={staff || []} today={today} currency={organization?.currency_code} inBranch={inBranch} />
      ) : tab === 'pay' ? (
        <PaySheets staff={staff || []} branchId={branchId} today={today} money={money} currency={organization?.currency_code} canRecord={canRecord} canApprove={canApprove} inBranch={inBranch} />
      ) : tab !== 'attendance' ? (
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
              <div key={s.id} className={`sk-card lk-card st-card${s.status !== 'active' ? ' is-inactive' : ''}`} onClick={() => setViewing(s)}
                onDoubleClick={() => { if (canManage) { setViewing(null); setEditing(s); } }} title="Click for details · double-click to edit">
                <div className="sk-name">
                  <strong>{s.full_name}</strong>
                  <span className="pl-help">{s.job_title || (s.kind ? KIND[s.kind] : 'kind not set')}</span>
                </div>
                <div className="sk-total">
                  {s.pay_rate == null ? <span className="text-warning">Pay not set</span> : (() => {
                    // earned so far: casuals this week (days × day rate); employed this month (days × salary ÷ 26 working days)
                    const daily = basisOf(s) === 'daily';
                    const days = daysIn(s.id, daily ? monday : `${today.slice(0, 7)}-01`, today);
                    const due = days * Number(s.pay_rate) / (daily ? 1 : workDays);
                    return <>
                      <strong title={daily ? 'Days this week × day rate' : `Days this month × salary ÷ ${workDays} working days`}>{money(Math.round(due))}</strong>
                      <span className="sk-sub">{days} day{days === 1 ? '' : 's'} this {daily ? 'week' : 'month'}</span>
                      <span className="sk-sub">{money(s.pay_rate)} {daily ? 'a day' : 'a month'}</span>
                    </>;
                  })()}
                </div>
                <div className="co-details">
                  <span>{s.kind ? KIND[s.kind] : <span className="text-warning">Employed or casual?</span>}</span>
                  <span className="pl-help">paid {CYCLE[cycleOf(s)].toLowerCase()}</span>
                  {s.status !== 'active' && <span className="pl-help">left{s.left_on ? ` ${s.left_on}` : ''}</span>}
                </div>
                <div className="st-att" onDoubleClick={e => e.stopPropagation()}>
                  <div className="st-week">
                    {week.map(d => {
                      const k = `${s.id}|${d}`; const v = att[k];
                      return (
                        <button key={d} type="button" className={`st-day at-mark${v === 1 ? ' is-full' : v === 0.5 ? ' is-half' : ''}${d === today ? ' is-today' : ''}`}
                          disabled={!canRecord || d > today || attBusy === k || s.status !== 'active'} title={`${dayName(d)}${canRecord && d <= today ? ' — click: ✓ full, ½ half, empty' : ''}`}
                          onClick={e => markDay(e, s.id, d)}>
                          <span className="st-dname">{dayName(d)}</span>{v === 1 ? '✓' : v === 0.5 ? '½' : d > today ? '' : '·'}
                        </button>
                      );
                    })}
                  </div>
                  <span className="pl-help st-att-sum">{daysIn(s.id, monday, today)} days this week · {daysIn(s.id, `${today.slice(0, 7)}-01`, today)} this month</span>
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
            <dt>Statutory deductions</dt><dd>{(viewing.statutory ?? viewing.kind === 'employed') ? 'NSSF, PAYE (employer: NSSF, WCF, SDL)' : 'None'}{viewing.statutory == null ? ' — as for their kind' : ''}</dd>
            <dt>In product cost</dt><dd>{viewing.in_production_cost ? 'Yes' : 'No — a running cost'}</dd>
            <dt>Phone</dt><dd>{viewing.phone || '—'}</dd>
            <dt>NSSF no.</dt><dd>{viewing.nssf_no || '—'}</dd>
            <dt>Started</dt><dd>{viewing.started_on || '—'}</dd>
            {viewing.status !== 'active' && <><dt>Left</dt><dd>{viewing.left_on || 'yes'}</dd></>}
            {viewing.notes && <><dt>Notes</dt><dd>{viewing.notes}</dd></>}
          </dl>
        </Modal>
      )}
      {settings && (
        <Modal title="Staff & payroll settings" onClose={() => setSettings(false)} size="lg"
          footer={<button type="button" className="btn btn-outline" onClick={() => setSettings(false)}>Close</button>}>
          <StatutoryRatesCard />
          <WorkDaysCard />
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
    statutory: person?.statutory == null ? '' : person.statutory ? 'yes' : 'no',
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
      ...(f.statutory !== '' || person?.statutory != null ? { statutory: f.statutory === '' ? null : f.statutory === 'yes' } : {}),
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
        <label className="pe-field"><span>Statutory deductions (NSSF, PAYE; employer WCF, SDL)</span>
          <select className="form-input" value={f.statutory} onChange={e => set({ statutory: e.target.value })}>
            <option value="">{f.kind === 'employed' ? 'Yes' : 'No'} — as for {f.kind === 'employed' ? 'employed staff' : 'casuals'} (usual)</option>
            <option value="yes">Yes</option><option value="no">No</option>
          </select></label>
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
function PaySheets({ staff, branchId, today, money, currency, canRecord, canApprove, inBranch }) {
  const [sheets, setSheets] = useState(null);
  const [error, setError] = useState('');
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
  const month = today.slice(0, 7);
  const paidMonth = here.filter(s => s.status === 'paid' && (s.paid_on || '').startsWith(month));
  const sum = (list, f) => list.reduce((t, s) => t + Number(s[f] || 0), 0);
  const waiting = here.filter(s => s.status === 'draft' || s.status === 'approved');
  const short = v => formatMoneyShort(v, currency);
  return (
    <>
      {sheets !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Paid this month</span><strong>{short(sum(paidMonth, 'total'))}</strong>
            <span className="pl-help" title="Net pay handed to staff on sheets paid this month">net · gross {short(sum(paidMonth, 'gross_total'))}</span></div>
          <div className="mm-stat"><span className="pl-label">Statutory this month</span><strong>{short(sum(paidMonth, 'employee_statutory') + sum(paidMonth, 'employer_statutory'))}</strong>
            <span className="pl-help" title="PAYE and NSSF taken from pay, plus the employer's NSSF, WCF and SDL — recorded as a Statutory contributions expense, owed until remitted">PAYE · NSSF · WCF · SDL to remit</span></div>
          <div className="mm-stat"><span className="pl-label">Waiting</span><strong className={waiting.length ? 'text-warning' : ''}>{waiting.length}</strong>
            <span className="pl-help">{waiting.length ? `${waiting.filter(s => s.status === 'draft').length} to approve · ${waiting.filter(s => s.status === 'approved').length} to pay` : 'nothing waiting'}</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
        <span className="pl-help" title="Marking attendance keeps the period's draft up to date: casuals weekly (Mon–Sun), employed every 2 weeks (1–15, 16–end). Casuals: days × day rate. Employed: days × salary ÷ working days a month (⚙). NSSF and PAYE come off gross pay; the employer adds NSSF, WCF and SDL. Paid: net pay is one Wages expense, the statutory amounts one Statutory contributions expense (owed until remitted).">Made automatically from attendance — open a sheet to approve and pay it. NSSF, PAYE, WCF and SDL from the rates (⚙).</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Period</th><th>Pay</th><th className="num">People</th><th className="num">Gross (TZS)</th><th className="num">PAYE + NSSF (TZS)</th><th className="num">Net (TZS)</th><th>Status</th><th>Paid on</th></tr></thead>
          <tbody>
            {sheets === null ? <tr><td colSpan={8}><span className="skeleton" /></td></tr>
            : here.length === 0 ? <tr><td colSpan={8} className="text-muted">No pay sheets yet.</td></tr>
            : here.map(s => (
              <tr key={s.id} className={`clickable-row${s.status === 'void' ? ' is-inactive' : ''}`} onClick={() => setOpenId(s.id)}>
                <td>{s.period_start} – {s.period_end}</td>
                <td>{CYCLE[s.cycle]}</td>
                <td className="num">{s.pay_sheet_lines?.[0]?.count ?? ''}</td>
                <td className="num">{formatAmount(Number(s.gross_total || s.total))}</td>
                <td className="num">{Number(s.employee_statutory) ? formatAmount(Number(s.employee_statutory)) : ''}</td>
                <td className="num"><strong>{formatAmount(Number(s.total))}</strong></td>
                <td><span className={`badge ${STATUS_BADGE[s.status]}`}>{STATUS[s.status]}</span>
                  {s.status === 'draft' && s.rates_unverified?.length > 0 && <div className="pl-help text-warning">rates to verify</div>}</td>
                <td>{s.paid_on || ''}</td>
              </tr>
            ))}
          </tbody>
          {here.some(s => s.status === 'paid') && (
            <tfoot><tr><td colSpan={5}><strong>Paid</strong></td><td className="num"><strong>{money(here.filter(s => s.status === 'paid').reduce((t, s) => t + Number(s.total), 0))}</strong></td><td colSpan={2} /></tr></tfoot>
          )}
        </table>
      </div></div>
      {openId && <SheetModal id={openId} staff={staff} money={money} today={today} canRecord={canRecord} canApprove={canApprove}
        onClose={() => setOpenId(null)} onChanged={load} />}
    </>
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
  // net as typed: NSSF and PAYE as last worked out (they follow the additions once saved)
  const grossOf = l => Number(l.base) + (num(val(l, 'additions')) || 0);
  const amountOf = l => Math.max(grossOf(l) - Number(l.nssf_employee || 0) - Number(l.paye || 0) - (num(val(l, 'deductions')) || 0) - Number(l.advance_deductions || 0), 0);
  const total = lines.reduce((t, l) => t + amountOf(l), 0);
  const sorted = [...lines].sort((a, b) => (a.pay_basis === b.pay_basis ? nameOf(a.staff_id).localeCompare(nameOf(b.staff_id)) : a.pay_basis === 'daily' ? -1 : 1));
  const missing = lines.filter(l => l.rate == null);
  const unverified = sheet?.rates_unverified || [];
  const tot = f => lines.reduce((t, l) => t + Number(l[f] || 0), 0);
  if (!sheet) return <Modal title="Pay sheet" onClose={onClose}>{error ? <div className="alert alert-error">{error}</div> : <span className="skeleton" />}</Modal>;
  return (
    <Modal title={`${CYCLE[sheet.cycle]} pay · ${sheet.period_start} – ${sheet.period_end}`} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        {sheet.status !== 'void' && (sheet.status === 'draft' ? canRecord : canApprove) && voidReason === null &&
          <button type="button" className="btn btn-ghost" onClick={() => setVoidReason('')}>Void…</button>}
        {draft && canRecord && <button type="button" className="btn btn-outline" disabled={busy} onClick={async () => { if (await saveEdits()) run(() => supabase.rpc('refresh_pay_sheet', { p_sheet: id })); }}><RefreshCw size={14} /> Refresh</button>}
        {draft && canRecord && Object.keys(edits).length > 0 && <button type="button" className="btn btn-outline" disabled={busy} onClick={saveEdits}>Save changes</button>}
        {draft && canApprove && <button type="button" className="btn btn-primary" disabled={busy || missing.length > 0 || unverified.length > 0} onClick={async () => { if (await saveEdits()) run(() => supabase.rpc('approve_pay_sheet', { p_sheet: id })); }}>Approve {money(total)}</button>}
        {sheet.status === 'approved' && canApprove && <button type="button" className="btn btn-primary" disabled={busy} onClick={() => run(() => supabase.rpc('pay_pay_sheet', { p_sheet: id, p: pay }))}>Mark paid {money(Number(sheet.total))}</button>}
        {lines.length > 0 && <a className="btn btn-outline" href={`/print/payslips/${id}`} target="_blank" rel="noreferrer">Payslips</a>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button></>}>
      <div className="modal-form">
        <p className="text-sm">Status: <strong>{STATUS[sheet.status]}</strong>{sheet.paid_on ? ` on ${sheet.paid_on} — net pay recorded as a Wages expense${sheet.statutory_expense_id ? ', PAYE/NSSF/WCF/SDL as a Statutory contributions expense (owed until remitted)' : ''}` : ''}{sheet.void_reason ? ` — ${sheet.void_reason}` : ''}</p>
        {draft && unverified.length > 0 && <div className="alert alert-warning">Rates to verify: {unverified.map(c => RATE_NAME[c]).join(', ')}. The Technical admin or a director checks them with TRA / NSSF / WCF and confirms them under ⚙ — then Refresh and approve.</div>}
        {missing.length > 0 && <div className="alert alert-warning">Pay not set for {missing.map(l => nameOf(l.staff_id)).join(', ')} — set it under Staff, then Refresh.</div>}
        <div className="table-container">
          <table className="ps-table">
            <thead><tr><th>Name</th><th className="num">Days</th><th className="num">Rate (TZS)</th><th className="num">Pay (TZS)</th><th className="num">Add (TZS)</th><th className="num">Gross (TZS)</th><th className="num">NSSF (TZS)</th><th className="num">PAYE (TZS)</th><th className="num">Other deductions (TZS)</th><th className="num">Advances (TZS)</th><th className="num">Net (TZS)</th><th>Note</th></tr></thead>
            <tbody>
              {sorted.length === 0 ? <tr><td colSpan={12} className="text-muted">No one on this sheet — no days attended in the period.</td></tr>
              : sorted.map(l => (
                <tr key={l.id}>
                  <td><strong>{nameOf(l.staff_id)}</strong></td>
                  <td className="num">{l.pay_basis === 'daily' ? Number(l.days || 0) : <span className="pl-help">salary</span>}</td>
                  <td className="num">{l.rate == null ? <span className="text-warning">not set</span> : <>{formatAmount(Number(l.rate))}<span className="pl-help"> {l.pay_basis === 'daily' ? '/day' : '/month'}</span></>}</td>
                  <td className="num">{formatAmount(Number(l.base))}</td>
                  <td className="num">{draft && canRecord
                    ? <NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} value={val(l, 'additions')} onChange={e => setVal(l, 'additions', e.target.value)} />
                    : Number(l.additions) ? formatAmount(Number(l.additions)) : ''}</td>
                  <td className="num">{formatAmount(grossOf(l))}</td>
                  <td className="num">{Number(l.nssf_employee) ? formatAmount(Number(l.nssf_employee)) : <span className="pl-help">{l.statutory ? '0' : '—'}</span>}</td>
                  <td className="num">{Number(l.paye) ? formatAmount(Number(l.paye)) : <span className="pl-help">{l.statutory ? '0' : '—'}</span>}</td>
                  <td className="num">{draft && canRecord
                    ? <NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} value={val(l, 'deductions')} onChange={e => setVal(l, 'deductions', e.target.value)} />
                    : Number(l.deductions) ? formatAmount(Number(l.deductions)) : ''}</td>
                  <td className="num" title="Advances and loans taken back (Advances tab)">{Number(l.advance_deductions) ? formatAmount(Number(l.advance_deductions)) : ''}</td>
                  <td className="num"><strong>{formatAmount(amountOf(l))}</strong></td>
                  <td>{draft && canRecord ? <input className="form-input" style={{ width: 140 }} placeholder="e.g. advance" value={val(l, 'note')} onChange={e => setVal(l, 'note', e.target.value)} /> : l.note || ''}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td colSpan={5}><strong>Total</strong></td><td className="num">{formatAmount(lines.reduce((t, l) => t + grossOf(l), 0))}</td><td className="num">{formatAmount(tot('nssf_employee'))}</td><td className="num">{formatAmount(tot('paye'))}</td><td className="num">{formatAmount(lines.reduce((t, l) => t + (num(val(l, 'deductions')) || 0), 0))}</td><td className="num">{formatAmount(tot('advance_deductions'))}</td><td className="num"><strong>{money(total)}</strong></td><td /></tr></tfoot>
          </table>
        </div>
        {(tot('nssf_employer') + tot('wcf') + tot('sdl')) > 0 && (
          <p className="pl-help">Employer on top of pay: NSSF {formatAmount(tot('nssf_employer'))} · WCF {formatAmount(tot('wcf'))} · SDL {formatAmount(tot('sdl'))} — with PAYE and employee NSSF, {money(tot('nssf_employer') + tot('wcf') + tot('sdl') + tot('nssf_employee') + tot('paye'))} to remit.</p>
        )}
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

/* Working days a month (089): a salary by the day — days attended × salary ÷ these days */
function WorkDaysCard() {
  const { can } = useAuth();
  const canSet = can('payroll.rates');
  const [days, setDays] = useState(null);
  const [text, setText] = useState('');
  const [msg, setMsg] = useState('');
  useEffect(() => {
    supabase.from('payroll_settings').select('work_days_a_month').maybeSingle().then(({ data, error }) => {
      if (error) { setDays(false); return; }
      const v = Number(data?.work_days_a_month ?? WORK_DAYS_DEFAULT); setDays(v); setText(String(v));
    });
  }, []);
  if (days === false || days === null) return null;   // before 089
  async function save() {
    setMsg('');
    const { error } = await supabase.rpc('set_work_days_a_month', { p_days: Number(text) });
    if (error) { setMsg(dbErrorMessage(error)); return; }
    setDays(Number(text)); setMsg('Saved — draft pay sheets updated.');
  }
  return (
    <section className="card" style={{ marginTop: 12 }}>
      <div className="card-header"><h2 className="card-title">Working days a month</h2></div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">Employed staff are paid by the days attended: salary ÷ this number × days. 26 = Monday to Saturday.</p>
        <div className="flex items-center gap-8">
          <input className="form-input" style={{ width: 90 }} inputMode="decimal" aria-label="Working days a month" value={text} disabled={!canSet} onChange={e => setText(e.target.value)} />
          {canSet && <button type="button" className="btn btn-primary btn-sm" disabled={!text || Number(text) === days} onClick={save}>Save</button>}
          {msg && <span className="pl-help">{msg}</span>}
        </div>
      </div>
    </section>
  );
}
