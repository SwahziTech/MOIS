import { useEffect, useMemo, useState } from 'react';
import { Receipt, Plus, Trash2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import { loadInventoryRefs, qtyText, orgToday } from '../lib/inventory';
import { categoryTools, productOrder } from '../lib/categories';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';
import ProductPicker from '../components/production/ProductPicker';

const LOAD_ERROR = "We couldn't load sales. Please try again.";
const STAGES = { quotation: 'Quotation', order: 'Order', invoice: 'Invoice', cancelled: 'Cancelled' };
const STAGE_BADGE = { quotation: 'badge-neutral', order: 'badge-accent', invoice: 'badge-success', cancelled: 'badge-neutral' };
const METHODS = { cash: 'Cash', mobile_money: 'Mobile money', bank: 'Bank' };
const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const r2 = n => Math.round(n * 100) / 100;

/*
 * Sales (1e, migration 064; SwahziTech 2026-10-25): one document moving
 * Quotation → Order → Invoice (or cancelled). Prices come from the branch's
 * price list per m² or piece (as the product is counted), VAT at the price's
 * own rate; all figures are worked out in the database — the screen only
 * previews. Managers may change a price, with a reason. Payments by cash,
 * mobile money or bank, in parts. Goods leave on delivery (stage 2), up to
 * what has been paid. Newest on top.
 */
export default function Sales() {
  const { organization, canAt } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [refs, setRefs] = useState(null);
  const [sales, setSales] = useState(null);
  const [customers, setCustomers] = useState([]);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [stage, setStage] = useState('');
  const [editing, setEditing] = useState(null);   // a sale (or {} for new)
  const [viewing, setViewing] = useState(null);   // a sale id

  async function load() {
    setError('');
    try {
      const [r, s, c] = await Promise.all([
        refs ? Promise.resolve(refs) : loadInventoryRefs(),
        (async () => {
          const q = cols => supabase.from('sales').select(cols).order('sale_date', { ascending: false }).order('sale_no', { ascending: false }).limit(500);
          const withDeliveries = await q('*, lines:sale_lines(*), payments:sale_payments(*), deliveries:sale_deliveries(*, lines:sale_delivery_lines(*))');
          return withDeliveries.error ? q('*, lines:sale_lines(*), payments:sale_payments(*)') : withDeliveries;   // before 065
        })(),
        supabase.from('customers').select('*').order('name'),
      ]);
      if (s.error) throw s.error;
      setRefs(r);
      setSales(s.data || []);
      setCustomers(c.data || []);
    } catch (e) {
      console.error(e);
      setError(LOAD_ERROR);
    }
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const buyerOf = s => customers.find(c => c.id === s.customer_id)?.name ?? s.walk_in_name ?? 'Walk-in';
  const paidOf = s => (s.payments || []).reduce((t, p) => t + Number(p.amount), 0);
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (sales || []).filter(s => inBranch(s.branch_id) && (!stage || s.stage === stage)
      && (!q || `${s.sale_no} ${buyerOf(s)} ${s.walk_in_phone ?? ''} ${s.efd_receipt_no ?? ''}`.toLowerCase().includes(q)));
  }, [sales, search, stage, branchId, customers]); // eslint-disable-line react-hooks/exhaustive-deps

  const canSell = branchId && canAt('sales.create', branchId, null);
  const open = (sales || []).find(s => s.id === viewing);

  return (
    <PageShell title="Sales" subtitle="Sales & Costing"
      description={branchId ? `Quotations, orders and invoices at ${branchName}, with their payments.` : 'Quotations, orders and invoices at every branch.'}
      primaryAction={canSell && <button type="button" className="btn btn-primary" onClick={() => setEditing({})}><Plus size={15} /> New sale</button>}>
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <>
          <ListToolbar id="sales-search" search={search} onSearch={setSearch} placeholder="Search number, customer, phone or EFD receipt…" />
          <ChipRow value={stage} onChange={setStage} items={Object.entries(STAGES).map(([id, label]) => ({ id, label }))} />
          <section className="sk">
            <div className="sk-head"><span>Sales ({shown.length})</span><span className="pl-help">newest first</span></div>
            {sales === null ? Array.from({ length: 4 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
            : shown.length === 0 ? <div className="card"><EmptyState icon={Receipt} title="No sales here yet" description={canSell ? 'Start with New sale: a quotation that becomes an order and an invoice.' : 'Sales recorded at this branch appear here.'} /></div>
            : shown.map(s => {
              const paid = paidOf(s);
              return (
                <div key={s.id} className="sk-card lk-card" onClick={() => setViewing(s.id)} title="Open this sale">
                  <div className="sk-name">
                    <strong>{buyerOf(s)}</strong>
                    <span className="pl-help">#{s.sale_no} · {s.sale_date}{s.efd_receipt_no ? ` · EFD ${s.efd_receipt_no}` : ''}</span>
                  </div>
                  <div className="sk-total">
                    <span><strong>{money(Number(s.total))}</strong></span>
                    <span className="sk-sub">{(s.lines || []).length} line{(s.lines || []).length === 1 ? '' : 's'} · with VAT</span>
                  </div>
                  <div className="co-details">
                    <span><span className={`badge ${STAGE_BADGE[s.stage]}`}>{STAGES[s.stage]}</span></span>
                    {s.stage !== 'cancelled' && s.stage !== 'quotation' && (
                      <span>paid <strong>{money(paid)}</strong>{Number(s.total) - paid > 0.004 ? <span className="co-est"> {money(r2(Number(s.total) - paid))} owed</span> : <span className="pl-help"> · paid in full</span>}</span>
                    )}
                    {s.stage === 'cancelled' && <span className="pl-help">{s.cancel_reason}</span>}
                    {(s.deliveries || []).length > 0 && <span className="pl-help">delivered {money((s.deliveries || []).reduce((t, d) => t + Number(d.value), 0))}</span>}
                  </div>
                </div>
              );
            })}
          </section>
        </>
      )}

      {editing && refs && (
        <SaleEditor sale={editing.id ? editing : null} branchId={editing.branch_id ?? branchId} refs={refs} customers={customers} money={money} today={today}
          canDiscount={canAt('sales.discount', editing.branch_id ?? branchId, null)}
          onClose={() => setEditing(null)} onSaved={async id => { setEditing(null); await load(); setViewing(id); }} />
      )}
      {open && refs && !editing && (
        <SaleView sale={open} refs={refs} buyer={buyerOf(open)} customer={customers.find(c => c.id === open.customer_id)} money={money} today={today} canAt={canAt}
          onEdit={() => setEditing(open)} onClose={() => setViewing(null)} onChanged={load} />
      )}
    </PageShell>
  );
}

/** A quotation or order: buyer, lines priced from the price list, a preview of the totals */
function SaleEditor({ sale, branchId, refs, customers, money, today, canDiscount, onClose, onSaved }) {
  const { organization } = useAuth();
  const [buyer, setBuyer] = useState(sale?.customer_id ? 'customer' : 'walkin');
  const [customerId, setCustomerId] = useState(sale?.customer_id ?? '');
  const [walkName, setWalkName] = useState(sale?.walk_in_name ?? '');
  const [walkPhone, setWalkPhone] = useState(sale?.walk_in_phone ?? '');
  const [newCust, setNewCust] = useState(null);   // { name, phone, tin } while adding one
  const [date, setDate] = useState(sale?.sale_date ?? today);
  const [validUntil, setValidUntil] = useState(sale?.valid_until ?? '');
  const [notes, setNotes] = useState(sale?.notes ?? '');
  const [lines, setLines] = useState(() => (sale?.lines || []).sort((a, b) => a.line_no - b.line_no).map(l => ({
    productId: l.product_id, colorId: l.color_id ?? '', quantity: String(+l.quantity),
    price: Number(l.price) !== Number(l.list_price) ? String(r2(Number(l.price) * (1 + Number(l.vat_rate) / 100))) : '', reason: l.discount_reason ?? '' })));
  const [prices, setPrices] = useState({});        // `${product}|${colour}` → { ex, rate, source }
  const [avail, setAvail] = useState({});          // `${product}|${colour}` → available
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const cats = useMemo(() => categoryTools(refs.categoryRows || []), [refs]);
  const carried = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .sort(productOrder(cats)), [refs, branchId, cats]);
  const unitOf = id => refs.unitById[refs.items[`p:${id}`]?.stockUnitId]?.symbol ?? '';
  const per = id => (unitOf(id).toUpperCase() === 'SQM' ? 'm²' : 'pc');
  const key = l => `${l.productId}|${l.colorId || ''}`;

  useEffect(() => {
    supabase.rpc('sales_availability', { p_branch_id: branchId }).then(({ data }) =>
      setAvail(Object.fromEntries((data || []).map(x => [`${x.product_id}|${x.color_id ?? ''}`, Number(x.available)]))));
  }, [branchId]);
  // the price list's price (without VAT) and its VAT rate for each product and colour on the sale
  useEffect(() => {
    for (const l of lines) {
      const k = key(l);
      if (!l.productId || prices[k] !== undefined) continue;
      const it = refs.items[`p:${l.productId}`];
      if (it?.colorIds?.length && !l.colorId) continue;
      setPrices(p => ({ ...p, [k]: null }));
      Promise.all([
        supabase.rpc('product_price_ex_vat', { p_branch_id: branchId, p_product_id: l.productId, p_color_id: l.colorId || null }),
        supabase.rpc('product_price_vat_rate', { p_branch_id: branchId, p_product_id: l.productId, p_color_id: l.colorId || null }),
      ]).then(([a, b]) => { const row = Array.isArray(a.data) ? a.data[0] : a.data; return setPrices(p => ({ ...p, [k]: { ex: row?.price ?? null, source: row?.source, rate: Number(b.data ?? 0) } })); });
    }
  }, [lines]); // eslint-disable-line react-hooks/exhaustive-deps

  // preview — the database works out the real figures the same way: unit price with VAT, line total, VAT inside it
  const preview = l => {
    const pr = prices[key(l)];
    if (!pr) return null;
    const listInc = pr.ex != null ? r2(pr.ex * (1 + pr.rate / 100)) : null;
    const inc = num(l.price) ?? listInc;
    const q = num(l.quantity) ?? 0;
    if (inc == null) return { listInc, inc: null, total: null };
    const total = r2(q * inc);
    return { listInc, inc, total, ex: r2(total / (1 + pr.rate / 100)), rate: pr.rate };
  };
  const totals = lines.reduce((t, l) => { const p = preview(l); if (p?.total != null) { t.total += p.total; t.ex += p.ex; } return t; }, { total: 0, ex: 0 });
  const set = (i, patch) => setLines(ls => ls.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  async function save() {
    setError('');
    if (!lines.length) { setError('Add at least one product.'); return; }
    let cust = buyer === 'customer' ? customerId : null;
    if (buyer === 'customer' && newCust) {
      if (!newCust.name.trim()) { setError('Enter the new customer\'s name.'); return; }
      setBusy(true);
      const { data, error: err } = await supabase.from('customers').insert({ organization_id: organization.id, branch_id: branchId,
        name: newCust.name.trim(), phone: newCust.phone.trim() || null, tin: newCust.tin.trim() || null }).select('id').single();
      setBusy(false);
      if (err) { setError(dbErrorMessage(err)); return; }
      cust = data.id;
    }
    if (buyer === 'customer' && !cust) { setError('Choose the customer, or sell to a walk-in buyer.'); return; }
    const payload = {
      id: sale?.id, branch_id: branchId, sale_date: date, valid_until: validUntil || null, notes,
      ...(cust ? { customer_id: cust } : { walk_in_name: walkName, walk_in_phone: walkPhone }),
      lines: lines.map(l => {
        const pr = prices[key(l)];
        const inc = num(l.price);
        return { product_id: l.productId, color_id: l.colorId || null, quantity: num(l.quantity),
          ...(inc != null && pr ? { price: inc / (1 + pr.rate / 100), discount_reason: l.reason } : {}) };
      }),
    };
    setBusy(true);
    const { data, error: err } = await supabase.rpc('save_sale', { p: payload });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save this sale. Please try again.")); return; }
    onSaved(data);
  }

  return (
    <Modal title={sale ? `${STAGES[sale.stage]} #${sale.sale_no}` : 'New sale'} onClose={onClose} size="xl"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>{sale ? 'Save' : 'Save quotation'}</button>
      </>}>
      <div className="modal-form">
        <div className="flex items-center gap-8" role="group" aria-label="Buyer">
          <button type="button" className={`filter-chip${buyer === 'walkin' ? ' is-on' : ''}`} onClick={() => setBuyer('walkin')}>Walk-in buyer</button>
          <button type="button" className={`filter-chip${buyer === 'customer' ? ' is-on' : ''}`} onClick={() => setBuyer('customer')}>Customer</button>
        </div>
        {buyer === 'walkin' ? (
          <div className="form-row">
            <label className="pe-field"><span>Name (optional)</span><input className="form-input" value={walkName} onChange={e => setWalkName(e.target.value)} /></label>
            <label className="pe-field"><span>Phone (optional)</span><input className="form-input" inputMode="tel" value={walkPhone} onChange={e => setWalkPhone(e.target.value)} /></label>
          </div>
        ) : newCust ? (
          <div className="form-row">
            <label className="pe-field"><span>New customer</span><input className="form-input" autoFocus value={newCust.name} onChange={e => setNewCust({ ...newCust, name: e.target.value })} /></label>
            <label className="pe-field"><span>Phone</span><input className="form-input" inputMode="tel" value={newCust.phone} onChange={e => setNewCust({ ...newCust, phone: e.target.value })} /></label>
            <label className="pe-field"><span>TIN (optional)</span><input className="form-input" value={newCust.tin} onChange={e => setNewCust({ ...newCust, tin: e.target.value })} /></label>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setNewCust(null)}>Pick existing</button>
          </div>
        ) : (
          <div className="form-row">
            <label className="pe-field"><span>Customer</span>
              <select className="form-input" value={customerId} onChange={e => setCustomerId(e.target.value)}>
                <option value="">Choose…</option>
                {customers.filter(c => c.status === 'active' || c.id === customerId).map(c => <option key={c.id} value={c.id}>{c.name}{c.phone ? ` · ${c.phone}` : ''}</option>)}
              </select></label>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setNewCust({ name: '', phone: '', tin: '' })}><Plus size={13} /> New customer</button>
          </div>
        )}
        <div className="form-row">
          <label className="pe-field"><span>Date</span><input type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value)} /></label>
          {(!sale || sale.stage === 'quotation') && <label className="pe-field"><span>Quotation valid until (optional)</span><input type="date" className="form-input" min={date} value={validUntil} onChange={e => setValidUntil(e.target.value)} /></label>}
        </div>

        <table className="rd-table sl-table">
          <thead><tr><th>Product</th><th>Colour</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Price with VAT</th><th style={{ textAlign: 'right' }}>Total</th><th /></tr></thead>
          <tbody>
            {lines.map((l, i) => {
              const it = refs.items[`p:${l.productId}`];
              const p = preview(l);
              const av = avail[key(l)];
              const changed = num(l.price) != null && p?.listInc != null && num(l.price) !== p.listInc;
              return (
                <tr key={i}>
                  <td><strong>{it?.name ?? '—'}</strong><div className="pl-help">{it?.category}</div></td>
                  <td>{it?.colorIds?.length ? (
                    <select className="form-input" value={l.colorId} onChange={e => set(i, { colorId: e.target.value, price: '', reason: '' })}>
                      <option value="">Colour…</option>
                      {it.colorIds.map(id => <option key={id} value={id}>{refs.colorById[id]?.name}</option>)}
                    </select>) : <span className="pl-help">—</span>}</td>
                  <td style={{ textAlign: 'right' }}>
                    <span className="flex items-center gap-4" style={{ justifyContent: 'flex-end' }}>
                      <NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} value={l.quantity} onChange={e => set(i, { quantity: e.target.value })} /> {per(l.productId)}
                    </span>
                    {av !== undefined && <div className={`pl-help${av < (num(l.quantity) ?? 0) ? ' text-warning' : ''}`}>{qtyText(r2(av))} {unitOf(l.productId)} available</div>}
                  </td>
                  <td style={{ textAlign: 'right' }}>
                    {p === null ? <span className="pl-help">{it?.colorIds?.length && !l.colorId ? 'pick a colour' : '…'}</span>
                      : canDiscount ? (<>
                        <NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} placeholder={p.listInc != null ? String(p.listInc) : 'No price'} value={l.price} onChange={e => set(i, { price: e.target.value })} />
                        <div className="pl-help">{p.listInc != null ? `list ${money(p.listInc)} /${per(l.productId)}` : 'no list price'}{p.rate === 0 ? ' · no VAT' : ''}</div>
                        {changed && <input className="form-input" placeholder="Reason for the price (required)" value={l.reason} onChange={e => set(i, { reason: e.target.value })} />}
                      </>) : (p.listInc != null
                        ? <><strong>{money(p.listInc)}</strong> <span className="pl-help">/{per(l.productId)}{p.rate === 0 ? ' · no VAT' : ''}</span></>
                        : <span className="text-warning text-xs">No price — set it in Pricing</span>)}
                  </td>
                  <td style={{ textAlign: 'right' }}>{p?.total != null ? <strong>{money(p.total)}</strong> : '—'}</td>
                  <td><button type="button" className="icon-btn" aria-label="Remove line" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={14} /></button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <div className="flex items-center gap-8">
          <button type="button" className="btn btn-outline btn-sm" onClick={() => setPicking(true)}><Plus size={13} /> Add product</button>
          <span style={{ marginLeft: 'auto' }} className="sl-totals">
            <span className="pl-help">without VAT {money(r2(totals.ex))} · VAT {money(r2(totals.total - totals.ex))}</span>
            <strong>Total {money(r2(totals.total))}</strong>
          </span>
        </div>
        <label className="pe-field"><span>Notes (optional)</span><input className="form-input" value={notes} onChange={e => setNotes(e.target.value)} /></label>
      </div>
      {picking && (
        <ProductPicker title="Add a product" items={carried} cats={cats} onClose={() => setPicking(false)}
          onPick={id => { setPicking(false); setLines(ls => [...ls, { productId: id, colorId: '', quantity: '', price: '', reason: '' }]); }} />
      )}
    </Modal>
  );
}

/** One sale: its lines and totals, payments, and what can be done next */
function SaleView({ sale, refs, buyer, customer, money, today, canAt, onEdit, onClose, onChanged }) {
  const [paying, setPaying] = useState(false);
  const [pay, setPay] = useState({ amount: '', method: 'cash', reference: '', paid_on: today });
  const [efd, setEfd] = useState(sale.efd_receipt_no ?? '');
  const [askEfd, setAskEfd] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [handing, setHanding] = useState(false);   // a delivery or collection being recorded (065)
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const br = sale.branch_id;
  const paid = (sale.payments || []).reduce((t, p) => t + Number(p.amount), 0);
  const owed = r2(Number(sale.total) - paid);
  const unitOf = id => refs.unitById[refs.items[`p:${id}`]?.stockUnitId]?.symbol ?? '';
  const per = id => (unitOf(id).toUpperCase() === 'SQM' ? 'm²' : 'pc');
  const editable = ['quotation', 'order'].includes(sale.stage) && canAt('sales.create', br, null) && !(sale.deliveries || []).length;
  // deliveries (065): what has left, its cost, and the margin on it (without VAT)
  const deliveries = [...(sale.deliveries || [])].sort((a, b) => b.delivery_no - a.delivery_no);
  const given = deliveries.reduce((t, d) => t + Number(d.value), 0);
  const doneOf = lineId => deliveries.reduce((t, d) => t + (d.lines || []).filter(x => x.sale_line_id === lineId).reduce((u, x) => u + Number(x.quantity), 0), 0);
  const lineById = Object.fromEntries((sale.lines || []).map(l => [l.id, l]));
  const exOf = x => Number(x.value) / (1 + Number(lineById[x.sale_line_id]?.vat_rate ?? 0) / 100);
  const delivered = deliveries.flatMap(d => d.lines || []).reduce((t, x) => ({ ex: t.ex + exOf(x), cost: t.cost + Number(x.cost ?? 0), est: t.est + Number(x.estimated_cost ?? 0), unknown: t.unknown || x.cost == null }), { ex: 0, cost: 0, est: 0, unknown: false });
  const canHand = ['order', 'invoice'].includes(sale.stage) && (canAt('sales.create', br, null) || canAt('inventory.issue', br, null))
    && (sale.lines || []).some(l => Number(l.quantity) - doneOf(l.id) > 1e-9);

  async function run(fn) {
    setError(''); setBusy(true);
    const { error: err } = await fn();
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return false; }
    await onChanged();
    return true;
  }
  const toStage = (stage, p = {}) => run(() => supabase.rpc('set_sale_stage', { p_sale: sale.id, p_stage: stage, p }));

  return (
    <Modal title={`${STAGES[sale.stage]} #${sale.sale_no} — ${buyer}`} onClose={onClose} size="xl"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {editable && <button type="button" className="btn btn-outline" onClick={onEdit}>Edit</button>}
        {sale.stage !== 'cancelled' && paid === 0 && canAt('sales.create', br, null) && (sale.stage !== 'invoice' || canAt('sales.discount', br, null)) &&
          <button type="button" className="btn btn-ghost" onClick={() => setCancelling(true)}>Cancel sale</button>}
        {sale.stage === 'quotation' && canAt('sales.create', br, null) && <button type="button" className="btn btn-outline" disabled={busy} onClick={() => toStage('order')}>Confirm order</button>}
        {['quotation', 'order'].includes(sale.stage) && canAt('invoices.create', br, null) && <button type="button" className="btn btn-primary" disabled={busy} onClick={() => setAskEfd(true)}>Invoice</button>}
        {canHand && <button type="button" className="btn btn-outline" onClick={() => setHanding(true)}>Deliver / collect</button>}
        {['order', 'invoice'].includes(sale.stage) && owed > 0 && canAt('payments.record', br, null) && <button type="button" className="btn btn-primary" onClick={() => { setPay(p => ({ ...p, amount: String(owed) })); setPaying(true); }}>Record payment</button>}
      </>}>
      <div className="modal-form">
        <p className="text-sm text-muted">
          <span className={`badge ${STAGE_BADGE[sale.stage]}`}>{STAGES[sale.stage]}</span> {sale.sale_date}
          {customer ? ` · ${customer.phone ?? ''}${customer.tin ? ` · TIN ${customer.tin}` : ''}` : sale.walk_in_phone ? ` · ${sale.walk_in_phone}` : ''}
          {sale.valid_until && sale.stage === 'quotation' ? ` · valid until ${sale.valid_until}` : ''}
          {sale.invoiced_on ? ` · invoiced ${sale.invoiced_on}` : ''}{sale.efd_receipt_no ? ` · EFD ${sale.efd_receipt_no}` : ''}
          {sale.stage === 'cancelled' ? ` · cancelled (was ${STAGES[sale.cancelled_from]}): ${sale.cancel_reason}` : ''}
        </p>
        <table className="rd-table">
          <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Price with VAT</th><th style={{ textAlign: 'right' }}>Without VAT</th><th style={{ textAlign: 'right' }}>VAT</th><th style={{ textAlign: 'right' }}>Total</th></tr></thead>
          <tbody>
            {[...(sale.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => {
              const it = refs.items[`p:${l.product_id}`];
              const inc = r2(Number(l.price) * (1 + Number(l.vat_rate) / 100));
              return (
                <tr key={l.id}>
                  <td><strong>{it?.name}{l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}</strong><div className="pl-help">{it?.category}</div>
                    {l.discount_reason && <div className="pl-help">list {money(r2(Number(l.list_price) * (1 + Number(l.vat_rate) / 100)))} · {l.discount_reason}</div>}</td>
                  <td style={{ textAlign: 'right' }}>{qtyText(Number(l.quantity))} {per(l.product_id)}</td>
                  <td style={{ textAlign: 'right' }}>{money(inc)}{Number(l.vat_rate) === 0 && <div className="pl-help">no VAT</div>}</td>
                  <td style={{ textAlign: 'right' }}>{money(Number(l.amount))}</td>
                  <td style={{ textAlign: 'right' }}>{money(Number(l.vat))}</td>
                  <td style={{ textAlign: 'right' }}><strong>{money(Number(l.total))}</strong></td>
                </tr>
              );
            })}
            <tr><td colSpan={3} style={{ textAlign: 'right' }}><strong>Totals</strong></td><td style={{ textAlign: 'right' }}>{money(Number(sale.subtotal))}</td><td style={{ textAlign: 'right' }}>{money(Number(sale.vat))}</td><td style={{ textAlign: 'right' }}><strong>{money(Number(sale.total))}</strong></td></tr>
          </tbody>
        </table>

        {sale.stage !== 'quotation' && sale.stage !== 'cancelled' && (
          <section>
            <h3 className="modal-section-title">Payments · paid {money(paid)}{owed > 0 ? ` · ${money(owed)} owed` : ' · paid in full'}</h3>
            {(sale.payments || []).length === 0 ? <p className="pl-help">No payment yet.</p> : (
              <table className="rd-table"><tbody>
                {[...sale.payments].sort((a, b) => (b.paid_on.localeCompare(a.paid_on) || b.created_at.localeCompare(a.created_at))).map(p => (
                  <tr key={p.id}><td>{p.paid_on}</td><td>{METHODS[p.method]}{p.reference ? ` · ${p.reference}` : ''}</td><td style={{ textAlign: 'right' }}><strong>{money(Number(p.amount))}</strong></td></tr>
                ))}
              </tbody></table>
            )}
            <p className="pl-help">Goods leave up to the value paid: {money(r2(Math.max(paid - given, 0)))} can leave now.</p>
          </section>
        )}
        {deliveries.length > 0 && (
          <section>
            <h3 className="modal-section-title">Delivered · {money(r2(given))} of {money(Number(sale.total))}</h3>
            <table className="rd-table"><tbody>
              {deliveries.map(d => (
                <tr key={d.id}>
                  <td>{d.delivered_on}</td>
                  <td>{d.kind === 'collection' ? 'Collected' : 'Delivered'} #{d.delivery_no}{d.received_by ? ` · ${d.received_by}` : ''}{d.vehicle ? ` · ${d.vehicle}` : ''}
                    <div className="pl-help">{(d.lines || []).map(x => `${qtyText(Number(x.quantity))} ${per(lineById[x.sale_line_id]?.product_id)} ${refs.items[`p:${lineById[x.sale_line_id]?.product_id}`]?.name ?? ''}`).join(', ')}</div></td>
                  <td style={{ textAlign: 'right' }}><strong>{money(Number(d.value))}</strong></td>
                </tr>
              ))}
            </tbody></table>
            <p className="text-sm">
              Delivered without VAT <strong>{money(r2(delivered.ex))}</strong> · cost <strong>{money(r2(delivered.cost))}</strong>
              {delivered.est > 0.5 && <span className="co-est-txt"> ({money(r2(delivered.est))} estimated at price)</span>}
              {' · '}margin <strong className={delivered.ex - delivered.cost < 0 ? 'text-error' : ''}>{money(r2(delivered.ex - delivered.cost))}</strong>
              {delivered.unknown && <span className="pl-help"> · part with no cost known</span>}
            </p>
          </section>
        )}
        {sale.stage === 'invoice' && canAt('invoices.create', br, null) && (
          <div className="flex items-center gap-8">
            <span className="text-sm">EFD receipt</span>
            <input className="form-input" style={{ maxWidth: 220 }} value={efd} onChange={e => setEfd(e.target.value)} placeholder="Receipt number" />
            {efd !== (sale.efd_receipt_no ?? '') && <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={() => toStage('efd', { efd_receipt_no: efd })}>Save</button>}
          </div>
        )}
        {sale.notes && <p className="text-sm"><span className="pl-label">Note</span> {sale.notes}</p>}
      </div>

      {askEfd && (
        <Modal title={`Invoice #${sale.sale_no}`} onClose={() => setAskEfd(false)}
          footer={<><button type="button" className="btn btn-outline" onClick={() => setAskEfd(false)}>Back</button>
            <button type="button" className="btn btn-primary" disabled={busy} onClick={async () => { if (await toStage('invoice', { efd_receipt_no: efd })) setAskEfd(false); }}>Invoice {money(Number(sale.total))}</button></>}>
          <p className="text-sm">The lines and prices are fixed once invoiced.</p>
          <label className="pe-field"><span>EFD receipt number (optional — can be added later)</span><input className="form-input" autoFocus value={efd} onChange={e => setEfd(e.target.value)} /></label>
        </Modal>
      )}
      {paying && (
        <Modal title={`Payment on #${sale.sale_no}`} onClose={() => setPaying(false)}
          footer={<><button type="button" className="btn btn-outline" onClick={() => setPaying(false)}>Back</button>
            <button type="button" className="btn btn-primary" disabled={busy} onClick={async () => { if (await run(() => supabase.rpc('record_sale_payment', { p_sale: sale.id, p: pay }))) setPaying(false); }}>Record {num(pay.amount) ? money(num(pay.amount)) : ''}</button></>}>
          <div className="modal-form">
            <div className="flex items-center gap-8" role="group" aria-label="Paid by">
              {Object.entries(METHODS).map(([k, v]) => <button type="button" key={k} className={`filter-chip${pay.method === k ? ' is-on' : ''}`} onClick={() => setPay({ ...pay, method: k })}>{v}</button>)}
            </div>
            <div className="form-row">
              <label className="pe-field"><span>Amount (up to {money(owed)})</span><NumberInput step="any" min="0" className="form-input" value={pay.amount} onChange={e => setPay({ ...pay, amount: e.target.value })} /></label>
              <label className="pe-field"><span>Date</span><input type="date" className="form-input" max={today} value={pay.paid_on} onChange={e => setPay({ ...pay, paid_on: e.target.value })} /></label>
            </div>
            {pay.method !== 'cash' && <label className="pe-field"><span>{pay.method === 'bank' ? 'Bank' : 'Mobile money'} reference (required)</span><input className="form-input" value={pay.reference} onChange={e => setPay({ ...pay, reference: e.target.value })} /></label>}
            {error && <p className="text-xs text-error">{error}</p>}
          </div>
        </Modal>
      )}
      {handing && <DeliveryModal sale={sale} refs={refs} money={money} doneOf={doneOf} canLeave={r2(Math.max(paid - given, 0))} per={per}
        onClose={() => setHanding(false)} onSaved={async () => { setHanding(false); await onChanged(); }} />}
      {cancelling && (
        <Modal title={`Cancel #${sale.sale_no}?`} onClose={() => setCancelling(false)}
          footer={<><button type="button" className="btn btn-outline" onClick={() => setCancelling(false)}>Back</button>
            <button type="button" className="btn btn-primary" disabled={busy || !reason.trim()} onClick={async () => { if (await toStage('cancelled', { reason })) setCancelling(false); }}>Cancel the sale</button></>}>
          <label className="pe-field"><span>Why? (required)</span><input className="form-input" autoFocus value={reason} onChange={e => setReason(e.target.value)} /></label>
        </Modal>
      )}
    </Modal>
  );
}

/** Hand goods over: line by line what leaves, up to what is still to deliver and the value paid */
function DeliveryModal({ sale, refs, money, doneOf, canLeave, per, onClose, onSaved }) {
  const lines = [...(sale.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => ({ ...l, left: r2(Number(l.quantity) - doneOf(l.id)) })).filter(l => l.left > 0);
  const unitInc = l => Number(l.total) / Number(l.quantity);
  const [kind, setKind] = useState('collection');
  const [qty, setQty] = useState(() => Object.fromEntries(lines.map(l => [l.id, ''])));
  const [receivedBy, setReceivedBy] = useState(sale.walk_in_name ?? '');
  const [vehicle, setVehicle] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const value = lines.reduce((t, l) => t + r2(unitInc(l) * (num(qty[l.id]) ?? 0)), 0);
  // fill what the payments cover, line by line in order
  function fillPaid() {
    let room = canLeave;
    const next = {};
    for (const l of lines) {
      const q = Math.max(0, Math.min(l.left, Math.floor((room / unitInc(l)) * 100) / 100));
      next[l.id] = q > 0 ? String(q) : '';
      room -= r2(unitInc(l) * q);
    }
    setQty(next);
  }
  async function save() {
    setError('');
    if (value <= 0) { setError('Enter what leaves.'); return; }
    if (value > canLeave + 0.01) { setError(`Goods worth ${money(canLeave)} can leave — record a payment first.`); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('record_sale_delivery', { p_sale: sale.id, p: { kind, received_by: receivedBy, vehicle,
      lines: lines.filter(l => num(qty[l.id]) > 0).map(l => ({ sale_line_id: l.id, quantity: num(qty[l.id]) })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't record this. Please try again.")); return; }
    onSaved();
  }
  return (
    <Modal title={`Goods leaving on #${sale.sale_no}`} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Back</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Record {value > 0 ? money(r2(value)) : ''}</button></>}>
      <div className="modal-form">
        <div className="flex items-center gap-8" role="group" aria-label="How it leaves">
          <button type="button" className={`filter-chip${kind === 'collection' ? ' is-on' : ''}`} onClick={() => setKind('collection')}>Collected by the customer</button>
          <button type="button" className={`filter-chip${kind === 'delivery' ? ' is-on' : ''}`} onClick={() => setKind('delivery')}>Delivered</button>
          <span className="pl-help" style={{ marginLeft: 'auto' }}>Paid for, not yet taken: <strong>{money(canLeave)}</strong></span>
        </div>
        <table className="rd-table">
          <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Left to deliver</th><th style={{ textAlign: 'right' }}>Leaving now</th><th style={{ textAlign: 'right' }}>Value</th></tr></thead>
          <tbody>
            {lines.map(l => (
              <tr key={l.id}>
                <td><strong>{refs.items[`p:${l.product_id}`]?.name}{l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}</strong></td>
                <td style={{ textAlign: 'right' }}>{qtyText(l.left)} {per(l.product_id)}</td>
                <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 100 }} value={qty[l.id]} onChange={e => setQty({ ...qty, [l.id]: e.target.value })} /></td>
                <td style={{ textAlign: 'right' }}>{num(qty[l.id]) > 0 ? money(r2(unitInc(l) * num(qty[l.id]))) : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="flex items-center gap-8">
          <button type="button" className="btn btn-ghost btn-sm" onClick={fillPaid}>Fill what is paid for</button>
          <span style={{ marginLeft: 'auto' }}><strong>{money(r2(value))}</strong> leaving</span>
        </div>
        <div className="form-row">
          <label className="pe-field"><span>Received by</span><input className="form-input" value={receivedBy} onChange={e => setReceivedBy(e.target.value)} /></label>
          {kind === 'delivery' && <label className="pe-field"><span>Vehicle / driver (optional)</span><input className="form-input" value={vehicle} onChange={e => setVehicle(e.target.value)} /></label>}
        </div>
      </div>
    </Modal>
  );
}
