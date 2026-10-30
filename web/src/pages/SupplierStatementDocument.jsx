import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney, formatAmount, dateText } from '../lib/format';
import { orgToday } from '../lib/inventory';

/*
 * A supplier's statement (PRD 4.12, 2026-10-30), A4, in a tab of its own:
 *   /print/supplier-statement/:supplierId?from=YYYY-MM-DD&to=YYYY-MM-DD
 * What we were billed (purchases and expenses from them) and what we paid,
 * with the running balance owed to them — the other side of the customer
 * statement. Read as saved.
 */
export default function SupplierStatementDocument() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!session) return;
    (async () => {
      const { data: supplier } = await supabase.from('suppliers').select('*').eq('id', id).maybeSingle();
      if (!supplier) { setError("We couldn't find this supplier."); return; }
      const [org, pu, ex] = await Promise.all([
        supabase.from('organizations').select('*').eq('id', supplier.organization_id).maybeSingle(),
        supabase.from('purchases').select('id, purchase_date, invoice_reference, status, payments:purchase_payments(paid_on, amount, reference)').eq('supplier_id', id).eq('status', 'recorded'),
        supabase.from('expenses').select('id, expense_date, description, amount, amount_paid, paid_on, status').eq('supplier_id', id).eq('status', 'recorded'),
      ]);
      const ids = (pu.data || []).map(p => p.id);
      const tot = ids.length ? await supabase.from('purchase_totals').select('purchase_id, total').in('purchase_id', ids) : { data: [] };
      const totalOf = Object.fromEntries((tot.data || []).map(t => [t.purchase_id, Number(t.total)]));
      // every charge and payment, oldest first
      const moves = [];
      for (const p of pu.data || []) {
        moves.push({ date: p.purchase_date, ref: `Purchase${p.invoice_reference ? ` ${p.invoice_reference}` : ''}`, charge: totalOf[p.id] ?? 0, paid: 0 });
        for (const pay of p.payments || []) moves.push({ date: pay.paid_on, ref: `Payment${pay.reference ? ` ${pay.reference}` : ''}${p.invoice_reference ? ` — ${p.invoice_reference}` : ''}`, charge: 0, paid: Number(pay.amount) });
      }
      for (const e of ex.data || []) {
        moves.push({ date: e.expense_date, ref: e.description, charge: Number(e.amount), paid: 0 });
        if (Number(e.amount_paid) > 0) moves.push({ date: e.paid_on || e.expense_date, ref: `Payment — ${e.description}`, charge: 0, paid: Number(e.amount_paid) });
      }
      moves.sort((a, b) => a.date.localeCompare(b.date) || b.charge - a.charge);
      setD({ supplier, org: org.data, moves });
    })();
  }, [id, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;

  const { supplier, org, moves } = d;
  const money = v => formatMoney(Math.round(v * 100) / 100, org?.currency_code);
  const to = params.get('to') || orgToday(org?.timezone);
  const from = params.get('from') || null;
  const opening = from ? moves.filter(m => m.date < from).reduce((t, m) => t + m.charge - m.paid, 0) : 0;
  let bal = opening;
  const rows = moves.filter(m => (!from || m.date >= from) && m.date <= to).map(m => { bal += m.charge - m.paid; return { ...m, balance: bal }; });
  const charged = rows.reduce((t, m) => t + m.charge, 0);
  const paid = rows.reduce((t, m) => t + m.paid, 0);

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
              <div>{[org?.tin && `TIN ${org.tin}`, org?.vrn && `VRN ${org.vrn}`].filter(Boolean).join(' · ')}</div>
            </div>
          </div>
          <div className="doc-title">
            <h1>Supplier statement</h1>
            <div>Date: {dateText(to)}</div>
            <div>Period: {from ? `${dateText(from)} to ${dateText(to)}` : `up to ${dateText(to)}`}</div>
          </div>
        </header>

        <section className="doc-to">
          <span className="doc-label">Supplier</span>
          <strong>{supplier.name}</strong>
          <div>{[supplier.contact_person, supplier.phone, supplier.email].filter(Boolean).join(' · ')}</div>
        </section>

        <section>
          <table className="doc-table">
            <thead><tr><th>Date</th><th>Details</th><th className="num">Billed</th><th className="num">Paid</th><th className="num">Owed</th></tr></thead>
            <tbody>
              {from && <tr><td>{dateText(from)}</td><td>Balance brought forward</td><td /><td /><td className="num">{formatAmount(opening)}</td></tr>}
              {rows.length === 0 && <tr><td colSpan={5}>Nothing in this period.</td></tr>}
              {rows.map((m, i) => (
                <tr key={i}><td>{dateText(m.date)}</td><td>{m.ref}</td>
                  <td className="num">{m.charge ? formatAmount(m.charge) : ''}</td><td className="num">{m.paid ? formatAmount(m.paid) : ''}</td>
                  <td className="num">{formatAmount(m.balance)}</td></tr>
              ))}
            </tbody>
          </table>
          <table className="doc-totals"><tbody>
            {from && <tr><td>Brought forward</td><td className="num">{money(opening)}</td></tr>}
            <tr><td>Billed in the period</td><td className="num">{money(charged)}</td></tr>
            <tr><td>Paid in the period</td><td className="num">{money(paid)}</td></tr>
            <tr className="doc-grand"><td>Owed to {supplier.name}</td><td className="num">{money(opening + charged - paid)}</td></tr>
          </tbody></table>
        </section>

        <footer className="doc-foot">
          <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
        </footer>
      </article>
    </div>
  );
}
