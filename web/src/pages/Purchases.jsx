import { useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { ShoppingCart, Plus, Trash2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import { loadInventoryRefs, warehouseLabel, qtyText, orgToday, byMaterialOrder, materialStockValue } from '../lib/inventory';
import PageShell from '../components/PageShell';
import { PageTabs, ChipRow } from '../components/ListControls';
import ExpenseModal from '../components/purchases/ExpenseModal';
import PowerMetersCard from '../components/settings/PowerMetersCard';
import OverheadCategoriesCard from '../components/settings/OverheadCategoriesCard';
import ElectricityPanel, { BuyModal } from '../components/purchases/ElectricityPanel';
import { RequestsPanel, PayPurchaseModal } from '../components/purchases/ProcurementPanels';
import ItemHistoryModal from '../components/inventory/ItemHistory';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import NumberInput from '../components/NumberInput';

const LOAD_ERROR = "We couldn't load purchases. Please try again.";
const PAYMENT_LABEL = { paid: 'Paid', part_paid: 'Part-paid', unpaid: 'Unpaid', void: 'Void' };
const PAYMENT_BADGE = { paid: 'badge-success', part_paid: 'badge-warning', unpaid: 'badge-neutral', void: 'badge-neutral' };
const METHODS = ['Cash', 'Mobile money', 'Bank transfer', 'Cheque'];
const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
// From the third purchase of a material at a branch, a new entry starts
// from the latest one's details (decided 2026-10-18); the user changes what differs
const AUTOFILL_AFTER = 1;   // a material's last price, unit and supplier fill the next purchase (SwahziTech, 2026-10-24)
// VAT on a purchase (decided 2026-10-18): ticked = the prices include VAT at
// the branch's rate (041, set by the branch manager), worked out as
// goods × r/(100 + r) — 18/118 at 18%. 18% until a branch has its own.
const DEFAULT_VAT = 18;
const round2 = n => Math.round(n * 100) / 100;

/*
 * Purchases (migration 035): the money side of material receipts. The
 * storekeeper receives the goods (Stock → Receive); the secretary or branch
 * manager completes the purchase here — supplier, prices, transport, VAT,
 * payment — or records goods and purchase together. Costs feed each
 * branch's moving average cost per material.
 */
export default function Purchases() {
  const { organization, canAt, canManage } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const money = v => formatMoney(v, organization?.currency_code);
  const canRecordAt = id => !!id && canAt('procurement.receive', id, null);

  const [tab,       setTab]       = useState(null);   // null until loaded: opens on "Waiting" only when something waits
  const [pendingReq, setPendingReq] = useState([]);   // purchases sent for approval, not yet decided
  const [refs,      setRefs]      = useState(null);
  const [materials, setMaterials] = useState([]);   // with branch_id (032)
  const [purchases, setPurchases] = useState([]);
  const [totals,    setTotals]    = useState({});
  const [awaiting,  setAwaiting]  = useState([]);
  const [txByMove,  setTxByMove]  = useState({});   // movement id → its stock lines
  const [people,    setPeople]    = useState({});
  const [costs,     setCosts]     = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [editing, setEditing] = useState(null);     // { mode: 'complete'|'new'|'edit', receipt?, purchase?, materialId? }
  const [historyOf, setHistoryOf] = useState(null); // a material whose purchases are shown
  // Materials' "Intake" opens a new purchase for that material (?buy=<material id>)
  const [params, setParams] = useSearchParams();
  const buyId = params.get('buy');
  useEffect(() => {
    if (!buyId || !refs) return;
    setEditing({ mode: 'new', materialId: buyId });
    setParams({}, { replace: true });
  }, [buyId, refs]); // eslint-disable-line react-hooks/exhaustive-deps
  const [deleting, setDeleting] = useState(null);   // a void purchase the technical admin is deleting
  // procurement (077): paying a purchase; an approved request being turned into an order; the branch's accounts to pay from
  const [paying, setPaying] = useState(null);
  const [orderFrom, setOrderFrom] = useState(null);
  const [payAccounts, setPayAccounts] = useState([]);
  useEffect(() => { supabase.from('payment_accounts').select('id, name, branch_id, status').eq('status', 'active').order('display_order').then(({ data }) => setPayAccounts(data || [])); }, []);
  const [vatRates,  setVatRates]  = useState({});     // branch id → VAT rate (041)
  const [expCats,   setExpCats]   = useState([]);
  const [expenses,  setExpenses]  = useState([]);
  const [expReady,  setExpReady]  = useState(false);  // false until migration 041 is live
  const [expChip,   setExpChip]   = useState('');
  const [editingExpense, setEditingExpense] = useState(null);   // 'new' | an expense
  const [expSettings, setExpSettings] = useState(false);        // ⚙: LUKU meters (072)
  const [expensePrefill, setExpensePrefill] = useState(null);   // a new expense for an approved request line (080) or an order line (082)
  const [ordersKey, setOrdersKey] = useState(0);                // refreshes the Orders list after a token is recorded
  const [tokenFor, setTokenFor] = useState(null);               // a LUKU order line being recorded as bought (082)

  async function load() {
    setError('');
    // With a branch picked, only its records are fetched (before any row limit)
    const byBranch = q => (branchId ? q.eq('branch_id', branchId) : q);
    try {
      const [r, mat, pu, tot, aw, pr] = await Promise.all([
        loadInventoryRefs(),
        supabase.from('materials').select('id, name, status, branch_id, category:material_categories(display_order)').order('name'),
        byBranch(supabase.from('purchases').select(`id, branch_id, movement_id, supplier_id, purchase_date, invoice_reference, transport_charge,
          vat_amount, prices_include_vat, amount_paid, payment_method, paid_on, status, void_reason, notes, created_by,
          lines:purchase_lines(id, transaction_id, unit_price, line_amount)`)).order('purchase_date', { ascending: false }).limit(300),
        byBranch(supabase.from('purchase_totals').select('*')),
        byBranch(supabase.from('receipts_awaiting_purchase').select('*')).order('movement_date', { ascending: false }),
        byBranch(supabase.from('pending_changes').select('id, branch_id, summary, payload, requested_by, requested_at')
          .eq('kind', 'purchase').eq('status', 'pending')).order('requested_at', { ascending: false }),
      ]);
      const err = mat.error || pu.error || tot.error || aw.error || pr.error;
      if (err) throw err;
      const moveIds = [...new Set([...(pu.data || []).map(p => p.movement_id), ...(aw.data || []).map(a => a.movement_id)])];
      const tx = moveIds.length
        ? await supabase.from('inventory_transactions')
            .select('id, movement_id, material_id, product_id, quantity, stock_unit_id, entered_quantity, entered_unit_id, warehouse_id')
            .in('movement_id', moveIds).eq('transaction_type', 'receipt')
        : { data: [] };
      if (tx.error) throw tx.error;
      const byMove = {};
      for (const t of tx.data) (byMove[t.movement_id] ||= []).push(t);
      const ids = [...new Set([...(aw.data || []).map(a => a.created_by), ...(pu.data || []).map(p => p.created_by), ...(pr.data || []).map(p => p.requested_by)].filter(Boolean))];
      if (ids.length) {
        const { data: ppl } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
        setPeople(Object.fromEntries((ppl || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
      }
      setRefs(r);
      // the agreed material order (category order, then name)
      setMaterials((mat.data || []).map(m => ({ ...m, rank: m.category?.display_order ?? 999 })).sort(byMaterialOrder));
      setPurchases(pu.data || []);
      setTotals(Object.fromEntries((tot.data || []).map(t => [t.purchase_id, t])));
      setAwaiting(aw.data || []);
      setPendingReq(pr.data || []);
      setTxByMove(byMove);
      setTab(t => t ?? (params.get('tab') || ((aw.data || []).some(a => inBranch(a.branch_id)) ? 'waiting' : 'purchases')));   // ?tab= from other pages (Costing › Electricity)
      // Branch VAT rates and expenses (041): the page still works without them
      const [vr, ec, ex] = await Promise.all([
        supabase.from('branches').select('id, vat_rate'),
        supabase.from('expense_categories').select('*').order('display_order').order('name'),
        byBranch(supabase.from('expenses').select('*')).order('expense_date', { ascending: false }).order('created_at', { ascending: false }).limit(500),
      ]);
      setVatRates(vr.error ? {} : Object.fromEntries((vr.data || []).map(b => [b.id, Number(b.vat_rate)])));
      setExpReady(!ec.error && !ex.error);
      setExpCats(ec.data || []);
      setExpenses(ex.data || []);
    } catch (e) {
      console.error(e);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }

  useEffect(() => { setLoading(true); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Moving average cost per material at the picked branch
  useEffect(() => {
    if (tab !== 'costs' || !branchId || !materials.length) return;
    let live = true;
    Promise.all(materials.filter(m => m.status === 'active' && (!m.branch_id || m.branch_id === branchId)).map(async m => {
      const v = await materialStockValue(branchId, m.id);
      return { material: m, average_cost: v?.unit_cost ?? null, last_purchase_cost: v?.last_cost ?? null, last_purchase_date: v?.last_date ?? null,
        costed_quantity: v?.costed_quantity ?? (v?.on_hand != null ? Number(v.on_hand) - Number(v.uncosted_quantity ?? 0) : null), uncosted_quantity: v?.uncosted_quantity ?? 0, value: v?.value ?? null };
    })).then(rows => { if (live) setCosts(rows); });
    return () => { live = false; };
  }, [tab, branchId, materials, purchases]);

  const supplierName = id => refs?.suppliers.find(s => s.id === id)?.name ?? '—';
  const waitingHere = awaiting.filter(a => inBranch(a.branch_id));
  // Opening stock costs: a material never bought yet fills its price from there
  const [openingCosts, setOpeningCosts] = useState([]);
  useEffect(() => {
    supabase.from('inventory_transactions')
      .select('material_id, entered_unit_id, entered_quantity, unit_cost, transaction_date, warehouse:warehouses(branch_id)')
      .eq('transaction_type', 'opening_balance').not('material_id', 'is', null).not('unit_cost', 'is', null)
      .then(({ data }) => setOpeningCosts(data || []));
  }, []);

  // Each material's recorded purchases per branch, newest first (purchases load newest first)
  const history = useMemo(() => {
    const h = {};
    for (const p of purchases) {
      if (p.status !== 'recorded') continue;
      for (const l of p.lines || []) {
        const t = (txByMove[p.movement_id] || []).find(x => x.id === l.transaction_id);
        if (!t?.material_id) continue;
        (h[`${p.branch_id}|${t.material_id}`] ||= []).push({ date: p.purchase_date, supplierId: p.supplier_id, unitId: t.entered_unit_id,
          qty: Number(t.entered_quantity), price: Number(l.unit_price), method: p.payment_method });
      }
    }
    for (const o of openingCosts) {
      const k = `${o.warehouse?.branch_id}|${o.material_id}`;
      if (h[k]?.some(x => !x.opening)) continue;   // a real purchase always wins
      (h[k] ||= []).push({ date: o.transaction_date, supplierId: null, unitId: o.entered_unit_id, qty: Number(o.entered_quantity), price: Number(o.unit_cost), method: null, opening: true });
    }
    return h;
  }, [purchases, txByMove, openingCosts]);

  // Technical admin (system.manage): may delete a purchase entered wrongly (040)
  const isTechAdmin = canManage('system.manage');
  const purchasesHere = purchases.filter(p => inBranch(p.branch_id));
  const vatRateOf = b => vatRates[b] ?? DEFAULT_VAT;
  const catName = id => expCats.find(c => c.id === id)?.name ?? '—';
  const expensesHere = expenses.filter(e => inBranch(e.branch_id) && (!expChip || e.category_id === expChip));
  const expensePay = e => (e.status === 'void' ? 'void' : Number(e.amount_paid) >= Number(e.amount) ? 'paid' : Number(e.amount_paid) > 0 ? 'part_paid' : 'unpaid');
  const pendingHere = pendingReq.filter(p => inBranch(p.branch_id));
  const owed = purchasesHere.filter(p => p.status === 'recorded').reduce((s, p) => s + Math.max(Number(totals[p.id]?.balance ?? 0), 0), 0);
  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const describeLines = lines => (lines || []).filter(t => t.material_id)
    .map(t => `${qtyText(t.entered_quantity)} ${refs?.unitById[t.entered_unit_id]?.symbol ?? ''} ${refs?.items[`m:${t.material_id}`]?.name ?? ''}`).join(', ');

  const purchaseTabs = (
    <PageTabs value={tab} onChange={setTab}
      tabs={[['purchases', `Purchases${pendingHere.length ? ` (${pendingHere.length} waiting for approval)` : ''}`], ['requests', 'Requests'], ...(expReady ? [['expenses', 'Expenses'], ['electricity', 'Electricity']] : []), ['costs', 'Material costs'], ['waiting', `Waiting for details (${waitingHere.length})`]]} />
  );

  return (
    <PageShell title="Purchases" subtitle="Inventory" onSettings={() => setExpSettings(true)}
      description="The money side of materials received: supplier, cost, payment — and each branch's material costs."
      actions={expReady && expCats.length > 0 && (branchId ? canRecordAt(branchId) : true) && (
        <button type="button" className="btn btn-outline" onClick={() => setEditingExpense('new')}>
          <Plus size={14} /> Record expense
        </button>
      )}
      primaryAction={canRecordAt(branchId) && (
        <button type="button" className="btn btn-primary" disabled={!refs} onClick={() => setEditing({ mode: 'new' })}>
          <Plus size={14} /> Record Goods + Purchase
        </button>
      )}>
      {/* page order (locked): heading → tabs → summary → search/filters → list */}
      {purchaseTabs}
      {tab === 'purchases' && owed > 0 && <p className="text-sm text-muted mb-8" style={{ textAlign: 'right' }}>Still to pay: <strong>{money(round2(owed))}</strong></p>}

      {tab === 'requests' ? <RequestsPanel key={`r${ordersKey}`} refs={refs} branchId={branchId} inBranch={inBranch} people={people} money={money} openFirst={orderFrom?.id} onOpened={() => setOrderFrom(null)}
          onReceive={fromOrder => setEditing({ mode: 'new', fromOrder })}
          onRecordExpense={prefill => { setExpensePrefill(prefill); setEditingExpense('new'); }}
          onRecordToken={q => setTokenFor(q)} />
      : tab === 'electricity' ? <ElectricityPanel branchId={branchId} onOrder={q => { setOrderFrom(q); setTab('requests'); }} /> : <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            {tab === 'waiting' && (
              <table>
                <thead><tr><th>Received</th><th>Store</th><th>Goods</th><th>Received by</th><th aria-label="Actions" /></tr></thead>
                <tbody>
                  {loading ? <SkeletonRow cols={5} /> : waitingHere.length === 0 ? (
                    <tr><td colSpan={5}><EmptyState icon={ShoppingCart} title="Nothing waiting"
                      description="Materials the storekeeper receives appear here until the supplier, cost and payment are added." /></td></tr>
                  ) : waitingHere.map(a => (
                    <tr key={a.movement_id}>
                      <td>{a.movement_date}{a.reference && <div className="text-xs text-muted">{a.reference}</div>}</td>
                      <td className="text-muted">{warehouseLabel(whById[a.warehouse_id])}</td>
                      <td className="text-sm">{describeLines(txByMove[a.movement_id])}</td>
                      <td className="text-sm text-muted">{people[a.created_by] ?? '—'}</td>
                      <td style={{ textAlign: 'right' }}>
                        {canRecordAt(a.branch_id) && (
                          <button type="button" className="btn btn-primary btn-sm" onClick={() => setEditing({ mode: 'complete', receipt: a })}>Add purchase details</button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}

            {tab === 'purchases' && (
              <table>
                <thead><tr><th>Date</th><th>Item</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Price</th><th>Source</th><th style={{ textAlign: 'right' }}>Total</th><th>Payment</th><th aria-label="Actions" /></tr></thead>
                <tbody>
                  {/* Sent for approval (backdated or by a branch manager): shown until an admin decides */}
                  {!loading && pendingHere.map(p => {
                    // the same short columns, read from what was sent for approval
                    const rl = p.payload?.receipt?.lines || [];
                    const priceOf = m => (p.payload?.lines || []).find(l => l.material_id === m)?.unit_price;
                    const goods = rl.reduce((sum, l) => sum + Number(l.quantity) * Number(priceOf(l.material_id) ?? 0), 0);
                    return (
                    <tr key={p.id} className="text-muted">
                      <td>{p.payload?.receipt?.movement_date ?? p.payload?.purchase_date ?? '—'}</td>
                      {rl.length ? <>
                        <td style={{ fontWeight: 500 }}>{rl.map((l, i) => <div key={i}>{refs?.items[`m:${l.material_id}`]?.name ?? '—'}</div>)}</td>
                        <td style={{ textAlign: 'right' }}>{rl.map((l, i) => <div key={i}>{qtyText(l.quantity)} <span className="text-xs">{refs?.unitById[l.unit_id]?.symbol}</span></div>)}</td>
                        <td style={{ textAlign: 'right' }}>{rl.map((l, i) => <div key={i}>{priceOf(l.material_id) != null ? money(priceOf(l.material_id)) : '—'}</div>)}</td>
                      </> : <td className="text-sm" colSpan={3}>{p.summary}</td>}
                      <td>{p.payload?.supplier_id ? supplierName(p.payload.supplier_id) : p.payload?.new_supplier_name ?? '—'}</td>
                      <td style={{ textAlign: 'right' }}>{rl.length ? money(round2(goods + Number(p.payload?.transport_charge ?? 0))) : ''}</td>
                      <td><span className="badge badge-warning">Waiting for approval</span>
                        <div className="text-xs">{people[p.requested_by] ?? ''} · {p.requested_at.slice(0, 10)}</div></td>
                      <td style={{ textAlign: 'right' }}><Link to="/approvals" className="btn btn-ghost btn-sm">Approvals</Link></td>
                    </tr>
                    );
                  })}
                  {loading ? <SkeletonRow cols={8} /> : purchasesHere.length === 0 ? (
                    pendingHere.length ? null : <tr><td colSpan={8}><EmptyState icon={ShoppingCart} title="No purchases yet" description="" /></td></tr>
                  ) : purchasesHere.map(p => {
                    const t = totals[p.id];
                    const priceOfTx = Object.fromEntries((p.lines || []).map(l => [l.transaction_id, l.unit_price]));
                    const ls = (txByMove[p.movement_id] || []).filter(x => x.material_id);
                    return (
                      <tr key={p.id} className={p.status === 'void' ? 'text-muted' : ''}>
                        <td>{p.purchase_date}{p.invoice_reference && <div className="text-xs text-muted">{p.invoice_reference}</div>}</td>
                        <td style={{ fontWeight: 500 }}>{ls.map(x => {
                          // double-click (a tap on a phone) opens that material's purchases
                          const open = () => { const it = refs?.items[`m:${x.material_id}`]; if (it) setHistoryOf({ id: it.id, name: it.name }); };
                          return <div key={x.id} className="pu-item" title="Double-click for its purchases" onDoubleClick={open} onClick={() => { if (window.matchMedia('(pointer: coarse)').matches) open(); }}>{refs?.items[`m:${x.material_id}`]?.name ?? '—'}</div>;
                        })}</td>
                        <td style={{ textAlign: 'right' }}>{ls.map(x => <div key={x.id}>{qtyText(x.entered_quantity)} <span className="text-muted text-xs">{refs?.unitById[x.entered_unit_id]?.symbol}</span></div>)}</td>
                        <td style={{ textAlign: 'right' }}>{ls.map(x => <div key={x.id}>{priceOfTx[x.id] != null ? money(priceOfTx[x.id]) : '—'}</div>)}</td>
                        <td>{supplierName(p.supplier_id)}</td>
                        <td style={{ textAlign: 'right' }}>{t ? money(t.total) : '—'}</td>
                        <td>
                          <span className={`badge ${PAYMENT_BADGE[t?.payment_status] ?? 'badge-neutral'}`}>{PAYMENT_LABEL[t?.payment_status] ?? '—'}</span>
                          {t?.payment_status === 'part_paid' && <div className="text-xs text-muted">{money(t.balance)} to pay</div>}
                          {p.status === 'void' && <div className="text-xs text-muted">{p.void_reason}</div>}
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          {p.status === 'recorded' && canRecordAt(p.branch_id) && t && Number(t.balance) > 0.004 && (
                            <button type="button" className="btn btn-primary btn-sm" style={{ marginRight: 6 }} onClick={() => setPaying({ purchase: p, total: t.total })}>Pay…</button>
                          )}
                          {p.status === 'recorded' && canRecordAt(p.branch_id) && (
                            <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing({ mode: 'edit', purchase: p })}>Open</button>
                          )}
                          {p.status === 'void' && isTechAdmin && (
                            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDeleting(p)}>Delete…</button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}

            {tab === 'expenses' && (
              <>
                {expCats.length > 0 && (
                  <div className="card-body" style={{ paddingBottom: 0 }}>
                    <ChipRow value={expChip} onChange={setExpChip} items={expCats.filter(c => c.status === 'active').map(c => ({ id: c.id, label: c.name }))} />
                  </div>
                )}
                <table>
                  <thead><tr><th>Date</th><th>Item</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Price</th><th>Source</th><th style={{ textAlign: 'right' }}>Total</th><th>Payment</th><th aria-label="Actions" /></tr></thead>
                  <tbody>
                    {loading ? <SkeletonRow cols={8} /> : expensesHere.length === 0 ? (
                      <tr><td colSpan={8}><EmptyState icon={ShoppingCart} title="No expenses yet" description="Electricity (LUKU), water, office tools, equipment… — use Record expense." /></td></tr>
                    ) : expensesHere.map(e => {
                      const pay = expensePay(e);
                      return (
                        <tr key={e.id} className={e.status === 'void' ? 'text-muted' : ''}>
                          <td>{e.expense_date}</td>
                          <td><span style={{ fontWeight: 500 }}>{e.description}</span><div className="text-xs text-muted">{catName(e.category_id)}</div></td>
                          <td style={{ textAlign: 'right' }}>{e.quantity != null ? qtyText(e.quantity) : '—'}</td>
                          <td style={{ textAlign: 'right' }}>{e.unit_price != null ? money(e.unit_price) : '—'}</td>
                          <td>{e.supplier_id ? supplierName(e.supplier_id) : '—'}</td>
                          <td style={{ textAlign: 'right' }}>{money(e.amount)}{e.vat_amount != null && <div className="text-xs text-muted">VAT {money(e.vat_amount)}</div>}</td>
                          <td>
                            <span className={`badge ${PAYMENT_BADGE[pay] ?? 'badge-neutral'}`}>{PAYMENT_LABEL[pay]}</span>
                            {pay === 'part_paid' && <div className="text-xs text-muted">{money(round2(e.amount - e.amount_paid))} to pay</div>}
                            {e.status === 'void' && <div className="text-xs text-muted">{e.void_reason}</div>}
                          </td>
                          <td style={{ textAlign: 'right' }}>
                            {e.status === 'recorded' && canRecordAt(e.branch_id) && (
                              <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditingExpense(e)}>Open</button>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </>
            )}

            {tab === 'costs' && (!branchId ? (
              <EmptyState icon={ShoppingCart} title="Pick a branch" description="Material costs are per branch — pick one in the sidebar." />
            ) : (
              <table>
                <thead><tr><th>Material</th><th style={{ textAlign: 'right' }} title="Cost of the stock left — oldest stock is used first">Cost of stock left</th><th style={{ textAlign: 'right' }}>Latest cost</th><th>Costed stock</th></tr></thead>
                <tbody>
                  {costs.length === 0 ? <SkeletonRow cols={4} /> : costs.map(c => {
                    const unit = refs?.unitById[refs?.items[`m:${c.material.id}`]?.stockUnitId]?.symbol ?? '';
                    return (
                      <tr key={c.material.id} className="clickable-row" title="Open its purchases" onClick={() => setHistoryOf(c.material)}>
                        <td style={{ fontWeight: 500 }}>{c.material.name}</td>
                        <td style={{ textAlign: 'right' }}>{c.average_cost != null ? <>{money(round2(c.average_cost))} <span className="text-muted">/ {unit}</span></> : <span className="text-muted">no cost yet</span>}</td>
                        <td style={{ textAlign: 'right' }}>{c.last_purchase_cost != null ? <>{money(round2(c.last_purchase_cost))} <span className="text-xs text-muted">{c.last_purchase_date}</span></> : <span className="text-muted">—</span>}</td>
                        <td className="text-sm text-muted">
                          {Number(c.costed_quantity) > 0 ? `${qtyText(c.costed_quantity)} ${unit}` : '—'}
                          {Number(c.uncosted_quantity) > 0 && <div className="text-xs">{qtyText(c.uncosted_quantity)} {unit} with no cost</div>}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            ))}
            {tab === 'costs' && branchId && (
              <div className="table-footer-note">
                Moving average landed cost at {branchName} — price plus transport, excluding VAT shown separately. Stock received before its first purchase has no cost and is left out.
              </div>
            )}
          </div>
        )}
      </div>}

      {editing && refs && (
        <PurchaseModal {...editing} refs={refs} materials={materials} txByMove={txByMove} organization={organization}
          branchId={branchId} canAt={canAt} canManage={canManage}
          goods={editing.purchase ? describeLines(txByMove[editing.purchase.movement_id]) : ''} history={history} vatRateOf={vatRateOf}
          onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); setOrdersKey(k => k + 1); await load(); }} />
      )}
      {editingExpense && refs && (
        <ExpenseModal expense={editingExpense === 'new' ? null : editingExpense} prefill={editingExpense === 'new' ? expensePrefill : null} branchId={branchId} categories={expCats}
          suppliers={refs.suppliers} vatRateOf={vatRateOf} organization={organization} canRecordAt={canRecordAt}
          onClose={() => { setEditingExpense(null); setExpensePrefill(null); }}
          onSaved={async () => { const from = expensePrefill ? tab : 'expenses'; setEditingExpense(null); setExpensePrefill(null); setOrdersKey(k => k + 1); setTab(from); await load(); }} />
      )}
      {tokenFor && <BuyModal q={tokenFor} meterName={tokenFor.meterName} today={orgToday(organization?.timezone)} money={money}
        onClose={() => setTokenFor(null)} onSaved={async () => { setTokenFor(null); setOrdersKey(k => k + 1); await load(); }} />}
      {paying && <PayPurchaseModal purchase={paying.purchase} total={paying.total} supplierName={supplierName(paying.purchase.supplier_id)} currency={organization?.currency_code}
        accounts={payAccounts.filter(a => a.branch_id === paying.purchase.branch_id)} onClose={() => setPaying(null)} onSaved={async () => { setPaying(null); await load(); }} />}
      {deleting && (
        <Modal title={`Delete the purchase of ${deleting.purchase_date}`} onClose={() => setDeleting(null)}>
          <DeletePurchase purchase={deleting} goods={describeLines(txByMove[deleting.movement_id])}
            onCancel={() => setDeleting(null)} onDeleted={async () => { setDeleting(null); await load(); }} />
        </Modal>
      )}
      {historyOf && refs && (() => {
        const it = refs.items[`m:${historyOf.id}`];
        const mu = it?.mainUnitId ? it.units.find(u => u.id === it.mainUnitId) : null;
        return (
          <ItemHistoryModal title={`${historyOf.name} — purchases`} item={{ kind: 'material', id: historyOf.id, name: historyOf.name }} branchId={branchId} mode="purchases"
            suppliers={refs.suppliers} unit={{ factor: mu?.factor ?? 1, symbol: refs.unitById[mu?.id ?? it?.stockUnitId]?.symbol ?? '', stockSymbol: refs.unitById[it?.stockUnitId]?.symbol ?? '' }}
            onClose={() => setHistoryOf(null)} />
        );
      })()}
      {expSettings && (
        <Modal title="Purchases & expenses settings" onClose={() => setExpSettings(false)} size="lg"
          footer={<button type="button" className="btn btn-outline" onClick={() => setExpSettings(false)}>Close</button>}>
          <PowerMetersCard />
          <OverheadCategoriesCard onChanged={load} />
        </Modal>
      )}
    </PageShell>
  );
}

function PurchaseModal({ mode, receipt, purchase, materialId, fromOrder, refs, materials, txByMove, organization, branchId, canAt, canManage, goods, history = {}, vatRateOf = () => DEFAULT_VAT, onClose, onSaved }) {
  const money = v => formatMoney(v, organization?.currency_code);
  const today = orgToday(organization?.timezone);
  const isNew = mode === 'new';
  const movementId = receipt?.movement_id ?? purchase?.movement_id;
  const receiptLines = (txByMove[movementId] || []).filter(t => t.material_id);
  const priceOf = Object.fromEntries((purchase?.lines || []).map(l => [l.transaction_id, String(l.unit_price)]));

  // goods + purchase in one: stores at the picked branch where the user can receive and record purchases
  const stores = refs.warehouses.filter(w => w.status === 'active' && w.branch_id === branchId
    && canAt('inventory.receive', w.branch_id, w.id) && canAt('procurement.receive', w.branch_id, w.id));
  const [warehouseId, setWarehouseId] = useState(stores.find(w => w.type === 'raw_materials')?.id ?? stores[0]?.id ?? '');
  // goods arriving against a purchase order (077): its lines still to come, at the agreed prices
  const [newLines, setNewLines] = useState(fromOrder?.lines?.length ? fromOrder.lines : [{ materialId: '', quantity: '', unitId: '', price: '' }]);
  const recBranch = receipt?.branch_id ?? branchId;
  const pastOf = (b, materialId) => history[`${b}|${materialId}`] || [];
  // the latest purchase's price, when it was bought in the same unit
  const filledPrice = t => { const p = pastOf(recBranch, t.material_id); return p.length >= AUTOFILL_AFTER && p[0].unitId === t.entered_unit_id ? String(p[0].price) : ''; };
  const firstPast = mode === 'complete' ? receiptLines.map(t => pastOf(recBranch, t.material_id)).find(p => p.length >= AUTOFILL_AFTER) : null;
  const [prices, setPrices] = useState(Object.fromEntries(receiptLines.map(t => [t.id, priceOf[t.id] ?? (mode === 'complete' ? filledPrice(t) : '')])));

  const activeSuppliers = refs.suppliers.filter(s => s.status === 'active' || s.id === purchase?.supplier_id);
  // who supplied these materials before (purchase history at this branch) — offered first, never assumed for other materials
  const lineMaterials = (isNew ? newLines.map(l => l.materialId) : receiptLines.map(t => t.material_id)).filter(Boolean);
  const suppliedBefore = new Set(lineMaterials.flatMap(m => pastOf(recBranch, m).map(p => p.supplierId)).filter(Boolean));
  const [supplierId, setSupplierId] = useState(purchase?.supplier_id ?? receipt?.supplier_id ?? fromOrder?.supplierId ?? firstPast?.[0].supplierId ?? '');
  // received against a purchase order (077): the supplier's open orders at this branch
  const [orderId, setOrderId] = useState(purchase?.purchase_order_id ?? fromOrder?.orderId ?? '');
  const [openOrders, setOpenOrders] = useState([]);
  useEffect(() => {
    if (!supplierId) { setOpenOrders([]); return; }
    supabase.from('purchase_orders').select('id, po_no, order_date, branch_id, status').eq('supplier_id', supplierId).eq('status', 'open').order('order_date', { ascending: false })
      .then(({ data }) => setOpenOrders(data || []));
  }, [supplierId]);
  const [newSupplier, setNewSupplier] = useState('');
  const [invoice,   setInvoice]   = useState(purchase?.invoice_reference ?? receipt?.reference ?? '');
  const [transport, setTransport] = useState(purchase?.transport_charge ? String(purchase.transport_charge) : '');
  const [vatShown,  setVatShown]  = useState(purchase?.vat_amount != null);
  const [paid,      setPaid]      = useState(purchase ? String(purchase.amount_paid) : '');
  const [method,    setMethod]    = useState(purchase?.payment_method ?? firstPast?.[0].method ?? '');
  const [paidOn,    setPaidOn]    = useState(purchase?.paid_on ?? receipt?.movement_date ?? today);
  const [paidOnSet, setPaidOnSet] = useState(!!purchase?.paid_on);   // until set by hand, it follows the purchase date
  const [notes,     setNotes]     = useState(purchase?.notes ?? '');
  const [date,      setDate]      = useState(today);
  const [submitted, setSubmitted] = useState(false);
  const [voiding,   setVoiding]   = useState(false);
  const [deleting,  setDeleting]  = useState(false);
  const [voidReason, setVoidReason] = useState('');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  const wh = refs.warehouses.find(w => w.id === warehouseId);
  useEffect(() => { if (isNew && !paidOnSet) setPaidOn(date); }, [date, isNew, paidOnSet]);
  const vatRate = vatRateOf(isNew ? wh?.branch_id ?? branchId : receipt?.branch_id ?? purchase?.branch_id ?? branchId);
  // An earlier date is a correction (033/036): it needs stock-correction
  // rights at the store; non-admins' backdated purchases go to approval
  const canBackdate = !!wh && canAt('inventory.adjust', wh.branch_id, wh.id);
  const backdated = isNew && date < today;
  const needsApproval = backdated && !canManage('inventory.adjust');
  const usable = m => m.status === 'active' && (!m.branch_id || m.branch_id === (wh?.branch_id ?? branchId));

  // Lines with their amount as bought, and quantity in the stock unit for the per-unit cost
  const lines = isNew
    ? newLines.map((l, i) => {
        const item = refs.items[`m:${l.materialId}`];
        const factor = item?.units.find(u => u.id === l.unitId)?.factor;
        return { key: i, materialId: l.materialId, name: item?.name, qty: num(l.quantity), unitId: l.unitId,
          stockQty: num(l.quantity) != null && factor ? num(l.quantity) * factor : null, stockUnitId: item?.stockUnitId, price: num(l.price) };
      })
    : receiptLines.map(t => ({ key: t.id, txId: t.id, name: refs.items[`m:${t.material_id}`]?.name, qty: Number(t.entered_quantity), unitId: t.entered_unit_id,
        stockQty: Number(t.quantity), stockUnitId: t.stock_unit_id, price: num(prices[t.id]) }));
  const amount = l => (l.price != null && l.qty != null ? round2(l.price * l.qty) : null);
  const subtotal = lines.reduce((s, l) => s + (amount(l) ?? 0), 0);
  const vat = vatShown ? round2(subtotal * vatRate / (100 + vatRate)) : 0;   // included in the goods amount
  const total = subtotal + (num(transport) ?? 0);
  const vatFactor = vatShown && subtotal > 0 ? (subtotal - vat) / subtotal : 1;
  const landedPerUnit = l => (amount(l) != null && l.stockQty > 0 && subtotal > 0
    ? (amount(l) * vatFactor + (num(transport) ?? 0) * amount(l) / subtotal) / l.stockQty : null);


  async function save(e) {
    e.preventDefault();
    setError('');
    if (!supplierId && !newSupplier.trim()) { setError('Choose the supplier, or name a new one.'); return; }
    if (lines.some(l => l.price == null || !(l.price >= 0))) { setError('Enter the price of each material (zero or more).'); return; }
    if (isNew) {
      if (!warehouseId) { setError('Choose the store.'); return; }
      if (newLines.some(l => !l.materialId || !(num(l.quantity) > 0) || !l.unitId)) { setError('Each line needs a material, a quantity above zero and a unit.'); return; }
      if (new Set(newLines.map(l => l.materialId)).size !== newLines.length) { setError('A material appears twice — combine the lines.'); return; }
    }
    if (num(paid) != null && num(paid) > round2(total)) { setError('Amount paid is more than the total.'); return; }
    if (isNew && (!date || date > today)) { setError('Choose a date up to today.'); return; }
    const header = {
      ...(supplierId ? { supplier_id: supplierId } : { new_supplier_name: newSupplier.trim() }),
      invoice_reference: invoice.trim() || null, transport_charge: num(transport) ?? 0,
      vat_amount: vatShown ? vat : null, prices_include_vat: vatShown,
      amount_paid: num(paid) ?? 0, payment_method: method.trim() || null, paid_on: num(paid) > 0 ? paidOn || null : null,
      notes: notes.trim() || null,
    };
    setBusy(true);
    let res;
    if (mode === 'edit') {
      res = await supabase.rpc('update_purchase', { p_id: purchase.id, p: { ...header, lines: lines.map(l => ({ transaction_id: l.txId, unit_price: l.price })) } });
    } else if (mode === 'complete') {
      res = await supabase.rpc('record_purchase', { p: { ...header, movement_id: movementId, lines: lines.map(l => ({ transaction_id: l.txId, unit_price: l.price })) } });
    } else {
      const payload = { ...header,
        receipt: { type: 'receipt', warehouse_id: warehouseId, movement_date: date, reference: invoice.trim() || null,
                   lines: newLines.map(l => ({ material_id: l.materialId, quantity: num(l.quantity), unit_id: l.unitId })) },
        lines: newLines.map(l => ({ material_id: l.materialId, unit_price: num(l.price) })) };
      if (needsApproval) {
        const supplierLabel = supplierId ? refs.suppliers.find(s => s.id === supplierId)?.name : newSupplier.trim();
        const goods = lines.map(l => `${qtyText(l.qty)} ${refs.unitById[l.unitId]?.symbol ?? ''} ${l.name ?? ''}`).join(', ');
        res = await supabase.rpc('request_change', {
          p_kind: 'purchase', p_branch_id: null, p_payload: payload,
          p_summary: `Purchase dated ${date} at ${warehouseLabel(wh)}: ${goods} from ${supplierLabel} — ${money(round2(total))}`,
        });
        setBusy(false);
        if (res.error) { setError(dbErrorMessage(res.error, "We couldn't send this for approval. Nothing was recorded.")); return; }
        setSubmitted(true);
        return;
      }
      res = await supabase.rpc('record_purchase', { p: payload });
    }
    if (!res.error && (orderId || purchase?.purchase_order_id) && orderId !== (purchase?.purchase_order_id ?? '')) {
      const pid = mode === 'edit' ? purchase.id : res.data;
      if (pid) { const r2 = await supabase.rpc('set_purchase_order', { p_purchase: pid, p_order: orderId || null }); if (r2.error) res = r2; }
    }
    setBusy(false);
    if (res.error) { setError(dbErrorMessage(res.error, "We couldn't save the purchase. Nothing was recorded.")); return; }
    onSaved();
  }

  async function voidIt() {
    setError('');
    if (!voidReason.trim()) { setError('Give a reason.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('void_purchase', { p_id: purchase.id, p_reason: voidReason.trim() });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  if (submitted) {
    return (
      <Modal title="Record goods + purchase" onClose={onSaved}
        footer={<button type="button" className="btn btn-primary" onClick={onSaved}>Done</button>}>
        <p className="text-sm">Sent for an admin's approval. The goods and the purchase are recorded, dated {date}, once it is approved — follow it under <strong>Approvals</strong>.</p>
      </Modal>
    );
  }

  const setNewLine = (i, patch) => setNewLines(ls => ls.map((l, j) => {
    if (j !== i) return l;
    const next = { ...l, ...patch };
    if (patch.materialId !== undefined) {
      const item = refs.items[`m:${patch.materialId}`];
      const past = pastOf(wh?.branch_id ?? branchId, patch.materialId);
      if (past.length >= AUTOFILL_AFTER && item?.units.some(u => u.id === past[0].unitId)) {
        next.unitId = past[0].unitId;
        next.price = String(past[0].price);
      } else {
        next.unitId = item?.mainUnitId ?? item?.stockUnitId ?? '';   // its main unit (051), e.g. Pipa, Bag/s
      }
    }
    return next;
  }));
  // opened from a material's Intake: that material is on the first line
  useEffect(() => { if (isNew && materialId) pickMaterial(0, materialId); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  function pickMaterial(i, materialId) {
    setNewLine(i, { materialId });
    const past = pastOf(wh?.branch_id ?? branchId, materialId);
    if (past.length < AUTOFILL_AFTER) return;
    if (!supplierId && !newSupplier.trim() && past[0].supplierId) setSupplierId(past[0].supplierId);
    if (!method && past[0].method) setMethod(past[0].method);
  }

  // "From the last 2 purchases: …" under a line, once a material has been bought twice here
  const supplierName = id => refs.suppliers.find(s => s.id === id)?.name ?? '—';
  function pastHint(b, materialId) {
    const past = pastOf(b, materialId);
    if (past.length < AUTOFILL_AFTER) return null;
    const [a, z] = past;
    const one = p => `${p.date} · ${supplierName(p.supplierId)} · ${qtyText(p.qty)} ${refs.unitById[p.unitId]?.symbol ?? ''} at ${money(p.price)}`;
    if (a.opening) return <div className="text-xs text-muted purchase-hint">Price filled from the opening stock cost: {money(a.price)} per {refs.unitById[a.unitId]?.symbol ?? 'unit'} ({a.date}). Change it if this purchase is different.</div>;
    return (
      <div className="text-xs text-muted purchase-hint">
        Filled from the last {z ? '2 purchases' : 'purchase'}: {[a, z].filter(Boolean).map(one).join('; ')}.{z && a.price !== z.price && a.unitId === z.unitId ? ` The price changed from ${money(z.price)} to ${money(a.price)}.` : ''} Change anything that is different this time.
      </div>
    );
  }

  return (
    <Modal title={mode === 'edit' ? 'Purchase' : mode === 'complete' ? 'Add purchase details' : 'Record goods + purchase'} onClose={onClose} size="lg"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="purchase-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>
          {mode === 'edit' ? 'Save changes' : needsApproval ? 'Submit for approval' : 'Record purchase'}
        </button>
      </>}>
      <form id="purchase-form" className="modal-form" onSubmit={save}>
        {isNew ? (
          <>
            <div className="form-row">
              <div className="form-group">
                <label className="form-label" htmlFor="pu-store">Store receiving the goods</label>
                <select id="pu-store" className="form-input" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
                  {stores.map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
                </select>
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="pu-date">Date received</label>
                <input id="pu-date" type="date" className="form-input" max={today} value={date} disabled={!canBackdate}
                  onChange={e => setDate(e.target.value)} />
                <span className="form-hint">
                  {!canBackdate ? 'Today only — earlier dates need stock-adjustment permission (ask the branch manager).'
                    : needsApproval ? 'Earlier date: this goes to an admin for approval and is recorded once approved.'
                    : date < today ? 'Earlier date: recorded as of then.' : 'Today, or an earlier date if the goods came before.'}
                </span>
              </div>
            </div>
            <section>
              <h3 className="modal-section-title">Goods</h3>
              <div className="flex flex-col gap-8">
                {newLines.map((l, i) => {
                  const item = refs.items[`m:${l.materialId}`];
                  return (
                    <div key={i}>
                    <div className="ingredient-row">
                      <select className="form-input" aria-label="Material" value={l.materialId} onChange={e => pickMaterial(i, e.target.value)}>
                        <option value="" disabled>Material…</option>
                        {materials.filter(usable).map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
                      </select>
                      <NumberInput step="any" min="0" className="form-input" aria-label="Quantity" placeholder="Qty" value={l.quantity} onChange={e => setNewLine(i, { quantity: e.target.value })} />
                      <select className="form-input" aria-label="Unit" value={l.unitId} onChange={e => setNewLine(i, { unitId: e.target.value })}>
                        <option value="" disabled>Unit…</option>
                        {(item?.units || []).map(u => <option key={u.id} value={u.id}>{refs.unitById[u.id]?.symbol}</option>)}
                      </select>
                      <NumberInput step="any" min="0" className="form-input" aria-label="Price per unit" placeholder="Price / unit" value={l.price} onChange={e => setNewLine(i, { price: e.target.value })} />
                      <button type="button" className="icon-btn" aria-label="Remove line" disabled={newLines.length === 1} onClick={() => setNewLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={14} /></button>
                    </div>
                    {l.materialId && pastHint(wh?.branch_id ?? branchId, l.materialId)}
                    </div>
                  );
                })}
              </div>
              <button type="button" className="btn btn-ghost btn-sm mt-8" onClick={() => setNewLines(ls => [...ls, { materialId: '', quantity: '', unitId: '', price: '' }])}><Plus size={13} /> Add material</button>
            </section>
          </>
        ) : (
          <section>
            <h3 className="modal-section-title">Goods received {receipt?.movement_date ?? purchase?.purchase_date}</h3>
            <div className="flex flex-col gap-8">
              {lines.map(l => (
                <div key={l.key} className="form-row" style={{ alignItems: 'center' }}>
                  <span className="text-sm">{qtyText(l.qty)} {refs.unitById[l.unitId]?.symbol} {l.name}</span>
                  <NumberInput step="any" min="0" className="form-input" aria-label={`${l.name} price per ${refs.unitById[l.unitId]?.symbol}`}
                    placeholder={`Price per ${refs.unitById[l.unitId]?.symbol ?? 'unit'}`} value={prices[l.txId] ?? ''}
                    onChange={e => setPrices(p => ({ ...p, [l.txId]: e.target.value }))} />
                  {mode === 'complete' && <div style={{ flexBasis: '100%' }}>{pastHint(recBranch, receiptLines.find(t => t.id === l.txId)?.material_id)}</div>}
                </div>
              ))}
            </div>
          </section>
        )}

        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="pu-sup">Supplier</label>
            <select id="pu-sup" className="form-input" value={supplierId} onChange={e => setSupplierId(e.target.value)}>
              <option value="">{mode === 'edit' ? 'Choose…' : 'New supplier…'}</option>
              {suppliedBefore.size > 0 && <optgroup label="Supplied these before">{activeSuppliers.filter(s => suppliedBefore.has(s.id)).map(s => <option key={s.id} value={s.id}>{s.name}</option>)}</optgroup>}
              <optgroup label={suppliedBefore.size ? 'Other suppliers' : 'Suppliers'}>{activeSuppliers.filter(s => !suppliedBefore.has(s.id)).map(s => <option key={s.id} value={s.id}>{s.name}</option>)}</optgroup>
            </select>
            {!supplierId && mode !== 'edit' && (
              <input className="form-input mt-4" aria-label="New supplier name" placeholder="Supplier's name" value={newSupplier} onChange={e => setNewSupplier(e.target.value)} />
            )}
            {supplierId && (openOrders.length > 0 || orderId) && (
              <select className="form-input mt-4" aria-label="Against purchase order" value={orderId} onChange={e => setOrderId(e.target.value)}>
                <option value="">No purchase order</option>
                {openOrders.map(o => <option key={o.id} value={o.id}>Against PO #{o.po_no} · {o.order_date}</option>)}
              </select>
            )}
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="pu-inv">Supplier's invoice / receipt no.</label>
            <input id="pu-inv" className="form-input" placeholder="Optional" value={invoice} onChange={e => setInvoice(e.target.value)} />
          </div>
        </div>

        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="pu-transport">Transport / other charges</label>
            <NumberInput id="pu-transport" step="any" min="0" className="form-input" placeholder="0" value={transport} onChange={e => setTransport(e.target.value)} />
            <span className="form-hint">Added to the materials' cost.</span>
          </div>
          <div className="form-group">
            {/* a branch that is not VAT-registered (rate 0) has no VAT to tick */}
            {(vatRate > 0 || vatShown) && (
            <label className="text-sm flex items-center gap-8">
              <input type="checkbox" checked={vatShown} onChange={e => setVatShown(e.target.checked)} /> VAT ({vatRate}%) is included in the prices
            </label>
            )}
            {vatShown && (
              <div className="flex flex-col gap-4 mt-4">
                <div className="text-sm">VAT: <strong>{money(vat)}</strong> <span className="text-muted">= {money(round2(subtotal))} × {vatRate}/{100 + vatRate}</span></div>
                <span className="form-hint">Worked out from the goods amount. VAT is not part of the materials' cost.</span>
              </div>
            )}
          </div>
        </div>

        <div className="detail-list text-sm">
          <div>Goods: <strong>{money(round2(subtotal))}</strong>{num(transport) ? <> · transport {money(num(transport))}</> : null}{vatShown && vat ? <> · VAT {money(vat)} (included)</> : null}</div>
          <div>Total to pay: <strong>{money(round2(total))}</strong></div>
          {lines.some(l => landedPerUnit(l) != null) && (
            <div className="text-xs text-muted">Cost: {lines.filter(l => landedPerUnit(l) != null).map(l => `${l.name} ${money(round2(landedPerUnit(l)))} per ${refs.unitById[l.stockUnitId]?.symbol ?? 'unit'}`).join(' · ')}</div>
          )}
        </div>

        <section>
          <h3 className="modal-section-title">Payment</h3>
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="pu-paid">Amount paid</label>
              <div className="flex gap-8">
                <NumberInput id="pu-paid" step="any" min="0" className="form-input" placeholder="0 = not paid yet" value={paid} onChange={e => setPaid(e.target.value)} />
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setPaid(String(round2(total)))}>Paid in full</button>
              </div>
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="pu-method">How</label>
              <input id="pu-method" className="form-input" list="pu-methods" placeholder="e.g. Cash" value={method} onChange={e => setMethod(e.target.value)} />
              <datalist id="pu-methods">{METHODS.map(m => <option key={m} value={m} />)}</datalist>
            </div>
            {num(paid) > 0 && (
              <div className="form-group">
                <label className="form-label" htmlFor="pu-paidon">Paid on</label>
                <input id="pu-paidon" type="date" className="form-input" max={today} value={paidOn} onChange={e => { setPaidOn(e.target.value); setPaidOnSet(true); }} />
              </div>
            )}
          </div>
        </section>

        <div className="form-group">
          <label className="form-label" htmlFor="pu-notes">Notes</label>
          <input id="pu-notes" className="form-input" value={notes} onChange={e => setNotes(e.target.value)} />
        </div>

        {mode === 'edit' && (
          <section>
            <h3 className="modal-section-title">Entered wrongly?</h3>
            {voiding ? (
              <div className="confirm-box">
                <p className="text-sm">Voiding keeps it on record and puts the receipt back under "Waiting for details". The goods stay in stock — to undo them, reverse the receipt (that needs approval).</p>
                <input className="form-input" placeholder="Reason" aria-label="Reason for voiding" value={voidReason} onChange={e => setVoidReason(e.target.value)} />
                <div className="flex gap-8">
                  <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={voidIt}>Void purchase</button>
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(false)}>Keep it</button>
                </div>
              </div>
            ) : deleting ? (
              <DeletePurchase purchase={purchase} goods={goods} onCancel={() => setDeleting(false)} onDeleted={onSaved} />
            ) : (
              <div className="flex gap-8" style={{ flexWrap: 'wrap' }}>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(true)}>Void this purchase…</button>
                {canManage('system.manage') && (
                  <button type="button" className="btn btn-ghost btn-sm text-error" onClick={() => setDeleting(true)}>Delete this purchase…</button>
                )}
              </div>
            )}
          </section>
        )}
      </form>
    </Modal>
  );
}

/**
 * Technical admin only (040): delete a purchase entered with wrong
 * details. The receipt stays (back under "Waiting for details") unless the
 * goods are undone too, which reverses it. audit_log keeps every value.
 */
function DeletePurchase({ purchase, goods, onCancel, onDeleted }) {
  const [reason, setReason] = useState('');
  const [undo, setUndo] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function remove() {
    setError('');
    if (!reason.trim()) { setError('Give a reason.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('delete_purchase', { p_id: purchase.id, p_reason: reason.trim(), p_undo_receipt: undo });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't delete this purchase. Please try again.")); return; }
    onDeleted();
  }

  return (
    <div className="confirm-box">
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <p className="text-sm">Deleting removes this purchase{purchase.status === 'void' ? ' (void)' : ''} from the list for good — supplier, prices and payment. The audit log keeps a copy of every value.</p>
      <label className="text-sm flex items-center gap-8">
        <input type="checkbox" checked={undo} onChange={e => setUndo(e.target.checked)} />
        <span>Also undo the goods received{goods ? ` (${goods})` : ''} — they never arrived, or the quantity was wrong</span>
      </label>
      <p className="text-xs text-muted">{undo
        ? 'The receipt is reversed, dated as the original. This is refused if the stock has since been used.'
        : 'The goods stay in stock and the receipt goes back under "Waiting for details", to be completed again with the right details.'}</p>
      <input className="form-input" placeholder="Reason (required)" aria-label="Reason for deleting" value={reason} onChange={e => setReason(e.target.value)} />
      <div className="flex gap-8">
        <button type="button" className={`btn btn-danger-outline btn-sm${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={remove}>Delete purchase</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={onCancel}>Keep it</button>
      </div>
    </div>
  );
}
