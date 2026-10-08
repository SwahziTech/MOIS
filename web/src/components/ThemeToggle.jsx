import { useEffect, useState } from 'react';
import { Moon, Sun } from 'lucide-react';

const STORAGE_KEY = 'mois-theme';

/** Apply the saved (or OS-preferred) theme before first render to avoid a flash. */
export function initTheme() {
  let theme = localStorage.getItem(STORAGE_KEY);
  if (theme !== 'light' && theme !== 'dark') {
    theme = window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  document.documentElement.dataset.theme = theme;
}

/** Moon / sun button shown in the top-right of every page. */
export default function ThemeToggle() {
  const [theme, setTheme] = useState(
    () => document.documentElement.dataset.theme || 'light'
  );

  useEffect(() => {
    const onChange = e => setTheme(e.detail);
    window.addEventListener('mois-theme-change', onChange);
    return () => window.removeEventListener('mois-theme-change', onChange);
  }, []);

  function toggle() {
    const next = theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    localStorage.setItem(STORAGE_KEY, next);
    window.dispatchEvent(new CustomEvent('mois-theme-change', { detail: next }));
  }

  const label = theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode';

  return (
    <button
      id="theme-toggle"
      type="button"
      className="theme-toggle"
      onClick={toggle}
      aria-label={label}
      title={label}
    >
      {theme === 'dark'
        ? <Sun size={16} strokeWidth={1.8} />
        : <Moon size={16} strokeWidth={1.8} />}
    </button>
  );
}
