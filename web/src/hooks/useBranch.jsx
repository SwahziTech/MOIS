import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from './useAuth';

const BranchContext = createContext(null);

const storageKey = userId => `mois.branch.${userId}`;
function readStored(userId) {
  try { return localStorage.getItem(storageKey(userId)); } catch { return null; }
}
function writeStored(userId, value) {
  try { localStorage.setItem(storageKey(userId), value); } catch { /* private mode etc. */ }
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
  const [all,       setAll]       = useState([]);     // active branches the user can read
  const [whBranch,  setWhBranch]  = useState({});     // warehouse id → branch id
  const [chosen,    setChosen]    = useState(null);   // null = not chosen in this session

  useEffect(() => {
    if (!organization?.id) return;
    let live = true;
    Promise.all([
      supabase.from('branches').select('id, name, status').order('name'),
      supabase.from('warehouses').select('id, branch_id'),
    ]).then(([br, wh]) => {
      if (!live) return;
      if (br.error) console.error('branches load failed', br.error);
      setAll((br.data || []).filter(b => b.status === 'active'));
      setWhBranch(Object.fromEntries((wh.data || []).map(w => [w.id, w.branch_id])));
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
