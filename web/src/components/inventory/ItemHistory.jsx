import { useEffect, useMemo, useState } from 'react';
import { ChevronDown, ChevronRight } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { qtyText, orgToday } from '../../lib/inventory';
import { formatMoney } from '../../lib/format';
import { useAuth } from '../../hooks/useAuth';
import Modal from '../Modal';

const LABEL = {
  opening_balance: 'Opening stock', receipt: 'Received', issue: 'Issued', transfer_in: 'Transfer in', transfer_out: 'Transfer out',
  adjustment: 'Adjustment', count: 'Count', reversal: 'Reversal', reclassification: 'Reclassified',
  production_use: 'Production', production_output: 'Cast', curing_out: 'Out of curing', curing_in: 'Released',
};
const PRODUCTION = new Set(['production_use', 'production_output', 'curing_out', 'curing_in']);
const groupOf = t => (t.buy ? 'purchase' : PRODUCTION.has(t.transaction_type) ? 'production' : 'movement');
const GROUPS = [['all', 'All'], ['purchase', 'Purchases'], ['production', 'Production'], ['movement', 'Other']];
const PERIODS = [['all', 'All time'], ['week', 'This week'], ['month', 'This month']];
const r2 = n => Math.round(n * 100) / 100;

/**
 * One item's stock history at a branch (SwahziTech, 2026-10-24): short rows,
 * newest on top, a running balance, and the details of a row only when it is
 * opened. mode 'purchases' shows purchases only (Purchases page); 'all' shows
 * everything (Materials, Stock). Filters: kind of movement and period;
 * order can be flipped to oldest first.
 *
 * item: { kind: 'material'|'product', id, name }
 * unit: { factor, symbol, stockSymbol } — shown in the main unit (051), the stock unit underneath
 */
export function ItemHistoryList({ item, branchId, mode = 'all', unit, suppliers = [], colorName = () => '' }) {
  const { organization } = useAuth();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [rows, setRows] = useState(null);
  const [group, setGroup] = useState(mode === 'purchases' ? 'purchase' : 'all');
  const [period, setPeriod] = useState('all');
  const [newestFirst, setNewestFirst] = useState(true);
  const [open, setOpen] = useState(null);
  const [people, setPeople] = useState({});
  const f = unit?.factor || 1;

  useEffect(() => {
    let live = true;
    const col = item.kind === 'material' ? 'material_id' : 'product_id';
    Promise.all([
      supabase.from('inventory_transactions')
        .select(`id, transaction_date, transaction_type, quantity, entered_quantity, entered_unit_id, unit_cost, color_id, seq, created_at,
          warehouse:warehouses!inner(branch_id, name), unit:units!inventory_transactions_entered_unit_id_fkey(symbol),
          movement:inventory_movements(movement_type, reason, reference, notes, created_by, production_batch_id)`)
        .eq(col, item.id).order('transaction_date').order('seq'),
      item.kind === 'material' ? supabase.from('purchase_line_costs').select('*').eq('material_id', item.id) : Promise.resolve({ data: [] }),
    ]).then(async ([t, pc]) => {
      if (!live) return;
      const bought = Object.fromEntries((pc.data || []).map(x => [x.transaction_id, x]));
      let bal = 0;
      const list = (t.data || []).filter(x => !branchId || x.warehouse?.branch_id === branchId).map(x => {
        bal += Number(x.quantity);
        return { ...x, buy: bought[x.id] ?? null, balance: bal };
      });
      setRows(list);
      const ids = [...new Set(list.map(x => x.movement?.created_by).filter(Boolean))];
      if (ids.length) {
        const { data } = await supabase.from('profiles').select('id, first_name, last_name, email').in('id', ids);
        if (live) setPeople(Object.fromEntries((data || []).map(p => [p.id, [p.first_name, p.last_name].filter(Boolean).join(' ') || p.email])));
      }
    });
    return () => { live = false; };
  }, [item.id, item.kind, branchId]);

  const since = useMemo(() => {
    const d = new Date(`${today}T00:00:00Z`);
    if (period === 'week') { d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7)); return d.toISOString().slice(0, 10); }
    if (period === 'month') return `${today.slice(0, 7)}-01`;
    return null;
  }, [period, today]);

  const shown = (rows || []).filter(x => (group === 'all' || groupOf(x) === group) && (!since || x.transaction_date >= since));
  const ordered = newestFirst ? [...shown].reverse() : shown;
  const counts = Object.fromEntries(GROUPS.map(([k]) => [k, (rows || []).filter(x => k === 'all' || groupOf(x) === k).length]));

  return (
    <div className="ih">
      <div className="ih-filters">
        {mode !== 'purchases' && GROUPS.map(([k, l]) => (
          counts[k] > 0 || k === 'all' ? <button key={k} type="button" className={`filter-chip${group === k ? ' is-on' : ''}`} onClick={() => setGroup(k)}>{l} {counts[k] ? `(${counts[k]})` : ''}</button> : null
        ))}
        <select className="form-input ih-select" aria-label="Period" value={period} onChange={e => setPeriod(e.target.value)}>
          {PERIODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
        </select>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setNewestFirst(v => !v)}>{newestFirst ? 'Newest first' : 'Oldest first'} ⇅</button>
      </div>
      {rows === null ? <span className="skeleton" /> : ordered.length === 0 ? <p className="pl-help">Nothing in this view.</p> : (
        <div className="ih-list">
          {ordered.map(x => {
            const q = Number(x.quantity);
            const isOpen = open === x.id;
            const price = x.buy ? x.buy.unit_price : x.unit_cost;
            const supplier = x.buy ? suppliers.find(s => s.id === x.buy.supplier_id)?.name : null;
            return (
              <div key={x.id} className={`ih-row${isOpen ? ' is-open' : ''}`}>
                <button type="button" className="ih-line" onClick={() => setOpen(isOpen ? null : x.id)} aria-expanded={isOpen}>
                  {isOpen ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                  <span className="ih-date">{x.transaction_date.slice(5).split('-').reverse().join('/')}</span>
                  <span className={`ih-kind is-${groupOf(x)}`}>{x.buy ? 'Purchase' : LABEL[x.transaction_type] ?? x.transaction_type}</span>
                  <span className="ih-who">{supplier ?? (x.color_id ? colorName(x.color_id) : '')}</span>
                  <span className={`ih-qty ${q < 0 ? 'is-out' : 'is-in'}`}>{q < 0 ? '−' : '+'}{qtyText(r2(Math.abs(q) / f))} {unit?.symbol}</span>
                  <span className="ih-price">{price != null ? money(price) : ''}</span>
                  <span className="ih-bal">{qtyText(r2(x.balance / f))}</span>
                </button>
                {isOpen && (
                  <dl className="ih-detail">
                    <dt>Store</dt><dd>{x.warehouse?.name}</dd>
                    <dt>Entered</dt><dd>{qtyText(Math.abs(Number(x.entered_quantity)))} {x.unit?.symbol}{f !== 1 || x.unit?.symbol !== unit?.stockSymbol ? ` = ${qtyText(r2(Math.abs(q)))} ${unit?.stockSymbol}` : ''}</dd>
                    {x.buy && <><dt>Paid</dt><dd>{money(x.buy.unit_price)} per {x.unit?.symbol} · line {money(x.buy.line_amount)}</dd>
                      <dt>Cost</dt><dd>{money(x.buy.cost_per_stock_unit * f)} per {unit?.symbol} (incl. VAT &amp; transport){x.buy.vat_share > 0 ? ` · VAT ${money(x.buy.vat_share)}` : ''}</dd></>}
                    {!x.buy && x.unit_cost != null && <><dt>Cost</dt><dd>{money(x.unit_cost)} per {x.unit?.symbol}</dd></>}
                    {x.movement?.reason && <><dt>Note</dt><dd>{x.movement.reason}</dd></>}
                    {x.movement?.reference && <><dt>Reference</dt><dd>{x.movement.reference}</dd></>}
                    <dt>Recorded</dt><dd>{people[x.movement?.created_by] ?? '—'} · {new Date(x.created_at).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</dd>
                  </dl>
                )}
              </div>
            );
          })}
        </div>
      )}
      <p className="pl-help">Quantities in {unit?.symbol}; balance after each line.</p>
    </div>
  );
}

/** The history in its own window (Purchases, Stock) */
export default function ItemHistoryModal({ title, onClose, ...props }) {
  return (
    <Modal title={title} onClose={onClose} size="lg"
      footer={<button type="button" className="btn btn-primary" onClick={onClose}>Close</button>}>
      <ItemHistoryList {...props} />
    </Modal>
  );
}
