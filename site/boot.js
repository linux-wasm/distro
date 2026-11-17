// Entry point of the page: make sure it is cross-origin isolated, then
// start the kernel host (host.js, taken from the kernel tree at build time).
//
// If the server already sends the COOP/COEP headers (scripts/serve.mjs) the
// page is isolated from the start. Otherwise (GitHub Pages) install sw.js,
// which adds them, and reload once so that this document is served by it.

const RELOADED = "linux-wasm-coi-reloaded";
const statusEl = document.getElementById("status");

async function showBuildInfo() {
  try {
    const info = await (await fetch("build.json")).json();
    const el = document.getElementById("build");
    el.textContent = `kernel ${info.kernel_commit.slice(0, 12)}`;
    el.href = `${info.kernel_repo}/commit/${info.kernel_commit}`;
  } catch {
    // Informational only.
  }
}

async function main() {
  showBuildInfo();

  if (globalThis.crossOriginIsolated) {
    sessionStorage.removeItem(RELOADED);
  } else if ("serviceWorker" in navigator && !sessionStorage.getItem(RELOADED)) {
    statusEl.textContent = "enabling cross-origin isolation";
    await navigator.serviceWorker.register("sw.js");
    await navigator.serviceWorker.ready;
    sessionStorage.setItem(RELOADED, "1");
    location.reload();
    return;
  }
  // Not isolated and nothing more to try: host.js explains the problem.
  await import("./host.js");
}

main();
