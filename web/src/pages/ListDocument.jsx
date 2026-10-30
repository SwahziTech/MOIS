import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { loadInventoryRefs, orgToday, mainUnitOf, byMaterialOrder } from '../lib/inventory';
import { formatAmount, dateText, tableDate } from '../lib/format';

const qty = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);
const amt = v => formatAmount(Math.round(Number(v || 0)));
const TITLE = { stock: 'Stock list', prices: 'Price list', attendance: 'Attendance sheet', purchases: 'Purchase record' };
const days = (from, to) => { const out = []; for (let d = new Date(`${from}T00:00:00Z`); d <= new Date(`${to}T00:00:00Z`) && out.length < 62; d.setUTCDate(d.getUTCDate() + 1)) out.push(d.toISOString().slice(0, 10)); return out; };

/*
 * Printed lists (Document Center › Print lists, 2026-10-30), A4, in a tab of their own:
 *   /print/list/stock?branch=                  products by colour and materials on hand now
 *   /print/list/prices?branch=                 selling prices with VAT (per m² or per piece, as the product is sold)
 *   /print/list/attendance?branch=&from=&to=   who worked each day (up to 62 days)
 *   /print/list/purchases?branch=&from=&to=    each purchase: supplier, invoice, total, paid, to pay
 * Read as saved; nothing is changed.
 */
export default function ListDocument() {
  const { kind } = useParams();
  const [params] = useSearchParams();
  const branchId = params.get('branch');
  const { session, organization, loading: authLoading } = useAuth();
  const today = orgToday(organization?.timezone);
  const from = params.get('from') || `${today.slice(0, 7)}-01`;
  const to = params.get('to') || today;
  const [d, setD] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!session || !branchId || !TITLE[kind]) return;
    setD(null); setError('');
    const load = { stock: loadStock, prices: loadPrices, attendance: loadAttendance, purchases: loadPurchases }[kind];
    Promise.all([supabase.from('organizations').select('*').eq('id', organization.id).maybeSingle(), supabase.from('branches').select('name').eq('id', branchId).maybeSingle(), load({ branchId, from, to })])
      .then(([o, b, x]) => setD({ key: `${kind}|${branchId}|${from}|${to}`, org: o.data ?? organization, branch: b.data?.name, ...x }))
      .catch(e => { console.error(e); setError("We couldn't put this list together."); });
  }, [session, kind, branchId, from, to]); // eslint-disable-line react-hooks/exhaustive-deps

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this list.</div>;
  if (!TITLE[kind] || !branchId) return <div className="doc-msg">Open this list from Document Center › Print lists.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d || d.key !== `${kind}|${branchId}|${from}|${to}`) return <div className="doc-msg">Loading…</div>;
  const dated = kind === 'attendance' || kind === 'purchases';
  const { org } = d;

  return (
    <div className="doc-page">
      <div className="doc-bar">
        <button type="button" className="btn btn-primary" onClick={() => window.print()}><Printer size={15} /> Print / Save as PDF</button>
        <span className="pl-help">Choose “Save as PDF” as the printer to keep a copy.</span>
      </div>
      <article className={`doc${kind === 'attendance' ? ' doc-wide' : ''}`}>
        <header className="doc-head">
          <div className="doc-co">
            {org?.logo_url && <img src={org.logo_url} alt="" className="doc-logo" />}
            <div>
              <strong className="doc-co-name">{org?.legal_name || org?.name}</strong>
              <div>{d.branch}</div>
            </div>
          </div>
          <div className="doc-title">
            <h1>{TITLE[kind]}</h1>
            <div>{dated ? `${dateText(from)} to ${dateText(to)}` : `As of ${dateText(today)}`}</div>
          </div>
        </header>

        {kind === 'stock' && d.groups.map(g => (
          <section key={g.title}>
            <h3 className="doc-label">{g.title}</h3>
            <table className="doc-table">
              <thead><tr><th>#</th><th>Item</th><th className="num">On hand</th><th className="num">Counted</th></tr></thead>
              <tbody>{g.rows.map((r, i) => <tr key={r.key}><td>{i + 1}</td><td>{r.name}</td><td className="num">{qty(r.qty)} {r.unit}</td><td /></tr>)}</tbody>
            </table>
          </section>
        ))}

        {kind === 'prices' && d.groups.map(g => (
          <section key={g.title}>
            <h3 className="doc-label">{g.title}</h3>
            <table className="doc-table">
              <thead><tr><th>Product</th><th className="num">Price (TZS)</th><th>Per</th><th>VAT</th></tr></thead>
              <tbody>{g.rows.map(r => <tr key={r.key}><td>{r.name}</td><td className="num">{amt(r.price)}</td><td>{r.per}</td><td>{r.vat}</td></tr>)}</tbody>
            </table>
          </section>
        ))}
        {kind === 'prices' && <p>Prices include VAT where shown. Some colours cost more — ask for the colour price.</p>}

        {kind === 'attendance' && (
          <section>
            <table className="doc-table doc-att">
              <thead><tr><th>Name</th>{d.days.map(x => <th key={x} className="num">{Number(x.slice(8))}</th>)}<th className="num">Days</th></tr></thead>
              <tbody>{d.people.map(p => (
                <tr key={p.id}><td>{p.name}</td>{d.days.map(x => <td key={x} className="num">{p.at[x] == null ? '' : p.at[x] === 1 ? '✓' : p.at[x] === 0.5 ? '½' : qty(p.at[x])}</td>)}<td className="num"><strong>{qty(p.total)}</strong></td></tr>
              ))}</tbody>
            </table>
            {d.people.length === 0 && <p>Nobody recorded as working in this period.</p>}
            {d.cut && <p>Only the first 62 days are shown.</p>}
          </section>
        )}

        {kind === 'purchases' && (
          <section>
            <table className="doc-table">
              <thead><tr><th>Date</th><th>Supplier</th><th>Invoice</th><th className="num">Total (TZS)</th><th className="num">Paid (TZS)</th><th className="num">To pay (TZS)</th></tr></thead>
              <tbody>{d.rows.map(r => <tr key={r.id}><td>{tableDate(r.date)}</td><td>{r.supplier}</td><td>{r.ref}</td><td className="num">{amt(r.total)}</td><td className="num">{amt(r.paid)}</td><td className="num">{r.balance > 0 ? amt(r.balance) : ''}</td></tr>)}</tbody>
              <tfoot><tr><td colSpan={3}><strong>Total ({d.rows.length})</strong></td><td className="num"><strong>{amt(d.rows.reduce((t, r) => t + r.total, 0))}</strong></td><td className="num"><strong>{amt(d.rows.reduce((t, r) => t + r.paid, 0))}</strong></td><td className="num"><strong>Tsh {amt(d.rows.reduce((t, r) => t + Math.max(r.balance, 0), 0))}</strong></td></tr></tfoot>
            </table>
            {d.rows.length === 0 && <p>No purchases in this period.</p>}
          </section>
        )}

        <footer className="doc-foot">
          <div className="doc-sign"><span>Prepared by</span><span>Checked by</span><span>Date</span></div>
          <div className="doc-gen">{org?.legal_name || org?.name} · prepared with MOIS</div>
        </footer>
      </article>
    </div>
  );
}

async function loadStock({ branchId }) {
  const [refs, bal] = await Promise.all([loadInventoryRefs(), supabase.from('stock_balances').select('product_id, material_id, color_id, quantity').eq('branch_id', branchId)]);
  if (bal.error) throw bal.error;
  const sum = {};
  for (const b of bal.data || []) { const k = b.material_id ? `m:${b.material_id}` : `p:${b.product_id}|${b.color_id ?? ''}`; sum[k] = (sum[k] || 0) + Number(b.quantity); }
  const prod = {}; const mats = [];
  for (const [k, q] of Object.entries(sum)) {
    if (Math.abs(q) < 1e-9) continue;
    if (k.startsWith('m:')) {
      const it = refs.items[k]; if (!it) continue;
      const mu = mainUnitOf(it);
      mats.push({ key: k, it, name: it.name, qty: mu ? q / mu.factor : q, unit: refs.unitById[mu ? mu.id : it.stockUnitId]?.symbol ?? '' });
    } else {
      const [p, c] = k.split('|'); const it = refs.items[p]; if (!it) continue;
      const colour = c ? refs.colorById[c]?.name : null;
      (prod[it.category ?? 'Products'] ||= []).push({ key: k, name: `${it.name}${colour ? ` — ${colour}` : ''}`, qty: q, unit: refs.unitById[it.stockUnitId]?.symbol ?? '' });
    }
  }
  const groups = Object.entries(prod).sort(([a], [b]) => a.localeCompare(b)).map(([title, rows]) => ({ title, rows: rows.sort((a, b) => a.name.localeCompare(b.name)) }));
  if (mats.length) groups.push({ title: 'Materials', rows: mats.sort((a, b) => byMaterialOrder(a.it, b.it)) });
  return { groups };
}

async function loadPrices({ branchId }) {
  const [pr, prods] = await Promise.all([
    supabase.from('product_branch_pricing').select('product_id, color_id, is_available, price_per_unit_inclusive, price_per_sqm_inclusive, vat_rate').eq('branch_id', branchId).is('color_id', null).eq('is_available', true),
    supabase.from('products').select('id, canonical_name, status, unit:units(symbol), category:product_categories(name, sort_order)'),
  ]);
  if (pr.error) throw pr.error;
  const byId = Object.fromEntries((prods.data || []).map(p => [p.id, p]));
  const g = {};
  for (const r of pr.data || []) {
    const p = byId[r.product_id]; if (!p || p.status !== 'active') continue;
    const sqm = r.price_per_sqm_inclusive != null;
    const price = sqm ? r.price_per_sqm_inclusive : r.price_per_unit_inclusive; if (price == null) continue;
    const cat = p.category?.name ?? 'Products';
    (g[cat] ||= { order: p.category?.sort_order ?? 999, rows: [] }).rows.push({ key: p.id, name: p.canonical_name, price, per: sqm ? 'm²' : (p.unit?.symbol?.toUpperCase() === 'SQM' ? 'm²' : 'piece'), vat: Number(r.vat_rate) === 0 ? 'no VAT' : 'incl.' });
  }
  return { groups: Object.entries(g).sort(([, a], [, b]) => a.order - b.order).map(([title, x]) => ({ title, rows: x.rows.sort((a, b) => a.name.localeCompare(b.name)) })) };
}

async function loadAttendance({ branchId, from, to }) {
  const [at, st] = await Promise.all([
    supabase.from('staff_attendance').select('staff_id, work_date, day_fraction').eq('branch_id', branchId).gte('work_date', from).lte('work_date', to),
    supabase.from('staff').select('id, full_name'),
  ]);
  if (at.error) throw at.error;
  const all = days(from, to);
  const name = Object.fromEntries((st.data || []).map(s => [s.id, s.full_name]));
  const m = {};
  for (const a of at.data || []) { const p = (m[a.staff_id] ||= { id: a.staff_id, name: name[a.staff_id] ?? '—', at: {}, total: 0 }); const f = Number(a.day_fraction ?? 1); p.at[a.work_date] = (p.at[a.work_date] || 0) + f; p.total += f; }
  return { days: all, cut: all.length >= 62 && all[all.length - 1] < to, people: Object.values(m).sort((a, b) => a.name.localeCompare(b.name)) };
}

async function loadPurchases({ branchId, from, to }) {
  const [pu, su] = await Promise.all([
    supabase.from('purchases').select('id, purchase_date, supplier_id, invoice_reference, status').eq('branch_id', branchId).neq('status', 'void').gte('purchase_date', from).lte('purchase_date', to).order('purchase_date', { ascending: false }),
    supabase.from('suppliers').select('id, name'),
  ]);
  if (pu.error) throw pu.error;
  const ids = (pu.data || []).map(p => p.id);
  const tot = ids.length ? await supabase.from('purchase_totals').select('purchase_id, total, amount_paid, balance').in('purchase_id', ids) : { data: [] };
  const t = Object.fromEntries((tot.data || []).map(x => [x.purchase_id, x]));
  const sup = Object.fromEntries((su.data || []).map(s => [s.id, s.name]));
  return { rows: (pu.data || []).map(p => ({ id: p.id, date: p.purchase_date, supplier: sup[p.supplier_id] ?? '—', ref: p.invoice_reference ?? '', total: Number(t[p.id]?.total || 0), paid: Number(t[p.id]?.amount_paid || 0), balance: Number(t[p.id]?.balance || 0) })) };
}
