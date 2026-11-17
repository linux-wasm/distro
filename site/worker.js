// Browser glue: a Web Worker that runs one kernel thread.
import { runThread } from "./thread.js";

self.onmessage = (e) => runThread(e.data, (msg) => self.postMessage(msg));
