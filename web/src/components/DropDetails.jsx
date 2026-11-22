import { useEffect, useRef } from 'react';

/*
 * A small drop-down (2026-11-22, the user: "if I click empty space it should disappear"): a <details> that closes
 * on a click outside it, on Escape, and — with closeOnPick — once something inside is picked.
 *   summary: what the closed button shows; className: extra classes (e.g. so-drop, so-drop is-up)
 */
export default function DropDetails({ summary, summaryClass = 'form-input', className = 'so-drop', closeOnPick = false, children }) {
  const ref = useRef(null);
  useEffect(() => {
    const away = e => { if (ref.current?.open && !ref.current.contains(e.target)) ref.current.open = false; };
    const esc = e => { if (e.key === 'Escape' && ref.current?.open) ref.current.open = false; };
    document.addEventListener('mousedown', away);
    document.addEventListener('touchstart', away);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', away); document.removeEventListener('touchstart', away); document.removeEventListener('keydown', esc); };
  }, []);
  return (
    <details ref={ref} className={className} onClick={closeOnPick ? e => { if (e.target.closest('.so-menu button') && ref.current) ref.current.open = false; } : undefined}>
      <summary className={summaryClass}>{summary}</summary>
      <div className="so-menu">{children}</div>
    </details>
  );
}
