import { useState } from 'react';
import { ChevronDown } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { categoryTools } from '../../lib/categories';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

const numOrNull = v => (String(v ?? '').trim() === '' ? null : Number(v));
const sameName = (a, b) => a.trim().toLowerCase().replace(/\s+/g, ' ') === b.trim().toLowerCase().replace(/\s+/g, ' ');
const sameSet = (a, b) => a.length === b.length && a.every(x => b.includes(x));

/**
 * Add or edit a product in one short form (SwahziTech, 2026-10-23): name,
 * category, size, wastani, the branch's molds, unit (m² or pieces), pieces
 * per m², colours, and the branch's reorder level. Tolerance, notes, merge,
 * review flags and history sit under "More". Products are never deleted —
 * they are deactivated, keeping their prices, recipes and history.
 *
 * Saving writes, in order: the product (org admins), the branch's list row
 * (reorder level), the branch's molds, then the colours through
 * set_product_colors() — which may ask where stock in a colour switched off
 * should go.
 */
export default function ProductEditModal({ product, organization, categories, units, products, branchId, branchName,
  canWrite, canBranch, capacityRow, branchRow, palette, colorIds, onHand, renderMore, onClose, onSaved }) {
  const isNew = !product.id;
  const catTools = categoryTools(categories);
  const sqmUnit = units.find(u => /^(sqm|m²)$/i.test(u.symbol));
  const pcsUnit = units.find(u => /^pcs$/i.test(u.symbol));
  const [name, setName] = useState(product.canonical_name ?? '');
  const [category, setCategory] = useState(product.category_id ?? '');
  const [size, setSize] = useState(product.size_cm ?? '');
  const [wastani, setWastani] = useState(product.wastani_per_bag ?? '');
  const [molds, setMolds] = useState(capacityRow?.molds ?? '');
  const [unitId, setUnitId] = useState(product.unit_id ?? '');
  const [perSqm, setPerSqm] = useState(product.pcs_per_sqm ?? '');
  const [reorder, setReorder] = useState(branchRow?.reorder_level ?? '');
  // labour norm (057): "3" or "2-3" bags one person casts in a day
  const lab0 = branchRow?.labour?.min != null ? (Number(branchRow.labour.min) === Number(branchRow.labour.max) ? String(+branchRow.labour.min) : `${+branchRow.labour.min}-${+branchRow.labour.max}`) : '';
  const [perPerson, setPerPerson] = useState(lab0);
  const [tolerance, setTolerance] = useState(product.yield_tolerance ?? '');
  const [notes, setNotes] = useState(product.notes ?? '');
  const catColours = cid => (categories.find(c => c.id === cid)?.colors ?? []);
  const [chosen, setChosen] = useState(isNew ? [] : colorIds);
  const [coloursTouched, setColoursTouched] = useState(false);
  // a product with no colours shows just that, until someone adds colours (SwahziTech, 2026-10-23)
  const [pickColours, setPickColours] = useState(() => (isNew ? catColours(product.category_id ?? '').length > 0 : colorIds.length > 0));
  const [stuck, setStuck] = useState(null);      // { message, ids } — stock in a colour switched off
  const [moveTo, setMoveTo] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const recipeLinks = product.recipes?.[0]?.count ?? 0;
  const unitLocked = !isNew && Number(onHand || 0) !== 0;
  const isSqm = unitId && unitId === sqmUnit?.id;
  const choosableCategories = catTools.leaves.filter(c => c.status === 'active' || c.id === product.category_id);
  // a new product starts with its category's colours
  const shownColours = isNew && !coloursTouched ? catColours(category) : chosen;

  function chooseCategory(id) {
    setCategory(id);
    if (isNew && !coloursTouched) setPickColours(catColours(id).length > 0);   // a new product starts with its category's colours
    const suggested = categories.find(c => c.id === id)?.default_unit_id;
    if (isNew && suggested && !unitId) setUnitId(suggested);
  }
  function toggleColour(id) {
    setStuck(null);
    const base = shownColours;
    setColoursTouched(true);
    setChosen((base.includes(id) ? base.filter(x => x !== id) : [...base, id]).sort((a, b) =>
      (palette.find(c => c.id === a)?.display_order ?? 0) - (palette.find(c => c.id === b)?.display_order ?? 0)));
  }

  async function save(e) {
    e?.preventDefault();
    setError('');
    if (canWrite) {
      if (!name.trim() || !category || !unitId) { setError('Enter the name, category and unit.'); return; }
      const clash = products.find(p => p.id !== product.id && p.status === 'active' && p.category_id === category && sameName(p.canonical_name, name));
      if (clash) { setError(`"${clash.canonical_name}" already exists in this category.`); return; }
      for (const [label, v] of [['Wastani', wastani], ['Pieces per m²', isSqm ? perSqm : '']]) {
        const n = numOrNull(v);
        if (n !== null && !(n > 0)) { setError(`${label} must be above zero, or blank if not known.`); return; }
      }
      const tol = numOrNull(tolerance);
      if (tol !== null && !(tol >= 0)) { setError('Yield tolerance must be zero or more, or blank.'); return; }
    }
    const m = numOrNull(molds);
    if (m !== null && !(Number.isInteger(m) && m > 0)) { setError('Molds: a whole number above zero, or blank.'); return; }
    const r = numOrNull(reorder);
    if (r !== null && !(r >= 0)) { setError('Reorder level: zero or more, or blank.'); return; }
    const pp = perPerson.trim() === '' ? null : perPerson.split(/[-–]/).map(x => Number(x.trim()));
    if (pp && (pp.length > 2 || pp.some(x => !(x > 0)) || (pp.length === 2 && pp[0] > pp[1]))) { setError('Bags a person: a number like 3, or a range like 2-3, or blank.'); return; }

    setBusy(true);
    const fail = msg => { setBusy(false); setError(msg); };
    let id = product.id;
    if (canWrite) {
      const row = {
        canonical_name: name.trim(), category_id: category, unit_id: unitId, size_cm: size.trim() || null,
        wastani_per_bag: numOrNull(wastani), pcs_per_sqm: isSqm ? numOrNull(perSqm) : null,
        yield_tolerance: numOrNull(tolerance), notes: notes.trim() || null,
      };
      const { data, error: err } = isNew
        ? await supabase.from('products').insert({ ...row, organization_id: organization.id, product_id_ref: nextProductRef(categories.find(c => c.id === category)?.category_id_ref, products) }).select('id').single()
        : await supabase.from('products').update(row).eq('id', product.id).select('id').single();
      if (err) return fail(dbErrorMessage(err));
      id = data.id;
    }

    // the branch's list: a new product joins it; the reorder level lives there
    if (branchId) {
      if (isNew) {
        const { error: err } = await supabase.from('branch_products').insert({ organization_id: organization.id, branch_id: branchId, product_id: id, ...(r !== null ? { reorder_level: r } : {}) });
        if (err) return fail(`Saved, but not added to ${branchName}'s list: ${dbErrorMessage(err)}`);
      } else if (branchRow?.id && numOrNull(branchRow.reorder_level) !== r) {
        const { error: err } = await supabase.from('branch_products').update({ reorder_level: r }).eq('id', branchRow.id);
        if (err) return fail(dbErrorMessage(err));
      }
      // the labour norm (057): bags a person, on the branch's list
      if (branchRow?.id && perPerson.trim() !== lab0) {
        const { error: err } = await supabase.from('branch_products').update({ bags_per_person_min: pp ? pp[0] : null, bags_per_person_max: pp ? pp[pp.length - 1] : null }).eq('id', branchRow.id);
        if (err) return fail(dbErrorMessage(err));
      }
      // the branch's molds (press products keep their bags a day)
      if (numOrNull(capacityRow?.molds) !== m) {
        const hasBags = capacityRow?.bags_per_day_min != null || capacityRow?.bags_per_day_max != null;
        const { error: err } = capacityRow?.id
          ? (m === null && !hasBags
            ? await supabase.from('branch_product_capacity').delete().eq('id', capacityRow.id)
            : await supabase.from('branch_product_capacity').update({ molds: m }).eq('id', capacityRow.id))
          : m !== null ? await supabase.from('branch_product_capacity').insert({ organization_id: organization.id, branch_id: branchId, product_id: id, molds: m }) : { error: null };
        if (err) return fail(dbErrorMessage(err));
      }
    }

    // colours, only when changed (a new product keeps its category's unless changed)
    if (canWrite && coloursTouched && !(isNew ? sameSet(chosen, catColours(category)) : sameSet(chosen, colorIds))) {
      const { error: err } = await supabase.rpc('set_product_colors', { p_product: id, p_own: true, p_color_ids: chosen, p_move_to: stuck ? (moveTo || null) : null });
      if (err) {
        setBusy(false);
        if (err.hint === 'move_stock') { setStuck({ message: err.message, ids: chosen }); setMoveTo(chosen.length ? '' : 'none'); return; }
        setError(dbErrorMessage(err));
        return;
      }
    }
    setBusy(false);
    onSaved();
  }

  async function toggleStatus() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('products').update({ status: product.status === 'active' ? 'inactive' : 'active' }).eq('id', product.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  const colourName = id => palette.find(c => c.id === id)?.name ?? '—';
  const colourChoices = palette.filter(c => c.is_active || shownColours.includes(c.id));
  return (
    <Modal title={isNew ? 'New product' : `Edit: ${product.canonical_name}`} onClose={onClose} size="md"
      footer={<>
        {!isNew && canWrite && (
          <button type="button" className={`btn ${product.status === 'active' ? 'btn-danger-outline' : 'btn-outline'} pe-left`} disabled={busy} onClick={toggleStatus}
            title={product.status === 'active' ? 'Hidden from new work; prices, recipes and history are kept' : ''}>
            {product.status === 'active' ? 'Deactivate' : 'Reactivate'}
          </button>
        )}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="pe-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>{isNew ? 'Add product' : 'Save changes'}</button>
      </>}>
      <form id="pe-form" className="pe" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <label className="pe-field"><span>Product name (as used in factory)</span>
          <input className="form-input" required autoFocus disabled={!canWrite} value={name} onChange={e => setName(e.target.value)} /></label>
        <div className="pe-row">
          <label className="pe-field"><span>Category</span>
            <select className="form-input" required value={category} disabled={!canWrite || (!isNew && recipeLinks > 0)} onChange={e => chooseCategory(e.target.value)}
              title={!isNew && recipeLinks > 0 ? 'Linked to recipes of this category — unlink them under Recipes to move it' : ''}>
              <option value="" disabled>Choose…</option>
              {choosableCategories.map(c => <option key={c.id} value={c.id}>{catTools.label(c)}{c.status !== 'active' ? ' (inactive)' : ''}</option>)}
            </select></label>
          <label className="pe-field pe-narrow"><span>Size</span>
            <input className="form-input" placeholder="e.g. 40x40" disabled={!canWrite} value={size} onChange={e => setSize(e.target.value)} /></label>
        </div>
        <div className="pe-row">
          <label className="pe-field"><span>Wastani (pcs / 50 kg bag)</span>
            <NumberInput step="any" min="0" className="form-input" placeholder="Not known" disabled={!canWrite} value={wastani} onChange={e => setWastani(e.target.value)} /></label>
          <label className="pe-field"><span>Molds{branchName ? ` at ${branchName}` : ''}</span>
            <NumberInput step="1" min="0" className="form-input" placeholder={capacityRow?.bags_per_day_max ? 'Press — bags a day' : 'Not set'} disabled={!branchId || !canBranch} value={molds} onChange={e => setMolds(e.target.value)} /></label>
        </div>
        <div className="pe-field"><span>Unit of measure</span>
          <div className="pe-toggle">
            {[sqmUnit && [sqmUnit.id, 'Square metre (m²)'], pcsUnit && [pcsUnit.id, 'Pieces (pcs)']].filter(Boolean).map(([uid, label]) => (
              <button key={uid} type="button" className={`pe-toggle-btn${unitId === uid ? ' is-on' : ''}`} disabled={!canWrite || unitLocked} onClick={() => setUnitId(uid)}>{label}</button>
            ))}
          </div>
          {unitId && unitId !== sqmUnit?.id && unitId !== pcsUnit?.id && <span className="pl-help">Counted in {units.find(u => u.id === unitId)?.name}.</span>}
          {unitLocked && <span className="pl-help">It has stock on hand, so its unit can't change.</span>}
        </div>
        {isSqm && (
          <label className="pe-field"><span>Pieces per square metre</span>
            <NumberInput step="any" min="0" className="form-input" placeholder="Not known" disabled={!canWrite} value={perSqm} onChange={e => setPerSqm(e.target.value)} /></label>
        )}
        <div className="pe-field"><span>Colours</span>
          {!pickColours ? (
            <div className="pe-nocolour">
              <span className="pc-unit">No colour</span>
              <span className="pl-help">Stocked as a single item.</span>
              {canWrite && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => setPickColours(true)}>Add colours</button>}
            </div>
          ) : (<>
            <div className="pe-colours">
              {colourChoices.map(c => (
                <button key={c.id} type="button" className={`pe-colour${shownColours.includes(c.id) ? ' is-on' : ''}`} disabled={!canWrite || busy} aria-pressed={shownColours.includes(c.id)} onClick={() => toggleColour(c.id)}>
                  <i style={{ background: c.name.toLowerCase() }} />{c.name}{shownColours.includes(c.id) ? ' ✓' : ''}
                </button>
              ))}
              {canWrite && shownColours.length > 0 && (
                <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => { setStuck(null); setColoursTouched(true); setChosen([]); setPickColours(false); }}>No colour</button>
              )}
            </div>
            {shownColours.length === 0 && <span className="pl-help">All off — it will be saved with no colour.</span>}
          </>)}
        </div>
        {stuck && (
          <div className="alert alert-warning">
            <div className="text-sm">{stuck.message}</div>
            <div className="flex items-center gap-8 mt-8" style={{ flexWrap: 'wrap' }}>
              <span className="text-sm">Move it to</span>
              <select className="form-input" style={{ width: 'auto' }} value={moveTo} onChange={e => setMoveTo(e.target.value)}>
                {stuck.ids.length ? <><option value="">Choose a colour…</option>{stuck.ids.map(id => <option key={id} value={id}>{colourName(id)}</option>)}</> : <option value="none">No colour</option>}
              </select>
              <button type="button" className="btn btn-primary btn-sm" disabled={busy || !moveTo} onClick={() => save()}>Move stock and save</button>
            </div>
          </div>
        )}
        {branchId && (
          <label className="pe-field"><span>Low-stock reorder level at {branchName}</span>
            <NumberInput step="any" min="0" className="form-input" placeholder="Not set" disabled={!canBranch || (!isNew && !branchRow?.id)} value={reorder} onChange={e => setReorder(e.target.value)} />
            {!isNew && !branchRow?.id && <span className="pl-help">Not in {branchName}'s list — add it there first.</span>}
            <span className="pl-help">In {units.find(u => u.id === unitId)?.symbol ?? 'its unit'}. Stock shows LOW below this.</span>
          </label>
        )}
        {branchId && !isNew && branchRow?.id && (
          <label className="pe-field"><span>Bags a person at {branchName}</span>
            <input className="form-input" inputMode="decimal" placeholder="e.g. 3 or 2-3 (blank: the machine's crew)" disabled={!canBranch} value={perPerson} onChange={e => setPerPerson(e.target.value)} />
            <span className="pl-help">Labour norm: cement bags one person casts in a day. Press products take the press crew instead (Production ⚙).</span>
          </label>
        )}
        {!isNew && canWrite && (
          <details className="pe-more">
            <summary><ChevronDown size={14} /> More — tolerance, notes, merge, review, history</summary>
            <div className="pe-more-body">
              <label className="pe-field"><span>Yield tolerance (± pieces per bag)</span>
                <NumberInput step="any" min="0" className="form-input" value={tolerance} onChange={e => setTolerance(e.target.value)}
                  placeholder={(() => { const d = categories.find(c => c.id === category)?.default_yield_tolerance; return d != null ? `Category default: ±${+d}` : 'Organization default'; })()} /></label>
              <label className="pe-field"><span>Notes</span>
                <textarea className="form-input" rows={2} value={notes} onChange={e => setNotes(e.target.value)} /></label>
              {renderMore?.()}
            </div>
          </details>
        )}
      </form>
    </Modal>
  );
}

function nextProductRef(categoryRef, products) {
  const taken = new Set(products.map(p => p.product_id_ref));
  let n = products.filter(p => p.product_id_ref.startsWith(`${categoryRef}_`)).length + 1;
  let ref;
  do { ref = `${categoryRef}_${String(n++).padStart(2, '0')}`; } while (taken.has(ref));
  return ref;
}
