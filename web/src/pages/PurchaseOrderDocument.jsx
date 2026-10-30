import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney, dateText } from '../lib/format';
import { qtyText } from '../lib/inventory';

/*
 * A purchase order for the supplier (1c/077), A4, in a tab of its own:
 * /print/po/:id. Read as saved (PRD 4.12). Company details from Settings.
 */
export default function PurchaseOrderDocument() {
  const { id } = useParams();
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!session) return;
    (async () => {
      const { data: po } = await supabase.from('purchase_orders').select('*, lines:purchase_order_lines(*)').eq('id', id).maybeSingle();
      if (!po) { setError("We couldn't find this purchase order."); return; }
      const [org, br, sup, mats, units] = await Promise.all([
        supabase.from('organizations').select('*').eq('id', po.organization_id).maybeSingle(),
        supabase.from('branches').select('*').eq('id', po.branch_id).maybeSingle(),
        supabase.from('suppliers').select('*').eq('id', po.supplier_id).maybeSingle(),
        supabase.from('materials').select('id, name').in('id', po.lines.map(l => l.material_id).filter(Boolean)),
        supabase.from('units').select('id, symbol'),
      ]);
      setD({ po, org: org.data, branch: br.data, supplier: sup.data,
        mat: Object.fromEntries((mats.data || []).map(m => [m.id, m.name])), unit: Object.fromEntries((units.data || []).map(u => [u.id, u.symbol])) });
    })();
  }, [id, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;
  const { po, org, branch, supplier, mat, unit } = d;
  const money = v => formatMoney(v, org?.currency_code);
  const lines = [...po.lines].sort((a, b) => a.line_no - b.line_no);
  const priced = lines.some(l => l.unit_price != null || l.amount != null);
  const amountOf = l => (l.kind === 'expense' ? (l.amount != null ? Number(l.amount) : null) : l.unit_price != null ? Number(l.unit_price) * Number(l.quantity) : null);
  const total = lines.reduce((t, l) => t + (amountOf(l) ?? 0), 0);

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
              {branch && <div>Deliver to: {branch.name}{branch.location ? ` — ${branch.location}` : ''}</div>}
            </div>
          </div>
          <div className="doc-title">
            <h1>Purchase order</h1>
            <div><strong>PO #{po.po_no}</strong></div>
            <div>Date: {dateText(po.order_date)}</div>
            {po.expected_on && <div>Expected by: {dateText(po.expected_on)}</div>}
          </div>
        </header>
        <section className="doc-to">
          <span className="doc-label">Supplier</span>
          <strong>{supplier?.name}</strong>
          {supplier?.address && <div>{supplier.address}</div>}
          <div>{[supplier?.contact_person, supplier?.phone, supplier?.tax_id && `TIN ${supplier.tax_id}`].filter(Boolean).join(' · ')}</div>
        </section>
        <section>
          <table className="doc-table">
            <thead><tr><th>#</th><th>Item</th><th className="num">Quantity</th>{priced && <th className="num">Price</th>}{priced && <th className="num">Amount</th>}</tr></thead>
            <tbody>
              {lines.map(l => (
                <tr key={l.id}>
                  <td>{l.line_no}</td><td>{l.kind === 'expense' ? l.description : mat[l.material_id] ?? '—'}</td>
                  <td className="num">{l.quantity != null ? `${qtyText(Number(l.quantity))} ${l.kind === 'expense' ? l.unit_text ?? '' : unit[l.unit_id] ?? ''}` : ''}</td>
                  {priced && <td className="num">{l.unit_price != null ? money(Number(l.unit_price)) : ''}</td>}
                  {priced && <td className="num">{amountOf(l) != null ? money(amountOf(l)) : '—'}</td>}
                </tr>
              ))}
            </tbody>
          </table>
          {priced && <table className="doc-totals"><tbody><tr className="doc-grand"><td>Total</td><td className="num">{money(total)}</td></tr></tbody></table>}
          {po.notes && <p className="doc-note">{po.notes}</p>}
          <div className="doc-sign">
            <div><span>Ordered by</span></div>
            <div><span>Approved by</span></div>
            <div><span>Supplier's acceptance</span></div>
          </div>
        </section>
        <footer className="doc-foot">
          {org?.document_footer && <div className="doc-pre">{org.document_footer}</div>}
          <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
        </footer>
      </article>
    </div>
  );
}
