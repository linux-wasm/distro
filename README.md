# linux-wasm distro

Builds a bootable Linux-on-WebAssembly system out of its parts and is the
place for everything that is neither kernel nor libc: build orchestration,
BusyBox patches, the initramfs, and later the web front end.

**Live: https://linux-wasm.github.io/distro/** (the kernel booting in your
browser tab; rebuilt from `main` on every push).

**Status: boots to a BusyBox shell.** `scripts/build.sh` builds musl,
BusyBox (unpatched 1.38.0, NOMMU configuration with the hush shell) and a
test program, packs them into an initramfs, builds the kernel around it
and assembles the web page. BusyBox `init` runs `/etc/inittab` and starts
an interactive shell with pipes, loops, command substitution and the
applets listed in `busybox/config`.

Not there: Ctrl-C and job control (the kernel does not run signal handlers
yet), networking, persistent storage, and anything beyond that applet list.

## Repositories

| Repository | Role | State |
|---|---|---|
| [linux-wasm/linux](https://github.com/linux-wasm/linux) | Kernel with `arch/wasm` | runs user programs: syscalls, clone, vfork, execve, console input |
| [linux-wasm/musl](https://github.com/linux-wasm/musl) | C library | enough for BusyBox and `/bin/selftest`; no libc test suite run |
| linux-wasm/distro (this) | Puts it together | builds, boot-tests and publishes kernel + musl + BusyBox |

BusyBox is the upstream release; it has needed no patches so far
(`patches/busybox/` is where they would go).

## Usage

Requirements: git, docker (or podman), node >= 20.

```sh
scripts/build.sh      # toolchain image, musl, headers, user programs, BusyBox, initramfs, kernel, site
scripts/test.sh       # headless boot test: types shell commands, checks the output
scripts/serve.mjs     # http://127.0.0.1:8080/
```

`scripts/build.sh <step>` runs one step (`toolchain`, `musl`, `headers`,
`user`, `busybox`, `initramfs`, `kernel`, `site`). Everything fetched or
built goes to `work/` (ignored by git).

## Layout

| Path | Contents |
|---|---|
| `sources.env` | Pinned kernel and musl commits, BusyBox release |
| `scripts/` | `fetch.sh`, `build.sh`, `test.sh`, `serve.mjs`, and `wasm-cc`, the compiler driver for user programs |
| `busybox/config` | BusyBox options enabled on top of allnoconfig |
| `kernel.config` | Kernel options enabled on top of the kernel's tinyconfig |
| `user/` | The distro's own files: `inittab`, `motd`, and `selftest.c` (`/bin/selftest`) |
| `tests/` | What the boot test types (`boot-input.txt`) and expects (`boot-expect.txt`) |
| `site/` | The web page: console, keyboard, worker glue and the service worker |
| `patches/` | Patches for upstream projects that have no fork here |

## Building your own programs

`scripts/wasm-cc` behaves like `cc` for this system (it runs inside the
toolchain container): it compiles with the required flags and links
against musl. A single `.c` file dropped into `user/` is built and can be
added to the initramfs list in `scripts/build.sh`.

## The web page

`site/` is the page (`index.html`, `boot.js`, `host.js`, `worker.js`,
`sw.js`); `scripts/build.sh site` combines it with the kernel's host
scripts (`tools/wasm/host/` in the kernel tree: the part shared with node) and
`vmlinux.wasm` into `work/site/`, a plain static site.

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
   execve, console input and output.
2. musl. Done: enough for BusyBox; `/bin/selftest` covers setjmp, files,
   pipes, malloc, time, threads and vfork. Open: no libc test suite run.
3. BusyBox. Done: init, hush and a basic applet set, unpatched.
4. Kernel: signal handlers (Ctrl-C, job control).
5. A real terminal on the page (escape sequences, line editing with arrow
   keys); today `site/` is a plain text console.
6. An initramfs handed over by the host instead of built into the kernel,
   more applets, storage, networking.

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
