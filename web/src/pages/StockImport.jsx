import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Upload, AlertTriangle, CheckCircle2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dbErrorMessage } from '../lib/masterData';
import { warehouseLabel, qtyText, orgToday } from '../lib/inventory';
import { parseStockSheet, matchSheet, lineProblems, normalize } from '../lib/stockImport';
import PageShell from '../components/PageShell';
import ErrorState from '../components/ErrorState';

const LOAD_ERROR = "We couldn't load the catalogue. Please try again.";

/*
 * Import a stock sheet as opening balances (build-plan 1b). Nothing is
 * written until "Post": the sheet is parsed and matched in the browser, the
 * admin resolves every line, previews the batch, and it posts through
 * post_inventory_batch() — every movement via post_inventory_movement(),
 * all or nothing. Every name resolved by hand is recorded as a standing
 * identity decision (identity_decisions, migration 026), so it is never
 * asked again; recorded decisions match exactly next time.
 */
export default function StockImport() {
  const { organization, session, canAt, canManage } = useAuth();
  const navigate = useNavigate();
  const today = orgToday(organization?.timezone);
  const [catalog, setCatalog] = useState(null);
  const [warehouses, setWarehouses] = useState([]);
  const [loadError, setLoadError] = useState('');

  const [fileName, setFileName] = useState('');
  const [parsed,   setParsed]   = useState(null);
  const [matched,  setMatched]  = useState(null);
  const [warehouseId, setWarehouseId] = useState('');
  const [date,     setDate]     = useState(today);
  const [tableChoice, setTableChoice] = useState({});   // table index → { categoryId, unitId }
  const [choices,  setChoices]  = useState({});         // line id → { productId, colorId, unitId, qty, date, skip, converted }
  const [step,     setStep]     = useState('upload');   // upload | resolve | preview | done
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState(null);
  const [fileText, setFileText] = useState('');
  const [draftId,  setDraftId]  = useState(null);
  const [drafts,   setDrafts]   = useState([]);
  const [saveState, setSaveState] = useState('');      // '' | saving | saved | failed

  async function loadCatalog() {
    setLoadError('');
    const [cats, pcc, prods, colors, units, decisions, wh] = await Promise.all([
      supabase.from('product_categories').select('id, name, status, sort_order, default_unit_id').order('sort_order'),
      supabase.from('product_category_colors').select('category_id, color_id, display_order'),
      supabase.from('products').select('id, canonical_name, category_id, unit_id, pcs_per_sqm, status').order('canonical_name'),
      supabase.from('color_palette').select('id, name, display_order, is_active').order('display_order'),
      supabase.from('units').select('id, symbol, name, status'),
      supabase.from('identity_decisions')
        .select('id, subject_type, context_normalized, term_normalized, decision, product_id, color_id, category_id, decided_by_label')
        .eq('status', 'active'),
      supabase.from('warehouses').select('id, name, status, branch_id, branch:branches(id, name, status)').order('name'),
    ]);
    const err = [cats, pcc, prods, colors, units, decisions, wh].find(r => r.error)?.error;
    if (err) { console.error(err); setLoadError(LOAD_ERROR); return null; }
    const c = {
      categories: cats.data.map(x => ({ id: x.id, name: x.name, status: x.status, defaultUnitId: x.default_unit_id,
        colorIds: pcc.data.filter(p => p.category_id === x.id).sort((a, b) => a.display_order - b.display_order).map(p => p.color_id) })),
      products: prods.data.map(p => ({ id: p.id, name: p.canonical_name, categoryId: p.category_id, unitId: p.unit_id, pcsPerSqm: p.pcs_per_sqm, status: p.status })),
      colors: colors.data.map(x => ({ id: x.id, name: x.name, isActive: x.is_active, display_order: x.display_order })),
      units: units.data.map(u => ({ id: u.id, symbol: u.symbol, name: u.name })),
      decisions: decisions.data,
    };
    setCatalog(c);
    setWarehouses(wh.data.filter(w => w.status === 'active' && canAt('inventory.adjust', w.branch_id, w.id)));
    return c;
  }

  async function loadDrafts() {
    const { data } = await supabase.from('stock_import_drafts')
      .select('id, file_name, warehouse_id, as_of_date, updated_at, created_by, line_choices')
      .eq('status', 'draft').order('updated_at', { ascending: false });
    setDrafts(data || []);
  }

  useEffect(() => { loadCatalog(); loadDrafts(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Every change is saved to the draft (migration 025), so work survives the
  // tab closing and can be reviewed before anything posts
  useEffect(() => {
    if (!draftId || step === 'done') return;
    setSaveState('saving');
    const t = setTimeout(async () => {
      const { error: err } = await supabase.from('stock_import_drafts').update({
        table_choices: tableChoice, line_choices: choices, warehouse_id: warehouseId || null,
        as_of_date: date || null, file_name: fileName || null, updated_by: session?.user?.id ?? null,
      }).eq('id', draftId);
      setSaveState(err ? 'failed' : 'saved');
      if (err) console.error(err);
    }, 800);
    return () => clearTimeout(t);
  }, [draftId, choices, tableChoice, warehouseId, date]); // eslint-disable-line react-hooks/exhaustive-deps

  const prodById = useMemo(() => Object.fromEntries((catalog?.products || []).map(p => [p.id, p])), [catalog]);
  const catById  = useMemo(() => Object.fromEntries((catalog?.categories || []).map(c => [c.id, c])), [catalog]);
  const colById  = useMemo(() => Object.fromEntries((catalog?.colors || []).map(c => [c.id, c])), [catalog]);
  const unitById = useMemo(() => Object.fromEntries((catalog?.units || []).map(u => [u.id, u])), [catalog]);

  function analyse(text, cat = catalog, saved = null) {
    const p = parseStockSheet(text);
    const first = matchSheet(p, cat);
    const tables = Object.fromEntries(first.tables.map(t => [t.index, saved?.tables?.[t.index] ?? {
      categoryId: t.cat.id ?? '',
      unitId: cat.units.find(u => normalize(u.symbol) === normalize(t.defaultUnit) || normalize(u.name) === normalize(t.defaultUnit))?.id ?? '',
    }]));
    // Categories chosen by hand (in a resumed draft) steer the product matching
    const extra = first.tables
      .filter(t => t.category && tables[t.index]?.categoryId && tables[t.index].categoryId !== t.cat.id)
      .map(t => ({ id: null, subject_type: 'category', context_normalized: '', term_normalized: normalize(t.category), decision: 'same_as', category_id: tables[t.index].categoryId, decided_by_label: 'this import' }));
    const m = extra.length ? { tables: first.tables, lines: matchSheet(p, { ...cat, decisions: [...cat.decisions, ...extra] }).lines } : first;
    setParsed(p);
    setMatched(m);
    setTableChoice(tables);
    setChoices(Object.fromEntries(m.lines.map(l => [l.id, saved?.lines?.[l.id] ?? {
      productId: l.product.id ?? '', colorId: l.colour?.id ?? '', unitId: l.unitId ?? '', qty: l.qty, date: '',
      skip: l.product.status === 'not_tracked',   // a decision says this isn't stocked
    }])));
    setStep('resolve');
  }

  async function resume(d) {
    setError('');
    const { data, error: err } = await supabase.from('stock_import_drafts').select('*').eq('id', d.id).single();
    if (err) { setError(dbErrorMessage(err, "We couldn't open that draft.")); return; }
    setDraftId(data.id);
    setFileName(data.file_name || '');
    setFileText(data.file_text);
    setWarehouseId(data.warehouse_id || '');
    setDate(data.as_of_date || today);
    analyse(data.file_text, catalog, { tables: data.table_choices, lines: data.line_choices });
    setSaveState('saved');
  }

  async function discard() {
    if (draftId) await supabase.from('stock_import_drafts').update({ status: 'discarded', updated_by: session?.user?.id ?? null }).eq('id', draftId);
    setDraftId(null); setParsed(null); setMatched(null); setFileName(''); setFileText(''); setStep('upload'); setSaveState('');
    loadDrafts();
  }

  function onFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    setFileName(f.name);
    const r = new FileReader();
    r.onload = async () => {
      const text = String(r.result);
      setFileText(text);
      analyse(text);
      const { data, error: err } = await supabase.from('stock_import_drafts').insert({
        organization_id: organization.id, file_name: f.name, file_text: text,
        warehouse_id: warehouseId || null, as_of_date: date || null, created_by: session.user.id,
      }).select('id').single();
      if (err) { console.error(err); setSaveState('failed'); return; }
      setDraftId(data.id);
      loadDrafts();
    };
    r.readAsText(f);
  }

  // A category chosen for a table re-runs that table's matching against it;
  // products already chosen stay chosen
  function chooseTableCategory(t, categoryId) {
    const next = { ...tableChoice, [t.index]: { ...tableChoice[t.index], categoryId } };
    setTableChoice(next);
    if (!t.category || !categoryId) return;
    const extra = Object.entries(next)
      .map(([i, v]) => ({ t: matched.tables[i], v }))
      .filter(({ t: tt, v }) => tt.category && v.categoryId && v.categoryId !== tt.cat.id)
      .map(({ t: tt, v }) => ({ id: null, subject_type: 'category', context_normalized: '', term_normalized: normalize(tt.category), decision: 'same_as', category_id: v.categoryId, decided_by_label: 'this import' }));
    const m = matchSheet(parsed, { ...catalog, decisions: [...catalog.decisions, ...extra] });
    setMatched({ tables: matched.tables, lines: m.lines });   // keep each table's original match labels
    setChoices(cs => Object.fromEntries(m.lines.map(l => [l.id, cs[l.id]?.productId ? cs[l.id] : { ...cs[l.id], productId: l.product.id ?? '' }])));
  }

  const setChoice = (id, patch) => setChoices(cs => ({ ...cs, [id]: { ...cs[id], ...patch } }));

  // Pieces counted for a product stocked by area convert at the product's
  // pieces per m² (decided 2026-10-14) — shown on the line, undoable
  const conversionFor = (c, unitId) => {
    const prod = prodById[c.productId];
    if (!prod || !unitId || unitId === prod.unitId || !(Number(prod.pcsPerSqm) > 0) || c.noConvert) return null;
    if (normalize(unitById[unitId]?.symbol) !== 'pcs') return null;
    return { qty: Math.round((Number(c.qty) / Number(prod.pcsPerSqm)) * 10000) / 10000, unitId: prod.unitId, pcsPerSqm: Number(prod.pcsPerSqm) };
  };

  // A table's own unit stands in for lines whose heading had none
  const effective = l => {
    const c = choices[l.id] || {};
    const unitId = c.unitId || (!l.unitExplicit ? tableChoice[l.table]?.unitId : '') || '';
    const conv = conversionFor(c, unitId);
    return conv ? { ...c, qty: conv.qty, unitId: conv.unitId, converted: conv } : { ...c, unitId };
  };
  // Standing import rule: a line nobody has matched to a product isn't
  // guessed and doesn't block — it becomes a placeholder product named as on
  // the sheet, flagged for review with the likely products as the choices.
  const placeholderFor = l => {
    const c = choices[l.id] || {};
    if (c.productId || c.skip || !matched) return null;
    const t = matched.tables[l.table];
    const sug = l.product.suggestions.slice(0, 3);
    const sugCats = [...new Set(sug.map(x => prodById[x.id]?.categoryId))];
    const categoryId = tableChoice[l.table]?.categoryId || t.cat.id || (sugCats.length === 1 ? sugCats[0] : '') || '';
    return { key: `${categoryId}|${normalize(l.typeText)}`, name: l.typeText, categoryId, context: t.category,
             candidates: sug.filter(x => prodById[x.id]?.categoryId === categoryId).map(x => x.id) };
  };
  const problemsOf = l => {
    if (!catalog) return [];
    const ph = placeholderFor(l);
    if (!ph) return lineProblems({ ...l, unitId: effective(l).unitId }, effective(l), catalog);
    const e = effective(l);
    const cat = catById[ph.categoryId];
    const out = [];
    if (!cat) out.push('Choose this table\'s category above, so the new product can be filed');
    if (!e.unitId) out.push(l.unitText ? `Unknown unit "${l.unitText}"` : 'No unit — the table heading has none');
    if (cat?.colorIds.length && !(e.colorId || l.colour?.id)) out.push(l.colourText ? `Colour "${l.colourText}" isn't set up` : 'Choose the colour');
    return out;
  };

  const lines = matched?.lines || [];
  const ready = lines.filter(l => !choices[l.id]?.skip && problemsOf(l).length === 0);
  const open  = lines.filter(l => !choices[l.id]?.skip && problemsOf(l).length > 0);
  const skipped = lines.filter(l => choices[l.id]?.skip);

  // Sheet lines that resolve to the same product + colour on the same date
  // (e.g. a row restating a product under another name) are added together
  // into ONE opening balance — shown on each line and in the preview
  const combined = useMemo(() => {
    const groups = {};
    for (const l of ready) {
      const c = effective(l);
      const ph = placeholderFor(l);
      const colorId = c.colorId || (ph ? l.colour?.id ?? '' : '');
      const k = `${c.date || date}|${ph ? 'ph:' + ph.key : c.productId}|${colorId}`;
      (groups[k] ??= { key: k, date: c.date || date, productId: c.productId, placeholder: ph, colorId, unitId: c.unitId, qty: 0, lines: [] });
      groups[k].qty = Math.round((groups[k].qty + Number(c.qty)) * 10000) / 10000;
      groups[k].lines.push(l);
    }
    return Object.values(groups);
  }, [ready, choices, date]); // eslint-disable-line react-hooks/exhaustive-deps
  const dupes = useMemo(() => new Set(combined.filter(g => g.lines.length > 1).flatMap(g => g.lines.map(l => l.id))), [combined]);

  async function createColour(l) {
    const prod = prodById[choices[l.id].productId];
    const cat = prod && catById[prod.categoryId];
    if (!cat) return;
    setError('');
    const name = l.colourText.charAt(0).toUpperCase() + l.colourText.slice(1).toLowerCase();
    setBusy(true);
    let colour = catalog.colors.find(c => normalize(c.name) === normalize(name));
    if (!colour) {
      const { data, error: err } = await supabase.from('color_palette')
        .insert({ organization_id: organization.id, name, display_order: catalog.colors.length + 1 }).select('id').single();
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
      colour = { id: data.id };
    }
    const { error: err2 } = await supabase.from('product_category_colors')
      .insert({ organization_id: organization.id, category_id: cat.id, color_id: colour.id, display_order: cat.colorIds.length + 1 });
    setBusy(false);
    if (err2 && err2.code !== '23505') { setError(dbErrorMessage(err2)); return; }
    const c = await loadCatalog();
    if (c) setChoices(cs => Object.fromEntries(Object.entries(cs).map(([id, ch]) => {
      const line = lines.find(x => x.id === id);
      return [id, line?.colourText && normalize(line.colourText) === normalize(name) && !ch.colorId ? { ...ch, colorId: colour.id } : ch];
    })));
  }

  async function post() {
    setError('');
    if (!warehouseId) { setError('Choose the store.'); return; }
    const byDate = {};
    const placeholders = {};
    for (const g of combined) {
      if (g.placeholder) {
        placeholders[g.placeholder.key] ??= { key: g.placeholder.key, name: g.placeholder.name, category_id: g.placeholder.categoryId,
          unit_id: g.unitId, context: g.placeholder.context, candidate_product_ids: g.placeholder.candidates,
          why: `It appeared on ${fileName || 'a stock sheet'} without a clear match.` };
      }
      (byDate[g.date] ??= []).push({ ...(g.placeholder ? { placeholder_key: g.placeholder.key } : { product_id: g.productId }),
        ...(g.colorId ? { color_id: g.colorId } : {}), quantity: g.qty, unit_id: g.unitId });
    }
    const merges = combined.filter(g => g.lines.length > 1)
      .map(g => `${g.placeholder?.name ?? prodById[g.productId]?.name}${g.colorId ? ' ' + colById[g.colorId]?.name : ''} = ${g.lines.map(l => `${l.typeText} ${l.qty}`).join(' + ')}`);
    const conversions = ready.map(l => ({ l, e: effective(l) })).filter(x => x.e.converted)
      .map(({ l, e }) => `${l.typeText}${l.colourText ? ' ' + l.colourText : ''}: ${l.qty}${l.unitText} at ${e.converted.pcsPerSqm}/m² → ${e.qty} ${unitById[e.unitId]?.symbol}`);
    const movements = Object.entries(byDate).sort().map(([d, ls]) => ({
      type: 'opening_balance', warehouse_id: warehouseId, movement_date: d, reference: fileName || null,
      notes: [conversions.length ? `Converted from pieces: ${conversions.join('; ')}` : '', merges.length ? `Sheet lines added together: ${merges.join('; ')}` : '']
        .filter(Boolean).join(' | ') || null,
      lines: ls,
    }));

    // Every name resolved by hand becomes a standing decision (never asked again)
    const decisions = [];
    const seen = new Set();
    const why = (l, c) => c.evidence || `Chosen while importing ${fileName || 'a stock sheet'} (sheet line ${l.lineNo})`;
    for (const l of ready) {
      const t = matched.tables[l.table];
      const c = effective(l);
      if (l.product.status !== 'exact' || l.product.id !== c.productId) {
        const k = `p|${normalize(t.category)}|${normalize(l.typeText)}`;
        if (!seen.has(k)) {
          seen.add(k);
          decisions.push({ subject_type: 'product', context: t.category, term: l.typeText, decision: 'same_as', product_id: c.productId, evidence: why(l, c) });
        }
      }
      if (l.colourText && c.colorId && (l.colour?.status !== 'exact' || l.colour.id !== c.colorId)) {
        const k = `c|${normalize(l.colourText)}`;
        if (!seen.has(k)) {
          seen.add(k);
          decisions.push({ subject_type: 'color', context: '', term: l.colourText, decision: 'same_as', color_id: c.colorId, evidence: why(l, c) });
        }
      }
    }
    for (const t of matched.tables) {
      const chosen = tableChoice[t.index]?.categoryId;
      if (t.category && chosen && t.cat.id !== chosen) {
        decisions.push({ subject_type: 'category', context: '', term: t.category, decision: 'same_as', category_id: chosen,
          evidence: `Chosen while importing ${fileName || 'a stock sheet'} (table heading, line ${t.firstLine})` });
      }
    }

    setBusy(true);
    const { data, error: err } = await supabase.rpc('post_inventory_batch', { p: { placeholders: Object.values(placeholders), movements, decisions } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't post the import. Nothing was recorded.")); return; }
    if (draftId) {
      await supabase.from('stock_import_drafts').update({
        status: 'posted', posted_movement_ids: data, table_choices: tableChoice, line_choices: choices, updated_by: session?.user?.id ?? null,
      }).eq('id', draftId);
    }
    setResult({ movements: data.length, lines: ready.length, decisions: decisions.length });
    setStep('done');
  }

  if (loadError) return <PageShell title="Import stock sheet" subtitle="Inventory"><div className="card"><ErrorState message={loadError} onRetry={loadCatalog} /></div></PageShell>;

  const canCreate = canManage('products.manage');
  const productOptions = l => {
    const t = matched.tables[l.table];
    const catId = tableChoice[l.table]?.categoryId || t.cat.id;
    const sug = l.product.suggestions.map(s => s.id);
    const inCat = catalog.products.filter(p => p.status === 'active' && p.categoryId === catId && !sug.includes(p.id));
    const rest = catalog.products.filter(p => p.status === 'active' && p.categoryId !== catId && !sug.includes(p.id));
    return { sug: l.product.suggestions, inCat, rest };
  };

  return (
    <PageShell title="Import stock sheet" subtitle="Inventory">
      {step === 'done' ? (
        <div className="card"><div className="card-body flex flex-col gap-12">
          <p className="flex items-center gap-8"><CheckCircle2 size={18} className="text-success" /> Posted {result.lines} opening-balance lines in {result.movements} movement{result.movements === 1 ? '' : 's'}.</p>
          {result.decisions > 0 && <p className="text-sm text-muted">{result.decisions} name{result.decisions === 1 ? '' : 's'} recorded as decisions — see Review queue → Decisions.</p>}
          <div className="flex gap-8">
            <button type="button" className="btn btn-primary" onClick={() => navigate('/movements')}>See movements</button>
            <button type="button" className="btn btn-outline" onClick={() => navigate('/stock')}>See stock</button>
          </div>
        </div></div>
      ) : (
        <div className="flex flex-col gap-16">
          <div className="card"><div className="card-body flex flex-col gap-12">
            <p className="text-sm text-muted">
              One file, one table per category: a heading like <code>== FLOOR TILES (unit: SQM) ==</code>, then <code>Type</code> and either one column per
              colour or a single <code>Qty</code>. A bare number is in the table's unit; <code>4pcs</code> overrides it for that cell. Nothing is recorded until you post.
            </p>
            <div className="form-row">
              <div className="form-group">
                <label className="form-label" htmlFor="imp-wh">Store</label>
                <select id="imp-wh" className="form-input" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
                  <option value="">Choose…</option>
                  {warehouses.map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
                </select>
                {!warehouses.length && catalog && <span className="form-hint">You need stock-adjustment permission at a store to import opening balances.</span>}
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="imp-date">Stock as of</label>
                <input id="imp-date" type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value)} />
                <span className="form-hint">Applies to every line unless you change a line's own date below.</span>
              </div>
            </div>
            {!matched && drafts.length > 0 && (
              <div className="flex flex-col gap-4">
                <span className="text-sm" style={{ fontWeight: 600 }}>Continue a saved import</span>
                {drafts.map(d => (
                  <div key={d.id} className="flex items-center gap-8 text-sm" style={{ flexWrap: 'wrap' }}>
                    <span>{d.file_name || 'Untitled sheet'}</span>
                    <span className="text-muted">
                      {Object.keys(d.line_choices || {}).length} lines · saved {new Date(d.updated_at).toLocaleString('en-GB', { timeZone: organization?.timezone || undefined })}
                    </span>
                    <button type="button" className="btn btn-outline btn-sm" disabled={!catalog} onClick={() => resume(d)}>Continue</button>
                  </div>
                ))}
              </div>
            )}
            {matched && (
              <div className="flex items-center gap-8 text-xs text-muted">
                {saveState === 'saving' ? 'Saving draft…' : saveState === 'saved' ? 'Draft saved — you can close this page and continue later.' : saveState === 'failed' ? <span className="text-error">Draft not saved — check your connection.</span> : null}
                {draftId && <button type="button" className="btn btn-ghost btn-sm" onClick={discard}>Discard draft</button>}
              </div>
            )}
            <label className="btn btn-outline" style={{ alignSelf: 'flex-start' }}>
              <Upload size={14} /> {fileName ? `Replace ${fileName}` : 'Choose file (.csv)'}
              <input type="file" accept=".csv,.txt,text/csv,text/plain" hidden onChange={onFile} disabled={!catalog} />
            </label>
          </div></div>

          {matched && (
            <>
              {parsed.issues.length > 0 && (
                <div className="alert alert-error" role="alert">
                  {parsed.issues.map((i, n) => <div key={n}>Line {i.lineNo}: {i.message}</div>)}
                </div>
              )}

              <div className="flex gap-8 text-sm" style={{ flexWrap: 'wrap' }}>
                <span className="badge badge-success">{ready.length} ready</span>
                <span className={`badge ${open.length ? 'badge-warning' : 'badge-neutral'}`}>{open.length} need a decision</span>
                <span className="badge badge-neutral">{skipped.length} skipped</span>
                {dupes.size > 0 && <span className="badge badge-neutral">{dupes.size} lines added together</span>}
              </div>

              {matched.tables.map(t => {
                const tl = lines.filter(l => l.table === t.index);
                const tc = tableChoice[t.index] || {};
                return (
                  <div key={t.index} className="card">
                    <div className="card-header" style={{ flexWrap: 'wrap', gap: 8 }}>
                      <h2 className="card-title">{t.category || <span className="text-error">Table with no category name (line {t.firstLine})</span>}</h2>
                      <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
                        <select className="form-input" style={{ width: 'auto' }} aria-label="Category" value={tc.categoryId}
                          onChange={e => chooseTableCategory(t, e.target.value)}>
                          <option value="">{t.cat.status === 'none' ? 'Category: no match — choose' : 'Category…'}</option>
                          {catalog.categories.filter(c => c.status === 'active').map(c => (
                            <option key={c.id} value={c.id}>{c.name}{t.cat.suggestions.some(s => s.id === c.id) ? ' (suggested)' : ''}</option>
                          ))}
                        </select>
                        <select className="form-input" style={{ width: 'auto' }} aria-label="Table unit" value={tc.unitId}
                          onChange={e => setTableChoice(x => ({ ...x, [t.index]: { ...tc, unitId: e.target.value } }))}>
                          <option value="">{t.defaultUnit ? `Unit "${t.defaultUnit}" not found` : 'Unit: none stated — choose'}</option>
                          {catalog.units.map(u => <option key={u.id} value={u.id}>{u.symbol}</option>)}
                        </select>
                      </div>
                    </div>
                    <div className="table-container">
                      <table>
                        <thead><tr><th>On the sheet</th><th>Product</th><th>Colour</th><th style={{ textAlign: 'right' }}>Quantity</th><th>Date</th><th>Status</th></tr></thead>
                        <tbody>
                          {tl.map(l => {
                            const c = choices[l.id] || {};
                            const e = effective(l);
                            const prod = prodById[c.productId];
                            const pcat = prod && catById[prod.categoryId];
                            const problems = c.skip ? [] : problemsOf(l);
                            const opts = productOptions(l);
                            const undone = c.noConvert && conversionFor({ ...c, noConvert: false }, c.unitId || '');
                            return (
                              <tr key={l.id} className={c.skip ? 'row-muted' : ''}>
                                <td className="text-sm">
                                  <div style={{ fontWeight: 500 }}>{l.typeText}</div>
                                  <div className="text-xs text-muted">{l.colourText ? `${l.colourText} · ` : ''}{l.raw}{!l.unitExplicit && l.unitText ? ` ${l.unitText}` : ''} · line {l.lineNo}</div>
                                </td>
                                <td>
                                  <select className="form-input" aria-label="Product" value={c.productId} disabled={c.skip}
                                    onChange={ev => setChoice(l.id, { productId: ev.target.value, colorId: l.colour?.id ?? '' })}>
                                    <option value="">{l.product.status === 'none' ? 'No match — choose…' : 'Choose…'}</option>
                                    {opts.sug.length > 0 && <optgroup label="Suggested">
                                      {opts.sug.map(s => <option key={s.id} value={s.id}>{prodById[s.id]?.name}{s.otherCategory ? ` — ${catById[prodById[s.id]?.categoryId]?.name}` : ''}{s.strong ? ' (good match)' : ''}</option>)}
                                    </optgroup>}
                                    <optgroup label="This category">{opts.inCat.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>
                                    <optgroup label="Other categories">{opts.rest.map(p => <option key={p.id} value={p.id}>{p.name} — {catById[p.categoryId]?.name}</option>)}</optgroup>
                                  </select>
                                  {l.product.status === 'exact' && c.productId === l.product.id && (
                                    <div className="text-xs text-muted">{l.product.via === 'same name' ? 'same name as on the sheet' : l.product.via.replace(/^decided: /, 'decided earlier by ')}</div>
                                  )}
                                </td>
                                <td>
                                  {pcat?.colorIds.length ? (
                                    <>
                                      <select className="form-input" aria-label="Colour" value={c.colorId} disabled={c.skip} onChange={ev => setChoice(l.id, { colorId: ev.target.value })}>
                                        <option value="">{l.colourText ? `"${l.colourText}" — choose…` : 'Choose…'}</option>
                                        {pcat.colorIds.map(id => <option key={id} value={id}>{colById[id]?.name}{colById[id]?.isActive === false ? ' (discontinued)' : ''}</option>)}
                                      </select>
                                      {l.colourText && !c.colorId && canCreate && !catalog.colors.some(x => normalize(x.name) === normalize(l.colourText) && pcat.colorIds.includes(x.id)) && (
                                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => createColour(l)}>
                                          Add {l.colourText.toLowerCase()} to {pcat.name}
                                        </button>
                                      )}
                                    </>
                                  ) : <span className="text-muted">—</span>}
                                </td>
                                <td style={{ textAlign: 'right' }}>
                                  {qtyText(e.qty)} {unitById[e.unitId]?.symbol ?? l.unitText ?? ''}
                                  {e.converted && (
                                    <div className="text-xs text-muted">
                                      from {l.qty}{l.unitText} at {e.converted.pcsPerSqm} pcs/m²
                                      {!c.skip && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setChoice(l.id, { noConvert: true })}>don't convert</button>}
                                    </div>
                                  )}
                                  {undone && !c.skip && (
                                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => setChoice(l.id, { noConvert: false })}>
                                      Convert at {undone.pcsPerSqm} pcs/m²
                                    </button>
                                  )}
                                </td>
                                <td>
                                  <input type="date" className="form-input" style={{ width: 150 }} max={today} aria-label="Line date"
                                    value={c.date || date} disabled={c.skip} onChange={ev => setChoice(l.id, { date: ev.target.value === date ? '' : ev.target.value })} />
                                </td>
                                <td className="text-xs">
                                  {c.skip ? <span className="text-muted">skipped</span>
                                    : problems.length ? <span className="text-error flex items-center gap-4"><AlertTriangle size={12} /> {problems.join('; ')}</span>
                                    : placeholderFor(l) ? <span className="text-warning">
                                        New product "{l.typeText}" will be added to {catById[placeholderFor(l).categoryId]?.name} and flagged in the Review queue
                                        {placeholderFor(l).candidates.length ? ` — it may be ${placeholderFor(l).candidates.map(id => prodById[id]?.name).join(' or ')}` : ''}
                                      </span>
                                    : dupes.has(l.id) ? <span className="text-success">ready · added to the other {prodById[e.productId]?.name}{e.colorId ? ' ' + colById[e.colorId]?.name : ''} line</span>
                                    : <span className="text-success">ready</span>}
                                  <label className="flex items-center gap-4 mt-8">
                                    <input type="checkbox" checked={!!c.skip} onChange={ev => setChoice(l.id, { skip: ev.target.checked })} /> skip
                                  </label>
                                </td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                  </div>
                );
              })}

              {step === 'preview' ? (
                <div className="card">
                  <div className="card-header"><h2 className="card-title">Preview — {combined.length} opening balances from {ready.length} sheet lines</h2></div>
                  <div className="table-container">
                    <table>
                      <thead><tr><th>Product</th><th>Colour</th><th>Date</th><th>From the sheet</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Running total</th></tr></thead>
                      <tbody>
                        {(() => {
                          const run = {};
                          return [...combined].sort((a, b) => (a.placeholder?.name ?? prodById[a.productId]?.name ?? '').localeCompare(b.placeholder?.name ?? prodById[b.productId]?.name ?? '')
                              || (colById[a.colorId]?.display_order ?? 0) - (colById[b.colorId]?.display_order ?? 0))
                            .map(g => {
                              const u = unitById[g.unitId]?.symbol;
                              run[u] = Math.round(((run[u] || 0) + g.qty) * 10000) / 10000;
                              return (
                                <tr key={g.key}>
                                  <td>{g.placeholder ? <>{g.placeholder.name} <span className="badge badge-warning">new · to review</span></> : prodById[g.productId]?.name}</td>
                                  <td className="text-muted">{colById[g.colorId]?.name ?? '—'}</td>
                                  <td className="text-muted">{g.date}</td>
                                  <td className="text-xs text-muted">
                                    {g.lines.map(l => `${l.typeText} ${l.raw}${effective(l).converted ? ' (converted)' : ''}`).join(' + ')}
                                  </td>
                                  <td style={{ textAlign: 'right' }}>{qtyText(g.qty)} {u}</td>
                                  <td style={{ textAlign: 'right' }} className="text-muted">{qtyText(run[u])} {u}</td>
                                </tr>
                              );
                            });
                        })()}
                      </tbody>
                    </table>
                  </div>
                  <div className="card-body flex flex-col gap-8">
                    {error && <div className="alert alert-error" role="alert">{error}</div>}
                    <p className="text-sm text-muted">
                      Posts {combined.length} opening balances at {warehouseLabel(warehouses.find(w => w.id === warehouseId))}
                      {skipped.length ? `; ${skipped.length} skipped lines are not recorded` : ''}. All or nothing — and an item that already has stock here is refused.
                    </p>
                    <div className="flex gap-8">
                      <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={post}>Post {combined.length} opening balances</button>
                      <button type="button" className="btn btn-ghost" onClick={() => setStep('resolve')}>Back</button>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="flex flex-col gap-8">
                  {error && <div className="alert alert-error" role="alert">{error}</div>}
                  <button type="button" className="btn btn-primary" style={{ alignSelf: 'flex-start' }}
                    disabled={!ready.length || open.length > 0 || !warehouseId}
                    onClick={() => setStep('preview')}>
                    {open.length ? `Resolve or skip ${open.length} line${open.length === 1 ? '' : 's'} first` : !warehouseId ? 'Choose the store first' : `Preview ${ready.length} lines`}
                  </button>
                  <p className="text-xs text-muted">Need a product that doesn't exist yet? Add it under <Link to="/products">Products</Link>, then choose the file again.</p>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </PageShell>
  );
}
