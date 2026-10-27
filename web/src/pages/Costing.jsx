import { useEffect, useMemo, useState } from 'react';
import { Calculator, X } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { loadInventoryRefs, qtyText } from '../lib/inventory';
import { formatMoney } from '../lib/format';
import { categoryTools, productOrder } from '../lib/categories';
import PageShell from '../components/PageShell';
import { ListToolbar, ChipRow, categoryChipItems, PageTabs } from '../components/ListControls';
import ElectricityCosting from '../components/costing/ElectricityCosting';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import NumberInput from '../components/NumberInput';
import { dbErrorMessage } from '../lib/masterData';

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
  const { organization, can } = useAuth();
  const isTech = can('system.manage');   // the Technical admin's benchmark (075) — no one else sees it
  const { branchId, branchName } = useBranch();
  const [refs, setRefs] = useState(null);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [chip, setChip] = useState('');
  const [sortBy, setSortBy] = useState('order');
  const [open, setOpen] = useState(null);
  const [bench, setBench] = useState({ target: null, perBag: {} });   // Technical admin only
  const [benchEdit, setBenchEdit] = useState(false);
  const [belowOnly, setBelowOnly] = useState(false);   // the target card shows only the products below it
  const [power, setPower] = useState(null);             // this month's electricity at the branch (072), from Purchases › Electricity
  const [view, setView] = useState('products');        // products | electricity (direct cost, from Purchases and Production)
  const money = v => formatMoney(v, organization?.currency_code);

  async function load() {
    setError('');
    if (!branchId) { setRows([]); return; }
    try {
      const [r, c] = await Promise.all([loadInventoryRefs(), supabase.rpc('product_costing', { p_branch_id: branchId })]);
      if (c.error) throw c.error;
      setRefs(r);
      setRows(c.data || []);
      const monthStart = new Date().toISOString().slice(0, 8) + '01';
      supabase.from('power_daily').select('day_cost, night_cost, gap_cost').eq('branch_id', branchId).gte('day', monthStart)
        .then(({ data, error: pErr }) => setPower(pErr ? null : (data || []).reduce((t, d) => ({ day: t.day + Number(d.day_cost || 0), other: t.other + Number(d.night_cost || 0) + Number(d.gap_cost || 0) }), { day: 0, other: 0 })));
      if (isTech) {
        const [t, y] = await Promise.all([
          supabase.from('tech_admin_settings').select('revenue_per_bag_target').maybeSingle(),
          supabase.rpc('product_yield_per_unit', { p_branch_id: branchId }),
        ]);
        setBench({ target: t.data?.revenue_per_bag_target != null ? Number(t.data.revenue_per_bag_target) : null,
          perBag: Object.fromEntries((y.data || []).map(x => [x.product_id, x.units_per_bag != null ? Number(x.units_per_bag) : null])) });
      }
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
    const per = isTech ? bench.perBag[r.product_id] : null;
    return { ...r, it, cost, price, margin: cost != null && price != null ? price - cost : null,
      bag: price != null && per ? price * per : null,
      colour: r.color_id ? refs?.colorById[r.color_id]?.name : null };
  }).filter(x => x.it && (Number(x.on_hand) !== 0 || x.batches > 0)), [rows, refs, bench, isTech]);
  const belowBag = x => bench.target != null && x.bag != null && x.bag < bench.target;

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    const inChip = x => !chip || x.it.categoryId === chip || cats.byId[x.it.categoryId]?.parent_category_id === chip;
    const list = items.filter(x => inChip(x) && (!belowOnly || belowBag(x)) && (!q || `${x.it.name} ${x.colour ?? ''} ${x.it.category}`.toLowerCase().includes(q)));
    const pctOf = x => (x.margin != null && x.price > 0 ? x.margin / x.price : -Infinity);
    return list.sort((a, b) => (sortBy === 'bag' ? (a.bag ?? Infinity) - (b.bag ?? Infinity) : sortBy === 'margin' ? pctOf(a) - pctOf(b) : sortBy === 'value' ? (Number(b.value) || 0) - (Number(a.value) || 0) : 0)
      || order(a.it, b.it) || String(a.colour ?? '').localeCompare(String(b.colour ?? '')));
  }, [items, search, chip, sortBy, cats, order, belowOnly, bench]); // eslint-disable-line react-hooks/exhaustive-deps

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
      ) : (
        <>
          <PageTabs tabs={[['products', 'Products'], ['electricity', 'Electricity']]} value={view} onChange={setView} />
          {view === 'electricity' ? <ElectricityCosting branchId={branchId} refs={refs} currency={organization?.currency_code} />
          : error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : <>
          <div className="mm-stats">
            <div className="mm-stat"><span className="pl-label">Finished stock at cost</span><strong className="mm-money">{rows ? money(totals.value) : '—'}</strong>
              <span className="pl-help">{money(totals.prod)} production cost · <span className="co-est-txt">{money(totals.est)} estimated</span></span></div>
            <div className="mm-stat"><span className="pl-label">Stock at price</span><strong className="mm-money">{rows ? money(totals.sales) : '—'}</strong><span className="pl-help">without VAT</span></div>
            <div className="mm-stat"><span className="pl-label">Products</span><strong>{items.length}</strong><span className="pl-help">made or in stock here</span></div>
            {isTech && (
              <div className={`mm-stat mm-click${belowOnly ? ' is-on' : ''}`} role="button" tabIndex={0} title="Show the products below the target — seen by the Technical admin only"
                onClick={() => bench.target != null && setBelowOnly(v => !v)} onKeyDown={e => { if (e.key === 'Enter' && bench.target != null) setBelowOnly(v => !v); }}><span className="pl-label">A bag · target</span>
                <strong className={items.some(belowBag) ? 'text-warning' : ''}>{bench.target != null ? `${items.filter(belowBag).length} below` : '—'}</strong>
                <span className="pl-help">{bench.target != null ? `target ${money(bench.target)} a cement bag` : 'no target set'} · <button type="button" className="link-btn" onClick={e => { e.stopPropagation(); setBenchEdit(true); }}>{bench.target != null ? 'change' : 'set'}</button></span></div>
            )}
            <div className="mm-stat mm-click" role="button" tabIndex={0} title="Electricity in production cost" onClick={() => setView('electricity')}
              onKeyDown={e => { if (e.key === 'Enter') setView('electricity'); }}>
              <span className="pl-label">Electricity · this month</span>
              <strong>{power ? money(round(power.day, 0)) : '—'}</strong>
              <span className="pl-help">{power ? `into products · ${money(round(power.other, 0))} nights` : 'meters and readings in Purchases'}</span></div>
            <div className="mm-stat"><span className="pl-label">No price</span><strong className={totals.unpriced ? 'text-warning' : ''}>{totals.unpriced}</strong><span className="pl-help">not valued — set it in Pricing</span></div>
          </div>
          <p className="pl-help" style={{ margin: '0 0 8px' }}>Production cost = materials of the latest batch (VAT included). Stock with no production cost is estimated at its price without VAT. Margin = price without VAT − production cost. Electricity: the day use of the batch's machine meter (Purchases › Electricity). Labour comes with HR; diesel and other expenses later.</p>

          <ListToolbar id="costing-search" search={search} onSearch={setSearch} placeholder="Search product (e.g. Buibui, 600R)…"
            sort={{ value: sortBy, onChange: setSortBy, options: [{ value: 'order', label: 'Category order' }, { value: 'margin', label: 'Lowest margin first' }, { value: 'value', label: 'Highest stock value first' }, ...(isTech ? [{ value: 'bag', label: 'Lowest a bag first' }] : [])] }} />
          {refs && <ChipRow value={chip} onChange={setChip} items={categoryChipItems(cats, c => c.status === 'active')} />}

          {belowOnly && <div className="flex items-center gap-8" style={{ marginBottom: 8 }}><button type="button" className="filter-chip is-on" onClick={() => setBelowOnly(false)}>Below the bag target <X size={12} /></button></div>}
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
                    {isTech && x.bag != null && <span className={belowBag(x) ? 'text-warning' : ''} title="Price without VAT × yield a cement bag — Technical admin only">a bag <strong>{money(round(x.bag, 0))}</strong>{belowBag(x) ? ' · below target' : ''}</span>}
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
          </>}
        </>
      )}

      {benchEdit && <BenchModal target={bench.target} organizationId={organization?.id} money={money}
        onClose={() => setBenchEdit(false)} onSaved={async () => { setBenchEdit(false); await load(); }} />}
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

/* The Technical admin's target a cement bag (075): price without VAT × yield a bag, per product */
function BenchModal({ target, organizationId, money, onClose, onSaved }) {
  const [value, setValue] = useState(target != null ? String(target) : '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    const n = value.trim() === '' ? null : Number(value);
    if (n !== null && !(n >= 0)) { setError('Enter the amount as a number.'); return; }
    setBusy(true);
    const { error: err } = await supabase.from('tech_admin_settings')
      .upsert({ organization_id: organizationId, revenue_per_bag_target: n }, { onConflict: 'organization_id' });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title="Target a cement bag" onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        <label className="pe-field"><span>Revenue a cement bag (TZS)</span>
          <NumberInput step="any" min="0" className="form-input" autoFocus value={value} onChange={e => setValue(e.target.value)} /></label>
        <p className="pl-help">Each product: its price without VAT × its yield a bag (m² or pieces). Products below this show in amber. Seen by the Technical admin only.{target != null ? ` Now: ${money(target)}.` : ''}</p>
      </div>
    </Modal>
  );
}
