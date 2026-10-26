/**
 * Frozen table headers that follow the page (2026-10-26, the user): the page
 * scrolls as usual — what is above a table scrolls away — and a table's
 * header row holds at the top of the screen only once it would leave it,
 * until the table itself has scrolled past. Its totals row (tfoot) holds at
 * the bottom of the screen the same way. Works for tables in the page and in
 * a window (a scrolling modal body), and keeps tables free to scroll sideways
 * (which plain CSS sticky can't do once a table scrolls sideways).
 *
 * Applies to every table inside a .table-container. Call once (Layout).
 */
const scrollerOf = el => {
  for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
    const oy = getComputedStyle(p).overflowY;
    if ((oy === 'auto' || oy === 'scroll') && p.scrollHeight > p.clientHeight) return p;
  }
  return null;   // the window
};

function place() {
  for (const box of document.querySelectorAll('.table-container')) {
    const head = box.querySelector(':scope > table > thead');
    const foot = box.querySelector(':scope > table > tfoot');
    if (!head && !foot) continue;
    const sc = scrollerOf(box);
    const top = sc ? sc.getBoundingClientRect().top : 0;
    const bottom = sc ? sc.getBoundingClientRect().bottom : window.innerHeight;
    const r = box.getBoundingClientRect();
    const hh = head ? head.getBoundingClientRect().height : 0;
    const fh = foot ? foot.getBoundingClientRect().height : 0;
    const room = Math.max(0, r.height - hh - fh);
    if (head) {
      const off = Math.min(Math.max(top - r.top, 0), room);
      const t = off > 0.5 ? `translateY(${off}px)` : '';
      for (const th of head.querySelectorAll('th')) if (th.style.transform !== t) th.style.transform = t;
      head.classList.toggle('is-frozen', off > 0.5);
    }
    if (foot) {
      const off = Math.max(Math.min(bottom - r.bottom, 0), -room);
      const t = off < -0.5 ? `translateY(${off}px)` : '';
      for (const td of foot.querySelectorAll('td, th')) if (td.style.transform !== t) td.style.transform = t;
      foot.classList.toggle('is-frozen', off < -0.5);
    }
  }
}

export function startFrozenHeads() {
  let queued = false;
  const tick = () => { if (queued) return; queued = true; requestAnimationFrame(() => { queued = false; place(); }); };
  window.addEventListener('scroll', tick, { passive: true, capture: true });   // the window and any scrolling window/body
  window.addEventListener('resize', tick, { passive: true });
  const mo = new MutationObserver(tick);                                        // tables appearing, rows loading
  mo.observe(document.body, { childList: true, subtree: true });
  tick();
  return () => {
    window.removeEventListener('scroll', tick, { capture: true });
    window.removeEventListener('resize', tick);
    mo.disconnect();
  };
}
