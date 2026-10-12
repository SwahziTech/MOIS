import { useMemo, useState } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { MOVEMENT_TYPES, warehouseLabel, qtyText } from '../../lib/inventory';
import Modal from '../Modal';

const today = () => new Date().toISOString().slice(0, 10);
const emptyLine = () => ({ key: '', quantity: '', unitId: '', unitCost: '', direction: 'remove' });

/**
 * Record one stock movement. Everything is validated again and posted
 * atomically by post_inventory_movement() (migration 022); this form only
 * offers what the user may do and shows the effect before posting.
 */
export default function MovementModal({ type, refs, balances, defaultWarehouseId, onClose, onPosted }) {
  const { canAt } = useAuth();
  const def = MOVEMENT_TYPES[type];
  const { warehouses, items, unitById, suppliers } = refs;

  const allowed = warehouses.filter(w => w.status === 'active' && w.branch?.status !== 'inactive' && canAt(def.perm, w.branch_id, w.id));
  const [warehouseId, setWarehouseId] = useState(allowed.some(w => w.id === defaultWarehouseId) ? defaultWarehouseId : (allowed[0]?.id ?? ''));
  const [toWarehouseId, setToWarehouseId] = useState('');
  const [supplierId, setSupplierId] = useState('');
  const [date,      setDate]      = useState(today());
  const [reference, setReference] = useState('');
  const [reason,    setReason]    = useState('');
  const [notes,     setNotes]     = useState('');
  const [lines,     setLines]     = useState([emptyLine()]);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  const itemList = useMemo(() => Object.values(items).filter(i => i.status === 'active'), [items]);
  const materials = itemList.filter(i => i.kind === 'material');
  const products = itemList.filter(i => i.kind === 'product');
  const balanceOf = key => Number(balances[`${warehouseId}|${key}`] ?? 0);

  function setLine(i, patch) {
    setLines(ls => ls.map((l, j) => {
      if (j !== i) return l;
      const next = { ...l, ...patch };
      if (patch.key !== undefined) next.unitId = items[patch.key]?.stockUnitId ?? '';
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
    if (new Set(filled.map(l => l.key)).size !== filled.length) { setError('An item appears twice — combine the lines.'); return; }
    for (const l of filled) {
      const q = Number(l.quantity);
      if (l.quantity === '' || !Number.isFinite(q) || (type === 'count' ? q < 0 : q <= 0)) {
        setError(`${items[l.key].name}: enter a ${type === 'count' ? 'quantity of zero or more' : 'quantity above zero'}.`); return;
      }
    }
    if (type === 'transfer' && !toWarehouseId) { setError('Choose where the stock goes.'); return; }
    if (type === 'adjustment' && !reason.trim()) { setError('Give a reason for the adjustment.'); return; }

    const payload = {
      type, warehouse_id: warehouseId, movement_date: date,
      reference: reference.trim() || null, reason: reason.trim() || null, notes: notes.trim() || null,
      ...(type === 'transfer' ? { to_warehouse_id: toWarehouseId } : {}),
      ...(type === 'receipt' && supplierId ? { supplier_id: supplierId } : {}),
      lines: filled.map(l => {
        const item = items[l.key];
        const q = Number(l.quantity);
        return {
          [item.kind === 'material' ? 'material_id' : 'product_id']: item.id,
          quantity: type === 'adjustment' && l.direction === 'remove' ? -q : q,
          unit_id: l.unitId,
          ...((type === 'receipt' || type === 'opening_balance') && l.unitCost !== '' ? { unit_cost: Number(l.unitCost) } : {}),
        };
      }),
    };
    setBusy(true);
    const { error: err } = await supabase.rpc('post_inventory_movement', { p: payload });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't record this movement. Please try again.")); return; }
    onPosted();
  }

  const withCost = type === 'receipt' || type === 'opening_balance';

  return (
    <Modal title={def.noun} onClose={onClose} size="lg"
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="movement-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !allowed.length}>
          Post {def.noun.toLowerCase()}
        </button>
      </>}>
      <form id="movement-form" className="modal-form" onSubmit={post}>
        <p className="text-sm text-muted">{def.help} Posted movements can't be edited — a mistake is undone with a reversal.</p>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
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
                <input id="mv-date" type="date" className="form-input" max={today()} value={date} onChange={e => setDate(e.target.value)} />
              </div>
            )}
          </div>
          <div className="form-row">
            {type === 'receipt' ? (
              <div className="form-group">
                <label className="form-label" htmlFor="mv-sup">Supplier</label>
                <select id="mv-sup" className="form-input" value={supplierId} onChange={e => setSupplierId(e.target.value)}>
                  <option value="">Not recorded</option>
                  {suppliers.filter(s => s.status === 'active').map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
                </select>
              </div>
            ) : type === 'transfer' ? (
              <div className="form-group">
                <label className="form-label" htmlFor="mv-date">Date</label>
                <input id="mv-date" type="date" className="form-input" max={today()} value={date} onChange={e => setDate(e.target.value)} />
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
                const bal = l.key ? balanceOf(l.key) : null;
                const sq = stockQty(l);
                const stockSym = unitById[item?.stockUnitId]?.symbol ?? '';
                let preview = '';
                if (item && bal != null) {
                  if (type === 'count') preview = sq != null ? `records ${qtyText(bal)} ${stockSym} → difference ${sq - bal >= 0 ? '+' : ''}${qtyText(sq - bal)}` : `records ${qtyText(bal)} ${stockSym}`;
                  else if (type === 'issue' || type === 'transfer' || (type === 'adjustment' && l.direction === 'remove')) preview = `${qtyText(bal)} ${stockSym} in stock${sq != null && sq > bal ? ' — not enough' : ''}`;
                  else preview = `${qtyText(bal)} ${stockSym} in stock${sq != null && l.unitId !== item.stockUnitId ? ` · adds ${qtyText(sq)} ${stockSym}` : ''}`;
                }
                return (
                  <div key={i} className="movement-line">
                    <div className="movement-line-main">
                      <select className="form-input" aria-label="Item" value={l.key} onChange={e => setLine(i, { key: e.target.value })}>
                        <option value="">Item…</option>
                        <optgroup label="Materials">
                          {materials.map(m => <option key={m.key} value={m.key} disabled={!m.stockUnitId}>{m.name}{!m.stockUnitId ? ' (set stock unit first)' : ''}</option>)}
                        </optgroup>
                        <optgroup label="Products">
                          {products.map(p => <option key={p.key} value={p.key}>{p.name} · {p.category}</option>)}
                        </optgroup>
                      </select>
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
                      <button type="button" className="icon-btn" aria-label="Remove line" onClick={() => setLines(ls => ls.length > 1 ? ls.filter((_, j) => j !== i) : [emptyLine()])}>
                        <Trash2 size={14} />
                      </button>
                    </div>
                    {preview && <div className={`text-xs ${preview.includes('not enough') ? 'text-error' : 'text-muted'}`}>{preview}</div>}
                  </div>
                );
              })}
            </div>
            <button type="button" className="btn btn-ghost btn-sm mt-8" onClick={() => setLines(ls => [...ls, emptyLine()])}>
              <Plus size={13} /> Add item
            </button>
            {withCost && <p className="text-xs text-muted mt-8">Cost is optional, per unit as entered (e.g. per bag). It is recorded for costing later.</p>}
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
