# Roadmap: to an Xfce desktop on X11

The goal this file plans for: `startxfce4` in a browser tab. The X server,
the window manager, the panel, a file manager and a terminal, all compiled
to WebAssembly and running on the linux-wasm kernel, drawing into a canvas
on the page. No emulated CPU and no X server written in JavaScript.

It is ordered by dependency. Every stage ends in something that can be
seen and tested, and each one is useful without the ones after it. Sizes
are relative (S: days, M: weeks, L: a month or more of the kind of work
done so far); none of them is a promise.

## Where we are

| Have | State |
|---|---|
| Kernel 7.3 on wasm32, one CPU, no MMU | boots in Chromium and node; virtio disks; ptys, epoll, signalfd, timerfd, inotify enabled, of which only ptys' device node has been looked at |
| Processes | `fork` (Asyncify + per-process copies of memory), `vfork`, `exec`, threads, signals, job control |
| musl | static only; enough for the 14 packages; no test suite run |
| Packages | BusyBox, bash, coreutils, ncurses, grep, sed, gawk, findutils, diffutils, tar, gzip, make, less, nano; all static, C only, autotools only |
| Network | the kernel's TCP/IP on a virtio network card, through a WebSocket proxy (linux-wasm/netproxy); outgoing TCP and UDP only |
| Page | boot menu; xterm.js terminal; base image over HTTP into memory; changes in the origin private file system |

What an Xfce desktop needs and none of this provides:

| Need | Why | Stage |
|---|---|---|
| Confidence in the kernel and libc | a desktop makes thousands of different system calls; the tests so far make dozens | 1 |
| Time slices | X server, window manager and clients must take turns; today a program that computes owns the machine | 1 |
| Shared libraries and `dlopen` | GTK, its modules and panel plugins; a static Xfce would be gigabytes | 2 |
| C++, meson, cmake, pkg-config | harfbuzz, vte; most of the stack no longer uses autotools | 2 |
| A base image that is not downloaded whole | the desktop is hundreds of megabytes of files | 3 |
| Unix sockets, shared memory | the X protocol, D-Bus, MIT-SHM | 4 |
| A screen, a keyboard and a mouse | there is only a serial console | 4 |
| An X server | | 5 |
| GTK 3 and what it stands on | | 6 |
| D-Bus and Xfce itself | | 7 |

## Stage 1: a kernel and libc that can be trusted, and that share time

Everything later multiplies the amount of kernel and libc that gets
exercised. Bugs found from inside a GTK program are expensive; the same
bugs found by a test suite are cheap. There is no memory protection, so
one stray pointer in any program can take the machine down: the fewer
unknowns below, the better.

- **Test suites** (M). Run musl's `libc-test` and a subset of LTP's
  system call tests as packages in ports; record what fails in the
  kernel's `NOTES.md` and musl's `README.md`, fix what a desktop needs.
  Run the test suites of the packages already ported (bash, coreutils).
- **Time slices and signals for programs that compute** (L). Running
  wasm code cannot be interrupted from outside. `wasm-cc` adds a pass
  after linking that puts a check of a flag in shared memory at loop
  back-edges and function entries; when the kernel has set the flag
  (timer tick, pending signal) the program calls into the kernel, which
  can then schedule or deliver. Kernel: set the flag from the timer, drop
  `ARCH_NO_PREEMPT`-style assumptions where they hide starvation. This
  also fixes "a busy program cannot be killed". Cost: a load and a branch
  per loop iteration; measure it.
- **A stack that fits real programs** (S). The user stack is a fixed
  256 KiB without a guard, and overflowing it silently overwrites
  whatever is below. Make the size a property of the program (or
  `RLIMIT_STACK`), default 8 MiB for the main thread, and have `wasm-cc`
  build with stack overflow checks (`--stack-first` layout or explicit
  checks) so that an overflow traps.
- **More memory** (S-M). The machine has 128 MiB and the kernel is
  linked for at most 1 GiB. Raise the limit to 4 GiB, let the page pick
  the size, and add memory on demand (`memory.grow` as memory hotplug)
  so that a shell does not reserve what a desktop needs. Watch
  fragmentation: without an MMU every mapping is one contiguous block.
- **Compiled programs are cached** (S). Every `exec` compiles the
  program again (20 ms for coreutils, it will be seconds for GTK). The
  host keeps compiled modules keyed by file identity (device, inode,
  mtime passed with `user_exec`) and shares them between processes.
- **fork with threads, `MAP_SHARED` across fork** (S). Not tried yet;
  GLib programs have threads when they fork.

Done when: libc-test and the chosen LTP subset pass or every failure is
listed with a reason; two busy loops and an interactive shell share the
machine; `kill -9` ends a busy loop.

## Stage 2: shared libraries, C++, and the build systems of today

- **Shared libraries and `dlopen`** (L). The largest piece of design
  left. Programs already are position-independent modules with a
  `dylink.0` section; a library is the same thing loaded at another
  base. What is missing:
  - a loader. Instantiating a wasm module is something only the host can
    do, so `ld.so` cannot be an ordinary program: the kernel maps the
    file and the host instantiates it into the process's memory and
    function table, resolving imports against the modules loaded before
    (wasm-ld's `GOT.mem`/`GOT.func` convention, as Emscripten's dynamic
    linking uses). musl's `dlopen`/`dlsym` call into that.
  - fork: the child's thread has to instantiate the same modules at the
    same bases, with the same table layout, before it rewinds; libraries
    are run through Asyncify like programs.
  - threads: every thread's instance needs every library, including
    those loaded after the thread started.
  - `wasm-cc -shared`, `-fPIC` libraries, sonames, `ldconfig`-less
    search in `/usr/lib`.
  - TLS in libraries (`__tls_base` per instance and module).
- **libffi** (S-M). GLib's signal marshalling calls functions whose
  signature is only known at run time. wasm cannot do that from inside
  (`call_indirect` is statically typed); the host can, through the
  function table. Add a host call for it and a libffi backend that uses
  it. Closures (new functions at run time) can wait: GTK and Xfce do not
  need them.
- **C++** (M). libc++, libc++abi and libunwind built for this target
  with wasm exceptions, as a package; `wasm-c++` next to `wasm-cc`.
  Check that exceptions and Asyncify coexist in the same function the
  way setjmp does.
- **ports: meson, cmake, pkg-config** (M). A cross file for meson, a
  toolchain file for cmake, a `pkg-config` that looks only in the stage;
  native build tools where a package runs its own programs during the
  build (glib-compile-schemas, gdk-pixbuf-query-loaders, xcb's python
  generators). Dependencies between recipes instead of the `ALL` list.
- **mmap of files** (M). Without an MMU a private file mapping is a copy
  of the file and a shared one only works on ramfs. Libraries, fonts and
  icon caches are mapped by every process that uses them. Decide between
  living with copies (memory), mapping read-only files directly out of
  the page cache where the file is contiguous there, or the item under
  "Decision" below.

Done when: bash runs linked against a shared ncurses and readline; a
program `dlopen`s a plugin and forks afterwards; a C++ program throws and
catches; a meson package (pixman is a good first one) builds.

## Stage 3: a distribution instead of an image

- **A package manager** (M). Packages are already archives with a name
  and a version. Add metadata (dependencies, file list, checksums), a
  repository index served as static files, and a small tool on the
  system that installs into the writable layer over HTTP. Whether that
  tool is apk-tools, opkg, dpkg or new is open; what matters is that the
  format is one that existing tools can produce.
- **The base image on demand** (M). The base is fetched whole into
  memory, which is fine for 15 MB and not for a desktop. The virtio disk
  of the base reads blocks with HTTP range requests when they are first
  used and keeps them in the browser's cache storage; erofs keeps related
  data together, which suits this.
- **util-linux, procps, shadow, eudev-less `/dev`** (M). `mount`,
  `login`, `ps`, `top`, users and groups from real packages; BusyBox
  shrinks to init and rescue.
- **Networking**. Done: a virtio network card and a user-mode network
  in the host that hands connections to a Wisp proxy. Open: a curl and
  CA certificates as packages (BusyBox wget does not verify
  certificates), `fetch` as a way to do HTTP without a proxy, and the
  gaps listed in the kernel's notes (no half-close, nothing inbound).

Done when: `pkg install nano` on a base image without nano works in the
browser, and a second visit starts without downloading the base again.

## Stage 4: sockets, shared memory, a screen and input devices

Kernel configuration and drivers, and the first pixels.

- **Unix sockets** (S). `CONFIG_UNIX` came in with networking and
  linked without trouble, but nothing has used it: X clients and D-Bus
  talk over unix sockets and pass file descriptors (`SCM_RIGHTS`). Test
  it (socketpair, a listening socket in `/tmp`, fd passing).
- **Shared memory** (S). `memfd_create`, `/dev/shm`, System V shm
  (`CONFIG_SYSVIPC`) for MIT-SHM. In one address space sharing is the
  easy case; the work is making the nommu `MAP_SHARED` rules accept it.
- **A framebuffer** (M). A kernel driver for a frame buffer in the
  kernel's memory, `/dev/fb0`. The host needs no copy protocol: the
  pixels are in the shared memory it already has, and the page draws
  them into a `<canvas>` once per animation frame. Size and depth come
  from the host (the canvas); a resize is a mode change. A virtio-gpu
  device would be the "proper" device and brings all of DRM with it;
  fbdev is enough for an X server without acceleration.
- **Keyboard and mouse** (M). `CONFIG_INPUT` with evdev, and a
  virtio-input device (or a small driver of the same shape) that the
  page feeds with key codes, pointer motion, buttons and wheel. Pointer
  lock for relative motion; absolute coordinates otherwise.
- **The page** (S-M). A canvas next to the terminal, focus handling
  between the two, full screen. The serial console stays: it is how the
  system is debugged.

Done when: a test program in `user/` fills `/dev/fb0` and follows the
mouse with a cursor it draws itself; two programs exchange a file
descriptor over a socketpair.

## Stage 5: X11

- **The X server** (L). Not Xorg: it loads its drivers as modules, wants
  udev and a seat, and most of its size is support for hardware that does
  not exist here. A kdrive-style server ("Xfbdev": fbdev for output,
  evdev for input) is the right size. Upstream xorg-server no longer
  carries that code, so the choice is between a maintained TinyX
  fork and a new, small DDX for current xorg-server modelled on Xvfb
  (which is what Xvfb plus "copy to `/dev/fb0`" amounts to). Rendering
  is pixman in software; no GLX, no DRI.
- **Client libraries** (M). xorgproto, xtrans, libXau, libXdmcp, libxcb,
  libX11, libXext, libXrender, libXfixes, libXi, libXrandr, libXcursor,
  libXdamage, libXcomposite, libXinerama, libxkbfile, libxkbcommon.
- **What a server needs around it** (M). xkbcomp and xkeyboard-config
  (the server runs xkbcomp at start: fork and exec, which work), fonts
  (libfontenc, libXfont2, a cursor font, DejaVu), xauth, xinit.
- **First clients** (S). xterm (needs libXt, libXaw, libXmu, libXpm) and
  twm: the classic proof that an X server works.

Done when: `xinit` in the browser shows twm with an xterm in it, typing
and dragging windows work, and it survives the Ctrl-C of its launcher.

## Stage 6: GTK 3

In build order; all of it shared libraries.

- zlib, libpng, libjpeg-turbo, expat, pcre2, libffi (stage 2)
- freetype, fontconfig, pixman, cairo, fribidi, harfbuzz (C++), pango
- glib (with `posix_spawn` instead of fork where it offers the choice,
  libmount disabled), gdk-pixbuf (loaders built in), shared-mime-info
- at-spi2-core (accessibility bus can be disabled at run time), libepoxy
  (GTK requires it; with no libGL present GTK draws with cairo)
- gtk+ 3.24, hicolor-icon-theme, adwaita-icon-theme

Xfce 4.20 uses GTK 3. GTK 4 is built around GPU rendering, for which
there would only be a software Mesa (softpipe; llvmpipe needs a JIT); it
is not on this path.

Done when: `gtk3-demo` runs under twm and its widgets redraw at a speed
one can work with. This is the point to measure before going on: start-up
time of a GTK program, memory per process, cost of Asyncify on the
libraries.

## Stage 7: D-Bus and Xfce

- **dbus** (M). The session bus: unix sockets, credential passing,
  service activation by fork and exec. No system bus, no polkit, no
  logind: Xfce runs without them.
- **Xfce core** (L): libxfce4util, xfconf, libxfce4ui, exo, garcon,
  libxfce4windowing, libwnck, startup-notification; then xfwm4 (the
  compositor off: no acceleration), xfce4-panel (its plugins are
  `dlopen`ed modules), xfdesktop, xfce4-session, xfce4-settings,
  xfce4-appfinder.
- **Applications** (M-L): thunar; xfce4-terminal, which needs vte (C++20,
  ptys: the first real use of `/dev/pts` here); mousepad.
- **Distro** (S): a session for the page (`startxfce4` on a button or a
  kernel command line option), a default configuration that fits a
  canvas, fonts.

Done when: the page boots to the Xfce desktop; the panel's menu starts
thunar and xfce4-terminal; a file saved from mousepad is there after
reloading the page.

## After that

- Clipboard between the page and X, resize of the canvas through RandR,
  HiDPI.
- Sound: a virtio sound device to WebAudio.
- A browser inside the browser is the usual next request; it needs
  everything above plus a JIT-less JavaScript engine and far more memory.
- systemd is not on the path to Xfce. It needs cgroups, netlink and
  namespaces on top of stage 4's sockets; it becomes a sensible project
  once stage 3 has made this a distribution.

## Decision: one memory or one per process

Today every process lives in the kernel's linear memory. That made the
port small and has costs that grow with the software:

| Cost | Hurts from |
|---|---|
| No protection: any program can overwrite any other and the kernel | stage 1 on (debugging), badly from stage 6 |
| All processes together are limited to 4 GiB, each mapping contiguous | stage 6 |
| fork relatives exchange their memory at every switch | whenever a large program forks without exec |
| File mappings are copies | stage 6 (libraries, fonts, icon caches) |

The alternative is a WebAssembly memory per process, with the kernel
reaching user memory through the host. It removes all four and is a
rewrite of the kernel's memory side (an MMU-less kernel assumes user
pointers are its own), of the binfmt and of parts of the host; tombl/linux
shows it can be done. It is not scheduled above because stages 1 to 5 do
not need it. Decide at the end of stage 5, with numbers from xterm and
twm, or earlier if stray pointers make stage 2 undebuggable.

## Risks that could change the plan

- **Workers.** Every task is a Web Worker. A desktop has around a
  hundred threads; browsers have limits and each worker costs memory.
  Measure in stage 5.
- **Asyncify on everything.** 40% more code and a check after indirect
  calls, in every library. If stage 6's measurements are bad: Asyncify
  only for call paths that can reach `fork` (needs whole-program
  knowledge that shared libraries take away), or `posix_spawn`
  everywhere and fork only where a program really continues as two.
- **Browsers other than Chromium.** Nothing has been run in Firefox or
  Safari. Do it in stage 1, before the list of required features grows.
- **Time-slice polling** may cost more than expected in tight loops
  (pixman's inner loops are exactly that).
