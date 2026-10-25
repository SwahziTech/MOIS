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
 * WITHOUT VAT, the margin between them, and the finished stock at cost
 * (first in first out; opening stock at the first batch cost, marked).
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
    let value = 0, est = 0;
    for (const x of items) {
      if (x.value == null) continue;
      value += Number(x.value);
      if (Number(x.estimated_quantity) > 0 && x.unit_cost != null) est += Number(x.estimated_quantity) * Number(x.unit_cost);
    }
    return { value, est, unpriced: items.filter(x => x.batches > 0 && x.price == null).length, uncosted: items.filter(x => Number(x.uncosted_quantity) > 0).length };
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
              <span className="pl-help">{totals.est > 0 ? `${money(totals.est)} of it opening stock at first batch cost` : 'oldest stock first'}</span></div>
            <div className="mm-stat"><span className="pl-label">Products</span><strong>{items.length}</strong><span className="pl-help">made or in stock here</span></div>
            <div className="mm-stat"><span className="pl-label">No price</span><strong className={totals.unpriced ? 'text-warning' : ''}>{totals.unpriced}</strong><span className="pl-help">made, but no price for its colour</span></div>
            <div className="mm-stat"><span className="pl-label">Not costed</span><strong className={totals.uncosted ? 'text-warning' : ''}>{totals.uncosted}</strong><span className="pl-help">stock with no batch cost yet</span></div>
          </div>
          <p className="pl-help" style={{ margin: '0 0 8px' }}>Cost = materials only (latest batch, VAT included). Margin = price without VAT − cost. Power, diesel and labour come later.</p>

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
                  <div className="sk-name">
                    <span className="pl-help">{x.it.category}</span>
                    <strong>{x.it.name}{x.colour ? ` ${x.colour}` : ''}</strong>
                  </div>
                  <div className="sk-total">
                    {x.margin != null ? (<>
                      <span><strong className={x.margin < 0 ? 'text-error' : ''}>{money(round(x.margin))}</strong> <span className="sk-unit">/{per(x.it)}</span></span>
                      <span className="sk-sub">margin{pct != null ? ` · ${pct}%` : ''}</span>
                    </>) : <span className="pl-help">{x.cost == null ? 'not produced yet' : 'no price'}</span>}
                  </div>
                  <div className="co-details">
                    <span>cost <strong>{x.cost != null ? money(round(x.cost)) : '—'}</strong> /{per(x.it)}{x.last_batch_date ? <span className="pl-help"> · {x.last_batch_date}</span> : ''}</span>
                    <span>price <strong>{x.price != null ? money(round(x.price)) : '—'}</strong> /{per(x.it)}{x.price == null && x.price_source ? <span className="pl-help"> · {x.price_source}</span> : ''}</span>
                    <span>stock {qtyText(round(Number(x.on_hand)))} {unitOf(x.it)}{x.value != null ? <> · <strong>{money(round(Number(x.value)))}</strong></> : ''}
                      {Number(x.estimated_quantity) > 0 && <span className="co-est" title="Opening stock valued at this product's first batch cost"> first batch cost</span>}
                      {Number(x.uncosted_quantity) > 0 && <span className="co-est"> {qtyText(round(Number(x.uncosted_quantity)))} not costed</span>}</span>
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

/** The stock left, lot by lot, oldest first: the batch it was made in (or opening stock), when it entered finished goods, how much is left, at what cost */
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
      <thead><tr><th>Made</th><th>In stock from</th><th style={{ textAlign: 'right' }}>Left</th><th style={{ textAlign: 'right' }}>Cost / {unit}</th><th style={{ textAlign: 'right' }}>Value</th><th /></tr></thead>
      <tbody>
        {layers.map((l, i) => (
          <tr key={i}>
            <td>{l.made ?? (l.estimated || !l.batch ? 'opening stock' : '—')}</td>
            <td>{l.made && l.made !== l.date ? <>{l.date} <span className="pl-help">released</span></> : l.date}</td>
            <td style={{ textAlign: 'right' }}>{qtyText(round(Number(l.quantity)))} {unit}</td>
            <td style={{ textAlign: 'right' }}>{l.cost != null ? money(round(Number(l.cost))) : '—'}</td>
            <td style={{ textAlign: 'right' }}>{l.cost != null ? money(round(Number(l.cost) * Number(l.quantity))) : '—'}</td>
            <td className="pl-help">{l.estimated ? 'at first batch cost' : l.batch ? (l.made === l.date ? 'curing' : 'batch cost') : l.cost == null ? 'no cost known' : ''}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
