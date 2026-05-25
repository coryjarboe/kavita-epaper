// kavita-epaper service worker
// Network pass-through. We explicitly call event.respondWith(fetch(...)) so
// Chromium doesn't classify this as a no-op handler — empty fetch handlers
// (added solely to pass PWA install criteria) fail the install check in
// Chrome 112+ via the "skip no-op fetch handler" optimization.
//
// No caching: Kavita's library changes too often and we don't want stale
// covers or chapter lists. Network is always the source of truth.

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  // Explicit pass-through so Chrome counts this as a real fetch handler.
  event.respondWith(fetch(event.request));
});
