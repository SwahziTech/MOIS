import { useEffect, useMemo, useState } from 'react';
import { Download } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { formatAmount, formatMoneyShort } from '../../lib/format';
import { PageTabs } from '../ListControls';

const monthName = m => new Date(`${m}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const prevMonth = m => { const d = new Date(`${m}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1); return d.toISOString().slice(0, 7); };

/*
 * Statutory returns (Staff (HR) Part 2, 2026-10-29): the month's figures for
 * the PAYE/SDL return to TRA, the NSSF contributions and WCF, read from the
 * pay sheets PAID in that month (all branches the viewer sees, or the chosen
 * branch). Each person once, with NSSF number; Excel to fill the forms.
 */
export default function StatutoryReturns({ staff, today, currency, inBranch }) {
  const [month, setMonth] = useState(prevMonth(today.slice(0, 7)));
  const [view, setView] = useState('paye');
  const [lines, setLines] = useState(null);
  const [error, setError] = useState('');
  useEffect(() => {
    setLines(null); setError('');
    const from = `${month}-01`; const d = new Date(`${from}T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + 1);
    supabase.from('pay_sheet_lines').select('staff_id, gross, nssf_employee, nssf_employer, paye, wcf, sdl, sheet:pay_sheets!inner(branch_id, status, paid_on)')
      .eq('sheet.status', 'paid').gte('sheet.paid_on', from).lt('sheet.paid_on', d.toISOString().slice(0, 10))
      .then(({ data, error: err }) => { if (err) { console.error(err); setError("We couldn't load the month's pay."); setLines([]); return; } setLines(data || []); });
  }, [month]);

  // each person once for the month
  const people = useMemo(() => {
    const by = {};
    for (const l of (lines || []).filter(x => inBranch(x.sheet.branch_id))) {
      const p = (by[l.staff_id] ||= { id: l.staff_id, gross: 0, nssfEe: 0, nssfEr: 0, paye: 0, wcf: 0, sdl: 0 });
      p.gross += Number(l.gross); p.nssfEe += Number(l.nssf_employee); p.nssfEr += Number(l.nssf_employer);
      p.paye += Number(l.paye); p.wcf += Number(l.wcf); p.sdl += Number(l.sdl);
    }
    return Object.values(by).map(p => ({ ...p, st: staff.find(s => s.id === p.id) || {} }))
      .sort((a, b) => (a.st.full_name || '').localeCompare(b.st.full_name || ''));
  }, [lines, staff, inBranch]);
  const sum = f => people.reduce((t, p) => t + p[f], 0);
  const short = v => formatMoneyShort(v, currency);
  const months = Array.from({ length: 12 }, (_, i) => { let m = today.slice(0, 7); for (let k = 0; k < i; k++) m = prevMonth(m); return m; });

  async function exportExcel() {
    const ExcelJS = (await import('exceljs')).default;
    const wb = new ExcelJS.Workbook();
    const add = (name, head, rows, total) => {
      const ws = wb.addWorksheet(name);
      ws.addRow([`${name} — ${monthName(month)}`]).font = { bold: true };
      ws.addRow([]);
      ws.addRow(head).font = { bold: true };
      rows.forEach(r => ws.addRow(r));
      if (total) ws.addRow(total).font = { bold: true };
      ws.columns.forEach((c, i) => { c.width = i === 0 ? 28 : 16; });
    };
    add('PAYE', ['Name', 'Gross pay', 'NSSF (employee)', 'Taxable pay', 'PAYE'],
      people.filter(p => p.paye > 0 || p.nssfEe > 0).map(p => [p.st.full_name, p.gross, p.nssfEe, p.gross - p.nssfEe, p.paye]),
      ['Total', sum('gross'), sum('nssfEe'), sum('gross') - sum('nssfEe'), sum('paye')]);
    add('NSSF', ['Name', 'NSSF no.', 'Gross pay', 'Employee', 'Employer', 'Total'],
      people.filter(p => p.nssfEe + p.nssfEr > 0).map(p => [p.st.full_name, p.st.nssf_no || '', p.gross, p.nssfEe, p.nssfEr, p.nssfEe + p.nssfEr]),
      ['Total', '', sum('gross'), sum('nssfEe'), sum('nssfEr'), sum('nssfEe') + sum('nssfEr')]);
    add('SDL & WCF', ['', 'Gross pay', 'SDL', 'WCF'], [['All staff paid', sum('gross'), sum('sdl'), sum('wcf')]]);
    const buf = await wb.xlsx.writeBuffer();
    const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
    const a = document.createElement('a'); a.href = url; a.download = `Statutory returns ${month}.xlsx`; document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
  }

  return (
    <>
      {lines !== null && (
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">PAYE</span><strong>{short(sum('paye'))}</strong><span className="pl-help">to TRA by the 7th</span></div>
          <div className="mm-stat"><span className="pl-label">NSSF</span><strong>{short(sum('nssfEe') + sum('nssfEr'))}</strong>
            <span className="pl-help">employee {short(sum('nssfEe'))} · employer {short(sum('nssfEr'))}</span></div>
          <div className="mm-stat"><span className="pl-label">SDL · WCF</span><strong>{short(sum('sdl') + sum('wcf'))}</strong>
            <span className="pl-help">SDL {short(sum('sdl'))} · WCF {short(sum('wcf'))}</span></div>
        </div>
      )}
      <div className="flex items-center gap-8" style={{ margin: '12px 0', flexWrap: 'wrap' }}>
        <select className="form-input" style={{ maxWidth: 200 }} aria-label="Month" value={month} onChange={e => setMonth(e.target.value)}>
          {months.map(m => <option key={m} value={m}>{monthName(m)}</option>)}
        </select>
        <PageTabs nested tabs={[['paye', 'PAYE'], ['nssf', 'NSSF'], ['sdl', 'SDL & WCF']]} value={view} onChange={setView} />
        <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} disabled={!people.length} onClick={exportExcel}><Download size={14} /> Excel</button>
        <span className="pl-help" title="From the pay sheets paid in the month. Check the figures before filing; the rates are the ones confirmed under ⚙.">Pay sheets paid in {monthName(month)}</span>
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="card"><div className="table-container">
        {view === 'paye' ? (
          <table>
            <thead><tr><th>Name</th><th className="num">Gross pay (TZS)</th><th className="num">NSSF employee (TZS)</th><th className="num">Taxable pay (TZS)</th><th className="num">PAYE (TZS)</th></tr></thead>
            <tbody>
              {lines === null ? <tr><td colSpan={5}><span className="skeleton" /></td></tr>
              : people.length === 0 ? <tr><td colSpan={5} className="text-muted">No pay sheets paid in {monthName(month)}.</td></tr>
              : people.filter(p => p.paye > 0 || p.nssfEe > 0).map(p => (
                <tr key={p.id}><td><strong>{p.st.full_name}</strong></td><td className="num">{formatAmount(p.gross)}</td><td className="num">{formatAmount(p.nssfEe)}</td>
                  <td className="num">{formatAmount(p.gross - p.nssfEe)}</td><td className="num"><strong>{formatAmount(p.paye)}</strong></td></tr>
              ))}
            </tbody>
            {people.length > 0 && <tfoot><tr><td><strong>Total</strong></td><td className="num">{formatAmount(sum('gross'))}</td><td className="num">{formatAmount(sum('nssfEe'))}</td><td className="num">{formatAmount(sum('gross') - sum('nssfEe'))}</td><td className="num"><strong>{formatAmount(sum('paye'))}</strong></td></tr></tfoot>}
          </table>
        ) : view === 'nssf' ? (
          <table>
            <thead><tr><th>Name</th><th>NSSF no.</th><th className="num">Gross pay (TZS)</th><th className="num">Employee (TZS)</th><th className="num">Employer (TZS)</th><th className="num">Total (TZS)</th></tr></thead>
            <tbody>
              {lines === null ? <tr><td colSpan={6}><span className="skeleton" /></td></tr>
              : people.filter(p => p.nssfEe + p.nssfEr > 0).length === 0 ? <tr><td colSpan={6} className="text-muted">No NSSF in {monthName(month)}.</td></tr>
              : people.filter(p => p.nssfEe + p.nssfEr > 0).map(p => (
                <tr key={p.id}><td><strong>{p.st.full_name}</strong></td><td>{p.st.nssf_no || <span className="text-warning">not set</span>}</td><td className="num">{formatAmount(p.gross)}</td>
                  <td className="num">{formatAmount(p.nssfEe)}</td><td className="num">{formatAmount(p.nssfEr)}</td><td className="num"><strong>{formatAmount(p.nssfEe + p.nssfEr)}</strong></td></tr>
              ))}
            </tbody>
            {people.length > 0 && <tfoot><tr><td colSpan={2}><strong>Total</strong></td><td className="num">{formatAmount(sum('gross'))}</td><td className="num">{formatAmount(sum('nssfEe'))}</td><td className="num">{formatAmount(sum('nssfEr'))}</td><td className="num"><strong>{formatAmount(sum('nssfEe') + sum('nssfEr'))}</strong></td></tr></tfoot>}
          </table>
        ) : (
          <table>
            <thead><tr><th>Paid in the month</th><th className="num">People</th><th className="num">Gross pay (TZS)</th><th className="num">SDL (TZS)</th><th className="num">WCF (TZS)</th></tr></thead>
            <tbody>
              {lines === null ? <tr><td colSpan={5}><span className="skeleton" /></td></tr>
              : <tr><td>All staff paid</td><td className="num">{people.length}</td><td className="num">{formatAmount(sum('gross'))}</td><td className="num"><strong>{formatAmount(sum('sdl'))}</strong></td><td className="num"><strong>{formatAmount(sum('wcf'))}</strong></td></tr>}
            </tbody>
          </table>
        )}
      </div></div>
    </>
  );
}
