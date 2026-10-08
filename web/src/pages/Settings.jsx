import { useEffect, useState } from 'react';
import { useAuth } from '../hooks/useAuth';
import { supabase } from '../lib/supabase';
import PageShell from '../components/PageShell';
import ThemeToggle from '../components/ThemeToggle';

function Row({ label, children }) {
  return (
    <div style={{ display: 'flex', padding: '10px 0', borderBottom: '1px solid var(--border)', gap: 16 }}>
      <div style={{ width: 180, color: 'var(--text-muted)', fontSize: 'var(--text-sm)' }}>{label}</div>
      <div style={{ flex: 1, fontSize: 'var(--text-sm)', fontWeight: 500 }}>{children ?? '—'}</div>
    </div>
  );
}

export default function Settings() {
  const { profile, session, userRoles } = useAuth();
  const [org, setOrg] = useState(null);

  useEffect(() => {
    if (!profile?.organization_id) return;
    supabase
      .from('organizations')
      .select('name, legal_name, status')
      .eq('id', profile.organization_id)
      .maybeSingle()
      .then(({ data }) => setOrg(data));
  }, [profile?.organization_id]);

  const roles = userRoles.map(ur => ur.role?.name).filter(Boolean);

  return (
    <PageShell title="Settings" subtitle="Organization">
      <div style={{ display: 'grid', gap: 16, gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))' }}>
        <section className="card">
          <div className="card-header"><h2 className="card-title">Organization</h2></div>
          <div className="card-body" style={{ paddingTop: 6 }}>
            <Row label="Name">{org?.name}</Row>
            <Row label="Legal name">{org?.legal_name}</Row>
            <Row label="Status">
              {org?.status && <span className="badge badge-success">{org.status}</span>}
            </Row>
          </div>
        </section>

        <section className="card">
          <div className="card-header"><h2 className="card-title">Your account</h2></div>
          <div className="card-body" style={{ paddingTop: 6 }}>
            <Row label="Name">
              {[profile?.first_name, profile?.last_name].filter(Boolean).join(' ') || null}
            </Row>
            <Row label="Email">{session?.user?.email}</Row>
            <Row label="Roles">
              {roles.length
                ? roles.map(r => <span key={r} className="badge badge-accent" style={{ marginRight: 4 }}>{r}</span>)
                : null}
            </Row>
          </div>
        </section>

        <section className="card">
          <div className="card-header"><h2 className="card-title">Appearance</h2></div>
          <div className="card-body" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div>
              <div style={{ fontWeight: 500, fontSize: 'var(--text-sm)' }}>Light / dark mode</div>
              <div className="text-muted text-sm">Saved on this device.</div>
            </div>
            <ThemeToggle />
          </div>
        </section>
      </div>
    </PageShell>
  );
}
