// Browser glue: loads the kernel, creates the machine with its disks and
// connects its console to a terminal emulator (xterm.js, loaded by
// index.html as the globals Terminal, FitAddon and WebglAddon).
import { Machine } from "./machine.js";

const notesEl = document.getElementById("notes");
const statusEl = document.getElementById("status");
const params = new URLSearchParams(location.search);

const kernelUrl = params.get("kernel") ?? "vmlinux.wasm";
const memoryMiB = Number(params.get("mem") ?? 128);
const cmdline = params.get("cmdline") ?? "";
// The file in the origin private file system that holds the user's
// changes to the file system (the kernel's /dev/vdb).
const DATA_FILE = "data.img";
const RESET = "linux-wasm-reset-disk";

// Everything the terminal shows is output of the kernel or of programs.
// What the page itself has to say goes below it, so that the two cannot
// be confused.
function hostNote(text, isError = false) {
  const line = document.createElement("span");
  if (isError) line.className = "error";
  line.textContent = `[host] ${text}\n`;
  notesEl.append(line);
  notesEl.scrollTop = notesEl.scrollHeight;
}

function setStatus(text) {
  statusEl.textContent = text;
}

function createTerminal() {
  const terminal = new Terminal({
    cursorBlink: true,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
    fontSize: 14,
    scrollback: 5000,
    theme: { background: "#111111", foreground: "#dddddd" },
  });
  const fit = new FitAddon.FitAddon();
  terminal.loadAddon(fit);
  terminal.open(document.getElementById("terminal"));
  try {
    // Draws on a canvas; without WebGL the DOM renderer stays in use.
    const webgl = new WebglAddon.WebglAddon();
    webgl.onContextLoss(() => webgl.dispose());
    terminal.loadAddon(webgl);
  } catch {
    // The DOM renderer it is.
  }
  fit.fit();
  new ResizeObserver(() => fit.fit()).observe(document.getElementById("terminal"));
  terminal.focus();
  return terminal;
}

function createWorker(file) {
  const worker = new Worker(new URL(file, import.meta.url), { type: "module" });
  const handle = {
    postMessage: (msg) => worker.postMessage(msg),
    terminate: () => worker.terminate(),
    onmessage: null,
    onerror: null,
  };
  worker.onmessage = (e) => handle.onmessage?.(e.data);
  worker.onerror = (e) => handle.onerror?.(e);
  return handle;
}

async function resetDisk() {
  const root = await navigator.storage.getDirectory();
  for (const name of [`${DATA_FILE}.ready`, DATA_FILE])
    await root.removeEntry(name).catch((e) => {
      if (e.name !== "NotFoundError") throw e;
    });
}

async function main() {
  if (!globalThis.crossOriginIsolated) {
    hostNote(
      "This page is not cross-origin isolated, so SharedArrayBuffer is " +
        "unavailable. Serve it with scripts/serve.mjs, or let sw.js add the COOP/COEP headers.",
      true,
    );
    setStatus("cannot start");
    return;
  }

  setStatus("loading kernel");
  const [module, build] = await Promise.all([
    WebAssembly.compileStreaming(fetch(kernelUrl)),
    fetch("build.json").then((r) => r.json()),
  ]);
  hostNote(`loaded ${kernelUrl}; ${memoryMiB} MiB memory; cmdline "${cmdline}"`);
  // Ask the browser not to evict the stored changes under storage pressure.
  navigator.storage?.persist?.().catch(() => {});

  const terminal = createTerminal();
  let machine;

  // The running machine holds the file open, so it is deleted on the way
  // into the next one.
  document.getElementById("reset").addEventListener("click", () => {
    if (!confirm("Delete all stored changes to the file system and restart?"))
      return;
    sessionStorage.setItem(RESET, "1");
    machine.stop();
    location.reload();
  });
  if (sessionStorage.getItem(RESET)) {
    sessionStorage.removeItem(RESET);
    await resetDisk();
    hostNote("stored changes deleted");
  }

  machine = new Machine({
    module,
    memoryMiB,
    cmdline,
    // The layers of the root file system, see scripts/build.sh rootfs:
    // the base as shipped, and the user's changes.
    disks: [
      {
        bytes: build.base_bytes,
        readOnly: true,
        backend: { kind: "http", url: new URL("base.erofs", location.href).href },
      },
      {
        bytes: build.data_bytes,
        backend: {
          kind: "opfs",
          name: DATA_FILE,
          bytes: build.data_bytes,
          initialUrl: new URL("data.img.gz", location.href).href,
        },
      },
    ],
    createWorker: () => createWorker("./worker.js"),
    createDeviceWorker: () => createWorker("./device-worker.js"),
    onConsoleBytes: (bytes) => terminal.write(bytes),
    onEvent(event) {
      switch (event.type) {
        case "thread-start":
        case "thread-exit":
          setStatus(`running, ${machine.threadCount} kernel threads`);
          break;
        case "halt":
          hostNote(`machine halted: ${event.reason}`);
          setStatus(`halted (${event.reason})`);
          break;
        case "returned":
          hostNote(`thread ${event.id} returned from its entry point`, true);
          break;
        case "trap":
          hostNote(`thread ${event.id} trapped: ${event.message}\n${event.stack}`, true);
          break;
        case "user-exec-error":
          hostNote(`thread ${event.id}: cannot load user program: ${event.message}`, true);
          break;
        case "worker-error":
          hostNote(`worker ${event.id} failed: ${event.message}`, true);
          break;
        case "device-note":
          hostNote(`disk ${event.device}: ${event.text}`);
          break;
        case "device-error":
          hostNote(`disk ${event.device} failed: ${event.message}`, true);
          break;
      }
    },
  });

  // Keyboard and paste: the terminal emulator turns them into the bytes a
  // terminal sends; the kernel's tty does the rest.
  terminal.onData((data) => machine.input(data));
  terminal.onBinary((data) =>
    machine.input(Uint8Array.from(data, (c) => c.charCodeAt(0))),
  );
  terminal.onResize(({ cols, rows }) => machine.resize(cols, rows));
  machine.resize(terminal.cols, terminal.rows);

  // For poking at it from the devtools console.
  globalThis.machine = machine;
  globalThis.terminal = terminal;
  machine.boot();
}

main().catch((e) => {
  hostNote(`failed to start: ${e}`, true);
  setStatus("failed");
});
