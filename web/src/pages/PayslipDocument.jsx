import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney, formatAmount, dateText } from '../lib/format';

const CYCLE = { weekly: 'Weekly', fortnightly: 'Every 2 weeks', monthly: 'Monthly' };

/*
 * Payslips of a pay sheet (Staff (HR) Part 2, migration 088), A4, one a page,
 * in a tab of their own:
 *   /print/payslips/:sheetId            everyone on the sheet
 *   /print/payslips/:sheetId?line=:id   one person
 * Earnings beside deductions, then net pay (2026-10-30). Read as
 * saved — a draft prints marked DRAFT.
 */
export default function PayslipDocument() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!session) return;
    (async () => {
      const { data: sheet } = await supabase.from('pay_sheets').select('*').eq('id', id).maybeSingle();
      if (!sheet) { setError("We couldn't find this pay sheet."); return; }
      const [org, br, lines, staff] = await Promise.all([
        supabase.from('organizations').select('*').eq('id', sheet.organization_id).maybeSingle(),
        supabase.from('branches').select('name').eq('id', sheet.branch_id).maybeSingle(),
        supabase.from('pay_sheet_lines').select('*').eq('sheet_id', id),
        supabase.from('staff').select('id, full_name, job_title, kind, nssf_no').eq('branch_id', sheet.branch_id),
      ]);
      if (lines.error) { setError("We couldn't load the payslips."); return; }
      setD({ sheet, org: org.data, branch: br.data?.name, lines: lines.data || [], staff: staff.data || [] });
    })();
  }, [id, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;

  const { sheet, org, branch, staff } = d;
  const money = v => formatMoney(v, org?.currency_code);
  const person = sid => staff.find(s => s.id === sid) || {};
  const only = params.get('line');
  const lines = d.lines.filter(l => !only || l.id === only)
    .sort((a, b) => (person(a.staff_id).full_name || '').localeCompare(person(b.staff_id).full_name || ''));
  const row = (label, v) => (Number(v) ? <tr><td>{label}</td><td className="num">{formatAmount(Number(v))}</td></tr> : null);

  return (
    <div className="doc-page">
      <div className="doc-bar">
        <button type="button" className="btn btn-primary" onClick={() => window.print()}><Printer size={15} /> Print / Save as PDF</button>
        <span className="pl-help">{lines.length} payslip{lines.length === 1 ? '' : 's'}, one a page. Choose “Save as PDF” as the printer to keep a copy.</span>
      </div>
      {lines.length === 0 && <div className="doc-msg">No one on this pay sheet.</div>}
      {lines.map(l => {
        const p = person(l.staff_id);
        return (
          <article key={l.id} className="doc doc-slip">
            <header className="doc-head">
              <div className="doc-co">
                {org?.logo_url && <img src={org.logo_url} alt="" className="doc-logo" />}
                <div>
                  <strong className="doc-co-name">{org?.legal_name || org?.name}</strong>
                  {org?.address && <div>{org.address}</div>}
                  <div>{[org?.tin && `TIN ${org.tin}`, branch].filter(Boolean).join(' · ')}</div>
                </div>
              </div>
              <div className="doc-title">
                <h1>Salary slip{sheet.status === 'draft' ? ' — DRAFT' : sheet.status === 'void' ? ' — VOID' : ''}</h1>
                <div>Period: {dateText(sheet.period_start)} to {dateText(sheet.period_end)}</div>
                <div>{CYCLE[sheet.cycle]}{sheet.paid_on ? ` · paid ${dateText(sheet.paid_on)}` : ''}</div>
              </div>
            </header>

            <section className="doc-to">
              <span className="doc-label">Employee</span>
              <strong>{p.full_name}</strong>
              <div>{[p.job_title, p.kind === 'casual' ? 'Casual' : p.kind === 'employed' ? 'Employed' : null].filter(Boolean).join(' · ')}</div>
              {p.nssf_no && <div>NSSF no. {p.nssf_no}</div>}
              {l.days != null && <div>Days attended: {Number(l.days)}</div>}
            </section>

            <section>
              <div className="doc-slip-grid">
                <table className="doc-table">
                  <thead><tr><th>Earnings</th><th className="num">TZS</th></tr></thead>
                  <tbody>
                    <tr><td>{l.pay_basis === 'daily' ? `${Number(l.days || 0)} days × ${formatAmount(Number(l.rate || 0))}`
                      : l.part === 'advance' ? `First payment of the month (salary ${formatAmount(Number(l.rate || 0))} a month)`
                      : `Salary (${formatAmount(Number(l.rate || 0))} a month)${l.part === 'balance' ? ' — the month' : ''}`}</td><td className="num">{formatAmount(Number(l.base))}</td></tr>
                    {row('Allowance', l.additions)}
                  </tbody>
                  <tfoot><tr><td><strong>Gross pay</strong></td><td className="num"><strong>{formatAmount(Number(l.gross))}</strong></td></tr></tfoot>
                </table>
                <table className="doc-table">
                  <thead><tr><th>Deductions</th><th className="num">TZS</th></tr></thead>
                  <tbody>
                    {row('NSSF (employee)', l.nssf_employee)}
                    {row('PAYE', l.paye)}
                    {row(`Other deductions${l.note ? ` (${l.note})` : ''}`, l.deductions)}
                    {row('First payment already paid', l.first_payment)}
                    {row('Advance / loan taken back', l.advance_deductions)}
                  </tbody>
                  <tfoot><tr><td><strong>Total deductions</strong></td><td className="num"><strong>{formatAmount(['nssf_employee', 'paye', 'deductions', 'first_payment', 'advance_deductions'].reduce((t, k) => t + Number(l[k] || 0), 0))}</strong></td></tr></tfoot>
                </table>
              </div>
              <table className="doc-totals"><tbody><tr className="doc-grand"><td>Net pay</td><td className="num">{money(Number(l.amount))}</td></tr></tbody></table>
              {Number(l.nssf_employer) > 0 && <p className="pl-help" style={{ marginTop: 10 }}>The employer also pays NSSF {formatAmount(Number(l.nssf_employer))} for you.</p>}
            </section>

            <footer className="doc-foot">
              <div className="doc-sign"><span>Received by</span><span>Signature</span><span>Date</span></div>
              <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
            </footer>
          </article>
        );
      })}
    </div>
  );
}
