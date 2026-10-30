import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dateText } from '../lib/format';

const qty = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(v);

/*
 * Goods received note (PRD 4.12, 2026-10-30), A4, in a tab of its own:
 *   /print/grn/:movementId
 * What came into the store on one receipt — each material and quantity as
 * counted, the store, the supplier and invoice when the purchase is recorded
 * (or "details to follow" for goods that came before the invoice) — with
 * signature lines for the storekeeper and the driver/supplier.
 */
export default function GoodsReceivedDocument() {
  const { id } = useParams();
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!session) return;
    (async () => {
      const { data: mv } = await supabase.from('inventory_movements').select('*').eq('id', id).maybeSingle();
      if (!mv) { setError("We couldn't find this receipt."); return; }
      const [org, br, wh, tx, pu, by] = await Promise.all([
        supabase.from('organizations').select('*').eq('id', mv.organization_id).maybeSingle(),
        supabase.from('branches').select('name').eq('id', mv.branch_id).maybeSingle(),
        supabase.from('warehouses').select('name').eq('id', mv.warehouse_id).maybeSingle(),
        supabase.from('inventory_transactions').select('id, material_id, product_id, entered_quantity, entered_unit_id, quantity, stock_unit_id')
          .eq('movement_id', id).eq('transaction_type', 'receipt').order('created_at'),
        supabase.from('purchases').select('id, supplier_id, invoice_reference, purchase_date, status, purchase_order_id').eq('movement_id', id).neq('status', 'void').maybeSingle(),
        mv.created_by ? supabase.from('profiles').select('first_name, last_name').eq('id', mv.created_by).maybeSingle() : Promise.resolve({ data: null }),
      ]);
      const supplierId = pu.data?.supplier_id ?? mv.supplier_id;
      const [sup, po, mats, units] = await Promise.all([
        supplierId ? supabase.from('suppliers').select('name').eq('id', supplierId).maybeSingle() : Promise.resolve({ data: null }),
        pu.data?.purchase_order_id ? supabase.from('purchase_orders').select('po_no').eq('id', pu.data.purchase_order_id).maybeSingle() : Promise.resolve({ data: null }),
        supabase.from('materials').select('id, name, code'),
        supabase.from('units').select('id, symbol'),
      ]);
      setD({ mv, org: org.data, branch: br.data?.name, store: wh.data?.name, tx: tx.data || [], purchase: pu.data, supplier: sup.data?.name, po: po.data?.po_no,
        by: by.data ? [by.data.first_name, by.data.last_name].filter(Boolean).join(' ') : null,
        mat: Object.fromEntries((mats.data || []).map(m => [m.id, m])), unit: Object.fromEntries((units.data || []).map(u => [u.id, u.symbol])) });
    })();
  }, [id, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;
  const { mv, org, purchase } = d;

  return (
    <div className="doc-page">
      <div className="doc-bar">
        <button type="button" className="btn btn-primary" onClick={() => window.print()}><Printer size={15} /> Print / Save as PDF</button>
        <span className="pl-help">Choose “Save as PDF” as the printer to keep a copy.</span>
      </div>
      <article className="doc">
        <header className="doc-head">
          <div className="doc-co">
            {org?.logo_url && <img src={org.logo_url} alt="" className="doc-logo" />}
            <div>
              <strong className="doc-co-name">{org?.legal_name || org?.name}</strong>
              {org?.address && <div>{org.address}</div>}
              <div>{[org?.tin && `TIN ${org.tin}`, d.branch].filter(Boolean).join(' · ')}</div>
            </div>
          </div>
          <div className="doc-title">
            <h1>Goods received note</h1>
            <div>GRN-{mv.id.slice(0, 8).toUpperCase()}</div>
            <div>Date: {dateText(mv.movement_date)}</div>
          </div>
        </header>

        <section className="doc-to">
          <span className="doc-label">From</span>
          <strong>{d.supplier || 'Supplier not recorded'}</strong>
          <div>{purchase ? [purchase.invoice_reference && `Invoice / delivery note ${purchase.invoice_reference}`, d.po && `PO #${d.po}`].filter(Boolean).join(' · ') || 'Purchase recorded'
            : 'Purchase details to follow'}</div>
          <div>Received into: {d.store || '—'}{mv.reference ? ` · ref ${mv.reference}` : ''}</div>
        </section>

        <section>
          <table className="doc-table">
            <thead><tr><th>#</th><th>Material</th><th className="num">Quantity received</th></tr></thead>
            <tbody>
              {d.tx.length === 0 && <tr><td colSpan={3}>Nothing on this receipt.</td></tr>}
              {d.tx.map((t, i) => (
                <tr key={t.id}>
                  <td>{i + 1}</td>
                  <td>{d.mat[t.material_id]?.name ?? '—'}</td>
                  <td className="num">{qty(Number(t.entered_quantity ?? t.quantity))} {d.unit[t.entered_unit_id ?? t.stock_unit_id] ?? ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {mv.notes && <p>{mv.notes}</p>}
        </section>

        <footer className="doc-foot">
          <div className="doc-sign"><span>Received by{d.by ? `: ${d.by}` : ''}</span><span>Delivered by (driver / supplier)</span><span>Date</span></div>
          <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
        </footer>
      </article>
    </div>
  );
}
