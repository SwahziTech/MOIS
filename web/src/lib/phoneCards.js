/*
 * Phone cards (2026-11-23, the user: the phone app is the web app, so lists must read well on
 * a phone). A table with class "pc" shows on phones (≤760px, styles/index.css) as one card a
 * row: each cell labelled with its column's heading. This copies the headings onto the cells
 * (data-label) whenever tables appear or change; desktop shows the table as before.
 * Tables with merged rows (rowspan) or spreadsheet views (calendars, pay sheets) stay tables.
 */
export function installPhoneCards() {
  let queued = false;
  const label = () => {
    queued = false;
    for (const t of document.querySelectorAll('table.pc')) {
      const heads = [...t.querySelectorAll('thead th')].map(th => th.innerText.replace(/\s+/g, ' ').trim());
      for (const tr of t.querySelectorAll('tbody tr')) {
        let i = 0;
        for (const td of tr.children) {
          const want = td.colSpan > 1 ? '' : heads[i] ?? '';
          if (td.dataset.label !== want) td.dataset.label = want;
          i += td.colSpan || 1;
        }
      }
    }
  };
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(label); } };
  new MutationObserver(queue).observe(document.body, { childList: true, subtree: true });
  queue();
}
