# linux-wasm distro

Builds a bootable Linux-on-WebAssembly system out of its parts and is the
place for everything that is neither kernel, libc nor a package: build
orchestration, the compiler driver, the root file system's own files and
the web front end.

**Live: https://linux-wasm.github.io/distro/** (the kernel booting in your
browser tab; rebuilt from `main` on every push).

**Status: boots to bash on a layered, persistent root file system, in a
real terminal, with GNU userland.** `scripts/build.sh` builds musl,
the packages of
[linux-wasm/ports](https://github.com/linux-wasm/ports) (BusyBox for init
and the small tools, bash, coreutils,
ncurses, grep, sed, gawk, findutils, diffutils, tar, gzip, make, less,
nano, openssl, curl, the openssh clients, rsync, drill) and a test program, packs them into a read-only base image, builds
the kernel and assembles the web page. At boot the base (`/dev/vda`,
erofs, loaded over HTTP and kept in memory) gets a writable layer on top
(`/dev/vdb`, ext4, stored by the browser in the origin private file
system) with overlayfs; BusyBox `init` then runs `/etc/inittab` and
starts bash as a login shell. The page starts with a boot menu (memory,
kernel command line, the stored disk, the network), then shows the
console in xterm.js and tells the kernel its size.

With a proxy ([linux-wasm/netproxy](https://github.com/linux-wasm/netproxy))
the system has a network: the kernel's own TCP/IP on a virtio network
card, whose connections the page hands to the proxy over a WebSocket.

What you add, change or delete is kept between visits; a newer base does
not replace it ("reset disk" on the page deletes it). The tab can be
closed at any time: changes reach the disk within about a second, and
ext4's journal copes with the cut.

`fork()` works: the shell runs subshells, pipelines and command
substitution in forked copies of itself, like on any Linux.

Not there: memory protection between programs, dynamic linking (every
program is linked statically), a package manager, connections into the
system from outside. A program that computes
without making system calls cannot be interrupted, and freezes the machine
while it runs. See the roadmap for what stands between this and a
distribution with systemd.

## Repositories

| Repository | Role | State |
|---|---|---|
| [linux-wasm/linux](https://github.com/linux-wasm/linux) | Kernel with `arch/wasm` | runs user programs: syscalls, clone, fork, vfork, execve, signals, virtio disks |
| [linux-wasm/musl](https://github.com/linux-wasm/musl) | C library | enough for BusyBox and `/bin/selftest`; no libc test suite run |
| [linux-wasm/ports](https://github.com/linux-wasm/ports) | Packages | 21 upstream packages, unpatched; exercised by this repository's boot test |
| [linux-wasm/netproxy](https://github.com/linux-wasm/netproxy) | WebSocket to TCP/UDP proxy | Wisp v1 server; used by the network test |
| linux-wasm/distro (this) | Puts it together | builds, boot-tests and publishes kernel + musl + packages |

## Usage

Requirements: git, docker (or podman), node >= 20.

```sh
scripts/build.sh      # toolchain image, musl, headers, user programs, packages, root file system, kernel, site
scripts/test.sh       # headless boot tests: the shell and every package, a second boot that finds the first one's changes, a third with a network
scripts/serve.mjs     # http://127.0.0.1:8080/
```

`scripts/build.sh <step>` runs one step (`toolchain`, `musl`, `headers`,
`user`, `ports`, `rootfs`, `kernel`, `site`). Everything fetched or
built goes to `work/` (ignored by git).

## Layout

| Path | Contents |
|---|---|
| `sources.env` | Pinned kernel, musl and ports commits, xterm.js packages |
| `scripts/` | `fetch.sh`, `build.sh`, `test.sh`, `serve.mjs`, and `wasm-cc`, the compiler driver for user programs |
| `kernel.config` | Kernel options enabled on top of the kernel's tinyconfig |
| `rootfs/` | Files copied into the base image as they are: `/etc`, and `/sbin/overlay-init`, which stacks the layers before init starts |
| `user/` | The distro's own programs: `selftest.c` (`/bin/selftest`) |
| `tests/` | What the tests type (`*-input.txt`) and expect (`*-expect.txt`): `boot`, then `persist` on the same disk, then `net` |
| `site/` | The web page: boot menu, terminal, disks and network card (`device-worker.js`), worker glue and the service worker |

## Building your own programs

`scripts/wasm-cc` behaves like `cc` for this system (it runs inside the
toolchain container): it compiles with the required flags and links
against musl. A single `.c` file dropped into `user/` is built and can be
installed in `/bin` of the base image.

## The web page

`site/` is the page (`index.html`, `boot.js`, `host.js`, `worker.js`,
`device-worker.js`, `sw.js`); `scripts/build.sh site` combines it with the
kernel's host scripts (`tools/wasm/host/` in the kernel tree: the part
shared with node), xterm.js, `vmlinux.wasm`, `base.erofs` and the empty
`data.img.gz` into `work/site/`, a plain static site.

The page opens on a boot menu. Its settings are kept in the browser
(localStorage) and can be given in the URL, which is how to link to a
configuration: `?mem=256&cmdline=...&proxy=ws://127.0.0.1:8765/&dns=1.1.1.1&autoboot=1`.
With "boot without asking" the menu waits three seconds for a key and
then boots. The disk with the user's changes can be deleted, saved as a
file and replaced from one there. "boot menu" in the header of the
running system stops the machine and returns to it.

## Networking

```sh
git clone https://github.com/linux-wasm/netproxy && cd netproxy && npm ci
node server.mjs --allow-origin http://127.0.0.1:8080    # ws://127.0.0.1:8765/
```

On the boot menu tick "Network card" and enter the proxy's URL. In the
system the interface is `eth0` (10.0.2.15, set up by `/sbin/network-up`),
the gateway 10.0.2.2 and the name server 10.0.2.3, whose queries go to
the server named on the menu (default 1.1.1.1). There are `curl` (with
OpenSSL and Mozilla's certificate authorities, so https is verified),
`ssh`, `scp`, `sftp`, `rsync`, `drill` (a `dig`), `openssl`, and from
BusyBox `wget`, `nc`, `ping` (the gateway only), `nslookup`, `telnet`;
bash has `/dev/tcp`. BusyBox `wget` does not verify certificates. A page served
over https (the public one) can only use a `wss://` proxy or one on
`127.0.0.1`. How it works and what it cannot do is in the kernel's
`tools/wasm/NOTES.md`; what running a proxy exposes is in netproxy's
README.

## The root file system

| Layer | Device | Contents | Where it lives |
|---|---|---|---|
| base | `/dev/vda`, erofs, read-only | everything the distro ships (`work/base.erofs`, 57 MiB) | fetched over HTTP compressed (17 MiB), held in memory unpacked |
| changes | `/dev/vdb`, ext4 | new and changed files, markers for deleted ones | a file in the browser's origin private file system, created from `data.img.gz` on the first visit; under node, the file given to `--disk` |

The kernel mounts the base as its root and runs `/sbin/overlay-init`
(`init=` on the built-in command line), which mounts the changes, joins
the two with overlayfs, makes the result the root and starts `/sbin/init`.
In the running system the base is at `/overlay/base` and the changes at
`/overlay/base/overlay/data/upper`. Both disks are virtio block devices
served by the host (`tools/wasm/host/` in the kernel tree).

The kernel needs SharedArrayBuffer, which browsers only give to
cross-origin isolated pages (`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`). `scripts/serve.mjs` sends
those headers. GitHub Pages cannot, so `site/sw.js`, a service worker, adds
them and `site/boot.js` reloads the page once after installing it.
`scripts/serve.mjs --plain` serves without the headers to test that path.

The CI workflow deploys `work/site/` to GitHub Pages from `main`.

## Pinned versions

`sources.env` names the exact kernel, musl and ports commits (the
versions of the packages are in the ports recipes). Bumping one is its own commit, e.g.
`build(sources): bump kernel to <short sha>`.

## Working on the kernel, musl and the distro together

Point the scripts at local checkouts instead of the pinned commits:

```sh
KERNEL_DIR=~/src/linux MUSL_DIR=~/src/musl PORTS_DIR=~/src/ports scripts/build.sh
KERNEL_DIR=~/src/linux scripts/test.sh
```

A change that spans both repositories lands as two pull requests: first the
kernel one, then a distro one that bumps `KERNEL_COMMIT` (plus whatever the
distro needs to change).

## Roadmap

Done so far: a kernel that runs user programs with fork, exec, threads,
signals and job control; musl; virtio disks with a read-only base and a
persistent layer for changes; a real terminal on the page; 21 packages
from linux-wasm/ports with bash as the shell.

What comes next, in order and with what each step is for, is in
[ROADMAP.md](ROADMAP.md). Its goal is an Xfce desktop on X11 in the
browser tab:

1. A kernel and libc that can be trusted (test suites), and time slices
   for programs that compute.
2. Shared libraries and `dlopen`, C++, meson and cmake in ports.
3. A package manager, and a base image fetched on demand.
4. Unix sockets, shared memory, a framebuffer on a canvas, keyboard and
   mouse.
5. An X server, the X libraries, xterm and twm.

Networking, which that plan had as optional, is done (see above).
6. GTK 3 and what it stands on.
7. D-Bus and Xfce.

## Conventions

- [Conventional Commits](https://www.conventionalcommits.org/) in English.
- Nothing is faked: a step that does not exist fails loudly instead of
  pretending.

## License

The files in this repository (scripts, the web page, CI) are MIT licensed,
see [LICENSE](LICENSE). That does not extend to what they build: the kernel
and most packages are GPL, musl is MIT. A built image is therefore subject
to the GPL.
