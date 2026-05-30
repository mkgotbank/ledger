/* The Ledger — Service Worker
   Strategy: Network First → cache on success → fall back to cache offline.
   iOS Add-to-Home-Screen bypasses HTTP cache, so this SW is what guarantees
   the user always gets fresh content when online. */

const CACHE = 'ledger-v1';
const SHELL = ['/ledger/', '/ledger/index.html'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(SHELL))
  );
  // Take over immediately — no waiting for old tabs to close
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  // Delete any old caches from previous SW versions
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  // Only handle same-origin GET requests
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== location.origin) return;

  event.respondWith(
    fetch(event.request)
      .then(response => {
        // Cache a fresh copy
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE).then(cache => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
