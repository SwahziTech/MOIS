import { useEffect, useMemo, useState } from 'react';
import PeriodBar from '../components/PeriodBar';
import { Receipt, Plus, Trash2, Printer, Check, Eye, Pencil, Paperclip } from 'lucide-react';
import { useSearchParams } from 'react-router-dom';
import { useUrlTab } from '../lib/urlTab';
import { useSessionPeriod } from '../lib/sessionPeriod';
import { weekPeriods, weekLabel, periodRange, keyForRange } from '../lib/periods';
import { PaymentProofsList, ProofModal, ReviewModal, ProofBadge, proofState, saleApproval, loadProofs, postSaleProofs, postSharedSlip } from '../components/sales/PaymentProofs';
import ProofBox from '../components/ProofBox';
import { getFiles, putFiles, dropFiles } from '../lib/fileStore';
import { useFileUrl } from '../components/ProofPreview';
import { SlipCanvas } from '../components/sales/SlipMark';
import DeliveriesPanel, { ConfirmDelivery } from '../components/sales/DeliveriesPanel';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatAmount, formatMoneyShort, dateText, tableDate, tableDateTime } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import { loadInventoryRefs, qtyText, orgToday } from '../lib/inventory';
import { categoryTools, productOrder } from '../lib/categories';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';
import ProductPicker from '../components/production/ProductPicker';
import SalesSettings from '../components/sales/SalesSettings';

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
  const [view, setView] = useUrlTab('book');      // book | list | deliveries | overview (the book first — 2026-10-26); list = the sidebar's Invoices
  const [accounts, setAccounts] = useState([]);   // receiving accounts (067)
  const [proofs, setProofs] = useState({});       // payment id → its proof (105)
  const [showSettings, setShowSettings] = useState(false);
  // sales typed from an uploaded sales book (Daily report › Upload a report, 2026-11-03): each opens
  // in Record sale in turn; the place reached is kept on this tab, so closing or a refresh carries on
  const uploadKey = `mois.upload.sales.${organization?.id}.${branchId}`;
  const [upload, setUpload] = useState(null);   // { at, sales }
  const openUpload = q => setEditing({ book: true, upload: true, at: q.at, prefill: q.sales[q.at] });
  function stepUpload() {
    const q = { ...upload, at: upload.at + 1 };
    if (q.at >= q.sales.length) { try { sessionStorage.removeItem(uploadKey); } catch { /* ignore */ } setUpload(null); return null; }
    try { sessionStorage.setItem(uploadKey, JSON.stringify(q)); } catch { /* ignore */ }
    setUpload(q);
    return q;
  }
  function stopUpload() { try { sessionStorage.removeItem(uploadKey); } catch { /* ignore */ } setUpload(null); }

  async function load() {
    setError('');
    try {
      const [r, s, c] = await Promise.all([
        refs ? Promise.resolve(refs) : loadInventoryRefs(),
        (async () => {
          const q = cols => supabase.from('sales').select(cols).order('sale_date', { ascending: false }).order('sale_no', { ascending: false }).limit(500);
          const withCorrections = await q('*, lines:sale_lines(*), payments:sale_payments(*), deliveries:sale_deliveries(*, lines:sale_delivery_lines(*)), corrections:sale_corrections(*)');
          if (!withCorrections.error) return withCorrections;   // 068
          const withDeliveries = await q('*, lines:sale_lines(*), payments:sale_payments(*), deliveries:sale_deliveries(*, lines:sale_delivery_lines(*))');
          return withDeliveries.error ? q('*, lines:sale_lines(*), payments:sale_payments(*)') : withDeliveries;   // before 065
        })(),
        supabase.from('customers').select('*').order('name'),
      ]);
      const ac = await supabase.from('payment_accounts').select('*').order('display_order').order('name');
      setProofs(await loadProofs());
      setAccounts(ac.error ? [] : ac.data || []);
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
  // opened on one sale (?sale=, from the Director view's sales report)
  const [saleParams] = useSearchParams();
  useEffect(() => { const id = saleParams.get('sale'); if (id && sales?.some(x => x.id === id)) setViewing(id); }, [sales === null]); // eslint-disable-line react-hooks/exhaustive-deps
  // opened from a lead (Customers › Leads › Make quotation, 095): a new quotation for its customer
  const [params, setParams] = useSearchParams();
  useEffect(() => {
    const cid = params.get('quote_for');
    if (!cid || !refs || !customers.some(c => c.id === cid)) return;
    const leadId = params.get('lead');
    (async () => {
      const { data: lead } = leadId ? await supabase.from('leads').select('site, interest').eq('id', leadId).maybeSingle() : { data: null };
      setEditing({ prefill: { customer_id: cid, site: lead?.site ?? '', notes: lead?.interest ? `Enquiry: ${lead.interest}` : '' }, leadId });
      setParams({ tab: 'list' }, { replace: true });
    })();
  }, [params, refs, customers]); // eslint-disable-line react-hooks/exhaustive-deps

  const buyerOf = s => customers.find(c => c.id === s.customer_id)?.name ?? s.walk_in_name ?? 'Walk-in';
  const paidOf = s => (s.payments || []).reduce((t, p) => t + Number(p.amount), 0);
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (sales || []).filter(s => inBranch(s.branch_id) && (!stage || s.stage === stage)
      && (!q || `${s.sale_no} ${buyerOf(s)} ${s.walk_in_phone ?? ''} ${s.efd_receipt_no ?? ''}`.toLowerCase().includes(q)));
  }, [sales, search, stage, branchId, customers]); // eslint-disable-line react-hooks/exhaustive-deps

  const canSell = branchId && canAt('sales.create', branchId, null);
  useEffect(() => {
    if (!organization?.id || !branchId || !refs || !canSell) return;
    let q = null;
    try { q = JSON.parse(sessionStorage.getItem(uploadKey) || 'null'); } catch { /* ignore */ }
    if (!q?.sales?.length || q.at >= q.sales.length) { setUpload(null); return; }
    setUpload(q);
    setView('book', true);
    openUpload(q);
  }, [uploadKey, !!refs, canSell]); // eslint-disable-line react-hooks/exhaustive-deps
  // what sells most at the branch (sale lines, last 90 days) — the product search lists it first (2026-10-26)
  const soldCount = useMemo(() => {
    const since = new Date(new Date(`${today}T00:00:00Z`).getTime() - 90 * 864e5).toISOString().slice(0, 10);
    const c = {};
    for (const x of sales || []) if (x.branch_id === branchId && x.stage !== 'cancelled' && x.stage !== 'quotation' && x.sale_date >= since)
      for (const l of x.lines || []) c[l.product_id] = (c[l.product_id] || 0) + 1;
    return c;
  }, [sales, branchId, today]);
  // walk-in buyers seen before: one entry per phone (digits), else per name — with how many sales
  const walkIns = useMemo(() => {
    const m = {};
    for (const x of sales || []) {
      if (x.customer_id || x.stage === 'cancelled' || !(x.walk_in_name || x.walk_in_phone)) continue;
      const k = (x.walk_in_phone || '').replace(/\D/g, '') || `n:${(x.walk_in_name || '').trim().toLowerCase()}`;
      const e = (m[k] ||= { key: k, name: x.walk_in_name || '', phone: x.walk_in_phone || '', count: 0, site: x.site || '' });
      e.count += 1;
      if (!e.name && x.walk_in_name) e.name = x.walk_in_name;
    }
    return Object.values(m).sort((a, b) => b.count - a.count);
  }, [sales]);
  const branchAccounts = accounts.filter(a => a.branch_id === branchId);
  const open = (sales || []).find(s => s.id === viewing);

  // page order (locked): heading → summary cards → these tabs → search/filters → list
  // the sidebar shows this page twice (2026-10-30): Sales (book, deliveries, overview) and Invoices (the quotations & invoices list)
  const onInvoices = view === 'list';
  const salesTabs = !onInvoices && <PageTabs tabs={[['book', 'Sales book'], ['receipts', 'Slips'], ['deliveries', 'Deliveries'], ['overview', 'Overview']]} value={view} onChange={setView} />;

  return (
    <PageShell title={onInvoices ? 'Invoices' : 'Sales'} subtitle="Sales"
      description={branchId ? branchName : 'All branches'}
      onSettings={() => setShowSettings(true)}
      actions={canSell && <button type="button" className="btn btn-outline" onClick={() => setEditing({})}><Plus size={15} /> New quotation</button>}
      primaryAction={canSell && <button type="button" className="btn btn-primary" onClick={() => setEditing({ book: true })}><Plus size={15} /> Record sale</button>}>
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <>
          {salesTabs}
          {upload && !editing && (
            <div className="alert alert-info" role="note">Uploaded sales: {upload.at + 1} of {upload.sales.length} waiting.
              {' '}<button type="button" className="btn btn-primary btn-sm" onClick={() => openUpload(upload)}>Continue</button>
              {' '}<button type="button" className="btn btn-outline btn-sm" onClick={() => { const q = stepUpload(); if (q) openUpload(q); }}>Skip this sale</button>
              {' '}<button type="button" className="btn btn-ghost btn-sm" onClick={stopUpload}>Stop</button></div>
          )}
          {view === 'book' && sales && refs && <SalesBook sales={(sales || []).filter(x => inBranch(x.branch_id) && x.stage !== 'quotation' && x.stage !== 'cancelled')}
            refs={refs} accounts={accounts.filter(a => inBranch(a.branch_id))} money={money} currency={organization?.currency_code} today={today} buyerOf={buyerOf} proofs={proofs} onOpen={id => setViewing(id)}
            canProof={id => canAt('sales.create', id, null)} organizationId={organization?.id} onChanged={load} />}
          {view === 'receipts' && <PaymentProofsList branchId={branchId} inBranch={inBranch} directorView={!canSell && canAt('sales.confirm_payments', branchId, null)} />}
          {view === 'deliveries' && <DeliveriesPanel branchId={branchId} inBranch={inBranch} canAct={!!canSell} today={today} search={search} />}
          {view === 'overview' && sales && refs && <SalesOverview sales={(sales || []).filter(x => inBranch(x.branch_id))} refs={refs} customers={customers} money={money} currency={organization?.currency_code} today={today} buyerOf={buyerOf} />}
          {view === 'list' && <>
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
                    <span className="pl-help">#{s.sale_no} · {dateText(s.sale_date)}{s.efd_receipt_no ? ` · EFD ${s.efd_receipt_no}` : ''}
                      {s.due_date && ['order', 'invoice'].includes(s.stage) && Number(s.total) - paid > 0.01 && s.due_date < today && <span className="text-error"> · overdue since {dateText(s.due_date)}</span>}</span>
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
          </>}
        </>
      )}

      {editing && refs && (
        <SaleEditor key={editing.upload ? `upload-${editing.at}` : 'edit'} sale={editing.id ? editing : null} prefill={editing.prefill} book={!!editing.book} sold={soldCount} walkIns={walkIns} accounts={branchAccounts} branchId={editing.branch_id ?? branchId} refs={refs} customers={customers} money={money} today={today}
          canDiscount={canAt('sales.discount', editing.branch_id ?? branchId, null)}
          canOther={canAt('sales.other_items', editing.branch_id ?? branchId, null)}
          onClose={() => setEditing(null)} onSaved={async id => {
            // a quotation made for a lead: the lead points to it and is quoted (095)
            if (editing.leadId && id) await supabase.from('leads').update({ sale_id: id, stage: 'quoted' }).eq('id', editing.leadId);
            // an uploaded sale saved: the next one opens
            if (editing.upload) { const q = stepUpload(); setEditing(null); await load(); if (q) openUpload(q); return; }
            setEditing(null); await load(); setViewing(id);
          }} />
      )}
      {open && refs && !editing && (
        <SaleView sale={open} proofs={proofs} accounts={accounts.filter(a => a.branch_id === open.branch_id)} refs={refs} buyer={buyerOf(open)} customer={customers.find(c => c.id === open.customer_id)} money={money} today={today} canAt={canAt}
          onEdit={() => setEditing(open)} onClose={() => setViewing(null)} onChanged={load} />
      )}
      {showSettings && <SalesSettings onClose={() => { setShowSettings(false); load(); }} />}
    </PageShell>
  );
}

/**
 * A quotation or order — or, from Record sale (book), a sale written straight
 * into the book: buyer, site, lines priced from the price list, then where
 * the money went (account, amount, receipt no.); saved as an invoice with its
 * payments in one go (record_sale, 067).
 */
/* The proof of a payment given while recording the sale (2026-11-08): the same box as Proof of payment;
   it is posted when the sale is saved */
/* A proof a sale already has, beside its name: a thumbnail that opens the photo to zoom (a PDF opens in a new tab) */
function HaveThumb({ file, name, amount, view, money }) {
  const url = useFileUrl(file);
  const [open, setOpen] = useState(false);
  const isImage = file?.type?.startsWith('image/');
  return (
    <>
      <span className="sl-have-pic"><span className="pl-help">{isImage ? 'photo' : 'PDF'}</span>
      <button type="button" className="sl-have-thumb" title={isImage ? 'Open the photo' : 'Open the PDF'} onClick={() => (isImage ? setOpen(true) : window.open(url, '_blank', 'noopener'))}>
        {isImage && url ? <img src={url} alt="" /> : <span className="pl-help">PDF</span>}
      </button></span>
      {open && url && (
        <Modal title={`Proof · ${name} · ${money(amount)}`} onClose={() => setOpen(false)} size="lg"
          footer={<button type="button" className="btn btn-primary" onClick={() => setOpen(false)}>Close</button>}>
          {/* the slip beside the sale it pays for (2026-11-11, the user) */}
          <div className="pp-review">
            <div className="pp-review-slip"><SlipCanvas url={url} strokes={[]} color="green" pen={null} onStrokes={() => {}} /></div>
            {view && (
              <div className="sl-have-sale">
                <div className="pl-label">Amount on this proof</div>
                <strong className="sl-have-amt">{money(amount)}</strong>
                <div className="pl-label" style={{ marginTop: 10 }}>Sale</div>
                <div><strong>{view.name}</strong>{view.date ? <span className="pl-help"> · {dateText(view.date)}</span> : null}</div>
                <table className="pp-shared-table"><tbody>
                  {(view.rows || []).map((r, i) => <tr key={i}><td>{r.product}</td><td className="num">{r.qty != null ? `${qtyText(r.qty)} ${r.unit}` : '—'}</td><td className="num">{formatAmount(r.amount)}</td></tr>)}
                </tbody><tfoot><tr><td colSpan={2}><strong>Total</strong></td><td className="num"><strong>{money(view.total)}</strong></td></tr></tfoot></table>
                <div className="pl-help">Paid {money(view.paid)} into {view.acc}{view.total - view.paid > 0.01 ? ` · ${money(view.total - view.paid)} not paid` : ''}</div>
              </div>
            )}
          </div>
        </Modal>
      )}
    </>
  );
}

function SaleProofWindow({ amount, money, start, note = 'Posted with the sale when it is saved.', existing = [], onClose, onDone }) {
  const [file, setFile] = useState(start?.file ?? null);
  const [text, setText] = useState(start?.text ?? '');
  const [replace, setReplace] = useState(false);   // the ticked sales' own proofs: keep (default) or replace with this slip
  const [error, setError] = useState('');
  return (
    <Modal title={`Proof of payment${amount > 0 ? ` · ${money(amount)}` : ''}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className="btn btn-primary" onClick={() => {
          if (!file && !text.trim() && !(existing.length && !replace)) { setError('Add the photo or paste the SMS.'); return; }
          onDone({ file, text }, replace);
        }}>{existing.length && !replace && !file && !text.trim() ? 'Keep them' : 'Add proof'}</button></>}>
      <div className="modal-form">
        <p className="pl-help">{note}</p>
        {/* proofs the ticked sales already have (2026-11-11, the user): shown, and the person chooses */}
        {existing.length > 0 && (
          <div className="sl-have">
            <strong>Already have a proof</strong>
            <ul>
              {existing.map(x => (
                <li key={x.name}><span className="sl-have-name">{x.name}</span>
                  <span className="pl-help">{x.lost ? 'added earlier — the photo was lost when the page reloaded' : [money(x.amount), x.text?.trim() && `SMS "${x.text.trim().slice(0, 40)}${x.text.trim().length > 40 ? '…' : ''}"`].filter(Boolean).join(' + ')}</span>
                  {x.file && <HaveThumb file={x.file} name={x.name} amount={x.amount} view={x.view} money={money} />}</li>
              ))}
            </ul>
            <div className="filter-chips" role="radiogroup" aria-label="Their own proofs">
              <button type="button" role="radio" aria-checked={!replace} className={`filter-chip${!replace ? ' is-on' : ''}`} onClick={() => setReplace(false)}>Keep their own proofs</button>
              <button type="button" role="radio" aria-checked={replace} className={`filter-chip${replace ? ' is-on' : ''}`} onClick={() => setReplace(true)}>Replace them with this slip</button>
            </div>
          </div>
        )}
        <ProofBox file={file} onFile={f => { if (f && f.size > 10 * 1024 * 1024) { setError('That file is over 10 MB. Take the photo again at a smaller size.'); return; } setError(''); setFile(f); }} text={text} onText={setText} />
      </div>
    </Modal>
  );
}

function SaleEditor({ sale, prefill, book = false, sold = {}, walkIns = [], accounts = [], branchId, refs, customers, money, today, canDiscount, canOther = false, onClose, onSaved }) {
  const { organization } = useAuth();
  const [buyer, setBuyer] = useState(sale?.customer_id || prefill?.customer_id ? 'customer' : 'walkin');
  const [customerId, setCustomerId] = useState(sale?.customer_id ?? prefill?.customer_id ?? '');
  const [walkName, setWalkName] = useState(sale?.walk_in_name ?? prefill?.walk_in_name ?? '');
  const [walkPhone, setWalkPhone] = useState(sale?.walk_in_phone ?? prefill?.walk_in_phone ?? '');
  const [newCust, setNewCust] = useState(null);   // { name, phone, tin } while adding one
  const [promote, setPromote] = useState(null);   // { name, phone, tin, address } — a walk-in buyer's third purchase (069)
  const digits = v => (v || '').replace(/\D/g, '');
  const seen = () => walkIns.find(w => (digits(walkPhone) && digits(w.phone) === digits(walkPhone)) || (!digits(walkPhone) && walkName.trim() && w.key === `n:${walkName.trim().toLowerCase()}`));
  const known = !sale && seen();
  function pickWalkIn(v, field) {
    const w = walkIns.find(x => (field === 'name' ? x.name : x.phone) === v);
    if (field === 'name') setWalkName(v); else setWalkPhone(v);
    if (w) { setWalkName(w.name); setWalkPhone(w.phone); if (!site && w.site) setSite(w.site); }
  }
  const [date, setDate] = useState(sale?.sale_date ?? prefill?.sale_date ?? today);
  const [validUntil, setValidUntil] = useState(sale?.valid_until ?? '');
  const [notes, setNotes] = useState(sale?.notes ?? prefill?.notes ?? '');
  const [site, setSite] = useState(sale?.site ?? prefill?.site ?? '');
  const [efd, setEfd] = useState(prefill?.efd_receipt_no ?? '');
  const activeAccounts = accounts.filter(a => a.status === 'active');
  const [pays, setPays] = useState(() => (prefill?.payments?.length
    ? prefill.payments.map(x => ({ accountId: x.accountId || '', amount: x.amount ?? '', receiptNo: x.receiptNo || '', auto: false }))
    : [{ accountId: '', amount: '', receiptNo: '', auto: true }]));   // auto: follows the total until typed
  const [payMode, setPayMode] = useState('order');    // order: one payment for the whole order | items: one per item (070)
  const [itemPays, setItemPays] = useState({});       // line index → { accountId, amount, receiptNo }
  const [lines, setLines] = useState(() => (!sale && prefill?.lines ? prefill.lines.map(l => ({ productId: l.productId, colorId: l.colorId ?? '', quantity: l.quantity, price: l.price ?? '', reason: '' }))
    : (sale?.lines || []).sort((a, b) => a.line_no - b.line_no).map(l => (!l.product_id ? { other: true, name: l.item_name ?? '', price: String(+l.total) } : {
    productId: l.product_id, colorId: l.color_id ?? '', quantity: String(+l.quantity),
    price: Number(l.price) !== Number(l.list_price) ? String(r2(Number(l.price) * (1 + Number(l.vat_rate) / 100))) : '', reason: l.discount_reason ?? '' }))));
  const [prices, setPrices] = useState({});        // `${product}|${colour}` → { ex, rate, source }
  const [listPrices, setListPrices] = useState({}); // product id → the price list's prices as the customer pays them (the picker)
  const [avail, setAvail] = useState({});          // `${product}|${colour}` → available
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [bad, setBad] = useState(null);   // { key, msg }: the field the error is about
  // the day's list (111): sales added one by one, listed below the form, saved at once; kept on this device until saved
  const dayOn = book && !sale && !prefill;
  const dayKey = `mois.daySales.${branchId}`;
  const [dayList, setDayList] = useState(() => { if (!dayOn) return []; try { return JSON.parse(localStorage.getItem(dayKey) || '[]'); } catch { return []; } });
  // one sheet = one date (2026-11-11, the user): a kept list brings its date back after a reload,
  // and changing the date moves every sale in the list to it
  useEffect(() => { if (dayOn && dayList.length && dayList[0].payload?.sale_date) setDate(dayList[0].payload.sale_date); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  function changeDate(v) {
    setDate(v);
    if (dayOn && v) setDayList(d => d.map(x => ({ ...x, payload: { ...x.payload, sale_date: v }, view: { ...x.view, date: v }, form: { ...x.form, date: v } })));
  }
  const [dayBad, setDayBad] = useState(null);   // index of the sale the save stopped on
  const [dayErr, setDayErr] = useState('');
  // one slip for the sales ticked in the day's list (2026-11-08): groups of entry ids with their slip (in memory)
  const [daySel, setDaySel] = useState(() => new Set());
  const [slipGroups, setSlipGroups] = useState([]);   // [{ ids: [entry id], slip: { file, text } }]
  const [groupSlipOpen, setGroupSlipOpen] = useState(false);
  const groupOf = id => slipGroups.findIndex(g => g.ids.includes(id));
  const [choosing, setChoosing] = useState(false);   // the tick boxes show while choosing a slip's sales
  // the proof of each payment (2026-11-08): payment row → { file, text }; files live in memory only
  const [payProofs, setPayProofs] = useState({});
  const [dayFiles, setDayFiles] = useState({});   // day's list entry id → its proofs
  // the proofs and shared slips of the day's list stay on this device with the list (2026-11-11, the user: a reload lost them)
  const [filesReady, setFilesReady] = useState(!dayOn);
  useEffect(() => {
    if (!dayOn) return;
    let live = true;
    getFiles(dayKey).then(v => {
      if (!live) return;
      if (v) { setDayFiles(f => ({ ...(v.files || {}), ...f })); setSlipGroups(g => (g.length ? g : v.groups || [])); }
      setFilesReady(true);
    });
    return () => { live = false; };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!dayOn || !filesReady) return;
    if (Object.keys(dayFiles).length || slipGroups.length) putFiles(dayKey, { files: dayFiles, groups: slipGroups }); else dropFiles(dayKey);
  }, [dayFiles, slipGroups, filesReady]); // eslint-disable-line react-hooks/exhaustive-deps
  const [proofFor, setProofFor] = useState(null);   // the payment row whose proof window is open
  const setProof = (i, patch) => setPayProofs(m => ({ ...m, [i]: { ...(m[i] || {}), ...patch } }));
  const proofsFor = payments => (payments || []).map((p, i) => (payProofs[i] && (payProofs[i].file || payProofs[i].text?.trim()) && !p.line_no ? { accountId: p.account_id || '', amount: p.amount, ...payProofs[i] } : null)).filter(Boolean);
  const buyerName = cust => (cust ? customers.find(c => c.id === cust)?.name : walkName.trim()) || 'Walk-in';
  useEffect(() => { if (!dayOn) return; try { if (dayList.length) localStorage.setItem(dayKey, JSON.stringify(dayList)); else localStorage.removeItem(dayKey); } catch { /* storage off */ } }, [dayList]); // eslint-disable-line react-hooks/exhaustive-deps
  const flag = (key, msg) => {
    setError(msg); setBad({ key, msg });
    setTimeout(() => { const el = document.querySelector(`[data-field="${key}"]`); el?.scrollIntoView({ block: 'center', behavior: 'smooth' }); el?.focus?.({ preventScroll: true }); }, 0);
  };
  const badMsg = key => (bad?.key === key ? <div className="sl-field-error" role="alert">{bad.msg}</div> : null);
  const badCls = key => (bad?.key === key ? ' is-invalid' : '');

  const cats = useMemo(() => categoryTools(refs.categoryRows || []), [refs]);
  const carried = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .sort(productOrder(cats)), [refs, branchId, cats]);
  const unitOf = id => refs.unitById[refs.items[`p:${id}`]?.stockUnitId]?.symbol ?? '';
  const per = id => (unitOf(id).toUpperCase() === 'SQM' ? 'm²' : 'pc');
  const key = l => `${l.productId}|${l.colorId || ''}`;

  // the picker shows each product's price (as paid, per m² or piece) — the lowest of its colours, 'from' when they differ
  useEffect(() => {
    supabase.from('product_branch_pricing').select('product_id, price_per_sqm_inclusive, price_per_unit_inclusive, is_available').eq('branch_id', branchId)
      .then(({ data }) => {
        const m = {};
        for (const x of data || []) {
          if (!x.is_available) continue;
          const sqm = (refs.unitById[refs.items[`p:${x.product_id}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM';
          const v = Number(sqm ? x.price_per_sqm_inclusive : x.price_per_unit_inclusive);
          if (!(v > 0)) continue;
          const e = (m[x.product_id] ||= { min: v, max: v });
          e.min = Math.min(e.min, v); e.max = Math.max(e.max, v);
        }
        setListPrices(m);
      });
  }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
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
    if (l.other) { const t = num(l.price); return t != null ? { listInc: null, inc: t, total: t, ex: t, rate: 0, off: false, discount: 0 } : { listInc: null, inc: null, total: null }; }
    const pr = prices[key(l)];
    if (!pr) return null;
    const listInc = pr.ex != null ? r2(pr.ex * (1 + pr.rate / 100)) : null;
    const inc = num(l.price) ?? listInc;
    const q = num(l.quantity) ?? 0;
    if (inc == null) return { listInc, inc: null, total: null };
    // a price other than the list's is a discount; the VAT box unticks itself for it unless the user ticks it (110)
    const off = listInc == null || inc !== listInc;
    const vatOn = l.vat ?? (!off && pr.rate > 0);
    const rate = vatOn ? (pr.rate > 0 ? pr.rate : 18) : 0;
    // 112: the price as typed to 3 decimals; the line total in whole shillings, as the database saves it
    const total = Math.round(q * (Math.round(inc * 1000) / 1000));
    return { listInc, inc, total, ex: r2(total / (1 + rate / 100)), rate, off, vatOn, discount: listInc != null && inc < listInc ? r2((listInc - inc) * q) : 0 };
  };
  const hasVat = lines.some(l => preview(l)?.vatOn);
  const totals = lines.reduce((t, l) => { const p = preview(l); if (p?.total != null) { t.total += p.total; t.ex += p.ex; } return t; }, { total: 0, ex: 0 });
  // not enough stock (2026-10-26): what is available (finished goods less what open orders hold — this sale's own hold given back
  // when it is being edited) set against all its lines for the same product and colour. A warning only: goods may come out of curing first.
  const ownHeld = {};
  if (sale && ['order', 'invoice'].includes(sale.stage)) for (const l of sale.lines || []) ownHeld[`${l.product_id}|${l.color_id ?? ''}`] = (ownHeld[`${l.product_id}|${l.color_id ?? ''}`] || 0) + Number(l.quantity);
  const availOf = k => (avail[k] === undefined ? undefined : avail[k] + (ownHeld[k] || 0));
  const wanted = {};
  for (const l of lines) if (l.productId && num(l.quantity) > 0) wanted[key(l)] = (wanted[key(l)] || 0) + num(l.quantity);
  const short = Object.entries(wanted).filter(([k, q]) => availOf(k) !== undefined && q > availOf(k) + 1e-9)
    .map(([k, q]) => { const [pid, cid] = k.split('|'); return { name: `${refs.items[`p:${pid}`]?.name ?? ''}${cid ? ` ${refs.colorById[cid]?.name ?? ''}` : ''}`, q, av: Math.max(availOf(k), 0), unit: per(pid) }; });
  const set = (i, patch) => setLines(ls => ls.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  async function save(toList = false) {
    setError(''); setBad(null);
    if (!lines.length) { setError('Add at least one product.'); return; }
    if (toList && ((buyer === 'customer' && newCust) || (buyer === 'walkin' && promote))) {
      setError('This buyer becomes a new customer: record this sale on its own (Record sale).'); return;
    }
    const badOther = lines.find(l => l.other && (!l.name.trim() || !(num(l.price) > 0)));
    if (badOther) { setError('Write what each other item is, and its price.'); return; }
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
    // the third purchase of a walk-in buyer: make them a customer first (their earlier sales follow)
    if (buyer === 'walkin' && promote) {
      if (!promote.name.trim()) { setError('Enter the customer\'s name.'); return; }
      setBusy(true);
      const { data, error: err } = await supabase.rpc('promote_walk_in', { p: { ...promote, match_name: walkName, match_phone: walkPhone } });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err)); return; }
      cust = data;
    }
    if (buyer === 'walkin' && !promote && !walkName.trim()) { flag('walkname', "Enter the buyer's name."); return; }
    if (buyer === 'customer' && !cust) { flag('customer', 'Choose the customer, or sell to a walk-in buyer.'); return; }
    const noReason = lines.findIndex(l => !l.other && preview(l)?.off && preview(l)?.listInc != null && !l.reason.trim());
    if (noReason >= 0) { flag(`reason-${noReason}`, `${refs.items[`p:${lines[noReason].productId}`]?.name}: give the reason for the price change.`); return; }
    const payload = {
      id: sale?.id, branch_id: branchId, sale_date: date, valid_until: validUntil || null, notes,
      ...(cust ? { customer_id: cust } : { walk_in_name: walkName, walk_in_phone: walkPhone }),
      lines: lines.map(l => {
        if (l.other) return { item_name: l.name.trim(), price: num(l.price) };   // an other item (104)
        const pr = prices[key(l)];
        const inc = num(l.price);
        return { product_id: l.productId, color_id: l.colorId || null, quantity: num(l.quantity), vat: !!preview(l)?.vatOn,
          ...(inc != null && pr ? { price: inc, discount_reason: l.reason } : {}) };   // the price charged a unit (069); the VAT box (110)
      }),
    };
    if (book && payMode === 'items' && lines.length > 1) {
      const ps = lines.map((l, i) => ({ i, x: itemPays[i] || {}, total: preview(l)?.total ?? 0 }))
        .map(({ i, x, total }) => ({ line_no: i + 1, accountId: x.accountId || '', value: x.amount === undefined || x.amount === '' ? total : num(x.amount), receiptNo: x.receiptNo || '' }))
        .filter(x => x.value > 0);
      if (!activeAccounts.length && ps.length) { setError('Add the receiving accounts first (Sales ⚙) — a payment must name its account.'); return; }
      if (ps.some(x => !x.accountId)) { setError('Choose the account each item was paid into — it is required.'); return; }
      payload.site = site; payload.efd_receipt_no = efd;
      payload.payments = ps.map(x => ({ line_no: x.line_no, account_id: x.accountId, amount: x.value, receipt_no: x.receiptNo }));
    } else if (book) {
      const ps = pays.map(x => ({ ...x, value: x.auto && pays.length === 1 ? r2(totals.total) : num(x.amount) })).filter(x => x.value > 0);
      const noAcc = ps.findIndex(x => !x.accountId);
      if (noAcc >= 0 && activeAccounts.length) { flag(`account-${pays.findIndex((y, j) => !y.accountId && (y.auto && pays.length === 1 ? r2(totals.total) : num(y.amount)) > 0)}`, 'Choose the account this payment went into — it is required.'); return; }
      if (ps.length && !activeAccounts.length) { setError('Add the receiving accounts first (Sales ⚙) — a payment must name its account.'); return; }
      if (r2(ps.reduce((t, x) => t + x.value, 0)) > r2(totals.total) + 0.01) { setError('The payments are more than the total.'); return; }
      payload.site = site; payload.efd_receipt_no = efd;
      payload.payments = ps.map(x => ({ account_id: x.accountId || null, amount: x.value, receipt_no: x.receiptNo, ...(x.accountId ? {} : { method: 'cash' }) }));
    } else payload.site = site;
    if (toList) { addToDay(payload, cust); return; }
    setBusy(true);
    const { data, error: err } = book
      ? await supabase.rpc('record_sale', { p: payload })
      : await supabase.rpc('save_sale', { p: payload });
    if (!err && !book && site !== (sale?.site ?? '') && sale?.id) await supabase.rpc('set_sale_site', { p_sale: sale.id, p_site: site });
    if (!err && !book && !sale?.id && site) await supabase.rpc('set_sale_site', { p_sale: data, p_site: site });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save this sale. Please try again.")); return; }
    if (book && data) {
      setBusy(true);
      const failed = await postSaleProofs(data, proofsFor(payload.payments), { organizationId: organization.id, buyer: buyerName(payload.customer_id) });
      setBusy(false);
      if (failed) window.alert('The sale is saved, but a proof could not be posted. Add it in Sales › Slips.');
    }
    onSaved(data);
  }

  // the sale in the form goes to the day's list; the form clears for the next one (the date stays)
  function addToDay(payload, cust) {
    const accName = id => activeAccounts.find(a => a.id === id)?.name ?? 'Cash';
    const view = {
      name: cust ? customers.find(c => c.id === cust)?.name ?? '' : walkName.trim(),
      date,
      rows: lines.map(l => ({ product: l.other ? l.name.trim() : `${refs.items[`p:${l.productId}`]?.name ?? ''}${l.colorId ? ` ${refs.colorById[l.colorId]?.name ?? ''}` : ''}`,
        qty: l.other ? null : num(l.quantity), unit: l.other ? '' : per(l.productId), amount: preview(l)?.total ?? 0 })),
      acc: [...new Set((payload.payments || []).map(x => accName(x.account_id)))].join(', ') || 'Not paid',
      paid: r2((payload.payments || []).reduce((t, x) => t + Number(x.amount || 0), 0)),
      total: r2(totals.total),
    };
    const form = { buyer, customerId, walkName, walkPhone, date, notes, site, efd, pays, payMode, itemPays, lines };
    const id = `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    const proofs = proofsFor(payload.payments);
    view.proofs = proofs.length;
    if (proofs.length) setDayFiles(m => ({ ...m, [id]: { proofs, buyer: buyerName(cust), raw: payProofs } }));
    setDayList(d => [...d, { id, payload, view, form }]);
    setPayProofs({});
    setDayBad(null);
    setLines([]); setWalkName(''); setWalkPhone(''); setCustomerId(''); setSite(''); setEfd(''); setNotes('');
    setPays([{ accountId: '', amount: '', receiptNo: '', auto: true }]); setPayMode('order'); setItemPays({});
  }
  // a row clicked goes back into the form to fix
  function editDay(i) {
    if (lines.length) { setError('Add the sale in the form to the list first, or remove its items.'); return; }
    const x = dayList[i].form;
    setBuyer(x.buyer); setCustomerId(x.customerId); setWalkName(x.walkName); setWalkPhone(x.walkPhone); setDate(x.date); setNotes(x.notes);
    setSite(x.site); setEfd(x.efd); setPays(x.pays); setPayMode(x.payMode); setItemPays(x.itemPays); setLines(x.lines);
    setPayProofs(dayFiles[dayList[i].id]?.raw ?? {});
    setDayList(d => d.filter((_, j) => j !== i)); setDayBad(null); setError('');
  }
  // Save all shows every sale first — date, items, payments, proofs — and saves only on Confirm (2026-11-11, the user)
  const [checkDay, setCheckDay] = useState(false);
  const [previewDay, setPreviewDay] = useState(null);   // index of the list's sale being looked at
  const removeDay = (i, id) => {
    setDayList(d => d.filter((_, k) => k !== i)); setDayBad(null);
    setDaySel(sl => { const n = new Set(sl); n.delete(id); return n; });
    setSlipGroups(gs => gs.map(g => ({ ...g, ids: g.ids.filter(x => x !== id) })).filter(g => g.ids.length));
  };
  function askSaveDay() {
    setError(''); setBad(null); setDayErr('');
    if (lines.length) { setDayErr('The form above still has a sale: add it to the list, or remove its items.'); return; }
    setCheckDay(true);
  }
  async function saveDay() {
    setCheckDay(false);
    setBusy(true);
    const { data: ids, error: err } = await supabase.rpc('record_sales_day', { p_sales: dayList.map(x => x.payload) });
    if (err) {
      const m = /^Sale (\d+): /.exec(err.message || '');
      if (m) setDayBad(Number(m[1]) - 1);
      setDayErr(dbErrorMessage(err, "We couldn't save the day's sales. Nothing was saved."));
      setBusy(false);
      return;
    }
    // the sales are saved: now their proofs
    let failed = 0;
    for (const [k, x] of dayList.entries()) {
      const pf = dayFiles[x.id];
      if (pf && ids?.[k]) failed += await postSaleProofs(ids[k], pf.proofs, { organizationId: organization.id, buyer: pf.buyer });
    }
    // one slip per account: every saved payment into it that has no proof of its own
    if (slipGroups.length && ids?.length) {
      const { data: pays } = await supabase.from('sale_payments').select('id, amount, paid_on, account_id, sale:sales!inner(id, sale_no, branch_id)').in('sale_id', ids);
      const { data: had } = await supabase.from('sale_payment_proofs').select('payment_id').in('payment_id', (pays || []).map(p => p.id));
      const taken = new Set((had || []).map(x => x.payment_id));
      for (const g of slipGroups) {
        const saleIds = g.ids.map(id => ids[dayList.findIndex(x => x.id === id)]).filter(Boolean);
        const covered = (pays || []).filter(p => saleIds.includes(p.sale.id) && !taken.has(p.id));
        const names = g.ids.map(id => dayList.find(x => x.id === id)?.view.name).filter(Boolean);
        failed += await postSharedSlip(covered, g.slip, { organizationId: organization.id, who: names.length > 2 ? `${names[0]}-and-${names.length - 1}-more` : names.join('-') });
      }
    }
    setSlipGroups([]); setDaySel(new Set()); setChoosing(false);
    setBusy(false);
    if (failed) window.alert(`The sales are saved, but ${failed} proof${failed === 1 ? '' : 's'} could not be posted. Add ${failed === 1 ? 'it' : 'them'} in Sales › Slips.`);
    // the list kept on this device goes first: the window closes straight after, before the list's own clean-up runs
    try { localStorage.removeItem(dayKey); } catch { /* storage off */ }
    await dropFiles(dayKey);
    setDayFiles({});
    setDayList([]);
    onSaved(null);
  }
  const dayTotal = r2(dayList.reduce((t, x) => t + x.view.total, 0));
  const dayByAcc = {};   // account id ('' = cash) → { name, amount, sales }
  for (const x of dayList) for (const p of x.payload.payments || []) {
    const k = p.account_id || '';
    const e = (dayByAcc[k] ||= { name: activeAccounts.find(a => a.id === k)?.name ?? 'Cash', amount: 0, sales: 0 });
    e.amount = r2(e.amount + Number(p.amount || 0)); e.sales += 1;
  }
  const dayUnpaid = r2(dayList.reduce((t, x) => t + Math.max(x.view.total - x.view.paid, 0), 0));

  return (
    <Modal title={<span className="sl-title">{sale ? `${STAGES[sale.stage]} #${sale.sale_no}` : book ? 'Record a sale' : 'New quotation'}
        <input type="date" className="form-input sl-date" aria-label="Date" max={today} value={date} title={dayOn && dayList.length ? 'The date of every sale in the list' : undefined} onChange={e => changeDate(e.target.value)} /></span>} onClose={onClose} size="xl"
      after={dayOn ? <>
        {/* between the sale being recorded and the day's list (2026-11-08) */}
        {dayOn && dayList.length > 0 && <div className="sl-day-add" aria-hidden="true" />}
        {dayOn && dayList.length > 0 && (
          <section className="modal modal-xl sl-day-card day-list" aria-label="Day's list">
            <div className="modal-body">
            <div className="day-list-head"><h3 className="day-list-title">Day's list</h3><span className="day-list-sub">Daily Sales Ledger</span><span className="day-list-chip">{dayList.length} sale{dayList.length === 1 ? '' : 's'} · {money(dayTotal)}</span></div>
            <table className="rd-table sl-day-table">
              <thead><tr><th aria-label={choosing ? 'Tick for the slip' : 'Proof'} style={{ width: 36 }} /><th>Name</th><th>Products</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Amount (TZS)</th><th>Acc.</th><th aria-label="Actions" /></tr></thead>
              <tbody>
                {/* newest on top (2026-11-13, the user); saved in the order they were added */}
                {dayList.map((x, i) => [x, i]).reverse().map(([x, i]) => x.view.rows.map((r, j) => (
                  <tr key={`${i}-${j}`} className={`clickable-row${dayBad === i ? ' sl-day-bad' : ''}${j === 0 ? ' sl-day-first' : ''}`} onClick={() => setPreviewDay(i)} title="Look at it">
                    {j === 0 && <td rowSpan={x.view.rows.length} onClick={e => e.stopPropagation()}>
                      {choosing
                        ? <input type="checkbox" aria-label={`Tick ${x.view.name} for one slip`} checked={daySel.has(x.id)} disabled={!(x.view.paid > 0)}
                            onChange={e => setDaySel(sl => { const n = new Set(sl); if (e.target.checked) n.add(x.id); else n.delete(x.id); return n; })} />
                        : <button type="button" className={`icon-btn${x.view.proofs > 0 || groupOf(x.id) >= 0 ? ' sl-has-proof' : ''}`} disabled={!(x.view.paid > 0)}
                            aria-label={`Add the proof of ${x.view.name}`} title={x.view.paid > 0 ? (x.view.proofs > 0 || groupOf(x.id) >= 0 ? 'Its proof — keep or replace it' : 'Add its proof/slip') : 'Nothing paid yet'}
                            onClick={() => { setDaySel(new Set([x.id])); setGroupSlipOpen(true); }}><Paperclip size={14} /></button>}
                    </td>}
                    {j === 0 && <td rowSpan={x.view.rows.length}><strong>{x.view.name}</strong></td>}
                    <td>{r.product}</td>
                    <td style={{ textAlign: 'right' }}>{r.qty != null ? <>{qtyText(r.qty)} <span className="pl-help">{r.unit}</span></> : '—'}</td>
                    <td style={{ textAlign: 'right' }}>{formatAmount(r.amount)}</td>
                    {j === 0 && <td rowSpan={x.view.rows.length}>{x.view.acc}{x.view.paid < x.view.total - 0.01 && <div className="pl-help text-warning">{formatAmount(r2(x.view.total - x.view.paid))} not paid</div>}
                      {groupOf(x.id) >= 0 && <div className="pl-help sl-shared-tag">+ shared slip {slipGroups.length > 1 ? groupOf(x.id) + 1 : ''}</div>}
                      {x.view.proofs > 0 && (dayFiles[x.id] ? <div className="pl-help">+ proof</div> : <div className="pl-help text-warning" title="Photos are not kept after a refresh">proof: add it again</div>)}</td>}
                    {j === 0 && <td rowSpan={x.view.rows.length} className="sl-day-acts" onClick={e => e.stopPropagation()}>
                      <button type="button" className="icon-btn" aria-label={`Look at ${x.view.name}`} title="Look at it" onClick={() => setPreviewDay(i)}><Eye size={14} /></button>
                      <button type="button" className="icon-btn" aria-label={`Edit ${x.view.name}`} title="Edit it in the form" onClick={() => editDay(i)}><Pencil size={14} /></button>
                      <button type="button" className="icon-btn" aria-label={`Remove ${x.view.name} from the list`} title="Remove from the list" onClick={() => removeDay(i, x.id)}><Trash2 size={14} /></button>
                    </td>}
                  </tr>
                )))}
                <tr className="sl-day-total"><td colSpan={4}><strong>Total</strong> <span className="pl-help">{dayList.length} sale{dayList.length === 1 ? '' : 's'}</span></td><td style={{ textAlign: 'right' }}><strong>{money(dayTotal)}</strong></td><td colSpan={2} /></tr>
              </tbody>
            </table>
            {choosing && (
              <div className="sl-sel-bar">
                <span>{daySel.size ? <><strong>{daySel.size}</strong> ticked · {money(r2(dayList.filter(x => daySel.has(x.id)).reduce((t, x) => t + x.view.paid, 0)))} paid</> : 'Tick the sales this proof/slip is for.'}</span>
                <button type="button" className="btn btn-primary btn-sm" disabled={!daySel.size} onClick={() => setGroupSlipOpen(true)}>Add the proof/slip</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setDaySel(new Set()); setChoosing(false); }}>Cancel</button>
              </div>
            )}
            <div className="sl-day-accs">
              {Object.entries(dayByAcc).map(([k, v]) => (
                <span key={k} className="sl-day-acc"><span className="pl-help">{v.name}</span><strong>{formatAmount(v.amount)}</strong>
                </span>
              ))}
              {dayUnpaid > 0 && <span className="sl-day-acc"><span className="pl-help">Not paid</span><strong className="text-warning">{formatAmount(dayUnpaid)}</strong></span>}
            </div>
            </div>
            <div className="modal-footer">
              {dayErr && <span className="modal-footer-error" role="alert">{dayErr}</span>}
              {/* a proof/slip for some of the list's sales: choose them, then add it; the count shows the slips added */}
              {!choosing && <button type="button" className="btn btn-outline sl-day-proof" onClick={() => { setDaySel(new Set()); setChoosing(true); }}>
                <Plus size={14} /> Add proof/slip{slipGroups.length > 0 && <span className="sl-count" title={`${slipGroups.length} proof/slip${slipGroups.length === 1 ? '' : 's'} added`}>{slipGroups.length}</span>}</button>}
              <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={askSaveDay}>Save all · {dayList.length} sale{dayList.length === 1 ? '' : 's'}</button>
            </div>
          </section>
        )}
      </> : null}
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {dayOn
          ? <button type="button" className="btn btn-outline" disabled={busy} onClick={() => save(true)}><Plus size={14} /> Add to the day's list</button>
          : <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>}
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={() => save()}>{sale ? 'Save' : book ? 'Record sale' : 'Save quotation'}</button>
      </>}>
      <div className="modal-form">
        {prefill?.banner && <div className="alert alert-info" role="note">{prefill.banner}</div>}
        <div className="flex items-center gap-8" role="group" aria-label="Buyer">
          <button type="button" className={`filter-chip${buyer === 'walkin' ? ' is-on' : ''}`} onClick={() => setBuyer('walkin')}>Walk-in buyer</button>
          <button type="button" className={`filter-chip${buyer === 'customer' ? ' is-on' : ''}`} onClick={() => setBuyer('customer')}>Customer</button>
        </div>
        {buyer === 'walkin' ? (
          <div className="form-row sl-buyer-row">
            <label className="pe-field"><span>Name</span><input className={`form-input${badCls('walkname')}`} data-field="walkname" list="walkin-names" value={walkName} onChange={e => { pickWalkIn(e.target.value, 'name'); setBad(null); }} />{badMsg('walkname')}</label>
            <label className="pe-field"><span>Phone (optional)</span><input className="form-input" list="walkin-phones" inputMode="tel" value={walkPhone} onChange={e => pickWalkIn(e.target.value, 'phone')} /></label>
            <datalist id="walkin-names">{walkIns.filter(w => w.name).map(w => <option key={w.key} value={w.name}>{w.phone}</option>)}</datalist>
            <label className="pe-field"><span>Site (where the goods go)</span><input className="form-input" value={site} placeholder="e.g. the customer's site" onChange={e => setSite(e.target.value)} /></label>
            <datalist id="walkin-phones">{walkIns.filter(w => w.phone).map(w => <option key={w.key} value={w.phone}>{w.name}</option>)}</datalist>
          </div>
        ) : null}
        {buyer === 'walkin' && known && (
          known.count >= 2 ? (
            <div className="alert alert-info sl-promote">
              <strong>{known.name || known.phone} is buying for the {known.count + 1}{known.count + 1 === 3 ? 'rd' : 'th'} time</strong> — save them as a customer (their {known.count} earlier sale{known.count === 1 ? '' : 's'} move with them).
              {promote ? (
                <div className="form-row">
                  <label className="pe-field"><span>Name</span><input className="form-input" value={promote.name} onChange={e => setPromote({ ...promote, name: e.target.value })} /></label>
                  <label className="pe-field"><span>Phone</span><input className="form-input" value={promote.phone} onChange={e => setPromote({ ...promote, phone: e.target.value })} /></label>
                  <label className="pe-field"><span>TIN (optional)</span><input className="form-input" value={promote.tin} onChange={e => setPromote({ ...promote, tin: e.target.value })} /></label>
                  <label className="pe-field"><span>Address (optional)</span><input className="form-input" value={promote.address} onChange={e => setPromote({ ...promote, address: e.target.value })} /></label>
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setPromote(null)}>Not now</button>
                </div>
              ) : <button type="button" className="btn btn-outline btn-sm" onClick={() => setPromote({ name: walkName || known.name, phone: walkPhone || known.phone, tin: '', address: '' })}>Add their details</button>}
            </div>
          ) : <p className="pl-help">Bought before ({known.count})</p>
        )}
        {buyer === 'walkin' ? null : newCust ? (
          <div className="form-row">
            <label className="pe-field"><span>New customer</span><input className="form-input" autoFocus value={newCust.name} onChange={e => setNewCust({ ...newCust, name: e.target.value })} /></label>
            <label className="pe-field"><span>Phone</span><input className="form-input" inputMode="tel" value={newCust.phone} onChange={e => setNewCust({ ...newCust, phone: e.target.value })} /></label>
            <label className="pe-field"><span>TIN (optional)</span><input className="form-input" value={newCust.tin} onChange={e => setNewCust({ ...newCust, tin: e.target.value })} /></label>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setNewCust(null)}>Pick existing</button>
            <label className="pe-field"><span>Site (where the goods go)</span><input className="form-input" value={site} placeholder="e.g. the customer's site" onChange={e => setSite(e.target.value)} /></label>
          </div>
        ) : (
          <div className="form-row">
            <label className="pe-field"><span>Customer</span>
              <select className={`form-input${badCls('customer')}`} data-field="customer" value={customerId} onChange={e => { setCustomerId(e.target.value); setBad(null); }}>
                <option value="">Choose…</option>
                {customers.filter(c => c.status === 'active' || c.id === customerId).map(c => <option key={c.id} value={c.id}>{c.name}{c.phone ? ` · ${c.phone}` : ''}</option>)}
              </select>{badMsg('customer')}</label>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setNewCust({ name: '', phone: '', tin: '' })}><Plus size={13} /> New customer</button>
            <label className="pe-field"><span>Site (where the goods go)</span><input className="form-input" value={site} placeholder="e.g. the customer's site" onChange={e => setSite(e.target.value)} /></label>
          </div>
        )}
        {!book && (!sale || sale.stage === 'quotation') && <div className="form-row">
          <label className="pe-field" style={{ maxWidth: 240 }}><span>Quotation valid until (optional)</span><input type="date" className="form-input" min={date} value={validUntil} onChange={e => setValidUntil(e.target.value)} /></label>
        </div>}

        {short.length > 0 && (
          <div className="alert alert-warning" role="alert">
            <strong>Not enough in stock:</strong> {short.map(x => `${x.name} — ${qtyText(r2(x.q))} ${x.unit} ordered, ${qtyText(r2(x.av))} available`).join('; ')}.
            
          </div>
        )}
        <table className="rd-table sl-table">
          <thead><tr><th>Product</th><th>Colour</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Price</th><th style={{ textAlign: 'right' }}>Total</th><th /></tr></thead>
          <tbody>
            {lines.map((l, i) => {
              if (l.other) return (
                <tr key={i} className="sl-other">
                  <td colSpan={2}><input className="form-input" placeholder="What is it? e.g. vipande 4&quot;" aria-label="Other item" value={l.name} onChange={e => set(i, { name: e.target.value })} />
                    <div className="pl-help" title="Price agreed with the buyer · no stock, no VAT">Other item</div></td>
                  <td style={{ textAlign: 'right' }}><span className="pl-help">—</span></td>
                  <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 120 }} placeholder="Price" aria-label="Other item price" value={l.price} onChange={e => set(i, { price: e.target.value })} /></td>
                  <td style={{ textAlign: 'right' }}>{num(l.price) > 0 ? <strong>{money(num(l.price))}</strong> : '—'}</td>
                  <td><button type="button" className="icon-btn" aria-label="Remove line" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={14} /></button></td>
                </tr>
              );
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
                    {availOf(key(l)) !== undefined && <div className={`pl-help${(wanted[key(l)] ?? 0) > availOf(key(l)) + 1e-9 ? ' text-warning' : ''}`}>{qtyText(r2(Math.max(availOf(key(l)), 0)))} {unitOf(l.productId)} available</div>}
                  </td>
                  <td style={{ textAlign: 'right' }}>
                    {p === null ? <span className="pl-help">{it?.colorIds?.length && !l.colorId ? 'pick a colour' : '…'}</span>
                      : canDiscount ? (<>
                        <NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} placeholder={p.listInc != null ? String(p.listInc) : 'No price'} value={l.price} onChange={e => set(i, { price: e.target.value })} />
                        <div className="pl-help">{p.listInc != null ? `list ${money(p.listInc)} /${per(l.productId)}` : 'no list price'}</div>
                        {p.off && p.discount > 0 && <div className="sl-discount">discount {money(p.discount)}</div>}
                        {p.off && !(p.discount > 0) && <div className="pl-help">not the list price</div>}
                        {changed && <input className={`form-input${badCls(`reason-${i}`)}`} data-field={`reason-${i}`} placeholder="Reason for the price (required)" value={l.reason} onChange={e => { set(i, { reason: e.target.value }); setBad(null); }} />}
                        {changed && badMsg(`reason-${i}`)}
                      </>) : (p.listInc != null
                        ? <><strong>{money(p.listInc)}</strong> <span className="pl-help">/{per(l.productId)}</span></>
                        : <span className="text-warning text-xs">No price — set it in Pricing</span>)}
                  </td>
                  <td style={{ textAlign: 'right' }}>{p?.total != null ? <strong>{money(p.total)}</strong> : '—'}
                    {p?.total != null && <label className="sl-vat" title={l.vat == null ? 'Unticks itself when the price is not the list price; tick it to charge VAT anyway' : 'Set by you'}>
                      <input type="checkbox" checked={!!p.vatOn} onChange={e => set(i, { vat: e.target.checked })} /> VAT</label>}</td>
                  <td><button type="button" className="icon-btn" aria-label="Remove line" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}><Trash2 size={14} /></button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <div className="flex items-center gap-8">
          <button type="button" className="btn btn-outline btn-sm" onClick={() => setPicking(true)}><Plus size={13} /> Add product</button>
          {canOther && <button type="button" className="btn btn-outline btn-sm" title="Something with no price list — rejects (vipande) and the like: write it and its price" onClick={() => setLines(ls => [...ls, { other: true, name: '', price: '' }])}><Plus size={13} /> Add other item</button>}
          <span style={{ marginLeft: 'auto' }} className="sl-totals">
            <span className="pl-help">without VAT {money(r2(totals.ex))} · VAT {money(r2(totals.total - totals.ex))}</span>
            <strong>Total {money(r2(totals.total))}</strong>
          </span>
        </div>
        {book && (
          <section>
            <h3 className="modal-section-title">Payments</h3>
            {lines.length > 1 && (
              <div className="flex items-center gap-8" role="group" aria-label="How it was paid">
                <button type="button" className={`filter-chip${payMode === 'order' ? ' is-on' : ''}`} onClick={() => setPayMode('order')}>One payment for the whole order</button>
                <button type="button" className={`filter-chip${payMode === 'items' ? ' is-on' : ''}`} onClick={() => setPayMode('items')}>Separately per item</button>
              </div>
            )}
            {payMode === 'items' && lines.length > 1 ? (
              <table className="rd-table">
                <thead><tr><th>Item</th><th style={{ textAlign: 'right' }}>Amount</th><th>Into account (required)</th></tr></thead>
                <tbody>{lines.map((l, i) => {
                  const x = itemPays[i] || {};
                  const setX = patch => setItemPays(m => ({ ...m, [i]: { ...(m[i] || {}), ...patch } }));
                  return (
                    <tr key={i}>
                      <td><strong>{l.other ? l.name || 'Other item' : <>{refs.items[`p:${l.productId}`]?.name}{l.colorId ? ` ${refs.colorById[l.colorId]?.name ?? ''}` : ''}</>}</strong></td>
                      <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 120 }}
                        value={x.amount === undefined ? String(preview(l)?.total ?? '') : x.amount} onChange={e => setX({ amount: e.target.value })} /></td>
                      <td><select className="form-input" value={x.accountId || ''} onChange={e => setX({ accountId: e.target.value })}>
                        <option value="">Choose…</option>{activeAccounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></td>
                    </tr>
                  );
                })}</tbody>
              </table>
            ) : <>
            {activeAccounts.length === 0 && <p className="pl-help">No accounts yet (Sales ⚙) — recorded as cash.</p>}
            {pays.map((x, i) => (
              <div key={i} className="form-row" style={{ alignItems: 'flex-end' }}>
                {activeAccounts.length > 0 && <label className="pe-field"><span>Into account (required)</span>
                  <select className={`form-input${badCls(`account-${i}`)}`} data-field={`account-${i}`} value={x.accountId} onChange={e => { setPays(ps => ps.map((y, j) => (j === i ? { ...y, accountId: e.target.value } : y))); setBad(null); }}>
                    <option value="">Choose…</option>
                    {activeAccounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
                  </select>{badMsg(`account-${i}`)}</label>}
                <label className="pe-field"><span>Amount</span>
                  <NumberInput step="any" min="0" className="form-input" value={x.auto && pays.length === 1 ? String(r2(totals.total)) : x.amount}
                    onChange={e => setPays(ps => ps.map((y, j) => (j === i ? { ...y, amount: e.target.value, auto: false } : y)))} /></label>
                {pays.length > 1 && <button type="button" className="icon-btn" aria-label="Remove payment" onClick={() => { setPays(ps => ps.filter((_, j) => j !== i)); setPayProofs({}); }}><Trash2 size={14} /></button>}
              </div>
            ))}
            <div className="flex items-center gap-8">
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => setPays(ps => [...ps.map(y => ({ ...y, amount: y.auto ? String(r2(totals.total)) : y.amount, auto: false })), { accountId: '', amount: '', receiptNo: '', auto: false }])}><Plus size={13} /> Split into another account</button>
              <span className="pl-help" style={{ marginLeft: 'auto' }}>Not paid yet? Amount 0.</span>
            </div>
            </>}
          </section>
        )}
        <div className="form-row sl-last-row">
          {book && <label className={`pe-field${hasVat && !efd.trim() ? ' sl-efd-due' : ''}`}><span>EFD receipt no. {hasVat ? <strong className={efd.trim() ? '' : 'text-warning'}>(required)</strong> : '(if any)'}</span>
            <input className="form-input" value={efd} placeholder={hasVat ? 'Add it now or later' : ''} onChange={e => setEfd(e.target.value)} /></label>}
          {/* the proof of each payment, small, between the EFD and the notes (2026-11-08) */}
          {book && !(payMode === 'items' && lines.length > 1) && pays.map((x, i) => (
            <div key={`proof-${i}`} className="pe-field"><span>Proof/Slip{pays.length > 1 ? ` · ${activeAccounts.find(a => a.id === x.accountId)?.name ?? `payment ${i + 1}`}` : ''}</span>
              {payProofs[i]?.file || payProofs[i]?.text?.trim()
                ? <button type="button" className="btn btn-outline sl-proof-btn is-added" title="Change the proof/slip" onClick={() => setProofFor(i)}><Check size={14} /> Proof/slip added</button>
                : <button type="button" className="btn btn-outline sl-proof-btn" onClick={() => setProofFor(i)}><Plus size={14} /> Add proof/slip</button>}</div>
          ))}
          <label className="pe-field"><span>Notes (optional)</span><input className="form-input" value={notes} onChange={e => setNotes(e.target.value)} /></label>
        </div>
      </div>
      {previewDay != null && dayList[previewDay] && (() => {
        const i = previewDay; const x = dayList[i];
        const own = dayFiles[x.id]?.proofs || [];
        const g = groupOf(x.id);
        return (
          <Modal title={<>{x.view.name} · {dateText(x.view.date)}</>} onClose={() => setPreviewDay(null)}
            footer={<>
              <button type="button" className="btn btn-ghost" onClick={() => { removeDay(i, x.id); setPreviewDay(null); }}><Trash2 size={14} /> Remove</button>
              <button type="button" className="btn btn-outline" onClick={() => setPreviewDay(null)}>Close</button>
              <button type="button" className="btn btn-primary" onClick={() => { setPreviewDay(null); editDay(i); }}><Pencil size={14} /> Edit</button></>}>
            <div className="modal-form">
              <table className="rd-table">
                <thead><tr><th>Products</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Amount (TZS)</th></tr></thead>
                <tbody>{x.view.rows.map((r, k) => <tr key={k}><td>{r.product}</td><td style={{ textAlign: 'right' }}>{r.qty != null ? <>{qtyText(r.qty)} <span className="pl-help">{r.unit}</span></> : '—'}</td><td style={{ textAlign: 'right' }}>{formatAmount(r.amount)}</td></tr>)}</tbody>
                <tfoot><tr><td colSpan={2}><strong>Total</strong></td><td style={{ textAlign: 'right' }}><strong>{money(x.view.total)}</strong></td></tr></tfoot>
              </table>
              <p>{x.view.paid > 0 ? <>Paid <strong>{money(x.view.paid)}</strong> into {x.view.acc}</> : <span className="text-warning">Not paid</span>}
                {x.view.paid > 0 && x.view.paid < x.view.total - 0.01 && <span className="text-warning"> · {money(r2(x.view.total - x.view.paid))} not paid</span>}</p>
              <div className="sl-check-proofs">
                {own.map((p, k) => (p.file ? <HaveThumb key={k} file={p.file} name={x.view.name} amount={Number(p.amount)} view={x.view} money={money} /> : <span key={k} className="pl-help" title={p.text}>SMS</span>))}
                {g >= 0 && (slipGroups[g].slip.file ? <span className="sl-check-shared"><span className="pl-help">shared slip</span><HaveThumb file={slipGroups[g].slip.file} name={x.view.name} amount={x.view.paid} view={x.view} money={money} /></span> : <span className="pl-help">shared SMS</span>)}
                {!own.length && g < 0 && x.view.paid > 0 && <button type="button" className="btn btn-outline btn-sm" onClick={() => { setPreviewDay(null); setDaySel(new Set([x.id])); setGroupSlipOpen(true); }}><Paperclip size={13} /> Add proof/slip</button>}
              </div>
            </div>
          </Modal>
        );
      })()}
      {checkDay && (() => {
        const lost = dayList.filter(x => x.view.proofs > 0 && !dayFiles[x.id]);
        const n = dayList.length;
        return (
          <Modal title={<>Save {n} sale{n === 1 ? '' : 's'} · {dateText(date)}</>} onClose={() => setCheckDay(false)} size="xl"
            footer={<>
              <button type="button" className="btn btn-outline" onClick={() => setCheckDay(false)}>Back to the list</button>
              <button type="button" className="btn btn-primary" onClick={saveDay}>Confirm and save</button></>}>
            <div className="modal-form">
              <p className="pl-help">Check each sale. Nothing is saved until you confirm.</p>
              {lost.length > 0 && <div className="sl-check-warn" role="alert">The proof of {lost.map(x => x.view.name).join(', ')} is no longer here. Go back and add it again, or save and add it later in Slips.</div>}
              <table className="rd-table sl-check-table">
                <thead><tr><th>Name</th><th>Products</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Amount (TZS)</th><th>Paid into</th><th>Proof</th></tr></thead>
                <tbody>
                  {dayList.map((x, i) => x.view.rows.map((r, j) => {
                    const own = dayFiles[x.id]?.proofs || [];
                    const g = groupOf(x.id);
                    return (
                      <tr key={`${i}-${j}`} className={j === 0 ? 'sl-day-first' : ''}>
                        {j === 0 && <td rowSpan={x.view.rows.length}><strong>{x.view.name}</strong></td>}
                        <td>{r.product}</td>
                        <td style={{ textAlign: 'right' }}>{r.qty != null ? <>{qtyText(r.qty)} <span className="pl-help">{r.unit}</span></> : '—'}</td>
                        <td style={{ textAlign: 'right' }}>{formatAmount(r.amount)}</td>
                        {j === 0 && <td rowSpan={x.view.rows.length}>{x.view.paid > 0 ? <>{x.view.acc}<div className="pl-help">{formatAmount(x.view.paid)}</div></> : <span className="text-warning">Not paid</span>}
                          {x.view.paid > 0 && x.view.paid < x.view.total - 0.01 && <div className="pl-help text-warning">{formatAmount(r2(x.view.total - x.view.paid))} not paid</div>}</td>}
                        {j === 0 && <td rowSpan={x.view.rows.length}>
                          <div className="sl-check-proofs">
                            {own.map((p, k) => p.file ? <HaveThumb key={k} file={p.file} name={x.view.name} amount={Number(p.amount)} view={x.view} money={money} />
                              : <span key={k} className="pl-help" title={p.text}>SMS</span>)}
                            {g >= 0 && (slipGroups[g].slip.file
                              ? <span className="sl-check-shared"><span className="pl-help">shared slip{slipGroups.length > 1 ? ` ${g + 1}` : ''}</span><HaveThumb file={slipGroups[g].slip.file} name={x.view.name} amount={r2(dayList.filter(y => slipGroups[g].ids.includes(y.id)).reduce((t, y) => t + y.view.paid, 0))} view={x.view} money={money} /></span>
                              : <span className="pl-help" title={slipGroups[g].slip.text}>shared SMS{slipGroups.length > 1 ? ` ${g + 1}` : ''}</span>)}
                            {x.view.proofs > 0 && !dayFiles[x.id] && <span className="text-warning">Lost — add again</span>}
                            {!own.length && g < 0 && !(x.view.proofs > 0) && x.view.paid > 0 && <span className="text-warning">No proof</span>}
                          </div></td>}
                      </tr>
                    );
                  }))}
                  <tr className="sl-day-total"><td colSpan={3}><strong>Total</strong> <span className="pl-help">{n} sale{n === 1 ? '' : 's'}</span></td><td style={{ textAlign: 'right' }}><strong>{money(dayTotal)}</strong></td><td colSpan={2} /></tr>
                </tbody>
              </table>
              <div className="sl-day-accs">
                {Object.entries(dayByAcc).map(([k, v]) => <span key={k} className="sl-day-acc"><span className="pl-help">{v.name}</span><strong>{formatAmount(v.amount)}</strong></span>)}
                {dayUnpaid > 0 && <span className="sl-day-acc"><span className="pl-help">Not paid</span><strong className="text-warning">{formatAmount(dayUnpaid)}</strong></span>}
              </div>
            </div>
          </Modal>
        );
      })()}
      {groupSlipOpen && (() => {
        // the proofs already given (2026-11-11, the user): one ticked sale's own proof opens in the box to keep or
        // replace; with several, each sale's proof is listed and the person chooses to keep them or replace them
        const ids = [...daySel];
        const ticked = dayList.filter(x => daySel.has(x.id));
        const ownOf = id => dayFiles[id]?.proofs?.[0];
        const own = ids.length === 1 ? ownOf(ids[0]) : null;
        const shared = slipGroups.find(g => ids.length && g.ids.length === ids.length && ids.every(id => g.ids.includes(id)));
        const start = own ? { file: own.file ?? null, text: own.text ?? '' } : shared?.slip;
        const existing = ids.length > 1 ? ticked.filter(x => ownOf(x.id) || x.view.proofs > 0)
          .map(x => ({ name: x.view.name, file: ownOf(x.id)?.file, text: ownOf(x.id)?.text, lost: !ownOf(x.id), amount: Number(ownOf(x.id)?.amount ?? x.view.paid), view: x.view })) : [];
        const names = ticked.map(x => x.view.name).join(', ');
        return <SaleProofWindow amount={r2(ticked.reduce((t, x) => t + x.view.paid, 0))} money={money} start={start} existing={existing}
          note={own ? 'The proof added with this sale: keep it or replace it.' : `One slip for ${daySel.size} sale${daySel.size === 1 ? '' : 's'}: ${names}.`}
          onClose={() => setGroupSlipOpen(false)}
          onDone={(v, replace) => {
            const gone = own ? [ids[0]] : replace ? ticked.filter(x => ownOf(x.id) || x.view.proofs > 0).map(x => x.id) : [];
            if (gone.length) {   // their own proofs give way to this slip
              setDayFiles(m => { const n = { ...m }; for (const id of gone) delete n[id]; return n; });
              setDayList(d => d.map(x => (gone.includes(x.id) ? { ...x, view: { ...x.view, proofs: 0 } } : x)));
            }
            if (v.file || v.text?.trim()) setSlipGroups(gs => [...gs.map(g => ({ ...g, ids: g.ids.filter(id => !daySel.has(id)) })).filter(g => g.ids.length), { ids, slip: v }]);
            setDaySel(new Set()); setGroupSlipOpen(false); setChoosing(false);
          }} />;
      })()}
      {proofFor != null && <SaleProofWindow amount={pays[proofFor]?.auto && pays.length === 1 ? totals.total : num(pays[proofFor]?.amount)} money={money} start={payProofs[proofFor]}
        onClose={() => setProofFor(null)} onDone={v => { setPayProofs(m => ({ ...m, [proofFor]: v })); setProofFor(null); }} />}
      {picking && (
        <ProductPicker title="Add a product" items={carried} cats={cats} usage={sold} usageLabel={['sale', 'sales']} onClose={() => setPicking(false)}
          metaOf={i => {
            // sales: what is available (all colours) and the price, not the wastani (2026-10-26)
            const av = Object.entries(avail).filter(([k]) => k.startsWith(`${i.id}|`)).reduce((t, [, v]) => t + Math.max(v, 0), 0);
            const lp = listPrices[i.id];
            return [`${qtyText(r2(av))} ${unitOf(i.id).toUpperCase() === 'SQM' ? 'm²' : 'pcs'} available`,
              lp ? `${lp.min !== lp.max || (i.colorIds?.length ?? 0) > 1 ? 'from ' : ''}${money(lp.min)} /${per(i.id)}` : 'no price'].join(' • ');
          }}
          onPick={id => { setPicking(false); setLines(ls => [...ls, { productId: id, colorId: '', quantity: '', price: '', reason: '' }]); }} />
      )}
    </Modal>
  );
}

/** One sale: its lines and totals, payments, and what can be done next */
function SaleView({ sale, proofs = {}, accounts = [], refs, buyer, customer, money, today, canAt, onEdit, onClose, onChanged }) {
  const [proofFor, setProofFor] = useState(null);    // a payment getting its proof (105)
  const [reviewFor, setReviewFor] = useState(null);  // a payment a director checks
  const [paying, setPaying] = useState(false);
  const [pay, setPay] = useState({ amount: '', method: 'cash', reference: '', paid_on: today, account_id: '', receipt_no: '', sale_line_id: '' });
  const activeAccounts = accounts.filter(a => a.status === 'active');
  const accountName = id => accounts.find(a => a.id === id)?.name;
  const [efd, setEfd] = useState(sale.efd_receipt_no ?? '');
  const [askEfd, setAskEfd] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [handing, setHanding] = useState(false);   // a delivery or collection being recorded (065)
  const [correcting, setCorrecting] = useState(false);   // a correction (068): Technical admin at once, managers through Approvals
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
  const [confirming, setConfirming] = useState(null);   // a delivery on the way, being confirmed (096)
  const [dueEdit, setDueEdit] = useState(null);         // the due date being changed (097)
  // other items (104) were handed over with the sale
  const given = deliveries.reduce((t, d) => t + Number(d.value), 0) + (sale.lines || []).filter(l => !l.product_id).reduce((t, l) => t + Number(l.total), 0);
  const doneOf = lineId => deliveries.reduce((t, d) => t + (d.lines || []).filter(x => x.sale_line_id === lineId).reduce((u, x) => u + Number(x.quantity), 0), 0);
  const lineById = Object.fromEntries((sale.lines || []).map(l => [l.id, l]));
  const exOf = x => Number(x.value) / (1 + Number(lineById[x.sale_line_id]?.vat_rate ?? 0) / 100);
  const delivered = deliveries.flatMap(d => d.lines || []).reduce((t, x) => ({ ex: t.ex + exOf(x), cost: t.cost + Number(x.cost ?? 0), est: t.est + Number(x.estimated_cost ?? 0), unknown: t.unknown || x.cost == null }), { ex: 0, cost: 0, est: 0, unknown: false });
  const canHand = ['order', 'invoice'].includes(sale.stage) && (canAt('sales.create', br, null) || canAt('inventory.issue', br, null))
    && (sale.lines || []).some(l => l.product_id && Number(l.quantity) - doneOf(l.id) > 1e-9);
  const goodsLeft = (sale.lines || []).some(l => l.product_id && Number(l.quantity) - doneOf(l.id) > 1e-9);

  async function run(fn) {
    setError(''); setBusy(true);
    const { error: err } = await fn();
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return false; }
    await onChanged();
    return true;
  }
  const toStage = (stage, p = {}) => run(() => supabase.rpc('set_sale_stage', { p_sale: sale.id, p_stage: stage, p }));
  // printable documents open in a tab of their own
  const openDoc = (doc, extra = '') => window.open(`/print/sale/${sale.id}?doc=${doc}${extra}`, '_blank', 'noopener');

  return (
    <Modal title={`${STAGES[sale.stage]} #${sale.sale_no} — ${buyer}`} onClose={onClose} size="xl"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {sale.stage !== 'cancelled' && <button type="button" className="btn btn-ghost" onClick={() => openDoc({ quotation: 'quotation', order: 'proforma', invoice: 'invoice' }[sale.stage])}>
          <Printer size={14} /> {{ quotation: 'Quotation', order: 'Proforma', invoice: 'Invoice' }[sale.stage]}</button>}
        {sale.stage === 'quotation' && <button type="button" className="btn btn-ghost" title="The quotation as a proforma invoice" onClick={() => openDoc('proforma')}><Printer size={14} /> Proforma</button>}
        {editable && <button type="button" className="btn btn-outline" onClick={onEdit}>Edit</button>}
        {!editable && sale.stage !== 'cancelled' && (canAt('system.manage', br, null) || canAt('sales.discount', br, null)) &&
          <button type="button" className="btn btn-ghost" onClick={() => setCorrecting(true)}>Correct…</button>}
        {sale.stage !== 'cancelled' && paid === 0 && canAt('sales.create', br, null) && (sale.stage !== 'invoice' || canAt('sales.discount', br, null)) &&
          <button type="button" className="btn btn-ghost" onClick={() => setCancelling(true)}>Cancel sale</button>}
        {sale.stage === 'quotation' && canAt('sales.create', br, null) && <button type="button" className="btn btn-outline" disabled={busy} onClick={() => toStage('order')}>Confirm order</button>}
        {['quotation', 'order'].includes(sale.stage) && canAt('invoices.create', br, null) && <button type="button" className="btn btn-primary" disabled={busy} onClick={() => setAskEfd(true)}>Invoice</button>}
        {canHand && <button type="button" className="btn btn-outline" onClick={() => setHanding(true)}>Deliver / collect</button>}
        {['order', 'invoice'].includes(sale.stage) && owed > 0 && canAt('payments.record', br, null) && <button type="button" className="btn btn-primary" onClick={() => { setPay(p => ({ ...p, amount: String(owed) })); setPaying(true); }}>Record payment</button>}
      </>}>
      <div className="modal-form">
        <p className="text-sm text-muted">
          <span className={`badge ${STAGE_BADGE[sale.stage]}`}>{STAGES[sale.stage]}</span> {dateText(sale.sale_date)}
          {customer ? ` · ${customer.phone ?? ''}${customer.tin ? ` · TIN ${customer.tin}` : ''}` : sale.walk_in_phone ? ` · ${sale.walk_in_phone}` : ''}
          {sale.valid_until && sale.stage === 'quotation' ? ` · valid until ${dateText(sale.valid_until)}` : ''}{sale.site ? ` · site: ${sale.site}` : ''}
          {sale.invoiced_on ? ` · invoiced ${dateText(sale.invoiced_on)}` : ''}{sale.efd_receipt_no ? ` · EFD ${sale.efd_receipt_no}` : ''}
          {sale.due_date && ['order', 'invoice'].includes(sale.stage) && (
            <> · <span className={owed > 0.01 && sale.due_date < today ? 'text-error' : ''}>due {dateText(sale.due_date)}{owed > 0.01 && sale.due_date < today ? ` — ${Math.round((new Date(today) - new Date(sale.due_date)) / 864e5)} days overdue` : ''}</span>
              {canAt('sales.create', sale.branch_id, null) && dueEdit === null && <button type="button" className="link-btn" style={{ marginLeft: 6 }} onClick={() => setDueEdit(sale.due_date)}>change</button>}
              {dueEdit !== null && <>
                <input type="date" className="form-input" style={{ display: 'inline-block', width: 150, marginLeft: 6 }} min={sale.sale_date} value={dueEdit} onChange={e => setDueEdit(e.target.value)} />
                <button type="button" className="btn btn-primary btn-sm" style={{ marginLeft: 4 }} disabled={busy || !dueEdit} onClick={async () => { if (await run(() => supabase.rpc('set_sale_due_date', { p_sale: sale.id, p_due: dueEdit }))) setDueEdit(null); }}>Save</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDueEdit(null)}>Cancel</button>
              </>}
            </>
          )}
          {sale.stage === 'cancelled' ? ` · cancelled (was ${STAGES[sale.cancelled_from]}): ${sale.cancel_reason}` : ''}
        </p>
        <table className="rd-table">
          <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Price</th><th style={{ textAlign: 'right' }}>Without VAT</th><th style={{ textAlign: 'right' }}>Total</th><th style={{ textAlign: 'right' }}>VAT</th></tr></thead>
          <tbody>
            {[...(sale.lines || [])].sort((a, b) => a.line_no - b.line_no).map(l => {
              const it = refs.items[`p:${l.product_id}`];
              const inc = r2(Number(l.price) * (1 + Number(l.vat_rate) / 100));
              return (
                <tr key={l.id}>
                  <td><strong>{l.product_id ? it?.name : l.item_name}{l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}</strong><div className="pl-help">{l.product_id ? it?.category : 'Other item'}</div>
                    {l.discount_reason && <div className="pl-help">list {money(r2(Number(l.list_price) * (1 + Number(l.vat_rate) / 100)))}{Number(l.vat_rate) === 0 ? ' before VAT' : ''} · {l.discount_reason}</div>}</td>
                  <td style={{ textAlign: 'right' }}>{l.product_id ? <>{qtyText(Number(l.quantity))} {per(l.product_id)}</> : <span className="pl-help">—</span>}</td>
                  <td style={{ textAlign: 'right' }}>{money(inc)}</td>
                  <td style={{ textAlign: 'right' }}>{money(Number(l.amount))}</td>
                  <td style={{ textAlign: 'right' }}><strong>{money(Number(l.total))}</strong></td>
                  {/* VAT last (2026-10-26): whether a line carries VAT shows at the end */}
                  <td style={{ textAlign: 'right' }}>{Number(l.vat_rate) === 0 ? <span className="pl-help">no VAT</span> : money(Number(l.vat))}</td>
                </tr>
              );
            })}
            <tr><td colSpan={3} style={{ textAlign: 'right' }}><strong>Totals</strong></td><td style={{ textAlign: 'right' }}>{money(Number(sale.subtotal))}</td><td style={{ textAlign: 'right' }}><strong>{money(Number(sale.total))}</strong></td><td style={{ textAlign: 'right' }}>{Number(sale.vat) === 0 ? <span className="pl-help">no VAT</span> : money(Number(sale.vat))}</td></tr>
          </tbody>
        </table>

        {sale.stage !== 'quotation' && sale.stage !== 'cancelled' && (
          <section>
            <h3 className="modal-section-title">Paid {money(paid)}{owed > 0 ? <span className="text-warning"> · {money(owed)} owed</span> : ''}</h3>
            {(sale.payments || []).length === 0 ? <p className="pl-help">No payment yet.</p> : (
              <table className="rd-table"><tbody>
                {[...sale.payments].sort((a, b) => (b.paid_on.localeCompare(a.paid_on) || b.created_at.localeCompare(a.created_at))).map(p => (
                  <tr key={p.id}><td>{tableDate(p.paid_on)}</td><td>{accountName(p.account_id) ?? METHODS[p.method]}{p.receipt_no ? ` · #${p.receipt_no}` : ''}{p.reference ? ` · ${p.reference}` : ''}</td><td style={{ textAlign: 'right' }}><strong>{money(Number(p.amount))}</strong></td>
                    <td><ProofBadge state={proofState(p, proofs[p.id], today)} />{proofs[p.id]?.status === 'queried' && <div className="pl-help text-error">{proofs[p.id].note}</div>}</td>
                    <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                      {proofs[p.id] && (proofs[p.id].status !== 'confirmed' && canAt('sales.confirm_payments', sale.branch_id, null)
                        ? <button type="button" className="btn btn-primary btn-sm" onClick={() => setReviewFor(p)}>Check</button>
                        : <button type="button" className="btn btn-ghost btn-sm" onClick={() => setReviewFor(p)}>View</button>)}
                      {proofs[p.id]?.status !== 'confirmed' && canAt('sales.create', sale.branch_id, null) && <button type="button" className="btn btn-outline btn-sm" onClick={() => setProofFor(p)}>{proofs[p.id] ? 'Replace proof' : 'Add proof'}</button>}
                      <button type="button" className="icon-btn" aria-label="Print receipt" title="Print receipt" onClick={() => openDoc('receipt', `&payment=${p.id}`)}><Printer size={15} /></button></td></tr>
                ))}
              </tbody></table>
            )}
            {goodsLeft && <p className="pl-help" title="Goods leave up to the value paid">Can leave now: {money(r2(Math.max(paid - given, 0)))}</p>}
          </section>
        )}
        {proofFor && <ProofModal payment={proofFor} sale={sale} proof={proofs[proofFor.id]} buyer={buyer} money={money} onClose={() => setProofFor(null)} onSaved={() => { setProofFor(null); onChanged(); }} />}
        {reviewFor && <ReviewModal payment={reviewFor} sale={sale} proof={proofs[reviewFor.id]} buyer={buyer} account={accountName(reviewFor.account_id) ?? METHODS[reviewFor.method]} money={money}
          canReview={proofs[reviewFor.id]?.status !== 'confirmed' && canAt('sales.confirm_payments', sale.branch_id, null)}
          onClose={() => setReviewFor(null)} onSaved={() => { setReviewFor(null); onChanged(); }} />}
        {deliveries.length > 0 && (
          <section>
            <h3 className="modal-section-title">Delivered {money(r2(deliveries.reduce((t, d) => t + Number(d.value), 0)))}</h3>
            <table className="rd-table"><tbody>
              {deliveries.map(d => (
                <tr key={d.id}>
                  <td>{tableDate(d.delivered_on)}</td>
                  <td>{d.kind === 'collection' || d.status === 'on_the_way' ? 'Collected' : 'Delivered'} DN-{d.delivery_no}{d.driver ? ` · ${d.driver}` : ''}{d.vehicle ? ` · ${d.vehicle}` : ''}
                    {d.status === 'on_the_way' && <span className="badge badge-warning" style={{ marginLeft: 6 }}>to confirm delivered</span>}
                    {d.kind === 'delivery' && d.status === 'delivered' && (d.pod_received_by || d.received_by) && <div className="pl-help">Received by {d.pod_received_by || d.received_by}{d.delivered_at ? ` · ${tableDateTime(d.delivered_at)}` : ''}{d.pod_note ? ` · ${d.pod_note}` : ''}</div>}
                    <div className="pl-help">{(d.lines || []).map(x => `${qtyText(Number(x.quantity))} ${per(lineById[x.sale_line_id]?.product_id)} ${refs.items[`p:${lineById[x.sale_line_id]?.product_id}`]?.name ?? ''}`).join(', ')}</div></td>
                  <td style={{ textAlign: 'right' }}><strong>{money(Number(d.value))}</strong></td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    {d.status === 'on_the_way' && canAt('sales.create', sale.branch_id, null) && <button type="button" className="btn btn-primary btn-sm" onClick={() => setConfirming(d)}>Delivered…</button>}
                    <button type="button" className="icon-btn" aria-label="Print delivery note" title="Print delivery note" onClick={() => openDoc('delivery', `&delivery=${d.id}`)}><Printer size={15} /></button></td>
                </tr>
              ))}
            </tbody></table>
            <p className="text-sm" title={`Without VAT ${money(r2(delivered.ex))} · cost ${money(r2(delivered.cost))}${delivered.est > 0.5 ? ` (${money(r2(delivered.est))} estimated at price)` : ''}${delivered.unknown ? ' · part with no cost known' : ''}`}>
              Margin <strong className={delivered.ex - delivered.cost < 0 ? 'text-error' : ''}>{money(r2(delivered.ex - delivered.cost))}</strong>
              {(delivered.est > 0.5 || delivered.unknown) && <span className="pl-help"> · estimated</span>}
            </p>
          </section>
        )}
        {sale.stage === 'invoice' && canAt('invoices.create', br, null) && (
          <div className="flex items-center gap-8">
            <span className="text-sm">EFD{Number(sale.vat) > 0 && !sale.efd_receipt_no ? <strong className="text-warning"> (required)</strong> : null}</span>
            <input className="form-input" style={{ maxWidth: 200 }} value={efd} onChange={e => setEfd(e.target.value)} placeholder="Number" />
            {efd !== (sale.efd_receipt_no ?? '') && <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={() => toStage('efd', { efd_receipt_no: efd })}>Save</button>}
          </div>
        )}
        {sale.notes && <p className="text-sm"><span className="pl-label">Note</span> {sale.notes}</p>}
        {(sale.corrections || []).length > 0 && (
          <section>
            <h3 className="modal-section-title">Corrections</h3>
            {[...sale.corrections].sort((a, b) => b.applied_at.localeCompare(a.applied_at)).map(c => (
              <p key={c.id} className="text-sm">{tableDate(c.applied_at)} · {c.reason}</p>
            ))}
          </section>
        )}
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
              {activeAccounts.length > 0 ? (
                <label className="pe-field" style={{ flex: 1 }}><span>Into account (required)</span>
                  <select className="form-input" value={pay.account_id} onChange={e => setPay({ ...pay, account_id: e.target.value })}>
                    <option value="">Choose…</option>
                    {activeAccounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
                  </select></label>
              ) : Object.entries(METHODS).map(([k, v]) => <button type="button" key={k} className={`filter-chip${pay.method === k ? ' is-on' : ''}`} onClick={() => setPay({ ...pay, method: k })}>{v}</button>)}
            </div>
            <div className="form-row">
              <label className="pe-field"><span>Amount (up to {money(owed)})</span><NumberInput step="any" min="0" className="form-input" value={pay.amount} onChange={e => setPay({ ...pay, amount: e.target.value })} /></label>
              <label className="pe-field"><span>Date</span><input type="date" className="form-input" max={today} value={pay.paid_on} onChange={e => setPay({ ...pay, paid_on: e.target.value })} /></label>
            </div>
            {(sale.lines || []).length > 1 && (
              <label className="pe-field"><span>For</span>
                <select className="form-input" value={pay.sale_line_id} onChange={e => setPay({ ...pay, sale_line_id: e.target.value })}>
                  <option value="">The whole order</option>
                  {[...sale.lines].sort((a, b) => a.line_no - b.line_no).map(l => <option key={l.id} value={l.id}>{l.product_id ? refs.items[`p:${l.product_id}`]?.name : l.item_name}{l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''} — {money(Number(l.total))}</option>)}
                </select></label>
            )}
            <label className="pe-field"><span>Receipt no. (optional)</span><input className="form-input" value={pay.receipt_no} onChange={e => setPay({ ...pay, receipt_no: e.target.value })} /></label>
            {activeAccounts.length > 0 && !pay.account_id && <p className="text-xs text-warning">Choose the account — it is required.</p>}
            {!activeAccounts.length && pay.method !== 'cash' && <label className="pe-field"><span>{pay.method === 'bank' ? 'Bank' : 'Mobile money'} reference (required)</span><input className="form-input" value={pay.reference} onChange={e => setPay({ ...pay, reference: e.target.value })} /></label>}
            {error && <p className="text-xs text-error">{error}</p>}
          </div>
        </Modal>
      )}
      {handing && <DeliveryModal sale={sale} refs={refs} money={money} doneOf={doneOf} canLeave={r2(Math.max(paid - given, 0))} per={per}
        onClose={() => setHanding(false)} onSaved={async () => { setHanding(false); await onChanged(); }} />}
      {correcting && <CorrectModal sale={sale} refs={refs} accounts={accounts} money={money} today={today} per={per} direct={canAt('system.manage', br, null)}
        onClose={() => setCorrecting(false)} onDone={async () => { setCorrecting(false); await onChanged(); }} />}
      {cancelling && (
        <Modal title={`Cancel #${sale.sale_no}?`} onClose={() => setCancelling(false)}
          footer={<><button type="button" className="btn btn-outline" onClick={() => setCancelling(false)}>Back</button>
            <button type="button" className="btn btn-primary" disabled={busy || !reason.trim()} onClick={async () => { if (await toStage('cancelled', { reason })) setCancelling(false); }}>Cancel the sale</button></>}>
          <label className="pe-field"><span>Why? (required)</span><input className="form-input" autoFocus value={reason} onChange={e => setReason(e.target.value)} /></label>
        </Modal>
      )}
      {confirming && <ConfirmDelivery delivery={confirming} who={buyer} branchId={sale.branch_id} onClose={() => setConfirming(null)} onDone={async () => { setConfirming(null); await onChanged(); }} />}
    </Modal>
  );
}

/** Hand goods over: line by line what leaves, up to what is still to deliver and the value paid */
function DeliveryModal({ sale, refs, money, doneOf, canLeave, per, onClose, onSaved }) {
  // what is in the finished-goods store now, per product and colour (2026-10-26)
  const [inStore, setInStore] = useState(null);
  useEffect(() => {
    supabase.rpc('sales_availability', { p_branch_id: sale.branch_id }).then(({ data }) =>
      setInStore(Object.fromEntries((data || []).map(x => [`${x.product_id}|${x.color_id ?? ''}`, Number(x.on_hand)]))));
  }, [sale.branch_id]);
  const lines = [...(sale.lines || [])].sort((a, b) => a.line_no - b.line_no).filter(l => l.product_id).map(l => ({ ...l, left: r2(Number(l.quantity) - doneOf(l.id)) })).filter(l => l.left > 0);
  const unitInc = l => Number(l.total) / Number(l.quantity);
  const [kind, setKind] = useState('collection');
  // filled in from the start: everything still to deliver, as far as the payments cover it (2026-10-26)
  const [qty, setQty] = useState(() => {
    let room = canLeave; const next = {};
    for (const l of lines) {
      const unit = Number(l.total) / Number(l.quantity);
      const q = Math.max(0, Math.min(l.left, Math.floor((room / unit) * 100) / 100));
      next[l.id] = q > 0 ? String(q) : ''; room -= Math.round(unit * q * 100) / 100;
    }
    return next;
  });
  const needEfd = Number(sale.vat) > 0;
  const [efdNo, setEfdNo] = useState(sale.efd_receipt_no ?? '');
  const [checked, setChecked] = useState(false);
  const [receivedBy, setReceivedBy] = useState(sale.walk_in_name ?? '');
  const [vehicle, setVehicle] = useState('');
  const [driver, setDriver] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const value = lines.reduce((t, l) => t + r2(unitInc(l) * (num(qty[l.id]) ?? 0)), 0);
  const stockKey = l => `${l.product_id}|${l.color_id ?? ''}`;
  const leaving = {};
  for (const l of lines) leaving[stockKey(l)] = (leaving[stockKey(l)] || 0) + (num(qty[l.id]) ?? 0);
  const tooMuch = inStore ? Object.entries(leaving).filter(([k, q]) => q > (inStore[k] ?? 0) + 1e-9).map(([k, q]) => {
    const l = lines.find(y => stockKey(y) === k);
    return { k, q, store: Math.max(inStore[k] ?? 0, 0), name: `${refs.items[`p:${l.product_id}`]?.name ?? ''}${l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}` };
  }) : [];
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
    if (tooMuch.length) { setError(`Not enough in the store: ${tooMuch.map(x => `${x.name} — ${qtyText(x.q)} leaving, ${qtyText(x.store)} in store`).join('; ')}.`); return; }
    if (value > canLeave + 0.01) { setError(`Goods worth ${money(canLeave)} can leave — record a payment first.`); return; }
    if (needEfd && !efdNo.trim()) { setError('This sale carries VAT — enter the EFD receipt number.'); return; }
    if (needEfd && !checked) { setError('Check the EFD receipt shows these amounts, then tick the box.'); return; }
    setBusy(true);
    // a delivery: who receives it is asked when it is confirmed delivered, not now
    const { data: did, error: err } = await supabase.rpc('record_sale_delivery', { p_sale: sale.id, p: { kind, received_by: kind === 'collection' ? receivedBy : '', vehicle, ...(needEfd ? { efd_receipt_no: efdNo.trim() } : {}),
      lines: lines.filter(l => num(qty[l.id]) > 0).map(l => ({ sale_line_id: l.id, quantity: num(qty[l.id]) })) } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't record this. Please try again.")); return; }
    if (kind === 'delivery' && driver.trim() && did) await supabase.rpc('set_delivery_trip', { p_delivery: did, p: { driver: driver.trim() } });
    onSaved();
  }
  return (
    <Modal title={`Goods leaving on #${sale.sale_no}`} onClose={onClose} size="lg"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Back</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || tooMuch.length > 0 || inStore === null} onClick={save} title={kind === 'delivery' ? 'The goods leave the store; confirm Delivered on the sale when they arrive' : 'The goods leave the store'}>Confirm</button></>}>
      <div className="modal-form">
        <div className="flex items-center gap-8" role="group" aria-label="How it leaves">
          <button type="button" className={`filter-chip${kind === 'collection' ? ' is-on' : ''}`} onClick={() => setKind('collection')}>Collected by the customer</button>
          <button type="button" className={`filter-chip${kind === 'delivery' ? ' is-on' : ''}`} onClick={() => setKind('delivery')}>We deliver</button>
          <span className="pl-help" style={{ marginLeft: 'auto' }}>Paid for, not yet taken: <strong>{money(canLeave)}</strong></span>
        </div>
        <table className="rd-table">
          <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Left to deliver</th><th style={{ textAlign: 'right' }}>In store</th><th style={{ textAlign: 'right' }}>Leaving now</th><th style={{ textAlign: 'right' }}>Value</th></tr></thead>
          <tbody>
            {lines.map(l => (
              <tr key={l.id}>
                <td><strong>{refs.items[`p:${l.product_id}`]?.name}{l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}</strong></td>
                <td style={{ textAlign: 'right' }}>{qtyText(l.left)} {per(l.product_id)}</td>
                <td style={{ textAlign: 'right' }} className={tooMuch.some(x => x.k === stockKey(l)) ? 'text-error' : ''}>{inStore ? `${qtyText(r2(Math.max(inStore[stockKey(l)] ?? 0, 0)))} ${per(l.product_id)}` : '…'}</td>
                <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 100 }} value={qty[l.id]} onChange={e => setQty({ ...qty, [l.id]: e.target.value })} /></td>
                <td style={{ textAlign: 'right' }}>{num(qty[l.id]) > 0 ? money(r2(unitInc(l) * num(qty[l.id]))) : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {tooMuch.length > 0 && (
          <div className="alert alert-error" role="alert">
            <strong>Not enough in the store</strong> — {tooMuch.map(x => `${x.name}: ${qtyText(r2(x.q))} leaving, ${qtyText(r2(x.store))} in store`).join('; ')}. Lower the quantity, or wait for stock (curing to be released).
          </div>
        )}
        <div className="flex items-center gap-8">
          <button type="button" className="btn btn-ghost btn-sm" onClick={fillPaid}>Fill what is paid for</button>
          <span style={{ marginLeft: 'auto' }}><strong>{money(r2(value))}</strong> leaving</span>
        </div>
        <div className="form-row">
          {needEfd && (
            <div className="sl-efd">
              <label className="pe-field"><span>EFD receipt no. (required — this sale carries VAT)</span><input className="form-input" value={efdNo} onChange={e => setEfdNo(e.target.value)} /></label>
              <p className="text-sm">Check the EFD receipt shows: total <strong>{money(Number(sale.total))}</strong> · VAT <strong>{money(Number(sale.vat))}</strong> · without VAT <strong>{money(Number(sale.subtotal))}</strong></p>
              <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={checked} onChange={e => setChecked(e.target.checked)} /> The EFD receipt shows these amounts</label>
            </div>
          )}
          {/* minimal (2026-11-11, the user): collected — who took it and the truck; delivered — the driver and the truck */}
          {kind === 'collection' && <label className="pe-field"><span>Collected by</span><input className="form-input" value={receivedBy} onChange={e => setReceivedBy(e.target.value)} /></label>}
          {kind === 'delivery' && <label className="pe-field"><span>Driver</span><input className="form-input" value={driver} onChange={e => setDriver(e.target.value)} /></label>}
          <label className="pe-field"><span>Truck plate no.</span><input className="form-input" placeholder="e.g. T 123 ABC" value={vehicle} data-no-caps onChange={e => setVehicle(e.target.value.toUpperCase())} /></label>
        </div>
      </div>
    </Modal>
  );
}

/**
 * Sales at a glance for a period (2026-10-26): sold (orders and invoices by
 * their date), paid in, still owed (all open), delivered and its margin
 * (without VAT less the stock's cost; the estimated part marked) — by
 * product and by customer. Figures as saved; nothing re-priced here.
 */
function SalesOverview({ sales, refs, customers, money, currency, today, buyerOf }) {
  const [period, setPeriod] = useSessionPeriod('sales-overview');   // this month first (2026-11-09)
  const [from, to] = periodRange(period, today);
  const inP = d => d >= from && d <= to;
  const live = sales.filter(x => x.stage === 'order' || x.stage === 'invoice');
  const sold = live.filter(x => inP(x.sale_date));
  const payments = live.flatMap(x => (x.payments || []).map(pm => ({ ...pm, sale: x }))).filter(pm => inP(pm.paid_on));
  const deliveries = live.flatMap(x => (x.deliveries || []).map(d => ({ ...d, sale: x }))).filter(d => inP(d.delivered_on));
  const owed = live.reduce((t, x) => t + Number(x.total) - (x.payments || []).reduce((u, pm) => u + Number(pm.amount), 0), 0);
  const lineOf = Object.fromEntries(live.flatMap(x => x.lines || []).map(l => [l.id, l]));
  const dl = deliveries.flatMap(d => (d.lines || []).map(x => ({ ...x, line: lineOf[x.sale_line_id], sale: d.sale })));
  const exOf = x => Number(x.value) / (1 + Number(x.line?.vat_rate ?? 0) / 100);
  const sum = (a, f) => a.reduce((t, x) => t + f(x), 0);
  const delivered = { value: sum(deliveries, d => Number(d.value)), ex: sum(dl, exOf), cost: sum(dl, x => Number(x.cost ?? 0)), est: sum(dl, x => Number(x.estimated_cost ?? 0)) };
  const queued = sales.filter(x => x.stage === 'quotation' && inP(x.sale_date));

  // by product: sold (orders + invoices), delivered, margin on delivered
  const byProduct = {};
  const prow = (l) => (byProduct[l.product_id ? `${l.product_id}|${l.color_id ?? ''}` : `other|${(l.item_name ?? '').trim().toLowerCase()}`] ||= { name: l.product_id ? `${refs.items[`p:${l.product_id}`]?.name ?? '—'}${l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}` : `${l.item_name} (other item)`,
    unit: !l.product_id ? '' : (refs.unitById[refs.items[`p:${l.product_id}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM' ? 'm²' : 'pcs', qty: 0, value: 0, dqty: 0, ex: 0, cost: 0, est: 0 });
  for (const x of sold) for (const l of x.lines || []) { const pr = prow(l); pr.qty += Number(l.quantity); pr.value += Number(l.total); }
  for (const x of dl) { if (!x.line) continue; const pr = prow(x.line); pr.dqty += Number(x.quantity); pr.ex += exOf(x); pr.cost += Number(x.cost ?? 0); pr.est += Number(x.estimated_cost ?? 0); }
  // by customer: sold, paid, owed (all open)
  const byCustomer = {};
  const crow = x => (byCustomer[x.customer_id ?? `walk:${x.walk_in_name ?? ''}`] ||= { name: buyerOf(x), sold: 0, paid: 0, owed: 0 });
  for (const x of sold) crow(x).sold += Number(x.total);
  for (const pm of payments) crow(pm.sale).paid += Number(pm.amount);
  for (const x of live) { const o = Number(x.total) - sum(x.payments || [], pm => Number(pm.amount)); if (o > 0.004) crow(x).owed += o; }

  const pct = (a, b) => (b > 0 ? ` · ${Math.round((a / b) * 100)}%` : '');
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Sold</span><strong className="mm-money">{money(sum(sold, x => Number(x.total)))}</strong><span className="pl-help">{sold.length} sale{sold.length === 1 ? '' : 's'} · with VAT</span></div>
        <div className="mm-stat"><span className="pl-label">Paid in</span><strong className="mm-money">{money(sum(payments, pm => Number(pm.amount)))}</strong><span className="pl-help">{payments.length} payment{payments.length === 1 ? '' : 's'}</span></div>
        <div className="mm-stat"><span className="pl-label">Owed now</span><strong className={`mm-money${owed > 0.004 ? ' text-warning' : ''}`}>{money(Math.max(owed, 0))}</strong><span className="pl-help">open orders & invoices</span></div>
        <div className="mm-stat"><span className="pl-label">Delivered</span><strong className="mm-money">{money(delivered.value)}</strong>
          <span className="pl-help" title={delivered.est > 0.5 ? `${money(delivered.est)} of the cost is estimated (stock with no production cost)` : undefined}>margin {formatMoneyShort(delivered.ex - delivered.cost, currency)}{pct(delivered.ex - delivered.cost, delivered.ex)}{delivered.est > 0.5 ? ' · est.' : ''}</span></div>
      </div>
      <div className="flex items-center gap-8" style={{ marginBottom: 8 }}>
        <PeriodBar value={period} onChange={setPeriod} today={today} extra={[['30', 'Last 30 days'], ['90', 'Last 90 days'], ['all', 'All time']]} />
      </div>
      {queued.length > 0 && <p className="pl-help" style={{ margin: '0 0 8px' }}>{queued.length} quotation{queued.length === 1 ? '' : 's'} not ordered · {money(sum(queued, x => Number(x.total)))}</p>}
      <div className="so-grid">
        <section className="card">
          <div className="card-header"><h2 className="card-title">By product</h2></div>
          <div className="table-container"><table>
            <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Sold</th><th style={{ textAlign: 'right' }}>Value</th><th style={{ textAlign: 'right' }}>Delivered</th><th style={{ textAlign: 'right' }}>Margin</th></tr></thead>
            <tbody>{Object.values(byProduct).length === 0 ? <tr><td colSpan={5} className="text-muted">Nothing sold in this period.</td></tr>
              : Object.values(byProduct).sort((a, b) => b.value - a.value).map(x => (
                <tr key={x.name}><td style={{ fontWeight: 500 }}>{x.name}</td>
                  <td style={{ textAlign: 'right' }}>{qtyText(r2(x.qty))} {x.unit}</td>
                  <td style={{ textAlign: 'right' }}>{money(r2(x.value))}</td>
                  <td style={{ textAlign: 'right' }}>{x.dqty > 0 ? `${qtyText(r2(x.dqty))} ${x.unit}` : '—'}</td>
                  <td style={{ textAlign: 'right' }}>{x.dqty > 0 ? <>{money(r2(x.ex - x.cost))}{x.est > 0.5 && <div className="co-est-txt text-xs">cost partly estimated</div>}</> : '—'}</td></tr>
              ))}</tbody>
          </table></div>
        </section>
        <section className="card">
          <div className="card-header"><h2 className="card-title">By customer</h2></div>
          <div className="table-container"><table>
            <thead><tr><th>Customer</th><th style={{ textAlign: 'right' }}>Sold</th><th style={{ textAlign: 'right' }}>Paid</th><th style={{ textAlign: 'right' }}>Owed now</th></tr></thead>
            <tbody>{Object.values(byCustomer).length === 0 ? <tr><td colSpan={4} className="text-muted">No customers in this period.</td></tr>
              : Object.values(byCustomer).sort((a, b) => b.sold - a.sold || b.owed - a.owed).map(x => (
                <tr key={x.name}><td style={{ fontWeight: 500 }}>{x.name}</td>
                  <td style={{ textAlign: 'right' }}>{money(r2(x.sold))}</td>
                  <td style={{ textAlign: 'right' }}>{money(r2(x.paid))}</td>
                  <td style={{ textAlign: 'right' }} className={x.owed > 0.004 ? 'text-warning' : ''}>{x.owed > 0.004 ? money(r2(x.owed)) : '—'}</td></tr>
              ))}</tbody>
          </table></div>
        </section>
      </div>
    </>
  );
}

/**
 * The sales book (2026-10-26), as the tenant keeps it: newest day on top, the
 * date once per day; one row per item — customer, item, quantity, rate,
 * amount; the amount under With VAT (and its VAT) or Without VAT; the money
 * under the account that received it (on the sale's first row); receipt no.;
 * site. Click a row for the sale. Totals at the foot.
 */
function SalesBook({ sales, refs, accounts, money, currency, today, buyerOf, proofs = {}, onOpen, canProof = () => false, organizationId, onChanged }) {
  // rows show plain amounts; the currency is in the headers and on the totals (2026-10-26)
  const cur = currency ? ` (${currency})` : '';
  // opened from a dashboard card: that card's period (?from=&to=&label=)
  const [params] = useSearchParams();
  const sentRange = params.get('from') && params.get('to') ? [params.get('from'), params.get('to')] : null;
  const known = sentRange && keyForRange(sentRange[0], sentRange[1], today);   // one of the usual choices opens on it
  const urlRange = known ? null : sentRange;
  const [savedPeriod, setSavedPeriod] = useSessionPeriod('sales-book');   // this month first (2026-11-09), remembered until the app closes
  const [cardPeriod, setCardPeriod] = useState(known || (urlRange ? 'range' : null));   // a dashboard card's period, on arrival
  const period = cardPeriod ?? savedPeriod;
  const setPeriod = v => { setCardPeriod(null); setSavedPeriod(v); };
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('newest');     // newest | oldest | amount
  const [delivery, setDelivery] = useState('');       // '' | not | part | done
  const [payment, setPayment] = useState('');         // '' | owed | paid
  const [account, setAccount] = useState('');         // '' | an account id
  const [vat, setVat] = useState('');                 // '' | with | without
  const [from, to] = period === 'range' && urlRange ? urlRange : periodRange(period, today);
  // delivered so far, per line (065)
  const doneOf = (x, lineId) => (x.deliveries || []).reduce((t, d) => t + (d.lines || []).filter(y => y.sale_line_id === lineId).reduce((u, y) => u + Number(y.quantity), 0), 0);
  const stateOf = (x, l) => { if (!l.product_id) return 'done';   // an other item: handed over with the sale (104)
    const d = doneOf(x, l.id); if (d <= 1e-9) return 'not'; if (d + 1e-9 < Number(l.quantity)) return 'part';
    // all of it has left the store: on the way until a delivery carrying it is confirmed (096)
    // collected until a delivery carrying it is confirmed delivered (2026-11-11, the user); a customer's own collection stays collected
    return (x.deliveries || []).some(dv => dv.status === 'on_the_way' && (dv.lines || []).some(y => y.sale_line_id === l.id)) || byCustomer(x, l) ? 'collected' : 'done'; };
  const byCustomer = (x, l) => (x.deliveries || []).filter(dv => (dv.lines || []).some(y => y.sale_line_id === l.id)).every(dv => dv.kind === 'collection');
  const paidOf = x => (x.payments || []).reduce((t, pm) => t + Number(pm.amount), 0);
  const nameOf = l => (l.product_id ? `${refs.items[`p:${l.product_id}`]?.name ?? ''}${l.color_id ? ` ${refs.colorById[l.color_id]?.name ?? ''}` : ''}` : l.item_name ?? '');
  const accName = id => accounts.find(a => a.id === id)?.name ?? '';
  // smart search: number, customer, phone, item, site, receipt no., EFD, account
  const q = search.trim().toLowerCase();
  const matches = x => !q || [`#${x.sale_no}`, String(x.sale_no), buyerOf(x), x.walk_in_phone, x.site, x.efd_receipt_no,
    ...(x.lines || []).map(nameOf), ...(x.payments || []).flatMap(pm => [pm.receipt_no, accName(pm.account_id)])]
    .filter(Boolean).some(t => String(t).toLowerCase().includes(q));
  const lineOk = (x, l) => (!delivery || stateOf(x, l) === delivery) && (!vat || (vat === 'with') === (Number(l.vat_rate) > 0));
  const inPeriod = sales.filter(x => x.sale_date >= from && x.sale_date <= to && matches(x)
      && (!payment || (payment === 'owed') === (Number(x.total) - paidOf(x) > 0.004))
      && (!account || (x.payments || []).some(pm => pm.account_id === account))
      && (x.lines || []).some(l => lineOk(x, l)))
    .sort((a, b) => (sortBy === 'amount' ? Number(b.total) - Number(a.total) : 0)
      || (sortBy === 'oldest' ? a.sale_date.localeCompare(b.sale_date) || a.sale_no - b.sale_no : b.sale_date.localeCompare(a.sale_date) || b.sale_no - a.sale_no));
  // account columns: the branch's accounts, plus "Other" for payments without one
  const cols = [...accounts.filter(a => a.status === 'active' || inPeriod.some(x => (x.payments || []).some(pm => pm.account_id === a.id)))];
  const hasOther = inPeriod.some(x => (x.payments || []).some(pm => !pm.account_id));
  const per = id => ((refs.unitById[refs.items[`p:${id}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM' ? 'm²' : 'pcs');
  const rows = [];
  let lastDate = null;
  let saleIdx = 0;
  // sales with several products are shaded; when they follow one another, every other one stays plain so each
  // block stands apart (2026-10-26); a run starts shaded again after a single-item sale
  let prevShaded = false;
  for (const x of inPeriod) {
    const lines = [...(x.lines || [])].sort((a, b) => a.line_no - b.line_no).filter(l => lineOk(x, l));
    const shade = lines.length > 1 && !prevShaded;
    if (lines.length) prevShaded = shade;
    // paid per item (070): every payment names its item → each row shows its own; else the sale's money is merged across its rows
    const perItem = (x.payments || []).length > 0 && (x.payments || []).every(pm => pm.sale_line_id);
    lines.forEach((l, i) => {
      // the date once per day when the book runs by date; on every sale's first row when sorted by amount
      rows.push({ x, l, first: i === 0, last: i === lines.length - 1, span: lines.length, perItem, band: saleIdx % 2, multi: lines.length > 1, shade,
        showDate: sortBy === 'amount' ? i === 0 : x.sale_date !== lastDate });
      lastDate = x.sale_date;
    });
    if (lines.length) saleIdx += 1;
  }
  const paidTo = (x, accId, lineId) => (x.payments || []).filter(pm => (accId === 'other' ? !pm.account_id : pm.account_id === accId) && (!lineId || pm.sale_line_id === lineId)).reduce((t, pm) => t + Number(pm.amount), 0);
  const slips = (x, lineId) => (x.payments || []).filter(pm => !lineId || pm.sale_line_id === lineId).map(pm => pm.receipt_no).filter(Boolean).join(', ');
  const sum = f => rows.reduce((t, row) => t + f(row), 0);
  const vatOn = l => Number(l.vat_rate) > 0;
  return (
    <>
      <ListToolbar id="book-search" search={search} onSearch={setSearch} placeholder="Search customer, item, site, receipt no., account, phone or #…"
        sort={{ value: sortBy, onChange: setSortBy, options: [{ value: 'newest', label: 'Newest first' }, { value: 'oldest', label: 'Oldest first' }, { value: 'amount', label: 'Largest sale first' }] }}
        filters={[
          { key: 'delivery', label: 'Goods', value: delivery, onChange: setDelivery,
            options: [{ value: '', label: 'All' }, { value: 'not', label: 'Not collected' }, { value: 'part', label: 'Part collected' }, { value: 'collected', label: 'Collected' }, { value: 'done', label: 'Delivered' }] },
          { key: 'payment', label: 'Paid', value: payment, onChange: setPayment,
            options: [{ value: '', label: 'All' }, { value: 'owed', label: 'Still owed' }, { value: 'paid', label: 'Paid in full' }] },
          ...(accounts.length ? [{ key: 'account', label: 'Account', value: account, onChange: setAccount,
            options: [{ value: '', label: 'All accounts' }, ...accounts.map(a => ({ value: a.id, label: a.name }))] }] : []),
          { key: 'vat', label: 'VAT', value: vat, onChange: setVat,
            options: [{ value: '', label: 'All' }, { value: 'with', label: 'With VAT' }, { value: 'without', label: 'Without VAT' }] },
        ]} />
      <div className="sb-under-bar">
      <PeriodBar value={period} onChange={setPeriod} today={today} range={[from, to]} sentLabel={params.get('label') || 'Chosen period'} extra={[['30', 'Last 30 days'], ['90', 'Last 90 days'], ['all', 'All time']]} />
      </div>
      <div className="card"><div className="table-container">
        <table className="sb-table">
          <thead>
            <tr><th>Date</th><th>Customer</th><th>Item</th><th className="num">Qty</th><th className="num">Rate{cur}</th><th className="num">Amount{cur}</th>
              <th className="num">With VAT{cur}</th><th className="num">VAT{cur}</th><th className="num">Without VAT{cur}</th>
              {cols.map((a, i) => <th key={a.id} className={`num sb-acc${i === 0 ? ' sb-acc-start' : ''}`}>{a.name}</th>)}{hasOther && <th className={`num sb-acc${cols.length ? '' : ' sb-acc-start'}`}>Other</th>}
              <th>Receipt no.</th><th>Site</th><th>Goods</th></tr>
          </thead>
          <tbody>
            {rows.length === 0 ? <tr><td colSpan={12 + cols.length + (hasOther ? 1 : 0)} className="text-muted">{q || delivery || payment || account || vat ? 'Nothing matches — change the search or filters.' : 'No sales in this period. Record sale adds one.'}</td></tr>
            : rows.map(({ x, l, first, last, span, perItem, band, multi, shade, showDate }) => (
              <tr key={l.id} className={`clickable-row sb-band-${band}${showDate ? ' sb-day' : ''}${first ? ' sb-first' : ''}${last ? ' sb-last' : ''}${multi ? ' sb-multi' : ''}${shade ? ' sb-shade' : ''}`} onClick={() => onOpen(x.id)}>
                <td>{showDate ? tableDate(x.sale_date) : ''}</td>
                {first && <td rowSpan={span} className="sb-merge">
                  {buyerOf(x)}{multi && <div className="sb-items">{span} items</div>}
                  {/* only what needs doing shows: a proof to add, or waiting for a director (2026-11-08) */}
                  {(() => { const a = saleApproval(x, proofs, today); return ['proof', 'waiting'].includes(a.state) ? <div><span className={`badge ${a.badge} sb-approval`}>{a.label}</span></div> : null; })()}</td>}
                <td>{nameOf(l)}{!l.product_id && <span className="pl-help"> · other item</span>}</td>
                <td className="num">{l.product_id ? <>{qtyText(Number(l.quantity))} <span className="pl-help">{per(l.product_id)}</span></> : ''}</td>
                <td className="num">{formatAmount(r2(Number(l.total) / Number(l.quantity)))}</td>
                <td className="num">{formatAmount(Number(l.total))}</td>
                <td className="num">{vatOn(l) ? formatAmount(Number(l.total)) : ''}</td>
                <td className="num">{vatOn(l) ? formatAmount(Number(l.vat)) : ''}</td>
                <td className="num">{vatOn(l) ? '' : formatAmount(Number(l.total))}</td>
                {perItem ? <>
                  {cols.map((a, i) => <td key={a.id} className={`num${i === 0 ? ' sb-acc-start' : ''}`}>{paidTo(x, a.id, l.id) > 0 ? formatAmount(paidTo(x, a.id, l.id)) : ''}</td>)}
                  {hasOther && <td className={`num${cols.length ? '' : ' sb-acc-start'}`}>{paidTo(x, 'other', l.id) > 0 ? formatAmount(paidTo(x, 'other', l.id)) : ''}</td>}
                  <td>{slips(x, l.id)}{first && Number(x.vat) > 0 && !x.efd_receipt_no && <div><span className="badge badge-warning sb-approval" title="This sale carries VAT: add its EFD receipt number">EFD to fill</span></div>}</td>
                </> : first && <>
                  {cols.map((a, i) => <td key={a.id} rowSpan={span} className={`num sb-merge${i === 0 ? ' sb-acc-start' : ''}`}>{paidTo(x, a.id) > 0 ? formatAmount(paidTo(x, a.id)) : ''}</td>)}
                  {hasOther && <td rowSpan={span} className={`num sb-merge${cols.length ? '' : ' sb-acc-start'}`}>{paidTo(x, 'other') > 0 ? formatAmount(paidTo(x, 'other')) : ''}</td>}
                  <td rowSpan={span} className="sb-merge">{slips(x)}{Number(x.vat) > 0 && !x.efd_receipt_no && <div><span className="badge badge-warning sb-approval" title="This sale carries VAT: add its EFD receipt number">EFD to fill</span></div>}</td>
                </>}
                {first && <td rowSpan={span} className="sb-merge">{x.site ?? ''}</td>}
                {/* has it left the store? (065) — all, part (how much) or not yet */}
                <td>{(() => { const st = stateOf(x, l); const d = doneOf(x, l.id);
                  return st === 'done' ? <span className="sb-del is-done">Delivered</span>
                    : st === 'collected' ? <span className="sb-del is-done" title="Left the store">Collected</span>
                    : st === 'part' ? <span className="sb-del is-part">Part — {qtyText(r2(d))} of {qtyText(Number(l.quantity))} {per(l.product_id)}</span>
                    : <span className="sb-del is-not">Not collected</span>; })()}</td>
              </tr>
            ))}
          </tbody>
          {rows.length > 0 && (
            <tfoot><tr>
              <td colSpan={5}><strong>Total</strong></td>
              <td className="num"><strong>{money(r2(sum(({ l }) => Number(l.total))))}</strong></td>
              <td className="num">{money(r2(sum(({ l }) => (vatOn(l) ? Number(l.total) : 0))))}</td>
              <td className="num">{money(r2(sum(({ l }) => (vatOn(l) ? Number(l.vat) : 0))))}</td>
              <td className="num">{money(r2(sum(({ l }) => (vatOn(l) ? 0 : Number(l.total)))))}</td>
              {cols.map((a, i) => <td key={a.id} className={`num${i === 0 ? ' sb-acc-start' : ''}`}><strong>{money(r2(sum(({ x, first }) => (first ? paidTo(x, a.id) : 0))))}</strong></td>)}
              {hasOther && <td className={`num${cols.length ? '' : ' sb-acc-start'}`}><strong>{money(r2(sum(({ x, first }) => (first ? paidTo(x, 'other') : 0))))}</strong></td>}
              <td colSpan={3} />
            </tr></tfoot>
          )}
        </table>
      </div></div>
    </>
  );
}

/**
 * Correct a sale (068): date, buyer, site, EFD receipt, notes; each line's
 * quantity and price (not below what was delivered; undelivered lines can be
 * removed); each payment's amount, account, date and receipt no. (or remove
 * it). A reason always. The Technical admin's applies at once; a manager's
 * goes to Approvals. Figures are worked out in the database.
 */
function CorrectModal({ sale, refs, accounts, money, today, per, direct, onClose, onDone }) {
  const doneOf = id => (sale.deliveries || []).reduce((t, d) => t + (d.lines || []).filter(y => y.sale_line_id === id).reduce((u, y) => u + Number(y.quantity), 0), 0);
  const inc = l => r2(Number(l.price) * (1 + Number(l.vat_rate) / 100));
  const [date, setDate] = useState(sale.sale_date);
  const [name, setName] = useState(sale.walk_in_name ?? '');
  const [phone, setPhone] = useState(sale.walk_in_phone ?? '');
  const [site, setSite] = useState(sale.site ?? '');
  const [efd, setEfd] = useState(sale.efd_receipt_no ?? '');
  const [lines, setLines] = useState(() => [...(sale.lines || [])].sort((a, b) => a.line_no - b.line_no)
    .map(l => ({ l, quantity: String(+l.quantity), price: String(inc(l)), remove: false, done: doneOf(l.id) })));
  const [pays, setPays] = useState(() => (sale.payments || []).map(pm => ({ pm, amount: String(+pm.amount), account_id: pm.account_id ?? '', paid_on: pm.paid_on, receipt_no: pm.receipt_no ?? '', remove: false })));
  const [added, setAdded] = useState([]);   // other items added by the correction (104): { name, price }
  // one transaction (user, 2026-11-03): a sale with one payment is paid as one — its amount follows the corrected total
  // unless the amount is typed (or this is unticked)
  const [oneTx, setOneTx] = useState(() => (sale.payments || []).length === 1);
  const newTotal = r2(lines.filter(x => !x.remove).reduce((t, x) => t + (x.l.product_id ? (num(x.quantity) ?? 0) * (num(x.price) ?? 0) : (num(x.price) ?? 0)), 0)
    + added.reduce((t, a) => t + (num(a.price) ?? 0), 0));
  const payAmount = x => (oneTx && pays.length === 1 && !x.remove ? String(newTotal) : x.amount);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);

  async function save() {
    setError('');
    if (!reason.trim()) { setError('Give the reason for the correction.'); return; }
    const ch = {};
    if (date !== sale.sale_date) ch.sale_date = date;
    if (!sale.customer_id && (name !== (sale.walk_in_name ?? '') || phone !== (sale.walk_in_phone ?? ''))) { ch.walk_in_name = name; ch.walk_in_phone = phone; }
    if (site !== (sale.site ?? '')) ch.site = site;
    if (efd !== (sale.efd_receipt_no ?? '')) ch.efd_receipt_no = efd;
    const lc = lines.filter(x => x.remove || num(x.quantity) !== Number(x.l.quantity) || num(x.price) !== inc(x.l))
      .map(x => (x.remove ? { id: x.l.id, remove: true }
        : { id: x.l.id, product_id: x.l.product_id, color_id: x.l.color_id, quantity: num(x.quantity), price: num(x.price) }));   // the price charged a unit (069)
    if (added.some(a => !a.name.trim() || !(num(a.price) > 0))) { setError('Write what each added item is, and its price.'); return; }
    lc.push(...added.map(a => ({ item_name: a.name.trim(), price: num(a.price) })));
    if (lc.length) ch.lines = lc;
    const pays2 = pays.map(x => ({ ...x, amount: payAmount(x) }));
    const pc = pays2.filter(x => x.remove || num(x.amount) !== Number(x.pm.amount) || x.account_id !== (x.pm.account_id ?? '') || x.paid_on !== x.pm.paid_on || x.receipt_no !== (x.pm.receipt_no ?? ''))
      .map(x => (x.remove ? { id: x.pm.id, remove: true } : { id: x.pm.id, amount: num(x.amount), ...(x.account_id ? { account_id: x.account_id } : {}), paid_on: x.paid_on, receipt_no: x.receipt_no }));
    if (pc.length) ch.payments = pc;
    if (!Object.keys(ch).length) { setError('Nothing has changed.'); return; }
    setBusy(true);
    const { data, error: err } = await supabase.rpc('correct_sale', { p_sale: sale.id, p_changes: ch, p_reason: reason.trim() });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't correct this sale. Please try again.")); return; }
    if (data?.request_id) setSent(true); else onDone();
  }

  if (sent) return (
    <Modal title={`Correction of #${sale.sale_no}`} onClose={onDone} footer={<button type="button" className="btn btn-primary" onClick={onDone}>Done</button>}>
      <p className="text-sm">Sent for approval — the sale changes once an admin approves it under <strong>Approvals</strong>.</p>
    </Modal>
  );
  return (
    <Modal title={`Correct #${sale.sale_no}`} onClose={onClose} size="xl"
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Back</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>{direct ? 'Correct' : 'Send for approval'}</button></>}>
      <div className="modal-form">
        <p className="text-xs text-muted">{direct ? 'Applies at once.' : 'Goes to Approvals.'} The old version is kept.</p>
        <div className="form-row">
          <label className="pe-field"><span>Date</span><input type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value)} /></label>
          <label className="pe-field"><span>Site</span><input className="form-input" value={site} onChange={e => setSite(e.target.value)} /></label>
          <label className="pe-field"><span>EFD receipt</span><input className="form-input" value={efd} onChange={e => setEfd(e.target.value)} /></label>
        </div>
        {!sale.customer_id && (
          <div className="form-row">
            <label className="pe-field"><span>Buyer</span><input className="form-input" value={name} onChange={e => setName(e.target.value)} /></label>
            <label className="pe-field"><span>Phone</span><input className="form-input" value={phone} onChange={e => setPhone(e.target.value)} /></label>
          </div>
        )}
        <table className="rd-table">
          <thead><tr><th>Product</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Price</th><th>Delivered</th><th /></tr></thead>
          <tbody>{lines.map((x, i) => (
            <tr key={x.l.id} className={x.remove ? 'text-muted' : ''}>
              <td><strong>{x.l.product_id ? refs.items[`p:${x.l.product_id}`]?.name : x.l.item_name}{x.l.color_id ? ` ${refs.colorById[x.l.color_id]?.name ?? ''}` : ''}</strong></td>
              <td style={{ textAlign: 'right' }}>{x.l.product_id ? <><NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} disabled={x.remove} value={x.quantity}
                onChange={e => setLines(ls => ls.map((y, j) => (j === i ? { ...y, quantity: e.target.value } : y)))} /> {per(x.l.product_id)}</> : <span className="pl-help">other item</span>}</td>
              <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} disabled={x.remove} value={x.price}
                onChange={e => setLines(ls => ls.map((y, j) => (j === i ? { ...y, price: e.target.value } : y)))} /></td>
              <td className="pl-help">{x.done > 0 ? `${qtyText(x.done)} ${per(x.l.product_id)}` : '—'}</td>
              <td>{x.done === 0 && <label className="text-xs flex items-center gap-4"><input type="checkbox" checked={x.remove} onChange={e => setLines(ls => ls.map((y, j) => (j === i ? { ...y, remove: e.target.checked } : y)))} /> remove</label>}</td>
            </tr>
          ))}
          {added.map((a, i) => (
            <tr key={`add${i}`} className="sl-other">
              <td><input className="form-input" placeholder="What is it? e.g. vipande" aria-label="Other item" value={a.name} onChange={e => setAdded(as => as.map((y, j) => (j === i ? { ...y, name: e.target.value } : y)))} /></td>
              <td style={{ textAlign: 'right' }}><span className="pl-help">other item</span></td>
              <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} placeholder="Price" aria-label="Other item price" value={a.price} onChange={e => setAdded(as => as.map((y, j) => (j === i ? { ...y, price: e.target.value } : y)))} /></td>
              <td className="pl-help">no stock, no VAT</td>
              <td><button type="button" className="icon-btn" aria-label="Remove added item" onClick={() => setAdded(as => as.filter((_, j) => j !== i))}><Trash2 size={14} /></button></td>
            </tr>
          ))}</tbody>
        </table>
        <div><button type="button" className="btn btn-outline btn-sm" onClick={() => setAdded(as => [...as, { name: '', price: '' }])}><Plus size={13} /> Add other item</button></div>
        {pays.length === 1 && (
          <label className="text-sm flex items-center gap-4"><input type="checkbox" checked={oneTx} onChange={e => setOneTx(e.target.checked)} />
            Paid as one transaction — the payment follows the total ({money(newTotal)})</label>
        )}
        {pays.length > 0 && (
          <table className="rd-table">
            <thead><tr><th>Payment</th><th style={{ textAlign: 'right' }}>Amount</th><th>Into</th><th>Date</th><th>Receipt no.</th><th /></tr></thead>
            <tbody>{pays.map((x, i) => (
              <tr key={x.pm.id} className={x.remove ? 'text-muted' : ''}>
                <td>{tableDate(x.pm.paid_on)}</td>
                <td style={{ textAlign: 'right' }}><NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} disabled={x.remove} value={payAmount(x)}
                  onChange={e => { setOneTx(false); setPays(ps => ps.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y))); }} /></td>
                <td>{accounts.length ? (
                  <select className="form-input" disabled={x.remove} value={x.account_id} onChange={e => setPays(ps => ps.map((y, j) => (j === i ? { ...y, account_id: e.target.value } : y)))}>
                    <option value="">{METHODS[x.pm.method]}</option>
                    {accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
                  </select>) : METHODS[x.pm.method]}</td>
                <td><input type="date" className="form-input" max={today} disabled={x.remove} value={x.paid_on} onChange={e => setPays(ps => ps.map((y, j) => (j === i ? { ...y, paid_on: e.target.value } : y)))} /></td>
                <td><input className="form-input" style={{ width: 100 }} disabled={x.remove} value={x.receipt_no} onChange={e => setPays(ps => ps.map((y, j) => (j === i ? { ...y, receipt_no: e.target.value } : y)))} /></td>
                <td><label className="text-xs flex items-center gap-4"><input type="checkbox" checked={x.remove} onChange={e => setPays(ps => ps.map((y, j) => (j === i ? { ...y, remove: e.target.checked } : y)))} /> remove</label></td>
              </tr>
            ))}</tbody>
          </table>
        )}
        <label className="pe-field"><span>Reason (required)</span><input className="form-input" value={reason} placeholder="e.g. quantity typed wrong" onChange={e => setReason(e.target.value)} /></label>
      </div>
    </Modal>
  );
}
