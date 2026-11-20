#!/usr/bin/env node
// What the network test (scripts/test.sh) talks to, all on 127.0.0.1 and
// on ports the system picks:
//
//   - the proxy from linux-wasm/netproxy, allowing private addresses
//   - an HTTP server with a small and a large document
//   - a name server that answers every A question with 10.0.2.2, the
//     address under which the system reaches this machine
//
//   net-test-servers.mjs <netproxy directory>
//
// Prints "PROXY=<port> HTTP=<port> DNS=<port>" and stays until killed.
import dgram from "node:dgram";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

const { startProxy } = await import(pathToFileURL(`${process.argv[2]}/server.mjs`));
const listening = (server) => new Promise((r) => server.once("listening", r));

const proxy = startProxy({ port: 0, allowPrivate: true });

// 300000 bytes that the test can check: "0123456789" repeated.
const large = "0123456789".repeat(30000);
const http = createServer((request, response) => {
  response.writeHead(200, { "Content-Type": "text/plain" });
  response.end(request.url === "/large" ? large : `host says ${request.url}\n`);
}).listen(0, "127.0.0.1");

const dns = dgram.createSocket("udp4");
dns.on("message", (query, from) => {
  // The header and the question (the name ends at the first zero byte,
  // then type and class), without whatever else the query carried.
  const end = query.indexOf(0, 12) + 5;
  const reply = Buffer.from(query.subarray(0, end));
  reply[2] = 0x81; // a response; recursion desired
  reply[3] = 0x80; // recursion available
  reply.writeUInt16BE(0, 8);
  reply.writeUInt16BE(0, 10);
  const isA = query.readUInt16BE(end - 4) === 1;
  reply.writeUInt16BE(isA ? 1 : 0, 6);
  // One A record for the name in the question.
  const record = Buffer.from([0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 0, 2, 2]);
  dns.send(isA ? Buffer.concat([reply, record]) : reply, from.port, from.address);
});
dns.bind(0, "127.0.0.1");

await Promise.all([listening(proxy), listening(http), listening(dns)]);
console.log(`PROXY=${proxy.address().port} HTTP=${http.address().port} DNS=${dns.address().port}`);
