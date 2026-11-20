// Browser glue: the boot menu, then the machine with its disks and
// network card, its console connected to a terminal emulator (xterm.js,
// loaded by index.html as the globals Terminal, FitAddon and WebglAddon).
import { Machine } from "./machine.js";

const $ = (id) => document.getElementById(id);
const notesEl = $("notes");
const statusEl = $("status");
const params = new URLSearchParams(location.search);

// The file in the origin private file system that holds the user's
// changes to the file system (the kernel's /dev/vdb), and the marker that
// says it is complete (see device-worker.js).
const DATA_FILE = "data.img";
const DATA_READY = `${DATA_FILE}.ready`;
const SETTINGS = "linux-wasm-settings";
const AUTOBOOT_SECONDS = 3;

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

// Settings: defaults, overridden by what the boot menu saved, overridden
// by the page's URL (?mem=256&cmdline=...&proxy=ws://...&dns=...
// &autoboot=1), which is how a link or a test sets them.
function loadSettings() {
  const settings = {
    memory: 128,
    cmdline: "",
    autoboot: false,
    network: false,
    proxy: "",
    dns: "",
  };
  try {
    Object.assign(settings, JSON.parse(localStorage.getItem(SETTINGS) ?? "{}"));
  } catch {
    // Unreadable settings are no settings.
  }
  if (params.has("mem")) settings.memory = Number(params.get("mem"));
  if (params.has("cmdline")) settings.cmdline = params.get("cmdline");
  if (params.has("autoboot")) settings.autoboot = params.get("autoboot") !== "0";
  if (params.has("proxy")) {
    settings.proxy = params.get("proxy");
    settings.network = true;
  }
  if (params.has("dns")) settings.dns = params.get("dns");
  return settings;
}

// The disk image in the browser's storage, managed from the boot menu
// while no machine has it open.
const disk = {
  async directory() {
    return navigator.storage.getDirectory();
  },
  // Size in bytes, or null if there is no (complete) image.
  async size() {
    try {
      const root = await this.directory();
      await root.getFileHandle(DATA_READY);
      return (await (await root.getFileHandle(DATA_FILE)).getFile()).size;
    } catch {
      return null;
    }
  },
  async delete() {
    const root = await this.directory();
    for (const name of [DATA_READY, DATA_FILE])
      await root.removeEntry(name).catch((e) => {
        if (e.name !== "NotFoundError") throw e;
      });
  },
  async export() {
    const root = await this.directory();
    const file = await (await root.getFileHandle(DATA_FILE)).getFile();
    const link = document.createElement("a");
    link.href = URL.createObjectURL(file);
    link.download = "linux-wasm-data.img";
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 60000);
  },
  async import(file) {
    const root = await this.directory();
    await root.removeEntry(DATA_READY).catch(() => {});
    const handle = await root.getFileHandle(DATA_FILE, { create: true });
    const writable = await handle.createWritable();
    await file.stream().pipeTo(writable);
    await root.getFileHandle(DATA_READY, { create: true });
  },
};

// Show the boot menu; resolves with the settings to boot with.
function bootMenu(settings, build) {
  const form = $("boot-form");
  const fields = form.elements;
  fields.memory.value = settings.memory;
  fields.cmdline.value = settings.cmdline;
  fields.autoboot.checked = settings.autoboot;
  fields.network.checked = settings.network;
  fields.proxy.value = settings.proxy;
  fields.dns.value = settings.dns;

  const read = () => ({
    memory: Math.min(1024, Math.max(64, Number(fields.memory.value) || 128)),
    cmdline: fields.cmdline.value.trim(),
    autoboot: fields.autoboot.checked,
    network: fields.network.checked,
    proxy: fields.proxy.value.trim(),
    dns: fields.dns.value.trim(),
  });

  async function showDisk() {
    const size = await disk.size();
    const mib = (bytes) => `${Math.round(bytes / 2 ** 20)} MiB`;
    $("disk-status").textContent =
      size === null
        ? `No disk yet: an empty one (${mib(build.data_bytes)}) is created at boot.`
        : size === build.data_bytes
          ? `A disk of ${mib(size)} is stored here.`
          : `A disk of ${mib(size)} is stored here; this version of the page expects ${mib(build.data_bytes)}, so it will not be used as it is.`;
    $("disk-delete").disabled = $("disk-export").disabled = size === null;
  }
  const diskAction = (action) => async (...args) => {
    try {
      await action(...args);
    } catch (e) {
      hostNote(`disk: ${e}`, true);
    }
    await showDisk();
  };
  $("disk-delete").onclick = diskAction(async () => {
    if (confirm("Delete the disk with everything you changed on the system?"))
      await disk.delete();
  });
  $("disk-export").onclick = diskAction(() => disk.export());
  $("disk-import").onclick = () => $("disk-file").click();
  $("disk-file").onchange = diskAction(async () => {
    const [file] = $("disk-file").files;
    $("disk-file").value = "";
    if (!file) return;
    if (file.size !== build.data_bytes)
      throw new Error(`${file.name} is ${file.size} bytes, a disk is ${build.data_bytes}`);
    if (confirm(`Replace the stored disk with ${file.name}?`)) await disk.import(file);
  });
  showDisk();

  $("boot").hidden = false;
  setStatus("boot menu");
  $("boot-button").focus();

  return new Promise((resolve) => {
    let timer = null;
    const cancel = () => {
      clearInterval(timer);
      timer = null;
      $("countdown").textContent = "";
    };
    const boot = () => {
      cancel();
      const chosen = read();
      localStorage.setItem(SETTINGS, JSON.stringify(chosen));
      $("boot").hidden = true;
      resolve(chosen);
    };
    form.onsubmit = (event) => {
      event.preventDefault();
      boot();
    };
    if (settings.autoboot) {
      let left = AUTOBOOT_SECONDS;
      const tick = () => {
        if (left === 0) return boot();
        $("countdown").textContent = `booting in ${left--} s; any key or click stops it`;
      };
      tick();
      timer = setInterval(tick, 1000);
      for (const type of ["keydown", "pointerdown"])
        addEventListener(type, () => timer && cancel(), { once: true, capture: true });
    }
  });
}

function createTerminal() {
  $("terminal").hidden = false;
  const terminal = new Terminal({
    cursorBlink: true,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
    fontSize: 14,
    scrollback: 5000,
    theme: { background: "#111111", foreground: "#dddddd" },
  });
  const fit = new FitAddon.FitAddon();
  terminal.loadAddon(fit);
  terminal.open($("terminal"));
  try {
    // Draws on a canvas; without WebGL the DOM renderer stays in use.
    const webgl = new WebglAddon.WebglAddon();
    webgl.onContextLoss(() => webgl.dispose());
    terminal.loadAddon(webgl);
  } catch {
    // The DOM renderer it is.
  }
  fit.fit();
  new ResizeObserver(() => fit.fit()).observe($("terminal"));
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

function boot(module, build, settings) {
  const kernelCmdline = settings.cmdline;
  hostNote(
    `booting: ${settings.memory} MiB memory; cmdline "${kernelCmdline}"; ` +
      (settings.network
        ? settings.proxy
          ? `network through ${settings.proxy}`
          : "network card without a proxy"
        : "no network card"),
  );
  // Ask the browser not to evict the stored disk under storage pressure.
  navigator.storage?.persist?.().catch(() => {});

  const terminal = createTerminal();
  const machine = new Machine({
    module,
    memoryMiB: settings.memory,
    cmdline: kernelCmdline,
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
    network: settings.network
      ? { proxy: settings.proxy || undefined, dns: settings.dns || undefined }
      : undefined,
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
          hostNote(`device ${event.device}: ${event.text}`);
          break;
        case "device-error":
          hostNote(`device ${event.device} failed: ${event.message}`, true);
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

  // Back to the boot menu: the same as pulling the plug and switching on
  // again, so only when the machine has halted or the user insists.
  $("restart").hidden = false;
  $("restart").onclick = () => {
    if (
      !machine.halted &&
      !confirm("Stop the machine without shutting it down? (Type poweroff in it for a clean stop.)")
    )
      return;
    machine.stop();
    // This time the menu waits, whatever the settings say.
    const url = new URL(location.href);
    url.searchParams.set("autoboot", "0");
    location.replace(url);
  };

  // For poking at it from the devtools console.
  globalThis.machine = machine;
  globalThis.terminal = terminal;
  machine.boot();
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
  const kernelUrl = params.get("kernel") ?? "vmlinux.wasm";
  const [module, build] = await Promise.all([
    WebAssembly.compileStreaming(fetch(kernelUrl)),
    fetch("build.json").then((r) => r.json()),
  ]);
  hostNote(`loaded ${kernelUrl}`);

  boot(module, build, await bootMenu(loadSettings(), build));
}

main().catch((e) => {
  hostNote(`failed to start: ${e}`, true);
  setStatus("failed");
});
