self.addEventListener('install', function() { self.skipWaiting(); });
self.addEventListener('activate', function() {
  self.registration.unregister();
  caches.keys().then(function(keys) { keys.forEach(function(k) { caches.delete(k); }); });
});
