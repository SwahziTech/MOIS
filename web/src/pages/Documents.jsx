import { useEffect, useMemo, useState } from 'react';
import { Printer, FileText } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatAmount, dateText, tableDate } from '../lib/format';
import { useUrlTab } from '../lib/urlTab';
import PageShell from '../components/PageShell';
import { PageTabs, ListToolbar, ChipRow } from '../components/ListControls';
import ErrorState from '../components/ErrorState';
import EmptyState from '../components/EmptyState';

const amt = v => (v == null ? '' : formatAmount(Math.round(Number(v))));
const openDoc = url => window.open(url, '_blank', 'noopener');
const SHOW = 300;

/*
 * Documents (Document Center, 2026-10-30): find any document MOIS prints and
 * open it again — the same print pages the other screens open, read as saved.
 *   Sales       — quotations, proformas (orders), invoices, payment receipts, delivery notes;
 *   Purchasing  — goods received notes, purchase orders;
 *   Payslips    — each pay sheet's payslips.
 * Newest first, at the branch in the sidebar; search by number, name or reference.
 * Customer and supplier statements are on Finance › Statements.
 */
export default function Documents() {
  const { can } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const tabs = [...(can('sales.view') ? [['sales', 'Sales']] : []), ...(can('procurement.view') ? [['purchasing', 'Purchasing']] : []), ...(can('staff.view') ? [['payslips', 'Payslips']] : [])];
  const [tab, setTab] = useUrlTab(tabs[0]?.[0] ?? 'sales');
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [kind, setKind] = useState('');

  useEffect(() => {
    let live = true; setRows(null); setError(''); setKind('');
    const load = { sales: loadSales, purchasing: loadPurchasing, payslips: loadPayslips }[tab];
    if (!load) { setRows([]); return undefined; }
    load().then(r => live && setRows(r)).catch(e => { console.error(e); if (live) { setError("We couldn't load the documents."); setRows([]); } });
    return () => { live = false; };
  }, [tab]);

  const here = useMemo(() => (rows || []).filter(r => inBranch(r.branch_id)), [rows, inBranch]);
  const kinds = [...new Set(here.map(r => r.kind))];
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return here.filter(r => (!kind || r.kind === kind) && (!q || `${r.number} ${r.who ?? ''} ${r.ref ?? ''}`.toLowerCase().includes(q)));
  }, [here, kind, search]);

  return (
    <PageShell title="Documents" subtitle="Document Center"
      description={`Find and print any invoice, receipt, delivery note, goods received note, purchase order or payslip — ${branchId ? branchName : 'all branches'}.`}>
      {tabs.length > 1 && <PageTabs tabs={tabs} value={tab} onChange={t => { setTab(t); setSearch(''); }} />}
      {tabs.length === 0 ? <div className="card"><EmptyState icon={FileText} title="No documents for you" description="Your role doesn't open sales, purchasing or payroll." /></div> : (
        <>
          <div className="mm-stats">
            <div className="mm-stat"><span className="pl-label">Documents</span><strong>{rows ? here.length : '—'}</strong><span className="pl-help">{branchId ? branchName : 'all branches'}</span></div>
            <div className="mm-stat"><span className="pl-label">Newest</span><strong className="text-base">{dateText(here[0]?.date) ?? '—'}</strong><span className="pl-help">{here[0] ? `${here[0].kind} ${here[0].number}` : ''}</span></div>
            <div className="mm-stat"><span className="pl-label">Kinds</span><strong>{kinds.length}</strong><span className="pl-help">{kinds.join(', ')}</span></div>
          </div>
          <ListToolbar id="docs-search" search={search} onSearch={setSearch} placeholder="Search number, name or reference…" />
          {kinds.length > 1 && <ChipRow value={kind} onChange={setKind} items={kinds.map(k => ({ id: k, label: k }))} />}
          <div className="card"><div className="table-container">
            {error ? <ErrorState message={error} /> : (
              <table>
                <thead><tr><th>Date</th><th>Document</th><th>Number</th><th>{tab === 'payslips' ? 'Pay sheet' : tab === 'purchasing' ? 'Supplier' : 'Customer'}</th><th>Reference</th><th className="num">Amount (TZS)</th><th aria-label="Print" /></tr></thead>
                <tbody>
                  {rows === null ? <tr><td colSpan={7}><span className="skeleton" /></td></tr>
                  : shown.length === 0 ? <tr><td colSpan={7} className="text-muted">{search || kind ? 'Nothing matches.' : 'No documents yet.'}</td></tr>
                  : shown.slice(0, SHOW).map(r => (
                    <tr key={r.key} className="clickable-row" onClick={() => openDoc(r.url)} title="Open to print">
                      <td>{tableDate(r.date)}</td><td>{r.kind}</td><td>{r.number}</td><td>{r.who ?? ''}</td><td className="text-sm">{r.ref ?? ''}</td>
                      <td className="num">{amt(r.amount)}</td>
                      <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-ghost btn-sm" onClick={e => { e.stopPropagation(); openDoc(r.url); }}><Printer size={13} /> Print</button></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div></div>
          {shown.length > SHOW && <p className="pl-help" style={{ marginTop: 8 }}>Showing the newest {SHOW} of {shown.length} — search to find older ones.</p>}
        </>
      )}
    </PageShell>
  );
}

const byNewest = rows => rows.sort((a, b) => (a.date === b.date ? String(b.at).localeCompare(String(a.at)) : a.date < b.date ? 1 : -1));
const buyer = s => s?.customer?.name ?? s?.walk_in_name ?? 'Walk-in';

async function loadSales() {
  const [s, p, d] = await Promise.all([
    supabase.from('sales').select('id, sale_no, stage, branch_id, sale_date, invoiced_on, total, efd_receipt_no, walk_in_name, created_at, customer:customers(name)').neq('stage', 'cancelled'),
    supabase.from('sale_payments').select('id, paid_on, amount, receipt_no, created_at, sale:sales!inner(id, sale_no, branch_id, walk_in_name, customer:customers(name))'),
    supabase.from('sale_deliveries').select('id, delivery_no, delivered_on, kind, created_at, sale:sales!inner(id, sale_no, branch_id, walk_in_name, site, customer:customers(name))'),
  ]);
  if (s.error) throw s.error;
  const DOC = { quotation: ['Quotation', 'quotation'], order: ['Proforma', 'proforma'], invoice: ['Invoice', 'invoice'] };
  return byNewest([
    ...(s.data || []).map(x => ({ key: `s${x.id}`, branch_id: x.branch_id, date: x.stage === 'invoice' ? (x.invoiced_on ?? x.sale_date) : x.sale_date, at: x.created_at,
      kind: DOC[x.stage][0], number: `#${x.sale_no}`, who: buyer(x), ref: x.efd_receipt_no ? `EFD ${x.efd_receipt_no}` : '', amount: x.total, url: `/print/sale/${x.id}?doc=${DOC[x.stage][1]}` })),
    ...(p.error ? [] : p.data || []).map(x => ({ key: `p${x.id}`, branch_id: x.sale.branch_id, date: x.paid_on, at: x.created_at,
      kind: 'Receipt', number: x.receipt_no || `on #${x.sale.sale_no}`, who: buyer(x.sale), ref: `Sale #${x.sale.sale_no}`, amount: x.amount, url: `/print/sale/${x.sale.id}?doc=receipt&payment=${x.id}` })),
    ...(d.error ? [] : d.data || []).map(x => ({ key: `d${x.id}`, branch_id: x.sale.branch_id, date: x.delivered_on, at: x.created_at,
      kind: 'Delivery note', number: `DN-${x.delivery_no ?? '—'}`, who: buyer(x.sale), ref: [`Sale #${x.sale.sale_no}`, x.sale.site].filter(Boolean).join(' · '), amount: null, url: `/print/sale/${x.sale.id}?doc=delivery&delivery=${x.id}` })),
  ]);
}

async function loadPurchasing() {
  const [pu, aw, po, su] = await Promise.all([
    supabase.from('purchases').select('id, movement_id, branch_id, supplier_id, purchase_date, invoice_reference, created_at, status').neq('status', 'void').not('movement_id', 'is', null),
    supabase.from('receipts_awaiting_purchase').select('movement_id, branch_id, supplier_id, movement_date, reference, created_at'),
    supabase.from('purchase_orders').select('id, po_no, branch_id, supplier_id, order_date, status, created_at'),
    supabase.from('suppliers').select('id, name'),
  ]);
  if (pu.error) throw pu.error;
  const tot = await supabase.from('purchase_totals').select('purchase_id, total');
  const totalOf = Object.fromEntries((tot.data || []).map(t => [t.purchase_id, t.total]));
  const name = id => (su.data || []).find(x => x.id === id)?.name ?? '';
  return byNewest([
    ...(pu.data || []).map(x => ({ key: `g${x.movement_id}`, branch_id: x.branch_id, date: x.purchase_date, at: x.created_at,
      kind: 'Goods received', number: `GRN-${x.movement_id.slice(0, 8).toUpperCase()}`, who: name(x.supplier_id), ref: x.invoice_reference ? `Invoice ${x.invoice_reference}` : '', amount: totalOf[x.id], url: `/print/grn/${x.movement_id}` })),
    ...(aw.error ? [] : aw.data || []).map(x => ({ key: `g${x.movement_id}`, branch_id: x.branch_id, date: x.movement_date, at: x.created_at,
      kind: 'Goods received', number: `GRN-${x.movement_id.slice(0, 8).toUpperCase()}`, who: name(x.supplier_id), ref: x.reference ? `${x.reference} · details to follow` : 'details to follow', amount: null, url: `/print/grn/${x.movement_id}` })),
    ...(po.error ? [] : po.data || []).map(x => ({ key: `o${x.id}`, branch_id: x.branch_id, date: x.order_date, at: x.created_at,
      kind: 'Purchase order', number: `PO #${x.po_no}`, who: name(x.supplier_id), ref: x.status, amount: null, url: `/print/po/${x.id}` })),
  ]);
}

async function loadPayslips() {
  const r = await supabase.from('pay_sheets').select('id, branch_id, cycle, period_start, period_end, status, total, paid_on, created_at').neq('status', 'void');
  if (r.error) throw r.error;
  return byNewest((r.data || []).map(x => ({ key: x.id, branch_id: x.branch_id, date: x.period_end, at: x.created_at,
    kind: 'Payslips', number: `${dateText(x.period_start)} – ${dateText(x.period_end)}`, who: `${x.cycle ?? ''} pay sheet`.trim(), ref: x.status === 'paid' ? `paid ${dateText(x.paid_on) ?? ''}`.trim() : x.status, amount: x.total, url: `/print/payslips/${x.id}` })));
}
