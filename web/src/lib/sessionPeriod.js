import { useState } from 'react';

/*
 * The period a page opens on (2026-11-09, the user): This month everywhere; the
 * period a person picks is remembered for that page until the app is closed
 * (sessionStorage — kept across reloads, cleared when the app or tab closes).
 */
const read = id => { try { return sessionStorage.getItem(`mois.period.${id}`); } catch { return null; } };
const write = (id, v) => { try { sessionStorage.setItem(`mois.period.${id}`, v); } catch { /* storage off */ } };

export function useSessionPeriod(id, fallback = 'month', allowed = null) {
  const [key, setKeyRaw] = useState(() => {
    const v = read(id);
    return v && v !== 'range' && v !== 'custom' && (!allowed || allowed.includes(v)) ? v : fallback;
  });
  const setKey = v => { setKeyRaw(v); if (v !== 'range' && v !== 'custom') write(id, v); };
  return [key, setKey];
}

export { read as readSessionPeriod, write as writeSessionPeriod };
