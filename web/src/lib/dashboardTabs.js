/*
 * The dashboard's tabs (2026-11-10, the user): every tab there is, and each role's
 * built-in set. The Technical admin can arrange a role's tabs (116, Settings ›
 * Dashboard layout); what a person can open on a tab still follows their permissions.
 */
export const DASHBOARD_TABS = [
  { key: 'director', label: 'Director view' },
  { key: 'overview', label: 'Overview', note: 'all summaries' },
  { key: 'hr', label: 'HR', note: 'Personnel, Attendance, Payroll', perm: ['staff.view'] },
  { key: 'attendance', label: 'Attendance', perm: ['staff.view'] },
  { key: 'sales', label: 'Sales', perm: ['sales.view'] },
  { key: 'production', label: 'Production', perm: ['production.view'] },
  { key: 'purchases', label: 'Purchases', perm: ['procurement.view', 'procurement.receive'] },
  { key: 'inventory', label: 'Inventory', perm: ['inventory.view'] },
  { key: 'setup', label: 'Setup', note: 'master-data counts' },
];
export const DEFAULT_DASHBOARD = {
  owner: ['director', 'overview', 'hr', 'sales', 'production', 'purchases', 'inventory', 'setup'],
  director: ['director'],
  branch_manager: ['overview', 'attendance', 'sales', 'production', 'purchases', 'inventory'],
  secretary: ['overview', 'attendance', 'sales', 'production', 'purchases', 'inventory'],
};
export const defaultTabsFor = role => DEFAULT_DASHBOARD[role] ?? ['overview', 'sales', 'production', 'inventory', 'setup'];
