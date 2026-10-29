/*
 * Sidebar layout per role (migration 098, 2026-10-30): the same pages, in
 * the order and sections the Technical admin set for a role; the current
 * sidebar (Sidebar's NAV) when none is set. A page a layout doesn't mention
 * (a page added later) goes into its usual section — or a section of that
 * name at the end — so nothing is ever lost from the menu.
 *   layout: { sections: [{ title, folded, items: [path…] }] }  (title '' = no heading)
 */

// whose layout a person sees, when they hold several roles: the highest
export const ROLE_RANK = ['owner', 'director', 'branch_manager', 'secretary', 'storekeeper'];
export function primaryRole(userRoles) {
  const names = [...new Set((userRoles || []).map(ur => ur.role?.name).filter(Boolean))];
  return names.sort((a, b) => (ROLE_RANK.indexOf(a) + 1 || 99) - (ROLE_RANK.indexOf(b) + 1 || 99))[0] ?? null;
}

/** The current sidebar as a layout — where the editor starts */
export function layoutFromNav(nav) {
  return { sections: nav.map(s => ({ title: s.section, folded: false, items: s.items.map(i => i.to) })) };
}

/** nav + a layout (or none) → [{ title, folded, items: [nav item…] }] */
export function resolveMenu(nav, layout) {
  if (!layout?.sections) return nav.map(s => ({ title: s.section, folded: false, items: s.items }));
  const byPath = {}; const homeOf = {};
  for (const s of nav) for (const i of s.items) { byPath[i.to] = i; homeOf[i.to] = s.section; }
  const used = new Set();
  const out = layout.sections.map(s => ({
    title: s.title ?? '', folded: !!s.folded,
    items: (s.items || []).filter(p => byPath[p] && !used.has(p) && used.add(p)).map(p => byPath[p]),
  }));
  for (const s of nav) for (const i of s.items) {
    if (used.has(i.to)) continue;
    let sec = out.find(x => x.title === homeOf[i.to]);
    if (!sec) { sec = { title: homeOf[i.to], folded: false, items: [] }; out.push(sec); }
    sec.items.push(i); used.add(i.to);
  }
  return out;
}
