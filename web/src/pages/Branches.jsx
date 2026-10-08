import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { Building2, MapPin } from 'lucide-react';

export default function Branches() {
  const [branches,   setBranches]   = useState([]);
  const [warehouses, setWarehouses] = useState([]);
  const [loading,    setLoading]    = useState(true);
  const [error,      setError]      = useState('');
  const [expanded,   setExpanded]   = useState({});

  async function load() {
    setLoading(true);
    setError('');
    const [brRes, whRes] = await Promise.all([
      supabase.from('branches').select('id, name, location, status, contact_info').order('name'),
      supabase.from('warehouses').select('id, name, type, status, branch_id').order('name'),
    ]);
    if (brRes.error) { setError(brRes.error.message); setLoading(false); return; }
    if (whRes.error) { setError(whRes.error.message); setLoading(false); return; }
    setBranches(brRes.data || []);
    setWarehouses(whRes.data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  function warehousesFor(branchId) {
    return warehouses.filter(w => w.branch_id === branchId);
  }

  const warehouseTypeLabel = {
    raw_materials:  'Raw Materials',
    finished_goods: 'Finished Goods',
    wip:            'WIP',
    general:        'General',
  };

  return (
    <PageShell title="Branches" subtitle="Organisation">
      {error ? (
        <ErrorState message={error} onRetry={load} />
      ) : loading ? (
        <div className="card">
          <div className="table-container">
            <table>
              <thead>
                <tr><th>Branch</th><th>Location</th><th>Warehouses</th><th>Status</th></tr>
              </thead>
              <tbody>{Array.from({ length: 3 }).map((_, i) => <SkeletonRow key={i} cols={4} />)}</tbody>
            </table>
          </div>
        </div>
      ) : branches.length === 0 ? (
        <div className="card">
          <EmptyState
            icon={Building2}
            title="No branches found"
            description="No branches have been seeded for this organisation."
          />
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {branches.map(branch => {
            const whs = warehousesFor(branch.id);
            const isExpanded = expanded[branch.id];
            return (
              <div key={branch.id} className="card">
                <div className="card-header" style={{ cursor: 'pointer' }}
                  onClick={() => setExpanded(e => ({ ...e, [branch.id]: !e[branch.id] }))}>
                  <div className="flex items-center gap-12">
                    <div style={{
                      width: 40, height: 40,
                      background: 'rgba(183,165,122,0.12)',
                      borderRadius: 'var(--radius-md)',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      flexShrink: 0,
                    }}>
                      <Building2 size={18} color="var(--color-khaki-dark)" strokeWidth={1.8} />
                    </div>
                    <div>
                      <div style={{ fontWeight: 600, fontSize: 'var(--text-md)' }}>{branch.name}</div>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 4, color: 'var(--text-muted)', fontSize: 'var(--text-sm)' }}>
                        <MapPin size={12} strokeWidth={1.5} />
                        {branch.location || 'Location not set'}
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-8">
                    <span className="badge badge-neutral">{whs.length} warehouse{whs.length !== 1 ? 's' : ''}</span>
                    <span className={`badge ${branch.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                      {branch.status}
                    </span>
                    <span style={{ color: 'var(--text-muted)', fontSize: 12 }}>
                      {isExpanded ? '▲' : '▼'}
                    </span>
                  </div>
                </div>

                {isExpanded && (
                  <div className="card-body" style={{ padding: '0' }}>
                    {whs.length === 0 ? (
                      <div style={{ padding: '20px', color: 'var(--text-muted)', fontSize: 'var(--text-sm)' }}>
                        No warehouses for this branch.
                      </div>
                    ) : (
                      <table>
                        <thead>
                          <tr>
                            <th>Warehouse</th>
                            <th>Type</th>
                            <th>Status</th>
                          </tr>
                        </thead>
                        <tbody>
                          {whs.map(wh => (
                            <tr key={wh.id}>
                              <td style={{ fontWeight: 500 }}>{wh.name}</td>
                              <td>
                                <span className="badge badge-info">
                                  {warehouseTypeLabel[wh.type] || wh.type}
                                </span>
                              </td>
                              <td>
                                <span className={`badge ${wh.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                                  {wh.status}
                                </span>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </PageShell>
  );
}
