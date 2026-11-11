import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Upload, AlertTriangle, CheckCircle2, X } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage } from '../lib/masterData';
import { warehouseLabel, qtyText, orgToday, productColorIds, stockKey } from '../lib/inventory';
import { parseStockSheet, matchSheet, lineProblems, normalize } from '../lib/stockImport';
import { categoryTools } from '../lib/categories';
import PageShell from '../components/PageShell';
import Modal from '../components/Modal';
import ErrorState from '../components/ErrorState';
import { dateText, dateTimeText, tableDate } from '../lib/format';

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
  const { inBranch } = useBranch();
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
  // what the sheet records (2026-11-11, the user): 'count' — a stock take (MOIS records the differences),
  // or 'opening' — a store's first stock. '' until chosen: a store that already has stock means a count.
  const [kind, setKind] = useState('');
  // confirmations inside MOIS (2026-11-11): the browser's own confirm box is answered "no" in the app's browser
  const [askDraft, setAskDraft] = useState(null);       // draft id asking "discard?"
  const [askCancel, setAskCancel] = useState(false);
  async function discardDraft(id) {
    const { error: err } = await supabase.from('stock_import_drafts').update({ status: 'discarded', updated_by: session?.user?.id ?? null }).eq('id', id);
    if (err) { setError(dbErrorMessage(err, "We couldn't discard that draft.")); return; }
    setAskDraft(null);
    loadDrafts();
  }
  const [expected, setExpected] = useState(null);     // date → { stock key → quantity } in this store, for a count
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
    const [cats, pcc, prods, colors, units, decisions, wh, bp, own] = await Promise.all([
      supabase.from('product_categories').select('id, name, status, sort_order, default_unit_id, parent_category_id').order('sort_order'),
      supabase.from('product_category_colors').select('category_id, color_id, display_order'),
      supabase.from('products').select('*').order('canonical_name'),
      supabase.from('color_palette').select('id, name, display_order, is_active').order('display_order'),
      supabase.from('units').select('id, symbol, name, status'),
      supabase.from('identity_decisions')
        .select('id, subject_type, context_normalized, term_normalized, decision, product_id, color_id, category_id, decided_by_label')
        .eq('status', 'active'),
      supabase.from('warehouses').select('id, name, status, branch_id, branch:branches(id, name, status)').order('name'),
      supabase.from('branch_products').select('branch_id, product_id').eq('status', 'active'),
      supabase.from('product_colors').select('product_id, color_id, display_order'),   // 046; none before it
    ]);
    const err = [cats, pcc, prods, colors, units, decisions, wh, bp].find(r => r.error)?.error;
    if (err) { console.error(err); setLoadError(LOAD_ERROR); return null; }
    const c = {
      // parentId: the group a category sits under (038); the matcher reads a group as all its categories
      categoryRows: cats.data,
      categories: cats.data.map(x => ({ id: x.id, name: x.name, status: x.status, defaultUnitId: x.default_unit_id, parentId: x.parent_category_id,
        colorIds: pcc.data.filter(p => p.category_id === x.id).sort((a, b) => a.display_order - b.display_order).map(p => p.color_id) })),
      // colorIds: the product's colours — its own when an admin set them, else its category's (046)
      products: prods.data.map(p => ({ id: p.id, name: p.canonical_name, categoryId: p.category_id, unitId: p.unit_id, pcsPerSqm: p.pcs_per_sqm, status: p.status,
        ownColors: !!p.own_colors, colorIds: productColorIds(p, pcc.data, own.error ? [] : own.data || []) })),
      colors: colors.data.map(x => ({ id: x.id, name: x.name, isActive: x.is_active, display_order: x.display_order })),
      units: units.data.map(u => ({ id: u.id, symbol: u.symbol, name: u.name })),
      decisions: decisions.data,
      // each branch's own catalogue (031), for matching against the chosen store's branch
      carriedByBranch: bp.data.reduce((m, r) => { (m[r.branch_id] ||= new Set()).add(r.product_id); return m; }, {}),
      branchOfWarehouse: Object.fromEntries(wh.data.map(w => [w.id, w.branch_id])),
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
        table_choices: { ...tableChoice, _kind: kind }, line_choices: choices, warehouse_id: warehouseId || null,
        as_of_date: date || null, file_name: fileName || null, updated_by: session?.user?.id ?? null,
      }).eq('id', draftId);
      setSaveState(err ? 'failed' : 'saved');
      if (err) console.error(err);
    }, 800);
    return () => clearTimeout(t);
  }, [draftId, choices, tableChoice, warehouseId, date, kind]); // eslint-disable-line react-hooks/exhaustive-deps

  // a store that already has stock: the sheet is a count, unless the person says otherwise
  useEffect(() => {
    if (kind || !warehouseId) return;
    let live = true;
    supabase.from('stock_balances').select('quantity').eq('warehouse_id', warehouseId).neq('quantity', 0).limit(1)
      .then(({ data }) => { if (live) setKind(data?.length ? 'count' : 'opening'); });
    return () => { live = false; };
  }, [warehouseId, kind]);

  const prodById = useMemo(() => Object.fromEntries((catalog?.products || []).map(p => [p.id, p])), [catalog]);
  const catById  = useMemo(() => Object.fromEntries((catalog?.categories || []).map(c => [c.id, c])), [catalog]);
  const catTools = useMemo(() => categoryTools(catalog?.categoryRows || []), [catalog]);
  const colById  = useMemo(() => Object.fromEntries((catalog?.colors || []).map(c => [c.id, c])), [catalog]);
  const unitById = useMemo(() => Object.fromEntries((catalog?.units || []).map(u => [u.id, u])), [catalog]);

  // The catalogue as the chosen store's branch sees it
  const forStore = (cat, whId = warehouseId) => ({
    ...cat, carriedIds: whId ? cat.carriedByBranch[cat.branchOfWarehouse[whId]] ?? new Set() : null,
  });

  function analyse(text, cat = catalog, saved = null, whId = warehouseId) {
    const p = parseStockSheet(text);
    if (!saved && p.dateHint && p.dateHint <= today) setDate(p.dateHint);   // the date in the sheet's title
    cat = forStore(cat, whId);
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
    setKind(data.table_choices?._kind || '');
    analyse(data.file_text, catalog, { tables: data.table_choices, lines: data.line_choices }, data.warehouse_id || '');
    setSaveState('saved');
  }

  async function discard() {
    if (draftId) await supabase.from('stock_import_drafts').update({ status: 'discarded', updated_by: session?.user?.id ?? null }).eq('id', draftId);
    setDraftId(null); setParsed(null); setMatched(null); setFileName(''); setFileText(''); setStep('upload'); setSaveState(''); setKind('');
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
    const m = matchSheet(parsed, { ...forStore(catalog), decisions: [...catalog.decisions, ...extra] });
    setMatched({ tables: matched.tables, lines: m.lines });   // keep each table's original match labels
    setChoices(cs => Object.fromEntries(m.lines.map(l => [l.id, cs[l.id]?.productId ? cs[l.id] : { ...cs[l.id], productId: l.product.id ?? '' }])));
  }

  // Choosing (or changing) the store re-ranks matches for its branch;
  // products already chosen stay chosen
  useEffect(() => {
    if (!parsed || !matched || !catalog) return;
    const extra = Object.entries(tableChoice)
      .map(([i, v]) => ({ t: matched.tables[i], v }))
      .filter(({ t: tt, v }) => tt?.category && v.categoryId && v.categoryId !== tt.cat.id)
      .map(({ t: tt, v }) => ({ id: null, subject_type: 'category', context_normalized: '', term_normalized: normalize(tt.category), decision: 'same_as', category_id: v.categoryId, decided_by_label: 'this import' }));
    const m = matchSheet(parsed, { ...forStore(catalog), decisions: [...catalog.decisions, ...extra] });
    setMatched(prev => ({ tables: prev.tables, lines: m.lines }));
    setChoices(cs => Object.fromEntries(m.lines.map(l => [l.id, cs[l.id]?.productId ? cs[l.id] : { ...cs[l.id], productId: l.product.id ?? '' }])));
  }, [warehouseId]); // eslint-disable-line react-hooks/exhaustive-deps

  const setChoice = (id, patch) => setChoices(cs => ({ ...cs, [id]: { ...cs[id], ...patch } }));

  // Pieces counted for a product stocked by area convert at the product's
  // pieces per m² (decided 2026-10-14) — shown on the line, undoable
  const conversionFor = (c, unitId) => {
    const prod = prodById[c.productId];
    if (!prod || !unitId || unitId === prod.unitId || !(Number(prod.pcsPerSqm) > 0) || c.noConvert) return null;
    if (normalize(unitById[unitId]?.symbol) !== 'pcs') return null;
    return { qty: Math.round((Number(c.qty) / Number(prod.pcsPerSqm)) * 10000) / 10000, unitId: prod.unitId, pcsPerSqm: Number(prod.pcsPerSqm) };
  };

  // the product's own colours when an admin set them, else its category's (046) — as lineProblems
  const prodColours = id => { const p = prodById[id]; return p ? (p.colorIds ?? catById[p.categoryId]?.colorIds ?? []) : []; };
  // A table's own unit stands in for lines whose heading had none
  const effective = l => {
    let c = choices[l.id] || {};
    // a product with no colours: the sheet's colour column means nothing for it (2026-11-11)
    if (c.colorId && prodColours(c.productId).length === 0 && prodById[c.productId]) c = { ...c, colorId: '' };
    // a bare number on the branch's stock-taking sheet is in the product's own unit (2026-11-11)
    const unitId = c.unitId || (!l.unitExplicit ? tableChoice[l.table]?.unitId : '') || (l.unitFromProduct ? prodById[c.productId]?.unitId : '') || '';
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
    const tableCat = tableChoice[l.table]?.categoryId || t.cat.id || '';
    // Under a group heading the new product goes in one of the group's
    // categories: chosen on the line, or the one all its likely matches share
    const groupKids = catTools.isGroup(tableCat) ? catTools.childrenOf(tableCat).map(x => x.id) : null;
    const categoryId = groupKids
      ? (c.categoryId && groupKids.includes(c.categoryId) ? c.categoryId : sugCats.length === 1 && groupKids.includes(sugCats[0]) ? sugCats[0] : '')
      : tableCat || (sugCats.length === 1 ? sugCats[0] : '') || '';
    return { key: `${categoryId}|${normalize(l.typeText)}`, name: l.typeText, categoryId, context: t.category, group: groupKids ? tableCat : null,
             candidates: sug.filter(x => prodById[x.id]?.categoryId === categoryId).map(x => x.id) };
  };
  // the sheet's rows: every cell of one sheet row together (the review grid)
  const sheetRows = tl => {
    const out = [];
    for (const l of tl) {
      const last = out[out.length - 1];
      if (last && last.lineNo === l.lineNo) last.lines.push(l);
      else out.push({ key: `${l.table}:${l.lineNo}`, lineNo: l.lineNo, typeText: l.typeText, lines: [l] });
    }
    return out;
  };
  const problemsOf = l => {
    if (!catalog) return [];
    const ph = placeholderFor(l);
    if (!ph) return lineProblems({ ...l, unitId: effective(l).unitId }, effective(l), catalog);
    const e = effective(l);
    const cat = catById[ph.categoryId];
    const out = [];
    if (!cat) out.push(ph.group ? `Choose which ${catTools.label(ph.group)} category the new product goes in` : 'Choose this table\'s category above, so the new product can be filed');
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

  const countDates = [...new Set([date, ...combined.map(g => g.date)].filter(Boolean))].sort().join(',');   // stable: the effect runs once per set of dates
  useEffect(() => {
    // on the sheet itself (2026-11-11, the user): what MOIS holds shows under each counted quantity
    if (!matched || kind !== 'count' || !warehouseId || !countDates) return;
    let live = true;
    const dates = countDates.split(',');
    Promise.all(dates.map(d => (d < today
      ? supabase.rpc('stock_balances_as_of', { p_date: d })
      : supabase.from('stock_balances').select('warehouse_id, material_id, product_id, color_id, quantity'))
      .then(({ data }) => [d, Object.fromEntries((data || []).filter(b => b.warehouse_id === warehouseId).map(b => [stockKey(b), Number(b.quantity)]))])))
      .then(rows => { if (live) setExpected(Object.fromEntries(rows)); });
    return () => { live = false; };
  }, [!!matched, kind, warehouseId, countDates, today]); // eslint-disable-line react-hooks/exhaustive-deps
  const expectedOf = g => (g.placeholder ? 0 : expected?.[g.date]?.[stockKey({ product_id: g.productId, color_id: g.colorId || null })] ?? 0);

  async function post() {
    setError('');
    if (!warehouseId) { setError('Choose the store.'); return; }
    if (!kind) { setError('Say whether the sheet is a stock count or opening stock.'); return; }
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
      type: kind === 'count' ? 'count' : 'opening_balance', warehouse_id: warehouseId, movement_date: d, reference: fileName || null,
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
    // Opening balances are corrections: non-admins send the import for an
    // admin's approval, which posts it exactly as prepared (migration 033)
    if (!canManage('inventory.adjust')) {
      const { error: err } = await supabase.rpc('request_change', {
        p_kind: 'stock_import', p_branch_id: null,
        p_payload: { batch: { placeholders: Object.values(placeholders), movements, decisions }, draft_id: draftId || null },
        p_summary: `${kind === 'count' ? 'Stock count' : 'Opening stock'} import${fileName ? ` "${fileName}"` : ''}: ${ready.length} lines at ${warehouseLabel(warehouses.find(w => w.id === warehouseId))}, dated ${dateText(date)}`,
      });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err, "We couldn't send the import for approval. Nothing was recorded.")); return; }
      setResult({ submitted: true, lines: ready.length, movements: 0, decisions: 0 });
      setStep('done');
      return;
    }
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
          {result.submitted ? (
            <p className="flex items-center gap-8"><CheckCircle2 size={18} className="text-success" /> Sent {result.lines} opening-balance lines for an admin's approval. Stock is recorded once approved — follow it under Approvals.</p>
          ) : (
            <p className="flex items-center gap-8"><CheckCircle2 size={18} className="text-success" /> Posted {result.lines} opening-balance lines in {result.movements} movement{result.movements === 1 ? '' : 's'}.</p>
          )}
          {result.decisions > 0 && <p className="text-sm text-muted">{result.decisions} name{result.decisions === 1 ? '' : 's'} saved as decisions.</p>}
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
                  {warehouses.filter(w => inBranch(w.branch_id) || w.id === warehouseId).map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
                </select>
                {!warehouses.length && catalog && <span className="form-hint">You can't adjust stock at any store.</span>}
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="imp-date">Stock as of</label>
                <input id="imp-date" type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value)} />
                <span className="form-hint">For every line unless changed below.</span>
              </div>
            </div>
            {warehouseId && (
              <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }} role="radiogroup" aria-label="What the sheet records">
                <span className="text-sm" style={{ fontWeight: 600 }}>This sheet is</span>
                <button type="button" role="radio" aria-checked={kind === 'count'} className={`filter-chip${kind === 'count' ? ' is-on' : ''}`} onClick={() => setKind('count')}
                  title="What was counted in the store on that date. MOIS compares it with what it expected and records the differences.">A stock count</button>
                <button type="button" role="radio" aria-checked={kind === 'opening'} className={`filter-chip${kind === 'opening' ? ' is-on' : ''}`} onClick={() => setKind('opening')}
                  title="The store's very first stock in MOIS. Refused for items that already have stock here.">Opening stock</button>
              </div>
            )}
            {!matched && drafts.some(d => !d.warehouse_id || inBranch(catalog?.branchOfWarehouse?.[d.warehouse_id])) && (
              <div className="flex flex-col gap-4">
                <span className="text-sm" style={{ fontWeight: 600 }}>Continue a saved import</span>
                {drafts.filter(d => !d.warehouse_id || inBranch(catalog?.branchOfWarehouse?.[d.warehouse_id])).map(d => (
                  <div key={d.id} className="flex items-center gap-8 text-sm" style={{ flexWrap: 'wrap' }}>
                    <span>{d.file_name || 'Untitled sheet'}</span>
                    <span className="text-muted">
                      {Object.keys(d.line_choices || {}).length} lines · saved {dateTimeText(d.updated_at, organization?.timezone)}
                    </span>
                    {askDraft === d.id ? (
                      <span className="flex items-center gap-8" role="group" aria-label="Discard this draft?">
                        <span className="text-error">Discard? Nothing was recorded from it.</span>
                        <button type="button" className="btn btn-danger btn-sm" onClick={() => discardDraft(d.id)}>Yes, discard</button>
                        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setAskDraft(null)}>Keep</button>
                      </span>
                    ) : <>
                      <button type="button" className="btn btn-outline btn-sm" disabled={!catalog} onClick={() => resume(d)}>Continue</button>
                      {/* throw a saved import away (2026-11-11, the user) */}
                      <button type="button" className="icon-btn" aria-label={`Discard the draft saved ${dateTimeText(d.updated_at, organization?.timezone)}`} title="Discard this draft"
                        onClick={() => setAskDraft(d.id)}><X size={15} /></button>
                    </>}
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
                          {catTools.ordered.filter(c => c.status === 'active').map(c => (
                            <option key={c.id} value={c.id}>{catTools.isGroup(c.id) ? `${c.name} (any of its categories)` : catTools.label(c)}{t.cat.suggestions.some(s => s.id === c.id) ? ' (suggested)' : ''}</option>
                          ))}
                        </select>
                        <select className="form-input" style={{ width: 'auto' }} aria-label="Table unit" value={tc.unitId}
                          onChange={e => setTableChoice(x => ({ ...x, [t.index]: { ...tc, unitId: e.target.value } }))}>
                          <option value="">{t.defaultUnit ? `Unit "${t.defaultUnit}" not found` : 'Unit: none stated — choose'}</option>
                          {catalog.units.map(u => <option key={u.id} value={u.id}>{u.symbol}</option>)}
                        </select>
                      </div>
                    </div>
                    {/* the sheet's own grid (2026-11-11, the user): one row per type, colours as columns, to follow and confirm */}
                    <div className="table-container">
                      <table className="si-grid">
                        <thead><tr><th>Product</th><th>On the sheet</th>
                          {(t.columns.length ? t.columns : ['Qty']).map((cn, k) => <th key={k} style={{ textAlign: 'right' }}>{t.isColoured ? cn : 'Qty'}</th>)}
                          <th>Date</th><th>Status</th></tr></thead>
                        <tbody>
                          {sheetRows(tl).map(r => {
                            const first = r.lines[0];
                            const cs = r.lines.map(l => choices[l.id] || {});
                            const allSkip = cs.every(c => c.skip);
                            const ids = [...new Set(cs.map(c => c.productId || ''))];
                            const productId = ids.length === 1 ? ids[0] : '';
                            const prod = prodById[productId];
                            const opts = productOptions(first);
                            const rowProblems = allSkip ? [] : r.lines.filter(l => !choices[l.id]?.skip).flatMap(l => problemsOf(l).map(p => ({ l, p })));
                            const ph = placeholderFor(first);
                            const rowDates = [...new Set(cs.map(c => c.date || ''))];
                            const setRow = patch => r.lines.forEach(l => setChoice(l.id, typeof patch === 'function' ? patch(l) : patch));
                            return (
                              <tr key={r.key} className={allSkip ? 'row-muted' : ''}>
                                <td>
                                  <select className="form-input" aria-label="Product" value={productId} disabled={allSkip}
                                    onChange={ev => setRow(l => ({ productId: ev.target.value, colorId: l.colour?.id ?? '' }))}>
                                    <option value="">{ids.length > 1 ? 'Different products — choose one…' : first.product.status === 'none' ? 'No match — choose…' : 'Choose…'}</option>
                                    {opts.sug.length > 0 && <optgroup label="Suggested">
                                      {opts.sug.map(x => <option key={x.id} value={x.id}>{prodById[x.id]?.name}{x.otherCategory ? ` — ${catById[prodById[x.id]?.categoryId]?.name}` : ''}{x.strong ? ' (good match)' : ''}{x.notCarried ? " (not in this branch's list yet)" : ''}</option>)}
                                    </optgroup>}
                                    <optgroup label="This category">{opts.inCat.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>
                                    <optgroup label="Other categories">{opts.rest.map(p => <option key={p.id} value={p.id}>{p.name} — {catById[p.categoryId]?.name}</option>)}</optgroup>
                                  </select>
                                  {first.product.status === 'exact' && productId === first.product.id && (
                                    <div className="text-xs text-muted" title={first.product.via === 'same name' ? 'The same name as on the sheet' : first.product.via.replace(/^decided: /, 'Decided earlier by ')}>
                                      {first.product.via === 'same name' ? 'same name' : 'decided before'}</div>
                                  )}
                                </td>
                                <td className="text-sm">
                                  <div style={{ fontWeight: 500 }}>{r.typeText}</div>
                                  <div className="text-xs text-muted">line {r.lineNo}</div>
                                </td>
                                {(t.columns.length ? t.columns : ['Qty']).map((cn, k) => {
                                  const l = r.lines.find(x => x.col === k);
                                  if (!l) return <td key={k} />;
                                  const c = choices[l.id] || {};
                                  const e = effective(l);
                                  const probs = c.skip ? [] : problemsOf(l);
                                  const pcols = prodColours(productId);
                                  const colourProblem = probs.some(p => /colour/i.test(p));
                                  const undone = c.noConvert && conversionFor({ ...c, noConvert: false }, c.unitId || '');
                                  const otherColour = t.isColoured && l.colourText && normalize(l.colourText) !== normalize(cn);
                                  return (
                                    <td key={k} className={`si-cell${probs.length ? ' si-bad' : ''}`} title={probs.length ? probs.join('; ') : `${l.raw} · line ${l.lineNo}`}>
                                      <div className="si-qty">{qtyText(e.qty)} <span className="pl-help">{unitById[e.unitId]?.symbol ?? l.unitText ?? ''}</span></div>
                                      {/* a stock count: what MOIS holds, and the difference (2026-11-11, the user) */}
                                      {kind === 'count' && expected && e.productId && !c.skip && (() => {
                                        const g = combined.find(x => x.lines.includes(l));
                                        const ex = g ? expectedOf(g) : (expected[c.date || date]?.[stockKey({ product_id: e.productId, color_id: e.colorId || null })] ?? 0);
                                        const counted = g ? g.qty : Number(e.qty);
                                        const d = Math.round((counted - ex) * 10000) / 10000;
                                        return (
                                          <div className="si-mois" title={`MOIS held ${qtyText(ex)} on ${c.date || date}; counted ${qtyText(counted)}${g && g.lines.length > 1 ? ' (sheet lines added together)' : ''}`}>
                                            MOIS {qtyText(ex)} · <span className={d < 0 ? 'text-error' : d > 0 ? 'text-success' : 'text-muted'}>{d === 0 ? 'same' : `${d > 0 ? '+' : ''}${qtyText(d)}`}</span>
                                          </div>
                                        );
                                      })()}
                                      {otherColour && <div className="text-xs">{l.colourText.charAt(0) + l.colourText.slice(1).toLowerCase()}</div>}
                                      {e.converted && <div className="text-xs text-muted">from {l.qty} {l.unitText}
                                        {!c.skip && <button type="button" className="btn-link-sm" onClick={() => setChoice(l.id, { noConvert: true })}>keep</button>}</div>}
                                      {undone && !c.skip && <button type="button" className="btn-link-sm" onClick={() => setChoice(l.id, { noConvert: false })}>to {unitById[prod?.unitId]?.symbol ?? 'its unit'}</button>}
                                      {colourProblem && pcols.length > 0 && (
                                        <select className="form-input si-colour" aria-label={`Colour for ${r.typeText} ${cn}`} value={c.colorId || ''} onChange={ev => setChoice(l.id, { colorId: ev.target.value })}>
                                          <option value="">{l.colourText ? `"${l.colourText}"?` : 'Colour?'}</option>
                                          {pcols.map(id => <option key={id} value={id}>{colById[id]?.name}{colById[id]?.isActive === false ? ' (discontinued)' : ''}</option>)}
                                        </select>
                                      )}
                                      {colourProblem && l.colourText && !c.colorId && canCreate && prod && !prod.ownColors && !catalog.colors.some(x => normalize(x.name) === normalize(l.colourText) && pcols.includes(x.id)) && (
                                        <button type="button" className="btn-link-sm" disabled={busy} onClick={() => createColour(l)}>add {l.colourText.toLowerCase()}</button>
                                      )}
                                      {probs.length > 0 && !colourProblem && <div className="text-xs text-error"><AlertTriangle size={11} /> {probs[0]}</div>}
                                    </td>
                                  );
                                })}
                                <td>
                                  <input type="date" className="form-input" style={{ width: 150 }} max={today} aria-label="Row date"
                                    value={(rowDates.length === 1 && rowDates[0]) || date} disabled={allSkip}
                                    onChange={ev => setRow({ date: ev.target.value === date ? '' : ev.target.value })} />
                                </td>
                                <td className="text-xs">
                                  {allSkip ? <span className="text-muted">skipped</span>
                                    : rowProblems.length ? <>
                                        <span className="text-error flex items-center gap-4"><AlertTriangle size={12} /> {rowProblems.length === 1 ? rowProblems[0].p : `${rowProblems.length} cells to fix`}</span>
                                        {ph?.group && (
                                          <select className="form-input mt-4" style={{ width: 'auto' }} aria-label="Category for the new product"
                                            value={cs[0].categoryId || ''} onChange={ev => setRow({ categoryId: ev.target.value })}>
                                            <option value="">Category…</option>
                                            {catTools.childrenOf(ph.group).map(x => <option key={x.id} value={x.id}>{catTools.label(x)}</option>)}
                                          </select>
                                        )}
                                      </>
                                    : ph ? <span className="text-warning" title={ph.candidates.length ? `It may be ${ph.candidates.map(id => prodById[id]?.name).join(' or ')}` : undefined}>
                                        New product, added to {catTools.label(ph.categoryId)} and flagged for review
                                      </span>
                                    : <span className="text-success">ready{r.lines.some(l => dupes.has(l.id)) ? ' · added to another line' : ''}</span>}
                                  <label className="flex items-center gap-4 mt-8">
                                    <input type="checkbox" checked={allSkip} onChange={ev => setRow({ skip: ev.target.checked })} /> skip
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
                  <div className="card-header"><h2 className="card-title">Preview — {kind === 'count' ? `${combined.length} items counted` : `${combined.length} opening balances`} from {ready.length} sheet lines</h2></div>
                  <div className="table-container">
                    <table>
                      <thead><tr><th>Product</th><th>Colour</th><th>Date</th><th>From the sheet</th>{kind === 'count'
                        ? <><th style={{ textAlign: 'right' }}>Counted</th><th style={{ textAlign: 'right' }} title="What MOIS held on that date, from everything recorded">MOIS expected</th><th style={{ textAlign: 'right' }}>Difference</th></>
                        : <><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Running total</th></>}</tr></thead>
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
                                  <td className="text-muted">{tableDate(g.date)}</td>
                                  <td className="text-xs text-muted">
                                    {g.lines.map(l => `${l.typeText} ${l.raw}${effective(l).converted ? ' (converted)' : ''}`).join(' + ')}
                                  </td>
                                  <td style={{ textAlign: 'right' }}>{qtyText(g.qty)} {u}</td>
                                  {kind === 'count' ? (() => {
                                    if (!expected) return <><td style={{ textAlign: 'right' }} className="text-muted">…</td><td /></>;
                                    const ex = expectedOf(g); const d = Math.round((g.qty - ex) * 10000) / 10000;
                                    return <><td style={{ textAlign: 'right' }} className="text-muted">{qtyText(ex)} {u}</td>
                                      <td style={{ textAlign: 'right', fontWeight: 600 }} className={d < 0 ? 'text-error' : d > 0 ? 'text-success' : 'text-muted'}>{d === 0 ? '—' : `${d > 0 ? '+' : ''}${qtyText(d)} ${u}`}</td></>;
                                  })() : <td style={{ textAlign: 'right' }} className="text-muted">{qtyText(run[u])} {u}</td>}
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
                      {kind === 'count'
                        ? <>Records the count at {warehouseLabel(warehouses.find(w => w.id === warehouseId))}: each item's stock on its date becomes what was counted, and the difference is recorded. Items not on the sheet keep their stock; anything recorded after that date stays on top.{expected ? ` ${combined.filter(g => Math.abs(g.qty - expectedOf(g)) > 1e-9).length} of ${combined.length} items differ.` : ''}</>
                        : <>Posts {combined.length} opening balances at {warehouseLabel(warehouses.find(w => w.id === warehouseId))}. An item that already has stock here is refused.</>}
                      {skipped.length ? ` ${skipped.length} skipped lines are not recorded.` : ''} All or nothing.
                    </p>
                    <div className="si-actions">
                      <span />
                      <button type="button" className="btn btn-ghost" onClick={() => setAskCancel(true)}>Cancel import</button>
                      <button type="button" className="btn btn-outline" onClick={() => setStep('resolve')}>Back to the sheet</button>
                      <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !kind} onClick={post}>{!canManage('inventory.adjust') ? `Submit ${combined.length} for approval` : kind === 'count' ? `Post the count (${combined.length} items)` : `Post ${combined.length} opening balances`}</button>
                    </div>
                  </div>
                </div>
              ) : (
                <>
                  {error && <div className="alert alert-error" role="alert">{error}</div>}
                  <p className="text-xs text-muted">Need a product that doesn't exist yet? Add it under <Link to="/products">Products</Link>, then choose the file again.</p>
                  {/* the actions, always in reach (2026-11-11, the user) */}
                  <div className="si-actions">
                    <span className="text-xs text-muted">{saveState === 'saving' ? 'Saving…' : saveState === 'saved' ? 'Draft saved' : saveState === 'failed' ? <span className="text-error">Draft not saved</span> : ''}</span>
                    <button type="button" className="btn btn-ghost" onClick={() => setAskCancel(true)}>Cancel import</button>
                    <button type="button" className="btn btn-outline" title="The draft keeps every choice; continue it later from this page" onClick={() => navigate('/stock')}>Save and close</button>
                    <button type="button" className="btn btn-primary"
                      disabled={!ready.length || open.length > 0 || !warehouseId}
                      onClick={() => { setStep('preview'); window.scrollTo({ top: 0, behavior: 'smooth' }); }}>
                      {open.length ? `Fix or skip ${open.length} first` : !warehouseId ? 'Choose the store first' : `Preview ${ready.length} lines`}
                    </button>
                  </div>
                </>
              )}
            </>
          )}
        </div>
      )}
      {askCancel && (
        <Modal title="Cancel this import?" onClose={() => setAskCancel(false)}
          footer={<>
            <button type="button" className="btn btn-outline" onClick={() => setAskCancel(false)}>Keep working</button>
            <button type="button" className="btn btn-danger" onClick={() => { setAskCancel(false); discard(); }}>Yes, cancel it</button></>}>
          <p>The draft is thrown away. Nothing has been recorded from it.</p>
        </Modal>
      )}
    </PageShell>
  );
}
