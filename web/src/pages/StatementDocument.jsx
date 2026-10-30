import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { formatMoney, formatAmount, dateText, tableDate } from '../lib/format';
import { orgToday } from '../lib/inventory';
import { loadOwing, statementLines, ageByBuyer, AGE_BUCKETS } from '../lib/receivables';

/*
 * A customer's statement (1e, 2026-10-27), A4, in a tab of its own:
 *   /print/statement/:customerId?from=YYYY-MM-DD&to=YYYY-MM-DD
 * Balance brought forward, each order/invoice and payment with the running
 * balance, the balance due and how old it is. Read as saved (PRD 4.12).
 */
export default function StatementDocument() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!session) return;
    (async () => {
      const { data: customer } = await supabase.from('customers').select('*').eq('id', id).maybeSingle();
      if (!customer) { setError("We couldn't find this customer."); return; }
      try {
        const [org, sales] = await Promise.all([
          supabase.from('organizations').select('*').eq('id', customer.organization_id).maybeSingle(),
          loadOwing({ customerId: id }),
        ]);
        setD({ customer, org: org.data, sales });
      } catch { setError("We couldn't load this statement."); }
    })();
  }, [id, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;

  const { customer, org, sales } = d;
  const money = v => formatMoney(v, org?.currency_code);
  const today = orgToday(org?.timezone);
  const to = params.get('to') || today;
  const from = params.get('from') || null;
  const st = statementLines(sales, from, to);
  const age = ageByBuyer(sales.filter(s => (s.ordered_on || s.invoiced_on || s.sale_date) <= to), [customer], to)[0];

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
            </div>
          </div>
          <div className="doc-title">
            <h1>Statement of account</h1>
            <div>Date: {dateText(to)}</div>
            <div>Period: {from ? `${dateText(from)} to ${dateText(to)}` : `up to ${dateText(to)}`}</div>
          </div>
        </header>

        <section className="doc-to">
          <span className="doc-label">Customer</span>
          <strong>{customer.name}</strong>
          {customer.address && <div>{customer.address}</div>}
          <div>{[customer.phone, customer.tin && `TIN ${customer.tin}`, customer.vrn && `VRN ${customer.vrn}`].filter(Boolean).join(' · ')}</div>
        </section>

        <section>
          <table className="doc-table">
            <thead><tr><th>Date</th><th>Details</th><th className="num">Charged</th><th className="num">Paid</th><th className="num">Balance</th></tr></thead>
            <tbody>
              {from && <tr><td>{tableDate(from)}</td><td>Balance brought forward</td><td /><td /><td className="num">{formatAmount(st.opening)}</td></tr>}
              {st.rows.length === 0 && <tr><td colSpan={5}>Nothing in this period.</td></tr>}
              {st.rows.map((m, i) => (
                <tr key={i}>
                  <td>{tableDate(m.date)}</td><td>{m.ref}</td>
                  <td className="num">{m.charge ? formatAmount(m.charge) : ''}</td>
                  <td className="num">{m.paid ? formatAmount(m.paid) : ''}</td>
                  <td className="num">{formatAmount(m.balance)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <table className="doc-totals"><tbody>
            {from && <tr><td>Brought forward</td><td className="num">{money(st.opening)}</td></tr>}
            <tr><td>Charged in the period</td><td className="num">{money(st.charged)}</td></tr>
            <tr><td>Paid in the period</td><td className="num">{money(st.paid)}</td></tr>
            <tr className="doc-grand"><td>Balance due</td><td className="num">{money(st.closing)}</td></tr>
          </tbody></table>
          {age && age.owed > 0 && (
            <table className="doc-table" style={{ marginTop: 10 }}>
              <thead><tr>{AGE_BUCKETS.map(([, , l]) => <th key={l} className="num">{l}</th>)}<th className="num">Total due</th></tr></thead>
              <tbody><tr>{age.buckets.map((v, i) => <td key={i} className="num">{v ? formatAmount(v) : '—'}</td>)}<td className="num"><strong>{formatAmount(age.owed)}</strong></td></tr></tbody>
            </table>
          )}
          {st.closing > 0 && org?.bank_details && <section className="doc-pay"><span className="doc-label">How to pay</span><div className="doc-pre">{org.bank_details}</div></section>}
        </section>

        <footer className="doc-foot">
          {org?.document_footer && <div className="doc-pre">{org.document_footer}</div>}
          <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
        </footer>
      </article>
    </div>
  );
}
