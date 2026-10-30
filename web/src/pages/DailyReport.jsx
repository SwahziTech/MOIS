import { useEffect, useMemo, useState } from 'react';
import { Copy, Check, FileText } from 'lucide-react';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatAmount, tableDate } from '../lib/format';
import { orgToday, loadInventoryRefs } from '../lib/inventory';
import { loadDayFacts, writeReport, readReport, compareReport } from '../lib/dailyReport';
import PageShell from '../components/PageShell';
import { PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';

const close = (a, b) => Math.abs(a - b) < 0.5;

/*
 * The daily report, two ways (1f, 2026-10-29):
 *   From MOIS — written from what was recorded that day, in the branch's
 *               Swahili format, ready to copy and send;
 *   Compare   — a written or pasted report read back and lined up against
 *               MOIS: production, cement in store, each meter.
 */
export default function DailyReport() {
  const { organization } = useAuth();
  const { branchId, branchName } = useBranch();
  const today = orgToday(organization?.timezone);
  const [tab, setTab] = useState('write');
  const [date, setDate] = useState(today);
  const [refs, setRefs] = useState(null);
  const [facts, setFacts] = useState(null);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  const [pasted, setPasted] = useState('');

  useEffect(() => { loadInventoryRefs().then(setRefs).catch(() => setError("We couldn't load the day.")); }, []);
  async function load() {
    if (!branchId || !refs) return;
    setError(''); setFacts(null);
    try { setFacts(await loadDayFacts({ branchId, date, today, refs })); } catch (e) { console.error(e); setError("We couldn't load the day."); }
  }
  useEffect(() => { load(); }, [branchId, date, refs]); // eslint-disable-line react-hooks/exhaustive-deps

  const text = facts ? writeReport(facts, { branchName: branchName || '', date }) : '';
  const rows = useMemo(() => (facts && pasted.trim() ? compareReport(readReport(pasted), facts) : []), [facts, pasted]);
  const off = rows.filter(r => r.report != null && r.mois != null && !close(r.report, r.mois)).length;
  const missing = rows.filter(r => (r.report == null) !== (r.mois == null)).length;
  async function copy() {
    try { await navigator.clipboard.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch { /* clipboard blocked */ }
  }

  const pieces = facts ? facts.products.reduce((t, p) => t + p.pieces, 0) : 0;
  const bags = facts ? facts.products.reduce((t, p) => t + p.cement, 0) : 0;
  const units = facts ? facts.meters.reduce((t, m) => t + (m.used || 0), 0) : 0;

  return (
    <PageShell title="Daily report" subtitle="Reports"
      description={branchId ? `The day at ${branchName}: written from MOIS, or a written report checked against it.` : 'Choose a branch to see its daily report.'}>
      <PageTabs tabs={[['write', 'From MOIS'], ['compare', 'Compare a report']]} value={tab} onChange={setTab} />
      {!branchId ? <div className="card"><EmptyState icon={FileText} title="Choose a branch" description="The daily report is one branch's day." /></div>
      : error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : (
        <>
          <div className="mm-stats">
            {tab === 'write' ? <>
              <div className="mm-stat"><span className="pl-label">Production</span><strong>{facts ? formatAmount(pieces) : '…'} pcs</strong><span className="pl-help">{facts ? `${facts.products.length} product${facts.products.length === 1 ? '' : 's'}` : ''}</span></div>
              <div className="mm-stat"><span className="pl-label">Cement</span><strong>{facts ? formatAmount(bags) : '…'} bags used</strong><span className="pl-help">{facts?.cementStore != null ? `${formatAmount(facts.cementStore)} left in store` : 'store not found'}</span></div>
              <div className="mm-stat"><span className="pl-label">Electricity</span><strong>{facts ? formatAmount(units) : '…'} units</strong><span className="pl-help">{facts ? `${facts.meters.filter(m => m.morning != null && m.evening != null).length} of ${facts.meters.length} meters read` : ''}</span></div>
            </> : <>
              <div className="mm-stat"><span className="pl-label">Lines read</span><strong>{rows.filter(r => r.report != null).length}</strong><span className="pl-help">from the pasted report</span></div>
              <div className="mm-stat"><span className="pl-label">Differ</span><strong className={off ? 'text-warning' : ''}>{off}</strong><span className="pl-help">report ≠ MOIS</span></div>
              <div className="mm-stat"><span className="pl-label">On one side only</span><strong className={missing ? 'text-warning' : ''}>{missing}</strong><span className="pl-help">missing from report or MOIS</span></div>
            </>}
          </div>
          <div className="flex items-center gap-8" style={{ margin: '12px 0' }}>
            <label className="pe-field" style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}><span>Day</span>
              <input type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value || today)} /></label>
            {tab === 'write' && <button type="button" className="btn btn-primary btn-sm" disabled={!text} onClick={copy}>{copied ? <><Check size={14} /> Copied</> : <><Copy size={14} /> Copy report</>}</button>}
            <span className="pl-help" title="Production from the day's batches (pieces of the main product, cement, wastani = all pieces ÷ bags, leftovers as MABAKI, team = people ticked on the batches); cement in the branch's stores at the end of the day; each meter's morning and evening readings and the units used.">From the day's batches, stores and meter readings.</span>
          </div>
          {tab === 'write' ? (
            <div className="card"><div className="card-body">
              {facts === null ? <span className="skeleton" /> : <pre className="dr-text">{text}</pre>}
            </div></div>
          ) : (
            <div className="dr-compare">
              <div className="card"><div className="card-body">
                <label className="pe-field"><span>Paste or type the day's report</span>
                  <textarea className="form-input dr-paste" rows={16} placeholder={'RIPOTI YA … TAREHE …\nUZALISHAJI WA …\nPcs … Cem … Wastani …\n…'} value={pasted} onChange={e => setPasted(e.target.value)} /></label>
              </div></div>
              <div className="card"><div className="table-container">
                <table>
                  <thead><tr><th>What</th><th className="num">Report</th><th className="num">MOIS</th><th className="num">Difference</th></tr></thead>
                  <tbody>
                    {!pasted.trim() ? <tr><td colSpan={4} className="text-muted">Paste a report to compare it with {tableDate(date)}.</td></tr>
                    : facts === null ? <tr><td colSpan={4}><span className="skeleton" /></td></tr>
                    : rows.map((r, i) => {
                      const both = r.report != null && r.mois != null;
                      const ok = both && close(r.report, r.mois);
                      return (
                        <tr key={i}>
                          <td>{r.item}<div className="pl-help">{r.section}</div></td>
                          <td className="num">{r.report != null ? formatAmount(r.report) : <span className="pl-help">—</span>}</td>
                          <td className="num">{r.mois != null ? formatAmount(r.mois) : <span className="pl-help">—</span>}</td>
                          <td className="num">{ok ? <span className="badge badge-success">Same</span>
                            : both ? <span className="badge badge-warning">{r.report - r.mois > 0 ? '+' : ''}{formatAmount(r.report - r.mois)}</span>
                            : <span className="badge badge-neutral">{r.report == null ? 'not in report' : 'not in MOIS'}</span>}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div></div>
            </div>
          )}
        </>
      )}
    </PageShell>
  );
}
