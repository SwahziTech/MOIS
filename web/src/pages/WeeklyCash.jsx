import { useEffect, useMemo, useRef, useState } from 'react';
import { Wallet, Plus, Trash2, Upload, Download, Copy } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatMoneyShort, formatAmount } from '../lib/format';
import { loadInventoryRefs, orgToday, qtyText } from '../lib/inventory';
import { dbErrorMessage } from '../lib/masterData';
import { readWeeklySheet, writeWeeklySheet } from '../lib/weeklyCashExcel';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';

const num = v => (v === '' || v === null || v === undefined || Number.isNaN(Number(v)) ? null : Number(v));
const r2 = n => Math.round(n * 100) / 100;
const addDays = (d, n) => { const x = new Date(`${d}T00:00:00Z`); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const saturdayOf = d => { const w = new Date(`${d}T00:00:00Z`).getUTCDay(); return addDays(d, (6 - w + 7) % 7); };
const longDate = d => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' }).toUpperCase();
const STATUS = { draft: ['Draft', 'badge-neutral'], with_directors: ['With directors', 'badge-warning'], approved: ['Approved', 'badge-info'], rejected: ['Turned down', 'badge-error'], paid: ['Paid', 'badge-success'], cancelled: ['Cancelled', 'badge-neutral'] };
const asked = r => (r.lines || []).reduce((t, l) => t + Number(l.amount), 0);
const approvedOf = r => (r.lines || []).reduce((t, l) => t + Number(l.approved_amount ?? l.amount), 0);

/*
 * Weekly operations cash (2026-10-28, migration 078): each week the branch
 * asks for what it needs — prepared by the secretary or branch manager,
 * approved and sent by the branch manager, approved by the directors (who
 * may trim lines), paid to the branch in one payment. Last week's summary is
 * read from what was recorded (expenses and payments to suppliers paid that
 * week): balance brought forward + cash sent − spent = balance. A request
 * can be imported from the branch's Excel sheet or filled here, and exported
 * in the same layout.
 */
export default function WeeklyCash() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName } = useBranch();
  const money = v => formatMoney(v, organization?.currency_code);
  const today = orgToday(organization?.timezone);
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [open, setOpen] = useState(null);       // a request, or { new: true }

  async function load() {
    setError('');
    if (!branchId) { setData(null); return; }
    const since = addDays(today, -400);
    const [rq, ex, pp, ac, cats, refs] = await Promise.all([
      supabase.from('cash_requests').select('*, lines:cash_request_lines(*)').eq('branch_id', branchId).order('week_ending', { ascending: false }),
      supabase.from('expenses').select('id, paid_on, expense_date, amount_paid, description, quantity, unit_price, category_id, status').eq('branch_id', branchId).eq('status', 'recorded').gt('amount_paid', 0).gte('paid_on', since),
      supabase.from('purchase_payments').select('id, paid_on, amount, purchase:purchases!inner(branch_id, supplier_id, status, movement_id)').eq('purchase.branch_id', branchId).eq('purchase.status', 'recorded').gte('paid_on', since),
      supabase.from('payment_accounts').select('*').eq('branch_id', branchId).order('display_order'),
      supabase.from('expense_categories').select('id, name, status').order('display_order').order('name'),
      loadInventoryRefs(),
    ]);
    if (rq.error) { console.error(rq.error); setError("We couldn't load the weekly cash requests."); return; }
    // what was bought with each purchase payment: its materials, from the receipt
    const moveIds = [...new Set((pp.data || []).map(p => p.purchase.movement_id))];
    const tx = moveIds.length ? (await supabase.from('inventory_transactions').select('movement_id, material_id, entered_quantity, entered_unit_id').in('movement_id', moveIds)).data || [] : [];
    setData({ requests: rq.data || [], expenses: ex.data || [], payments: pp.data || [], accounts: (ac.data || []).filter(a => a.status === 'active'), cats: cats.data || [], refs, tx });
  }
  useEffect(() => { setData(null); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // money spent in a week (Sunday–Saturday): expenses paid and payments to suppliers
  const spentIn = useMemo(() => (weekEnding) => {
    if (!data) return [];
    const from = addDays(weekEnding, -6);
    const inWeek = d => d && d >= from && d <= weekEnding;
    const supplier = id => data.refs.suppliers.find(s => s.id === id)?.name ?? '';
    const goods = mid => data.tx.filter(t => t.movement_id === mid && t.material_id)
      .map(t => `${data.refs.items[`m:${t.material_id}`]?.name ?? ''}`).join(', ');
    const qtyOfMove = mid => data.tx.filter(t => t.movement_id === mid && t.material_id)
      .map(t => `${qtyText(Number(t.entered_quantity))} ${data.refs.unitById[t.entered_unit_id]?.symbol ?? ''}`).join(', ');
    return [
      ...data.expenses.filter(e => inWeek(e.paid_on)).map(e => ({ date: e.paid_on, description: e.description, qty: e.quantity ? qtyText(Number(e.quantity)) : '', amount: Number(e.amount_paid) })),
      ...data.payments.filter(p => inWeek(p.paid_on)).map(p => ({ date: p.paid_on, description: `${goods(p.purchase.movement_id) || 'Purchase'}${supplier(p.purchase.supplier_id) ? ` — ${supplier(p.purchase.supplier_id)}` : ''}`, qty: qtyOfMove(p.purchase.movement_id), amount: Number(p.amount) })),
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
  const thisWeek = here.find(r => r.week_ending === saturdayOf(today) && !['cancelled', 'rejected'].includes(r.status));
  const lastClosed = ledger[addDays(saturdayOf(today), -7)];
  const canPrepare = !!branchId && canAt('cash.request', branchId);

  return (
    <PageShell title="Weekly cash" subtitle="Finance"
      description={branchId ? `What ${branchName} asks for each week, its approval and payment, and what last week's money went on.` : 'Pick a branch in the sidebar.'}
      primaryAction={canPrepare && data && <button type="button" className="btn btn-primary" onClick={() => setOpen({ new: true })}><Plus size={15} /> New weekly request</button>}>
      {!branchId ? <div className="card"><EmptyState icon={Wallet} title="Pick a branch" description="Weekly cash is per branch." /></div>
      : error ? <div className="card"><ErrorState message={error} onRetry={load} /></div>
      : data === null ? <div className="card"><span className="skeleton" /></div> : (
        <>
          <div className="mm-stats">
            <div className="mm-stat"><span className="pl-label">This week</span><strong>{thisWeek ? money(approvedOf(thisWeek)) : '—'}</strong><span className="pl-help">{thisWeek ? `${STATUS[thisWeek.status][0]} · week ending ${thisWeek.week_ending}` : 'no request yet'}</span></div>
            <div className="mm-stat"><span className="pl-label">With directors</span><strong className={here.some(r => r.status === 'with_directors') ? 'text-warning' : ''}>{here.filter(r => r.status === 'with_directors').length}</strong><span className="pl-help">waiting for approval</span></div>
            <div className="mm-stat"><span className="pl-label">Last week's balance</span><strong>{lastClosed ? money(lastClosed.closing) : '—'}</strong><span className="pl-help">{lastClosed ? `spent ${formatMoneyShort(lastClosed.spent, organization?.currency_code)}` : 'from the first request on'}</span></div>
          </div>
          <div className="card"><div className="table-container">
            <table>
              <thead><tr><th>Week ending</th><th>Status</th><th className="num">Asked (TZS)</th><th className="num">Approved (TZS)</th><th className="num">Sent (TZS)</th><th className="num">Spent (TZS)</th><th className="num">Balance (TZS)</th></tr></thead>
              <tbody>
                {here.length === 0 ? <tr><td colSpan={7} className="text-muted">No weekly requests yet — New weekly request, or import this week's Excel sheet.</td></tr>
                : here.map(r => {
                  const w = ledger[r.week_ending];
                  return (
                    <tr key={r.id} className="clickable-row" onClick={() => setOpen(r)}>
                      <td>{r.week_ending}{r.source === 'excel' && <div className="pl-help">from Excel</div>}</td>
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
          <p className="pl-help" style={{ marginTop: 8 }}>A week runs Sunday to Saturday. Spent = expenses and payments to suppliers recorded as paid that week (Purchases). Balance = brought forward + cash sent − spent, carried into the next week.</p>
        </>
      )}
      {open && <RequestModal request={open.new ? null : open} branchId={branchId} branchName={branchName} data={data} ledger={ledger} today={today} money={money}
        organization={organization} onClose={() => setOpen(null)} onSaved={async () => { setOpen(null); await load(); }} />}
    </PageShell>
  );
}

function RequestModal({ request, branchId, branchName, data, ledger, today, money, organization, onClose, onSaved }) {
  const { canAt } = useAuth();
  const isNew = !request;
  const editable = isNew || request.status === 'draft';
  const prevLive = data.requests.filter(r => !['cancelled', 'rejected'].includes(r.status) && r.id !== request?.id).sort((a, b) => (a.week_ending < b.week_ending ? 1 : -1))[0];
  const [week, setWeek] = useState(request?.week_ending ?? saturdayOf(today));
  const [accountId, setAccountId] = useState(request?.account_id ?? data.accounts.find(a => a.receives_weekly_cash)?.id ?? '');
  const [opening, setOpening] = useState(request?.opening_balance != null ? String(Number(request.opening_balance)) : '');
  const [notes, setNotes] = useState(request?.notes ?? '');
  const [source, setSource] = useState(request?.source ?? 'app');
  const [lines, setLines] = useState(() => (request?.lines?.length
    ? [...request.lines].sort((a, b) => a.line_no - b.line_no).map(l => ({ id: l.id, description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unit: l.unit ?? '', amount: String(Number(l.amount)), approved: l.approved_amount != null ? String(Number(l.approved_amount)) : '', categoryId: l.category_id ?? '' }))
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
  const acc = data.accounts.find(a => a.id === accountId);
  const step = async (name, p = {}) => {
    setError(''); setBusy(true);
    const { error: err } = await supabase.rpc('cash_request_step', { p_id: request.id, p_step: name, p });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  };
  async function save() {
    setError('');
    const ls = lines.filter(l => l.description.trim() || num(l.amount) != null);
    if (!ls.length) { setError('Add what is needed.'); return; }
    if (ls.some(l => !l.description.trim() || num(l.amount) == null)) { setError('Each line needs what it is for and an amount.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('save_cash_request', { p: { id: request?.id ?? null, branch_id: branchId, week_ending: week, account_id: accountId || null,
      opening_balance: firstEver ? num(opening) : null, notes, source,
      lines: ls.map(l => ({ description: l.description, quantity: num(l.quantity), unit: l.unit, amount: num(l.amount), category_id: l.categoryId || null })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  async function importFile(f) {
    setError('');
    try {
      const s = await readWeeklySheet(f);
      setLines(s.lines.map(l => ({ description: l.description, quantity: l.quantity != null ? String(l.quantity) : '', unit: l.unit || '', amount: String(l.amount), categoryId: '' })));
      if (s.weekEnding) setWeek(saturdayOf(s.weekEnding));
      setSource('excel');
      if (s.total != null && Math.abs(s.total - s.lines.reduce((t, l) => t + l.amount, 0)) > 0.5) setError(`Read ${s.lines.length} lines — their sum differs from the sheet's TOTAL (${formatAmount(s.total)}). Check before saving.`);
    } catch (e) { setError(e.message || 'That file could not be read.'); }
  }
  const copyLast = () => prevLive && setLines([...prevLive.lines].sort((a, b) => a.line_no - b.line_no).map(l => ({ description: l.description, quantity: l.quantity != null ? String(Number(l.quantity)) : '', unit: l.unit ?? '', amount: String(Number(l.approved_amount ?? l.amount)), categoryId: l.category_id ?? '' })));
  const exportFile = () => writeWeeklySheet({
    fileName: `Weekly cash ${branchName} ${week}.xlsx`,
    summaryTitle: `SUMMARY YA MATUMIZI YA LAST WEEK ${longDate(addDays(week, -7))}`,
    summary: lastWeek ? { date: addDays(week, -7), opening: lastWeek.opening, sent: lastWeek.sent, spent: lastWeek.spent, closing: lastWeek.closing,
      lines: (() => { let b = lastWeek.opening + lastWeek.sent; return lastWeek.lines.map(l => { b = r2(b - l.amount); return { ...l, balance: b }; }); })() } : null,
    needsTitle: `MAHITAJI YA WIKI HII (${longDate(week)})`,
    needs: lines.filter(l => l.description.trim()).map(l => ({ description: l.description, qty: [l.unit, l.quantity].filter(Boolean).join(' '), amount: num(request && ['approved', 'paid'].includes(request.status) ? (l.approved || l.amount) : l.amount) ?? 0 })),
    account: acc ? { bank: acc.name, number: acc.account_no ?? '', holder: acc.account_name ?? '' } : null,
  });

  const st = request?.status ?? 'draft';
  return (
    <Modal title={isNew ? 'New weekly request' : `Weekly cash — week ending ${request.week_ending}`} onClose={onClose} size="xl"
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
          {request.decision_note ? ` · ${request.decision_note}` : ''}{st === 'paid' ? ` · ${money(Number(request.paid_amount))} sent on ${request.paid_on}${request.paid_reference ? ` (${request.paid_reference})` : ''}` : ''}</p>}

        <h3 className="modal-section-title">Last week — week ending {addDays(week, -7)}</h3>
        {lastWeek ? (
          <table className="rd-table">
            <thead><tr><th>Date</th><th>Description</th><th>Qty</th><th className="num">Cash in (TZS)</th><th className="num">Cash out (TZS)</th><th className="num">Balance (TZS)</th></tr></thead>
            <tbody>
              <tr><td /><td>Balance brought forward</td><td /><td className="num">{formatAmount(lastWeek.opening)}</td><td /><td /></tr>
              <tr><td /><td>Cash sent</td><td /><td className="num">{formatAmount(lastWeek.sent)}</td><td /><td className="num"><strong>{formatAmount(lastWeek.opening + lastWeek.sent)}</strong></td></tr>
              {(() => { let b = lastWeek.opening + lastWeek.sent; return lastWeek.lines.map((l, i) => { b = r2(b - l.amount); return (
                <tr key={i}><td>{l.date}</td><td>{l.description}</td><td className="pl-help">{l.qty}</td><td /><td className="num">{formatAmount(l.amount)}</td><td className="num">{formatAmount(b)}</td></tr>); }); })()}
            </tbody>
            <tfoot><tr><td /><td><strong>Spent · balance</strong></td><td /><td /><td className="num"><strong>{money(lastWeek.spent)}</strong></td><td className="num"><strong>{money(lastWeek.closing)}</strong></td></tr></tfoot>
          </table>
        ) : <p className="pl-help">{firstEver ? 'The first week: type the balance brought forward below.' : 'No week before this one yet.'}</p>}

        <h3 className="modal-section-title">This week's needs</h3>
        <div className="form-row">
          <label className="pe-field"><span>Week ending (Saturday)</span><input type="date" className="form-input" disabled={!editable} value={week} onChange={e => setWeek(saturdayOf(e.target.value))} /></label>
          <label className="pe-field"><span>Paid into</span>
            <select className="form-input" disabled={!editable} value={accountId} onChange={e => setAccountId(e.target.value)}>
              <option value="">Choose…</option>{data.accounts.map(a => <option key={a.id} value={a.id}>{a.name}{a.account_no ? ` · ${a.account_no}` : ''}</option>)}
            </select></label>
          {firstEver && <label className="pe-field"><span>Balance brought forward (first week)</span><NumberInput step="any" className="form-input" disabled={!editable} value={opening} onChange={e => setOpening(e.target.value)} /></label>}
        </div>
        {editable && (
          <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
            <input ref={fileRef} type="file" accept=".xlsx" hidden onChange={e => { if (e.target.files?.[0]) importFile(e.target.files[0]); e.target.value = ''; }} />
            <button type="button" className="btn btn-outline btn-sm" onClick={() => fileRef.current?.click()}><Upload size={14} /> Import Excel sheet</button>
            {prevLive && <button type="button" className="btn btn-ghost btn-sm" onClick={copyLast}><Copy size={14} /> Start from last week's lines</button>}
            <span className="pl-help">The sheet's "needs this week" table (DESCRIPTION · QTY · AMOUNT) is read; check it before saving.</span>
          </div>
        )}
        <table className="rd-table">
          <thead><tr><th>Description</th><th className="num">Qty</th><th>Unit</th><th className="num">Amount (TZS)</th>{!isNew && st !== 'draft' && <th className="num">Approved (TZS)</th>}<th>Category</th><th /></tr></thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td><input className="form-input" disabled={!editable} value={l.description} onChange={e => set(i, { description: e.target.value })} /></td>
                <td className="num"><NumberInput step="any" className="form-input" style={{ width: 80 }} disabled={!editable} value={l.quantity} onChange={e => set(i, { quantity: e.target.value })} /></td>
                <td><input className="form-input" style={{ width: 70 }} disabled={!editable} value={l.unit} onChange={e => set(i, { unit: e.target.value })} /></td>
                <td className="num"><NumberInput step="any" min="0" className="form-input" style={{ width: 120 }} disabled={!editable} value={l.amount} onChange={e => set(i, { amount: e.target.value })} /></td>
                {!isNew && st !== 'draft' && <td className="num">{st === 'with_directors' && canAt('cash.approve', branchId)
                  ? <NumberInput step="any" min="0" className="form-input" style={{ width: 120 }} placeholder={l.amount} value={l.approved} onChange={e => set(i, { approved: e.target.value })} />
                  : formatAmount(num(l.approved) ?? num(l.amount))}</td>}
                <td><select className="form-input" disabled={!editable} value={l.categoryId} onChange={e => set(i, { categoryId: e.target.value })}>
                  <option value="">—</option>{data.cats.filter(c => c.status === 'active' || c.id === l.categoryId).map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></td>
                <td>{editable && lines.length > 1 && <button type="button" className="btn btn-ghost btn-sm" aria-label="Remove line" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={13} /></button>}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr>
            <td>{editable && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setLines(ls => [...ls, { description: '', quantity: '', unit: '', amount: '', categoryId: '' }])}><Plus size={13} /> Add a line</button>}<strong style={{ marginLeft: 8 }}>Total</strong></td>
            <td /><td /><td className="num"><strong>{money(total)}</strong></td>{!isNew && st !== 'draft' && <td className="num"><strong>{money(approvedTotal)}</strong></td>}<td colSpan={2} />
          </tr></tfoot>
        </table>
        {acc && <p className="text-sm">Paid into <strong>{acc.name}</strong>{acc.account_no ? ` · ${acc.account_no}` : ''}{acc.account_name ? ` · ${acc.account_name}` : ''}</p>}
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
    </Modal>
  );
}
