import { useEffect, useMemo, useState } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';
import { MOVEMENT_TYPES, warehouseLabel, qtyText, stockKey, orgToday, matchSuppliers, isCorrective } from '../../lib/inventory';
import Modal from '../Modal';

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
    if (new Set(filled.map(l => `${l.key}|${l.colorId}`)).size !== filled.length) { setError('An item appears twice — combine the lines.'); return; }
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
    if (needsApproval) {
      const what = filled.map(l => {
        const sq = stockQty(l);
        return `${type === 'adjustment' ? (l.direction === 'remove' ? 'remove ' : 'add ') : ''}${qtyText(sq ?? l.quantity)} ${unitById[items[l.key].stockUnitId]?.symbol ?? ''} ${items[l.key].name}${l.colorId ? ` (${colorById[l.colorId]?.name})` : ''}`;
      }).join(', ');
      const summary = `${def.noun} at ${warehouseLabel(wh)}${date < today ? `, dated ${date}` : ''}: ${what}${reason.trim() ? ` — ${reason.trim()}` : ''}`;
      const { error: err } = await supabase.rpc('request_change', { p_kind: 'stock_movement', p_branch_id: null, p_payload: payload, p_summary: summary });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err, "We couldn't send this for approval. Please try again.")); return; }
      setSubmitted(true);
      return;
    }
    const { error: err } = await supabase.rpc('post_inventory_movement', { p: payload });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't record this movement. Please try again.")); return; }
    onPosted();
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
    <Modal title={def.noun} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="movement-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !allowed.length}>
          {needsApproval ? 'Submit for approval' : `Post ${def.noun.toLowerCase()}`}
        </button>
      </>}>
      <form id="movement-form" className="modal-form" onSubmit={post}>
        <p className="text-sm text-muted">{def.help} Posted movements can't be edited — a mistake is undone with a reversal.</p>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
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
                      <input type="number" step="any" min="0" className="form-input" aria-label={type === 'count' ? 'Quantity found' : 'Quantity'}
                        placeholder={type === 'count' ? 'Found' : 'Qty'} value={l.quantity} onChange={e => setLine(i, { quantity: e.target.value })} />
                      <select className="form-input" aria-label="Unit" value={l.unitId} onChange={e => setLine(i, { unitId: e.target.value })} disabled={!item}>
                        {(item?.units || []).map(u => <option key={u.id} value={u.id}>{unitById[u.id]?.symbol}</option>)}
                      </select>
                      {withCost && (
                        <input type="number" step="any" min="0" className="form-input" aria-label="Cost per unit"
                          placeholder="Cost / unit" value={l.unitCost} onChange={e => setLine(i, { unitCost: e.target.value })} />
                      )}
                      <button type="button" className="icon-btn" aria-label="Remove line" onClick={() => setLines(ls => ls.length > 1 ? ls.filter((_, j) => j !== i) : [emptyLine(l.kind)])}>
                        <Trash2 size={14} />
                      </button>
                    </div>
                    {preview && <div className={`text-xs ${preview.includes('not enough') ? 'text-error' : 'text-muted'}`}>{preview}</div>}
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
