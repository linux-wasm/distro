// Browser glue: a Web Worker that runs one virtio device (device.js, from
// the kernel tree). A network card needs nothing opened: its backend is
// the options of the user-mode network. For a disk it opens what backs it:
//
//   { kind: "http", url }
//       The gzip-compressed image is downloaded once and kept in memory,
//       unpacked; read-only.
//   { kind: "opfs", name, bytes, initialUrl }
//       A file in the origin private file system, which the browser keeps
//       between visits. If it does not exist yet it is created from the
//       gzip-compressed image at initialUrl. Where the browser offers no
//       such storage, the image is kept in memory and what is written to
//       it is lost when the page goes away.
import { runDevice } from "./device.js";

const note = (text) => self.postMessage({ type: "device-note", text });

function memoryDisk(data, writable) {
  return {
    read(view, position) {
      const part = data.subarray(position, position + view.length);
      view.set(part);
      return part.length;
    },
    write(view, position) {
      if (!writable) throw new Error("read-only disk");
      data.set(view, position);
    },
    flush() {},
  };
}

const isZero = (chunk) => {
  // Whole words where the alignment allows it: images are mostly zeros.
  let i = 0;
  if (chunk.byteOffset % 4 === 0) {
    const words = new Uint32Array(chunk.buffer, chunk.byteOffset, chunk.length >> 2);
    for (let w = 0; w < words.length; w++) if (words[w]) return false;
    i = words.length << 2;
  }
  for (; i < chunk.length; i++) if (chunk[i]) return false;
  return true;
};

async function gunzip(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.body.pipeThrough(new DecompressionStream("gzip"));
}

async function openOpfs({ name, bytes, initialUrl }) {
  const root = await navigator.storage.getDirectory();
  // The marker is written after the image: a file without it is the rest
  // of an interrupted first visit.
  const marker = `${name}.ready`;
  let fresh = false;
  try {
    await root.getFileHandle(marker);
  } catch {
    fresh = true;
  }
  const file = await root.getFileHandle(name, { create: true });
  const handle = await file.createSyncAccessHandle();
  if (fresh) {
    note(`creating ${name} (${bytes >> 20} MiB) in the browser's storage`);
    handle.truncate(0);
    let position = 0;
    for await (const chunk of await gunzip(initialUrl)) {
      // Runs of zeros are left out; the file reads as zeros there.
      if (!isZero(chunk)) handle.write(chunk, { at: position });
      position += chunk.length;
    }
    handle.truncate(bytes);
    handle.flush();
    await root.getFileHandle(marker, { create: true });
  }
  return {
    read: (view, position) => handle.read(view, { at: position }),
    write: (view, position) => handle.write(view, { at: position }),
    flush: () => handle.flush(),
  };
}

async function open(backend) {
  // A network card: the options, plus where its reports go.
  if (backend.kind === undefined) return { ...backend, onstatus: note };
  switch (backend.kind) {
    case "http": {
      const image = new Response(await gunzip(backend.url));
      return memoryDisk(new Uint8Array(await image.arrayBuffer()), false);
    }
    case "opfs":
      try {
        return await openOpfs(backend);
      } catch (e) {
        note(`no persistent storage for ${backend.name} (${e}); changes will be lost`);
        const data = new Uint8Array(backend.bytes);
        let position = 0;
        for await (const chunk of await gunzip(backend.initialUrl)) {
          data.set(chunk, position);
          position += chunk.length;
        }
        return memoryDisk(data, true);
      }
  }
  throw new Error(`unknown disk backend ${backend.kind}`);
}

self.onmessage = async (e) => {
  try {
    await runDevice(e.data, await open(e.data.backend));
  } catch (err) {
    self.postMessage({ type: "device-error", message: String(err) });
  }
};
