/*
 * Guess an expense category from what a line says (2026-11-15, the user: "read the item and find its
 * category"). First what the branch chose before for the same words; then common words, Swahili and
 * English. Only a guess — the category stays changeable on the line.
 *   guessCategory(description, categories, history?) → category id | ''
 *   categories: [{ id, name, status }]; history: [{ description, category_id }] (earlier lines)
 */
const RULES = [
  // [category name (as in Settings), words…] — the first rule that matches wins
  // loading / offloading and posho are pay to people → Wages (2026-11-15, the user)
  ['Wages', /\b(vibarua|kibarua|casual|casuals|daily\s*labou?r|posho|upakizi|kupakia|kushusha|kupakua|loading|offloading)\b/i],
  ['Salaries', /\b(mishahara|mshahara|salary|salaries|payroll)\b/i],
  ['General expenses', /\bmafuta\s+ya\s+kula\b|\b(makato|wakala|charges?|bank\s*fee|sabuni|soap|chakula|food|chai|tea|usafi|cleaning|maji\s+ya\s+kunywa)\b/i],
  ['Transport', /\b(nauli|usafiri|transport|fare|kuosha\s+gari|car\s*wash|gari|lori|truck|bodaboda|diesel|petrol|fuel)\b/i],
  ['Spare parts', /\b(spare|spea|fan\s*belts?|belts?|bolts?|nati|nuts?|bearings?|oil|grease|filters?|seal|tyre|tairi|plug)\b/i],
  ['Tools', /\b(cutting|grinding|grending|disc|disk|stick|electrodes?|gamboot|gumboots?|gloves?|glavu|spana|spanner|nyundo|hammer|tools?|shovel|sepeto|koleo|toroli|wheelbarrow|brashi|brush|helmet|reflector)\b/i],
  ['Materials', /\b(cement|saruji|mchanga|sand|kokoto|aggregate|rangi|paint|dawa|chuma|nondo|waya|wire|material|materials)\b/i],
  ['Electricity (LUKU)', /\b(luku|umeme|electricity|token)\b/i],
  ['Water', /\b(maji|water)\b/i],
  ['Office tools', /\b(vocha|voucher|bundle|router|internet|wifi|stationery|karatasi|paper|printer|ink|kalamu|pen|file|sim\s*card|simu|airtime)\b/i],
  ['Other', /\b(ziada|other|others|mengineyo|dharura|emergency)\b/i],
];
const norm = s => String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

export function guessCategory(description, categories, history = []) {
  const d = norm(description);
  if (!d) return '';
  const live = categories.filter(c => c.status !== 'inactive');
  // the same item chosen before (newest first)
  const seen = history.find(h => h.category_id && norm(h.description) === d && live.some(c => c.id === h.category_id));
  if (seen) return seen.category_id;
  for (const [name, re] of RULES) {
    if (!re.test(String(description))) continue;
    const c = live.find(x => norm(x.name) === norm(name));
    if (c) return c.id;
  }
  return '';
}

/** Fill the lines that have no category yet; lines someone chose stay as they are */
export function fillCategories(lines, categories, history = []) {
  return lines.map(l => (l.locked || l.categoryId || !String(l.description ?? '').trim() ? l : { ...l, categoryId: guessCategory(l.description, categories, history) }));
}
