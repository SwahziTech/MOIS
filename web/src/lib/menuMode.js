import { useEffect, useState } from 'react';

/* Is the top menu on (2026-11-10)? The side menu sets body.menu-top and tells the pages. */
export function useMenuTop() {
  const read = () => document.body.classList.contains('menu-top');
  const [top, setTop] = useState(read);
  useEffect(() => {
    const on = () => setTop(read());
    on();
    window.addEventListener('mois:menu-mode', on);
    return () => window.removeEventListener('mois:menu-mode', on);
  }, []);
  return top;
}
