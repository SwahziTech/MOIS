import { useEffect, useState } from 'react';
import { supabase } from './supabase';

/*
 * Where each product is kept at a branch (137, 2026-11-20): its home area on
 * the site plan, else the zone of a machine it is made on — the same rule as
 * product_zone() in the database. Zones are names with a text colour; the
 * stores stay as they are. Branches without a plan get nothing back.
 */
export const ZONE_COLORS = { teal: '#1D9E75', blue: '#378ADD', coral: '#D85A30', purple: '#7F77DD', amber: '#BA7517', pink: '#D4537E', green: '#639922', gray: '#888780' };

const cache = new Map();   // branch id → promise of the lookup, for this page load

async function loadSiteZones(branchId) {
  const [z, a, h, m, mp] = await Promise.all([
    supabase.from('site_zones').select('id, name, color').eq('branch_id', branchId),
    supabase.from('site_areas').select('id, name, zone_id, warehouse_id').eq('branch_id', branchId).eq('status', 'active'),
    supabase.from('product_home_areas').select('product_id, area_id').eq('branch_id', branchId),
    supabase.from('machines').select('id, name, zone_id').eq('branch_id', branchId).eq('status', 'active').not('zone_id', 'is', null).order('name'),
    supabase.from('machine_products').select('machine_id, product_id'),
  ]);
  if (z.error || a.error) return null;   // before 137, or no access: no zones shown
  const zones = Object.fromEntries((z.data || []).map(x => [x.id, { ...x, hex: ZONE_COLORS[x.color] ?? null }]));
  const areas = Object.fromEntries((a.data || []).map(x => [x.id, x]));
  const home = Object.fromEntries((h.data || []).map(x => [x.product_id, areas[x.area_id]]).filter(([, v]) => v));
  const machineZone = {};
  for (const l of mp.data || []) {
    const mc = (m.data || []).find(x => x.id === l.machine_id);
    if (mc && !machineZone[l.product_id]) machineZone[l.product_id] = mc.zone_id;
  }
  return {
    hasPlan: Object.keys(zones).length > 0,
    // { zone: { name, hex }, area: { name } | null } or null
    of(productId) {
      const area = home[productId] ?? null;
      const zone = zones[area?.zone_id ?? machineZone[productId]] ?? null;
      return zone || area ? { zone, area } : null;
    },
  };
}

export function siteZones(branchId) {
  if (!branchId) return Promise.resolve(null);
  if (!cache.has(branchId)) cache.set(branchId, loadSiteZones(branchId).catch(() => null));
  return cache.get(branchId);
}

/** The branch's lookup, or null while loading / without a plan */
export function useSiteZones(branchId) {
  const [z, setZ] = useState(null);
  useEffect(() => { let live = true; setZ(null); siteZones(branchId).then(v => { if (live) setZ(v); }); return () => { live = false; }; }, [branchId]);
  return z;
}

/** "Yard P · Tofali 6"" in the zone's colour — or nothing */
export function ZoneTag({ where, className = 'text-xs' }) {
  if (!where) return null;
  const text = [where.zone?.name, where.area?.name].filter(Boolean).join(' · ');
  return text ? <span className={className} style={{ color: where.zone?.hex ?? undefined, fontWeight: 600 }} title="Where it is kept (site plan)">{text}</span> : null;
}
