/**
 * Materials + recipe-ingredient mapping, shared by seed.js and the one-off
 * migration scripts so both produce exactly the same data.
 *
 * Reads materials_master.json / ratios_and_molds.json AS-IS (AGENTS.md §12).
 * The few tenant facts that are not in a structured field are named
 * constants below, each with its source and confirmation date.
 */

// Units named in materials_master.json / ratios_and_molds.json → unit symbol
// in the org's units table.
const UNIT_ALIASES = {
  '50kg bag': 'bag', 'bag': 'bag',
  'litre': 'L', 'liter': 'L', 'l': 'L',
  'kg': 'kg',
  'sqm': 'SQM', 'pcs': 'PCS',
  // Every sand/chip/kokoto/dust measure in the notebook is the same bucket:
  // floor/wall tiles spell it "ndoo/bucket", the other categories wrote
  // "unit". Confirmed by the tenant 2026-10-12.
  'bucket': 'bucket', 'ndoo': 'bucket', 'unit': 'bucket',
};

// Units introduced by materials_master.json (purchase/inventory units)
const MATERIAL_UNITS = {
  'Cbm':         { name: 'Cubic metre',          notes: null },
  'Trip/Truck':  { name: 'Trip / Truck (20 Cbm)', notes: '1 truck = 20 Cbm = 2,500 ndoo/buckets (Materials master, 2026-10-12)' },
  '25kg bag':    { name: 'Bag (25 kg)',          notes: null },
  '200L barrel': { name: 'Barrel (200 L)',       notes: null },
  '20L dumu':    { name: 'Dumu (20 L)',          notes: null },
};

// Materials master: "Trip/Truck is 20 Cbm, 20 Cbm = 2,500 ndoo/buckets"
const BUCKETS_PER_TRUCK = 2500;

// Pigment per recipe colour. Grey uses Rangi Black — notebook glossary
// "Rangi(Red and Black for both black and grey)"; confirmed 2026-10-12.
// White has none: it is the natural, unpigmented colour of concrete — the
// notebook's "—" for White is a recorded zero, not missing data (confirmed
// by the tenant 2026-10-12). A White recipe therefore has no pigment line.
const PIGMENT_BY_COLOUR = { Red: 'rangi_red', Black: 'rangi_black', Grey: 'rangi_black' };

/** True when a recipe ingredient is pigment for a colour that takes none. */
function isUnpigmented(component, ctx) {
  return String(component.material || '').toLowerCase() === 'rangi'
    && ctx.colour != null && !(ctx.colour in PIGMENT_BY_COLOUR);
}

// Generic ingredient names used in ratios_and_molds.json → material_id
const INGREDIENT_REF = {
  cement: 'cement',
  chip: 'chipping', chipping: 'chipping',
  kokoto: 'kokoto', kok: 'kokoto',
  dust: 'dust',
  dawa: 'dawa',
  rangi_red: 'rangi_red', rangi_black: 'rangi_black',
  rangi_grey: PIGMENT_BY_COLOUR.Grey,
};

// Product notes in product_master.json that mark an unresolved identity
const REVIEW_NOTE = /needs review|unresolved|ambiguous|needs confirmation|possible duplicate|not confirmed/i;

function unitSymbolFor(unitStr) {
  if (unitStr == null) return null;
  const s = String(unitStr).trim();
  return UNIT_ALIASES[s.toLowerCase()] ?? (MATERIAL_UNITS[s] ? s : null);
}

/**
 * The material a recipe ingredient uses, or null when the source does not
 * say (e.g. pigment on a White recipe, quantity '—').
 *   ctx.colour  — canonical recipe colour, if a colour recipe
 *   ctx.sandRef — sand_material_id for this recipe (ratios_and_molds.json)
 */
function resolveMaterialRef(component, ctx) {
  const m = String(component.material || '').toLowerCase();
  if (m === 'mchanga') {
    if (!ctx.sandRef) throw new Error('Recipe uses mchanga but has no sand_material_id');
    return ctx.sandRef;
  }
  if (m === 'rangi') return PIGMENT_BY_COLOUR[ctx.colour] ?? null;
  return INGREDIENT_REF[m] ?? null;
}

/**
 * materials_master.json → everything to store: categories, materials,
 * unit conversions, per-branch sources and review flags.
 */
function buildMaterialPlan(materialsMaster, branchNames) {
  const categories = [];
  const materials = [];
  const conversions = [];
  const sources = [];
  const flags = [];

  for (const m of materialsMaster.materials) {
    if (!categories.includes(m.category)) categories.push(m.category);

    const stockUnit = unitSymbolFor(m.inventory_unit);
    const purchaseUnit = unitSymbolFor(m.purchase_unit);
    if (m.inventory_unit && !stockUnit) throw new Error(`Unknown unit '${m.inventory_unit}' for ${m.material_id}`);
    if (m.purchase_unit && !purchaseUnit) throw new Error(`Unknown unit '${m.purchase_unit}' for ${m.material_id}`);

    materials.push({
      ref: m.material_id, name: m.name, category: m.category, stockUnit,
      notes: [m.note, m.conversion_note].filter(Boolean).join(' ') || null,
    });

    if (stockUnit && purchaseUnit && purchaseUnit !== stockUnit) {
      if (m.conversion_to_inventory_unit == null) throw new Error(`No conversion for ${m.material_id}`);
      conversions.push({ ref: m.material_id, unit: purchaseUnit, factor: m.conversion_to_inventory_unit, notes: m.conversion_note || null });
    }
    if (stockUnit === 'Trip/Truck') {
      conversions.push({ ref: m.material_id, unit: 'bucket', factor: 1 / BUCKETS_PER_TRUCK,
        notes: `1 truck = ${BUCKETS_PER_TRUCK} ndoo/buckets (Materials master)` });
    }

    if (m.source && m.source_branch) {
      sources.push({ ref: m.material_id, branch: m.source_branch, sourceName: m.source,
        purchaseUnit, isPrimary: true, notes: m.source_note || null });
    }

    if (!stockUnit || !purchaseUnit) {
      flags.push({ entity: 'material', ref: m.material_id, code: 'missing_unit',
        reason: 'Purchase and stock units are not specified in the source yet — enter them here.' });
    }
    if (m.used_in_recipes === false) {
      flags.push({ entity: 'material', ref: m.material_id, code: 'unconfirmed_use', reason: m.note });
    }
    const sourced = new Set(m.source && m.source_branch ? [m.source_branch] : []);
    const missing = branchNames.filter(b => !sourced.has(b));
    if (missing.length) {
      flags.push({ entity: 'material', ref: m.material_id, code: 'missing_branch_source',
        reason: `No source recorded for ${missing.join(', ')}.` });
    }
  }
  return { categories, materials, conversions, sources, flags };
}

/** product_master.json products whose own note marks them for review */
function productReviewFlags(productMaster) {
  const flags = [];
  for (const cat of productMaster.categories) {
    for (const p of cat.products) {
      if (p.note && REVIEW_NOTE.test(p.note)) {
        flags.push({ entity: 'product', ref: p.product_id, code: 'unresolved_identity', reason: p.note });
      }
    }
  }
  return flags;
}

module.exports = {
  UNIT_ALIASES, MATERIAL_UNITS, BUCKETS_PER_TRUCK, PIGMENT_BY_COLOUR,
  unitSymbolFor, resolveMaterialRef, isUnpigmented, buildMaterialPlan, productReviewFlags,
};
