#!/bin/bash
#
# Oasis Linux Build Script
#
# This script builds a bootable QEMU image of Oasis Linux from source.
# It includes all necessary fixes and workarounds discovered during the build process.
#
# Prerequisites (install before running):
#   sudo apt-get install -y lua5.1 bison flex nasm bc ninja-build xz-utils libwayland-dev curl git cpio gzip build-essential
#
# Usage:
#   ./build-oasis.sh [--desktop] [BUILD_DIR]
#
# Options:
#   --desktop    Include graphical desktop (velox WM, st terminal, netsurf browser)
#   BUILD_DIR    Where to build (default: ./oasis-linux, next to this script)
#
# The script will create:
#   BUILD_DIR/qemu/bzImage         - Linux kernel
#   BUILD_DIR/qemu/initramfs.img.gz - Root filesystem
#   BUILD_DIR/qemu/run             - QEMU launch script
#

set -e

# Parse flags
DESKTOP_MODE=false
BUILD_DIR=""
for arg in "$@"; do
    case "$arg" in
        --desktop)
            DESKTOP_MODE=true
            ;;
        *)
            BUILD_DIR="$arg"
            ;;
    esac
done
# Default to ./oasis-linux next to this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/oasis-linux}"

# Configuration
KERNEL_VERSION="6.12"
MUSL_TOOLCHAIN_URL="http://musl.cc/x86_64-linux-musl-cross.tgz"
OASIS_REPO="https://github.com/oasislinux/oasis.git"
OASIS_ETC_REPO="https://github.com/oasislinux/etc.git"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for required tools
check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing=()

    for cmd in lua5.1 bison flex nasm curl git cpio gzip make gcc bc ninja xz; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install with: sudo apt-get install -y lua5.1 bison flex nasm bc ninja-build xz-utils libwayland-dev curl git cpio gzip build-essential"
        exit 1
    fi

    log_info "All prerequisites found."
}

# Create build directory structure
setup_directories() {
    log_info "Setting up build directories in $BUILD_DIR..."
    mkdir -p "$BUILD_DIR"/{src,toolchain,kernel,rootfs,qemu}
}

# Download and extract musl cross-compiler
setup_toolchain() {
    if [ -d "$BUILD_DIR/toolchain/x86_64-linux-musl-cross" ]; then
        log_info "Toolchain already exists, skipping download."
        return
    fi

    log_info "Downloading musl cross-compiler toolchain..."
    curl -L "$MUSL_TOOLCHAIN_URL" -o "$BUILD_DIR/toolchain/musl-cross.tgz"

    log_info "Extracting toolchain..."
    tar -xzf "$BUILD_DIR/toolchain/musl-cross.tgz" -C "$BUILD_DIR/toolchain"
    rm "$BUILD_DIR/toolchain/musl-cross.tgz"
}

# Clone Oasis repository
clone_oasis() {
    if [ -d "$BUILD_DIR/src/oasis/.git" ]; then
        log_info "Oasis repository already cloned, updating..."
        cd "$BUILD_DIR/src/oasis"
        git pull || true
        return
    fi

    log_info "Cloning Oasis Linux repository..."
    git clone "$OASIS_REPO" "$BUILD_DIR/src/oasis"
}

# Clean and reinitialize a submodule
reinit_submodule() {
    local submodule="$1"
    if [ -d "$submodule" ] || [ -f ".gitmodules" ]; then
        log_info "  Reinitializing $submodule..."
        # Remove any leftover rebase-apply directories
        rm -rf ".git/modules/$submodule/rebase-apply" 2>/dev/null || true
        git submodule deinit -f "$submodule" 2>/dev/null || true
        git submodule update --init "$submodule" 2>/dev/null || true
    fi
}

# Initialize all git submodules with fixes for problematic ones
init_submodules() {
    cd "$BUILD_DIR/src/oasis"

    log_info "Initializing git submodules (this may take a while)..."

    # Disable GPG signing which can cause timeout issues
    git config --local commit.gpgsign false

    # First pass: try to initialize all submodules
    git submodule update --init --recursive 2>/dev/null || true

    # Critical submodules that commonly have issues and MUST be initialized before build
    # These are packages that ninja tries to compile before their FETCH step completes
    local critical_submodules=(
        "pkg/bearssl/src"
        "pkg/libtls-bearssl/src"
        "pkg/libfido2/src"
        "pkg/openssh/src"
        "pkg/b3sum/src"
        "pkg/hotplugd/src"
        "pkg/rc/src"
        "pkg/pigz/src"
        "pkg/sdhcp/src"
        "pkg/syslogd/src"
        "pkg/ubase/src"
        "pkg/sbase/src"
        "pkg/sinit/src"
        "pkg/perp/src"
        "pkg/oksh/src"
        "pkg/vis/src"
        "pkg/samurai/src"
        "pkg/curl/src"
        "pkg/git/src"
        "pkg/mandoc/src"
        "pkg/less/src"
        "pkg/file/src"
        "pkg/libcbor/src"
        "pkg/e2fsprogs/src"
        "pkg/util-linux/src"
        "pkg/iproute2/src"
        "pkg/iptables/src"
        "pkg/zlib/src"
        "pkg/awk/src"
        "pkg/pax/src"
        "pkg/luaposix/src"
        "pkg/lua/src"
        # Desktop packages (used when --desktop is passed)
        "pkg/swc/src"
        "pkg/velox/src"
        "pkg/st/src"
        "pkg/dmenu/src"
        "pkg/wld/src"
        "pkg/libdrm/src"
        "pkg/pixman/src"
        "pkg/libinput/src"
        "pkg/libxkbcommon/src"
        "pkg/fontconfig/src"
        "pkg/freetype/src"
        "pkg/expat/src"
        "pkg/libffi/src"
        "pkg/libevdev/src"
        "pkg/libpng/src"
    )

    log_info "Ensuring critical submodules are properly initialized..."
    for submodule in "${critical_submodules[@]}"; do
        if [ -e "$(dirname "$submodule")" ]; then
            # Check if the submodule source directory is empty or missing key files
            if [ ! -d "$submodule" ] || [ -z "$(ls -A "$submodule" 2>/dev/null)" ]; then
                reinit_submodule "$submodule"
            fi
        fi
    done

    # Special handling for mtdev which may need cloning from a mirror
    if [ -d "pkg/mtdev" ] && [ ! -f "pkg/mtdev/src/configure.ac" ]; then
        log_warn "Attempting to fix mtdev submodule..."
        rm -rf "pkg/mtdev/src"
        git clone https://github.com/nicman23/mtdev.git "pkg/mtdev/src" 2>/dev/null || \
        git clone https://gitlab.freedesktop.org/libevdev/mtdev.git "pkg/mtdev/src" 2>/dev/null || true
    fi
}

# Create config.lua with necessary fixes
create_config() {
    log_info "Creating config.lua with build fixes..."

    if [ "$DESKTOP_MODE" = "true" ]; then
        log_info "Desktop mode enabled - including desktop, extra, and media sets."
        cat > "$BUILD_DIR/src/oasis/config.lua" << 'EOF'
local sets = dofile(basedir..'/sets.lua')

return {
	-- build output directory
	builddir='out',

	-- install prefix
	prefix='',

	-- compress man pages
	gzman=true,

	-- package/file selection - core + desktop + extra + media
	fs={
		{sets.core, exclude={'^include/', '^lib/.*%.a$'}},
		{sets.desktop, exclude={'^include/', '^lib/.*%.a$'}},
		{sets.extra, exclude={'^include/', '^lib/.*%.a$'}},
		{sets.media, exclude={'^include/', '^lib/.*%.a$'}},
	},

	-- target toolchain and flags
	target={
		platform='x86_64-linux-musl',
		cflags='-Os -fPIE -pipe',
		ldflags='-s -static-pie',
	},

	-- host toolchain and flags
	-- NOTE: -D_GNU_SOURCE is required for pipe2() support in host tools
	host={
		cflags='-O2 -pipe -D_GNU_SOURCE',
		ldflags='',
	},

	-- output git repository
	repo={
		path='out/root.git',
		flags='--bare',
		tag='tree',
		branch='master',
	},
}
EOF
    else
        log_info "Core-only mode (use --desktop for graphical desktop)."
        cat > "$BUILD_DIR/src/oasis/config.lua" << 'EOF'
local sets = dofile(basedir..'/sets.lua')

return {
	-- build output directory
	builddir='out',

	-- install prefix
	prefix='',

	-- compress man pages
	gzman=true,

	-- package/file selection - core set for bootable system
	fs={
		{sets.core, exclude={'^include/', '^lib/.*%.a$'}},
	},

	-- target toolchain and flags
	target={
		platform='x86_64-linux-musl',
		cflags='-Os -fPIE -pipe',
		ldflags='-s -static-pie',
	},

	-- host toolchain and flags
	-- NOTE: -D_GNU_SOURCE is required for pipe2() support in host tools
	host={
		cflags='-O2 -pipe -D_GNU_SOURCE',
		ldflags='',
	},

	-- output git repository
	repo={
		path='out/root.git',
		flags='--bare',
		tag='tree',
		branch='master',
	},
}
EOF
    fi
}

# Fix xz landlock syscall compilation issue
fix_xz_landlock() {
    log_info "Applying xz landlock syscall fix..."

    local xz_gen="$BUILD_DIR/src/oasis/pkg/xz/gen.lua"

    if [ -f "$xz_gen" ]; then
        # Check if fix is already applied
        if grep -q "SYS_landlock_create_ruleset" "$xz_gen"; then
            log_info "xz landlock fix already applied."
            return
        fi

        # Add landlock syscall definitions after '-D HAVE_CONFIG_H'
        # These syscall numbers are for x86_64 Linux 5.13+
        sed -i "/'-D HAVE_CONFIG_H',/a\\
	'-D SYS_landlock_create_ruleset=444',\\
	'-D SYS_landlock_add_rule=445',\\
	'-D SYS_landlock_restrict_self=446'," "$xz_gen"

        log_info "xz landlock fix applied successfully."
    else
        log_warn "xz/gen.lua not found, skipping landlock fix."
    fi
}

# Run the Oasis build with automatic submodule fixing
build_oasis() {
    cd "$BUILD_DIR/src/oasis"

    # Add toolchain to PATH
    export PATH="$BUILD_DIR/toolchain/x86_64-linux-musl-cross/bin:$PATH"

    # Add host tools (like zic) that are built during the build to PATH
    export PATH="$BUILD_DIR/src/oasis/out/pkg/tz:$PATH"

    log_info "Running setup.lua to generate build files..."
    lua5.1 setup.lua

    log_info "Building Oasis Linux with ninja (this will take a while)..."

    # Use ninja or samurai if available
    local ninja_cmd="ninja"
    if command -v samu &> /dev/null; then
        ninja_cmd="samu"
    fi

    # Build with parallel jobs
    local jobs=$(nproc)

    # Run the build with automatic retry for submodule issues
    local max_retries=20
    local retry=0

    while [ $retry -lt $max_retries ]; do
        # Run ninja and capture exit code properly (tee masks it otherwise)
        set +e
        $ninja_cmd -j"$jobs" 2>&1 | tee "$BUILD_DIR/build.log"
        local ninja_status=${PIPESTATUS[0]}
        set -e

        if [ $ninja_status -eq 0 ]; then
            log_info "Build completed successfully!"
            break
        fi

        # Check for host tool not found errors (like zic) - just retry, the tool should be built now
        if grep -qE "^/bin/sh:.*: not found" "$BUILD_DIR/build.log"; then
            log_warn "Build failed due to missing host tool (should be built now), retrying..."
            ((++retry))
            sleep 2
            continue
        fi

        # Check for submodule-related errors
        if grep -qE "(No such file or directory|Dirty index|rebase-apply|failed to access)" "$BUILD_DIR/build.log"; then
            log_warn "Build failed due to submodule issue (attempt $((retry+1))/$max_retries)..."

            # Extract the problematic package from the ERROR line specifically
            # First, find lines with the error, then extract the package name from those lines
            local error_line=$(grep -E "(No such file or directory|Dirty index|rebase-apply|failed to access)" "$BUILD_DIR/build.log" | tail -1)
            local pkg=$(echo "$error_line" | grep -oP "pkg/[^/]+" | head -1)

            # If not found in error line, try FAILED lines
            if [ -z "$pkg" ]; then
                error_line=$(grep -E "^FAILED:" "$BUILD_DIR/build.log" | tail -1)
                pkg=$(echo "$error_line" | grep -oP "pkg/[^/]+" | head -1)
            fi

            if [ -n "$pkg" ]; then
                log_warn "Fixing $pkg/src..."
                rm -rf ".git/modules/$pkg/src/rebase-apply" 2>/dev/null || true
                git submodule deinit -f "$pkg/src" 2>/dev/null || true
                git submodule update --init "$pkg/src" 2>/dev/null || true
            else
                log_warn "Could not identify problematic submodule, reinitializing all..."
                git submodule update --init --recursive 2>/dev/null || true
            fi

            ((++retry))
            sleep 2
        else
            log_error "Build failed with non-submodule error. Check $BUILD_DIR/build.log"
            tail -50 "$BUILD_DIR/build.log"
            exit 1
        fi
    done

    if [ $retry -eq $max_retries ]; then
        log_error "Build failed after $max_retries retries. Check $BUILD_DIR/build.log"
        exit 1
    fi
}

# Download and build Linux kernel
build_kernel() {
    cd "$BUILD_DIR/kernel"

    local kernel_tarball="linux-$KERNEL_VERSION.tar.xz"
    local kernel_url="https://cdn.kernel.org/pub/linux/kernel/v6.x/$kernel_tarball"

    if [ -f "$BUILD_DIR/qemu/bzImage" ]; then
        log_info "Kernel already built, skipping."
        return
    fi

    if [ ! -f "$kernel_tarball" ]; then
        log_info "Downloading Linux kernel $KERNEL_VERSION..."
        curl -LO "$kernel_url"
    fi

    if [ ! -d "linux-$KERNEL_VERSION" ]; then
        log_info "Extracting kernel source..."
        tar xf "$kernel_tarball"
    fi

    cd "linux-$KERNEL_VERSION"

    log_info "Configuring kernel for QEMU/KVM..."
    make defconfig
    make kvm_guest.config

    log_info "Building kernel (this will take a while)..."
    make -j$(nproc)

    log_info "Copying kernel to qemu directory..."
    cp arch/x86/boot/bzImage "$BUILD_DIR/qemu/"
}

# Extract rootfs and create initramfs
create_rootfs() {
    cd "$BUILD_DIR/rootfs"

    log_info "Extracting root filesystem from build..."

    # Get the tree hash from the build output
    local tree_hash=$(cat "$BUILD_DIR/src/oasis/out/root.tree" 2>/dev/null)

    if [ -z "$tree_hash" ]; then
        log_error "Could not find root.tree - build may not have completed successfully"
        exit 1
    fi

    # Clone the bare git repository
    rm -rf root.git
    git clone --bare "$BUILD_DIR/src/oasis/out/root.git" root.git

    # Extract the filesystem
    rm -rf root
    mkdir -p root
    cd root
    git --git-dir=../root.git archive "$tree_hash" | tar x

    # Create necessary directories
    mkdir -p dev proc sys tmp var/run var/log home root run mnt

    # Clone and copy /etc configuration (optional - system boots without it)
    if [ ! -d "$BUILD_DIR/rootfs/oasis-etc" ]; then
        git clone "$OASIS_ETC_REPO" "$BUILD_DIR/rootfs/oasis-etc" 2>/dev/null || true
    fi
    if [ -d "$BUILD_DIR/rootfs/oasis-etc" ]; then
        cp -a "$BUILD_DIR/rootfs/oasis-etc"/* etc/ 2>/dev/null || true
    fi
    mkdir -p etc

    # Create init script for initramfs boot
    cat > init << 'INIT_EOF'
#!/bin/sh

# Mount essential filesystems
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Create device nodes if they don't exist
mknod -m 666 /dev/null c 1 3 2>/dev/null
mknod -m 666 /dev/zero c 1 5 2>/dev/null
mknod -m 666 /dev/console c 5 1 2>/dev/null
mknod -m 666 /dev/tty c 5 0 2>/dev/null

# Set up basic environment
export PATH=/bin:/usr/bin:/libexec/velox
export HOME=/root
export TERM=linux

# Check kernel command line for desktop mode
DESKTOP=false
for param in $(cat /proc/cmdline); do
    case "$param" in
        oasis.desktop) DESKTOP=true ;;
    esac
done

if [ "$DESKTOP" = "true" ] && [ -x /bin/velox ]; then
    # Set up Wayland environment
    export XDG_RUNTIME_DIR=/run/user
    mkdir -p "$XDG_RUNTIME_DIR"

    # Copy velox config if available
    mkdir -p /root
    if [ -f /share/doc/velox/velox.conf.sample ] && [ ! -f /root/velox.conf ]; then
        cp /share/doc/velox/velox.conf.sample /root/velox.conf
    fi

    echo "Starting Oasis desktop (velox)..."
    echo "  Mod+Shift+Return = terminal"
    echo "  Mod+r            = run menu"
    echo "  Mod+b            = browser"
    echo "  Mod+Shift+q      = quit"
    echo ""

    # Launch velox via swc-launch (handles DRM access)
    swc-launch velox
else
    # Console mode - start a shell
    echo ""
    echo "Welcome to Oasis Linux"
    echo "Type 'exit' to power off."
    echo ""
    /bin/ksh -l
fi

# Clean shutdown
echo "Powering off..."
sync
halt -p
INIT_EOF
    chmod +x init

    log_info "Creating initramfs..."
    find . | cpio -o -H newc | gzip > "$BUILD_DIR/qemu/initramfs.img.gz"
}

# Create QEMU launch script
create_qemu_script() {
    log_info "Creating QEMU launch script..."

    cat > "$BUILD_DIR/qemu/run" << 'QEMU_EOF'
#!/bin/sh

# Oasis Linux QEMU launcher script
#
# Usage:
#   ./run           - Launch graphical desktop (if desktop build)
#   ./run -s        - Launch in serial/console mode (no graphics)
#   ./run -c        - Launch graphical window with console (no desktop WM)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$SCRIPT_DIR/bzImage"
INITRD="$SCRIPT_DIR/initramfs.img.gz"

# Check for required files
if [ ! -f "$KERNEL" ]; then
    echo "Error: Kernel not found at $KERNEL"
    exit 1
fi

if [ ! -f "$INITRD" ]; then
    echo "Error: Initramfs not found at $INITRD"
    exit 1
fi

# Parse arguments
MODE="desktop"
for arg in "$@"; do
    case "$arg" in
        -s|--serial)
            MODE="serial"
            ;;
        -c|--console)
            MODE="console"
            ;;
        -h|--help)
            echo "Usage: $0 [-s|--serial] [-c|--console]"
            echo "  -s, --serial    Serial console (no graphics window)"
            echo "  -c, --console   Graphical window with console (no desktop WM)"
            echo "  (default)       Graphical desktop with velox WM"
            exit 0
            ;;
    esac
done

# Check for KVM support
KVM_OPTS=""
if [ -w /dev/kvm ]; then
    KVM_OPTS="-enable-kvm -cpu host"
else
    echo "Warning: KVM not available, using emulation (slower)"
fi

COMMON_OPTS="-m 1G $KVM_OPTS"
COMMON_OPTS="$COMMON_OPTS -kernel $KERNEL -initrd $INITRD"

case "$MODE" in
    serial)
        exec qemu-system-x86_64 \
            $COMMON_OPTS \
            -nographic \
            -append "console=ttyS0 rdinit=/init"
        ;;
    console)
        exec qemu-system-x86_64 \
            $COMMON_OPTS \
            -device virtio-gpu-pci \
            -device qemu-xhci,id=xhci \
            -device usb-kbd,bus=xhci.0 \
            -device usb-tablet,bus=xhci.0 \
            -append "console=tty0 rdinit=/init"
        ;;
    desktop)
        exec qemu-system-x86_64 \
            $COMMON_OPTS \
            -device virtio-gpu-pci \
            -device qemu-xhci,id=xhci \
            -device usb-kbd,bus=xhci.0 \
            -device usb-tablet,bus=xhci.0 \
            -append "console=tty0 rdinit=/init oasis.desktop"
        ;;
esac
QEMU_EOF

    chmod +x "$BUILD_DIR/qemu/run"
}

# Create README
create_readme() {
    cat > "$BUILD_DIR/qemu/README.md" << 'README_EOF'
# Oasis Linux QEMU Image

This directory contains a bootable Oasis Linux system for QEMU.

## Files

- `bzImage` - Linux kernel
- `initramfs.img.gz` - Root filesystem (initramfs)
- `run` - QEMU launch script

## Usage

```sh
# Graphical mode
./run

# Serial console mode (no graphics)
./run -s
```

## What is Oasis Linux?

Oasis is a small, statically-linked Linux distribution that uses:
- musl libc instead of glibc
- sbase/ubase instead of coreutils
- BearSSL instead of OpenSSL
- oksh instead of bash
- sinit instead of systemd

For more information, see: https://github.com/oasislinux/oasis

## Exiting QEMU

- Graphical mode: Close the window or press Ctrl+Alt+Q
- Serial mode: Press Ctrl+A, then X

## Build Information

This image was built using the automated build script.
Build fixes applied:
- Added -D_GNU_SOURCE for pipe2() support in host tools
- Fixed xz landlock syscall definitions (444, 445, 446)
- Automatic submodule reinitialization for race conditions
README_EOF
}

# Main build process
main() {
    log_info "============================================"
    log_info "Starting Oasis Linux build..."
    log_info "Build directory: $BUILD_DIR"
    log_info "============================================"

    check_prerequisites
    setup_directories
    setup_toolchain
    clone_oasis
    init_submodules
    create_config
    fix_xz_landlock
    build_oasis
    build_kernel
    create_rootfs
    create_qemu_script
    create_readme

    log_info "============================================"
    log_info "Build completed successfully!"
    if [ "$DESKTOP_MODE" = "true" ]; then
        log_info "  Mode: Desktop (velox WM + st + netsurf)"
    else
        log_info "  Mode: Core only (console)"
    fi
    log_info "============================================"
    log_info ""
    log_info "To run Oasis Linux in QEMU:"
    log_info "  cd $BUILD_DIR/qemu"
    log_info "  ./run         # Desktop mode (velox WM)"
    log_info "  ./run -c      # Graphical console (no WM)"
    log_info "  ./run -s      # Serial console (no graphics)"
    log_info ""
    log_info "Files created:"
    log_info "  $BUILD_DIR/qemu/bzImage         - Linux kernel"
    log_info "  $BUILD_DIR/qemu/initramfs.img.gz - Root filesystem"
    log_info "  $BUILD_DIR/qemu/run             - QEMU launcher"
    log_info ""
}

main "$@"
