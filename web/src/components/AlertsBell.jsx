import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Bell } from 'lucide-react';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { orgToday } from '../lib/inventory';
import { loadAlerts } from '../lib/alerts';

const SEEN_KEY = 'mois.alerts.seen';
const readSeen = () => { try { return JSON.parse(localStorage.getItem(SEEN_KEY) || '{}'); } catch { return {}; } };
const writeSeen = v => { try { localStorage.setItem(SEEN_KEY, JSON.stringify(v)); } catch { /* private window */ } };

/*
 * The alert bell (PRD 4.16, 2026-10-30), beside the theme switch: what needs
 * this person now, at the chosen branch (lib/alerts). The badge counts alerts
 * that are new or have grown since the bell was last opened; opening it marks
 * them seen. Refreshed on every page change and every two minutes.
 */
export default function AlertsBell() {
  const { organization, can, session } = useAuth();
  const { inBranch, branchId } = useBranch();
  const location = useLocation();
  const navigate = useNavigate();
  const [alerts, setAlerts] = useState([]);
  const [open, setOpen] = useState(false);
  const [seen, setSeen] = useState(readSeen);
  const box = useRef(null);
  const today = orgToday(organization?.timezone);

  useEffect(() => {
    if (!session) return undefined;
    let live = true;
    const load = () => loadAlerts({ can, inBranch, today }).then(a => { if (live) setAlerts(a); });
    load();
    const t = setInterval(load, 120000);
    return () => { live = false; clearInterval(t); };
  }, [session, branchId, location.pathname]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!open) return undefined;
    const close = e => { if (box.current && !box.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);

  const fresh = alerts.filter(a => (seen[a.key] ?? 0) < a.count).length;
  function toggle() {
    if (!open) { const s = { ...seen }; for (const a of alerts) s[a.key] = a.count; setSeen(s); writeSeen(s); }
    setOpen(o => !o);
  }

  return (
    <div className="ab" ref={box}>
      <button type="button" className="ab-btn" aria-label={`Alerts${alerts.length ? ` (${alerts.length})` : ''}`} title="Alerts" onClick={toggle}>
        <Bell size={18} />
        {fresh > 0 && <span className="ab-badge">{fresh}</span>}
      </button>
      {open && (
        <div className="ab-panel" role="dialog" aria-label="Alerts">
          <div className="ab-head">Alerts{alerts.length ? ` · ${alerts.length}` : ''}</div>
          {alerts.length === 0 ? <p className="ab-empty">Nothing needs you right now.</p> : (
            <ul>
              {alerts.map(a => (
                <li key={a.key}>
                  <button type="button" className={`ab-item${a.level === 'warn' ? ' is-warn' : ''}`} onClick={() => { setOpen(false); navigate(a.to); }}>
                    <span className="ab-dot" aria-hidden="true" />{a.text}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
