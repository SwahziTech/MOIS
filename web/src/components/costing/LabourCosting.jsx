import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { HardHat } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatMoney, formatAmount } from '../../lib/format';
import { PageTabs } from '../ListControls';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';

const monthName = m => new Date(`${m}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const r2 = n => Math.round(n * 100) / 100;

/*
 * Labour on Costing (Staff (HR), migrations 086 → 090): pulled from HR as the
 * pay sheets pay it — each production person's days attended × day rate (a
 * salary ÷ working days a month), plus the employer's NSSF, WCF and SDL —
 * shared over that day's batches by cement bags. Pay is seen by those who see
 * staff pay (Technical admin, directors, branch manager, secretary).
 */
export default function LabourCosting({ branchId, currency }) {
  const { canAt } = useAuth();
  const money = v => formatMoney(v, currency);
  const [view, setView] = useState('days');
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const can = canAt('staff.view', branchId);

  async function load() {
    setError('');
    const since = new Date(Date.now() - 90 * 864e5).toISOString().slice(0, 10);
    const [d, m, b] = await Promise.all([
      supabase.from('labour_days').select('*').eq('branch_id', branchId).gte('day', since).order('day', { ascending: false }),
      supabase.from('labour_months').select('*').eq('branch_id', branchId).gte('month', since.slice(0, 8) + '01').order('month', { ascending: false }),   // newest first
      supabase.from('production_batches').select('batch_date, cement_bags').eq('branch_id', branchId).neq('status', 'void').gte('batch_date', since.slice(0, 8) + '01'),
    ]);
    if (d.error || m.error) { console.error(d.error || m.error); setError("We couldn't load labour costs."); return; }
    const bagsDay = {}; const bagsMonth = {};
    for (const x of b.data || []) { bagsDay[x.batch_date] = (bagsDay[x.batch_date] || 0) + Number(x.cement_bags); const mo = x.batch_date.slice(0, 8) + '01'; bagsMonth[mo] = (bagsMonth[mo] || 0) + Number(x.cement_bags); }
    setData({ days: d.data || [], months: m.data || [], bagsDay, bagsMonth });
  }
  useEffect(() => { if (can) { setData(null); load(); } }, [branchId, can]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!can) return <div className="card"><EmptyState icon={HardHat} title="Labour pay is private" description="Seen by those who see staff pay (Technical admin, directors, branch manager, secretary)." /></div>;
  if (error) return <div className="card"><ErrorState message={error} onRetry={load} /></div>;
  if (data === null) return <div className="card"><span className="skeleton" /></div>;
  const thisMonth = new Date().toISOString().slice(0, 8) + '01';
  const mo = data.months.find(x => x.month === thisMonth);
  const costOf = x => Number(x?.wages || 0) + Number(x?.employer || 0);
  const bags = data.bagsMonth[thisMonth] || 0;
  const total = costOf(mo);
  const unpriced = Number(mo?.without_rate || 0);

  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Labour this month</span><strong>{money(r2(total))}</strong><span className="pl-help" title={`Casuals ${formatAmount(Number(mo?.casual_wages || 0))} · employed ${formatAmount(Number(mo?.employed_wages || 0))} · employer's NSSF/WCF/SDL ${formatAmount(Number(mo?.employer || 0))}`}>pay {formatAmount(Number(mo?.wages || 0))} · employer {formatAmount(Number(mo?.employer || 0))}</span></div>
        <div className="mm-stat"><span className="pl-label">A cement bag</span><strong>{bags ? money(r2(total / bags)) : '—'}</strong><span className="pl-help">{bags ? `${formatAmount(bags)} bags this month` : 'no batches this month'}</span></div>
        <div className="mm-stat"><span className="pl-label">Pay not set</span><strong className={unpriced ? 'text-warning' : ''}>{unpriced}</strong><span className="pl-help">{unpriced ? 'worked this month, no rate' : 'everyone has a rate'}</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8, flexWrap: 'wrap' }}>
        <PageTabs nested tabs={[['days', 'By day'], ['months', 'By month']]} value={view} onChange={setView} />
        <Link to="/staff" className="btn btn-ghost btn-sm" style={{ marginLeft: 'auto' }}>Staff ›</Link>
      </div>
      <div className="card"><div className="table-container">
        {view === 'days' ? (
          <table>
            <thead><tr><th>Day</th><th className="num">People</th><th className="num">Days</th><th className="num">Pay (TZS)</th><th className="num">Employer (TZS)</th><th className="num">Labour (TZS)</th><th className="num">Cement bags</th><th className="num">A bag (TZS)</th></tr></thead>
            <tbody>
              {data.days.length === 0 ? <tr><td colSpan={8} className="text-muted">No days yet — mark attendance in HR › Staff.</td></tr>
              : data.days.map(x => (
                <tr key={x.day}>
                  <td>{x.day}{Number(x.without_rate) > 0 && <div className="pl-help text-warning">{x.without_rate} without a day rate</div>}</td>
                  <td className="num">{x.people}</td><td className="num">{Number(x.days)}</td>
                  <td className="num">{formatAmount(Number(x.wages || 0))}</td>
                  <td className="num">{Number(x.employer) ? formatAmount(Number(x.employer)) : ''}</td>
                  <td className="num"><strong>{formatAmount(costOf(x))}</strong></td>
                  <td className="num">{data.bagsDay[x.day] || <span className="pl-help">no batches</span>}</td>
                  <td className="num">{data.bagsDay[x.day] ? formatAmount(costOf(x) / data.bagsDay[x.day]) : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <table>
            <thead><tr><th>Month</th><th className="num">People</th><th className="num">Days</th><th className="num">Pay (TZS)</th><th className="num">Employer (TZS)</th><th className="num">Labour (TZS)</th><th className="num">Cement bags</th><th className="num">A bag (TZS)</th></tr></thead>
            <tbody>
              {data.months.length === 0 ? <tr><td colSpan={8} className="text-muted">No days yet — mark attendance in HR › Staff.</td></tr>
              : data.months.map(x => (
                <tr key={x.month}>
                  <td>{monthName(x.month)}{Number(x.without_rate) > 0 && <div className="pl-help text-warning">{x.without_rate} without a rate</div>}</td>
                  <td className="num">{x.people}</td>
                  <td className="num">{Number(x.days)}</td>
                  <td className="num">{formatAmount(Number(x.wages || 0))}</td>
                  <td className="num">{Number(x.employer) ? formatAmount(Number(x.employer)) : ''}</td>
                  <td className="num"><strong>{formatAmount(costOf(x))}</strong></td>
                  <td className="num">{data.bagsMonth[x.month] || <span className="pl-help">no batches</span>}</td>
                  <td className="num">{data.bagsMonth[x.month] ? formatAmount(costOf(x) / data.bagsMonth[x.month]) : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div></div>
      <p className="pl-help" style={{ marginTop: 8 }}>From HR, as the pay sheets pay it: each production person's days attended × day rate (a salary ÷ working days a month), plus the employer's NSSF, WCF and SDL — shared over that day's batches by cement bags. Office and running staff are left out (untick them in Staff).</p>
    </>
  );
}
