import { useEffect, useRef, useState } from 'react';
import { Search, ArrowUpDown, Check, ChevronDown } from 'lucide-react';

/*
 * The standard list-page controls (2026-10-17): a full-width search, a
 * "Sort / Filter" button opening a menu (sort options as a radio list,
 * then "Show" filters), and a row of chips for categories. Each page
 * brings its own options; only the structure is shared.
 */

/** Search bar + Sort / Filter menu (+ any extra controls, e.g. an ActionMenu) on one row */
export function ListToolbar({ search, onSearch, placeholder = 'Search…', sort, filters = [], id, children }) {
  return (
    <div className="list-toolbar">
      <div className="search-wrapper list-search">
        <Search size={15} className="search-icon" />
        <input id={id} type="search" className="search-input" placeholder={placeholder}
          value={search} onChange={e => onSearch(e.target.value)} aria-label={placeholder} />
      </div>
      {(sort || filters.length > 0) && <SortFilterMenu sort={sort} filters={filters} />}
      {children}
    </div>
  );
}

/**
 * sort:    { value, onChange, options: [{ value, label }] }
 * filters: [{ key, label, value, onChange, options: [{ value, label }] }] — shown under "Show"
 */
export function SortFilterMenu({ sort, filters = [] }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    if (!open) return;
    const close = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const esc = e => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
  }, [open]);

  // A dot on the button when a filter is narrowing the list
  const narrowed = filters.some(f => f.value !== f.options[0]?.value);

  return (
    <div className="sortfilter" ref={ref}>
      <button type="button" className={`btn btn-outline sortfilter-button${narrowed ? ' is-narrowed' : ''}`}
        aria-haspopup="true" aria-expanded={open} onClick={() => setOpen(o => !o)}>
        <ArrowUpDown size={14} /><span className="btn-label">Sort / Filter</span>
      </button>
      {open && (
        <div className="sortfilter-menu" role="menu">
          {sort && (
            <section>
              <div className="sortfilter-heading">Sort</div>
              {sort.options.map(o => (
                <button key={o.value} type="button" role="menuitemradio" aria-checked={sort.value === o.value}
                  className={`sortfilter-option${sort.value === o.value ? ' is-on' : ''}`}
                  onClick={() => { sort.onChange(o.value); setOpen(false); }}>
                  <span>{o.label}</span>{sort.value === o.value && <Check size={14} />}
                </button>
              ))}
            </section>
          )}
          {filters.length > 0 && (
            <section>
              <div className="sortfilter-heading">Show</div>
              {filters.map(f => (
                <div key={f.key} className="sortfilter-filter">
                  <label className="sortfilter-filter-label" htmlFor={`sf-${f.key}`}>{f.label}</label>
                  <select id={`sf-${f.key}`} className="form-input" value={f.value} onChange={e => f.onChange(e.target.value)}>
                    {f.options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
                  </select>
                </div>
              ))}
            </section>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Category chips: "All" plus each item; an item with children (a category
 * group, migration 038) opens a second row when it or a child is picked.
 * items: [{ id, label, children?: [{ id, label }] }]
 */
export function ChipRow({ items, value, onChange, allLabel = 'All' }) {
  const open = items.find(i => i.children?.length && (i.id === value || i.children.some(c => c.id === value)));
  return (
    <div className="chip-rows">
      <div className="filter-chips">
        <button type="button" className={`filter-chip${!value ? ' is-on' : ''}`} onClick={() => onChange('')}>{allLabel}</button>
        {items.map(i => (
          <button type="button" key={i.id} className={`filter-chip${value === i.id || open?.id === i.id ? ' is-on' : ''}`}
            onClick={() => onChange(value === i.id ? '' : i.id)}>
            {i.label}
          </button>
        ))}
      </div>
      {open && (
        <div className="filter-chips">
          <button type="button" className={`filter-chip${value === open.id ? ' is-on' : ''}`} onClick={() => onChange(open.id)}>All {open.label}</button>
          {open.children.map(c => (
            <button type="button" key={c.id} className={`filter-chip${value === c.id ? ' is-on' : ''}`} onClick={() => onChange(c.id)}>{c.label}</button>
          ))}
        </div>
      )}
    </div>
  );
}

/** Product-category chips from categoryTools() (lib/categories.js) */
export function categoryChipItems(cats, keep = () => true) {
  return cats.ordered
    .filter(c => !c.parent_category_id && keep(c))
    .map(c => ({ id: c.id, label: c.name, children: cats.isGroup(c.id) ? cats.childrenOf(c.id).map(k => ({ id: k.id, label: k.name })) : undefined }));
}

/**
 * A page's own tabs (e.g. Materials · Material categories · Units) — kept apart from category chips.
 * The page's tabs hold at the top of the screen once scrolled up to it (2026-10-27), with table headers
 * holding just below them; `nested` tabs inside a tab (e.g. Days · Readings) scroll away as usual.
 */
export function PageTabs({ tabs, value, onChange, nested = false }) {
  const ref = useRef(null);
  // the tabs' height, so frozen table headers sit just under them (the row can wrap on a narrow screen)
  useEffect(() => {
    if (nested || !ref.current || typeof ResizeObserver === 'undefined') return undefined;
    const root = document.documentElement;
    const ro = new ResizeObserver(([e]) => root.style.setProperty('--page-tabs-h', `${Math.ceil(e.target.getBoundingClientRect().height)}px`));
    ro.observe(ref.current);
    return () => { ro.disconnect(); root.style.removeProperty('--page-tabs-h'); };
  }, [nested]);
  return (
    <div ref={ref} className={`page-tabs${nested ? '' : ' is-page'}`} role="tablist">
      {tabs.map(([key, label]) => (
        <button key={key} type="button" role="tab" aria-selected={value === key}
          className={`page-tab${value === key ? ' is-on' : ''}`} onClick={() => onChange(key)}>{label}</button>
      ))}
    </div>
  );
}

/**
 * One button that opens the page's actions as a list (Stock: Receive,
 * Issue, …). items: [{ key, label, onClick, disabled, divider }] — a
 * divider item starts a new group.
 */
export function ActionMenu({ label, icon: Icon, items }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    if (!open) return;
    const close = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const esc = e => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
  }, [open]);

  return (
    <div className="sortfilter" ref={ref}>
      <button type="button" className="btn btn-primary" aria-haspopup="true" aria-expanded={open} title={label}
        onClick={() => setOpen(o => !o)}>
        {Icon && <Icon size={14} />}<span className="btn-label">{label}</span><ChevronDown size={14} />
      </button>
      {open && (
        <div className="sortfilter-menu action-menu" role="menu">
          {items.map(it => it.divider
            ? <div key={it.key} className="action-menu-divider" role="separator" />
            : (
              <button key={it.key} type="button" role="menuitem" className="sortfilter-option" disabled={it.disabled}
                onClick={() => { setOpen(false); it.onClick(); }}>
                <span>{it.label}</span>
              </button>
            ))}
        </div>
      )}
    </div>
  );
}
