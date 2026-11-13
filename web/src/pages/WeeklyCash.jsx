import SheetGrid from '../components/SheetGrid';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Wallet, Plus, Trash2, Upload, Download, Copy } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatMoneyShort, formatAmount, dateText, tableDate } from '../lib/format';
import { loadInventoryRefs, orgToday, qtyText } from '../lib/inventory';
import PeriodSelect, { usePeriod } from '../components/PeriodSelect';
import { dbErrorMessage } from '../lib/masterData';
import { readWeeklySheet, listWeeklySheets, writeWeeklySheet } from '../lib/weeklyCashExcel';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';

const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const r2 = n => Math.round(n * 100) / 100;
const addDays = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const saturdayOf = d => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return addDays(d, (6 - w + 7) % 7); };
const longDate = d => dateText(d).toUpperCase();
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
export default function WeeklyCash() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName } = useBranch();
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
      ...data.expenses.filter(e => inWeek(e.paid_on) && pick(e)).map(e => ({ kind: 'expense', id: e.id, date: e.paid_on, description: e.description, qty: e.quantity ? qtyText(Number(e.quantity)) : '', amount: Number(e.amount_paid) })),
      ...data.payments.filter(p => inWeek(p.paid_on) && pick(p)).map(p => ({ kind: 'purchase_payment', id: p.id, date: p.paid_on, description: `${goods(p.purchase.movement_id) || 'Purchase'}${supplier(p.purchase.supplier_id) ? ` — ${supplier(p.purchase.supplier_id)}` : ''}`, qty: qtyOfMove(p.purchase.movement_id), amount: Number(p.amount) })),
    ].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  }, [data]);

  // week by week from the first request: balance brought forward + cash sent − spent = balance carried
  const ledger = useMemo(() => {
    if (!data) return {};
    const live = data.requests.filter(r => !['cancelled', 'rejected'].includes(r.status)).sort((a, b) => (a.week_ending < b.week_ending ? -1 : 1));
    if (!live.length) return {};
    const out = {};
    let bal = 0;
    for (let w = live[0].week_ending; w <= saturdayOf(today); w = addDays(w, 7)) {
      const req = live.find(r => r.week_ending === w);
      const opening = req?.opening_balance != null ? Number(req.opening_balance) : bal;
      const sent = req?.status === 'paid' ? Number(req.paid_amount) : 0;
      const lines = spentIn(w);
      const spent = lines.reduce((t, l) => t + l.amount, 0);
      bal = r2(opening + sent - spent);
      out[w] = { week: w, opening, sent, spent: r2(spent), closing: bal, lines };
    }
    return out;
  }, [data, spentIn, today]);

  const here = data?.requests || [];
  const shownWeeks = here.filter(r => r.week_ending >= period.from && addDays(r.week_ending, -6) <= period.to);
  const thisWeek = here.find(r => r.week_ending === saturdayOf(today) && !['cancelled', 'rejected'].includes(r.status));
  const lastClosed = ledger[addDays(saturdayOf(today), -7)];
  const canPrepare = !!branchId && canAt('cash.request', branchId);

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
              <thead><tr><th>Week ending</th><th>Status</th><th className="num">Asked (TZS)</th><th className="num">Approved (TZS)</th><th className="num">Sent (TZS)</th><th className="num">Spent (TZS)</th><th className="num">Balance (TZS)</th></tr></thead>
              <tbody>
                {shownWeeks.length === 0 ? <tr><td colSpan={7} className="text-muted">{here.length ? 'No weekly request in this period.' : <>No requests yet.</>}</td></tr>
                : shownWeeks.map(r => {
                  const w = ledger[r.week_ending];
                  return (
                    <tr key={r.id} className="clickable-row" onClick={() => setOpen(r)}>
                      <td>{tableDate(r.week_ending)}{r.source === 'excel' && <div className="pl-help">from Excel</div>}</td>
                      <td><span className={`badge ${STATUS[r.status][1]}`}>{STATUS[r.status][0]}</span></td>
                      <td className="num">{formatAmount(asked(r))}</td>
                      <td className="num">{['approved', 'paid'].includes(r.status) ? formatAmount(approvedOf(r)) : ''}</td>
                      <td className="num">{r.status === 'paid' ? formatAmount(Number(r.paid_amount)) : ''}</td>
                      <td className="num">{w ? formatAmount(w.spent) : ''}</td>
                      <td className="num"><strong>{w ? formatAmount(w.closing) : ''}</strong></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div></div>
          <p className="pl-help" style={{ marginTop: 8 }} title={"A week runs Sunday to Saturday. Spent = expenses and payments to suppliers recorded as paid that week (Purchases). Balance = brought forward + cash sent − spent, carried into the next week."}>Balance = brought forward + sent − spent.</p>
        </>
      )}
      {open && <RequestModal request={open.new ? null : open} branchId={branchId} branchName={branchName} data={data} ledger={ledger} spentIn={spentIn} today={today} money={money}
        organization={organization} onRefresh={load} onClose={() => setOpen(null)} onSaved={async () => { setOpen(null); await load(); }} />}
    </PageShell>
  );
}

function RequestModal({ request, branchId, branchName, data, ledger, spentIn = () => [], today, money, organization, onRefresh, onClose, onSaved }) {
  const { canAt } = useAuth();
  const isNew = !request;
  const editable = isNew || request.status === 'draft';
  const prevLive = data.requests.filter(r => !['cancelled', 'rejected'].includes(r.status) && r.id !== request?.id).sort((a, b) => (a.week_ending < b.week_ending ? 1 : -1))[0];
  const [week, setWeek] = useState(request?.week_ending ?? saturdayOf(today));
  // where the money is sent: written on the request, carried from the previous week's
  const [payTo, setPayTo] = useState({ bank: request?.pay_bank ?? prevLive?.pay_bank ?? '', no: request?.pay_account_no ?? prevLive?.pay_account_no ?? '', name: request?.pay_account_name ?? prevLive?.pay_account_name ?? '' });
  const [opening, setOpening] = useState(request?.opening_balance != null ? String(Number(request.opening_balance)) : '');
  const [notes, setNotes] = useState(request?.notes ?? '');
  const [source, setSource] = useState(request?.source ?? 'app');
  const [lines, setLines] = useState(() => (request?.lines?.length
    ? [...request.lines].sort((a, b) => a.line_no - b.line_no).map(l => ({ id: l.id, description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unit: l.unit ?? '', amount: String(Number(l.amount)), approved: l.approved_amount != null ? String(Number(l.approved_amount)) : '', categoryId: l.category_id ?? '', locked: !!l.pay_sheet_id }))
    : [{ description: '', quantity: '', unit: '', amount: '', categoryId: '' }]));
  const [pay, setPay] = useState({ paid_on: today, amount: '', reference: '' });
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const fileRef = useRef(null);
  const firstEver = !prevLive;   // the first request: its balance brought forward is typed in
  const set = (i, patch) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const total = lines.reduce((t, l) => t + (num(l.amount) ?? 0), 0);
  const approvedTotal = lines.reduce((t, l) => t + (num(l.approved) ?? num(l.amount) ?? 0), 0);
  const lastWeek = ledger[addDays(week, -7)];
  // the first week in MOIS: last week's summary exactly as on the branch's sheet (121)
  const [sheetLW, setSheetLW] = useState(request?.last_week?.rows ?? null);
  const prevWeek = addDays(week, -7);
  // part 1 rows, as the sheet lays them out: BALANCE, CASH SENT, TOTAL CASH, what was spent, TOTAL CASH, BALANCE
  const lwRows = useMemo(() => {
    if (lastWeek) {
      let b = r2(lastWeek.opening + lastWeek.sent);
      return [
        { date: prevWeek, description: 'BALANCE', cash_in: lastWeek.opening },
        { description: 'CASH SENT', cash_in: lastWeek.sent },
        { description: 'TOTAL CASH', cash_in: b, bold: true },
        ...lastWeek.lines.map(l => { b = r2(b - l.amount); return { date: l.date, description: l.description, qty: l.qty, cash_out: l.amount, balance: b }; }),
        { description: 'TOTAL CASH', cash_out: lastWeek.spent, bold: true },
        { description: 'BALANCE', cash_in: lastWeek.closing, bold: true },
      ];
    }
    if (firstEver && sheetLW?.length) return sheetLW.map(x => ({ ...x, bold: /^\s*(total|balance)/i.test(x.description || '') && !x.date }));
    const rec = spentIn(prevWeek);
    const spent = r2(rec.reduce((t, l) => t + l.amount, 0));
    return [
      ...rec.map(l => ({ date: l.date, description: l.description, qty: l.qty, cash_out: l.amount })),
      { description: 'TOTAL CASH', cash_out: spent, bold: true },
      ...(firstEver && num(opening) != null ? [{ description: 'BALANCE', cash_in: num(opening), bold: true }] : []),
    ];
  }, [lastWeek, firstEver, sheetLW, spentIn, prevWeek, opening]);
  // last week's payments: which came from the weekly cash (tick in / out, 121)
  const lwAll = useMemo(() => [...spentIn(prevWeek).map(l => ({ ...l, on: true })), ...spentIn(prevWeek, 'others').map(l => ({ ...l, on: false }))]
    .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0)), [spentIn, prevWeek]);
  const showTick = canAt('cash.request', branchId) && !(firstEver && sheetLW?.length) && lwAll.length > 0;
  const [ticking, setTicking] = useState('');
  async function tick(l) {
    setTicking(l.id); setError('');
    const { error: err } = await supabase.rpc('set_weekly_cash', { p_kind: l.kind, p_id: l.id, p_on: !l.on });
    if (err) setError(/set_weekly_cash/.test(err.message || '') ? 'This needs the latest database update (121).' : dbErrorMessage(err));
    else await onRefresh?.();
    setTicking('');
  }
  const step = async (name, p = {}) => {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('cash_request_step', { p_id: request.id, p_step: name, p });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  };
  async function save() {
    setError('');
    // the casual wages line comes from the approved pay sheet and stays as it is (115)
    const ls = lines.filter(l => !l.locked && (l.description.trim() || num(l.amount) != null));
    if (!ls.length && !lines.some(l => l.locked)) { setError('Add what is needed.'); return; }
    if (ls.some(l => !l.description.trim() || num(l.amount) == null)) { setError('Each line needs what it is for and an amount.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('save_cash_request', { p: { id: request?.id ?? null, branch_id: branchId, week_ending: week, pay_bank: payTo.bank, pay_account_no: payTo.no, pay_account_name: payTo.name,
      opening_balance: firstEver ? num(opening) : null, notes, source,
      ...(firstEver ? { last_week: sheetLW?.length ? { rows: sheetLW } : null } : {}),
      lines: ls.map(l => ({ description: l.description, quantity: num(l.quantity), unit: l.unit, amount: num(l.amount), category_id: l.categoryId || null })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  // a workbook with several sheets: ask which one (2026-11-13, the user)
  const [sheetPick, setSheetPick] = useState(null);   // { file, sheets, name }
  async function chooseFile(f) {
    setError('');
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
      setLines(s.lines.map(l => ({ description: l.description, quantity: l.quantity != null ? String(l.quantity) : '', unit: l.unit || '', amount: String(l.amount), categoryId: '' })));
      if (s.weekEnding) setWeek(saturdayOf(s.weekEnding));
      if (firstEver && s.carried != null) setOpening(String(s.carried));   // the sheet's last balance, carried into this week
      if (firstEver && s.summaryRows?.length) setSheetLW(s.summaryRows.map(({ date, description, qty, cash_in, cash_out, balance }) => ({ date, description, qty, cash_in, cash_out, balance })));
      setSource('excel');
      if (s.total != null && Math.abs(s.total - s.lines.reduce((t, l) => t + l.amount, 0)) > 0.5) setError(`Read ${s.lines.length} lines — their sum differs from the sheet's TOTAL (${formatAmount(s.total)}). Check before saving.`);
    } catch (e) { setError(e.message || 'That file could not be read.'); }
  }
  const copyLast = () => prevLive && setLines(cur => [...cur.filter(l => l.locked), ...[...prevLive.lines].filter(l => !l.pay_sheet_id).sort((a, b) => a.line_no - b.line_no).map(l => ({ description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unit: l.unit ?? '', amount: String(Number(l.approved_amount ?? l.amount)), categoryId: l.category_id ?? '' }))]);
  const exportFile = () => writeWeeklySheet({
    fileName: `Weekly cash ${branchName} ${week}.xlsx`,
    summaryTitle: `SUMMARY YA MATUMIZI YA LAST WEEK ${longDate(addDays(week, -7))}`,
    summary: { rows: lwRows.map(x => ({ ...x, date: /^\d{4}-\d{2}-\d{2}$/.test(x.date || '') ? tableDate(x.date) : x.date })) },
    needsTitle: `MAHITAJI YA WIKI HII (${longDate(week)})`,
    needs: lines.filter(l => l.description.trim()).map(l => ({ description: l.description, qty: [l.unit, l.quantity].filter(Boolean).join(' '), amount: num(request && ['approved', 'paid'].includes(request.status) ? (l.approved || l.amount) : l.amount) ?? 0 })),
    account: payTo.bank || payTo.no || payTo.name ? { bank: payTo.bank, number: payTo.no, holder: payTo.name } : null,
  });

  const st = request?.status ?? 'draft';
  return (
    <>
    {sheetPick && (
      <Modal title="Which sheet?" onClose={() => setSheetPick(null)}
        footer={<>
          <button type="button" className="btn btn-outline" onClick={() => setSheetPick(null)}>Cancel</button>
          <button type="button" className="btn btn-primary" onClick={async () => { const p = sheetPick; setSheetPick(null); await importFile(p.file, p.name); }}>Import this sheet</button></>}>
        <div className="modal-form">
          <p className="pl-help">{sheetPick.file.name} has {sheetPick.sheets.length} sheets. Pick the one to import.</p>
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
    <Modal title={isNew ? 'New weekly request' : `Weekly cash — week ending ${dateText(request.week_ending)}`} onClose={onClose} size="xl"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-ghost" onClick={exportFile}><Download size={14} /> Export Excel</button>
        {!isNew && ['draft', 'with_directors'].includes(st) && canAt('cash.request', branchId) && <button type="button" className="btn btn-ghost" disabled={busy} onClick={() => step('cancel')}>Cancel request</button>}
        {editable && <button type="button" className={`btn btn-outline${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save draft</button>}
        {!isNew && st === 'draft' && canAt('cash.branch_approve', branchId) && <button type="button" className="btn btn-primary" disabled={busy} onClick={() => step('send')}>Approve & send to directors</button>}
        {!isNew && st === 'with_directors' && canAt('cash.approve', branchId) && <>
          <button type="button" className="btn btn-ghost" disabled={busy || !note.trim()} onClick={() => step('reject', { note })}>Turn down</button>
          <button type="button" className="btn btn-outline" disabled={busy} onClick={() => step('back_to_draft', { note })}>Send back to change</button>
          <button type="button" className="btn btn-primary" disabled={busy} onClick={() => step('approve', { note, lines: lines.map(l => ({ id: l.id, approved_amount: l.approved === '' ? null : num(l.approved) })) })}>Approve {money(approvedTotal)}</button>
        </>}
        {!isNew && st === 'approved' && canAt('cash.approve', branchId) && <button type="button" className="btn btn-primary" disabled={busy || !(num(pay.amount) > 0)} onClick={() => step('pay', pay)}>Record payment</button>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
      </>}>
      <div className="modal-form">
        {!isNew && <p className="text-sm"><span className={`badge ${STATUS[st][1]}`}>{STATUS[st][0]}</span>
          {request.decision_note ? ` · ${request.decision_note}` : ''}{st === 'paid' ? ` · ${money(Number(request.paid_amount))} sent on ${dateText(request.paid_on)}${request.paid_reference ? ` (${request.paid_reference})` : ''}` : ''}</p>}

        {/* part 1, exactly as on the branch's sheet (2026-11-13, the user): SUMMARY YA MATUMIZI YA LAST WEEK —
            only what was paid from the weekly cash; cement, sand… paid by the directors stay off it (121) */}
        <h3 className="modal-section-title">Last week's spending · week ending {dateText(prevWeek)}</h3>
        <SheetGrid label="Last week's spending" readOnly rows={lwRows.length ? lwRows : [{ description: 'Nothing paid from the weekly cash last week' }]}
          columns={[
            { key: 'date', label: 'Date', width: 110, show: l => (/^\d{4}-\d{2}-\d{2}$/.test(l.date || '') ? tableDate(l.date) : l.date || '') },
            { key: 'description', label: 'Description', show: l => (l.bold ? <strong>{l.description}</strong> : l.description) },
            { key: 'qty', label: 'Qty', width: 120, show: l => <span className="pl-help">{l.qty || ''}</span> },
            ...['cash_in', 'cash_out', 'balance'].map((k, i) => ({ key: k, label: `${['Cash in', 'Cash out', 'Balance'][i]} (TZS)`, width: 140, align: 'right',
              show: l => (l[k] != null && l[k] !== '' ? (l.bold ? <strong>{formatAmount(Number(l[k]))}</strong> : formatAmount(Number(l[k]))) : '') })),
          ]} />
        {firstEver && !lastWeek && <p className="pl-help">{sheetLW?.length ? 'First week in MOIS: as on the imported sheet. From next week, MOIS fills this part itself.' : 'First week in MOIS: import the branch\'s sheet to show its summary here, or type the balance carried below. From next week, this part fills itself.'}</p>}
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

        <h3 className="modal-section-title">This week's needs</h3>
        <div className="form-row">
          <label className="pe-field"><span>Week ending (Saturday)</span><input type="date" className="form-input" disabled={!editable} value={week} onChange={e => setWeek(saturdayOf(e.target.value))} /></label>
          {firstEver && <label className="pe-field"><span>Balance brought forward (first week)</span><NumberInput step="any" className="form-input" disabled={!editable} value={opening} onChange={e => setOpening(e.target.value)} /></label>}
        </div>
        {editable && (
          <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
            <input ref={fileRef} type="file" accept=".xlsx" hidden onChange={e => { if (e.target.files?.[0]) chooseFile(e.target.files[0]); e.target.value = ''; }} />
            <button type="button" className="btn btn-outline btn-sm" onClick={() => fileRef.current?.click()}><Upload size={14} /> Import Excel sheet</button>
            {prevLive && <button type="button" className="btn btn-ghost btn-sm" onClick={copyLast}><Copy size={14} /> Start from last week's lines</button>}
            <span className="pl-help">Check the lines before saving.</span>
          </div>
        )}
        {/* this week's needs as a sheet, like the branch's Excel (2026-11-13, the user) */}
        <SheetGrid label="This week's needs" rows={lines} onChange={setLines} readOnly={!editable}
          isLocked={l => !!l.locked} lockedTitle="From the casuals' approved pay sheet — it changes with the sheet"
          blankRow={{ description: '', quantity: '', unit: '', amount: '', categoryId: '' }}
          columns={[
            { key: 'description', label: 'Description', type: 'text' },
            { key: 'quantity', label: 'Qty', type: 'number', width: 90, align: 'right', show: l => (l.quantity !== '' && l.quantity != null ? formatAmount(num(l.quantity)) : '') },
            { key: 'unit', label: 'Unit', type: 'text', width: 90 },
            { key: 'amount', label: 'Amount (TZS)', type: 'number', min: 0, width: 150, align: 'right', show: l => (num(l.amount) != null ? formatAmount(num(l.amount)) : '') },
            ...(!isNew && st !== 'draft' ? [{ key: 'approved', label: 'Approved (TZS)', type: 'number', min: 0, width: 150, align: 'right', ignoreLock: true,
              editable: st === 'with_directors' && canAt('cash.approve', branchId), show: l => formatAmount(num(l.approved) ?? num(l.amount) ?? 0) }] : []),
            { key: 'categoryId', label: 'Category', type: 'select', width: 190,
              options: data.cats.filter(c => c.status === 'active' || lines.some(l => l.categoryId === c.id)).map(c => ({ value: c.id, label: c.name })),
              show: l => data.cats.find(c => c.id === l.categoryId)?.name ?? '' },
          ]}
          totals={{ amount: money(total), ...(!isNew && st !== 'draft' ? { approved: money(approvedTotal) } : {}) }} />
        {editable && <p className="pl-help">Type straight into the cells — Enter goes down, Tab across. Copy rows in Excel and paste them here (Ctrl+V) to fill several lines at once.</p>}
        <label className="pe-field"><span>Notes (optional)</span><input className="form-input" disabled={!editable} value={notes} onChange={e => setNotes(e.target.value)} /></label>
        {/* the end of the request: where the money is sent (as on the sheet) */}
        <div className="form-row">
          <label className="pe-field"><span>Bank</span><input className="form-input" disabled={!editable} placeholder="e.g. the bank's name" value={payTo.bank} onChange={e => setPayTo({ ...payTo, bank: e.target.value })} /></label>
          <label className="pe-field"><span>Account number</span><input className="form-input" disabled={!editable} value={payTo.no} onChange={e => setPayTo({ ...payTo, no: e.target.value })} /></label>
          <label className="pe-field"><span>Account name (jina)</span><input className="form-input" disabled={!editable} value={payTo.name} onChange={e => setPayTo({ ...payTo, name: e.target.value })} /></label>
        </div>
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
    </Modal>
    </>
  );
}
