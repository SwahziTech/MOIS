import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import { SkeletonRow } from '../components/LoadingSpinner';
import { Beaker, Search } from 'lucide-react';

export default function Materials() {
  const [materials, setMaterials] = useState([]);
  const [loading,   setLoading]   = useState(true);
  const [error,     setError]     = useState('');
  const [search,    setSearch]    = useState('');

  async function load() {
    setLoading(true);
    setError('');
    const { data, error: err } = await supabase
      .from('materials')
      .select(`
        id, name, code, status, notes,
        unit:units(symbol, name)
      `)
      .order('name');
    if (err) { setError(err.message); setLoading(false); return; }
    setMaterials(data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  const filtered = !search
    ? materials
    : materials.filter(m =>
        m.name.toLowerCase().includes(search.toLowerCase()) ||
        (m.code || '').toLowerCase().includes(search.toLowerCase())
      );

  return (
    <PageShell
      title="Materials"
      subtitle="Master Data"
      actions={
        <div className="search-wrapper">
          <Search size={14} className="search-icon" />
          <input
            id="materials-search"
            type="search"
            className="search-input"
            placeholder="Search materials…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
      }
    >
      <div className="card">
        {error ? (
          <ErrorState message={error} onRetry={load} />
        ) : (
          <div className="table-container">
            <table>
              <thead>
                <tr>
                  <th>Code</th>
                  <th>Name</th>
                  <th>Default Unit</th>
                  <th>Notes</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  Array.from({ length: 6 }).map((_, i) => <SkeletonRow key={i} cols={5} />)
                ) : filtered.length === 0 ? (
                  <tr>
                    <td colSpan={5}>
                      <EmptyState
                        icon={Beaker}
                        title="No materials found"
                        description={search ? `No materials match "${search}".` : 'No materials seeded yet.'}
                      />
                    </td>
                  </tr>
                ) : (
                  filtered.map(m => (
                    <tr key={m.id}>
                      <td>
                        <code style={{ fontSize: 'var(--text-xs)', background: 'var(--bg-canvas)', padding: '2px 6px', borderRadius: 'var(--radius-sm)' }}>
                          {m.code || '—'}
                        </code>
                      </td>
                      <td style={{ fontWeight: 500 }}>{m.name}</td>
                      <td>{m.unit ? `${m.unit.symbol} (${m.unit.name})` : <span style={{ color: 'var(--text-muted)' }}>—</span>}</td>
                      <td style={{ color: 'var(--text-muted)', fontSize: 'var(--text-sm)', maxWidth: 280 }}>{m.notes || '—'}</td>
                      <td>
                        <span className={`badge ${m.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>
                          {m.status}
                        </span>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
            {!loading && filtered.length > 0 && (
              <div style={{ padding: '10px 14px', borderTop: '1px solid var(--border)', fontSize: 'var(--text-xs)', color: 'var(--text-muted)' }}>
                {filtered.length} material{filtered.length !== 1 ? 's' : ''}
              </div>
            )}
          </div>
        )}
      </div>
    </PageShell>
  );
}
