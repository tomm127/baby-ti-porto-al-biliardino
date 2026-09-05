const CACHE = 'baby-biliardino-shell-v9';
const SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png', '/icons/badge-96.png', '/sounds/race-start-beeps-125125.mp3', '/sounds/boxing-bell-1-232450.mp3', '/sounds/new-notification-09-352705.mp3'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      self.clients.claim(),
      caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))),
    ]),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) caches.open(CACHE).then((cache) => cache.put('/', response.clone()));
          return response;
        })
        .catch(async () => (await caches.match('/')) || Response.error()),
    );
    return;
  }

  // Vite's production assets are content-hashed. Cache them locally so the app
  // shell keeps opening even if Wi-Fi drops during the tournament. Use
  // stale-while-revalidate for non-navigation same-origin assets.
  if (['script', 'style', 'image', 'font', 'manifest', 'audio'].includes(request.destination)) {
    event.respondWith(
      caches.match(request).then((cached) => {
        const network = fetch(request).then((response) => {
          if (response.ok) caches.open(CACHE).then((cache) => cache.put(request, response.clone()));
          return response;
        }).catch(() => cached || Response.error());
        return cached || network;
      }),
    );
  }
});

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { body: event.data?.text() ?? '' }; }

  const title = data.title || 'BTPB';
  const called = data.kind === 'called';
  const options = {
    body: data.body || 'Aggiornamento torneo',
    icon: '/icons/icon-192.png',
    badge: '/icons/badge-96.png',
    tag: data.tag || `baby-biliardino-${Date.now()}`,
    renotify: called,
    requireInteraction: called,
    silent: false,
    vibrate: called ? [220, 100, 220] : [140],
    data: { url: data.url || '/', kind: data.kind, ...(data.data || {}) },
  };

  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true,
    });

    const visibleClients = clients.filter(
      (client) => client.visibilityState === 'visible',
    );

    await Promise.all(visibleClients.map((client) => client.postMessage({
      type: 'BTPB_PUSH_ALERT',
      kind: data.kind,
      title,
      body: options.body,
    })));

    if (visibleClients.length === 0) {
      await self.registration.showNotification(title, options);
    }
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = new URL(event.notification.data?.url || '/', self.location.origin).href;

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(async (clients) => {
      for (const client of clients) {
        if ('focus' in client) {
          await client.focus();
          if ('navigate' in client) await client.navigate(targetUrl);
          return;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    }),
  );
});
