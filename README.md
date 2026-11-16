# linux-wasm distro

Builds a bootable Linux-on-WebAssembly system out of its parts and is the
place for everything that is neither kernel nor libc: build orchestration,
BusyBox patches, the initramfs, and later the web front end.

**Live: https://linux-wasm.github.io/distro/** (the kernel booting in your
browser tab; rebuilt from `main` on every push).

**Status: only the kernel.** `scripts/build.sh` fetches the pinned kernel
commit, builds it and assembles the web page; `scripts/test.sh` boots the
kernel headless. The boot ends, as expected for now, in
`Kernel panic - not syncing: No working init found`.
There is no user space: musl, BusyBox and the initramfs are not implemented
(the scripts say so and fail if asked for them).

## Repositories

| Repository | Role | State |
|---|---|---|
| [linux-wasm/linux](https://github.com/linux-wasm/linux) | Kernel with `arch/wasm` | boots to "no init" |
| [linux-wasm/musl](https://github.com/linux-wasm/musl) | C library | port not started |
| linux-wasm/distro (this) | Puts it together | builds and boots the kernel |

BusyBox needs few changes, so it is planned as upstream release + patches
in `patches/busybox/` rather than a fork.

## Usage

Requirements: git, docker (or podman), node >= 20, python3.

```sh
scripts/build.sh      # fetch + build what exists today: kernel and web page
scripts/test.sh       # headless boot test
scripts/serve.sh      # http://127.0.0.1:8080/
```

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

Everything fetched or built goes to `work/` (ignored by git).

## Pinned versions

`sources.env` names the exact kernel commit, musl commit and BusyBox
release. Bumping one is its own commit, e.g.
`build(sources): bump kernel to <short sha>`.

## Working on the kernel and the distro together

Point the scripts at a kernel checkout instead of the pinned commit:

```sh
KERNEL_DIR=~/src/linux scripts/build.sh kernel
KERNEL_DIR=~/src/linux scripts/test.sh
```

A change that spans both repositories lands as two pull requests: first the
kernel one, then a distro one that bumps `KERNEL_COMMIT` (plus whatever the
distro needs to change).

## Roadmap

1. Kernel: user mode (syscall entry, wasm binfmt, user threads, tty),
   tested with a hand-written init that needs no libc.
2. musl against that ABI.
3. BusyBox and an initramfs here; boot test expects a shell prompt.
4. Web front end with a terminal and devices here. Today `site/` is only a
   log viewer around the kernel's reference host scripts.

## Conventions

- [Conventional Commits](https://www.conventionalcommits.org/) in English.
- Nothing is faked: a step that does not exist fails loudly instead of
  pretending.
