// Browser glue: loads the kernel, creates the machine, shows its console.
import { Machine } from "./machine.js";

const consoleEl = document.getElementById("console");
const statusEl = document.getElementById("status");
const params = new URLSearchParams(location.search);

const kernelUrl = params.get("kernel") ?? "vmlinux.wasm";
const memoryMiB = Number(params.get("mem") ?? 128);
const cmdline = params.get("cmdline") ?? "";

// Console output is appended as the kernel wrote it, with the two control
// characters a tty echo produces interpreted: carriage returns are dropped
// (the tty sends "\r\n") and a backspace removes the previous character of
// the current line. Anything the host itself has to say goes in a separately
// styled "[host]" line so the two cannot be confused.
function kernelOutput(text) {
  for (const part of text.replaceAll("\r", "").split(/(\x08)/)) {
    if (part === "\b") {
      const last = consoleEl.lastChild;
      if (last?.nodeType === Node.TEXT_NODE && !last.data.endsWith("\n"))
        last.data = last.data.slice(0, -1);
    } else if (part) {
      if (consoleEl.lastChild?.nodeType === Node.TEXT_NODE)
        consoleEl.lastChild.data += part;
      else consoleEl.append(part);
    }
  }
  consoleEl.scrollTop = consoleEl.scrollHeight;
}

// Keyboard: translate key presses on the console into the bytes a terminal
// would send. The kernel's tty does the echoing and line editing.
function keyToInput(event) {
  if (event.metaKey || event.altKey) return null;
  if (event.ctrlKey)
    return /^[a-z]$/i.test(event.key)
      ? String.fromCharCode(event.key.toUpperCase().charCodeAt(0) - 64)
      : null;
  switch (event.key) {
    case "Enter":
      return "\n";
    case "Backspace":
      return "\x7f";
    case "Tab":
      return "\t";
    case "Escape":
      return "\x1b";
  }
  return event.key.length === 1 ? event.key : null;
}

function attachKeyboard(machine) {
  consoleEl.tabIndex = 0;
  consoleEl.focus();
  consoleEl.addEventListener("keydown", (event) => {
    // Leave copy (Ctrl+C with a selection) to the browser.
    if (event.ctrlKey && event.key.toLowerCase() === "c" &&
        !getSelection().isCollapsed)
      return;
    const input = keyToInput(event);
    if (input === null) return;
    event.preventDefault();
    machine.input(input);
  });
  consoleEl.addEventListener("paste", (event) => {
    event.preventDefault();
    machine.input(event.clipboardData.getData("text"));
  });
}

function hostNote(text, isError = false) {
  const line = document.createElement("span");
  line.className = isError ? "host error" : "host";
  line.textContent = `[host] ${text}\n`;
  consoleEl.append(line);
  consoleEl.scrollTop = consoleEl.scrollHeight;
}

function setStatus(text) {
  statusEl.textContent = text;
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
  const module = await WebAssembly.compileStreaming(fetch(kernelUrl));
  hostNote(`loaded ${kernelUrl}; ${memoryMiB} MiB memory; cmdline "${cmdline}"`);

  const machine = new Machine({
    module,
    memoryMiB,
    cmdline,
    createWorker() {
      const worker = new Worker(new URL("./worker.js", import.meta.url), {
        type: "module",
      });
      const handle = {
        postMessage: (msg) => worker.postMessage(msg),
        terminate: () => worker.terminate(),
        onmessage: null,
        onerror: null,
      };
      worker.onmessage = (e) => handle.onmessage?.(e.data);
      worker.onerror = (e) => handle.onerror?.(e);
      return handle;
    },
    onConsole: kernelOutput,
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
      }
    },
  });

  attachKeyboard(machine);

  // For poking at it from the devtools console.
  globalThis.machine = machine;
  machine.boot();
}

main().catch((e) => {
  hostNote(`failed to start: ${e}`, true);
  setStatus("failed");
});
