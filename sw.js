/* The Ledger — Service Worker
   HTML: Cache-First (app JS handles updates via checkForUpdate, writes new HTML into cache)
   Assets: Network-First with offline fallback
   This ensures home screen / PWA always serves from cache (fast) and
   updates are applied explicitly by the app, not the CDN. */

const CACHE = 'ledger-v5';
const SHELL = ['/ledger/', '/ledger/index.html', '/ledger/i18n.js', '/ledger/icon.svg',
               '/ledger/icon-monogram.svg', '/ledger/icon-book.svg'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(SHELL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
      .then(() => self.clients.matchAll({ type:'window', includeUncontrolled:true }))
      .then(clients => {
        // Tell every open tab/window to reload so they get the new cached HTML
        clients.forEach(c => c.postMessage({ type:'SW_UPDATED' }));
      })
  );
});

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);

  // Runtime-cache the CDN libraries (supabase, html2canvas, jsPDF) so they load instantly
  // and work offline after the first fetch — keeps invoice PDF export reliable across the
  // page reloads that app updates trigger (stale-while-revalidate).
  if (url.hostname === 'cdn.jsdelivr.net') {
    event.respondWith(
      caches.open(CACHE).then(cache =>
        cache.match(event.request).then(cached => {
          const net = fetch(event.request)
            .then(resp => { if (resp && resp.ok) cache.put(event.request, resp.clone()); return resp; })
            .catch(() => cached);
          return cached || net;
        })
      )
    );
    return;
  }

  if (url.origin !== location.origin) return;

  const isShell = url.pathname === '/ledger/' ||
                  url.pathname === '/ledger/index.html' ||
                  url.pathname === '/ledger';

  if (isShell) {
    // Cache-First for HTML shell — app JS explicitly updates the cache when
    // a new version is found, then reloads so SW serves the fresh cached HTML.
    // ignoreSearch: auth-return links arrive with query strings (?code=...) and
    // must still hit the cached shell — they otherwise bypass it and fail offline.
    event.respondWith(
      caches.match('/ledger/index.html', { ignoreSearch: true }).then(cached => {
        if (cached) return cached;
        // First visit — no cache yet, fetch from network
        return fetch(event.request).then(response => {
          if (response.ok) {
            caches.open(CACHE).then(c => c.put('/ledger/index.html', response.clone()));
          }
          return response;
        }).catch(() => caches.match('/ledger/index.html'));
      })
    );
  } else {
    // Network-First for everything else (manifest, icons, etc.)
    event.respondWith(
      fetch(event.request)
        .then(response => {
          if (response.ok) {
            caches.open(CACHE).then(c => c.put(event.request, response.clone()));
          }
          return response;
        })
        .catch(() => caches.match(event.request))
    );
  }
});

// App can message the SW to update the cached HTML directly
self.addEventListener('message', event => {
  if (event.data?.type === 'CACHE_UPDATE' && event.data.html) {
    // waitUntil keeps the SW alive until both puts land — without it the browser may
    // kill the worker mid-write, leaving '/ledger/' and '/ledger/index.html' skewed.
    const work = caches.open(CACHE).then(cache => {
      const r = new Response(event.data.html, {
        status: 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' }
      });
      return Promise.all([
        cache.put('/ledger/', r.clone()),
        cache.put('/ledger/index.html', r.clone())
      ]);
    });
    if (event.waitUntil) event.waitUntil(work);
  }
});
