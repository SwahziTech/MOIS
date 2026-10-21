import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { dbErrorMessage } from '../lib/masterData';
import { browserTimeZone } from '../lib/format';
import { roleLabel } from '../lib/manageUsers';
import PageShell from '../components/PageShell';
import ThemeToggle from '../components/ThemeToggle';
import NumberInput from '../components/NumberInput';
import { BranchVatCard, ExpenseCategoriesCard, RejectReasonsCard, CuringDays, PlannerMode } from '../components/settings/PurchaseSettings';

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
    <PageShell title="Settings" subtitle="Organization" description="Organization settings, your account and how the app looks.">
      <div style={{ display: 'grid', gap: 16, gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))' }}>
        <section className="card">
          <div className="card-header"><h2 className="card-title">Organization</h2></div>
          <div className="card-body" style={{ paddingTop: 6 }}>
            <Row label="Name">{org?.name}</Row>
            <Row label="Legal name">{org?.legal_name}</Row>
            <Row label="Currency">{org?.currency_code}</Row>
            <Row label="Time zone"><TimeZone org={org} canEdit={canManage('org.manage')} /></Row>
            <Row label="Default branch"><DefaultBranch org={org} canEdit={canManage('org.manage')} /></Row>
            <Row label="Yield tolerance"><YieldTolerance org={org} canEdit={canManage('org.manage')} /></Row>
            <Row label="Curing period"><CuringDays canEdit={canManage('org.manage')} /></Row>
            <Row label="Capacity planner"><PlannerMode canEdit={canManage('org.manage')} /></Row>
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
                ? roles.map(r => <span key={r} className="badge badge-accent" style={{ marginRight: 4 }}>{roleLabel(r)}</span>)
                : null}
            </Row>
          </div>
        </section>

        <BranchVatCard />
        <ExpenseCategoriesCard />
        <RejectReasonsCard />

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
 * ± pieces around the average yield per bag (migration 031): production
 * output outside the band gets flagged for review — never corrected.
 */
function YieldTolerance({ org, canEdit }) {
  const { reloadProfile } = useAuth();
  const [editing, setEditing] = useState(false);
  const [value,   setValue]   = useState(org?.yield_tolerance ?? '');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  async function save() {
    setError('');
    const n = String(value).trim() === '' ? null : Number(value);
    if (n != null && !(n >= 0)) { setError('Enter zero or more pieces, or leave blank for no check.'); return; }
    setBusy(true);
    const { error: err } = await supabase.from('organizations').update({ yield_tolerance: n }).eq('id', org.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setEditing(false);
    reloadProfile();
  }

  if (!editing) {
    return (
      <span className="flex items-center gap-8">
        {org?.yield_tolerance != null ? `± ${org.yield_tolerance} pieces per bag` : 'Not set'}
        {canEdit && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(true)}>Change</button>}
      </span>
    );
  }
  return (
    <span className="flex flex-col gap-4">
      <span className="flex items-center gap-8">
        ± <NumberInput min="0" step="any" className="form-input" style={{ width: 90 }} aria-label="Yield tolerance"
            value={value} onChange={e => setValue(e.target.value)} /> pieces per bag
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(false)}>Cancel</button>
      </span>
      <span className="text-xs text-muted" style={{ fontWeight: 400 }}>
        Production output outside the average yield ± this many pieces is flagged for review. A size or a branch can set its own.
      </span>
      {error && <span className="text-xs text-error">{error}</span>}
    </span>
  );
}

/**
 * Which branch everyone's screens open on (migration 030) — e.g. the branch
 * being verified first while others are rolled out later. Anyone can still
 * switch branch in the sidebar.
 */
function DefaultBranch({ org, canEdit }) {
  const { reloadProfile } = useAuth();
  const { branches } = useBranch();
  const [editing, setEditing] = useState(false);
  const [value,   setValue]   = useState(org?.default_branch_id ?? '');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const current = branches.find(b => b.id === org?.default_branch_id)?.name ?? 'All branches';

  async function save() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('organizations').update({ default_branch_id: value || null }).eq('id', org.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setEditing(false);
    reloadProfile();
  }

  if (!editing) {
    return (
      <span className="flex items-center gap-8">
        {current}
        {canEdit && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(true)}>Change</button>}
      </span>
    );
  }
  return (
    <span className="flex flex-col gap-4">
      <span className="flex items-center gap-8">
        <select className="form-input" style={{ width: 'auto' }} aria-label="Default branch" value={value} onChange={e => setValue(e.target.value)}>
          <option value="">All branches</option>
          {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
        </select>
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(false)}>Cancel</button>
      </span>
      <span className="text-xs text-muted" style={{ fontWeight: 400 }}>
        The branch screens open on for everyone, until they pick another in the sidebar.
      </span>
      {error && <span className="text-xs text-error">{error}</span>}
    </span>
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
