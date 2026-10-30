import { useEffect, useMemo, useState } from 'react';
import { Printer } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { formatAmount, formatMoneyShort } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import { ListToolbar } from '../ListControls';
import ErrorState from '../ErrorState';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

const monthName = m => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const prevMonth = m => { const d = new Date(`${m}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); };
const monthEnd = m => { const x = new Date(`${m}-01T00:00:00Z`); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
const shortDay = d => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' });
const n = v => Number(v || 0);
const amt = v => formatAmount(Math.round(n(v)));
const cell = v => (n(v) ? amt(v) : '');
const SHEET_STATUS = { draft: 'Draft', approved: 'Approved', paid: 'Paid' };

/** where a payment stands: paid, approved, or due (by its date or already) */
function standing(sheet, dueOn, today) {
  if (sheet?.status === 'paid') return { text: `Paid ${sheet.paid_on ?? ''}`.trim(), cls: 'text-success' };
  if (sheet?.status === 'approved') return { text: 'Approved — to pay', cls: 'text-warning' };
  return today >= dueOn ? { text: 'Due', cls: 'text-warning' } : { text: `Due ${shortDay(dueOn)}`, cls: 'text-muted' };
}

/*
 * Payroll › Employees (2026-10-30): one month, one person a row — the monthly
 * salary, days attended and earned as of today, the first payment (a share of
 * the salary, 50% by default) and whether it is paid or due, NSSF (a fixed
 * share of the salary, 099, on the end-of-month payment), PAYE, other
 * deductions and the balance at the end of the month. A row opens the person
 * in full: allowance and other deductions are filled there, with their slips.
 */
export default function PayrollMonth({ staff, today, money, currency, canRecord, inBranch, SheetModal, canApprove, workDays }) {
  const [month, setMonth] = useState(today.slice(0, 7));
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [openId, setOpenId] = useState(null);
  const [personId, setPersonId] = useState(null);
  const from = `${month}-01`; const to = monthEnd(month);

  async function load() {
    setError('');
    const [sh, at, cfg, ra] = await Promise.all([
      supabase.from('pay_sheets').select('*').neq('status', 'void').neq('cycle', 'weekly').gte('period_start', from).lte('period_start', to).order('period_start'),
      supabase.from('staff_attendance').select('staff_id, day_fraction').gte('work_date', from).lte('work_date', to),
      supabase.from('payroll_settings').select('*').maybeSingle(),
      supabase.from('statutory_rates').select('rate, effective_from').eq('code', 'nssf_employee').eq('status', 'active').lte('effective_from', to).order('effective_from', { ascending: false }).limit(1),
    ]);
    if (sh.error || at.error) { console.error(sh.error || at.error); setError("We couldn't load payroll."); setD({ sheets: [], lines: [], days: {}, pct: 50, nssf: 0 }); return; }
    const ids = (sh.data || []).map(s => s.id);
    const li = ids.length ? await supabase.from('pay_sheet_lines').select('*').in('sheet_id', ids) : { data: [] };
    const days = {};
    for (const a of at.data || []) days[a.staff_id] = (days[a.staff_id] || 0) + n(a.day_fraction);
    setD({ sheets: sh.data || [], lines: li.data || [], days, pct: n(cfg.data?.first_half_pct ?? 50), nssf: n(ra.data?.[0]?.rate) });
  }
  useEffect(() => { setD(null); load(); }, [month]); // eslint-disable-line react-hooks/exhaustive-deps

  const months = Array.from({ length: 24 }, (_, i) => { let m = today.slice(0, 7); for (let k = 0; k < i; k++) m = prevMonth(m); return m; });
  const firstDue = `${month}-15`;
  const sheetsHere = useMemo(() => (d?.sheets || []).filter(s => inBranch(s.branch_id)), [d, inBranch]);
  const rows = useMemo(() => {
    if (!d) return [];
    const byId = Object.fromEntries(d.sheets.map(s => [s.id, s]));
    const q = search.trim().toLowerCase();
    return staff.filter(s => s.kind === 'employed' && inBranch(s.branch_id)).map(s => {
      const own = d.lines.filter(l => l.staff_id === s.id && byId[l.sheet_id]);
      const first = own.find(l => l.part === 'advance');
      const last = own.find(l => l.part === 'balance' || byId[l.sheet_id].cycle === 'monthly');
      if (s.status !== 'active' && !own.length) return null;
      const salary = last?.rate ?? first?.rate ?? s.pay_rate;
      const days = d.days[s.id] || 0;
      const earned = last ? n(last.base) : salary == null ? 0 : days * n(salary) / workDays;
      const firstAmt = first ? n(first.amount) : 0;
      const firstOwed = first ? firstAmt : (today <= firstDue && salary != null ? n(salary) * d.pct / 100 : 0);   // not on a sheet yet, still to come
      const statutory = s.statutory ?? true;
      const nssf = last ? n(last.nssf_employee) : statutory && salary != null ? n(salary) * d.nssf / 100 : 0;
      const additions = n(last?.additions); const paye = n(last?.paye); const other = n(last?.deductions); const loans = n(last?.advance_deductions);
      const gross = earned + additions;
      const raw = gross - nssf - paye - other - loans - firstOwed;
      return { s, salary, days, earned, gross, additions, nssf, paye, other, loans, first, last, firstSheet: first && byId[first.sheet_id], lastSheet: last && byId[last.sheet_id], firstAmt: firstOwed, balance: Math.max(raw, 0), overpaid: raw < 0 ? -raw : 0 };
    }).filter(Boolean).filter(r => !q || `${r.s.full_name} ${r.s.job_title ?? ''}`.toLowerCase().includes(q))
      .sort((a, b) => a.s.full_name.localeCompare(b.s.full_name));
  }, [d, staff, search, inBranch, workDays, today, firstDue]);
  const tot = k => rows.reduce((t, r) => t + n(r[k]), 0);
  const short = v => formatMoneyShort(v, currency);
  const firstPaid = rows.filter(r => r.firstSheet?.status === 'paid').reduce((t, r) => t + r.firstAmt, 0);
  const person = rows.find(r => r.s.id === personId);
  const isNow = month === today.slice(0, 7);
  const lastDue = to;

  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Monthly salaries</span><strong>{short(tot('salary'))}</strong><span className="pl-help">{rows.length} employees</span></div>
        <div className="mm-stat"><span className="pl-label">{isNow ? 'Earned as of today' : 'Earned'}</span><strong>{short(tot('earned'))}</strong><span className="pl-help">by days attended</span></div>
        <div className="mm-stat"><span className="pl-label">First payment ({d?.pct ?? 50}%)</span><strong>{short(tot('firstAmt'))}</strong><span className="pl-help">{short(firstPaid)} paid · {short(tot('firstAmt') - firstPaid)} due</span></div>
        <div className="mm-stat"><span className="pl-label">Balance at month end</span><strong>{short(tot('balance'))}</strong><span className="pl-help">after NSSF {short(tot('nssf'))}</span></div>
      </div>
      <ListToolbar id="payroll-search" search={search} onSearch={setSearch} placeholder="Search name…" />
      <div className="flex items-center gap-8" style={{ margin: '0 0 12px', flexWrap: 'wrap' }}>
        <select className="form-input" style={{ maxWidth: 260 }} aria-label="Month" value={month} onChange={e => setMonth(e.target.value)}>
          {months.map(m => <option key={m} value={m}>{monthName(m)}{m === today.slice(0, 7) ? ' (this month)' : ''}</option>)}
        </select>
        <span style={{ marginLeft: 'auto' }} className="flex items-center gap-8" >
          {sheetsHere.map(s => (
            <button key={s.id} type="button" className="btn btn-outline btn-sm" title="Approve, pay or void this payment" onClick={() => setOpenId(s.id)}>
              {s.period_start.endsWith('-01') && s.cycle === 'fortnightly' ? 'First payment' : 'End of month'} · {SHEET_STATUS[s.status]}{s.status === 'draft' && s.rates_unverified?.length ? ' · rates to verify' : ''}
            </button>
          ))}
        </span>
      </div>
      <div className="card"><div className="table-container">
        <table className="ps-table">
          <thead><tr><th>Name</th><th className="num">Days</th><th className="num">Salary (TZS)</th><th className="num">Earned (TZS)</th><th className="num">Allowance (TZS)</th><th className="num">First payment (TZS)</th>
            <th className="num">NSSF (TZS)</th><th className="num">PAYE (TZS)</th><th className="num">Other deductions (TZS)</th><th className="num">Loans (TZS)</th><th className="num">Balance (TZS)</th></tr></thead>
          <tbody>
            {d === null ? <tr><td colSpan={11}><span className="skeleton" /></td></tr>
            : rows.length === 0 ? <tr><td colSpan={11} className="text-muted">{search ? 'Nobody matches.' : 'No employees here.'}</td></tr>
            : rows.map(r => {
              const f = r.first || r.firstAmt ? standing(r.firstSheet, firstDue, today) : { text: 'None recorded', cls: 'text-muted' };
              const b = standing(r.lastSheet, lastDue, today);
              return (
                <tr key={r.s.id} className="clickable-row" title="Open in full" onClick={() => setPersonId(r.s.id)}>
                  <td><strong>{r.s.full_name}</strong>{r.s.job_title && <div className="pl-help">{r.s.job_title}</div>}</td>
                  <td className="num">{r.days || ''}</td>
                  <td className="num">{r.salary == null ? <span className="text-warning">not set</span> : amt(r.salary)}</td>
                  <td className="num">{amt(r.earned)}</td>
                  <td className="num">{cell(r.additions)}</td>
                  <td className="num">{cell(r.firstAmt)}<div className={`pl-help ${f.cls}`}>{f.text}</div></td>
                  <td className="num">{cell(r.nssf)}</td>
                  <td className="num">{cell(r.paye)}</td>
                  <td className="num">{cell(r.other)}</td>
                  <td className="num">{cell(r.loans)}</td>
                  <td className="num"><strong>{amt(r.balance)}</strong><div className={`pl-help ${r.overpaid ? 'text-warning' : b.cls}`}>{r.overpaid ? `Overpaid ${amt(r.overpaid)}` : b.text}</div></td>
                </tr>
              );
            })}
          </tbody>
          {rows.length > 0 && <tfoot><tr><td><strong>Total</strong></td><td className="num">{tot('days') || ''}</td>
            {['salary', 'earned', 'additions', 'firstAmt', 'nssf', 'paye', 'other', 'loans'].map(k => <td key={k} className="num"><strong>{amt(tot(k))}</strong></td>)}
            <td className="num"><strong>{money(Math.round(tot('balance')))}</strong></td></tr></tfoot>}
        </table>
      </div></div>
      {openId && <SheetModal id={openId} staff={staff} money={money} today={today} canRecord={canRecord} canApprove={canApprove} onClose={() => { setOpenId(null); load(); }} onChanged={load} />}
      {person && <PersonMonth r={person} month={month} today={today} money={money} pct={d.pct} nssfPct={d.nssf} workDays={workDays} firstDue={firstDue} lastDue={lastDue} canRecord={canRecord} onClose={() => setPersonId(null)} onSaved={load} />}
    </>
  );
}

/* One employee's month in full: earned as of today, the two payments, deductions, slips */
function PersonMonth({ r, month, today, money, pct, nssfPct, workDays, firstDue, lastDue, canRecord, onClose, onSaved }) {
  const editable = canRecord && r.lastSheet?.status === 'draft';
  const [form, setForm] = useState({ additions: r.additions ? String(r.additions) : '', deductions: r.other ? String(r.other) : '', note: r.last?.note ?? '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const dirty = editable && (Number(form.additions || 0) !== r.additions || Number(form.deductions || 0) !== r.other || form.note !== (r.last?.note ?? ''));
  async function save() {
    setBusy(true); setError('');
    const { error: err } = await supabase.rpc('update_pay_sheet_line', { p_line: r.last.id, p: { additions: form.additions || '0', deductions: form.deductions || '0', note: form.note } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  const f = r.first || r.firstAmt ? standing(r.firstSheet, firstDue, today) : { text: 'None recorded', cls: 'text-muted' };
  const b = standing(r.lastSheet, lastDue, today);
  const totalDed = r.nssf + r.paye + r.other + r.loans + r.firstAmt;
  const row = (label, v) => (n(v) ? <tr key={label}><td>{label}</td><td className="num">{amt(v)}</td></tr> : null);
  const isNow = month === today.slice(0, 7);
  return (
    <Modal title={`${r.s.full_name} — ${monthName(month)}`} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        {dirty && <button type="button" className="btn btn-primary" disabled={busy} onClick={save}>Save</button>}
        {r.first && <a className="btn btn-outline" href={`/print/payslips/${r.first.sheet_id}?line=${r.first.id}`} target="_blank" rel="noreferrer"><Printer size={14} /> First payment slip</a>}
        {r.last && <a className="btn btn-outline" href={`/print/payslips/${r.last.sheet_id}?line=${r.last.id}`} target="_blank" rel="noreferrer"><Printer size={14} /> Salary slip</a>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button></>}>
      <div className="modal-form">
        <p className="text-sm">{[r.s.job_title, r.s.nssf_no && `NSSF no. ${r.s.nssf_no}`].filter(Boolean).join(' · ')}</p>
        <div className="pp-facts">
          <div><span className="pl-label">Monthly salary</span><strong>{r.salary == null ? 'Not set' : money(Math.round(n(r.salary)))}</strong></div>
          <div><span className="pl-label">Days attended</span><strong>{r.days} of {workDays}</strong></div>
          <div><span className="pl-label">{isNow ? 'Earned as of today' : 'Earned'}</span><strong>{money(Math.round(r.earned))}</strong></div>
        </div>
        <div className="pp-pay">
          <div><span>First payment ({pct}% of salary){r.firstSheet?.period_end ? '' : ` — by ${shortDay(firstDue)}`}</span><strong>{money(Math.round(r.firstAmt))}</strong><span className={f.cls}>{f.text}</span></div>
          <div><span>Balance at the end of the month</span><strong>{money(Math.round(r.balance))}</strong><span className={r.overpaid ? 'text-warning' : b.cls}>{r.overpaid ? `Overpaid ${amt(r.overpaid)}` : b.text}</span></div>
        </div>
        <div className="pp-grid">
          <table className="pp-table">
            <thead><tr><th>Earnings</th><th className="num">TZS</th></tr></thead>
            <tbody><tr><td>Earned by days attended</td><td className="num">{amt(r.earned)}</td></tr>{row('Allowance', r.additions)}</tbody>
            <tfoot><tr><td><strong>Gross pay</strong></td><td className="num"><strong>{amt(r.gross)}</strong></td></tr></tfoot>
          </table>
          <table className="pp-table">
            <thead><tr><th>Deductions</th><th className="num">TZS</th></tr></thead>
            <tbody>
              {row(`NSSF (${nssfPct}% of salary)`, r.nssf)}{row('PAYE', r.paye)}{row(`Other deductions${r.last?.note ? ` (${r.last.note})` : ''}`, r.other)}{row('Advance / loan taken back', r.loans)}{row('First payment', r.firstAmt)}
              {totalDed === 0 && <tr><td className="text-muted" colSpan={2}>None</td></tr>}
            </tbody>
            <tfoot><tr><td><strong>Total deductions</strong></td><td className="num"><strong>{amt(totalDed)}</strong></td></tr></tfoot>
          </table>
        </div>
        {editable ? (
          <div className="form-row">
            <label className="pe-field"><span>Allowance</span><NumberInput step="any" min="0" className="form-input" value={form.additions} onChange={e => setForm({ ...form, additions: e.target.value })} /></label>
            <label className="pe-field"><span>Other deductions</span><NumberInput step="any" min="0" className="form-input" value={form.deductions} onChange={e => setForm({ ...form, deductions: e.target.value })} /></label>
            <label className="pe-field" style={{ flex: 1 }}><span>Note</span><input className="form-input" placeholder="e.g. what the deduction is for" value={form.note} onChange={e => setForm({ ...form, note: e.target.value })} /></label>
          </div>
        ) : !r.last ? <p className="pl-help">Allowance and other deductions open once the month-end payment starts (the first attendance from the 16th).</p>
          : r.lastSheet?.status !== 'draft' ? <p className="pl-help">This payment is {r.lastSheet?.status}, so it no longer changes.</p> : null}
        {r.overpaid > 0 && <p className="pl-help text-warning">The first payment and deductions are more than what was earned by {Math.round(r.overpaid).toLocaleString('en-US')}; the balance stops at 0.</p>}
      </div>
    </Modal>
  );
}
