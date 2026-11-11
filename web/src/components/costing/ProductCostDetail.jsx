import { useEffect, useMemo, useState } from 'react';
import { useAuth } from '../../hooks/useAuth';
import { orgToday, qtyText } from '../../lib/inventory';
import { formatAmount, tableDate } from '../../lib/format';
import { loadOutputs, totals, perUnit, trend, standards, standardWindow, keyOf, PART_LABEL } from '../../lib/costingCalc';

/*
 * A product's cost (2026-11-11, migration 118): what one m² or piece costs in its four parts —
 * materials, labour, electricity, overheads — for its latest batch and month by month over the
 * last 6 months, beside its standard (the 3 months before this month). Read only.
 */
const PARTS = ['material', 'labour', 'power', 'overhead'];

export default function ProductCostDetail({ branchId, row, unit, money }) {
  const { organization } = useAuth();
  const today = orgToday(organization?.timezone);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const monthStart = `${today.slice(0, 7)}-01`;
  useEffect(() => {
    const d = new Date(`${monthStart}T00:00:00Z`);
    const from = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - 5, 1)).toISOString().slice(0, 10);
    loadOutputs(branchId, from, today)
      .then(rs => setRows(rs))
      .catch(e => { console.error(e); setError("We couldn't load its costs."); });
  }, [branchId, today, monthStart]);

  const k = keyOf({ product_id: row.product_id, color_id: row.color_id });
  const data = useMemo(() => {
    if (!rows) return null;
    const mine = rows.filter(r => keyOf(r) === k);
    const costed = mine.filter(r => r.material != null && r.qty_cast > 0);
    const last = costed.length ? costed.reduce((a, b) => (b.batch_date >= a.batch_date ? b : a)) : null;
    const lastBatch = last ? costed.filter(r => r.batch_id === last.batch_id) : [];
    const [sFrom, sTo] = standardWindow(monthStart);
    const std = standards(rows.filter(r => r.batch_date >= sFrom && r.batch_date <= sTo)).byKey[k];
    return { latest: last ? { date: last.batch_date, unit: perUnit(totals(lastBatch)) } : null, months: trend(costed), std };
  }, [rows, k, monthStart]);

  if (error) return <p className="text-error">{error}</p>;
  if (!data) return <p className="pl-help">Loading…</p>;
  if (!data.latest) return <p className="pl-help">Not made at this branch in the last 6 months.</p>;
  const max = Math.max(...data.months.map(m => m.unit.total), data.std?.unit ?? 0, 1);
  const r = v => formatAmount(Math.round(v));
  return (
    <div className="pcd">
      <div className="pcd-latest">
        <div className="pl-label">Cost a {unit} · latest batch {tableDate(data.latest.date)}</div>
        <div className="pcd-total"><strong>{money(Math.round(data.latest.unit.total))}</strong>
          {data.std && <span className="pl-help"> · standard {money(Math.round(data.std.unit))}</span>}</div>
        <div className="pcd-bar" aria-hidden="true">
          {PARTS.map(p => <span key={p} className={`pcd-seg pcd-${p}`} style={{ width: `${(data.latest.unit[p] / data.latest.unit.total) * 100}%` }} />)}
        </div>
        <div className="pcd-legend">
          {PARTS.map(p => (
            <span key={p}><i className={`pcd-dot pcd-${p}`} />{PART_LABEL[p]} <strong>{r(data.latest.unit[p])}</strong>
              <span className="pl-help"> {Math.round((data.latest.unit[p] / data.latest.unit.total) * 100)}%</span></span>
          ))}
        </div>
      </div>

      <table className="rd-table">
        <thead><tr><th>Month</th><th className="num">Made</th>
          {PARTS.map(p => <th key={p} className="num">{PART_LABEL[p]}</th>)}<th className="num">Total / {unit}</th><th /></tr></thead>
        <tbody>
          {data.months.map(m => (
            <tr key={m.month}>
              <td>{new Date(`${m.month}-01T00:00:00Z`).toLocaleDateString('en-GB', { month: 'short', year: 'numeric', timeZone: 'UTC' })}</td>
              <td className="num">{qtyText(Math.round(m.made))} <span className="pl-help">{unit}</span></td>
              {PARTS.map(p => <td key={p} className="num">{r(m.unit[p])}</td>)}
              <td className="num"><strong>{r(m.unit.total)}</strong></td>
              <td style={{ width: 90 }}><span className="pcd-mini" style={{ width: `${(m.unit.total / max) * 100}%` }} /></td>
            </tr>
          ))}
          {data.std && (
            <tr className="pcd-std">
              <td title="Recipe × the average material prices, and the branch's labour, electricity and overheads a cement bag, over the 3 months before this month">Standard</td>
              <td />
              {PARTS.map(p => <td key={p} className="num">{r(data.std.parts[p])}</td>)}
              <td className="num"><strong>{r(data.std.unit)}</strong></td>
              <td><span className="pcd-mini pcd-mini-std" style={{ width: `${(data.std.unit / max) * 100}%` }} /></td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
