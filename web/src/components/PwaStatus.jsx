import { useEffect, useRef, useState } from 'react';

const DISMISS_KEY = 'mois.install.dismissed';
const wasDismissed = () => { try { return localStorage.getItem(DISMISS_KEY) === '1'; } catch { return false; } };
const rememberDismissed = () => { try { localStorage.setItem(DISMISS_KEY, '1'); } catch { /* private window */ } };

/*
 * The installed app's small notes (PWA, 2026-10-30), along the bottom of the
 * screen: no connection; a new version ready to reload into; and, on a phone,
 * how to install MOIS. The service worker only runs in the built app.
 */
export default function PwaStatus() {
  const [offline, setOffline] = useState(() => !navigator.onLine);
  const [waiting, setWaiting] = useState(null);
  const [installEvent, setInstallEvent] = useState(null);
  const [iosHint, setIosHint] = useState(false);
  const reloading = useRef(false);

  useEffect(() => {
    const off = () => setOffline(true);
    const on = () => setOffline(false);
    window.addEventListener('offline', off);
    window.addEventListener('online', on);
    return () => { window.removeEventListener('offline', off); window.removeEventListener('online', on); };
  }, []);

  useEffect(() => {
    if (!import.meta.env.PROD || !('serviceWorker' in navigator)) return undefined;
    let reg = null;
    const check = () => reg?.update().catch(() => {});
    const watch = r => {
      if (r.waiting && navigator.serviceWorker.controller) setWaiting(r.waiting);
      r.addEventListener('updatefound', () => {
        const sw = r.installing;
        sw?.addEventListener('statechange', () => {
          if (sw.state === 'installed' && navigator.serviceWorker.controller) setWaiting(sw);
        });
      });
    };
    navigator.serviceWorker.register('/sw.js').then(r => { reg = r; watch(r); }).catch(e => console.error(e));
    const reload = () => { if (reloading.current) window.location.reload(); };
    navigator.serviceWorker.addEventListener('controllerchange', reload);
    const seen = () => { if (document.visibilityState === 'visible') check(); };
    document.addEventListener('visibilitychange', seen);
    const timer = setInterval(check, 3600000);
    return () => {
      navigator.serviceWorker.removeEventListener('controllerchange', reload);
      document.removeEventListener('visibilitychange', seen);
      clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    const standalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
    const phone = window.matchMedia('(max-width: 760px)').matches;
    if (standalone || !phone || wasDismissed()) return undefined;
    const ua = window.navigator.userAgent;
    if (/iPhone|iPad|iPod/.test(ua)) { setIosHint(true); return undefined; }
    const offer = e => { e.preventDefault(); setInstallEvent(e); };
    window.addEventListener('beforeinstallprompt', offer);
    return () => window.removeEventListener('beforeinstallprompt', offer);
  }, []);

  const dismiss = () => { rememberDismissed(); setInstallEvent(null); setIosHint(false); };
  async function install() {
    installEvent.prompt();
    await installEvent.userChoice.catch(() => null);
    dismiss();
  }
  function update() { reloading.current = true; waiting.postMessage('update'); }

  if (!offline && !waiting && !installEvent && !iosHint) return null;
  return (
    <div className="pwa-notes">
      {offline && <div className="pwa-note is-warn" role="status">You&apos;re offline. MOIS needs a connection to load and save.</div>}
      {waiting && <div className="pwa-note" role="status"><span>A new version of MOIS is ready.</span><button type="button" className="btn btn-primary btn-sm" onClick={update}>Reload</button></div>}
      {installEvent && <div className="pwa-note"><span>Add MOIS to your home screen.</span><button type="button" className="btn btn-primary btn-sm" onClick={install}>Install</button><button type="button" className="btn btn-ghost btn-sm" onClick={dismiss}>Not now</button></div>}
      {iosHint && <div className="pwa-note"><span>To install MOIS: tap Share, then Add to Home Screen.</span><button type="button" className="btn btn-ghost btn-sm" onClick={dismiss}>OK</button></div>}
    </div>
  );
}
