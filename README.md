# build-oasis-linux

Automated build script that compiles [Oasis Linux](https://github.com/oasislinux/oasis) from source and produces a bootable QEMU image.

Oasis is a small, statically-linked Linux distribution built on musl libc, BearSSL, oksh, and Wayland -- no glibc, no OpenSSL, no bash, no systemd, no Xorg.

## Quick Start

```bash
# Install prerequisites (Debian/Ubuntu)
sudo apt-get install -y lua5.1 bison flex nasm bc ninja-build xz-utils \
    libwayland-dev curl git cpio gzip build-essential

# Build core system (console only)
./build-oasis.sh

# Or build with graphical desktop (velox WM, st terminal, netsurf browser)
./build-oasis.sh --desktop

# Or specify a custom build directory
./build-oasis.sh --desktop /path/to/build
```

Build output goes to `./oasis-linux/` by default (next to the script).

## Running

```bash
cd oasis-linux/qemu/

# Desktop mode (velox Wayland WM) -- requires --desktop build
./run

# Graphical window with console (no WM)
./run -c

# Serial console in your terminal
./run -s
```

To exit: type `exit` in the shell (or `Mod+Shift+Q` in velox). The VM will power off cleanly.

In serial mode, you can also press `Ctrl+A` then `X` to kill QEMU directly.

## What It Does

The build script handles everything automatically:

1. Downloads the musl cross-compiler toolchain
2. Clones the Oasis Linux repository and initializes 150+ git submodules
3. Applies build fixes (landlock syscalls, `_GNU_SOURCE` for host tools)
4. Builds all packages with ninja, automatically retrying and fixing submodule issues
5. Builds a Linux 6.12 kernel configured for QEMU/KVM
6. Packages everything into an initramfs
7. Creates a QEMU launch script

## Build Modes

| Flag | Packages | Use Case |
|------|----------|----------|
| *(none)* | core (32 packages) | Minimal console system |
| `--desktop` | core + desktop + extra + media (70+ packages) | Full graphical desktop |

### Desktop Includes

- **velox** -- tiling Wayland window manager
- **st** -- terminal emulator
- **dmenu** -- application launcher
- **netsurf** -- web browser
- **mupdf** -- PDF viewer
- **mpv** -- media player
- **vis** -- text editor (vim-like)
- Fonts (Adobe Source, Terminus)

## Build Fixes Applied Automatically

The Oasis build has several issues when building from a fresh clone. This script handles all of them:

- **`-D_GNU_SOURCE`** added to host compiler flags for `pipe2()` support
- **xz landlock syscall numbers** defined for kernels 5.13+ (syscalls 444-446)
- **Submodule race conditions** -- ninja fetches submodules lazily, but sometimes tries to compile packages before their source is checked out. The script detects these failures, reinitializes the broken submodule, and retries (up to 20 times)
- **Host tool PATH** -- tools like `zic` are built during the build and need to be in PATH for later steps
- **Dirty submodule index / rebase-apply leftovers** -- automatically cleaned and reinitialized

## Requirements

- Linux x86_64
- ~10 GB disk space
- ~15-30 minutes build time (depending on CPU and network)
- QEMU for running the image (`qemu-system-x86_64`)
- KVM recommended for performance (`/dev/kvm`)
