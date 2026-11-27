import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from './useAuth';

const BranchContext = createContext(null);
const EMPTY = [];
const NONE = {};

const storageKey = userId => `mois.branch.${userId}`;
function readStored(userId) {
  try { return localStorage.getItem(storageKey(userId)); } catch { return null; }
}
function writeStored(userId, value) {
  try { localStorage.setItem(storageKey(userId), value); } catch { /* private mode etc. */ }
}
// the branch list as last read, kept on this device: pages open on the right branch at once instead of loading
// everything for all branches first and again for the branch a moment later (2026-11-27, the user: "loads forever")
const listsKey = orgId => `mois.branches.${orgId}`;
function readLists(orgId) {
  try { return orgId ? JSON.parse(localStorage.getItem(listsKey(orgId)) || 'null') : null; } catch { return null; }
}

/*
 * The branch every screen is looking at ('' = all branches). Screens filter
 * their own data by it; RLS still decides what a user can see at all.
 *
 * Starts on the viewer's last choice, else the organization's default branch
 * (organizations.default_branch_id, migration 030), else all branches. Users
 * whose roles are tied to branches or stores only get those branches.
 */
export function BranchProvider({ children }) {
  const { session, organization, userRoles } = useAuth();
  const userId = session?.user?.id;
  // { orgId, all: active branches the user can read, whBranch: warehouse id → branch id }
  const [lists,     setLists]     = useState(() => readLists(organization?.id));
  const [chosen,    setChosen]    = useState(null);   // null = not chosen in this session
  const ready = !!organization?.id && lists?.orgId === organization.id;
  const all = ready ? lists.all : EMPTY;
  const whBranch = ready ? lists.whBranch : NONE;

  useEffect(() => {
    if (!organization?.id) return;
    let live = true;
    Promise.all([
      supabase.from('branches').select('id, name, status').order('name'),
      supabase.from('warehouses').select('id, branch_id'),
    ]).then(([br, wh]) => {
      if (!live) return;
      if (br.error) console.error('branches load failed', br.error);
      const next = { orgId: organization.id, all: (br.data || []).filter(b => b.status === 'active'),
        whBranch: Object.fromEntries((wh.data || []).map(w => [w.id, w.branch_id])) };
      // a failed read keeps the list already shown
      if (br.error || wh.error) { setLists(cur => (cur?.orgId === next.orgId ? cur : next)); return; }
      setLists(cur => (JSON.stringify(cur) === JSON.stringify(next) ? cur : next));
      try { localStorage.setItem(listsKey(next.orgId), JSON.stringify(next)); } catch { /* storage off */ }
    });
    return () => { live = false; };
  }, [organization?.id]);

  // Branches this user's roles reach: all of them with any org-wide role
  const branches = useMemo(() => {
    if (userRoles.some(ur => !ur.branch_id && !ur.warehouse_id)) return all;
    const reach = new Set(userRoles.map(ur => ur.branch_id || whBranch[ur.warehouse_id]).filter(Boolean));
    return all.filter(b => reach.has(b.id));
  }, [all, userRoles, whBranch]);

  const allowAll = branches.length !== 1;
  const valid = id => (id === '' ? allowAll : branches.some(b => b.id === id));
  const stored = userId ? readStored(userId) : null;
  const defaultId = organization?.default_branch_id ?? null;
  const branchId =
    chosen != null && valid(chosen) ? chosen
    : stored != null && valid(stored) ? stored
    : defaultId && valid(defaultId) ? defaultId
    : allowAll ? '' : branches[0]?.id ?? '';

  function setBranchId(id) {
    setChosen(id);
    if (userId) writeStored(userId, id);
  }

  const value = {
    ready,   // the branch list is known — pages wait for it, so they load once, for the right branch
    branchId,
    setBranchId,
    branches,
    allowAll,
    branchName: branches.find(b => b.id === branchId)?.name ?? null,
    /** Whether a row in branch `id` belongs in the current view */
    inBranch: id => !branchId || id === branchId,
  };
  return <BranchContext.Provider value={value}>{children}</BranchContext.Provider>;
}

export function useBranch() {
  const ctx = useContext(BranchContext);
  if (!ctx) throw new Error('useBranch must be used within BranchProvider');
  return ctx;
}
