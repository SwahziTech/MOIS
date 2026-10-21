/**
 * Stock-sheet import: parse a file of stacked tables and match its rows to
 * the catalogue. Pure functions — no database access — so the same code
 * runs in the browser and in the dry-run script.
 *
 * FORMAT (one file, one table per category):
 *
 *   == FLOOR TILES (unit: SQM unless cell says otherwise) ==
 *   Type,WHITE,RED,GREY,BLACK
 *   40 COMBO,197,188,54,
 *   SLAB,21pcs,86pcs,4pcs,2pcs
 *
 *   == CULVERTS (unit: PCS unless cell says otherwise) ==
 *   Type,Qty
 *   900N,42
 *
 * - A heading line names the category and its default unit.
 * - Coloured tables: Type, then one column per colour present.
 *   Plain tables: Type, Qty.
 * - A bare number is in the table's default unit; a number with a unit
 *   suffix ("4pcs") overrides it for that cell only.
 */

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function splitCsvLine(line) {
  const out = [];
  let cur = '', quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cur += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out.map(c => c.trim());
}

const HEADING = /^=+\s*(.*?)\s*=+$/;

/** "FLOOR TILES (unit: SQM unless cell says otherwise)" → { category, unit } */
export function parseHeading(text) {
  const unitMatch = text.match(/\(\s*unit\s*:\s*([^\s),]+)[^)]*\)/i);
  const category = text.replace(/\([^)]*\)/g, '').trim();
  return { category, unit: unitMatch ? unitMatch[1] : null };
}

/** "197" → {qty:197}; "4pcs" / "4 pcs" → {qty:4, unit:'pcs'}; '' → null; anything else → {error} */
export function parseCell(raw) {
  const s = String(raw ?? '').trim();
  if (!s) return null;
  const m = s.match(/^(\d+(?:[.,]\d+)?)\s*([A-Za-z²³]+[A-Za-z0-9²³]*)?$/);
  if (!m) return { error: `"${s}" isn't a number` };
  return { qty: Number(m[1].replace(',', '.')), unit: m[2] ?? null };
}

/**
 * Parse a stock sheet. Returns { tables, lines, issues }:
 *   tables: [{ index, heading, category, defaultUnit, columns, isColoured, firstLine }]
 *   lines:  one per non-empty cell — { id, table, typeText, colourText, qty,
 *           unitText, unitExplicit, lineNo, raw }
 *   issues: problems with the file itself (unreadable cells, rows outside a
 *           table, tables with no category name or unit)
 */
export function parseStockSheet(text) {
  const rows = String(text).replace(/^﻿/, '').split(/\r?\n/);
  const tables = [];
  const lines = [];
  const issues = [];
  let table = null;
  let expectHeader = false;

  rows.forEach((rawLine, i) => {
    const lineNo = i + 1;
    const cells = splitCsvLine(rawLine);
    const first = cells[0] ?? '';
    if (cells.every(c => c === '')) return;

    const h = first.match(HEADING) || (cells.slice(1).every(c => c === '') && rawLine.trim().match(HEADING));
    if (h) {
      const { category, unit } = parseHeading(h[1]);
      table = { index: tables.length, heading: h[1], category, defaultUnit: unit, columns: [], isColoured: false, firstLine: lineNo };
      tables.push(table);
      if (!category) issues.push({ lineNo, table: table.index, kind: 'no_category', message: 'This table\'s heading has no category name.' });
      if (!unit) issues.push({ lineNo, table: table.index, kind: 'no_unit', message: 'This table\'s heading doesn\'t state a unit.' });
      expectHeader = true;
      return;
    }
    if (!table) {
      issues.push({ lineNo, kind: 'outside_table', message: 'Row before any table heading — ignored.' });
      return;
    }
    if (expectHeader) {
      expectHeader = false;
      const cols = cells.slice(1);
      while (cols.length && cols[cols.length - 1] === '') cols.pop();
      table.columns = cols;
      table.isColoured = !(cols.length === 1 && /^(qty|quantity|idadi)$/i.test(cols[0]));
      return;
    }

    const typeText = first;
    if (!typeText) {
      issues.push({ lineNo, table: table.index, kind: 'no_type', message: 'Row without an item name.' });
      return;
    }
    table.columns.forEach((col, c) => {
      const raw = cells[c + 1] ?? '';
      const parsed = parseCell(raw);
      if (!parsed) return;
      if (parsed.error) {
        issues.push({ lineNo, table: table.index, kind: 'bad_cell', message: `${typeText} / ${col}: ${parsed.error}` });
        return;
      }
      lines.push({
        id: `${lineNo}:${c}`,
        table: table.index,
        typeText,
        colourText: table.isColoured ? col : null,
        qty: parsed.qty,
        unitText: parsed.unit ?? table.defaultUnit,
        unitExplicit: !!parsed.unit,
        lineNo,
        raw,
      });
    });
  });
  return { tables, lines, issues };
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

/** Same rule as the database's normalize_name(): case/space/punctuation-blind */
export const normalize = s => String(s ?? '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');

function ratio(a, b) {
  if (a === b) return 1;
  if (!a || !b) return 0;
  const prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return 1 - prev[b.length] / Math.max(a.length, b.length);
}

// Words that describe the measurement, not the item
const NOISE = new Set(['cm', 'mm', 'in', 'inch', 'x', 'the', 'and', 'of', 'unless', 'cell', 'says', 'otherwise', 'mpa']);

/** "TUNDU 6 CM 50" → ['tundu','6','50']; "40*80 COMBO" → ['40','80','combo'] */
export function tokens(s) {
  return String(s ?? '').toLowerCase()
    .replace(/(\d)(?=[a-z])/g, '$1 ').replace(/([a-z])(?=\d)/g, '$1 ')   // 6cm → 6 cm, w40 → w 40
    .split(/[^\p{L}\p{N}]+/u)
    .filter(t => t && !NOISE.has(t))
    // Swahili plural/singular noun class (mikubwa/mkubwa, midogo/mdogo)
    .map(t => (/^mi[^aeiou]/.test(t) ? `m${t.slice(2)}` : t));
}

/** Token-set similarity in [0,1]; numbers must match exactly */
export function nameScore(a, b) {
  const A = tokens(a), B = tokens(b);
  if (!A.length || !B.length) return 0;
  const word = (t, u) => {
    if (/^\d/.test(t) || /^\d/.test(u)) return t === u ? 1 : 0;
    const [short, long] = t.length <= u.length ? [t, u] : [u, t];
    if (short.length >= 2 && long.startsWith(short)) return Math.max(0.8, ratio(t, u));   // SQ ~ SQUARE
    const r = ratio(t, u);
    return r >= 0.7 ? r : 0;
  };
  const best = (t, set) => Math.max(0, ...set.map(u => word(t, u)));
  const sum = A.reduce((s, t) => s + best(t, B), 0) + B.reduce((s, t) => s + best(t, A), 0);
  return sum / (A.length + B.length);
}

/**
 * Every word on both sides has a counterpart (numbers equal). "80 CM PRESS"
 * vs "80 Press" is full; "40 MAYAI 2''" vs "40 Mayai" is not (the 2'' is
 * unexplained), nor "Z-PLAIN PRESS" vs "Z Plain".
 */
export function fullMatch(a, b) {
  const A = tokens(a), B = tokens(b);
  const has = (t, set) => set.some(u => (/^\d/.test(t) || /^\d/.test(u)) ? t === u
    : ((s, l) => (s.length >= 2 && l.startsWith(s)))(...(t.length <= u.length ? [t, u] : [u, t])) || ratio(t, u) >= 0.7);
  return A.length > 0 && B.length > 0 && A.every(t => has(t, B)) && B.every(t => has(t, A));
}

function rank(text, candidates, nameOf, limit = 4, threshold = 0.45) {
  return candidates
    .map(c => ({ item: c, score: nameScore(text, nameOf(c)) }))
    .filter(x => x.score >= threshold)
    .sort((x, y) => y.score - x.score)
    .slice(0, limit);
}

/**
 * Match parsed lines to the catalogue.
 * catalog: { categories:[{id,name,colorIds:[]}], products:[{id,name,categoryId,unitId,pcsPerSqm,status,colorIds?}],
 *            colors:[{id,name}], units:[{id,symbol,name}],
 *            decisions:[{id,subject_type,context_normalized,term_normalized,decision,product_id,color_id,category_id,decided_by_label}] }
 *   decisions = the active rows of identity_decisions (migration 026)
 *   carriedIds = optional Set of product ids in the store's branch catalogue (031): those win
 *     when a name fits several products and come first in suggestions; others stay matchable
 *     (posting opening stock adds them to the branch's list) and are marked notCarried
 * Each result: { status: 'exact'|'suggested'|'none'|'not_tracked', id, via, decision, suggestions:[{id,score}] }
 * - exact: a recorded decision, or the same name (ignoring case/spacing/punctuation)
 * - suggested: close matches for the admin to confirm (never ones a decision says it is NOT)
 * - none: nothing close — the admin picks, creates, or skips
 * - not_tracked: a decision says this term isn't stocked — skip it
 */
export function matchSheet(parsed, catalog) {
  const activeProducts = catalog.products.filter(p => p.status === 'active');
  const decisions = catalog.decisions || [];
  const carried = catalog.carriedIds || null;
  const isCarried = id => !carried || carried.has(id);
  // The standing answer for a term: one recorded for this context, else one for anywhere
  const answer = (type, context, text) => {
    const t = normalize(text), c = normalize(context);
    const mine = decisions.filter(d => d.subject_type === type && d.term_normalized === t && d.decision !== 'distinct_from');
    return mine.find(d => d.context_normalized === c) || mine.find(d => d.context_normalized === '') || null;
  };
  // Records a decision says the term is NOT
  const notThese = (type, context, text) => new Set(decisions
    .filter(d => d.subject_type === type && d.decision === 'distinct_from' && d.term_normalized === normalize(text)
      && (d.context_normalized === normalize(context) || d.context_normalized === ''))
    .map(d => d.product_id ?? d.color_id ?? d.category_id));
  const via = d => `decided: ${d.decided_by_label}`;
  // categories grouped under another (parentId, migration 038)
  const childrenOf = {};
  for (const c of catalog.categories) if (c.parentId) (childrenOf[c.parentId] ||= []).push(c.id);
  const expandGroups = ids => ids.flatMap(id => childrenOf[id] ?? [id]);

  // Categories per table
  const tables = parsed.tables.map(t => {
    const a = t.category && answer('category', '', t.category);
    if (a?.category_id) return { ...t, cat: { status: 'exact', id: a.category_id, via: via(a), decision: a.id, suggestions: [] } };
    const same = catalog.categories.filter(c => normalize(c.name) === normalize(t.category));
    if (t.category && same.length === 1) return { ...t, cat: { status: 'exact', id: same[0].id, via: 'same name', suggestions: [] } };
    const sug = t.category ? rank(t.category, catalog.categories, c => c.name, 3, 0.4) : [];
    return { ...t, cat: { status: sug.length ? 'suggested' : 'none', id: null, suggestions: sug.map(s => ({ id: s.item.id, score: s.score })) } };
  });

  const unitBy = text => catalog.units.find(u => normalize(u.symbol) === normalize(text) || normalize(u.name) === normalize(text));

  const lines = parsed.lines.map(l => {
    const t = tables[l.table];
    // Categories the heading points at (exact, or all suggested ones)
    // A group (038) stands for all of its subcategories
    const catIds = expandGroups(t.cat.status === 'exact' ? [t.cat.id] : t.cat.suggestions.map(s => s.id));

    // Product
    let product;
    const pa = answer('product', t.category, l.typeText);
    const excluded = notThese('product', t.category, l.typeText);
    let sameName = activeProducts.filter(p => normalize(p.name) === normalize(l.typeText) && !excluded.has(p.id)
      && (!catIds.length || catIds.includes(p.categoryId)));
    // Several products by that name: the one this branch carries
    if (sameName.length > 1 && carried) {
      const here = sameName.filter(p => carried.has(p.id));
      if (here.length) sameName = here;
    }
    if (pa?.decision === 'not_tracked') product = { status: 'not_tracked', id: null, via: via(pa), decision: pa.id, suggestions: [] };
    else if (pa?.product_id) product = { status: 'exact', id: pa.product_id, via: via(pa), decision: pa.id, notCarried: !isCarried(pa.product_id), suggestions: [] };
    else if (sameName.length === 1) product = { status: 'exact', id: sameName[0].id, via: 'same name', notCarried: !isCarried(sameName[0].id), suggestions: [] };
    else {
      const candidates = activeProducts.filter(p => !excluded.has(p.id));
      const inCats = candidates.filter(p => catIds.includes(p.categoryId));
      let sug = rank(l.typeText, inCats.length ? inCats : candidates, p => p.name);
      if (!sug.length && inCats.length) sug = rank(l.typeText, candidates, p => p.name, 3, 0.6);   // elsewhere in the catalogue
      sug = [...sug].sort((a, b) => isCarried(b.item.id) - isCarried(a.item.id));                // the branch's own first
      // strong: every word accounted for AND in the heading's category — still the admin's call
      product = { status: sug.length ? 'suggested' : 'none', id: null, suggestions: sug.map(s => ({
        id: s.item.id, score: Number(s.score.toFixed(2)),
        otherCategory: !catIds.includes(s.item.categoryId),
        strong: catIds.includes(s.item.categoryId) && fullMatch(l.typeText, s.item.name),
        notCarried: !isCarried(s.item.id),
      })) };
    }

    // Colour
    let colour = null;
    if (l.colourText) {
      const ca = answer('color', t.category, l.colourText);
      const same = catalog.colors.find(c => normalize(c.name) === normalize(l.colourText));
      if (ca?.color_id) colour = { status: 'exact', id: ca.color_id, via: via(ca), decision: ca.id, suggestions: [] };
      else if (same) colour = { status: 'exact', id: same.id, via: 'same name', suggestions: [] };
      else {
        const sug = rank(l.colourText, catalog.colors, c => c.name, 2, 0.6);
        colour = { status: sug.length ? 'suggested' : 'none', id: null, suggestions: sug.map(s => ({ id: s.item.id, score: s.score })) };
      }
    }

    // Unit
    const unit = l.unitText ? unitBy(l.unitText) : null;
    return { ...l, product, colour, unitId: unit?.id ?? null };
  });

  return { tables, lines };
}

/**
 * What still stops a line from posting, once product/colour/unit are
 * chosen. Returns a list of problems ([] = ready).
 */
export function lineProblems(line, choice, catalog) {
  const problems = [];
  if (choice.skip) return problems;
  const product = catalog.products.find(p => p.id === choice.productId);
  if (!product) problems.push('Choose the product');
  const unitId = choice.unitId ?? line.unitId;
  if (!unitId) problems.push(line.unitText ? `Unknown unit "${line.unitText}"` : 'No unit — the table heading has none');
  if (product) {
    const cat = catalog.categories.find(c => c.id === product.categoryId);
    // the product's own colours when an admin set them, else its category's (046)
    const colorIds = product.colorIds ?? cat?.colorIds ?? [];
    const coloured = colorIds.length > 0;
    if (coloured && !choice.colorId) problems.push(line.colourText ? `Colour "${line.colourText}" isn't set up` : 'Choose the colour');
    if (coloured && choice.colorId && !colorIds.includes(choice.colorId)) problems.push(`That colour isn't one of ${product.name}'s colours`);
    if (!coloured && choice.colorId) problems.push(`${product.name} has no colours`);
    if (unitId && unitId !== product.unitId) problems.push('Counted in a different unit from the one this product is stocked in');
  }
  if (!(line.qty > 0)) problems.push('Quantity must be above zero');
  return problems;
}
