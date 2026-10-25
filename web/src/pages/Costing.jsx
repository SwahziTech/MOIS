import { useEffect, useMemo, useState } from 'react';
import { Calculator } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { loadInventoryRefs, qtyText } from '../lib/inventory';
import { formatMoney } from '../lib/format';
import { categoryTools, productOrder } from '../lib/categories';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, categoryChipItems } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';

const LOAD_ERROR = "We couldn't load costing. Please try again.";
const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;

/*
 * Costing (1e, migration 058; SwahziTech 2026-10-25): per product and colour
 * at a branch — the latest batch's material cost per m² or piece, the price
 * WITHOUT VAT, the margin between them, the finished stock at cost (first in
 * first out: production cost per batch; stock with no production cost —
 * opening stock, products never produced — estimated at its price without
 * VAT, kept apart; 060) and the stock at its price without VAT.
 * Materials only for now: power, diesel and labour are shared once expenses
 * are entered. Locked list layout: category over name, figure centred
 * (margin), details right; click shows the stock layers.
 */
export default function Costing() {
  const { organization } = useAuth();
  const { branchId, branchName } = useBranch();
  const [refs, setRefs] = useState(null);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [chip, setChip] = useState('');
  const [sortBy, setSortBy] = useState('order');
  const [open, setOpen] = useState(null);
  const money = v => formatMoney(v, organization?.currency_code);

  async function load() {
    setError('');
    if (!branchId) { setRows([]); return; }
    try {
      const [r, c] = await Promise.all([loadInventoryRefs(), supabase.rpc('product_costing', { p_branch_id: branchId })]);
      if (c.error) throw c.error;
      setRefs(r);
      setRows(c.data || []);
    } catch (e) {
      console.error(e);
      setError(LOAD_ERROR);
    }
  }
  useEffect(() => { setRows(null); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const cats = useMemo(() => categoryTools(refs?.categoryRows || []), [refs]);
  const order = useMemo(() => productOrder(cats), [cats]);
  const unitOf = it => refs?.unitById[it?.stockUnitId]?.symbol ?? '';
  const per = it => (unitOf(it).toUpperCase() === 'SQM' ? 'm²' : 'pc');

  const items = useMemo(() => (rows || []).map(r => {
    const it = refs?.items[`p:${r.product_id}`];
    const cost = r.last_batch_cost != null ? Number(r.last_batch_cost) : null;
    const price = r.price_ex_vat != null ? Number(r.price_ex_vat) : null;
    return { ...r, it, cost, price, margin: cost != null && price != null ? price - cost : null,
      colour: r.color_id ? refs?.colorById[r.color_id]?.name : null };
  }).filter(x => x.it && (Number(x.on_hand) !== 0 || x.batches > 0)), [rows, refs]);

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    const inChip = x => !chip || x.it.categoryId === chip || cats.byId[x.it.categoryId]?.parent_category_id === chip;
    const list = items.filter(x => inChip(x) && (!q || `${x.it.name} ${x.colour ?? ''} ${x.it.category}`.toLowerCase().includes(q)));
    const pctOf = x => (x.margin != null && x.price > 0 ? x.margin / x.price : -Infinity);
    return list.sort((a, b) => (sortBy === 'margin' ? pctOf(a) - pctOf(b) : sortBy === 'value' ? (Number(b.value) || 0) - (Number(a.value) || 0) : 0)
      || order(a.it, b.it) || String(a.colour ?? '').localeCompare(String(b.colour ?? '')));
  }, [items, search, chip, sortBy, cats, order]);

  const totals = useMemo(() => {
    let value = 0, est = 0, sales = 0;
    for (const x of items) {
      value += Number(x.value) || 0;
      est += Number(x.estimated_value) || 0;
      sales += Number(x.sales_value) || 0;
    }
    return { value, est, prod: value - est, sales, unpriced: items.filter(x => x.price == null).length };
  }, [items]);

  return (
    <PageShell title="Costing" subtitle="Sales & Costing"
      description={branchId ? `Material cost, price without VAT and margin per product at ${branchName}; finished stock at cost.` : 'Pick a branch in the sidebar to see its costing.'}>
      {!branchId ? (
        <div className="card"><EmptyState icon={Calculator} title="Pick a branch" description="Costs, prices and stock are per branch." /></div>
      ) : error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <>
          <div className="mm-stats">
            <div className="mm-stat"><span className="pl-label">Finished stock at cost</span><strong className="mm-money">{rows ? money(totals.value) : '—'}</strong>
              <span className="pl-help">{money(totals.prod)} production cost · <span className="co-est-txt">{money(totals.est)} estimated</span></span></div>
            <div className="mm-stat"><span className="pl-label">Stock at price</span><strong className="mm-money">{rows ? money(totals.sales) : '—'}</strong><span className="pl-help">without VAT</span></div>
            <div className="mm-stat"><span className="pl-label">Products</span><strong>{items.length}</strong><span className="pl-help">made or in stock here</span></div>
            <div className="mm-stat"><span className="pl-label">No price</span><strong className={totals.unpriced ? 'text-warning' : ''}>{totals.unpriced}</strong><span className="pl-help">not valued — set it in Pricing</span></div>
          </div>
          <p className="pl-help" style={{ margin: '0 0 8px' }}>Production cost = materials of the latest batch (VAT included). Stock with no production cost is estimated at its price without VAT. Margin = price without VAT − production cost. Power, diesel and labour come later.</p>

          <ListToolbar id="costing-search" search={search} onSearch={setSearch} placeholder="Search product (e.g. Buibui, 600R)…"
            sort={{ value: sortBy, onChange: setSortBy, options: [{ value: 'order', label: 'Category order' }, { value: 'margin', label: 'Lowest margin first' }, { value: 'value', label: 'Highest stock value first' }] }} />
          {refs && <ChipRow value={chip} onChange={setChip} items={categoryChipItems(cats, c => c.status === 'active')} />}

          <section className="sk">
            <div className="sk-head"><span>Products ({shown.length})</span><span className="pl-help">per {`m² or piece`}, without VAT</span></div>
            {rows === null ? Array.from({ length: 5 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
            : shown.length === 0 ? <div className="card"><EmptyState icon={Calculator} title="Nothing to show" description="Products this branch has made or holds appear here." /></div>
            : shown.map(x => {
              const pct = x.margin != null && x.price > 0 ? Math.round((x.margin / x.price) * 100) : null;
              return (
                <div key={`${x.product_id}|${x.color_id ?? ''}`} className="sk-card lk-card" title="Open its stock at cost" onClick={() => setOpen(x)}>
                  <div className="sk-name">{/* products: name on top, category below (locked) */}
                    <strong>{x.it.name}{x.colour ? ` ${x.colour}` : ''}</strong>
                    <span className="pl-help">{x.it.category}</span>
                  </div>
                  <div className="sk-total">
                    {x.margin != null ? (<>
                      <span><strong className={x.margin < 0 ? 'text-error' : ''}>{money(round(x.margin))}</strong> <span className="sk-unit">/{per(x.it)}</span></span>
                      <span className="sk-sub">margin{pct != null ? ` · ${pct}%` : ''}</span>
                    </>) : <span className="pl-help">{x.cost == null ? 'not produced yet' : 'no price'}</span>}
                  </div>
                  <div className="co-details">
                    <span>{x.cost != null ? <>production cost <strong>{money(round(x.cost))}</strong> /{per(x.it)}<span className="pl-help"> · {x.last_batch_date}</span></>
                      : <>cost <span className="co-est-txt">estimated at price</span></>}</span>
                    <span>price <strong>{x.price != null ? money(round(x.price)) : '—'}</strong> /{per(x.it)}{x.price == null && x.price_source ? <span className="pl-help"> · {x.price_source}</span> : ''}</span>
                    <span>stock {qtyText(round(Number(x.on_hand)))} {unitOf(x.it)}{x.value != null ? <> · at cost <strong>{money(round(Number(x.value)))}</strong></> : ''}
                      {Number(x.estimated_value) > 0 && Number(x.estimated_value) < Number(x.value) - 0.5 && <span className="co-est" title="Part with no production cost, estimated at the price without VAT"> {money(round(Number(x.estimated_value)))} estimated</span>}
                      {Number(x.estimated_value) > 0 && Number(x.estimated_value) >= Number(x.value) - 0.5 && <span className="co-est"> estimated</span>}
                      {x.sales_value != null && <> · at price {money(round(Number(x.sales_value)))}</>}
                      {Number(x.uncosted_quantity) > 0 && <span className="co-est"> {qtyText(round(Number(x.uncosted_quantity)))} not valued</span>}</span>
                  </div>
                </div>
              );
            })}
          </section>
        </>
      )}

      {open && (
        <Modal title={`${open.it.name}${open.colour ? ` ${open.colour}` : ''} — stock at cost`} onClose={() => setOpen(null)}
          footer={<button type="button" className="btn btn-outline" onClick={() => setOpen(null)}>Close</button>}>
          <LayerList branchId={branchId} row={open} unit={unitOf(open.it)} money={money} />
        </Modal>
      )}
    </PageShell>
  );
}

/** The stock left, lot by lot, oldest first: the day it was produced (its stock date; curing until released), how much is left, at what cost */
function LayerList({ branchId, row, unit, money }) {
  const [layers, setLayers] = useState(null);
  useEffect(() => {
    supabase.rpc('product_stock_value', { p_branch_id: branchId, p_product_id: row.product_id, p_color_id: row.color_id })
      .then(({ data }) => setLayers(data?.[0]?.layers || []));
  }, [branchId, row]);
  if (!layers) return <p className="pl-help">Loading…</p>;
  if (!layers.length) return <p className="pl-help">No stock left.</p>;
  return (
    <table className="rd-table">
      <thead><tr><th>Produced</th><th>Stage</th><th style={{ textAlign: 'right' }}>Left</th><th style={{ textAlign: 'right' }}>Cost / {unit}</th><th style={{ textAlign: 'right' }}>Value</th><th /></tr></thead>
      <tbody>
        {[...layers].reverse().map((l, i) => (   /* newest on top (locked 2026-10-25) */
          <tr key={i}>
            <td>{l.date}</td>
            <td>{l.stage === 'curing' ? 'curing' : l.stage === 'released' ? 'released' : l.batch ? '—' : 'opening stock'}</td>
            <td style={{ textAlign: 'right' }}>{qtyText(round(Number(l.quantity)))} {unit}</td>
            <td style={{ textAlign: 'right' }}>{l.cost != null ? money(round(Number(l.cost))) : '—'}</td>
            <td style={{ textAlign: 'right' }}>{l.cost != null ? money(round(Number(l.cost) * Number(l.quantity))) : '—'}</td>
            <td className={l.estimated ? 'co-est-txt' : 'pl-help'}>{l.estimated ? 'estimated at price' : l.cost == null ? 'no price' : 'production cost'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
