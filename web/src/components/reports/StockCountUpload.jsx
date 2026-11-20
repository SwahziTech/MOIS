import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Plus, Trash2 } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { MOVEMENT_TYPES, qtyText, stockKey, byMaterialOrder } from '../../lib/inventory';
import { categoryTools, productOrder } from '../../lib/categories';
import NumberInput from '../NumberInput';
import { useSiteZones, ZoneTag } from '../../lib/siteZones';

const num = v => (String(v ?? '').trim() === '' ? null : Number(String(v).replace(/,/g, '')));
let seq = 0;
const newRow = (warehouseId = '') => ({ k: `r${++seq}`, warehouseId, key: '', colorId: '', unitId: '', counted: '' });
// products are counted in the ready-goods and curing stores, materials in the others
const holdsProducts = w => w?.type === 'finished_goods' || w?.type === 'wip';
// the yard first, then the shop, the curing places, then the material stores
const rank = w => (w.type === 'finished_goods' ? (w.receives_production !== false ? 0 : 1) : w.type === 'wip' ? 2 : 3);

/*
 * Stock count upload (2026-11-20, the user): one count sheet can cover the
 * whole branch — each row names its store, item, colour and what was found.
 * MOIS shows its own figure and the difference beside each row. Saving keeps
 * the photos with the day and opens Stock › Count already filled in, one
 * store at a time: the normal count form posts it, with its usual checks and
 * approvals (uploads only save retyping).
 */
export const COUNT_QUEUE_KEY = orgId => `mois.upload.count.${orgId}`;

export default function StockCountUpload({ refs, branchId, day, today, keep, onStats }) {
  const { organization, canAt } = useAuth();
  const navigate = useNavigate();
  const perm = MOVEMENT_TYPES.count.perm;
  const stores = useMemo(() => refs.warehouses
    .filter(w => w.status === 'active' && w.branch_id === branchId && canAt(perm, w.branch_id, w.id))
    .sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name)), [refs, branchId]); // eslint-disable-line react-hooks/exhaustive-deps
  const [rows, setRows] = useState(() => [newRow(stores[0]?.id ?? '')]);
  const [bal, setBal] = useState(null);         // `${store}|${stockKey}` → quantity on the count day
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const zones = useSiteZones(branchId);   // where each product is kept (137), shown under the item

  // what MOIS holds in each store on the day of the count
  useEffect(() => {
    let live = true;
    setBal(null);
    (day < today
      ? supabase.rpc('stock_balances_as_of', { p_date: day })
      : supabase.from('stock_balances').select('warehouse_id, material_id, product_id, color_id, quantity'))
      .then(({ data }) => { if (live) setBal(Object.fromEntries((data || []).map(b => [`${b.warehouse_id}|${stockKey(b)}`, Number(b.quantity)]))); });
    return () => { live = false; };
  }, [day, today]);

  const cats = useMemo(() => categoryTools(refs.categoryRows || []), [refs]);
  const all = useMemo(() => Object.values(refs.items).filter(i => i.status === 'active'), [refs]);
  const products = useMemo(() => all.filter(i => i.kind === 'product' && refs.carriedByBranch?.[branchId]?.has(i.id)).sort(productOrder(cats)), [all, refs, branchId, cats]);
  const materials = useMemo(() => all.filter(i => i.kind === 'material' && (!i.branchId || i.branchId === branchId)).sort(byMaterialOrder), [all, branchId]);
  const storeOf = r => refs.warehouses.find(w => w.id === r.warehouseId);
  const itemsFor = r => (holdsProducts(storeOf(r)) ? products : materials);
  const itemOf = r => refs.items[r.key];
  const unitSym = id => refs.unitById[id]?.symbol ?? '';
  const factorOf = r => itemOf(r)?.units?.find(u => u.id === r.unitId)?.factor ?? 1;
  // in MOIS, in the row's unit
  const inMois = r => {
    const it = itemOf(r);
    if (!it || !bal || !r.warehouseId) return null;
    const row = { [it.kind === 'material' ? 'material_id' : 'product_id']: it.id, color_id: r.colorId || null };
    return (bal[`${r.warehouseId}|${stockKey(row)}`] ?? 0) / factorOf(r);
  };

  const set = (k, patch) => { setError(''); setRows(rs => rs.map(r => (r.k === k ? { ...r, ...patch } : r))); };
  const missingOf = r => ({
    store: !r.warehouseId,
    item: !r.key,
    colour: !!r.key && (itemOf(r)?.colorIds?.length ?? 0) > 0 && !r.colorId,
    counted: !(num(r.counted) != null && num(r.counted) >= 0),
  });
  const dupKey = r => `${r.warehouseId}|${r.key}|${r.colorId}`;
  const dups = new Set(Object.entries(rows.filter(r => r.key).reduce((m, r) => ({ ...m, [dupKey(r)]: (m[dupKey(r)] || 0) + 1 }), {}))
    .filter(([, n]) => n > 1).map(([k]) => k));
  const toType = rows.reduce((t, r) => t + Object.values(missingOf(r)).filter(Boolean).length, 0);
  const bad = on => (tried && on ? ' error' : '');
  const diffs = rows.filter(r => r.key && num(r.counted) != null && inMois(r) != null && Math.abs(num(r.counted) - inMois(r)) > 1e-9).length;
  const storesUsed = new Set(rows.filter(r => r.warehouseId && r.key).map(r => r.warehouseId)).size;

  useEffect(() => { onStats?.({ rows: rows.filter(r => r.key).length, stores: storesUsed, toType, diffs }); }, [rows, bal]); // eslint-disable-line react-hooks/exhaustive-deps

  async function save() {
    setTried(true); setError('');
    if (!rows.length) { setError('Add the counted items first.'); return; }
    if (toType) { setError(`Fill the ${toType} red box${toType === 1 ? '' : 'es'} first.`); return; }
    if (dups.size) { setError('An item is on the sheet twice for the same store: remove one row, or add the two counts together.'); return; }
    setBusy(true);
    try {
      await keep('stock', null);
      // one count a store, opened in Stock › Count one after another
      const byStore = [];
      for (const r of rows) {
        let g = byStore.find(x => x.warehouseId === r.warehouseId);
        if (!g) byStore.push(g = { warehouseId: r.warehouseId, lines: [] });
        g.lines.push({ key: r.key, colorId: r.colorId, unitId: r.unitId, quantity: String(num(r.counted)) });
      }
      try { sessionStorage.setItem(COUNT_QUEUE_KEY(organization.id), JSON.stringify({ date: day, stores: byStore, total: byStore.length })); } catch { /* ignore */ }
      navigate('/stock');
    } catch (e) {
      setError(dbErrorMessage(e, "We couldn't save the count sheet. Please try again."));
    } finally {
      setBusy(false);
    }
  }

  if (!stores.length) return <div className="card"><div className="card-body"><p className="text-sm">You can't count stock at any store of this branch.</p></div></div>;

  return (
    <>
      <div className="card"><div className="card-body">
        <h3 className="ru-h">What was counted</h3>
        <div className="table-container"><table className="ru-table">
          <thead><tr><th>Store</th><th>Item</th><th>Colour</th><th className="num">Counted</th><th>Unit</th><th className="num">In MOIS</th><th className="num">Difference</th><th /></tr></thead>
          <tbody>
            {rows.map((r, i) => {
              const miss = missingOf(r);
              const it = itemOf(r);
              const m = inMois(r);
              const d = num(r.counted) != null && m != null ? num(r.counted) - m : null;
              return (
                <tr key={r.k} className={dups.has(dupKey(r)) ? 'ru-dup' : ''}>
                  <td><select className={`form-input${bad(miss.store)}`} aria-label="Store" value={r.warehouseId}
                    onChange={e => set(r.k, { warehouseId: e.target.value, ...(holdsProducts(refs.warehouses.find(w => w.id === e.target.value)) !== holdsProducts(storeOf(r)) ? { key: '', colorId: '', unitId: '' } : {}) })}>
                    <option value="">Choose…</option>
                    {stores.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
                  </select></td>
                  <td><select className={`form-input${bad(miss.item)}`} aria-label="Item" value={r.key} disabled={!r.warehouseId}
                    onChange={e => set(r.k, { key: e.target.value, colorId: '', unitId: refs.items[e.target.value]?.mainUnitId ?? refs.items[e.target.value]?.stockUnitId ?? '' })}>
                    <option value="">Choose…</option>
                    {itemsFor(r).map(x => <option key={x.key} value={x.key}>{x.name}</option>)}
                  </select>{it?.kind === 'product' && zones?.hasPlan && <div><ZoneTag where={zones.of(it.id)} /></div>}</td>
                  <td>{it?.colorIds?.length ? (
                    <select className={`form-input${bad(miss.colour)}`} aria-label="Colour" value={r.colorId} onChange={e => set(r.k, { colorId: e.target.value })}>
                      <option value="">Choose…</option>
                      {it.colorIds.map(id => <option key={id} value={id}>{refs.colorById[id]?.name}</option>)}
                    </select>) : <span className="pl-help">—</span>}</td>
                  <td><NumberInput className={`form-input num${bad(miss.counted)}`} min="0" step="any" aria-label="Counted" value={r.counted}
                    onChange={e => set(r.k, { counted: e.target.value })}
                    onKeyDown={e => { if (e.key === 'Enter' && i === rows.length - 1) { e.preventDefault(); setRows(rs => [...rs, newRow(r.warehouseId)]); } }} /></td>
                  <td>{it && it.units?.length > 1 ? (
                    <select className="form-input" aria-label="Unit" value={r.unitId} onChange={e => set(r.k, { unitId: e.target.value })}>
                      {it.units.map(u => <option key={u.id} value={u.id}>{unitSym(u.id)}</option>)}
                    </select>) : <span className="pl-help">{it ? unitSym(r.unitId) : ''}</span>}</td>
                  <td className="num">{it && r.warehouseId ? (m == null ? '…' : qtyText(Math.round(m * 1000) / 1000)) : ''}</td>
                  <td className={`num${d == null || Math.abs(d) < 1e-9 ? ' pl-help' : ' text-warning'}`}>{d == null ? '' : `${d > 0 ? '+' : ''}${qtyText(Math.round(d * 1000) / 1000)}`}</td>
                  <td><button type="button" className="icon-btn" aria-label="Remove row" onClick={() => setRows(rs => rs.filter(x => x.k !== r.k))}><Trash2 size={14} /></button></td>
                </tr>
              );
            })}
          </tbody>
        </table></div>
        <button type="button" className="btn btn-ghost btn-sm" style={{ marginTop: 8 }} onClick={() => setRows(rs => [...rs, newRow(rs[rs.length - 1]?.warehouseId ?? stores[0]?.id ?? '')])}>
          <Plus size={14} /> Add row</button>
        <p className="pl-help" style={{ marginTop: 6 }}>Only the rows here are counted; other items in the stores are left as they are.</p>
      </div></div>

      {error && <div className="alert alert-error" role="alert">{error}</div>}
      <div className="ru-actions">
        <span className="pl-help">Opens Stock › Count filled in{storesUsed > 1 ? `, one store at a time (${storesUsed})` : ''}.</span>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save and open the count</button>
      </div>
    </>
  );
}
