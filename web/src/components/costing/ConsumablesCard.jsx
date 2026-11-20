import { useEffect, useMemo, useState } from 'react';
import { Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { categoryTools } from '../../lib/categories';
import { qtyText } from '../../lib/inventory';
import { dbErrorMessage } from '../../lib/masterData';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

/*
 * Consumables per bag (138; SwahziTech 2026-11-20): mould oil, soap — an
 * amount a bag of cement for the categories that use them. Not in the
 * recipes: every batch of those categories takes bags × amount out of its
 * store with the recipe materials, and their cost is part of the batch's.
 * Switched on once their stock is in (a batch can't take what isn't there).
 */
export default function ConsumablesCard({ branchId, refs }) {
  const { organization, canAt } = useAuth();
  const canEdit = canAt('products.manage', branchId, null);
  const [rows, setRows] = useState(null);   // null = loading; false = not set up (before 138)
  const [editing, setEditing] = useState(null);
  const cats = useMemo(() => categoryTools(refs?.categoryRows || []), [refs]);

  async function load() {
    const { data, error } = await supabase.from('production_consumables').select('*').eq('branch_id', branchId);
    setRows(error ? false : data || []);
  }
  useEffect(() => { setRows(null); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  if (rows === false || !refs) return null;
  const name = id => refs.items[`m:${id}`]?.name ?? '—';
  const sym = id => refs.unitById[id]?.symbol ?? '';
  return (
    <section className="card" style={{ marginBottom: 12 }}>
      <div className="card-header" style={{ gap: 8 }}>
        <h2 className="card-title" title="Not in the recipes: each batch of these categories takes bags × the amount out of its store, and their cost goes into the batch's cost">Consumables a bag of cement ⓘ</h2>
        {canEdit && <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setEditing({})}><Plus size={13} /> Add</button>}
      </div>
      <div className="card-body" style={{ paddingTop: 4 }}>
        {rows === null ? <span className="skeleton" />
        : rows.length === 0 ? <p className="text-sm text-muted">None yet — e.g. mafuta and sabuni for floor tiles.</p>
        : (
          <table className="rd-table">
            <thead><tr><th>Material</th><th className="num">A bag</th><th>For</th><th>Status</th>{canEdit && <th aria-label="Actions" />}</tr></thead>
            <tbody>
              {[...rows].sort((a, b) => name(a.material_id).localeCompare(name(b.material_id))).map(r => (
                <tr key={r.id} className={r.status === 'active' ? '' : 'text-muted'}>
                  <td><strong>{name(r.material_id)}</strong></td>
                  <td className="num">{qtyText(Number(r.quantity_per_bag))} <span className="pl-help">{sym(r.unit_id)}</span></td>
                  <td className="text-sm">{(r.category_ids || []).map(id => cats.label(id)).join(', ') || <span className="text-warning">no category</span>}</td>
                  <td><span className={`badge ${r.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{r.status === 'active' ? 'On' : 'Off'}</span></td>
                  {canEdit && <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(r)}>Edit</button></td>}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {editing && <ConsumableModal row={editing} branchId={branchId} organizationId={organization?.id} refs={refs} cats={cats} taken={(rows || []).map(r => r.material_id)}
        onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />}
    </section>
  );
}

function ConsumableModal({ row, branchId, organizationId, refs, cats, taken, onClose, onSaved }) {
  const isNew = !row.id;
  const [materialId, setMaterialId] = useState(row.material_id ?? '');
  const mat = refs.items[`m:${materialId}`];
  const [unitId, setUnitId] = useState(row.unit_id ?? '');
  const [qty, setQty] = useState(row.quantity_per_bag != null ? String(+row.quantity_per_bag) : '');
  const [catIds, setCatIds] = useState(row.category_ids ?? []);
  const [on, setOn] = useState(row.status ? row.status === 'active' : true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => { if (mat && !mat.units.some(u => u.id === unitId)) setUnitId(mat.mainUnitId ?? mat.stockUnitId ?? ''); }, [materialId]); // eslint-disable-line react-hooks/exhaustive-deps

  const materials = Object.values(refs.items).filter(i => i.kind === 'material' && i.status === 'active' && (!i.branchId || i.branchId === branchId)
    && (i.id === row.material_id || !taken.includes(i.id))).sort((a, b) => a.name.localeCompare(b.name));
  const categories = (refs.categoryRows || []).filter(c => c.status === 'active').sort(cats.compare);

  async function save(e) {
    e.preventDefault();
    setError('');
    const q = Number(qty);
    if (!materialId) { setError('Choose the material.'); return; }
    if (!(q > 0)) { setError('Enter the amount a bag of cement.'); return; }
    if (!catIds.length) { setError('Tick the categories that use it.'); return; }
    const values = { material_id: materialId, unit_id: unitId, quantity_per_bag: q, category_ids: catIds, status: on ? 'active' : 'inactive' };
    setBusy(true);
    const { error: err } = isNew
      ? await supabase.from('production_consumables').insert({ ...values, organization_id: organizationId, branch_id: branchId })
      : await supabase.from('production_consumables').update(values).eq('id', row.id);
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That material is already on the list.' : dbErrorMessage(err)); return; }
    onSaved();
  }
  async function remove() {
    setBusy(true);
    const { error: err } = await supabase.from('production_consumables').delete().eq('id', row.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Add a consumable' : `Edit ${mat?.name ?? ''}`} onClose={onClose}
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {!isNew && <button type="button" className="btn btn-ghost text-error" style={{ marginRight: 'auto' }} disabled={busy} onClick={remove}>Remove</button>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="consumable-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>Save</button>
      </>}>
      <form id="consumable-form" className="modal-form" onSubmit={save}>
        <div className="form-row">
          <label className="pe-field"><span>Material</span>
            <select className="form-input" value={materialId} disabled={!isNew} onChange={e => setMaterialId(e.target.value)}>
              <option value="">Choose…</option>
              {materials.map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select></label>
          <label className="pe-field" style={{ maxWidth: 140 }}><span>A bag of cement</span>
            <NumberInput step="any" min="0" className="form-input" value={qty} onChange={e => setQty(e.target.value)} /></label>
          <label className="pe-field" style={{ maxWidth: 140 }}><span>Unit</span>
            <select className="form-input" value={unitId} onChange={e => setUnitId(e.target.value)} disabled={!mat}>
              {(mat?.units || []).map(u => <option key={u.id} value={u.id}>{refs.unitById[u.id]?.symbol ?? '—'}</option>)}
            </select></label>
        </div>
        <div className="pe-field"><span>For these categories</span>
          <div className="flex gap-8" style={{ flexWrap: 'wrap' }}>
            {categories.map(c => (
              <button key={c.id} type="button" className={`filter-chip${catIds.includes(c.id) ? ' is-on' : ''}`}
                onClick={() => setCatIds(ids => (ids.includes(c.id) ? ids.filter(x => x !== c.id) : [...ids, c.id]))}>{cats.label(c)}</button>
            ))}
          </div>
        </div>
        <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={on} onChange={e => setOn(e.target.checked)} />
          On — batches take it from the store (turn on once its stock is entered)</label>
      </form>
    </Modal>
  );
}
