import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2, AlertTriangle } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';
import { MOVEMENT_TYPES, warehouseLabel, qtyText, stockKey, orgToday, matchSuppliers, isCorrective } from '../../lib/inventory';
import Modal from '../Modal';
import { findRepeats, planOpeningFix, runSteps } from '../../lib/doubleEntry';
import { fitsStore } from './DoubleEntry';
import NumberInput from '../NumberInput';

const emptyLine = (kind = 'material') => ({ kind, key: '', colorId: '', quantity: '', unitId: '', unitCost: '', direction: 'remove' });
// A new line's type follows the store: products in a finished-goods store, materials elsewhere
const kindForStore = w => (w?.type === 'finished_goods' ? 'product' : 'material');

/**
 * Record one stock movement. Everything is validated again and posted
 * atomically by post_inventory_movement() (migration 022); this form only
 * offers what the user may do and shows the effect before posting.
 */
export default function MovementModal({ type, refs, balances, defaultWarehouseId, onClose, onPosted }) {
  const { canAt, canManage, organization } = useAuth();
  const { inBranch } = useBranch();
  const today = orgToday(organization?.timezone);
  const def = MOVEMENT_TYPES[type];
  const { warehouses, items, unitById, colorById, suppliers } = refs;

  // Stores of the branch picked in the sidebar (all of them on "All branches")
  const allowed = warehouses.filter(w => w.status === 'active' && w.branch?.status !== 'inactive' && inBranch(w.branch_id)
    && canAt(def.perm, w.branch_id, w.id));
  const [warehouseId, setWarehouseId] = useState(allowed.some(w => w.id === defaultWarehouseId) ? defaultWarehouseId : (allowed[0]?.id ?? ''));
  const [toWarehouseId, setToWarehouseId] = useState('');
  const [supplier,  setSupplier]  = useState(null);   // { id } | { newName } | null
  const [date,      setDate]      = useState(today);
  const [asOf,      setAsOf]      = useState(null);   // balances at a past date
  const [reference, setReference] = useState('');
  const [reason,    setReason]    = useState('');
  const [notes,     setNotes]     = useState('');
  const [lines,     setLines]     = useState(() => [emptyLine(kindForStore(warehouses.find(w => w.id === warehouseId)))]);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [submitted, setSubmitted] = useState(false);
  const [repeats, setRepeats] = useState(null);     // possible double entries found before posting
  const [choices, setChoices] = useState({});       // line index → what to do about its repeat

  // Corrections and backdated entries by non-admins go to the Approvals queue
  const needsApproval = !canManage('inventory.adjust') && (isCorrective(type, date, today)
    || (type === 'count' && !!wh && !canAt('inventory.adjust', wh.branch_id, wh.id)));

  const itemList = useMemo(() => Object.values(items).filter(i => i.status === 'active'), [items]);
  // Only what the chosen store's branch uses: shared materials and its own
  // (032); products in its catalogue (031), or already in stock in this store
  const inThisStore = key => Object.entries(balances || {}).some(([k, q]) => Number(q) !== 0 && (k === `${warehouseId}|${key}` || k.startsWith(`${warehouseId}|${key}|`)));
  const whBranchId = warehouses.find(w => w.id === warehouseId)?.branch_id;
  const materials = itemList.filter(i => i.kind === 'material' && (!i.branchId || i.branchId === whBranchId));
  const products = itemList.filter(i => i.kind === 'product'
    && (refs.carriedByBranch?.[whBranchId]?.has(i.id) || inThisStore(i.key)));
  const wh = warehouses.find(w => w.id === warehouseId);
  // Earlier dates need stock-adjustment permission at the store (migration 023)
  const canBackdate = !!wh && canAt('inventory.adjust', wh.branch_id, wh.id);
  useEffect(() => { if (!canBackdate) setDate(today); }, [canBackdate, today]);
  // Lines not filled in yet follow the store's usual kind of item
  useEffect(() => { setLines(ls => ls.map(l => (l.key ? l : { ...l, kind: kindForStore(wh) }))); }, [warehouseId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Stock as of the chosen date, for the previews; the server re-checks
  // every later date too when posting
  useEffect(() => {
    if (!date || date >= today) { setAsOf(null); return; }
    let live = true;
    supabase.rpc('stock_balances_as_of', { p_date: date }).then(({ data }) => {
      if (live) setAsOf(Object.fromEntries((data || []).map(b => [`${b.warehouse_id}|${stockKey(b)}`, b.quantity])));
    });
    return () => { live = false; };
  }, [date, today]);
  const balanceOf = l => {
    const item = items[l.key];
    const row = { [item.kind === 'material' ? 'material_id' : 'product_id']: item.id, color_id: l.colorId || null };
    return Number((asOf ?? balances)[`${warehouseId}|${stockKey(row)}`] ?? 0);
  };

  function setLine(i, patch) {
    setLines(ls => ls.map((l, j) => {
      if (j !== i) return l;
      const next = { ...l, ...patch };
      if (patch.kind !== undefined && patch.kind !== l.kind) {   // a different type: the item no longer fits
        next.key = ''; next.unitId = ''; next.colorId = '';
      }
      if (patch.key !== undefined) {
        next.unitId = items[patch.key]?.stockUnitId ?? '';
        next.colorId = '';
      }
      return next;
    }));
  }

  // The same item twice in this form: offer to merge the lines
  const twice = Object.values(lines.reduce((g, l, i) => {
    if (l.key) (g[`${l.key}|${l.colorId}`] ||= []).push(i);
    return g;
  }, {})).filter(g => g.length > 1);
  function mergeLines(group) {
    const ls = group.map(i => lines[i]);
    const item = items[ls[0].key];
    const sameUnit = ls.every(l => l.unitId === ls[0].unitId);
    const signed = l => (type === 'adjustment' && l.direction === 'remove' ? -1 : 1) * (sameUnit ? Number(l.quantity || 0) : (stockQty(l) ?? 0));
    const sum = ls.reduce((s, l) => s + signed(l), 0);
    const merged = { ...ls[0], quantity: String(+Math.abs(sum).toPrecision(12)), unitId: sameUnit ? ls[0].unitId : item.stockUnitId,
      direction: type === 'adjustment' ? (sum < 0 ? 'remove' : 'add') : ls[0].direction,
      unitCost: ls.find(l => l.unitCost !== '')?.unitCost ?? '' };
    setLines(all => all.map((l, i) => (i === group[0] ? merged : l)).filter((_, i) => !group.slice(1).includes(i)));
  }

  // Quantity in the item's stock unit, for previews
  function stockQty(l) {
    const item = items[l.key];
    const f = item?.units.find(u => u.id === l.unitId)?.factor;
    const q = Number(l.quantity);
    return item && f && l.quantity !== '' && Number.isFinite(q) ? q * f : null;
  }

  async function post(e) {
    e.preventDefault();
    setError('');
    const filled = lines.filter(l => l.key);
    if (!filled.length) { setError('Add at least one item.'); return; }
    if (twice.length) { setError('An item is entered twice — merge the lines, or remove one.'); return; }
    const noColour = filled.find(l => items[l.key].colorIds?.length && !l.colorId);
    if (noColour) { setError(`${items[noColour.key].name}: choose the colour.`); return; }
    for (const l of filled) {
      const q = Number(l.quantity);
      if (l.quantity === '' || !Number.isFinite(q) || (type === 'count' ? q < 0 : q <= 0)) {
        setError(`${items[l.key].name}: enter a ${type === 'count' ? 'quantity of zero or more' : 'quantity above zero'}.`); return;
      }
    }
    if (type === 'transfer' && !toWarehouseId) { setError('Choose where the stock goes.'); return; }
    if (type === 'adjustment' && !reason.trim()) { setError('Give a reason for the adjustment.'); return; }
    if (supplier?.pendingConfirm) { setError('Choose one of the suggested suppliers, or confirm the new one.'); return; }

    // Possible double entry? Ask before posting (the check helps; it never blocks)
    setBusy(true);
    let found = [];
    try {
      found = await findRepeats({ type, warehouse: wh, date, lines: filled.map((l, idx) => ({
        idx, [items[l.key].kind === 'material' ? 'material_id' : 'product_id']: items[l.key].id, color_id: l.colorId || null,
        qty: (type === 'adjustment' && l.direction === 'remove' ? -1 : type === 'issue' || type === 'transfer' ? -1 : 1) * (stockQty(l) ?? 0),
      })) });
    } catch (err) { console.error(err); }
    setBusy(false);
    if (found.length) { setRepeats({ found, filled }); setChoices({}); return; }
    await send(filled, []);
  }

  // Post (or send for approval) the movement, plus any corrections chosen for repeats
  async function send(filled, steps) {
    setError('');
    const payload = {
      type, warehouse_id: warehouseId, movement_date: date,
      reference: reference.trim() || null, reason: reason.trim() || null, notes: notes.trim() || null,
      ...(type === 'transfer' ? { to_warehouse_id: toWarehouseId } : {}),
      ...(type === 'receipt' && supplier?.id ? { supplier_id: supplier.id } : {}),
      ...(type === 'receipt' && supplier?.newName ? { new_supplier_name: supplier.newName } : {}),
      lines: filled.map(l => {
        const item = items[l.key];
        const q = Number(l.quantity);
        return {
          [item.kind === 'material' ? 'material_id' : 'product_id']: item.id,
          ...(l.colorId ? { color_id: l.colorId } : {}),
          quantity: type === 'adjustment' && l.direction === 'remove' ? -q : q,
          unit_id: l.unitId,
          ...(type === 'opening_balance' && l.unitCost !== '' ? { unit_cost: Number(l.unitCost) } : {}),
        };
      }),
    };
    setBusy(true);
    let sentAny = false;
    if (filled.length && needsApproval) {
      const what = filled.map(l => {
        const sq = stockQty(l);
        return `${type === 'adjustment' ? (l.direction === 'remove' ? 'remove ' : 'add ') : ''}${qtyText(sq ?? l.quantity)} ${unitById[items[l.key].stockUnitId]?.symbol ?? ''} ${items[l.key].name}${l.colorId ? ` (${colorById[l.colorId]?.name})` : ''}`;
      }).join(', ');
      const summary = `${def.noun} at ${warehouseLabel(wh)}${date < today ? `, dated ${date}` : ''}: ${what}${reason.trim() ? ` — ${reason.trim()}` : ''}`;
      const { error: err } = await supabase.rpc('request_change', { p_kind: 'stock_movement', p_branch_id: null, p_payload: payload, p_summary: summary });
      if (err) { setBusy(false); setError(dbErrorMessage(err, "We couldn't send this for approval. Please try again.")); return; }
      sentAny = true;
    } else if (filled.length) {
      const { error: err } = await supabase.rpc('post_inventory_movement', { p: payload });
      if (err) { setBusy(false); setError(dbErrorMessage(err, "We couldn't record this movement. Please try again.")); return; }
    }
    if (steps.length) {
      try {
        const res = await runSteps(steps, !canManage('inventory.adjust'));
        if (res.sent) sentAny = true;
      } catch (err) {
        setBusy(false);
        setError(`${filled.length ? 'The entry was recorded, but a correction failed: ' : ''}${dbErrorMessage(err, "We couldn't make the correction. Please try again.")}`);
        return;
      }
    }
    setBusy(false);
    if (sentAny) setSubmitted(true); else onPosted();
  }

  // After choosing what to do about each possible double entry
  async function continueWithChoices() {
    const { found, filled } = repeats;
    if (found.some(f => !choices[f.idx])) { setError('Choose what to do for each item.'); return; }
    const leaveOut = new Set();
    const steps = [];
    for (const f of found) {
      const c = choices[f.idx];
      const l = filled[f.idx];
      const item = items[l.key];
      const sym = unitById[item.stockUnitId]?.symbol ?? '';
      const qty = stockQty(l);
      const first = f.existing[0];
      if (c === 'skip' || c === 'keep_existing') leaveOut.add(f.idx);
      if (c === 'correct') {
        leaveOut.add(f.idx);
        const reason = `Opening balance entered again (${qtyText(qty)} ${sym}) — corrected to that figure`;
        steps.push(...planOpeningFix({ entries: f.existing, item, colorId: l.colorId || null, whById: Object.fromEntries(warehouses.map(w => [w.id, w])),
          target: { qty, warehouseId: first.warehouse_id, unitSymbol: sym }, reason }));
      }
      if (c === 'merge') {
        leaveOut.add(f.idx);
        const reason = `Opening balance entered again — ${qtyText(qty)} ${sym} merged into the existing entry`;
        steps.push({ kind: 'movement',
          payload: { type: 'adjustment', warehouse_id: first.warehouse_id, movement_date: first.transaction_date, reason,
            lines: [{ [item.kind === 'material' ? 'material_id' : 'product_id']: item.id, ...(l.colorId ? { color_id: l.colorId } : {}), quantity: qty, unit_id: item.stockUnitId }] },
          summary: `Adjustment at ${warehouseLabel(warehouses.find(w => w.id === first.warehouse_id))}, dated ${first.transaction_date}: add ${qtyText(qty)} ${sym} ${item.name} — ${reason}` });
      }
    }
    await send(filled.filter((_, i) => !leaveOut.has(i)), steps);
  }

  if (submitted) {
    return (
      <Modal title={def.noun} onClose={onPosted}
        footer={<button type="button" className="btn btn-primary" onClick={onPosted}>Done</button>}>
        <p className="text-sm">Sent for an admin's approval. Stock changes once it is approved — follow it under <strong>Approvals</strong>.</p>
      </Modal>
    );
  }

  // Receipts carry no cost: what goods cost is recorded on the purchase (035)
  const withCost = type === 'opening_balance';

  return (
    <Modal title={repeats ? 'Possible double entry' : def.noun} onClose={onClose} size="lg"
      footer={repeats ? <>
        <button type="button" className="btn btn-outline" onClick={() => { setRepeats(null); setError(''); }}>Back</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || repeats.found.some(f => !choices[f.idx])} onClick={continueWithChoices}>
          Continue
        </button>
      </> : <>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="movement-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !allowed.length}>
          {needsApproval ? 'Submit for approval' : `Post ${def.noun.toLowerCase()}`}
        </button>
      </>}>
      {repeats && (
        <RepeatChoices repeats={repeats} type={type} def={def} wh={wh} items={items} unitById={unitById} colorById={colorById}
          warehouses={warehouses} stockQty={stockQty} choices={choices} setChoices={setChoices} error={error} />
      )}
      <form id="movement-form" className="modal-form" onSubmit={post} hidden={!!repeats}>
        <p className="text-sm text-muted">{def.help} Posted movements can't be edited — a mistake is undone with a reversal.</p>
        {error && !repeats && <div className="alert alert-error" role="alert">{error}</div>}
        {needsApproval && allowed.length > 0 && (
          <div className="alert alert-info" role="note">{date < today ? 'Backdated entries' : type === 'count' ? "Count differences" : 'Corrections'} need an admin's approval: this is sent to the Approvals queue and changes stock once approved.</div>
        )}
        {!allowed.length ? (
          <p className="text-sm">You don't have permission for this at any store.</p>
        ) : <>
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="mv-wh">{type === 'transfer' ? 'From' : 'Store'}</label>
              <select id="mv-wh" className="form-input" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
                {allowed.map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
              </select>
            </div>
            {type === 'transfer' ? (
              <div className="form-group">
                <label className="form-label" htmlFor="mv-to">To</label>
                <select id="mv-to" className="form-input" value={toWarehouseId} onChange={e => setToWarehouseId(e.target.value)}>
                  <option value="">Choose…</option>
                  {warehouses.filter(w => w.status === 'active' && w.id !== warehouseId).map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
                </select>
              </div>
            ) : (
              <div className="form-group">
                <label className="form-label" htmlFor="mv-date">Date</label>
                <input id="mv-date" type="date" className="form-input" max={today} value={date} disabled={!canBackdate}
                  onChange={e => setDate(e.target.value)} />
                <span className="form-hint">{canBackdate ? (date < today ? 'Earlier date: stock is checked as of then and at every later date.' : 'Today, or an earlier date if this happened before.') : 'Today only — earlier dates need stock-adjustment permission.'}</span>
              </div>
            )}
          </div>
          <div className="form-row">
            {type === 'receipt' ? (
              <SupplierField suppliers={suppliers} value={supplier} onChange={setSupplier} />
            ) : type === 'transfer' ? (
              <div className="form-group">
                <label className="form-label" htmlFor="mv-date">Date</label>
                <input id="mv-date" type="date" className="form-input" max={today} value={date} disabled={!canBackdate}
                  onChange={e => setDate(e.target.value)} />
                <span className="form-hint">{canBackdate ? (date < today ? 'Earlier date: stock is checked as of then and at every later date.' : 'Today, or an earlier date if this happened before.') : 'Today only — earlier dates need stock-adjustment permission.'}</span>
              </div>
            ) : (
              <div className="form-group">
                <label className="form-label" htmlFor="mv-reason">Reason{type === 'adjustment' ? '' : ' (optional)'}</label>
                <input id="mv-reason" className="form-input" required={type === 'adjustment'}
                  placeholder={type === 'adjustment' ? 'e.g. damaged in storage' : type === 'issue' ? 'e.g. production' : ''}
                  value={reason} onChange={e => setReason(e.target.value)} />
              </div>
            )}
            <div className="form-group">
              <label className="form-label" htmlFor="mv-ref">Reference (optional)</label>
              <input id="mv-ref" className="form-input" placeholder="e.g. delivery note no." value={reference} onChange={e => setReference(e.target.value)} />
            </div>
          </div>

          <section>
            <h3 className="modal-section-title">Items</h3>
            {twice.map(g => (
              <div key={g.join()} className="alert alert-warning mb-8 flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
                <AlertTriangle size={14} />
                <span><strong>{items[lines[g[0]].key].name}{lines[g[0]].colorId ? ` (${colorById[lines[g[0]].colorId]?.name})` : ''}</strong> is entered {g.length === 2 ? 'twice' : `${g.length} times`}.</span>
                <button type="button" className="btn btn-outline btn-sm" onClick={() => mergeLines(g)}>Merge into one line</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setLines(ls => ls.filter((_, i) => !g.slice(1).includes(i)))}>Keep the first only</button>
              </div>
            ))}
            <div className="ingredient-list">
              {lines.map((l, i) => {
                const item = items[l.key];
                const needsColour = !!item?.colorIds?.length;
                const bal = l.key && (!needsColour || l.colorId) ? balanceOf(l) : null;
                const sq = stockQty(l);
                const stockSym = unitById[item?.stockUnitId]?.symbol ?? '';
                let preview = '';
                const when = date < today ? ` on ${date}` : '';
                if (item && bal != null) {
                  if (type === 'count') preview = sq != null ? `records${when} ${qtyText(bal)} ${stockSym} → difference ${sq - bal >= 0 ? '+' : ''}${qtyText(sq - bal)}` : `records ${qtyText(bal)} ${stockSym}`;
                  else if (type === 'issue' || type === 'transfer' || (type === 'adjustment' && l.direction === 'remove')) preview = `${qtyText(bal)} ${stockSym} in stock${when}${sq != null && sq > bal ? ' — not enough' : ''}`;
                  else preview = `${qtyText(bal)} ${stockSym} in stock${when}${sq != null && l.unitId !== item.stockUnitId ? ` · adds ${qtyText(sq)} ${stockSym}` : ''}`;
                }
                return (
                  <div key={i} className="movement-line">
                    <div className="movement-line-main">
                      <select className="form-input" style={{ flex: '0 0 auto', width: 'auto' }} aria-label="Type" value={l.kind} onChange={e => setLine(i, { kind: e.target.value })}>
                        <option value="material">Material</option>
                        <option value="product">Product</option>
                      </select>
                      <select className="form-input" aria-label="Item" value={l.key} onChange={e => setLine(i, { key: e.target.value })}>
                        <option value="">{l.kind === 'product' ? 'Product…' : 'Material…'}</option>
                        {l.kind === 'product'
                          ? products.map(p => <option key={p.key} value={p.key}>{p.name} · {p.category}</option>)
                          : materials.map(m => <option key={m.key} value={m.key} disabled={!m.stockUnitId}>{m.name}{!m.stockUnitId ? ' (set stock unit first)' : ''}</option>)}
                      </select>
                      {needsColour && (
                        <select className="form-input" aria-label="Colour" value={l.colorId} onChange={e => setLine(i, { colorId: e.target.value })}>
                          <option value="">Colour…</option>
                          {item.colorIds.map(c => <option key={c} value={c}>{colorById[c]?.name}{colorById[c]?.is_active === false ? ' (discontinued)' : ''}</option>)}
                        </select>
                      )}
                      {type === 'adjustment' && (
                        <select className="form-input" aria-label="Direction" value={l.direction} onChange={e => setLine(i, { direction: e.target.value })}>
                          <option value="remove">Remove</option>
                          <option value="add">Add</option>
                        </select>
                      )}
                      <NumberInput step="any" min="0" className="form-input" aria-label={type === 'count' ? 'Quantity found' : 'Quantity'}
                        placeholder={type === 'count' ? 'Found' : 'Qty'} value={l.quantity} onChange={e => setLine(i, { quantity: e.target.value })} />
                      <select className="form-input" aria-label="Unit" value={l.unitId} onChange={e => setLine(i, { unitId: e.target.value })} disabled={!item}>
                        {(item?.units || []).map(u => <option key={u.id} value={u.id}>{unitById[u.id]?.symbol}</option>)}
                      </select>
                      {withCost && (
                        <NumberInput step="any" min="0" className="form-input" aria-label="Cost per unit"
                          placeholder="Cost / unit" value={l.unitCost} onChange={e => setLine(i, { unitCost: e.target.value })} />
                      )}
                      <button type="button" className="icon-btn" aria-label="Remove line" onClick={() => setLines(ls => ls.length > 1 ? ls.filter((_, j) => j !== i) : [emptyLine(l.kind)])}>
                        <Trash2 size={14} />
                      </button>
                    </div>
                    {preview && <div className={`text-xs ${preview.includes('not enough') ? 'text-error' : 'text-muted'}`}>{preview}</div>}
                    {item && wh && !fitsStore(item, wh) && (type === 'opening_balance' || type === 'receipt') && (
                      <div className="text-xs text-warning">{item.kind === 'material' ? `${item.name} is a material — ${wh.name} is a finished-goods store.` : `${item.name} is a product — ${wh.name} is not the finished-goods store.`}</div>
                    )}
                  </div>
                );
              })}
            </div>
            <button type="button" className="btn btn-ghost btn-sm mt-8" onClick={() => setLines(ls => [...ls, emptyLine(ls.at(-1)?.kind ?? kindForStore(wh))])}>
              <Plus size={13} /> Add item
            </button>
            {withCost && <p className="text-xs text-muted mt-8">Cost is optional, per unit as entered (e.g. per bag).</p>}
            {type === 'receipt' && <p className="text-xs text-muted mt-8">What it cost, and the supplier's invoice and payment, are recorded on the purchase (Purchases page) — by the secretary or branch manager.</p>}
          </section>

          <div className="form-group">
            <label className="form-label" htmlFor="mv-notes">Notes (optional)</label>
            <input id="mv-notes" className="form-input" value={notes} onChange={e => setNotes(e.target.value)} />
          </div>
        </>}
      </form>
    </Modal>
  );
}

/**
 * Supplier for a receipt: pick an existing one, or type a new name. Names
 * equal ignoring case/spacing/punctuation are the same supplier (the
 * database refuses a second); close matches are suggested before a new one
 * is created, which happens only when the receipt is posted.
 */
function SupplierField({ suppliers, value, onChange }) {
  const active = suppliers.filter(s => s.status === 'active');
  const [text, setText] = useState('');
  const chosen = value?.id ? suppliers.find(s => s.id === value.id) : null;
  const { exact, similar } = matchSuppliers(text, active);

  function type(t) {
    setText(t);
    const m = matchSuppliers(t, active);
    if (!t.trim()) onChange(null);
    else if (m.exact) onChange({ id: m.exact.id });
    else onChange({ newName: t.trim(), pendingConfirm: m.similar.length > 0 });
  }

  if (chosen) {
    return (
      <div className="form-group">
        <span className="form-label">Supplier</span>
        <div className="flex items-center gap-8 text-sm">
          <span className="badge badge-accent">{chosen.name}</span>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setText(''); onChange(null); }}>Change</button>
        </div>
      </div>
    );
  }
  return (
    <div className="form-group">
      <label className="form-label" htmlFor="mv-sup">Supplier (optional)</label>
      <input id="mv-sup" className="form-input" list="mv-sup-list" autoComplete="off" placeholder="Type to find or add"
        value={text} onChange={e => type(e.target.value)} />
      <datalist id="mv-sup-list">{active.map(s => <option key={s.id} value={s.name} />)}</datalist>
      {text.trim() && !exact && (
        similar.length > 0 ? (
          <div className="text-xs mt-8">
            <span className="text-muted">Did you mean </span>
            {similar.map(s => (
              <button key={s.id} type="button" className="btn btn-ghost btn-sm" onClick={() => { setText(s.name); onChange({ id: s.id }); }}>{s.name}</button>
            ))}
            {value?.pendingConfirm ? (
              <button type="button" className="btn btn-outline btn-sm" onClick={() => onChange({ newName: text.trim(), pendingConfirm: false })}>
                No — add “{text.trim()}” as new
              </button>
            ) : <span className="text-muted"> · “{text.trim()}” will be added as a new supplier</span>}
          </div>
        ) : <span className="form-hint">New supplier — added when this receipt is posted.</span>
      )}
    </div>
  );
}

/**
 * What to do about each line that may repeat an entry already posted
 * (2026-10-17): leave it out, merge it into the existing entry, correct
 * the existing entry, or post it anyway.
 */
function RepeatChoices({ repeats, type, def, wh, items, unitById, colorById, warehouses, stockQty, choices, setChoices, error }) {
  const store = id => warehouses.find(w => w.id === id)?.name ?? 'a store';
  return (
    <div className="modal-form">
      <div className="alert alert-warning" role="note">
        {repeats.found.length === 1 ? 'This entry may repeat one already recorded.' : `${repeats.found.length} items may repeat entries already recorded.`} Choose what is right before anything is posted.
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {repeats.found.map(f => {
        const l = repeats.filled[f.idx];
        const item = items[l.key];
        const name = `${item.name}${l.colorId ? ` (${colorById[l.colorId]?.name})` : ''}`;
        const sym = unitById[item.stockUnitId]?.symbol ?? '';
        const qty = stockQty(l);
        const first = f.existing[0];
        const opts = type === 'opening_balance' ? [
          ['keep_existing', <>Keep what is already recorded — leave {item.name} out of this entry</>],
          ['merge', <>Merge: add <strong>{qtyText(qty)} {sym}</strong> to the {store(first.warehouse_id)} entry (total {qtyText(Number(first.quantity) + qty)} {sym})</>],
          ['correct', <>Correct it: the opening stock is <strong>{qtyText(qty)} {sym}</strong>, in {store(first.warehouse_id)}{f.existing.length > 1 ? ' (the other entries are undone)' : ''}</>],
          // separate stock only makes sense in a store that has no entry yet
          ...(f.existing.some(e => e.warehouse_id === wh.id) ? [] : [['post', <>Both are right — {qtyText(qty)} {sym} is separate stock in {wh.name}</>]]),
        ] : [
          ['skip', <>It's the same one — leave {item.name} out</>],
          ['post', <>It's a different {def.noun.toLowerCase()} — post it too</>],
        ];
        return (
          <div key={f.idx} className="confirm-box text-sm">
            <div>
              <strong>{name}</strong>{type === 'opening_balance' ? ` already has ${f.existing.length === 1 ? 'an opening balance' : `${f.existing.length} opening balances`} at ${wh.branch?.name ?? 'this branch'}:` : ` — the same ${def.noun.toLowerCase()} is already recorded:`}
              <ul className="double-entry-entries">
                {f.existing.map(e => (
                  <li key={e.id}>{qtyText(Math.abs(Number(e.quantity)))} {sym} in {store(e.warehouse_id)}, dated {e.transaction_date} <span className="text-muted">· entered {e.created_at.slice(0, 10)}</span></li>
                ))}
              </ul>
              <div>This entry: <strong>{qtyText(qty)} {sym}</strong> in {wh.name}{!fitsStore(item, wh) ? <span className="text-warning"> — {item.kind === 'material' ? 'a material in a finished-goods store' : 'a product outside the finished-goods store'}</span> : ''}</div>
            </div>
            <div className="double-entry-options">
              {opts.map(([v, label]) => (
                <label key={v} className={`double-entry-option${choices[f.idx] === v ? ' is-on' : ''}`}>
                  <input type="radio" name={`rep-${f.idx}`} checked={choices[f.idx] === v} onChange={() => setChoices(c => ({ ...c, [f.idx]: v }))} />
                  <span>{label}</span>
                </label>
              ))}
            </div>
          </div>
        );
      })}
      <p className="text-xs text-muted">Corrections are posted as adjustments or reversals — nothing is deleted from the history.</p>
    </div>
  );
}
