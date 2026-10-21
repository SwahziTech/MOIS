import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { productColorIds } from '../../lib/inventory';

/**
 * A product's colours (046), in its edit window. A product follows its
 * category's colours until an admin switches colours on or off here; then it
 * has its own list (none = not coloured). Stock in a colour being switched
 * off is never stranded: the database refuses and names it, and the admin
 * picks the colour (or no colour) it moves to.
 */
export default function ProductColours({ product, categoryName, canEdit, onSaved }) {
  const [palette, setPalette] = useState(null);   // null = loading; [] when 046 isn't live
  const [catColors, setCatColors] = useState([]);
  const [own, setOwn] = useState(false);
  const [saved, setSaved] = useState([]);          // colour ids as stored
  const [chosen, setChosen] = useState([]);        // colour ids being edited
  const [stuck, setStuck] = useState(null);        // { message, ids, toCategory } when some stock must move
  const [moveTo, setMoveTo] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const [pal, cc, pc, pr] = await Promise.all([
      supabase.from('color_palette').select('id, name, display_order, is_active').order('display_order'),
      supabase.from('product_category_colors').select('category_id, color_id, display_order').eq('category_id', product.category_id),
      supabase.from('product_colors').select('product_id, color_id, display_order').eq('product_id', product.id),
      supabase.from('products').select('*').eq('id', product.id).maybeSingle(),
    ]);
    if (pal.error || pc.error || cc.error || pr.error || !('own_colors' in (pr.data ?? {}))) { setPalette([]); return; }
    const ids = productColorIds(pr.data, cc.data, pc.data);
    setPalette(pal.data || []);
    setCatColors((cc.data || []).sort((a, b) => a.display_order - b.display_order).map(c => c.color_id));
    setOwn(!!pr.data.own_colors);
    setSaved(ids);
    setChosen(ids);
  }
  useEffect(() => { load(); }, [product.id]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!palette?.length) return null;
  const name = id => palette.find(c => c.id === id)?.name ?? '—';
  const shown = palette.filter(c => c.is_active || chosen.includes(c.id) || saved.includes(c.id));
  const sameSet = (a, b) => a.length === b.length && a.every(x => b.includes(x));
  const changed = !sameSet(chosen, saved);
  const inPaletteOrder = ids => palette.filter(c => ids.includes(c.id)).map(c => c.id);

  function toggle(id) {
    setStuck(null); setError('');
    setChosen(c => (c.includes(id) ? c.filter(x => x !== id) : inPaletteOrder([...c, id])));
  }

  async function save(toCategory = false) {
    setError('');
    setBusy(true);
    const ids = toCategory ? catColors : chosen;
    const { error: err } = await supabase.rpc('set_product_colors', {
      p_product: product.id, p_own: !toCategory, p_color_ids: toCategory ? [] : ids,
      p_move_to: stuck ? (moveTo || null) : null,   // only once the admin chose where the stock goes
    });
    setBusy(false);
    if (err) {
      if (err.hint === 'move_stock') { setStuck({ message: err.message, ids, toCategory }); setMoveTo(ids.length ? '' : 'none'); return; }
      setError(dbErrorMessage(err));
      return;
    }
    setStuck(null);
    await load();
    onSaved?.();
  }

  return (
    <section>
      <h3 className="modal-section-title">Colours</h3>
      <p className="text-xs text-muted" style={{ marginBottom: 6 }}>
        {own ? (saved.length ? 'Own colours' : 'No colours — not stocked by colour') : `Same as ${categoryName ?? 'its category'}${catColors.length ? '' : ' (no colours)'}`}
        {canEdit && ' · tap a colour to switch it on or off'}
      </p>
      <div className="filter-chips">
        {shown.map(c => (
          <button key={c.id} type="button" className={`filter-chip${chosen.includes(c.id) ? ' is-on' : ''}`} disabled={!canEdit || busy}
            aria-pressed={chosen.includes(c.id)} onClick={() => toggle(c.id)}>
            {c.name}{!c.is_active ? ' (discontinued)' : ''}
          </button>
        ))}
      </div>
      {stuck && (
        <div className="alert alert-warning mt-8" role="alert">
          <div className="text-sm">{stuck.message}</div>
          <div className="flex items-center gap-8 mt-8" style={{ flexWrap: 'wrap' }}>
            <label className="text-sm" htmlFor="pc-move">Move it to</label>
            <select id="pc-move" className="form-input" style={{ width: 'auto' }} value={moveTo} onChange={e => setMoveTo(e.target.value)}>
              {stuck.ids.length
                ? <><option value="">Choose a colour…</option>{stuck.ids.map(id => <option key={id} value={id}>{name(id)}</option>)}</>
                : <option value="none">No colour</option>}
            </select>
            <button type="button" className="btn btn-primary btn-sm" disabled={busy || !moveTo} onClick={() => save(stuck.toCategory)}>Move stock and save</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setStuck(null); setChosen(saved); }}>Cancel</button>
          </div>
        </div>
      )}
      {error && <p className="text-xs text-error mt-8">{error}</p>}
      {canEdit && !stuck && (changed || own) && (
        <div className="flex gap-8 mt-8" style={{ flexWrap: 'wrap' }}>
          {changed && <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => save(false)}>Save colours</button>}
          {changed && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => setChosen(saved)}>Undo</button>}
          {own && !changed && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => save(true)}>Use {categoryName ?? 'the category'}'s colours</button>}
        </div>
      )}
    </section>
  );
}
