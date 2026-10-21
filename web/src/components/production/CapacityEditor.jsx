import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText } from '../../lib/inventory';
import NumberInput from '../NumberInput';

/**
 * A branch's capacity for one product (045): molds (vibro — one cast per
 * mold per day) or bags of cement a day (press — a usual range). Neither =
 * not defined. The branch manager keeps it; shown in product details.
 */
export default function CapacityEditor({ productId, branchId, branchName, organizationId, canEdit }) {
  const [row, setRow] = useState(undefined);   // undefined = loading, null = none
  const [editing, setEditing] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const { data, error: err } = await supabase.from('branch_product_capacity').select('*').eq('branch_id', branchId).eq('product_id', productId).maybeSingle();
    setRow(err ? null : data ?? null);
  }
  useEffect(() => { load(); }, [productId, branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const n = v => (String(v ?? '').trim() === '' ? null : Number(v));
  async function save() {
    setError('');
    const molds = n(editing.molds), lo = n(editing.lo), hi = n(editing.hi);
    if (molds != null && !(Number.isInteger(molds) && molds > 0)) { setError('Molds: a whole number above zero, or blank.'); return; }
    if ((lo != null && !(lo > 0)) || (hi != null && !(hi > 0)) || (lo != null && hi != null && lo > hi)) { setError('Bags a day: from ≤ to, both above zero.'); return; }
    setBusy(true);
    const fields = { molds, bags_per_day_min: lo, bags_per_day_max: hi };
    const { error: err } = row?.id
      ? (molds == null && lo == null && hi == null
        ? await supabase.from('branch_product_capacity').delete().eq('id', row.id)
        : await supabase.from('branch_product_capacity').update(fields).eq('id', row.id))
      : await supabase.from('branch_product_capacity').insert({ organization_id: organizationId, branch_id: branchId, product_id: productId, ...fields });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setEditing(null);
    load();
  }

  if (row === undefined) return null;
  const text = row?.molds ? `${qtyText(row.molds)} molds — up to ${qtyText(row.molds)} pcs a day`
    : row?.bags_per_day_min || row?.bags_per_day_max ? `${qtyText(row.bags_per_day_min ?? row.bags_per_day_max)}–${qtyText(row.bags_per_day_max ?? row.bags_per_day_min)} bags of cement a day`
    : 'Not defined';
  return (
    <section>
      <h3 className="modal-section-title">{branchName}'s capacity</h3>
      {editing ? (
        <div className="confirm-box">
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="cap-molds">Molds (vibro)</label>
              <NumberInput id="cap-molds" step="1" min="0" className="form-input" placeholder="—" value={editing.molds} onChange={e => setEditing(x => ({ ...x, molds: e.target.value }))} />
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="cap-lo">Bags a day (press), from</label>
              <NumberInput id="cap-lo" step="any" min="0" className="form-input" placeholder="—" value={editing.lo} onChange={e => setEditing(x => ({ ...x, lo: e.target.value }))} />
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="cap-hi">to</label>
              <NumberInput id="cap-hi" step="any" min="0" className="form-input" placeholder="—" value={editing.hi} onChange={e => setEditing(x => ({ ...x, hi: e.target.value }))} />
            </div>
          </div>
          {error && <span className="text-xs text-error">{error}</span>}
          <div className="flex gap-8">
            <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditing(null); setError(''); }}>Cancel</button>
          </div>
        </div>
      ) : (
        <p className="text-sm flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
          <span className={row ? '' : 'text-muted'}>{text}</span>
          {canEdit && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing({ molds: row?.molds ?? '', lo: row?.bags_per_day_min ?? '', hi: row?.bags_per_day_max ?? '' })}>Change…</button>}
        </p>
      )}
    </section>
  );
}
