import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Plus, Trash2 } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { formatAmount, tableDate } from '../../lib/format';
import NumberInput from '../NumberInput';

const num = v => (String(v ?? '').trim() === '' ? null : Number(String(v).replace(/,/g, '')));
const r2 = n => Math.round(n * 100) / 100;
let seq = 0;
const blank = date => ({ key: `r${++seq}`, date, receipt: '', buyer: '', phone: '', productId: '', colorId: '', qty: '', price: '', paid: '', accountId: '', efd: '' });

/*
 * Sales sheet and past sales (2026-11-03, the user): the pages of the sales
 * book are kept with the day, and their rows typed into a grid beside them —
 * one row a product; rows with the same date and receipt number are one sale.
 * The price is the book's (what was charged); below the price list it is a
 * discount, as in Record sale. Nothing is saved as a sale here: each sale
 * opens in Sales › Record sale, filled in, and is saved the normal way.
 * Reading the pages by AI comes later and fills the same grid.
 */
export default function SalesUpload({ refs, branchId, today, day, past, keep, onStats }) {
  const { organization } = useAuth();
  const navigate = useNavigate();
  const [rows, setRows] = useState(() => Array.from({ length: 5 }, () => blank(past ? '' : day)));
  const [customers, setCustomers] = useState([]);
  const [accounts, setAccounts] = useState([]);
  const [listPrice, setListPrice] = useState({});   // product id → lowest price as paid (per m² or piece)
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    Promise.all([
      supabase.from('customers').select('id, name, phone, status').order('name'),
      supabase.from('payment_accounts').select('id, name, status, branch_id').eq('branch_id', branchId).order('display_order').order('name'),
      supabase.from('product_branch_pricing').select('product_id, price_per_sqm_inclusive, price_per_unit_inclusive, is_available').eq('branch_id', branchId),
    ]).then(([c, a, p]) => {
      setCustomers((c.data || []).filter(x => x.status === 'active'));
      setAccounts((a.data || []).filter(x => x.status === 'active'));
      const m = {};
      for (const x of p.data || []) {
        if (!x.is_available) continue;
        const sqm = (refs.unitById[refs.items[`p:${x.product_id}`]?.stockUnitId]?.symbol ?? '').toUpperCase() === 'SQM';
        const v = Number(sqm ? x.price_per_sqm_inclusive : x.price_per_unit_inclusive);
        if (v > 0) m[x.product_id] = Math.min(m[x.product_id] ?? v, v);
      }
      setListPrice(m);
    });
  }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  // the daily sheet is one day: its rows follow the day chosen above
  useEffect(() => { if (!past) setRows(rs => rs.map(r => ({ ...r, date: day }))); }, [day, past]);

  const carried = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .sort((a, b) => a.name.localeCompare(b.name)), [refs, branchId]);
  const productOf = id => refs.items[`p:${id}`];
  const used = r => !!(r.productId || num(r.qty) || r.buyer.trim() || num(r.paid) || r.receipt.trim());
  const customerOf = name => customers.find(c => c.name.trim().toLowerCase() === name.trim().toLowerCase());
  const set = (key, patch) => setRows(rs => rs.map(r => (r.key === key ? { ...r, ...patch } : r)));

  // rows → sales: same date and receipt number = one sale; the first row carries the buyer, account and EFD
  const sales = useMemo(() => {
    const out = []; const byKey = {};
    for (const r of rows.filter(used)) {
      const k = r.receipt.trim() ? `${r.date}|${r.receipt.trim().toLowerCase()}` : r.key;
      if (!byKey[k]) { byKey[k] = { key: k, first: r, rows: [] }; out.push(byKey[k]); }
      byKey[k].rows.push(r);
    }
    return out.map(s => {
      const value = r2(s.rows.reduce((t, r) => t + (num(r.qty) || 0) * (num(r.price) ?? listPrice[r.productId] ?? 0), 0));
      const paid = r2(s.rows.reduce((t, r) => t + (num(r.paid) || 0), 0));
      return { ...s, value, paid };
    });
  }, [rows, listPrice]); // eslint-disable-line react-hooks/exhaustive-deps
  const firstOf = r => sales.find(s => s.rows.includes(r))?.first;

  const missingOf = r => {
    if (!used(r)) return {};
    const first = firstOf(r) === r;
    const s = sales.find(x => x.rows.includes(r));
    return {
      date: !r.date || r.date > today,
      product: !r.productId,
      colour: !!r.productId && (productOf(r.productId)?.colorIds?.length ?? 0) > 0 && !r.colorId,
      qty: !(num(r.qty) > 0),
      account: first && s.paid > 0 && !r.accountId,
      over: first && s.paid > s.value + 0.01,
    };
  };
  const toType = rows.reduce((t, r) => t + Object.values(missingOf(r)).filter(Boolean).length, 0);
  const bad = on => (tried && on ? ' error' : '');
  const dates = sales.map(s => s.first.date).filter(Boolean).sort();
  // the summary cards above (sent up only when it changes)
  const stats = JSON.stringify({ sales: sales.length, rows: rows.filter(used).length, value: r2(sales.reduce((t, s) => t + s.value, 0)), paid: r2(sales.reduce((t, s) => t + s.paid, 0)), toType,
    span: dates.length ? (dates[0] === dates.at(-1) ? tableDate(dates[0]) : `${tableDate(dates[0])} – ${tableDate(dates.at(-1))}`) : '' });
  useEffect(() => { onStats?.(JSON.parse(stats)); }, [stats]); // eslint-disable-line react-hooks/exhaustive-deps

  async function save() {
    setTried(true); setError('');
    if (!sales.length) { setError('Type at least one row.'); return; }
    if (toType) { setError(`Fill the ${toType} red box${toType === 1 ? '' : 'es'} first.`); return; }
    setBusy(true);
    try {
      // the grid as text, kept with the pages
      const nameOf = id => productOf(id)?.name ?? '';
      const text = ['Date\tReceipt\tCustomer\tPhone\tProduct\tColour\tQty\tPrice\tPaid\tAccount\tEFD',
        ...rows.filter(used).map(r => [r.date, r.receipt, r.buyer, r.phone, nameOf(r.productId), r.colorId ? refs.colorById[r.colorId]?.name : '', r.qty, r.price, r.paid,
          accounts.find(a => a.id === r.accountId)?.name ?? '', r.efd].join('\t'))].join('\n');
      await keep(past ? 'past_sales' : 'sales', text);
      const queue = sales.map((s, i) => {
        const f = s.first; const c = customerOf(f.buyer);
        return {
          sale_date: f.date,
          ...(c ? { customer_id: c.id } : { walk_in_name: f.buyer.trim(), walk_in_phone: f.phone.trim() }),
          lines: s.rows.map(r => ({ productId: r.productId, colorId: r.colorId, quantity: String(num(r.qty)), price: num(r.price) != null ? String(num(r.price)) : '' })),
          payments: s.paid > 0 ? [{ accountId: f.accountId, amount: String(s.paid), receiptNo: f.receipt.trim() }] : [],
          efd_receipt_no: f.efd.trim(),
          banner: `From the uploaded sales book: sale ${i + 1} of ${sales.length}${f.receipt.trim() ? `, receipt ${f.receipt.trim()}` : ''}.`,
        };
      });
      try { sessionStorage.setItem(`mois.upload.sales.${organization.id}.${branchId}`, JSON.stringify({ at: 0, sales: queue })); } catch { /* ignore */ }
      navigate('/sales');
    } catch (e) {
      setError(dbErrorMessage(e, "We couldn't keep the pages. Please try again."));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="card"><div className="table-container">
        <table className="ru-grid">
          <thead><tr>
            {past && <th>Date</th>}<th>Receipt</th><th>Customer</th><th>Phone</th><th>Product</th><th>Colour</th>
            <th className="num">Qty</th><th className="num">Price (TZS)</th><th className="num">Paid (TZS)</th><th>Account</th><th>EFD no</th><th />
          </tr></thead>
          <tbody>
            {rows.map((r, i) => {
              const miss = missingOf(r);
              const first = firstOf(r);
              const same = first && first !== r;   // a later row of the same sale
              const main = productOf(r.productId);
              const lp = listPrice[r.productId];
              const below = lp != null && num(r.price) != null && num(r.price) < lp;
              return (
                <tr key={r.key}>
                  {past && <td><input type="date" className={`form-input${bad(miss.date)}`} max={today} aria-label="Date" value={r.date} onChange={e => set(r.key, { date: e.target.value })} /></td>}
                  <td><input className="form-input" style={{ minWidth: 70 }} aria-label="Receipt no" value={r.receipt} onChange={e => set(r.key, { receipt: e.target.value })} /></td>
                  {same ? <td colSpan={2} className="ru-same">same sale ↑</td> : <>
                    <td><input className="form-input" list="ru-customers" aria-label="Customer" placeholder="Walk-in" value={r.buyer} onChange={e => set(r.key, { buyer: e.target.value })} />
                      {r.buyer.trim() && <span className="pl-help">{customerOf(r.buyer) ? 'customer' : 'walk-in'}</span>}</td>
                    <td><input className="form-input" inputMode="tel" aria-label="Phone" value={r.phone} onChange={e => set(r.key, { phone: e.target.value })} /></td>
                  </>}
                  <td><select className={`form-input${bad(miss.product)}`} aria-label="Product" value={r.productId} onChange={e => set(r.key, { productId: e.target.value, colorId: '' })}>
                    <option value="">Choose…</option>
                    {carried.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                  </select></td>
                  <td>{main?.colorIds?.length ? (
                    <select className={`form-input${bad(miss.colour)}`} aria-label="Colour" value={r.colorId} onChange={e => set(r.key, { colorId: e.target.value })}>
                      <option value="">Choose…</option>
                      {main.colorIds.map(id => <option key={id} value={id}>{refs.colorById[id]?.name}</option>)}
                    </select>) : <span className="pl-help">—</span>}</td>
                  <td><NumberInput className={`form-input num${bad(miss.qty)}`} min="0" aria-label="Quantity" value={r.qty} onChange={e => set(r.key, { qty: e.target.value })} /></td>
                  <td><NumberInput className="form-input num" min="0" aria-label="Price" placeholder={lp != null ? formatAmount(lp) : ''} value={r.price} onChange={e => set(r.key, { price: e.target.value })} />
                    {below && <span className="pl-help text-warning" title="Below the price list: Record sale asks for the reason">discount</span>}</td>
                  <td><NumberInput className={`form-input num${bad(miss.over)}`} min="0" aria-label="Paid" value={r.paid} onChange={e => set(r.key, { paid: e.target.value })} /></td>
                  {same ? <td colSpan={2} className="ru-same">same sale ↑</td> : <>
                    <td><select className={`form-input${bad(miss.account)}`} aria-label="Account" value={r.accountId} onChange={e => set(r.key, { accountId: e.target.value })}>
                      <option value="">{accounts.length ? 'Choose…' : 'No accounts'}</option>
                      {accounts.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
                    </select></td>
                    <td><input className="form-input" style={{ minWidth: 70 }} aria-label="EFD no" value={r.efd} onChange={e => set(r.key, { efd: e.target.value })} /></td>
                  </>}
                  <td><button type="button" className="icon-btn" aria-label={`Remove row ${i + 1}`} onClick={() => setRows(rs => (rs.length > 1 ? rs.filter(x => x.key !== r.key) : [blank(past ? '' : day)]))}><Trash2 size={14} /></button></td>
                </tr>
              );
            })}
          </tbody>
        </table>
        <datalist id="ru-customers">{customers.map(c => <option key={c.id} value={c.name}>{c.phone ?? ''}</option>)}</datalist>
      </div>
        <div className="card-body ru-grid-foot">
          <button type="button" className="btn btn-outline btn-sm" onClick={() => setRows(rs => [...rs, ...Array.from({ length: 5 }, () => blank(past ? rs.filter(used).at(-1)?.date ?? '' : day))])}><Plus size={14} /> Add 5 rows</button>
          <span className="pl-help">Same {past ? 'date and ' : ''}receipt = one sale. Empty price = price list.</span>
        </div>
      </div>

      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="ru-actions">
        <span className="pl-help">Opens in Record sale, one at a time.</span>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>
          {sales.length ? `Save and open ${sales.length} sale${sales.length === 1 ? '' : 's'} in Sales` : 'Save'}</button>
      </div>
    </>
  );
}
