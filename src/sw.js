// Cache only the same-origin application shell. Never cache auth or database responses.
const NAME='awb-shell-20261011',URLS=["./","./index.html","./config.js","./assets/cloud.js","./assets/cloud.css","./assets/v8-app.js","./assets/jszip.min.js"];
self.addEventListener('install',e=>{e.waitUntil(caches.open(NAME).then(c=>c.addAll(URLS)));});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('awb-shell-')&&k!==NAME).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));});
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==self.location.origin)return;const allowed=URLS.some(p=>new URL(p,self.registration.scope).href===u.href);if(!allowed)return;e.respondWith(fetch(e.request).catch(()=>caches.open(NAME).then(c=>c.match(e.request)).then(r=>r||Response.error())));});
