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

/**
 * Size as a sort key: area first (width × length), then each dimension.
 * "300x200x80mm" reads in mm, everything else in cm. No size sorts last.
 */
export function sizeKey(size) {
  if (!size) return [Infinity];
  const mm = /mm/i.test(size);
  const nums = (String(size).match(/\d+(?:\.\d+)?/g) || []).map(Number).map(n => (mm ? n / 10 : n));
  if (!nums.length) return [Infinity];
  return [nums.length >= 2 ? nums[0] * nums[1] : nums[0], ...nums];
}
export const compareKeys = (a, b) => {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? -1, y = b[i] ?? -1;
    if (x !== y) return x - y;
  }
  return 0;
};

/**
 * The order products appear in everywhere (decided 2026-10-20): the
 * organization's category order, then size smallest first, then name.
 * Items: { categoryId, size, name }.
 */
export function productOrder(cats) {
  return (a, b) => {
    const ca = cats.byId[a.categoryId], cb = cats.byId[b.categoryId];
    return (ca && cb ? cats.compare(ca, cb) : 0)
      || compareKeys(sizeKey(a.size), sizeKey(b.size))
      || String(a.name).localeCompare(String(b.name), undefined, { numeric: true });
  };
}
