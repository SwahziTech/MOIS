import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { qtyText } from '../../lib/inventory';

// Flags that ask "which product is this really?"
const IDENTITY_FLAGS = new Set(['import_placeholder', 'unresolved_identity', 'possible_duplicate']);

/**
 * "Here are your choices" for one Review-queue flag, in plain language.
 * - A product whose identity is open (import placeholder / possible
 *   duplicate): it's another product · its stock is several products ·
 *   it's a product in its own right (resolve_product_identity, migration 028)
 * - A name match to confirm: yes · no, it's another one (correcting the
 *   decision and, if needed, moving the stock that came in under it)
 * - Anything else: done · not needed
 */
export default function FlagChoices({ flag, name, refs, onDone }) {
  const kind = flag.entity_type === 'product' && IDENTITY_FLAGS.has(flag.reason_code) ? 'identity'
    : flag.entity_type === 'identity_decision' ? 'confirm' : 'other';
  const [choice, setChoice] = useState(null);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  // The admin's own words: saved as typed, never interpreted (migration 029 —
  // kept as data for the future AI features of build-plan 1f)
  const [text,  setText]  = useState(flag.admin_explanation ?? '');
  const [saved, setSaved] = useState(flag.admin_explanation ?? '');
  const [noteState, setNoteState] = useState('');

  async function saveNote() {
    const { error: err } = await supabase.from('review_flags').update({
      admin_explanation: text.trim() ? text : null, admin_explanation_by: refs.me.id, admin_explanation_at: new Date().toISOString(),
    }).eq('id', flag.id);
    if (err) return err;
    setSaved(text);
    return null;
  }

  async function run(fn) {
    setError('');
    setBusy(true);
    // whatever was typed is kept, whichever choice is made
    if (text !== saved) {
      const noteErr = await saveNote();
      if (noteErr) { setBusy(false); setError(dbErrorMessage(noteErr)); return; }
    }
    const err = await fn();
    setBusy(false);
    if (err) { setError(typeof err === 'string' ? err : dbErrorMessage(err, "That didn't work. Please try again.")); return; }
    onDone();
  }

  const closeFlag = (status, note) => run(async () => {
    const { error } = await supabase.from('review_flags').update({
      status, resolved_at: new Date().toISOString(), resolved_by: refs.me.id, resolution_note: note || null,
    }).eq('id', flag.id);
    return error;
  });

  return (
    <div className="flag-choices">
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!choice && (
        <div className="flex flex-col gap-4">
          <span className="text-xs text-muted">What would you like to do?</span>
          {kind === 'identity' && <>
            <button type="button" className="btn btn-outline btn-sm" onClick={() => setChoice('same_as')}>It's one of our existing products…</button>
            <button type="button" className="btn btn-outline btn-sm" onClick={() => setChoice('split')}>Its stock is several products…</button>
            <button type="button" className="btn btn-outline btn-sm" onClick={() => setChoice('keep')}>It's a product in its own right…</button>
          </>}
          {kind === 'confirm' && <>
            <button type="button" className="btn btn-outline btn-sm" disabled={busy}
              onClick={() => closeFlag('resolved', `Confirmed by ${refs.me.name}`)}>Yes, that's right</button>
            <button type="button" className="btn btn-outline btn-sm" onClick={() => setChoice('correct')}>No, it's something else…</button>
          </>}
          {kind === 'other' && <>
            <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={() => closeFlag('resolved', `Done — ${refs.me.name}`)}>Done, it's sorted</button>
            <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => closeFlag('dismissed', `Not needed — ${refs.me.name}`)}>Not needed</button>
          </>}
        </div>
      )}
      {choice && kind === 'identity' && (
        <IdentityChoice choice={choice} productId={flag.entity_id} name={name} refs={refs} busy={busy} run={run} onBack={() => setChoice(null)} />
      )}
      {choice === 'correct' && (
        <CorrectMatch decisionId={flag.entity_id} flag={flag} refs={refs} busy={busy} run={run} onBack={() => setChoice(null)} />
      )}
      <div className="flex flex-col gap-4 mt-8">
        <label className="text-xs text-muted" htmlFor={`explain-${flag.id}`}>Explain in your own words (optional)</label>
        <textarea id={`explain-${flag.id}`} className="form-input" rows={2} value={text}
          placeholder="Anything the choices above don't cover"
          onChange={e => { setText(e.target.value); setNoteState(''); }} />
        {text !== saved && (
          <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} disabled={busy}
            onClick={async () => { const err = await saveNote(); setNoteState(err ? 'failed' : 'saved'); if (err) setError(dbErrorMessage(err)); }}>
            Save note
          </button>
        )}
        {noteState === 'saved' && text === saved && <span className="text-xs text-success">Note saved.</span>}
      </div>
    </div>
  );
}

/** Stock a product holds, per store and colour */
function useStock(productId) {
  const [rows, setRows] = useState(null);
  useEffect(() => {
    if (!productId) { setRows([]); return; }
    supabase.from('stock_balances').select('warehouse_id, color_id, quantity, stock_unit_id').eq('product_id', productId)
      .then(({ data }) => setRows((data || []).filter(r => Number(r.quantity) > 0)));
  }, [productId]);
  return rows;
}

function ProductPick({ refs, value, onChange, excludeId, sameCategoryAs, label = 'Choose the product' }) {
  const products = refs.products.filter(p => p.status === 'active' && p.id !== excludeId);
  const first = products.filter(p => p.categoryId === sameCategoryAs);
  const rest = products.filter(p => p.categoryId !== sameCategoryAs);
  return (
    <select className="form-input" aria-label={label} value={value} onChange={e => onChange(e.target.value)}>
      <option value="">{label}…</option>
      {first.length > 0 && <optgroup label="Same category">{first.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>}
      <optgroup label="Other categories">{rest.map(p => <option key={p.id} value={p.id}>{p.name} — {refs.categoryName[p.categoryId]}</option>)}</optgroup>
    </select>
  );
}

const where = (refs, r) => `${refs.storeName[r.warehouse_id] ?? 'a store'}${r.color_id ? ` · ${refs.colorName[r.color_id]}` : ''}`;

function IdentityChoice({ choice, productId, name, refs, busy, run, onBack }) {
  const product = refs.products.find(p => p.id === productId);
  const stock = useStock(productId);
  const unit = r => refs.unitSymbol[r.stock_unit_id] ?? '';
  const [target, setTarget] = useState('');
  const [nots, setNots] = useState([]);
  const [parts, setParts] = useState({});   // `${wh}|${col}` → [{ productId, qty }]

  const key = r => `${r.warehouse_id}|${r.color_id ?? ''}`;
  const rowsFor = r => parts[key(r)] ?? [{ productId: '', qty: '' }, { productId: '', qty: '' }];
  const setRow = (r, i, patch) => setParts(ps => ({ ...ps, [key(r)]: rowsFor(r).map((x, j) => (j === i ? { ...x, ...patch } : x)) }));

  const submit = () => run(async () => {
    let p;
    if (choice === 'same_as') {
      if (!target) return 'Choose the product it really is.';
      p = { choice, target_product_id: target };
    } else if (choice === 'split') {
      const allocations = [];
      for (const r of stock) {
        const rows = rowsFor(r).filter(x => x.productId && Number(x.qty) > 0);
        const sum = rows.reduce((s, x) => s + Number(x.qty), 0);
        if (Math.abs(sum - Number(r.quantity)) > 1e-9) return `${where(refs, r)}: the parts add up to ${qtyText(sum)}, but there are ${qtyText(r.quantity)} ${unit(r)} — they must match.`;
        for (const x of rows) allocations.push({ warehouse_id: r.warehouse_id, color_id: r.color_id, product_id: x.productId, quantity: Number(x.qty) });
      }
      p = { choice, allocations };
    } else {
      p = { choice, not_products: nots };
    }
    const { error } = await supabase.rpc('resolve_product_identity', { p_product_id: productId, p });
    return error;
  });

  if (stock === null) return <p className="text-xs text-muted">Loading…</p>;
  const hasStock = stock.length > 0;
  return (
    <div className="flex flex-col gap-8">
      {choice === 'same_as' && <>
        <span className="text-sm">Which product is "{name}" really?</span>
        <ProductPick refs={refs} value={target} onChange={setTarget} excludeId={productId} sameCategoryAs={product?.categoryId} />
        <span className="text-xs text-muted">
          {hasStock ? `Its stock (${stock.map(r => `${qtyText(r.quantity)} ${unit(r)} at ${where(refs, r)}`).join('; ')}) moves to that product, dated when it was first recorded. ` : ''}
          "{name}" is then retired, and MOIS will treat that name as the chosen product from now on.
        </span>
      </>}
      {choice === 'split' && (hasStock ? <>
        <span className="text-sm">How does the stock of "{name}" divide between products?</span>
        {stock.map(r => (
          <div key={key(r)} className="flex flex-col gap-4">
            <span className="text-xs text-muted">{qtyText(r.quantity)} {unit(r)} at {where(refs, r)}</span>
            {rowsFor(r).map((x, i) => (
              <div key={i} className="flex gap-4">
                <ProductPick refs={refs} value={x.productId} onChange={v => setRow(r, i, { productId: v })} excludeId={productId}
                  sameCategoryAs={product?.categoryId} label="Product" />
                <input type="number" step="any" min="0" className="form-input" style={{ width: 90 }} aria-label="Quantity" placeholder={unit(r)}
                  value={x.qty} onChange={e => setRow(r, i, { qty: e.target.value })} />
              </div>
            ))}
            <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }}
              onClick={() => setParts(ps => ({ ...ps, [key(r)]: [...rowsFor(r), { productId: '', qty: '' }] }))}>+ another product</button>
          </div>
        ))}
        <span className="text-xs text-muted">Each part moves to its product, dated when the stock was first recorded. "{name}" is then retired.</span>
      </> : <span className="text-sm">"{name}" has no stock to divide — choose another option.</span>)}
      {choice === 'keep' && <>
        <span className="text-sm">"{name}" stays as a product of its own.</span>
        <span className="text-xs text-muted">Optional: products it is <strong>not</strong>, so MOIS never suggests them for this name again.</span>
        <select multiple className="form-input" style={{ minHeight: 90 }} aria-label="Products it is not"
          value={nots} onChange={e => setNots([...e.target.selectedOptions].map(o => o.value))}>
          {refs.products.filter(p => p.status === 'active' && p.id !== productId && p.categoryId === product?.categoryId)
            .map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
      </>}
      <div className="flex gap-8">
        <button type="button" className="btn btn-primary btn-sm" disabled={busy || (choice === 'split' && !hasStock)} onClick={submit}>Confirm</button>
        <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={onBack}>Back</button>
      </div>
    </div>
  );
}

function CorrectMatch({ decisionId, flag, refs, busy, run, onBack }) {
  const [decision, setDecision] = useState(null);
  const [target, setTarget] = useState('');
  const [move, setMove] = useState({});     // `${wh}|${col}` → qty
  useEffect(() => {
    supabase.from('identity_decisions').select('id, term, subject_type, product_id, category_id, decision').eq('id', decisionId).single()
      .then(({ data }) => setDecision(data));
  }, [decisionId]);
  const stock = useStock(decision?.product_id);
  const unit = r => refs.unitSymbol[r.stock_unit_id] ?? '';
  const key = r => `${r.warehouse_id}|${r.color_id ?? ''}`;

  if (!decision || stock === null) return <p className="text-xs text-muted">Loading…</p>;
  const isCategory = decision.subject_type === 'category';
  const current = isCategory ? refs.categoryName[decision.category_id] : refs.products.find(p => p.id === decision.product_id)?.name;

  const submit = () => run(async () => {
    if (!target) return isCategory ? 'Choose the right category.' : 'Choose the right product.';
    const why = `Corrected by ${refs.me.name} from the Review queue: "${decision.term}" is not ${current}.`;
    const { error: e1 } = await supabase.rpc('correct_identity_decision', {
      p_id: decision.id, p_new: { decision: 'same_as', [isCategory ? 'category_id' : 'product_id']: target }, p_evidence: why,
    });
    if (e1) return e1;
    if (!isCategory) {
      const lines = stock.filter(r => Number(move[key(r)] ?? 0) > 0)
        .map(r => ({ warehouse_id: r.warehouse_id, from_product_id: decision.product_id, to_product_id: target, color_id: r.color_id, quantity: Number(move[key(r)]) }));
      if (lines.length) {
        const { error: e2 } = await supabase.rpc('reclassify_stock', { p: { reason: why, lines,
          date: refs.firstStockDate[decision.product_id] } });
        if (e2) return `The name was corrected, but the stock couldn't be moved: ${dbErrorMessage(e2)}`;
      }
    }
    const { error: e3 } = await supabase.from('review_flags').update({
      status: 'resolved', resolved_at: new Date().toISOString(), resolved_by: refs.me.id, resolution_note: why,
    }).eq('id', flag.id);
    return e3;
  });

  return (
    <div className="flex flex-col gap-8">
      <span className="text-sm">"{decision.term}" was recorded as {current}. What is it really?</span>
      {isCategory ? (
        <select className="form-input" aria-label="Category" value={target} onChange={e => setTarget(e.target.value)}>
          <option value="">Choose the category…</option>
          {refs.categories.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      ) : (
        <ProductPick refs={refs} value={target} onChange={setTarget} excludeId={decision.product_id}
          sameCategoryAs={refs.products.find(p => p.id === decision.product_id)?.categoryId} />
      )}
      {!isCategory && stock.length > 0 && <>
        <span className="text-xs text-muted">
          How much of {current}'s stock came in under "{decision.term}" and should move? (Leave 0 to move nothing.)
        </span>
        {stock.map(r => (
          <div key={key(r)} className="flex items-center gap-8 text-xs">
            <span style={{ minWidth: 200 }}>{where(refs, r)} — has {qtyText(r.quantity)} {unit(r)}</span>
            <input type="number" step="any" min="0" className="form-input" style={{ width: 90 }} aria-label="Quantity to move"
              value={move[key(r)] ?? ''} placeholder="0" onChange={e => setMove(m => ({ ...m, [key(r)]: e.target.value }))} />
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setMove(m => ({ ...m, [key(r)]: String(r.quantity) }))}>all</button>
          </div>
        ))}
      </>}
      <div className="flex gap-8">
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={submit}>Confirm</button>
        <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={onBack}>Back</button>
      </div>
    </div>
  );
}
