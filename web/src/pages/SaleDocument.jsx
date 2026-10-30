import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney, dateText, dateTimeText } from '../lib/format';
import { qtyText } from '../lib/inventory';

const METHODS = { cash: 'Cash', mobile_money: 'Mobile money', bank: 'Bank' };
const r2 = n => Math.round(n * 100) / 100;

/*
 * A sale's printable documents (1e, 2026-10-26), A4, in a tab of their own:
 *   ?doc=quotation | proforma | invoice | receipt&payment=<id> | delivery&delivery=<id>
 * Every figure is read as saved — nothing is worked out here (PRD 4.12).
 * Company details from Settings → Company details for documents (066).
 */
export default function SaleDocument() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const doc = params.get('doc') || 'invoice';
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!session) return;
    (async () => {
      const { data: sale, error: err } = await supabase.from('sales')
        .select('*, lines:sale_lines(*), payments:sale_payments(*), deliveries:sale_deliveries(*, lines:sale_delivery_lines(*))').eq('id', id).maybeSingle();
      if (err || !sale) { setError("We couldn't find this sale."); return; }
      const ids = [...new Set(sale.lines.map(l => l.product_id))];
      const [org, br, cust, prods, cols] = await Promise.all([
        supabase.from('organizations').select('*').eq('id', sale.organization_id).maybeSingle(),
        supabase.from('branches').select('*').eq('id', sale.branch_id).maybeSingle(),
        sale.customer_id ? supabase.from('customers').select('*').eq('id', sale.customer_id).maybeSingle() : Promise.resolve({ data: null }),
        supabase.from('products').select('id, canonical_name, unit:units(symbol)').in('id', ids),
        supabase.from('color_palette').select('id, name'),
      ]);
      const ac = await supabase.from('payment_accounts').select('id, name').eq('branch_id', sale.branch_id);   // 067
      setD({ sale, org: org.data, branch: br.data, customer: cust.data,
        product: Object.fromEntries((prods.data || []).map(p => [p.id, p])), colour: Object.fromEntries((cols.data || []).map(c => [c.id, c.name])), account: Object.fromEntries((ac.data || []).map(a => [a.id, a.name])) });
    })();
  }, [id, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;

  const { sale, org, branch, customer, product, colour, account } = d;
  const money = v => formatMoney(v, org?.currency_code);
  const nameOf = l => `${product[l.product_id]?.canonical_name ?? '—'}${l.color_id ? ` ${colour[l.color_id] ?? ''}` : ''}`;
  const per = l => ((product[l.product_id]?.unit?.symbol ?? '').toUpperCase() === 'SQM' ? 'm²' : 'pcs');
  const lines = [...sale.lines].sort((a, b) => a.line_no - b.line_no);
  const paid = sale.payments.reduce((t, p) => t + Number(p.amount), 0);
  const payment = sale.payments.find(p => p.id === params.get('payment'));
  const delivery = sale.deliveries.find(x => x.id === params.get('delivery'));
  const buyer = customer ?? { name: sale.walk_in_name || 'Walk-in customer', phone: sale.walk_in_phone };
  const hasVat = Number(sale.vat) > 0;

  const title = { quotation: 'Quotation', proforma: 'Proforma invoice', invoice: hasVat ? 'Tax invoice' : 'Invoice', receipt: 'Payment receipt', delivery: 'Delivery note' }[doc];
  const number = doc === 'receipt' ? `R-${sale.sale_no}-${sale.payments.filter(p => p.created_at <= (payment?.created_at ?? '')).length}`
    : doc === 'delivery' ? `DN-${delivery?.delivery_no ?? '—'}` : `#${sale.sale_no}`;
  const date = doc === 'receipt' ? payment?.paid_on : doc === 'delivery' ? delivery?.delivered_on : doc === 'invoice' ? (sale.invoiced_on ?? sale.sale_date) : sale.sale_date;
  if ((doc === 'receipt' && !payment) || (doc === 'delivery' && !delivery)) return <div className="doc-msg">That {doc} isn&apos;t on this sale.</div>;

  return (
    <div className="doc-page">
      <div className="doc-bar">
        <button type="button" className="btn btn-primary" onClick={() => window.print()}><Printer size={15} /> Print / Save as PDF</button>
        <span className="pl-help">Choose “Save as PDF” as the printer to keep a copy or send it.</span>
      </div>
      <article className="doc">
        <header className="doc-head">
          <div className="doc-co">
            {org?.logo_url && <img src={org.logo_url} alt="" className="doc-logo" />}
            <div>
              <strong className="doc-co-name">{org?.legal_name || org?.name}</strong>
              {org?.address && <div>{org.address}</div>}
              <div>{[org?.phone, org?.email].filter(Boolean).join(' · ')}</div>
              <div>{[org?.tin && `TIN ${org.tin}`, org?.vrn && `VRN ${org.vrn}`].filter(Boolean).join(' · ')}</div>
              {branch && <div>Branch: {branch.name}{branch.location ? ` — ${branch.location}` : ''}</div>}
            </div>
          </div>
          <div className="doc-title">
            <h1>{title}</h1>
            <div><strong>{number}</strong></div>
            <div>Date: {dateText(date)}</div>
            {doc === 'quotation' && sale.valid_until && <div>Valid until: {dateText(sale.valid_until)}</div>}
            {(doc === 'invoice' || doc === 'receipt') && sale.efd_receipt_no && <div>EFD receipt: {sale.efd_receipt_no}</div>}
            {doc === 'receipt' && payment.receipt_no && <div>Receipt book no.: {payment.receipt_no}</div>}
            {(doc === 'receipt' || doc === 'delivery') && <div>For {sale.stage === 'invoice' ? 'invoice' : 'order'} #{sale.sale_no}</div>}
          </div>
        </header>

        <section className="doc-to">
          <span className="doc-label">{doc === 'delivery' ? 'Deliver to' : doc === 'receipt' ? 'Received from' : 'Bill to'}</span>
          <strong>{buyer.name}</strong>
          {buyer.address && <div>{buyer.address}</div>}
          <div>{[buyer.phone, buyer.tin && `TIN ${buyer.tin}`, buyer.vrn && `VRN ${buyer.vrn}`].filter(Boolean).join(' · ')}</div>
          {sale.site && <div>Site: {sale.site}</div>}
        </section>

        {doc === 'receipt' ? (
          <section className="doc-receipt">
            <p>Received with thanks the sum of <strong>{money(Number(payment.amount))}</strong> into {account[payment.account_id] ?? METHODS[payment.method]}{payment.reference ? ` (ref. ${payment.reference})` : ''}.</p>
            <table className="doc-table"><tbody>
              <tr><td>Total of {sale.stage === 'invoice' ? 'invoice' : 'order'} #{sale.sale_no}</td><td className="num">{money(Number(sale.total))}</td></tr>
              <tr><td>Paid up to and including this receipt</td><td className="num">{money(r2(sale.payments.filter(p => p.created_at <= payment.created_at).reduce((t, p) => t + Number(p.amount), 0)))}</td></tr>
              <tr><td><strong>Balance</strong></td><td className="num"><strong>{money(r2(Number(sale.total) - sale.payments.filter(p => p.created_at <= payment.created_at).reduce((t, p) => t + Number(p.amount), 0)))}</strong></td></tr>
            </tbody></table>
          </section>
        ) : doc === 'delivery' ? (
          <section>
            <table className="doc-table">
              <thead><tr><th>#</th><th>Product</th><th className="num">Quantity</th></tr></thead>
              <tbody>
                {(delivery.lines || []).map((x, i) => {
                  const l = lines.find(y => y.id === x.sale_line_id);
                  return <tr key={x.id}><td>{i + 1}</td><td>{l ? nameOf(l) : '—'}</td><td className="num">{qtyText(Number(x.quantity))} {l ? per(l) : ''}</td></tr>;
                })}
              </tbody>
            </table>
            <p>{delivery.kind === 'collection' ? 'Collected by the customer' : 'Delivery'}{sale.site ? ` · site: ${sale.site}` : ''}
              {delivery.driver ? ` · driver: ${delivery.driver}` : ''}{delivery.vehicle ? ` · vehicle: ${delivery.vehicle}` : ''}</p>
            {/* proof of delivery once confirmed (096) */}
            {delivery.kind === 'delivery' && delivery.status === 'delivered' && delivery.pod_received_by && (
              <p><strong>Delivered</strong> — received by {delivery.pod_received_by}
                {delivery.delivered_at ? `, ${dateTimeText(delivery.delivered_at)}` : ''}
                {delivery.pod_note ? ` · ${delivery.pod_note}` : ''}</p>
            )}
            <div className="doc-sign">
              <div><span>Issued by</span></div>
              <div><span>Received by{delivery.received_by ? `: ${delivery.received_by}` : ''}</span></div>
              <div><span>Date and time</span></div>
            </div>
          </section>
        ) : (
          <section>
            <table className="doc-table">
              <thead><tr><th>#</th><th>Product</th><th className="num">Quantity</th><th className="num">Price</th><th className="num">Amount</th></tr></thead>
              <tbody>
                {lines.map(l => (
                  <tr key={l.id}>
                    <td>{l.line_no}</td><td>{nameOf(l)}</td>
                    <td className="num">{qtyText(Number(l.quantity))} {per(l)}</td>
                    <td className="num">{money(r2(Number(l.total) / Number(l.quantity)))}</td>
                    <td className="num">{money(Number(l.total))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <table className="doc-totals"><tbody>
              {hasVat && <tr><td>Amount without VAT</td><td className="num">{money(Number(sale.subtotal))}</td></tr>}
              {hasVat && <tr><td>VAT</td><td className="num">{money(Number(sale.vat))}</td></tr>}
              <tr className="doc-grand"><td>Total{hasVat ? ' (incl. VAT)' : ''}</td><td className="num">{money(Number(sale.total))}</td></tr>
              {doc !== 'quotation' && paid > 0 && <tr><td>Paid</td><td className="num">{money(r2(paid))}</td></tr>}
              {doc !== 'quotation' && paid > 0 && <tr><td><strong>Balance</strong></td><td className="num"><strong>{money(r2(Number(sale.total) - paid))}</strong></td></tr>}
            </tbody></table>
            {doc !== 'invoice' || Number(sale.total) - paid > 0 ? (org?.bank_details && <section className="doc-pay"><span className="doc-label">How to pay</span><div className="doc-pre">{org.bank_details}</div></section>) : null}
          </section>
        )}

        {sale.notes && doc !== 'receipt' && <p className="doc-note">{sale.notes}</p>}
        <footer className="doc-foot">
          {org?.document_footer && <div className="doc-pre">{org.document_footer}</div>}
          <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
        </footer>
      </article>
    </div>
  );
}
