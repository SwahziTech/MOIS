import { supabase } from './supabase';

/*
 * The two-way daily report (1f, 2026-10-29), in Swahili as the branches write
 * it by hand today:
 *
 *   RIPOTI YA <BRANCH> TAREHE dd/mm/yy
 *   UZALISHAJI WA <product> <colour>
 *   Pcs <pieces> Cem <bags> Wastani <all pieces ÷ bags, whole>
 *   <leftover product> Pcs <pieces> (MABAKI)
 *   TEAM WATU <people>
 *   CEMENT ILIYOPO STORE NI <bags> BAGS
 *   UMEME <meter>
 *   ASUBUHI - <reading>   JIONI - <reading>   ILIYOTUMIKA - <units>
 *
 * loadDayFacts reads what MOIS holds for a branch and day; writeReport turns
 * it into the text; readReport reads a written/pasted report back; compare
 * lines the two up.
 */

const num = v => Number(String(v).replace(/,/g, ''));
const fmt = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);

/** What MOIS holds for a branch and day → { products, cementStore, cementName, meters } */
export async function loadDayFacts({ branchId, date, today, refs }) {
  const [b, rd, pd, m, bal, ri] = await Promise.all([
    supabase.from('production_batches').select('id, cement_bags, worker_ids, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast)')
      .eq('branch_id', branchId).eq('batch_date', date).neq('status', 'void'),
    supabase.from('power_readings').select('meter_id, slot, reading, read_at').eq('branch_id', branchId).eq('read_on', date).eq('status', 'recorded'),
    supabase.from('power_daily').select('meter_id, day_units, token_missing').eq('branch_id', branchId).eq('day', date),
    supabase.from('power_meters').select('id, name, status').eq('branch_id', branchId).order('name'),
    date < today ? supabase.rpc('stock_balances_as_of', { p_date: date })
      : supabase.from('stock_balances').select('warehouse_id, material_id, product_id, quantity'),
    // cement = what recipes take one bag of per bag of cement (as the production form reads it)
    supabase.from('recipe_items').select('material_id, quantity, unit_id'),
  ]);
  const cementIds = new Set((ri.data || []).filter(x => refs.unitById[x.unit_id]?.symbol?.toLowerCase() === 'bag' && Number(x.quantity) === 1).map(x => x.material_id));
  if (b.error) throw b.error;
  const label = (pid, cid) => [refs.items[`p:${pid}`]?.name ?? '?', cid ? refs.colorById?.[cid]?.name : null].filter(Boolean).join(' ');

  // production: one entry per main product (and colour), leftovers under it
  const byKey = {};
  for (const batch of b.data || []) {
    const main = (batch.outputs || []).find(o => o.is_primary);
    if (!main) continue;
    const k = `${main.product_id}|${main.color_id ?? ''}`;
    const e = (byKey[k] ||= { key: k, name: label(main.product_id, main.color_id), pieces: 0, cement: 0, all: 0, workers: new Set(), leftovers: {} });
    e.pieces += main.pieces_cast; e.cement += Number(batch.cement_bags); e.all += main.pieces_cast;
    (batch.worker_ids || []).forEach(w => e.workers.add(w));
    for (const o of (batch.outputs || []).filter(x => !x.is_primary)) {
      const lk = `${o.product_id}|${o.color_id ?? ''}`;
      e.leftovers[lk] = { name: label(o.product_id, o.color_id), pieces: (e.leftovers[lk]?.pieces || 0) + o.pieces_cast };
      e.all += o.pieces_cast;
    }
  }
  const products = Object.values(byKey).map(e => ({
    name: e.name, pieces: e.pieces, cement: e.cement, wastani: e.cement > 0 ? Math.floor(e.all / e.cement) : null,
    leftovers: Object.values(e.leftovers), people: e.workers.size || null,
  }));

  // cement in the branch's stores at the end of the day, in bags
  const whs = new Set(refs.warehouses.filter(w => w.branch_id === branchId).map(w => w.id));
  let cementStore = null; const names = new Set();
  for (const r of (bal.data || []).filter(x => x.material_id && whs.has(x.warehouse_id))) {
    const it = refs.items[`m:${r.material_id}`];
    if (!it || !cementIds.has(r.material_id)) continue;
    const bag = it.units.find(u => refs.unitById[u.id]?.symbol?.toLowerCase() === 'bag');
    cementStore = (cementStore || 0) + Number(r.quantity) / (bag?.factor || 1);
    names.add(it.name);
  }

  // each meter: morning, evening, units used in the day
  const meters = (m.data || []).filter(x => x.status === 'active').map(x => {
    const r = (rd.data || []).filter(y => y.meter_id === x.id);
    const d = (pd.data || []).find(y => y.meter_id === x.id);
    const morning = r.find(y => y.slot === 'morning'); const evening = r.find(y => y.slot === 'evening');
    const used = d?.day_units != null ? Number(d.day_units) : morning && evening ? Number(morning.reading) - Number(evening.reading) : null;
    return { name: x.name, morning: morning ? Number(morning.reading) : null, evening: evening ? Number(evening.reading) : null, used, tokenMissing: !!d?.token_missing };
  });
  return { products, cementStore: cementStore == null ? null : Math.round(cementStore * 100) / 100, cementName: [...names].join(', '), meters };
}

/** The report text from MOIS's facts */
export function writeReport(facts, { branchName, date }) {
  const [y, mo, d] = date.split('-');
  const out = [`RIPOTI YA ${branchName.toUpperCase()} TAREHE ${d}/${mo}/${y.slice(2)}`, ''];
  if (!facts.products.length) out.push('HAKUNA UZALISHAJI', '');
  for (const p of facts.products) {
    out.push(`UZALISHAJI WA ${p.name.toUpperCase()}`);
    out.push(`Pcs ${fmt(p.pieces)} Cem ${fmt(p.cement)}${p.wastani != null ? ` Wastani ${p.wastani}` : ''}`);
    for (const l of p.leftovers) out.push(`${l.name.toUpperCase()} Pcs ${fmt(l.pieces)} (MABAKI)`);
    if (p.people) out.push(`TEAM WATU ${p.people}`);
    out.push('');
  }
  if (facts.cementStore != null) out.push(`CEMENT ILIYOPO STORE NI ${fmt(facts.cementStore)} BAGS`, '');
  for (const m of facts.meters) {
    out.push(`UMEME ${m.name.toUpperCase()}`);
    out.push(`ASUBUHI - ${m.morning != null ? fmt(m.morning) : '—'}`);
    out.push(`JIONI - ${m.evening != null ? fmt(m.evening) : '—'}`);
    out.push(`ILIYOTUMIKA - ${m.used != null ? fmt(m.used) : '—'}`);
    out.push('');
  }
  return out.join('\n').trim();
}

/** A written or pasted report read back → { products, cementStore, meters } (what could be read) */
export function readReport(text) {
  const res = { products: [], cementStore: null, meters: [] };
  let prod = null; let meter = null;
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const U = line.toUpperCase();
    const pcs = U.match(/PCS\s*[:.]?\s*([\d,]+)/);
    const cem = U.match(/CEM\w*\s*[:.]?\s*([\d.,]+)/);
    const head = U.match(/^UZALISHAJI\s+WA\s+(.+?)(?=\s+PCS\b|$)/);
    if (head) {
      prod = { name: head[1].trim(), pieces: null, cement: null, leftovers: [], people: null };
      res.products.push(prod); meter = null;
      if (pcs) prod.pieces = num(pcs[1]);
      if (cem) prod.cement = num(cem[1]);
      continue;
    }
    if (/^UMEME\b/.test(U)) { meter = { name: line.replace(/^umeme\s*/i, '').trim(), morning: null, evening: null, used: null }; res.meters.push(meter); prod = null; continue; }
    const store = U.match(/CEMENT.*STORE[^\d]*([\d.,]+)/);
    if (store) { res.cementStore = num(store[1]); prod = null; meter = null; continue; }
    if (meter) {
      const v = U.match(/([\d.,]+)\s*$/);
      if (/ASUBUHI/.test(U) && v) meter.morning = num(v[1]);
      else if (/JIONI/.test(U) && v) meter.evening = num(v[1]);
      else if (/ILIYOTUMIKA|IMETUMIKA/.test(U) && v) meter.used = num(v[1]);
      continue;
    }
    if (!prod) continue;
    const team = U.match(/TEAM\s+WATU\s*([\d]+)/) || U.match(/WATU\s*([\d]+)/);
    if (team) { prod.people = num(team[1]); continue; }
    if (/MABAKI/.test(U) && pcs) { prod.leftovers.push({ name: U.slice(0, U.search(/PCS/)).trim(), pieces: num(pcs[1]) }); continue; }
    if (pcs && prod.pieces == null) { prod.pieces = num(pcs[1]); if (cem) prod.cement = num(cem[1]); }
  }
  return res;
}

// words of a name, for matching a written name to MOIS's ("C/STONE PRESS CM 80" ↔ "Curbstone Press 80cm")
const words = s => String(s).toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(w => w && w !== 'cm' && w !== 'pcs');
function bestMatch(name, list) {
  const a = words(name); let best = null; let score = 0;
  for (const x of list) {
    const b = words(x.name);
    const s = a.filter(w => b.some(v => v === w || (w.length >= 3 && (v.startsWith(w) || w.startsWith(v))))).length;
    if (s > score) { best = x; score = s; }
  }
  return best;
}

/** Report vs MOIS → rows { section, item, report, mois } (numbers, or null when missing) */
export function compareReport(read, facts) {
  const rows = []; const used = new Set();
  for (const p of read.products) {
    const m = bestMatch(p.name, facts.products.filter(x => !used.has(x)));
    if (m) used.add(m);
    const item = m ? `${p.name} ↔ ${m.name}` : p.name;
    rows.push({ section: 'Production', item: `${item} · pieces`, report: p.pieces, mois: m ? m.pieces : null });
    rows.push({ section: 'Production', item: `${item} · cement`, report: p.cement, mois: m ? m.cement : null });
    const lr = p.leftovers.reduce((t, l) => t + l.pieces, 0); const lm = m ? m.leftovers.reduce((t, l) => t + l.pieces, 0) : null;
    if (lr || lm) rows.push({ section: 'Production', item: `${item} · leftovers (mabaki)`, report: lr || null, mois: lm });
    if (p.people != null || m?.people) rows.push({ section: 'Production', item: `${item} · team`, report: p.people, mois: m ? m.people : null });
  }
  for (const m of facts.products.filter(x => !used.has(x))) {
    rows.push({ section: 'Production', item: `${m.name} · pieces (not in the report)`, report: null, mois: m.pieces });
  }
  rows.push({ section: 'Cement', item: 'Cement in store (bags)', report: read.cementStore, mois: facts.cementStore });
  const usedM = new Set();
  for (const r of read.meters) {
    const m = bestMatch(r.name, facts.meters.filter(x => !usedM.has(x)));
    if (m) usedM.add(m);
    const item = m ? m.name : r.name;
    rows.push({ section: 'Electricity', item: `${item} · morning`, report: r.morning, mois: m ? m.morning : null });
    rows.push({ section: 'Electricity', item: `${item} · evening`, report: r.evening, mois: m ? m.evening : null });
    rows.push({ section: 'Electricity', item: `${item} · used`, report: r.used, mois: m ? m.used : null });
  }
  for (const m of facts.meters.filter(x => !usedM.has(x))) {
    rows.push({ section: 'Electricity', item: `${m.name} · used (not in the report)`, report: null, mois: m.used });
  }
  return rows;
}
