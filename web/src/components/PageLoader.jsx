import { useEffect, useState } from 'react';

/*
 * What the app is doing while it waits (2026-11-27, the user: "does not show what is happening, either stuck or
 * loading"): a label from the start; after 8 s it says the connection is slow and offers Reload; after 25 s it says
 * it may be stuck. `full` fills the screen (sign-in, first open); otherwise it fills the page area beside the menu.
 */
export default function PageLoader({ label = 'Opening the page…', full = false }) {
  const [secs, setSecs] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setSecs(s => s + 1), 1000);
    return () => clearInterval(t);
  }, []);
  const slow = secs >= 8, stuck = secs >= 25;
  return (
    <div className={full ? 'fullscreen-loader' : 'page-loader'} role="status" aria-live="polite">
      <div className="spinner" style={{ width: 28, height: 28 }} />
      <div className="fullscreen-loader-label">{label}</div>
      {slow && (
        <div className="page-loader-slow">
          <span>{stuck ? 'This is taking too long — the connection may have dropped.' : `Slow connection — still loading (${secs} s)…`}</span>
          <button type="button" className="btn btn-outline btn-sm" onClick={() => window.location.reload()}>Reload</button>
        </div>
      )}
    </div>
  );
}
