# linux-wasm distro

Builds a bootable Linux-on-WebAssembly system out of its parts and is the
place for everything that is neither kernel nor libc: build orchestration,
BusyBox patches, the initramfs, and later the web front end.

**Live: https://linux-wasm.github.io/distro/** (the kernel booting in your
browser tab; rebuilt from `main` on every push).

**Status: boots to a BusyBox shell on a layered, persistent root file
system, in a real terminal.** `scripts/build.sh` builds musl, BusyBox
(unpatched 1.38.0, with the ash shell) and a test
program, packs them into a read-only base image, builds the kernel and
assembles the web page. At boot the base (`/dev/vda`, erofs, loaded over
HTTP and kept in memory) gets a writable layer on top (`/dev/vdb`, ext4,
stored by the browser in the origin private file system) with overlayfs;
BusyBox `init` then runs `/etc/inittab` and starts an interactive shell
with pipes, loops, command substitution, Ctrl-C, job control and the
applets listed in `busybox/config` (including `vi`, `less`, `top`).
The page shows the console in xterm.js and tells the kernel its size.

What you add, change or delete is kept between visits; a newer base does
not replace it ("reset disk" on the page deletes it). The tab can be
closed at any time: changes reach the disk within about a second, and
ext4's journal copes with the cut.

`fork()` works: ash runs subshells, pipelines and command substitution in
forked copies of itself, like on any Linux.

Not there: memory protection between programs, dynamic linking,
networking, and anything beyond that applet list. A program that computes
without making system calls cannot be interrupted, and freezes the machine
while it runs. See the roadmap for what stands between this and a
distribution with systemd.

## Repositories

| Repository | Role | State |
|---|---|---|
| [linux-wasm/linux](https://github.com/linux-wasm/linux) | Kernel with `arch/wasm` | runs user programs: syscalls, clone, fork, vfork, execve, signals, virtio disks |
| [linux-wasm/musl](https://github.com/linux-wasm/musl) | C library | enough for BusyBox and `/bin/selftest`; no libc test suite run |
| linux-wasm/distro (this) | Puts it together | builds, boot-tests and publishes kernel + musl + BusyBox |

BusyBox is the upstream release; it has needed no patches so far
(`patches/busybox/` is where they would go).

## Usage

Requirements: git, docker (or podman), node >= 20.

```sh
scripts/build.sh      # toolchain image, musl, headers, user programs, BusyBox, root file system, kernel, site
scripts/test.sh       # headless boot tests: shell commands, Ctrl-C/Ctrl-Z, and a second boot that finds the first one's changes
scripts/serve.mjs     # http://127.0.0.1:8080/
```

`scripts/build.sh <step>` runs one step (`toolchain`, `musl`, `headers`,
`user`, `busybox`, `rootfs`, `kernel`, `site`). Everything fetched or
built goes to `work/` (ignored by git).

## Layout

| Path | Contents |
|---|---|
| `sources.env` | Pinned kernel and musl commits, BusyBox release, xterm.js packages |
| `scripts/` | `fetch.sh`, `build.sh`, `test.sh`, `serve.mjs`, and `wasm-cc`, the compiler driver for user programs |
| `busybox/config` | BusyBox options enabled on top of allnoconfig |
| `kernel.config` | Kernel options enabled on top of the kernel's tinyconfig |
| `rootfs/` | Files copied into the base image as they are: `/etc`, and `/sbin/overlay-init`, which stacks the layers before init starts |
| `user/` | The distro's own programs: `selftest.c` (`/bin/selftest`) |
| `tests/` | What the tests type (`*-input.txt`) and expect (`*-expect.txt`): `boot`, then `persist` on the same disk |
| `site/` | The web page: terminal, disks (`device-worker.js`), worker glue and the service worker |
| `patches/` | Patches for upstream projects that have no fork here |

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

## The root file system

| Layer | Device | Contents | Where it lives |
|---|---|---|---|
| base | `/dev/vda`, erofs, read-only | everything the distro ships (`work/base.erofs`) | fetched over HTTP, held in memory |
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

`sources.env` names the exact kernel commit, musl commit and BusyBox
release. Bumping one is its own commit, e.g.
`build(sources): bump kernel to <short sha>`.

## Working on the kernel, musl and the distro together

Point the scripts at local checkouts instead of the pinned commits:

```sh
KERNEL_DIR=~/src/linux MUSL_DIR=~/src/musl scripts/build.sh
KERNEL_DIR=~/src/linux scripts/test.sh
```

A change that spans both repositories lands as two pull requests: first the
kernel one, then a distro one that bumps `KERNEL_COMMIT` (plus whatever the
distro needs to change).

## Roadmap

1. Kernel: user mode. Done: system calls, wasm binfmt, clone, vfork,
   execve, signal handlers, console input and output.
2. musl. Done: enough for BusyBox; `/bin/selftest` covers setjmp, files,
   pipes, malloc, time, threads, vfork and signals. Open: no libc test
   suite run.
3. BusyBox. Done: init, ash with job control and the usual applets,
   unpatched.
4. Kernel: signal handlers. Done: Ctrl-C and job control work. Open: a
   program that makes no system calls cannot be signalled.
5. A real terminal on the page. Done: xterm.js, window size.
6. Storage. Done: virtio disks, a read-only base with a persistent layer
   for changes. Open: the base is downloaded whole; fetching it block by
   block on demand (HTTP ranges, cached) is what a large distribution
   needs.
7. A process model that ordinary software can live with. This is the
   step everything below depends on, and it is a change of the kernel's
   design, not of its configuration:
   - `fork()`. Done: programs are instrumented with Binaryen's Asyncify
     (`scripts/wasm-cc`) so that they can save and rebuild their call
     stack, and the kernel keeps a copy of the memory per process, which
     it exchanges when switching between related processes. Open: that
     exchange costs a copy of the shared memory per switch; a memory of
     its own per process would remove it and give protection.
   - Interrupting a program that computes (signals, time slices):
     compiler-inserted polling in user programs.
   - Shared libraries and `dlopen`, `mmap` of files.
8. A package repository: a new repository of build recipes (ncurses,
   bash, coreutils, util-linux, ... as wasm packages), a package manager,
   and a base image made of packages instead of one BusyBox.
9. systemd. Besides 7 it needs cgroups, unix sockets, netlink and more
   of the kernel configuration; the event interfaces (epoll, signalfd,
   timerfd, inotify) are enabled already. systemd supports musl since
   v259.
10. Networking (a virtio network device tunnelled over WebSocket or
    WebTransport).

## Conventions

- [Conventional Commits](https://www.conventionalcommits.org/) in English.
- Nothing is faked: a step that does not exist fails loudly instead of
  pretending.

## License

The files in this repository (scripts, the web page, CI) are MIT licensed,
see [LICENSE](LICENSE). That does not extend to what they build: the kernel
and BusyBox are GPL-2.0, musl is MIT, and a patch in `patches/` carries the
license of the project it applies to. A built image is therefore subject to
the GPL.
