/*
 * MOIS service worker (PWA, 2026-10-30). Keeps only the app's own files so it
 * opens fast and can say it is offline. Business data is never stored: requests
 * to the database (another origin) and anything not GET pass straight through.
 * __BUILD__ is replaced on each build (vite.config.js), so a new deploy shows
 * as a new version.
 */
const CACHE = 'mois-shell-__BUILD__';
const SHELL = '/index.html';

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.add(SHELL)));
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
    await self.clients.claim();
  })());
});

// the person chose to reload into the new version
self.addEventListener('message', e => { if (e.data === 'update') self.skipWaiting(); });

self.addEventListener('fetch', e => {
  const { request } = e;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;

  // pages: the newest when online, the saved shell when not
  if (request.mode === 'navigate') {
    e.respondWith((async () => {
      try {
        const res = await fetch(request);
        if (res.ok) (await caches.open(CACHE)).put(SHELL, res.clone());
        return res;
      } catch {
        return (await caches.match(SHELL)) || Response.error();
      }
    })());
    return;
  }

  // built files, fonts and icons: named by version or never changing
  if (/^\/(assets|fonts|icons)\//.test(url.pathname)) {
    e.respondWith((async () => {
      const hit = await caches.match(request);
      if (hit) return hit;
      const res = await fetch(request);
      if (res.ok) (await caches.open(CACHE)).put(request, res.clone());
      return res;
    })());
  }
});
