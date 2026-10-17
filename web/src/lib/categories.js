// Category groups (migration 038): a category can sit under a group
// (parent_category_id), one level deep. A group is only a heading — its
// products, colours, recipes and prices live on the categories under it.

const cmp = (a, b) => {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0, y = b[i] ?? 0;
    if (x !== y) return x - y;
  }
  return 0;
};

/**
 * categories: rows with id, name, sort_order, parent_category_id.
 * Returns helpers for labelling, ordering and choosing categories.
 */
export function categoryTools(categories) {
  const list = categories || [];
  const byId = Object.fromEntries(list.map(c => [c.id, c]));
  const groupIds = new Set(list.filter(c => c.parent_category_id).map(c => c.parent_category_id));
  const parentOf = c => (c?.parent_category_id ? byId[c.parent_category_id] : null);

  /** "Paving Blocks › Vibro" — or just the name for an ungrouped category */
  const label = (cOrId, sep = ' › ') => {
    const c = typeof cOrId === 'string' ? byId[cOrId] : cOrId;
    if (!c) return '—';
    const p = parentOf(c);
    return p ? `${p.name}${sep}${c.name}` : c.name;
  };

  /** Groups in their place in the order, each followed by its subcategories */
  const orderKey = c => {
    const p = parentOf(c);
    return p ? [p.sort_order ?? 0, 1, c.sort_order ?? 0] : [c.sort_order ?? 0, 0, 0];
  };
  const ordered = [...list].sort((a, b) => cmp(orderKey(a), orderKey(b)) || label(a).localeCompare(label(b)));

  return {
    byId,
    label,
    orderKey,
    compare: (a, b) => cmp(orderKey(a), orderKey(b)),
    ordered,
    isGroup: id => groupIds.has(id),
    childrenOf: id => ordered.filter(c => c.parent_category_id === id),
    /** Categories that hold products, colours, recipes and prices (not groups) */
    leaves: ordered.filter(c => !groupIds.has(c.id)),
  };
}
