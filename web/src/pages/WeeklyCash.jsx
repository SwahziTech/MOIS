import SheetGrid from '../components/SheetGrid';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Wallet, Plus, Upload, Download, Copy, Pencil, Lock, Save, Undo2, RotateCcw, Trash2, Maximize2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatMoneyShort, formatAmount, dateText, tableDate } from '../lib/format';
import { loadInventoryRefs, orgToday, qtyText } from '../lib/inventory';
import PeriodSelect, { usePeriod } from '../components/PeriodSelect';
import { dbErrorMessage } from '../lib/masterData';
import { readWeeklySheet, listWeeklySheets } from '../lib/weeklyCashExcel';
import { guessCategory, fillCategories } from '../lib/expenseGuess';
import WeeklyCashDocDialog from '../components/finance/WeeklyCashDocDialog';
import WeeklyCashViewer from '../components/finance/WeeklyCashViewer';
import { PayModal } from '../components/dashboard/DirectorPayments';
import { useSearchParams } from 'react-router-dom';
import { saveWeeklyCash } from '../components/purchases/PaidFrom';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';

const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const r2 = n => Math.round(n * 100) / 100;
const addDays = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const saturdayOf = d => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return addDays(d, (6 - w + 7) % 7); };
// "Sat, 31 Oct – Sat, 7 Nov 2026"
const weekRange = (a, b) => `${a.slice(0, 4) === b.slice(0, 4) ? dateText(a).replace(/ \d{4}$/, '') : dateText(a)} – ${dateText(b)}`;
// last week's summary works like the sheet's formulas (2026-11-15, the user): the person types the
// balance, the cash sent and the items; TOTAL CASH, each running balance, TOTAL CASH (out) and the
// closing BALANCE are worked out, and the last two rows always stay last.
const FORMULA_ROW = /^\s*(balance|cash\s*sent|total)/i;
// any rows (imported, typed, saved) → { date, opening, sent, items }
function sheetParts(rows) {
  const bal = rows.find(r => /^\s*balance\s*$/i.test(r.description || ''));
  const sent = rows.find(r => /cash\s*sent/i.test(r.description || ''));
  return { date: bal?.date ?? '', opening: bal?.cash_in ?? '', sent: sent?.cash_in ?? '',
    items: rows.filter(r => !FORMULA_ROW.test(r.description || '')).map(r => ({ date: r.date ?? '', description: r.description ?? '', qty: r.qty ?? '', cash_out: r.cash_out ?? '', category_id: r.category_id ?? '' })) };
}
// the parts → the sheet, every formula worked out
function sheetRows(p) {
  const totalIn = r2((num(p.opening) ?? 0) + (num(p.sent) ?? 0));
  let b = totalIn;
  const items = p.items.map(i => { b = r2(b - (num(i.cash_out) ?? 0)); return { ...i, kind: 'item', balance: b }; });
  const spent = r2(p.items.reduce((t, i) => t + (num(i.cash_out) ?? 0), 0));
  return [
    { kind: 'open', date: p.date, description: 'BALANCE', cash_in: p.opening, bold: true },
    { kind: 'sent', description: 'CASH SENT', cash_in: p.sent, bold: true },
    { kind: 'total_in', description: 'TOTAL CASH', cash_in: totalIn, bold: true },
    ...items,
    { kind: 'total_out', description: 'TOTAL CASH', cash_out: spent, bold: true },
    { kind: 'close', description: 'BALANCE', cash_in: r2(totalIn - spent), bold: true },
  ];
}
// rows kept in the database: plain values
const storeRows = p => sheetRows({ ...p, items: p.items.filter(i => [i.date, i.description, i.qty, i.cash_out].some(v => String(v ?? '').trim())) })
  .map(({ date, description, qty, cash_in, cash_out, balance, category_id }) => ({ date: String(date ?? '').trim(), description: String(description ?? '').trim(), qty: String(qty ?? '').trim(), cash_in: num(cash_in), cash_out: num(cash_out), balance: num(balance), category_id: category_id || null }));
// a summary as written → its figures
function sheetSums(rows) {
  const rs = sheetRows(sheetParts(rows));
  return { opening: num(rs[0].cash_in), sent: num(rs[1].cash_in) ?? 0, spent: rs[rs.length - 2].cash_out, closing: rs[rs.length - 1].cash_in };
}
const STATUS = { draft: ['Draft', 'badge-neutral'], with_directors: ['With directors', 'badge-warning'], approved: ['Approved', 'badge-info'], rejected: ['Turned down', 'badge-error'], paid: ['Paid', 'badge-success'], cancelled: ['Cancelled', 'badge-neutral'] };
const asked = r => (r.lines || []).reduce((t, l) => t + Number(l.amount), 0);
const approvedOf = r => (r.lines || []).reduce((t, l) => t + Number(l.approved_amount ?? l.amount), 0);

/*
 * Weekly operations cash (2026-10-28, migration 078): each week the branch
 * asks for what it needs — prepared by the secretary or branch manager,
 * approved and sent by the branch manager, approved by the directors (who
 * may trim lines), paid to the branch in one payment. Last week's summary is
 * read from what was recorded (expenses and payments to suppliers paid that
 * week): balance brought forward + cash sent − spent = balance. Where the
 * money is sent (bank, account number and name) is written on the request. A request
 * can be imported from the branch's Excel sheet or filled here, and exported
 * in the same layout.
 */
// embed: { id, branch } — only that request's document, full screen, over the page the person is on
// (the directors' View, 2026-11-16: no going to Finance; closing leaves them where they were)
export default function WeeklyCash({ embed = null, onEmbedClose, onEmbedSaved }) {
  const { organization, canAt } = useAuth();
  const { branchId: ctxBranch, branchName: ctxName, setBranchId, branches } = useBranch();
  const branchId = embed?.branch || ctxBranch;
  const branchName = embed ? (branches || []).find(b => b.id === embed.branch)?.name ?? null : ctxName;
  // opened from the director's card: ?open=<request>&branch=<branch>&view=1 → that request, full screen (2026-11-16)
  const [params, setParams] = useSearchParams();
  const wantOpen = params.get('open');
  const wantView = params.get('view') === '1';
  const money = v => formatMoney(v, organization?.currency_code);
  const today = orgToday(organization?.timezone);
  const period = usePeriod(today);   // this week first; or a dashboard card's period
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [open, setOpen] = useState(null);       // a request, or { new: true }

  async function load() {
    setError('');
    if (!branchId) { setData(null); return; }
    const since = addDays(today, -400);
    const [rq, ex, pp, cats, refs] = await Promise.all([
      supabase.from('cash_requests').select('*, lines:cash_request_lines(*)').eq('branch_id', branchId).order('week_ending', { ascending: false }),
      // '*' so from_weekly_cash (121) comes along once it exists
      supabase.from('expenses').select('*').eq('branch_id', branchId).eq('status', 'recorded').gt('amount_paid', 0).gte('paid_on', since),
      supabase.from('purchase_payments').select('*, purchase:purchases!inner(branch_id, supplier_id, status, movement_id)').eq('purchase.branch_id', branchId).eq('purchase.status', 'recorded').gte('paid_on', since),
      supabase.from('expense_categories').select('id, name, status').order('display_order').order('name'),
      loadInventoryRefs(),
    ]);
    if (rq.error) { console.error(rq.error); setError("We couldn't load the weekly cash requests."); return; }
    // what was bought with each purchase payment: its materials, from the receipt
    const moveIds = [...new Set((pp.data || []).map(p => p.purchase.movement_id))];
    const tx = moveIds.length ? (await supabase.from('inventory_transactions').select('movement_id, material_id, entered_quantity, entered_unit_id').in('movement_id', moveIds)).data || [] : [];
    setData({ requests: rq.data || [], expenses: ex.data || [], payments: pp.data || [], cats: cats.data || [], refs, tx });
  }
  useEffect(() => { setData(null); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (embed) return; const b = params.get('branch'); if (b && b !== branchId) setBranchId(b); }, [params]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (embed || !wantOpen || !data) return;
    const r = data.requests.find(x => x.id === wantOpen);
    if (r) { setOpen({ ...r, __view: wantView }); setParams({}, { replace: true }); }
  }, [wantOpen, data]); // eslint-disable-line react-hooks/exhaustive-deps

  // money spent in a week (Sunday–Saturday) from the weekly cash: expenses paid and payments to
  // suppliers marked "Weekly cash (branch)" (121); others = paid by the directors · bank, to tick in
  const spentIn = useMemo(() => (weekEnding, which = 'weekly') => {
    if (!data) return [];
    const pick = r => (which === 'others' ? r.from_weekly_cash === false : r.from_weekly_cash !== false);
    const from = addDays(weekEnding, -6);
    const inWeek = d => d && d >= from && d <= weekEnding;
    const supplier = id => data.refs.suppliers.find(s => s.id === id)?.name ?? '';
    const goods = mid => data.tx.filter(t => t.movement_id === mid && t.material_id)
      .map(t => `${data.refs.items[`m:${t.material_id}`]?.name ?? ''}`).join(', ');
    const qtyOfMove = mid => data.tx.filter(t => t.movement_id === mid && t.material_id)
      .map(t => `${qtyText(Number(t.entered_quantity))} ${data.refs.unitById[t.entered_unit_id]?.symbol ?? ''}`).join(', ');
    return [
      ...data.expenses.filter(e => inWeek(e.paid_on) && pick(e)).map(e => ({ kind: 'expense', id: e.id, date: e.paid_on, description: e.description, qty: e.quantity ? qtyText(Number(e.quantity)) : '', amount: Number(e.amount_paid), category_id: e.category_id ?? '' })),
      ...data.payments.filter(p => inWeek(p.paid_on) && pick(p)).map(p => ({ kind: 'purchase_payment', id: p.id, date: p.paid_on, description: `${goods(p.purchase.movement_id) || 'Purchase'}${supplier(p.purchase.supplier_id) ? ` — ${supplier(p.purchase.supplier_id)}` : ''}`, qty: qtyOfMove(p.purchase.movement_id), amount: Number(p.amount) })),
    ].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  }, [data]);

  // The sheet dated Saturday W (2026-11-15, the user): "last week's spending" is the week just ended
  // (W−7 to W), paid from the cash sent on the request of W−7; "this week's request" is W to W+7.
  // Balance + cash sent − spent = balance carried. A week whose summary was imported or edited is
  // taken exactly as written (cash_requests.last_week).
  const ledger = useMemo(() => {
    if (!data) return {};
    const live = data.requests.filter(r => !['cancelled', 'rejected'].includes(r.status)).sort((a, b) => (a.week_ending < b.week_ending ? -1 : 1));
    if (!live.length) return {};
    const out = {};
    let bal = 0;
    const w0 = live[0].week_ending;
    for (let w = w0; w <= saturdayOf(today); w = addDays(w, 7)) {
      const req = live.find(r => r.week_ending === w);
      const prev = live.find(r => r.week_ending === addDays(w, -7));
      if (req?.last_week?.rows?.length) {
        const s = sheetSums(req.last_week.rows);
        bal = s.closing ?? (req.opening_balance != null ? Number(req.opening_balance) : bal);
        out[w] = { week: w, fromSheet: true, opening: s.opening, sent: s.sent, spent: s.spent, closing: bal, lines: [] };
        continue;
      }
      if (w === w0) {   // the first week in MOIS without a sheet: its balance is typed
        bal = req?.opening_balance != null ? Number(req.opening_balance) : 0;
        const lines = spentIn(w);
        out[w] = { week: w, first: true, opening: null, sent: 0, spent: r2(lines.reduce((t, l) => t + l.amount, 0)), closing: bal, lines };
        continue;
      }
      const opening = bal;
      const sent = prev?.status === 'paid' ? Number(prev.paid_amount) : 0;
      const lines = spentIn(w);
      const spent = lines.reduce((t, l) => t + l.amount, 0);
      bal = r2(opening + sent - spent);
      out[w] = { week: w, opening, sent, spent: r2(spent), closing: bal, lines };
    }
    return out;
  }, [data, spentIn, today]);
  // a week after the last one worked out (a request dated ahead)
  const weekOf = w => {
    if (ledger[w]) return ledger[w];
    const p = ledger[addDays(w, -7)];
    if (!p) return null;
    const prev = data.requests.find(r => r.week_ending === addDays(w, -7) && !['cancelled', 'rejected'].includes(r.status));
    const sent = prev?.status === 'paid' ? Number(prev.paid_amount) : 0;
    const lines = spentIn(w);
    const spent = r2(lines.reduce((t, l) => t + l.amount, 0));
    return { week: w, opening: p.closing, sent, spent, closing: r2(p.closing + sent - spent), lines };
  };

  const here = data?.requests || [];
  const shownWeeks = here.filter(r => r.week_ending >= period.from && addDays(r.week_ending, -6) <= period.to);
  const lastSat = saturdayOf(today) === today ? today : addDays(saturdayOf(today), -7);
  const liveAt = w => here.find(r => r.week_ending === w && !['cancelled', 'rejected'].includes(r.status));
  const thisWeek = liveAt(addDays(saturdayOf(today), -7));   // the request whose week we are in
  const lastClosed = ledger[addDays(saturdayOf(today), -7)];
  // a new request: dated the last Saturday, unless that one exists already
  const newWeek = liveAt(lastSat) ? saturdayOf(addDays(lastSat, 1)) : lastSat;
  const canPrepare = !!branchId && canAt('cash.request', branchId);
  // a cancelled import can be deleted or used again — only cancelled ones (123, 2026-11-15, the user)
  const [askDel, setAskDel] = useState(null);   // request id waiting for "Delete?"
  const [rowBusy, setRowBusy] = useState('');
  const canDelete = r => canPrepare && r.status === 'cancelled' && !r.sent_by && !(r.lines || []).some(l => l.pay_sheet_id);
  async function rowAction(fn, r) {
    setRowBusy(r.id); setError('');
    const { error: err } = await supabase.rpc(fn, { p_id: r.id });
    setRowBusy(''); setAskDel(null);
    if (err) { setActionError(/delete_cash_request|reopen_cash_request/.test(err.message || '') ? 'This needs the latest database update (123).' : dbErrorMessage(err)); return; }
    setActionError(''); await load();
  }
  const [actionError, setActionError] = useState('');

  if (embed) {
    const r = data?.requests.find(x => x.id === embed.id);
    if (!r) return null;
    return <RequestModal key={r.id} viewOnly startView request={r} newWeek={newWeek} branchId={branchId} branchName={branchName} data={data} weekOf={weekOf} spentIn={spentIn} today={today} money={money}
      organization={organization} onRefresh={load} onClose={() => onEmbedClose?.()} onSaved={() => onEmbedSaved?.()} />;
  }
  return (
    <PageShell title="Weekly cash" subtitle="Finance"
      description={branchId ? branchName : 'Pick a branch in the sidebar'}
      primaryAction={canPrepare && data && <button type="button" className="btn btn-primary" onClick={() => setOpen({ new: true })}><Plus size={15} /> New weekly request</button>}>
      {!branchId ? <div className="card"><EmptyState icon={Wallet} title="Pick a branch" description="Weekly cash is per branch." /></div>
      : error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : data === null ? <div className="card"><span className="skeleton" /></div> : (
        <>
          <div className="mm-stats">
            <div className="mm-stat"><span className="pl-label">This week</span><strong>{thisWeek ? money(approvedOf(thisWeek)) : '—'}</strong><span className="pl-help">{thisWeek ? `${STATUS[thisWeek.status][0]} · week ending ${dateText(thisWeek.week_ending)}` : 'no request yet'}</span></div>
            <div className="mm-stat"><span className="pl-label">With directors</span><strong className={here.some(r => r.status === 'with_directors') ? 'text-warning' : ''}>{here.filter(r => r.status === 'with_directors').length}</strong><span className="pl-help">waiting for approval</span></div>
            <div className="mm-stat"><span className="pl-label">Last week's balance</span><strong>{lastClosed ? money(lastClosed.closing) : '—'}</strong><span className="pl-help">{lastClosed ? `spent ${formatMoneyShort(lastClosed.spent, organization?.currency_code)}` : 'from the first request on'}</span></div>
          </div>
          <div><PeriodSelect period={period} today={today} extra={[['all', 'All time']]} /></div>
          <div className="card"><div className="table-container">
            <table>
              <thead><tr><th>Week ending</th><th>Status</th><th className="num">Asked (TZS)</th><th className="num">Sent (TZS)</th><th className="num">Spent (TZS)</th><th className="num">Balance (TZS)</th><th aria-label="Actions" style={{ width: 120 }} /></tr></thead>
              <tbody>
                {shownWeeks.length === 0 ? <tr><td colSpan={7} className="text-muted">{here.length ? 'No weekly request in this period.' : <>No requests yet.</>}</td></tr>
                : shownWeeks.map(r => {
                  const w = ledger[r.week_ending];
                  return (
                    <tr key={r.id} className="clickable-row" onClick={() => setOpen(r)}>
                      <td>{tableDate(r.week_ending)}{r.source === 'excel' && <div className="pl-help">from Excel</div>}</td>
                      <td><span className={`badge ${STATUS[r.status][1]}`}>{STATUS[r.status][0]}</span></td>
                      <td className="num">{formatAmount(asked(r))}</td>
                      <td className="num">{r.status === 'paid' ? formatAmount(Number(r.paid_amount)) : ''}</td>
                      <td className="num">{w ? formatAmount(w.spent) : ''}</td>
                      <td className="num"><strong>{w ? formatAmount(w.closing) : ''}</strong></td>
                      <td className="wc-row-act" onClick={e => e.stopPropagation()}>
                        {askDel === r.id ? <span className="flex items-center gap-8">
                          <span className="text-sm">Delete?</span>
                          <button type="button" className="btn btn-ghost btn-sm text-error" disabled={rowBusy === r.id} onClick={() => rowAction('delete_cash_request', r)}>Yes</button>
                          <button type="button" className="btn btn-ghost btn-sm" onClick={() => setAskDel(null)}>No</button>
                        </span> : <>
                          {canPrepare && r.status === 'cancelled' && <button type="button" className="btn btn-ghost btn-sm" disabled={rowBusy === r.id} title="Use again — back to draft" aria-label="Use again" onClick={() => rowAction('reopen_cash_request', r)}><RotateCcw size={14} /></button>}
                          {canDelete(r) && <button type="button" className="btn btn-ghost btn-sm" title="Delete this cancelled request" aria-label="Delete" onClick={() => setAskDel(r.id)}><Trash2 size={14} /></button>}
                        </>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div></div>
          {actionError && <p className="text-sm text-error" role="alert" style={{ marginTop: 8 }}>{actionError}</p>}
          <p className="pl-help" style={{ marginTop: 8 }} title={"A week runs Sunday to Saturday. Spent = expenses and payments to suppliers recorded as paid that week (Purchases). Balance = brought forward + cash sent − spent, carried into the next week."}>Balance = brought forward + sent − spent.</p>
        </>
      )}
      {open && <RequestModal key={open.id ?? 'new'} startView={!!open.__view} request={open.new ? null : open} newWeek={newWeek} branchId={branchId} branchName={branchName} data={data} weekOf={weekOf} spentIn={spentIn} today={today} money={money}
        organization={organization} onRefresh={load} onClose={() => setOpen(null)} onSaved={async () => { setOpen(null); await load(); }} />}
    </PageShell>
  );
}

function RequestModal({ viewOnly = false, startView = false, request, newWeek, branchId, branchName, data, weekOf, spentIn = () => [], today, money, organization, onRefresh, onClose, onSaved }) {
  const { canAt } = useAuth();
  const isNew = !request;
  const editable = isNew || request.status === 'draft';
  const prevLive = data.requests.filter(r => !['cancelled', 'rejected'].includes(r.status) && r.id !== request?.id).sort((a, b) => (a.week_ending < b.week_ending ? 1 : -1))[0];
  const [week, setWeek] = useState(request?.week_ending ?? newWeek ?? saturdayOf(today));
  // where the money is sent: written on the request, carried from the previous week's
  // accounts the branch used before, the latest first: the last one fills in by itself; another can be picked (2026-11-15, the user)
  const savedAccounts = useMemo(() => {
    const seen = new Map();
    for (const r of [...data.requests].filter(x => x.id !== request?.id).sort((a, b) => String(b.updated_at ?? b.week_ending).localeCompare(String(a.updated_at ?? a.week_ending)))) {
      const a = { bank: (r.pay_bank ?? '').trim(), no: (r.pay_account_no ?? '').trim(), name: (r.pay_account_name ?? '').trim() };
      if (!a.bank && !a.no && !a.name) continue;
      const k = `${a.bank}|${a.no}|${a.name}`.toLowerCase();
      if (!seen.has(k)) seen.set(k, a);
    }
    return [...seen.values()];
  }, [data.requests, request?.id]);
  const [payTo, setPayTo] = useState(() => (request && (request.pay_bank || request.pay_account_no || request.pay_account_name)
    ? { bank: request.pay_bank ?? '', no: request.pay_account_no ?? '', name: request.pay_account_name ?? '' }
    : savedAccounts[0] ? { ...savedAccounts[0] } : { bank: '', no: '', name: '' }));
  const [opening, setOpening] = useState(request?.opening_balance != null ? String(Number(request.opening_balance)) : '');
  const [notes, setNotes] = useState(request?.notes ?? '');
  const [source, setSource] = useState(request?.source ?? 'app');
  // what the branch chose before, newest first: the same item gets the same category (2026-11-15)
  // it learns from every saved choice (2026-11-15, the user): request lines, last week's spending rows and the
  // expenses recorded — the latest choice for the same item wins
  const catHistory = useMemo(() => [
    ...[...data.requests].sort((a, b) => String(b.updated_at ?? b.week_ending).localeCompare(String(a.updated_at ?? a.week_ending)))
      .flatMap(r => [...(r.lines || []).map(l => ({ description: l.description, category_id: l.category_id })),
        ...((r.last_week?.rows) || []).map(x => ({ description: x.description, category_id: x.category_id }))]),
    ...[...data.expenses].sort((a, b) => String(b.paid_on ?? '').localeCompare(String(a.paid_on ?? ''))).map(e => ({ description: e.description, category_id: e.category_id })),
  ].filter(h => h.category_id && h.description), [data.requests, data.expenses]);
  const [lines, setLinesRaw] = useState(() => {
    const ls = request?.lines?.length
      ? [...request.lines].sort((a, b) => a.line_no - b.line_no).map(l => ({ id: l.id, description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unit: l.unit ?? '', amount: String(Number(l.amount)), approved: l.approved_amount != null ? String(Number(l.approved_amount)) : '', categoryId: l.category_id ?? '', locked: !!l.pay_sheet_id }))
    : [{ description: '', quantity: '', unit: '', amount: '', categoryId: '' }];
    return isNew || request.status === 'draft' ? fillCategories(ls, data.cats, catHistory).map(l => ({ ...l, catAuto: !l.locked && !!l.categoryId && !ls.find(x => x === l) })) : ls;
  });
  const setLines = setLinesRaw;
  // typing an item: its category is guessed, unless someone picked one by hand
  function onLinesChange(next) {
    setLinesRaw(prev => next.map((l, i) => {
      const was = prev[i];
      if (l.locked) return l;
      if (was && l.categoryId !== was.categoryId) return { ...l, catAuto: false };   // chosen by hand
      if (l.description !== was?.description && (!l.categoryId || l.catAuto)) {
        const g = guessCategory(l.description, data.cats, catHistory);
        return { ...l, categoryId: g || (l.catAuto ? '' : l.categoryId), catAuto: !!g };
      }
      return l;
    }));
  }
  const [pay, setPay] = useState({ paid_on: today, amount: '', reference: '' });
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [docMode, setDocMode] = useState(null);   // 'export' | 'review'
  const [viewing, setViewing] = useState(startView);   // the report full screen (2026-11-16)
  const [savedId, setSavedId] = useState(null);   // a new request saved without closing the window
  const [payTouched, setPayTouched] = useState(false);   // bank details typed here win over the imported sheet's
  const fileRef = useRef(null);
  const firstEver = !data.requests.some(r => !['cancelled', 'rejected'].includes(r.status) && r.id !== request?.id && r.week_ending < week);   // the first request in MOIS
  const total = lines.reduce((t, l) => t + (num(l.amount) ?? 0), 0);
  const approvedTotal = lines.reduce((t, l) => t + (num(l.approved) ?? num(l.amount) ?? 0), 0);
  const st = request?.status ?? 'draft';
  const poster = canAt('cash.branch_approve', branchId);   // the branch manager posts; the secretary submits
  const primaryLabel = poster ? 'Post request' : 'Submit request';

  // last week's summary as written (imported from the sheet, or edited here) — or worked out from the records
  const [sheetLW, setSheetLW] = useState(request?.last_week?.rows ?? null);
  const fig = weekOf(week);
  const lwRows = useMemo(() => {
    if (sheetLW?.length) return sheetRows(sheetParts(sheetLW));
    if (fig && !fig.first) return sheetRows({ date: addDays(week, -7), opening: fig.opening, sent: fig.sent, items: fig.lines.map(l => ({ date: l.date, description: l.description, qty: l.qty, cash_out: l.amount, category_id: l.category_id ?? '' })) });
    const rec = spentIn(week);
    return [
      ...rec.map(l => ({ date: l.date, description: l.description, qty: l.qty, cash_out: l.amount })),
      { description: 'TOTAL CASH', cash_out: r2(rec.reduce((t, l) => t + l.amount, 0)), bold: true },
      ...(num(opening) != null ? [{ description: 'BALANCE', cash_in: num(opening), bold: true }] : []),
    ];
  }, [sheetLW, fig, spentIn, week, opening]);
  const lwTitle = `LAST WEEK'S SPENDING: ${weekRange(addDays(week, -7), week)}`;
  const reqTitle = `THIS WEEK'S REQUEST: ${dateText(week).replace(/, (\d) /, ', 0$1 ')}`;   // one date: "Sat, 07 Nov 2026" (2026-11-15, the user)

  // last week's summary, edited like the sheet (2026-11-15, the user): the formulas work as you type,
  // the two total rows stay last with an empty line above them for a new item; undo; saved by itself
  const [lwEdit, setLwEdit] = useState(null);   // { parts, dirty, at }
  const [lwHist, setLwHist] = useState([]);      // every earlier state, kept after saving (2026-11-15, the user: undo undoes all)
  const [lwSaved, setLwSaved] = useState('');   // '' | 'saving' | 'saved'
  const startEdit = () => {
    const p = sheetParts(lwRows.filter(r => r.kind !== 'total_out' && r.kind !== 'close'));
    const s = v => (v == null ? '' : String(v));
    setLwEdit({ parts: { date: /^\d{4}-\d{2}-\d{2}$/.test(p.date || '') ? tableDate(p.date) : s(p.date), opening: s(p.opening), sent: s(p.sent),
      items: p.items.map(i => ({ ...i, date: /^\d{4}-\d{2}-\d{2}$/.test(i.date || '') ? tableDate(i.date) : s(i.date), cash_out: s(i.cash_out), category_id: i.category_id || guessCategory(i.description, data.cats, catHistory) })) }, dirty: false, at: 0 });
    setLwSaved('');
  };
  const editRows = lwEdit ? sheetRows(lwEdit.parts) : [];
  function onEditRows(next) {
    const [o, sn] = next;
    const parts = { date: o.date ?? '', opening: o.cash_in ?? '', sent: sn.cash_in ?? '', items: next.slice(3).filter(r => r.kind !== 'total_out' && r.kind !== 'close').map(r => ({ date: r.date ?? '', description: r.description ?? '', qty: r.qty ?? '', cash_out: r.cash_out ?? '', category_id: r.category_id || (String(r.description ?? '').trim() ? guessCategory(r.description, data.cats, catHistory) : '') })) };
    const now = Date.now();
    if (now - lwEdit.at > 800) setLwHist(h => [...h, lwEdit.parts].slice(-200));   // a typed word is one step back
    setLwEdit({ parts, dirty: true, at: now });
  }
  // back one step at a time, through saved changes too, to how it was when the window opened; the step back is saved
  function undoEdit() {
    if (!lwHist.length) return;
    setLwEdit(e => ({ ...(e || {}), parts: lwHist[lwHist.length - 1], dirty: true, at: 0 }));
    setLwHist(h => h.slice(0, -1));
  }
  // saved by itself a moment after the last change
  const saveTimer = useRef(null);
  useEffect(() => {
    if (!lwEdit?.dirty) return undefined;
    clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => persistSheet(storeRows(lwEdit.parts)), 1500);
    return () => clearTimeout(saveTimer.current);
  }, [lwEdit?.parts]); // eslint-disable-line react-hooks/exhaustive-deps
  const withCats = rows => rows && rows.map(r => (FORMULA_ROW.test(r.description || '') || r.category_id ? r : { ...r, category_id: guessCategory(r.description, data.cats, catHistory) || null }));
  async function persistSheet(rows) {
    rows = withCats(rows);
    setSheetLW(rows);
    if (!request && !savedId) return;
    setLwSaved('saving');
    const id = await save({ keepOpen: true, lastWeek: rows });
    setLwSaved(id !== null ? 'saved' : '');
  }
  async function stopEdit() {
    clearTimeout(saveTimer.current);
    if (lwEdit?.dirty) await persistSheet(storeRows(lwEdit.parts));
    setLwEdit(null);
  }
  async function saveBoth() {
    clearTimeout(saveTimer.current);
    let rows = sheetLW;
    if (lwEdit) { rows = withCats(storeRows(lwEdit.parts)); setSheetLW(rows); setLwEdit(e => ({ ...e, dirty: false })); }
    const id = await save({ keepOpen: true, lastWeek: rows });
    if (id !== null) setLwSaved('saved');
  }
  async function useRecords() {
    clearTimeout(saveTimer.current);
    setLwEdit(null); setSheetLW(null);
    if (!isNew) await save({ keepOpen: true, lastWeek: null });
  }

  // last week's payments: which came from the weekly cash (tick in / out, 121)
  const lwAll = useMemo(() => [...spentIn(week).map(l => ({ ...l, on: true })), ...spentIn(week, 'others').map(l => ({ ...l, on: false }))]
    .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0)), [spentIn, week]);
  const showTick = canAt('cash.request', branchId) && !sheetLW?.length && !lwEdit && lwAll.length > 0;
  const [ticking, setTicking] = useState('');
  async function tick(l) {
    setTicking(l.id); setError('');
    const { error: err } = await supabase.rpc('set_weekly_cash', { p_kind: l.kind, p_id: l.id, p_on: !l.on });
    if (err) setError(dbErrorMessage(err));
    else await onRefresh?.();
    setTicking('');
  }
  // approve as asked; then the approving director is asked "Pay now?" (2026-11-16, the user)
  const [askPay, setAskPay] = useState(false);
  const [paying, setPaying] = useState(false);
  async function approveIt(n) {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('cash_request_step', { p_id: request.id, p_step: 'approve', p: { note: n, lines: lines.map(l => ({ id: l.id, approved_amount: null })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setViewing(false);
    if (canAt('finance.pay', branchId, null)) setAskPay(true); else onSaved();
  }
  const step = async (name, p = {}) => {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('cash_request_step', { p_id: request.id, p_step: name, p });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  };
  // the casual wages line comes from the approved pay sheet and stays as it is (115)
  const filled = () => lines.filter(l => !l.locked && (l.description.trim() || num(l.amount) != null));
  function check() {
    const ls = filled();
    if (!ls.length && !lines.some(l => l.locked)) { setError('Add what is needed.'); return false; }
    if (ls.some(l => !l.description.trim() || num(l.amount) == null)) { setError('Each line needs what it is for and an amount.'); return false; }
    return true;
  }
  // save the draft → its id; keepOpen: stay in the window (saving the summary sheet)
  // two ways in (2026-11-15, the user): (1) import the branch's sheet — when the branch manager posts it,
  // last week's spending items are written into MOIS as expenses paid from the weekly cash; an item
  // already in MOIS (same amount that week, and the same words or the same day) is not entered again;
  // (2) no import — last week's spending comes from what MOIS already has, and only the request is filled.
  const nw = t => String(t ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const isoOf = t => {
    const v = String(t ?? '').trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
    const d = v ? new Date(`${v} UTC`) : null;
    return d && !Number.isNaN(d.getTime()) ? d.toISOString().slice(0, 10) : null;
  };
  function spendPlan(rows) {
    const from = addDays(week, -6);
    const existing = [...spentIn(week), ...spentIn(week, 'others')].map(x => ({ ...x, used: false }));
    const out = { record: [], already: [] };
    (rows || []).forEach((r, i) => {
      if (FORMULA_ROW.test(r.description || '') || !(num(r.cash_out) > 0) || !String(r.description ?? '').trim()) return;
      if (r.expense_id || r.record_id) { out.already.push({ r, i }); return; }
      const d = isoOf(r.date);
      const day = d && d >= from && d <= week ? d : week;
      const first = nw(r.description).split(' ')[0];
      const m = existing.find(x => !x.used && Math.abs(x.amount - num(r.cash_out)) < 1
        && (nw(x.description) === nw(r.description) || (first && nw(x.description).split(' ').includes(first)) || x.date === day));
      if (m) { m.used = true; out.already.push({ r, i, match: m }); } else out.record.push({ r, i, day });
    });
    return out;
  }
  async function recordSpending(rows) {
    const plan = spendPlan(rows);
    const next = rows.map(r => ({ ...r }));
    for (const a of plan.already) if (a.match) next[a.i].record_id = a.match.id;
    const other = data.cats.find(c => /^other$/i.test(c.name))?.id ?? null;
    for (const it of plan.record) {
      const amt = num(it.r.cash_out);
      const { data: eid, error: err } = await supabase.rpc('record_expense', { p: {
        branch_id: branchId, expense_date: it.day, paid_on: it.day, amount: amt, amount_paid: amt, payment_method: 'Cash',
        category_id: it.r.category_id || guessCategory(it.r.description, data.cats, catHistory) || other,
        description: String(it.r.description).trim(),
        notes: `Weekly cash sheet ${dateText(week)}${it.r.qty ? ` · ${it.r.qty}` : ''}` } });
      if (err) return { error: err, rows: next };
      await saveWeeklyCash('expense', eid, true);
      next[it.i].expense_id = eid;
    }
    return { rows: next };
  }
  // how many of the sheet's spending items go into MOIS on posting (shown in the check window)
  const postNote = () => {
    if (!poster || !sheetLW?.length) return null;
    const p = spendPlan(sheetLW);
    if (!p.record.length && !p.already.length) return null;
    return `Posting writes last week's spending into MOIS: ${p.record.length} item${p.record.length === 1 ? '' : 's'} recorded as expenses (weekly cash)${p.already.length ? `, ${p.already.length} already in MOIS — not entered again` : ''}.`;
  };
  async function save({ keepOpen = false, lastWeek = sheetLW, send = false } = {}) {
    setError('');
    if (!check()) return null;
    setBusy(true);
    // the branch manager posts: the sheet's spending goes into MOIS first; on a problem it is saved, not sent
    let recErr = null;
    if (send && poster && lastWeek?.length) {
      const rec = await recordSpending(withCats(lastWeek));
      lastWeek = rec.rows; setSheetLW(rec.rows);
      if (rec.error) { recErr = rec.error; send = false; keepOpen = true; }
    }
    const carried = lastWeek?.length ? sheetSums(lastWeek).closing : null;
    const { data: id, error: err } = await supabase.rpc('save_cash_request', { p: { id: request?.id ?? savedId ?? null, branch_id: branchId, week_ending: week, pay_bank: payTo.bank, pay_account_no: payTo.no, pay_account_name: payTo.name,
      opening_balance: firstEver ? (carried ?? num(opening)) : null, notes, source,
      last_week: lastWeek?.length ? { rows: lastWeek } : null,
      lines: filled().map(l => ({ description: l.description, quantity: num(l.quantity), unit: l.unit, amount: num(l.amount), category_id: l.categoryId || null })) } });
    if (err) { setBusy(false); setError(dbErrorMessage(err)); return null; }
    if (id && !request) setSavedId(id);
    if (send) {
      const { error: e2 } = await supabase.rpc('cash_request_step', { p_id: id ?? request?.id ?? savedId, p_step: 'send', p: {} });
      if (e2) { setBusy(false); setError(dbErrorMessage(e2)); return null; }
    }
    setBusy(false);
    if (recErr) { await onRefresh?.(); setError(`Not sent: a spending item could not be recorded — ${dbErrorMessage(recErr)}`); return null; }
    if (keepOpen) await onRefresh?.(); else onSaved();
    return id;
  }
  // a workbook with several sheets: ask which one (2026-11-13, the user)
  const [sheetPick, setSheetPick] = useState(null);   // { file, sheets, name }
  // a sheet already in the report: ask before replacing it — two sheets are never combined (2026-11-15, the user)
  const [replaceAsk, setReplaceAsk] = useState(null);   // the file waiting for a yes
  const hasSheet = () => !!sheetLW?.length || lines.some(l => !l.locked && (String(l.description ?? '').trim() || num(l.amount) != null));
  async function chooseFile(f, sure = false) {
    setError('');
    if (!sure && hasSheet()) { setReplaceAsk(f); return; }
    try {
      const sheets = await listWeeklySheets(f);
      if (sheets.length > 1) {
        const likely = [...sheets].filter(x => x.hasNeeds).sort((a, b) => String(b.week ?? '').localeCompare(String(a.week ?? '')))[0] ?? sheets[0];
        // newest week on top, oldest below; sheets without a needs table last (2026-11-13, the user)
        const ordered = [...sheets].sort((a, b) => (b.hasNeeds - a.hasNeeds) || String(b.week ?? '').localeCompare(String(a.week ?? '')));
        setSheetPick({ file: f, sheets: ordered, name: likely.name });
        return;
      }
      await importFile(f, sheets[0]?.name ?? null);
    } catch (e) { setError(e.message || 'That file could not be read.'); }
  }
  async function importFile(f, sheetName = null) {
    setError('');
    try {
      const s = await readWeeklySheet(f, sheetName);
      // everything from the earlier sheet goes; only the casuals' pay-sheet line (from MOIS) stays
      setLines(cur => [...cur.filter(l => l.locked), ...fillCategories(s.lines.map(l => ({ description: l.description, quantity: l.quantity != null ? String(l.quantity) : '', unit: l.unit || '', amount: String(l.amount), categoryId: '' })), data.cats, catHistory).map(l => ({ ...l, catAuto: !!l.categoryId }))]);
      if (s.weekEnding) setWeek(saturdayOf(s.weekEnding));
      setOpening(s.carried != null ? String(s.carried) : '');   // the sheet's last balance
      if (!payTouched) setPayTo(s.account ? { bank: s.account.bank || '', no: s.account.number || '', name: s.account.holder || '' } : savedAccounts[0] ? { ...savedAccounts[0] } : { bank: '', no: '', name: '' });   // no account on the sheet: the last one used
      clearTimeout(saveTimer.current); setLwEdit(null);
      setSheetLW(s.summaryRows?.length ? s.summaryRows.map(({ date, description, qty, cash_in, cash_out, balance }) => ({ date, description, qty, cash_in, cash_out, balance })) : null);
      setSource('excel');
      if (s.total != null && Math.abs(s.total - s.lines.reduce((t, l) => t + l.amount, 0)) > 0.5) setError(`Read ${s.lines.length} lines — their sum differs from the sheet's TOTAL (${formatAmount(s.total)}). Check before saving.`);
    } catch (e) { setError(e.message || 'That file could not be read.'); }
  }
  const copyLast = () => prevLive && setLines(cur => [...cur.filter(l => l.locked), ...[...prevLive.lines].filter(l => !l.pay_sheet_id).sort((a, b) => a.line_no - b.line_no).map(l => ({ description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unit: l.unit ?? '', amount: String(Number(l.approved_amount ?? l.amount)), categoryId: l.category_id ?? '' }))]);
  // the report as a document: what the directors see (PDF) or the sheet (Excel)
  const showApproved = false;   // no Approved column anywhere (2026-11-16, the user): the directors approve or send back
  const docModel = () => ({
    company: organization?.name ?? '', branch: branchName ?? '', title: 'WEEKLY CASH REPORT', status: STATUS[st][0],
    lw: { title: lwTitle, rows: lwRows.map(r => ({ ...r, date: /^\d{4}-\d{2}-\d{2}$/.test(r.date || '') ? tableDate(r.date) : r.date })) },
    req: { title: reqTitle, showApproved, total, approvedTotal,
      lines: lines.filter(l => l.description.trim()).map(l => ({ description: l.description, qty: [l.unit, l.quantity].filter(Boolean).join(' '), amount: num(l.amount) ?? 0, approved: num(l.approved) ?? num(l.amount) ?? 0 })) },
    account: { bank: payTo.bank, number: payTo.no, holder: payTo.name },   // always on the page (2026-11-15, the user)
    notes: notes.trim(), fileName: `Weekly cash ${branchName ?? ''} ${week}`,
  });

  // the total rows stand out: TOTAL CASH on top, the two closing rows at the bottom
  const lwRowClass = r => (r.kind === 'total_in' ? 'xs-total xs-total-in' : r.kind === 'total_out' ? 'xs-total xs-total-first' : r.kind === 'close' ? 'xs-total' : '');
  // each spending line's category: as chosen, else guessed from the item (2026-11-15, the user)
  const catOf = r => (r.kind === 'item' || (!r.kind && r.cash_out != null && !FORMULA_ROW.test(r.description || ''))
    ? r.category_id || guessCategory(r.description, data.cats, catHistory) : '');
  const lwCols = [
    { key: 'date', label: 'Date', type: 'text', width: 110, show: l => (/^\d{4}-\d{2}-\d{2}$/.test(l.date || '') ? tableDate(l.date) : l.date || '') },
    { key: 'description', label: 'Description', type: 'text', wrap: true, show: l => (l.bold ? <strong>{l.description}</strong> : l.description) },
    { key: 'qty', label: 'Qty', type: 'text', width: 90, show: l => <span className="pl-help">{l.qty || ''}</span> },
    ...['cash_in', 'cash_out', 'balance'].map((k, i) => ({ key: k, label: `${['Cash in', 'Cash out', 'Balance'][i]} (TZS)`, type: 'number', width: 125, align: 'center',
      show: l => (l[k] != null && l[k] !== '' ? (l.bold ? <strong>{formatAmount(Number(l[k]))}</strong> : formatAmount(Number(l[k]))) : '') })),
    { key: 'category_id', label: 'Category', type: 'select', width: 120,
      options: data.cats.filter(c => c.status === 'active').map(c => ({ value: c.id, label: c.name })),
      show: l => data.cats.find(c => c.id === catOf(l))?.name ?? '' },
  ];
  return (
    <>
    {replaceAsk && (
      <Modal title="Replace the sheet?" onClose={() => setReplaceAsk(null)}
        footer={<>
          <button type="button" className="btn btn-outline" onClick={() => setReplaceAsk(null)}>Cancel</button>
          <button type="button" className="btn btn-primary" onClick={() => { const f = replaceAsk; setReplaceAsk(null); chooseFile(f, true); }}>Replace</button></>}>
        <p className="text-sm" title="Last week's spending, this week's request, the balance and the bank details are all taken from the new sheet. The two sheets are not combined.">
          This report already has a sheet. Replace it with {replaceAsk.name}?</p>
      </Modal>
    )}
    {sheetPick && (
      <Modal title="Which sheet?" onClose={() => setSheetPick(null)}
        footer={<>
          <button type="button" className="btn btn-outline" onClick={() => setSheetPick(null)}>Cancel</button>
          <button type="button" className="btn btn-primary" onClick={async () => { const p = sheetPick; setSheetPick(null); await importFile(p.file, p.name); }}>Import this sheet</button></>}>
        <div className="modal-form">
          {/* the import button at the top too — the list can be long (2026-11-15, the user) */}
          <div className="wc-top">
            <p className="pl-help" style={{ margin: 0 }}>{sheetPick.file.name} has {sheetPick.sheets.length} sheets. Pick the one to import.</p>
            <div className="wc-top-right">
              <button type="button" className="btn btn-primary btn-sm" onClick={async () => { const p = sheetPick; setSheetPick(null); await importFile(p.file, p.name); }}>Import this sheet</button>
            </div>
          </div>
          <div className="wc-sheets" role="radiogroup" aria-label="Sheets">
            {sheetPick.sheets.map(x => (
              <label key={x.name} className={`wc-sheet${sheetPick.name === x.name ? ' is-on' : ''}${x.hasNeeds ? '' : ' is-off'}`}>
                <input type="radio" name="wc-sheet" checked={sheetPick.name === x.name} disabled={!x.hasNeeds} onChange={() => setSheetPick(p => ({ ...p, name: x.name }))} />
                <strong>{x.name}</strong>
                <span className="pl-help">{x.hasNeeds ? (x.week ? `needs for the week of ${dateText(x.week)}` : 'has a needs table') : 'no needs table'}</span>
              </label>
            ))}
          </div>
        </div>
      </Modal>
    )}
    {askPay && !paying && (
      <Modal title="Approved" onClose={onSaved}
        footer={<>
          <button type="button" className="btn btn-outline" onClick={onSaved}>Later</button>
          <button type="button" className="btn btn-primary" onClick={() => setPaying(true)}>Pay now</button></>}>
        <p className="text-sm">{money(total)} approved for {branchName} · {dateText(week)}. Pay it now?</p>
      </Modal>
    )}
    {paying && <PayModal preset={{ kind: 'weekly_cash', branch: branchId, ref: request.id }} onClose={onSaved} onSaved={onSaved} />}
    {viewing && (
      <WeeklyCashViewer doc={docModel()} total={total} money={money} busy={busy} error={error}
        canDecide={!isNew && st === 'with_directors' && canAt('cash.approve', branchId)}
        onApprove={() => approveIt('')}
        onSendBack={n => step('back_to_draft', { note: n })}
        onClose={() => (viewOnly ? onClose() : setViewing(false))} />
    )}
    {docMode && (
      <WeeklyCashDocDialog doc={docModel()} mode={docMode} note={docMode === 'review' ? postNote() : null} defaultFormat={docMode === 'review' || !editable ? 'pdf' : 'excel'} busy={busy}
        confirmLabel={primaryLabel} onClose={() => setDocMode(null)}
        onConfirm={async () => { await save({ send: poster }); setDocMode(null); }} />
    )}
    {!viewOnly && <Modal title="WEEKLY CASH REPORT" onClose={onClose} size="xl"
      footer={<>
        <div className="wc-foot-left">
          <button type="button" className="btn btn-ghost" onClick={() => setDocMode('export')}><Download size={14} /> Export</button>
          <button type="button" className="btn btn-ghost" title="Full screen, as the PDF page" aria-label="Full screen" onClick={() => setViewing(true)}><Maximize2 size={14} /></button>
          {!isNew && ['draft', 'with_directors'].includes(st) && canAt('cash.request', branchId) && <button type="button" className="btn btn-ghost" disabled={busy} onClick={() => step('cancel')}>Cancel request</button>}
        </div>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {editable && <button type="button" className={`btn btn-outline${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={() => save()}>Save draft</button>}
        {editable && (canAt('cash.request', branchId) || poster) && <button type="button" className="btn btn-primary" disabled={busy || !!lwEdit} title={lwEdit ? "Stop editing last week's spending first (the lock or pencil on its heading)" : undefined}
          onClick={() => { setError(''); if (check()) setDocMode('review'); }}>{primaryLabel}</button>}
        {!isNew && st === 'with_directors' && canAt('cash.approve', branchId) && <>
          <button type="button" className="btn btn-ghost" disabled={busy || !note.trim()} onClick={() => step('reject', { note })}>Turn down</button>
          <button type="button" className="btn btn-outline" disabled={busy} onClick={() => step('back_to_draft', { note })}>Send back to change</button>
          <button type="button" className="btn btn-primary" disabled={busy} onClick={() => approveIt(note)}>Approve {money(total)}</button>
        </>}
        {!isNew && st === 'approved' && canAt('cash.approve', branchId) && <button type="button" className="btn btn-primary" disabled={busy || !(num(pay.amount) > 0)} onClick={() => step('pay', pay)}>Record payment</button>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
      </>}>
      <div className="modal-form">
        {/* top: the report's date on the left; status and the importer on the right (2026-11-15, the user) */}
        <div className="wc-top">
          {editable
            ? <label className="pe-field"><span title="The Saturday the report is made">Report date</span><input type="date" className="form-input" value={week} onChange={e => setWeek(saturdayOf(e.target.value))} /></label>
            : <span className="pl-help">{dateText(week)}</span>}
          {editable && firstEver && !sheetLW?.length && (
            <label className="pe-field" title="The first week in MOIS: the cash left on this date. Importing the branch's sheet fills it."><span>Balance on this date</span>
              <NumberInput step="any" className="form-input" style={{ width: 140 }} value={opening} onChange={e => setOpening(e.target.value)} /></label>)}
          <div className="wc-top-right">
            {editable && <>
              <input ref={fileRef} type="file" accept=".xlsx" hidden onChange={e => { if (e.target.files?.[0]) chooseFile(e.target.files[0]); e.target.value = ''; }} />
              {prevLive && <button type="button" className="btn btn-ghost btn-sm" onClick={copyLast} title="Start this week's request from last week's lines"><Copy size={14} /></button>}
              <button type="button" className="btn btn-outline btn-sm" onClick={() => fileRef.current?.click()} title="Import the branch's Excel sheet — check the lines before saving"><Upload size={14} /> Import Excel</button>
            </>}
            <span className={`badge ${STATUS[st][1]}`}>{STATUS[st][0]}</span>
          </div>
        </div>
        {!isNew && (request.decision_note || st === 'paid') && <p className="pl-help" style={{ margin: 0 }}>{request.decision_note ?? ''}{request.decision_note && st === 'paid' ? ' · ' : ''}{st === 'paid' ? `${money(Number(request.paid_amount))} sent on ${dateText(request.paid_on)}${request.paid_reference ? ` (${request.paid_reference})` : ''}` : ''}</p>}

        <div className="wc-tables">
          {/* part 1, exactly as on the branch's sheet: only what was paid from the weekly cash (121) */}
          {lwEdit ? <>
            <SheetGrid resizable freeze label="Last week's spending" className="xs-bold" columns={lwCols}
              title={<>
                <span className="xs-title-left">
                  <button type="button" className="btn btn-ghost btn-sm" aria-label="Undo" title="Undo the last change" disabled={!lwHist.length} onClick={undoEdit}><Undo2 size={14} /></button>
                </span>
                {lwTitle}
                <span className="xs-title-act">
                  <button type="button" className="btn btn-ghost btn-sm" aria-label="Lock — stop editing" title="Lock — stop editing (changes are saved)" onClick={stopEdit}><Lock size={14} /></button>
                </span>
              </>}
              rows={editRows.filter(r => r.kind !== 'total_out' && r.kind !== 'close')} onChange={onEditRows}
              footRows={editRows.filter(r => r.kind === 'total_out' || r.kind === 'close')}
              canEditCell={(col, r) => (r.kind === 'open' ? ['date', 'cash_in'].includes(col.key) : r.kind === 'sent' ? col.key === 'cash_in' : r.kind === 'total_in' ? false : ['date', 'description', 'qty', 'cash_out', 'category_id'].includes(col.key))}
              canRemoveRow={r => r.kind === 'item'} rowClass={lwRowClass}
              blankRow={{ date: '', description: '', qty: '', cash_out: '', category_id: '' }} />
            {sheetLW?.length > 0 && <div className="wc-sheet-save"><button type="button" className="btn btn-ghost btn-sm" disabled={busy} title="Drop the typed summary and use what MOIS recorded" onClick={useRecords}><RotateCcw size={14} /> Use MOIS records</button></div>}
          </> : (
            <SheetGrid resizable freeze label="Last week's spending" className="xs-bold" readOnly columns={lwCols} rowClass={lwRowClass}
              title={<>{lwTitle}{editable && <span className="xs-title-act"><button type="button" className="btn btn-ghost btn-sm" aria-label="Edit the spending" title="Edit the spending" onClick={startEdit}><Pencil size={14} /></button></span>}</>}
              rows={lwRows.length ? lwRows : [{ description: 'Nothing paid from the weekly cash last week' }]} />
          )}
          {showTick && (
            <details className="wc-tick">
              <summary className="pl-help" title="Only payments made from the weekly cash go on this sheet. Payments by the directors or a bank (cement, sand…) stay off it.">Which of last week's payments came from the weekly cash?</summary>
              <ul>
                {lwAll.map(l => (
                  <li key={l.kind + l.id}>
                    <label className="flex items-center gap-8">
                      <input type="checkbox" checked={l.on} disabled={!!ticking} onChange={() => tick(l)} />
                      <span>{tableDate(l.date)} · {l.description} · {formatAmount(l.amount)}</span>
                      <span className="pl-help">{l.on ? 'weekly cash' : 'directors · bank'}</span>
                    </label>
                  </li>
                ))}
              </ul>
            </details>
          )}

          {/* one Save for both sheets, even with saving by itself on (2026-11-15, the user) */}
          {editable && (
            <div className="wc-sheet-save">
              {lwSaved && <span className="pl-help">{lwSaved === 'saving' ? 'Saving…' : 'Saved'}</span>}
              <button type="button" className={`btn btn-primary btn-sm${busy ? ' btn-loading' : ''}`} disabled={busy} title="Save both sheets" onClick={saveBoth}><Save size={14} /> Save</button>
            </div>
          )}
          {/* part 2: this week's request, as a sheet like the branch's Excel */}
          <SheetGrid resizable freeze label="This week's request" className="xs-bold" title={reqTitle} rows={lines} onChange={onLinesChange} readOnly={!editable}
            isLocked={l => !!l.locked} lockedTitle="From the casuals' approved pay sheet — it changes with the sheet"
            blankRow={{ description: '', quantity: '', unit: '', amount: '', categoryId: '' }}
            columns={[
              { key: 'description', label: 'Description', type: 'text', wrap: true },
              { key: 'quantity', label: 'Qty', type: 'number', width: 90, align: 'right', show: l => (l.quantity !== '' && l.quantity != null ? formatAmount(num(l.quantity)) : '') },
              { key: 'unit', label: 'Unit', type: 'text', width: 90 },
              { key: 'amount', label: 'Amount (TZS)', type: 'number', min: 0, width: 150, align: 'center', show: l => (num(l.amount) != null ? formatAmount(num(l.amount)) : '') },
              { key: 'categoryId', label: 'Category', type: 'select', width: 130,
                options: data.cats.filter(c => c.status === 'active' || lines.some(l => l.categoryId === c.id)).map(c => ({ value: c.id, label: c.name })),
                show: l => data.cats.find(c => c.id === l.categoryId)?.name ?? '' },
            ]}
            totals={{ amount: money(total) }} />
        </div>
        {editable && <p className="pl-help" style={{ margin: 0 }} title="Enter goes down, Tab across. Copy rows in Excel and paste them here (Ctrl+V) to fill several lines at once.">Type straight into the cells, or paste rows from Excel.</p>}

        {/* where the money is sent — one row; the note below (2026-11-15, the user) */}
        {editable && savedAccounts.length > 0 && (
          <label className="pe-field wc-acct-pick"><span>Account</span>
            <select className="form-input" value={savedAccounts.findIndex(a => a.bank === payTo.bank && a.no === payTo.no && a.name === payTo.name)}
              onChange={e => { const k = Number(e.target.value); setPayTouched(true); setPayTo(k >= 0 ? { ...savedAccounts[k] } : { bank: '', no: '', name: '' }); }}>
              {savedAccounts.map((a, k) => <option key={k} value={k}>{[a.bank, a.no, a.name].filter(Boolean).join(' · ')}{k === 0 ? ' (last used)' : ''}</option>)}
              <option value={-1}>Another account…</option>
            </select>
          </label>
        )}
        <div className="wc-pay-row">
          <label className="pe-field"><span>Bank</span><input className="form-input" disabled={!editable} placeholder="e.g. the bank's name" value={payTo.bank} onChange={e => { setPayTouched(true); setPayTo({ ...payTo, bank: e.target.value }); }} /></label>
          <label className="pe-field"><span>Account number</span><input className="form-input" disabled={!editable} value={payTo.no} onChange={e => { setPayTouched(true); setPayTo({ ...payTo, no: e.target.value }); }} /></label>
          <label className="pe-field"><span>Account name (jina)</span><input className="form-input" disabled={!editable} value={payTo.name} onChange={e => { setPayTouched(true); setPayTo({ ...payTo, name: e.target.value }); }} /></label>
        </div>
        <label className="pe-field"><span>Notes (optional)</span><input className="form-input" disabled={!editable} value={notes} onChange={e => setNotes(e.target.value)} /></label>
        {!isNew && st === 'with_directors' && canAt('cash.approve', branchId) && (
          <label className="pe-field"><span>Directors' note (needed to turn down)</span><input className="form-input" value={note} onChange={e => setNote(e.target.value)} /></label>
        )}
        {!isNew && st === 'approved' && canAt('cash.approve', branchId) && (
          <div className="form-row">
            <label className="pe-field"><span>Sent on</span><input type="date" className="form-input" max={today} value={pay.paid_on} onChange={e => setPay({ ...pay, paid_on: e.target.value })} /></label>
            <label className="pe-field"><span>Amount sent</span><NumberInput step="any" min="0" className="form-input" placeholder={String(approvedTotal)} value={pay.amount} onChange={e => setPay({ ...pay, amount: e.target.value })} /></label>
            <label className="pe-field"><span>Reference (optional)</span><input className="form-input" value={pay.reference} onChange={e => setPay({ ...pay, reference: e.target.value })} /></label>
          </div>
        )}
      </div>
    </Modal>}
    </>
  );
}
