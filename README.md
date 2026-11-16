# linux-wasm distro

Builds a bootable Linux-on-WebAssembly system out of its parts and is the
place for everything that is neither kernel nor libc: build orchestration,
BusyBox patches, the initramfs, and later the web front end.

**Live: https://linux-wasm.github.io/distro/** (the kernel booting in your
browser tab; rebuilt from `main` on every push).

**Status: kernel + musl + a demo init.** `scripts/build.sh` builds musl,
a small C program linked against it (`user/init.c`), packs it into an
initramfs, builds the kernel around it and assembles the web page. The
init is a command loop, not a shell: `help`, `uname`, `echo`, `ls`, `cat`,
`run PROG` (posix_spawn + waitpid) and `poweroff`. BusyBox is not there yet
(the script says so and fails if asked for it).

## Repositories

| Repository | Role | State |
|---|---|---|
| [linux-wasm/linux](https://github.com/linux-wasm/linux) | Kernel with `arch/wasm` | runs test programs in user mode: syscalls, clone, execve, console input |
| [linux-wasm/musl](https://github.com/linux-wasm/musl) | C library | builds; printf, malloc, files, posix_spawn work in the demo init; otherwise untested |
| linux-wasm/distro (this) | Puts it together | builds, boot-tests and publishes kernel + musl + demo init |

BusyBox needs few changes, so it is planned as upstream release + patches
in `patches/busybox/` rather than a fork.

## Usage

Requirements: git, docker (or podman), node >= 20, python3.

```sh
scripts/build.sh      # toolchain image, musl, user programs, initramfs, kernel, site
scripts/test.sh       # headless boot test: types commands, checks the output
scripts/serve.sh      # http://127.0.0.1:8080/
```

`scripts/build.sh <step>` runs one step (`toolchain`, `musl`, `user`,
`initramfs`, `kernel`, `site`). Everything fetched or built goes to `work/`
(ignored by git).

## Layout

| Path | Contents |
|---|---|
| `sources.env` | Pinned kernel and musl commits, BusyBox release |
| `scripts/` | `fetch.sh`, `build.sh`, `test.sh`, `serve.sh` |
| `user/` | The distro's own programs and files: `init.c`, `selftest.c` (`/bin/selftest`), `motd` |
| `tests/` | What the boot test types (`boot-input.txt`) and expects (`boot-expect.txt`) |
| `site/` | The web page and the service worker |
| `patches/` | Patches for upstream projects that have no fork here (BusyBox) |

## The web page

`site/` is the page; `scripts/build.sh site` combines it with the kernel's
reference host scripts (`tools/wasm/host/` in the kernel tree) and
`vmlinux.wasm` into `work/site/`, a plain static site.

The kernel needs SharedArrayBuffer, which browsers only give to
cross-origin isolated pages (`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`). `scripts/serve.sh` sends
those headers. GitHub Pages cannot, so `site/sw.js`, a service worker, adds
them and `site/boot.js` reloads the page once after installing it.
`scripts/serve.sh --plain` serves without the headers to test that path.

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

1. Kernel: user mode. Done: system calls, wasm binfmt, clone with an entry
   function, execve, console input and output.
2. musl. Done: builds, runs the demo init; `/bin/selftest` covers setjmp,
   files, pipes, malloc, time and threads. Open: no libc test suite run.
3. Kernel: signal handlers (Ctrl-C, job control).
4. BusyBox. Its shell and init call `vfork()`, which cannot exist here
   (a child cannot resume in its parent's wasm call stack); they need
   patches to use `posix_spawn`, or a libc `vfork` built on setjmp.
5. Web front end with a real terminal. Today `site/` is a log viewer with
   keyboard input around the kernel's reference host scripts.

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
