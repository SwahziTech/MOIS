import { useEffect, useMemo, useState } from 'react';
import { ShoppingCart, Plus, Trash2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import { loadInventoryRefs, warehouseLabel, qtyText, orgToday } from '../lib/inventory';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';

const LOAD_ERROR = "We couldn't load purchases. Please try again.";
const PAYMENT_LABEL = { paid: 'Paid', part_paid: 'Part-paid', unpaid: 'Unpaid', void: 'Void' };
const PAYMENT_BADGE = { paid: 'badge-success', part_paid: 'badge-warning', unpaid: 'badge-neutral', void: 'badge-neutral' };
const METHODS = ['Cash', 'Mobile money', 'Bank transfer', 'Cheque'];
const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round2 = n => Math.round(n * 100) / 100;

/*
 * Purchases (migration 035): the money side of material receipts. The
 * storekeeper receives the goods (Stock → Receive); the secretary or branch
 * manager completes the purchase here — supplier, prices, transport, VAT,
 * payment — or records goods and purchase together. Costs feed each
 * branch's moving average cost per material.
 */
export default function Purchases() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const money = v => formatMoney(v, organization?.currency_code);
  const canRecordAt = id => !!id && canAt('procurement.receive', id, null);

  const [tab,       setTab]       = useState('waiting');
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
  const [editing, setEditing] = useState(null);     // { mode: 'complete'|'new'|'edit', receipt?, purchase? }

  async function load() {
    setError('');
    try {
      const [r, mat, pu, tot, aw] = await Promise.all([
        loadInventoryRefs(),
        supabase.from('materials').select('id, name, status, branch_id').order('name'),
        supabase.from('purchases').select(`id, branch_id, movement_id, supplier_id, purchase_date, invoice_reference, transport_charge,
          vat_amount, prices_include_vat, amount_paid, payment_method, paid_on, status, void_reason, notes, created_by,
          lines:purchase_lines(id, transaction_id, unit_price, line_amount)`).order('purchase_date', { ascending: false }).limit(300),
        supabase.from('purchase_totals').select('*'),
        supabase.from('receipts_awaiting_purchase').select('*').order('movement_date', { ascending: false }),
      ]);
      const err = mat.error || pu.error || tot.error || aw.error;
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
      const ids = [...new Set([...(aw.data || []).map(a => a.created_by), ...(pu.data || []).map(p => p.created_by)].filter(Boolean))];
      if (ids.length) {
        const { data: ppl } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
        setPeople(Object.fromEntries((ppl || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
      }
      setRefs(r);
      setMaterials(mat.data || []);
      setPurchases(pu.data || []);
      setTotals(Object.fromEntries((tot.data || []).map(t => [t.purchase_id, t])));
      setAwaiting(aw.data || []);
      setTxByMove(byMove);
    } catch (e) {
      console.error(e);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // Moving average cost per material at the picked branch
  useEffect(() => {
    if (tab !== 'costs' || !branchId || !materials.length) return;
    let live = true;
    Promise.all(materials.filter(m => m.status === 'active' && (!m.branch_id || m.branch_id === branchId)).map(async m => {
      const { data } = await supabase.rpc('material_average_cost', { p_branch_id: branchId, p_material_id: m.id });
      return { material: m, ...(data?.[0] || {}) };
    })).then(rows => { if (live) setCosts(rows); });
    return () => { live = false; };
  }, [tab, branchId, materials, purchases]);

  const supplierName = id => refs?.suppliers.find(s => s.id === id)?.name ?? '—';
  const waitingHere = awaiting.filter(a => inBranch(a.branch_id));
  const purchasesHere = purchases.filter(p => inBranch(p.branch_id));
  const owed = purchasesHere.filter(p => p.status === 'recorded').reduce((s, p) => s + Math.max(Number(totals[p.id]?.balance ?? 0), 0), 0);
  const whById = useMemo(() => Object.fromEntries((refs?.warehouses || []).map(w => [w.id, w])), [refs]);
  const describeLines = lines => (lines || []).filter(t => t.material_id)
    .map(t => `${qtyText(t.entered_quantity)} ${refs?.unitById[t.entered_unit_id]?.symbol ?? ''} ${refs?.items[`m:${t.material_id}`]?.name ?? ''}`).join(', ');

  return (
    <PageShell title="Purchases" subtitle="Inventory"
      actions={canRecordAt(branchId) && (
        <button type="button" className="btn btn-primary" disabled={!refs} onClick={() => setEditing({ mode: 'new' })}>
          <Plus size={14} /> Record goods + purchase
        </button>
      )}>
      <div className="flex items-center gap-8 mb-16" style={{ flexWrap: 'wrap' }}>
        <div className="filter-chips">
          <button type="button" className={`filter-chip${tab === 'waiting' ? ' is-on' : ''}`} onClick={() => setTab('waiting')}>Waiting for details ({waitingHere.length})</button>
          <button type="button" className={`filter-chip${tab === 'purchases' ? ' is-on' : ''}`} onClick={() => setTab('purchases')}>Purchases</button>
          <button type="button" className={`filter-chip${tab === 'costs' ? ' is-on' : ''}`} onClick={() => setTab('costs')}>Material costs</button>
        </div>
        {tab === 'purchases' && owed > 0 && <span className="text-sm text-muted" style={{ marginLeft: 'auto' }}>Still to pay: <strong>{money(round2(owed))}</strong></span>}
      </div>

      <div className="card">
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
                <thead><tr><th>Date</th><th>Supplier</th><th>Goods</th><th style={{ textAlign: 'right' }}>Total</th><th>Payment</th><th aria-label="Actions" /></tr></thead>
                <tbody>
                  {loading ? <SkeletonRow cols={6} /> : purchasesHere.length === 0 ? (
                    <tr><td colSpan={6}><EmptyState icon={ShoppingCart} title="No purchases yet" description="" /></td></tr>
                  ) : purchasesHere.map(p => {
                    const t = totals[p.id];
                    return (
                      <tr key={p.id} className={p.status === 'void' ? 'text-muted' : ''}>
                        <td>{p.purchase_date}{p.invoice_reference && <div className="text-xs text-muted">{p.invoice_reference}</div>}</td>
                        <td style={{ fontWeight: 500 }}>{supplierName(p.supplier_id)}</td>
                        <td className="text-sm">{describeLines(txByMove[p.movement_id])}</td>
                        <td style={{ textAlign: 'right' }}>{t ? money(t.total) : '—'}</td>
                        <td>
                          <span className={`badge ${PAYMENT_BADGE[t?.payment_status] ?? 'badge-neutral'}`}>{PAYMENT_LABEL[t?.payment_status] ?? '—'}</span>
                          {t?.payment_status === 'part_paid' && <div className="text-xs text-muted">{money(t.balance)} to pay</div>}
                          {p.status === 'void' && <div className="text-xs text-muted">{p.void_reason}</div>}
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          {p.status === 'recorded' && canRecordAt(p.branch_id) && (
                            <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing({ mode: 'edit', purchase: p })}>Open</button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}

            {tab === 'costs' && (!branchId ? (
              <EmptyState icon={ShoppingCart} title="Pick a branch" description="Material costs are per branch — pick one in the sidebar." />
            ) : (
              <table>
                <thead><tr><th>Material</th><th style={{ textAlign: 'right' }}>Average cost</th><th style={{ textAlign: 'right' }}>Last purchase</th><th>Costed stock</th></tr></thead>
                <tbody>
                  {costs.length === 0 ? <SkeletonRow cols={4} /> : costs.map(c => {
                    const unit = refs?.unitById[refs?.items[`m:${c.material.id}`]?.stockUnitId]?.symbol ?? '';
                    return (
                      <tr key={c.material.id}>
                        <td style={{ fontWeight: 500 }}>{c.material.name}</td>
                        <td style={{ textAlign: 'right' }}>{c.average_cost != null ? <>{money(round2(c.average_cost))} <span className="text-muted">/ {unit}</span></> : <span className="text-muted">no purchases yet</span>}</td>
                        <td style={{ textAlign: 'right' }}>{c.last_purchase_cost != null ? <>{money(round2(c.last_purchase_cost))} <span className="text-xs text-muted">{c.last_purchase_date}</span></> : <span className="text-muted">—</span>}</td>
                        <td className="text-sm text-muted">
                          {Number(c.costed_quantity) > 0 ? `${qtyText(c.costed_quantity)} ${unit}` : '—'}
                          {Number(c.uncosted_quantity) > 0 && <div className="text-xs">{qtyText(c.uncosted_quantity)} {unit} with no cost (before the first purchase)</div>}
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
      </div>

      {editing && refs && (
        <PurchaseModal {...editing} refs={refs} materials={materials} txByMove={txByMove} organization={organization}
          branchId={branchId} canAt={canAt}
          onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />
      )}
    </PageShell>
  );
}

function PurchaseModal({ mode, receipt, purchase, refs, materials, txByMove, organization, branchId, canAt, onClose, onSaved }) {
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
  const [newLines, setNewLines] = useState([{ materialId: '', quantity: '', unitId: '', price: '' }]);
  const [prices, setPrices] = useState(Object.fromEntries(receiptLines.map(t => [t.id, priceOf[t.id] ?? ''])));

  const activeSuppliers = refs.suppliers.filter(s => s.status === 'active' || s.id === purchase?.supplier_id);
  const [supplierId, setSupplierId] = useState(purchase?.supplier_id ?? receipt?.supplier_id ?? '');
  const [newSupplier, setNewSupplier] = useState('');
  const [invoice,   setInvoice]   = useState(purchase?.invoice_reference ?? receipt?.reference ?? '');
  const [transport, setTransport] = useState(purchase?.transport_charge ? String(purchase.transport_charge) : '');
  const [vatShown,  setVatShown]  = useState(purchase?.vat_amount != null);
  const [vatAmount, setVatAmount] = useState(purchase?.vat_amount != null ? String(purchase.vat_amount) : '');
  const [inclVat,   setInclVat]   = useState(purchase?.prices_include_vat ?? false);
  const [paid,      setPaid]      = useState(purchase ? String(purchase.amount_paid) : '');
  const [method,    setMethod]    = useState(purchase?.payment_method ?? '');
  const [paidOn,    setPaidOn]    = useState(purchase?.paid_on ?? today);
  const [notes,     setNotes]     = useState(purchase?.notes ?? '');
  const [voiding,   setVoiding]   = useState(false);
  const [voidReason, setVoidReason] = useState('');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  const wh = refs.warehouses.find(w => w.id === warehouseId);
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
  const vat = vatShown ? (num(vatAmount) ?? 0) : 0;
  const total = subtotal + (num(transport) ?? 0) + (vatShown && !inclVat ? vat : 0);
  const vatFactor = vatShown && inclVat && subtotal > 0 ? (subtotal - vat) / subtotal : 1;
  const landedPerUnit = l => (amount(l) != null && l.stockQty > 0 && subtotal > 0
    ? (amount(l) * vatFactor + (num(transport) ?? 0) * amount(l) / subtotal) / l.stockQty : null);

  function vatFromRate(rate) {
    const r = num(rate);
    if (r == null || !(r >= 0)) return;
    setVatAmount(String(round2(inclVat ? subtotal * r / (100 + r) : subtotal * r / 100)));
  }

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
    const header = {
      ...(supplierId ? { supplier_id: supplierId } : { new_supplier_name: newSupplier.trim() }),
      invoice_reference: invoice.trim() || null, transport_charge: num(transport) ?? 0,
      vat_amount: vatShown ? num(vatAmount) : null, prices_include_vat: vatShown && inclVat,
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
      res = await supabase.rpc('record_purchase', { p: { ...header,
        receipt: { type: 'receipt', warehouse_id: warehouseId, reference: invoice.trim() || null,
                   lines: newLines.map(l => ({ material_id: l.materialId, quantity: num(l.quantity), unit_id: l.unitId })) },
        lines: newLines.map(l => ({ material_id: l.materialId, unit_price: num(l.price) })) } });
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

  const setNewLine = (i, patch) => setNewLines(ls => ls.map((l, j) => {
    if (j !== i) return l;
    const next = { ...l, ...patch };
    if (patch.materialId !== undefined) next.unitId = refs.items[`m:${patch.materialId}`]?.stockUnitId ?? '';
    return next;
  }));

  return (
    <Modal title={mode === 'edit' ? 'Purchase' : mode === 'complete' ? 'Add purchase details' : 'Record goods + purchase'} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="purchase-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>
          {mode === 'edit' ? 'Save changes' : 'Record purchase'}
        </button>
      </>}>
      <form id="purchase-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
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
                <span className="form-label">Date</span>
                <p className="text-sm">{today} <span className="text-xs text-muted">— for an earlier date, receive the goods under Stock (it needs approval), then add the purchase here.</span></p>
              </div>
            </div>
            <section>
              <h3 className="modal-section-title">Goods</h3>
              <div className="flex flex-col gap-8">
                {newLines.map((l, i) => {
                  const item = refs.items[`m:${l.materialId}`];
                  return (
                    <div key={i} className="ingredient-row">
                      <select className="form-input" aria-label="Material" value={l.materialId} onChange={e => setNewLine(i, { materialId: e.target.value })}>
                        <option value="" disabled>Material…</option>
                        {materials.filter(usable).map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
                      </select>
                      <input type="number" step="any" min="0" className="form-input" aria-label="Quantity" placeholder="Qty" value={l.quantity} onChange={e => setNewLine(i, { quantity: e.target.value })} />
                      <select className="form-input" aria-label="Unit" value={l.unitId} onChange={e => setNewLine(i, { unitId: e.target.value })}>
                        <option value="" disabled>Unit…</option>
                        {(item?.units || []).map(u => <option key={u.id} value={u.id}>{refs.unitById[u.id]?.symbol}</option>)}
                      </select>
                      <input type="number" step="any" min="0" className="form-input" aria-label="Price per unit" placeholder="Price / unit" value={l.price} onChange={e => setNewLine(i, { price: e.target.value })} />
                      <button type="button" className="icon-btn" aria-label="Remove line" disabled={newLines.length === 1} onClick={() => setNewLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={14} /></button>
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
                  <input type="number" step="any" min="0" className="form-input" aria-label={`${l.name} price per ${refs.unitById[l.unitId]?.symbol}`}
                    placeholder={`Price per ${refs.unitById[l.unitId]?.symbol ?? 'unit'}`} value={prices[l.txId] ?? ''}
                    onChange={e => setPrices(p => ({ ...p, [l.txId]: e.target.value }))} />
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
              {activeSuppliers.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
            {!supplierId && mode !== 'edit' && (
              <input className="form-input mt-4" aria-label="New supplier name" placeholder="Supplier's name" value={newSupplier} onChange={e => setNewSupplier(e.target.value)} />
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
            <input id="pu-transport" type="number" step="any" min="0" className="form-input" placeholder="0" value={transport} onChange={e => setTransport(e.target.value)} />
            <span className="form-hint">Added to the materials' cost.</span>
          </div>
          <div className="form-group">
            <label className="text-sm flex items-center gap-8">
              <input type="checkbox" checked={vatShown} onChange={e => setVatShown(e.target.checked)} /> The receipt shows VAT separately
            </label>
            {vatShown && (
              <div className="flex flex-col gap-4 mt-4">
                <div className="flex gap-8">
                  <input type="number" step="any" min="0" className="form-input" aria-label="VAT amount" placeholder="VAT amount" value={vatAmount} onChange={e => setVatAmount(e.target.value)} />
                  <input type="number" step="any" min="0" className="form-input" style={{ width: 110 }} aria-label="or VAT rate %" placeholder="or rate %" onBlur={e => vatFromRate(e.target.value)} />
                </div>
                <label className="text-xs flex items-center gap-4">
                  <input type="checkbox" checked={inclVat} onChange={e => setInclVat(e.target.checked)} /> The prices above already include this VAT
                </label>
                <span className="form-hint">VAT is not part of the materials' cost.</span>
              </div>
            )}
          </div>
        </div>

        <div className="detail-list text-sm">
          <div>Goods: <strong>{money(round2(subtotal))}</strong>{num(transport) ? <> · transport {money(num(transport))}</> : null}{vatShown && vat ? <> · VAT {money(vat)}{inclVat ? ' (included)' : ''}</> : null}</div>
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
                <input id="pu-paid" type="number" step="any" min="0" className="form-input" placeholder="0 = not paid yet" value={paid} onChange={e => setPaid(e.target.value)} />
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
                <input id="pu-paidon" type="date" className="form-input" max={today} value={paidOn} onChange={e => setPaidOn(e.target.value)} />
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
            ) : (
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(true)}>Void this purchase…</button>
            )}
          </section>
        )}
      </form>
    </Modal>
  );
}
