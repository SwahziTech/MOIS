import { useMemo, useState } from 'react';
import { Search } from 'lucide-react';
import { qtyText } from '../../lib/inventory';
import Modal from '../Modal';
import { productOrder } from '../../lib/categories';

/**
 * Pick a product for a batch: search, category chips, and cards showing
 * size and wastani. Under "All" the products this branch casts most often
 * come first (by batches recorded), then the agreed category order, size, name.
 * items: products to choose from; usage: product id → batches; wastani: product id → pcs per bag
 * capacity (planner only): product id → the branch's molds / bags a day; shown on each card when given
 */
export default function ProductPicker({ title = 'Select primary product', items, cats, usage = {}, usageLabel = ['batch', 'batches'], wastani = {}, capacity = null, onPick, onClose }) {
  const [q, setQ] = useState('');
  const [cat, setCat] = useState('');
  // chips in the organization's category order
  const chips = useMemo(() => [...new Map(items.map(i => [i.categoryId, i.category])).entries()]
    .sort((a, b) => (cats.byId[a[0]] && cats.byId[b[0]] ? cats.compare(cats.byId[a[0]], cats.byId[b[0]]) : 0) || String(a[1]).localeCompare(String(b[1]))), [items, cats]);
  const order = useMemo(() => productOrder(cats), [cats]);
  const shown = items
    .filter(i => (!cat || i.categoryId === cat) && (!q.trim() || `${i.name} ${i.category}`.toLowerCase().includes(q.trim().toLowerCase())))
    .sort((a, b) => (usage[b.id] ?? 0) - (usage[a.id] ?? 0) || order(a, b));

  return (
    <Modal title={title} onClose={onClose} size="lg">
      <div className="pp">
        <p className="pl-help">Filter by product name or category.</p>
        <div className="search-wrapper pp-search">
          <Search size={15} className="search-icon" />
          <input type="search" className="search-input" autoFocus placeholder="Search by product name…" value={q} onChange={e => setQ(e.target.value)} aria-label="Search products" />
        </div>
        <div className="pp-chips">
          <button type="button" className={`filter-chip${!cat ? ' is-on' : ''}`} onClick={() => setCat('')}>All</button>
          {chips.map(([id, name]) => (
            <button type="button" key={id} className={`filter-chip${cat === id ? ' is-on' : ''}`} onClick={() => setCat(cat === id ? '' : id)}>{name}</button>
          ))}
        </div>
        <div className="pp-list">
          {shown.length === 0 && <div className="pl-empty">No product matches.</div>}
          {shown.map((i, n) => (
            <button type="button" key={i.id} className="pp-card" onClick={() => onPick(i.id)}>
              <span className="pp-head"><span className="pp-n">#{n + 1}</span><strong>{i.name}</strong>
                {capacity?.[i.id]?.molds ? <span className="pp-cap">{capOf(capacity[i.id])}</span>
                  : capOf(capacity?.[i.id]) && <span className="pp-cap is-none" title="A guide, not a limit">~{capOf(capacity[i.id])}</span>}
                {usage[i.id] > 0 && <span className="pp-used">{usage[i.id]} {usage[i.id] === 1 ? usageLabel[0] : usageLabel[1]}</span>}</span>
              <span className="pp-cat">{i.category}</span>{/* products: name on top, category below (locked 2026-10-25) */}
              <span className="pp-meta">
                {[i.size && `Size: ${i.size}`, wastani[i.id] > 0 ? `Wastani: ${+wastani[i.id]} pcs/bag` : 'No wastani set'].filter(Boolean).join(' • ')}
              </span>
            </button>
          ))}
        </div>
      </div>
    </Modal>
  );
}

/** A capacity row as a short label: molds, or bags of cement a day */
function capOf(c) {
  if (!c) return null;
  if (c.molds) return `${qtyText(c.molds)} molds`;
  const lo = c.bags_per_day_min ?? c.bags_per_day_max, hi = c.bags_per_day_max ?? c.bags_per_day_min;
  return lo ? `${qtyText(lo)}${hi !== lo ? `–${qtyText(hi)}` : ''} bags/day` : null;
}
