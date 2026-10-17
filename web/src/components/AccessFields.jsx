import { roleLabel } from '../lib/manageUsers';

/**
 * Role + branch + warehouse pickers for a user_roles grant.
 * Empty branch = all branches; empty warehouse = all warehouses in scope.
 */
export default function AccessFields({ idPrefix, roles, branches, warehouses, value, onChange }) {
  const branchWarehouses = warehouses.filter(w => w.branch_id === value.branch_id);
  const set = patch => onChange({ ...value, ...patch });

  return (
    <div className="access-fields">
      <div className="form-group">
        <label className="form-label" htmlFor={`${idPrefix}-role`}>Role</label>
        <select id={`${idPrefix}-role`} className="form-input" required
          value={value.role_id} onChange={e => set({ role_id: e.target.value })}>
          <option value="">Choose a role…</option>
          {roles.map(r => <option key={r.id} value={r.id}>{roleLabel(r.name)}</option>)}
        </select>
      </div>
      <div className="form-group">
        <label className="form-label" htmlFor={`${idPrefix}-branch`}>Branch access</label>
        <select id={`${idPrefix}-branch`} className="form-input"
          value={value.branch_id} onChange={e => set({ branch_id: e.target.value, warehouse_id: '' })}>
          <option value="">All branches</option>
          {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
        </select>
      </div>
      <div className="form-group">
        <label className="form-label" htmlFor={`${idPrefix}-warehouse`}>Warehouse access</label>
        <select id={`${idPrefix}-warehouse`} className="form-input" disabled={!value.branch_id}
          value={value.warehouse_id} onChange={e => set({ warehouse_id: e.target.value })}>
          <option value="">{value.branch_id ? 'All warehouses in branch' : 'All warehouses'}</option>
          {branchWarehouses.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
        </select>
      </div>
    </div>
  );
}

export const EMPTY_ACCESS = { role_id: '', branch_id: '', warehouse_id: '' };

/** Human-readable scope of a user_roles row */
export function scopeLabel(grant) {
  if (grant.warehouse?.name) return `${grant.branch?.name ?? ''} · ${grant.warehouse.name}`;
  if (grant.branch?.name) return grant.branch.name;
  return 'Org-wide';
}
