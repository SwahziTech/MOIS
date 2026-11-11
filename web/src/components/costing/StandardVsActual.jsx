import { Fragment, useEffect, useMemo, useState } from 'react';
import { Scale, ChevronDown, ChevronRight } from 'lucide-react';
import PeriodBar from '../PeriodBar';
import EmptyState from '../EmptyState';
import ErrorState from '../ErrorState';
import { useAuth } from '../../hooks/useAuth';
import { orgToday, qtyText } from '../../lib/inventory';
import { useSessionPeriod } from '../../lib/sessionPeriod';
import { periodRange } from '../../lib/periods';
import { formatMoney, formatAmount, tableDate } from '../../lib/format';
import { loadOutputs, totals, standards, variance, keyOf, standardWindow, CAUSE_LABEL, CAUSE_HELP } from '../../lib/costingCalc';

/*
 * Standard vs actual (PRD 4.13; 2026-11-11, migration 118): for each product made in the period,
 * what it should have cost a unit (from the 3 months before) against what it cost, and why —
 * material prices, materials used against the recipe, labour, electricity, overheads, yield.
 * Rejects are shown apart, at their full cost. Nothing here is typed in: it is all read from
 * production, purchases, expenses and HR as recorded.
 */
const sign = v => (v > 0.5 ? '+' : v < -0.5 ? '−' : '');
const cls = v => (v > 0.5 ? 'text-error' : v < -0.5 ? 'text-success' : 'text-muted');

export default function StandardVsActual({ branchId, refs }) {
  const { organization } = useAuth();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [period, setPeriod] = useSessionPeriod('costing-standard');
  const [from, to] = periodRange(period, today);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [open, setOpen] = useState(null);

  async function load() {
    setError(''); setRows(null);
    try {
      const [sFrom] = standardWindow(from);
      setRows(await loadOutputs(branchId, sFrom, to < today ? to : today));
    } catch (e) { console.error(e); setError("We couldn't load the costs."); }
  }
  useEffect(() => { if (branchId) load(); }, [branchId, from, to]); // eslint-disable-line react-hooks/exhaustive-deps

  const unitOf = id => refs?.unitById[refs?.items[`p:${id}`]?.stockUnitId]?.symbol ?? '';
  const per = id => (unitOf(id).toUpperCase() === 'SQM' ? 'm²' : 'pc');
  const nameOf = r => `${refs?.items[`p:${r.product_id}`]?.name ?? ''}${r.color_id ? ` ${refs?.colorById[r.color_id]?.name ?? ''}` : ''}`;

  const data = useMemo(() => {
    if (!rows) return null;
    const [sFrom, sTo] = standardWindow(from);
    const before = rows.filter(r => r.batch_date >= sFrom && r.batch_date <= sTo);
    const now = rows.filter(r => r.batch_date >= from && r.batch_date <= to);
    const s = standards(before);
    const groups = {};
    for (const r of now) (groups[keyOf(r)] ||= []).push(r);
    const list = Object.values(groups).map(rs => {
      const t = totals(rs);
      const std = s.byKey[keyOf(rs[0])];
      return { key: keyOf(rs[0]), first: rs[0], t, v: variance(t, std, s), std };
    }).filter(x => x.t.qtyCast > 0)
      .sort((a, b) => Math.abs(b.v?.diff ?? 0) - Math.abs(a.v?.diff ?? 0));
    const sum = { std: 0, actual: 0, rejects: 0, causes: {} };
    for (const x of list) {
      if (!x.v) continue;
      sum.std += x.v.stdTotal; sum.actual += x.v.actualTotal; sum.rejects += x.v.rejects.cost;
      for (const [k, v] of Object.entries(x.v.causes)) sum.causes[k] = (sum.causes[k] || 0) + v;
    }
    const top = Object.entries(sum.causes).sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))[0];
    return { list, sum, top, window: [sFrom, sTo], noStd: list.filter(x => !x.v).length };
  }, [rows, from, to]);

  return (
    <>
      <PeriodBar value={period} onChange={setPeriod} today={today} />
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : !data ? <div className="card"><span className="skeleton" /></div>
      : <>
        <div className="mm-stats">
          <div className="mm-stat"><span className="pl-label">Actual cost</span><strong className="mm-money">{money(Math.round(data.sum.actual))}</strong>
            <span className="pl-help">standard {money(Math.round(data.sum.std))}</span></div>
          <div className="mm-stat"><span className="pl-label">Difference</span>
            <strong className={cls(data.sum.actual - data.sum.std)}>{sign(data.sum.actual - data.sum.std)}{money(Math.round(Math.abs(data.sum.actual - data.sum.std)))}</strong>
            {data.top && Math.abs(data.top[1]) > 0.5 && <span className="pl-help" title={CAUSE_HELP[data.top[0]]}>most from {CAUSE_LABEL[data.top[0]].toLowerCase()}</span>}</div>
          <div className="mm-stat"><span className="pl-label">Rejects</span><strong className={data.sum.rejects > 0.5 ? 'text-error' : ''}>{money(Math.round(data.sum.rejects))}</strong>
            <span className="pl-help">at full cost</span></div>
        </div>

        {data.list.length === 0 ? <div className="card"><EmptyState icon={Scale} title="Nothing made in this period" description="Products made in the period are compared with their standard here." /></div> : (
          <div className="card"><div className="table-container">
            <table className="rd-table sva-table">
              <thead><tr>
                <th>Product</th><th className="num">Made</th>
                <th className="num" title={`What it should cost a unit — from the 3 months before (${tableDate(data.window[0])} to ${tableDate(data.window[1])})`}>Standard</th>
                <th className="num">Actual</th><th className="num">Difference</th><th className="num">Rejects</th>
              </tr></thead>
              <tbody>
                {data.list.map(x => {
                  const p = per(x.first.product_id);
                  const isOpen = open === x.key;
                  const d = x.v ? x.v.actualUnit - x.v.stdUnit : null;
                  return (
                    <Fragment key={x.key}>
                      <tr className="clickable-row" onClick={() => setOpen(isOpen ? null : x.key)} title={x.v ? 'Show why' : undefined}>
                        <td>{x.v ? (isOpen ? <ChevronDown size={13} /> : <ChevronRight size={13} />) : null} <strong>{nameOf(x.first)}</strong>
                          <div className="pl-help">{x.t.count} batch{x.t.count === 1 ? '' : 'es'}</div></td>
                        <td className="num">{qtyText(Math.round(x.t.qtyCast))} <span className="pl-help">{p}</span></td>
                        <td className="num">{x.v ? formatAmount(Math.round(x.v.stdUnit)) : <span className="pl-help" title="Not made in the 3 months before, so there is nothing to compare with yet">—</span>}</td>
                        <td className="num">{formatAmount(Math.round(x.t.total / x.t.qtyCast))}</td>
                        <td className={`num ${d != null ? cls(d * x.t.qtyCast) : ''}`}>{d != null ? <>{sign(d * x.t.qtyCast)}{formatAmount(Math.round(Math.abs(d)))} <span className="pl-help">/{p} · {Math.round((d / x.v.stdUnit) * 100)}%</span></> : ''}</td>
                        <td className={`num ${x.v?.rejects.cost > 0.5 ? 'text-error' : 'text-muted'}`}>{x.v?.rejects.qty > 0 ? <>{qtyText(Math.round(x.v.rejects.qty * 100) / 100)} <span className="pl-help">{p}</span></> : '—'}</td>
                      </tr>
                      {isOpen && x.v && (
                        <tr className="sva-why"><td colSpan={6}>
                          <div className="sva-causes">
                            {Object.entries(x.v.causes).map(([k, v]) => (
                              <div key={k} className="sva-cause" title={CAUSE_HELP[k]}>
                                <span className="pl-help">{CAUSE_LABEL[k]}</span>
                                <strong className={cls(v)}>{Math.abs(v) < 0.5 ? '—' : `${sign(v)}${money(Math.round(Math.abs(v)))}`}</strong>
                              </div>
                            ))}
                            <div className="sva-cause sva-total"><span className="pl-help">Total</span>
                              <strong className={cls(x.v.diff)}>{sign(x.v.diff)}{money(Math.round(Math.abs(x.v.diff)))}</strong></div>
                            {x.v.rejects.cost > 0.5 && <div className="sva-cause" title="Pieces that failed quality, at their full cost — a loss on top"><span className="pl-help">Rejects</span>
                              <strong className="text-error">{money(Math.round(x.v.rejects.cost))}</strong></div>}
                          </div>
                          <p className="pl-help">+ costs more than the standard, − costs less. Standard from {tableDate(data.window[0])} to {tableDate(data.window[1])}: recipe × average material prices, the branch's labour, electricity and overheads a cement bag, the usual yield.</p>
                        </td></tr>
                      )}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div></div>
        )}
        {data.noStd > 0 && <p className="pl-help">{data.noStd} product{data.noStd === 1 ? ' was' : 's were'} not made in the 3 months before, so {data.noStd === 1 ? 'it has' : 'they have'} no standard yet.</p>}
      </>}
    </>
  );
}
