import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dbErrorMessage } from '../lib/masterData';
import { browserTimeZone } from '../lib/format';
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
  const { profile, session, userRoles, organization: org, canManage } = useAuth();

  const roles = [...new Set(userRoles.map(ur => ur.role?.name).filter(Boolean))];

  return (
    <PageShell title="Settings" subtitle="Organization">
      <div style={{ display: 'grid', gap: 16, gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))' }}>
        <section className="card">
          <div className="card-header"><h2 className="card-title">Organization</h2></div>
          <div className="card-body" style={{ paddingTop: 6 }}>
            <Row label="Name">{org?.name}</Row>
            <Row label="Legal name">{org?.legal_name}</Row>
            <Row label="Currency">{org?.currency_code}</Row>
            <Row label="Time zone"><TimeZone org={org} canEdit={canManage('org.manage')} /></Row>
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

/**
 * The organization's time zone decides what "today" is for stock movements
 * (migration 023): today's date can be posted by anyone allowed to, earlier
 * dates need stock-adjustment permission.
 */
function TimeZone({ org, canEdit }) {
  const { reloadProfile } = useAuth();
  const [editing, setEditing] = useState(false);
  const [value,   setValue]   = useState(org?.timezone ?? 'UTC');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const deviceZone = browserTimeZone();
  const zones = typeof Intl.supportedValuesOf === 'function' ? Intl.supportedValuesOf('timeZone') : [value];
  const localTime = tz => { try { return new Date().toLocaleTimeString('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit' }); } catch { return ''; } };

  async function save() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('organizations').update({ timezone: value }).eq('id', org.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setEditing(false);
    reloadProfile();
  }

  if (!editing) {
    return (
      <span className="flex items-center gap-8">
        {org?.timezone ?? 'UTC'} <span className="text-muted" style={{ fontWeight: 400 }}>({localTime(org?.timezone ?? 'UTC')} now)</span>
        {canEdit && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(true)}>Change</button>}
      </span>
    );
  }
  return (
    <span className="flex flex-col gap-4">
      <span className="flex items-center gap-8">
        <select className="form-input" style={{ width: 'auto' }} aria-label="Time zone" value={value} onChange={e => setValue(e.target.value)}>
          {zones.map(z => <option key={z} value={z}>{z}</option>)}
        </select>
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(false)}>Cancel</button>
      </span>
      {deviceZone && deviceZone !== value && (
        <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => setValue(deviceZone)}>
          Use this device's time zone ({deviceZone})
        </button>
      )}
      <span className="text-xs text-muted" style={{ fontWeight: 400 }}>
        One setting for the whole organization — it decides what "today" is for stock movements, the same for everyone. {localTime(value)} there now.
      </span>
      {error && <span className="text-xs text-error">{error}</span>}
    </span>
  );
}
