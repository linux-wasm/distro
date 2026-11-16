// Service worker that makes the page cross-origin isolated on static hosts
// which cannot send HTTP headers (GitHub Pages).
//
// SharedArrayBuffer, and with it the kernel's shared memory, is only
// available to cross-origin isolated pages. Isolation is normally requested
// with two response headers; this worker adds them to every response it
// relays, including the page itself and the kernel thread worker scripts.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) =>
  event.waitUntil(self.clients.claim()),
);

self.addEventListener("fetch", (event) => {
  const request = event.request;
  // Chrome DevTools issues such requests; they cannot be relayed.
  if (request.cache === "only-if-cached" && request.mode !== "same-origin")
    return;

  event.respondWith(
    fetch(request).then((response) => {
      if (response.status === 0) return response; // opaque, leave alone
      const headers = new Headers(response.headers);
      headers.set("Cross-Origin-Opener-Policy", "same-origin");
      headers.set("Cross-Origin-Embedder-Policy", "require-corp");
      headers.set("Cross-Origin-Resource-Policy", "same-origin");
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers,
      });
    }),
  );
});
