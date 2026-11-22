#!/bin/sh
# Build the keygen binaries from keygen.c as statically linked executables.
#
#   keygen_x86    32-bit i386 ELF   (RouterOS x86)
#   keygen_arm64  aarch64 ELF       (RouterOS arm64)
#   keygen_mipsbe 32-bit big-endian MIPS ELF (RouterOS mipsbe)
#   keygen_arm    32-bit ARM ELF    (RouterOS arm)
#   keygen_mipsle 32-bit little-endian MIPS ELF (RouterOS mmips and smips)
#   keygen_ppc    32-bit big-endian PowerPC ELF (RouterOS ppc)
#   keygen_host   x86_64 ELF        (local testing only)
#
# Usage:
#   build.sh            build all supported keygen variants
#   build.sh x86        build only keygen_x86
#   build.sh arm64      build only keygen_arm64
#   build.sh mipsbe     build only keygen_mipsbe
#   build.sh arm mmips ppc
#                       build the additional 32-bit variants
#   build.sh host       build only keygen_host
#   build.sh all        same as no arguments
#
# Only the toolchains for the requested targets are needed: an x86-only build
# never looks for an aarch64 or MIPS compiler.
#
# The licence key pair is baked in at compile time from
# CUSTOM_LICENSE_PUBLIC_KEY / CUSTOM_LICENSE_PRIVATE_KEY (32-byte little-endian
# hex, as `mikrotikpatch genkeys` emits them).  When they are unset the key
# recovered from the shipped keygen is used.
#
# Toolchains (override with CC_X86 / CC_ARM64 / CC_MIPSBE / CC_ARM /
# CC_MIPSLE / CC_PPC / CC_HOST):
#   x86    i486-linux-musl-gcc / i686-linux-musl-gcc, or the local toolchain
#          built by tools/musl_i386.sh (run automatically when no i386 musl
#          compiler is in PATH)
#   arm64  aarch64-linux-musl-gcc, or the local toolchain built by
#          tools/musl_aarch64.sh (run automatically when no aarch64 musl
#          compiler is in PATH)
#   mipsbe  mips-linux-musl-gcc, or the local toolchain built by
#           tools/musl_mipsbe.sh (run automatically when no MIPS musl
#           compiler is in PATH)
#   arm     arm-linux-gnueabi-gcc
#   mmips /
#   smips   mipsel-linux-gnu-gcc
#   ppc     powerpc-linux-gnu-gcc
#   host   musl-gcc
set -e
cd "$(dirname "$0")"

ROOT=$(cd .. && pwd)
TOOLCHAIN="$ROOT/.toolchain"
STUBS="$TOOLCHAIN/stubs"

CFLAGS="-std=gnu11 -Os -static -s -fno-pie -no-pie -fno-stack-protector"

# ---- targets --------------------------------------------------------------
BUILD_X86=0
BUILD_ARM64=0
BUILD_MIPSBE=0
BUILD_ARM=0
BUILD_MIPSLE=0
BUILD_PPC=0
BUILD_HOST=0

if [ $# -eq 0 ]; then
    set -- all
fi
for arg in "$@"; do
    case "$arg" in
        x86|i386|i486|i686) BUILD_X86=1 ;;
        arm64|aarch64)      BUILD_ARM64=1 ;;
        mipsbe|mips)        BUILD_MIPSBE=1 ;;
        arm)                BUILD_ARM=1 ;;
        mmips|smips)        BUILD_MIPSLE=1 ;;
        ppc)                BUILD_PPC=1 ;;
        host)               BUILD_HOST=1 ;;
        all)                BUILD_X86=1; BUILD_ARM64=1; BUILD_MIPSBE=1
                            BUILD_ARM=1; BUILD_MIPSLE=1; BUILD_PPC=1 ;;
        *)
            echo "unknown argument: $arg" >&2
            echo "usage: $0 [x86] [arm64] [mipsbe] [arm] [mmips] [smips] [ppc] [host]" >&2
            exit 2
            ;;
    esac
done
if [ "$BUILD_X86" -eq 0 ] && [ "$BUILD_ARM64" -eq 0 ] && [ "$BUILD_MIPSBE" -eq 0 ] && [ "$BUILD_ARM" -eq 0 ] && [ "$BUILD_MIPSLE" -eq 0 ] && [ "$BUILD_PPC" -eq 0 ] && [ "$BUILD_HOST" -eq 0 ]; then
    echo "nothing to build" >&2
    exit 2
fi

# ---- key material ---------------------------------------------------------
DEFS=""
if [ -n "$CUSTOM_LICENSE_PUBLIC_KEY" ]; then
    DEFS="$DEFS -DKEYGEN_LICENSE_PUBLIC_HEX=\"$CUSTOM_LICENSE_PUBLIC_KEY\""
fi
if [ -n "$CUSTOM_LICENSE_PRIVATE_KEY" ]; then
    DEFS="$DEFS -DKEYGEN_LICENSE_PRIVATE_HEX=\"$CUSTOM_LICENSE_PRIVATE_KEY\""
fi

find_x86_cc() {
    for c in "${CC_X86:-}" i486-linux-musl-gcc i686-linux-musl-gcc \
             i386-linux-musl-gcc "$TOOLCHAIN/i386-musl/bin/musl-gcc"; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

find_arm_cc() {
    for c in "${CC_ARM64:-}" aarch64-linux-musl-gcc \
             "$TOOLCHAIN/aarch64-musl/bin/musl-gcc"; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

find_mipsbe_cc() {
    for c in "${CC_MIPSBE:-}" mips-linux-musl-gcc \
             "$TOOLCHAIN/mipsbe-musl/bin/musl-gcc"; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

find_arm32_cc() {
    for c in "${CC_ARM:-}" arm-linux-gnueabi-gcc; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

find_mipsle_cc() {
    for c in "${CC_MIPSLE:-}" mipsel-linux-gnu-gcc; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

find_ppc_cc() {
    for c in "${CC_PPC:-}" powerpc-linux-gnu-gcc; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

# Some distributions (Arch) patch gcc to link -latomic_asneeded, which is not
# available for cross/64-bit targets.  An empty archive satisfies the link and
# is ignored by toolchains that do not ask for it.
make_stubs() {
    mkdir -p "$STUBS"
    [ -f "$STUBS/libatomic_asneeded.a" ] || ar rcs "$STUBS/libatomic_asneeded.a"
}

# ---- x86 ------------------------------------------------------------------
if [ "$BUILD_X86" -eq 1 ]; then
    X86_CC=$(find_x86_cc || true)
    if [ -z "$X86_CC" ]; then
        echo "==> no i386 musl compiler in PATH; building one (tools/musl_i386.sh)"
        sh "$ROOT/tools/musl_i386.sh"
        X86_CC=$(find_x86_cc || true)
    fi
    if [ -z "$X86_CC" ]; then
        echo "ERROR: no i386 musl compiler found (set CC_X86)" >&2
        exit 1
    fi
    echo "==> keygen_x86   ($X86_CC)"
    $X86_CC $CFLAGS $DEFS -Wl,-m,elf_i386 -o keygen_x86 keygen.c
fi

# ---- arm64 ----------------------------------------------------------------
if [ "$BUILD_ARM64" -eq 1 ]; then
    ARM_CC=$(find_arm_cc || true)
    if [ -z "$ARM_CC" ]; then
        echo "==> no aarch64 musl compiler in PATH; building one (tools/musl_aarch64.sh)"
        sh "$ROOT/tools/musl_aarch64.sh"
        ARM_CC=$(find_arm_cc || true)
    fi
    if [ -z "$ARM_CC" ]; then
        echo "ERROR: no aarch64 musl compiler found (set CC_ARM64)" >&2
        exit 1
    fi
    make_stubs
    echo "==> keygen_arm64 ($ARM_CC)"
    $ARM_CC $CFLAGS $DEFS -L"$STUBS" -o keygen_arm64 keygen.c
fi

# ---- mipsbe ----------------------------------------------------------------
if [ "$BUILD_MIPSBE" -eq 1 ]; then
    MIPSBE_CC=$(find_mipsbe_cc || true)
    if [ -z "$MIPSBE_CC" ]; then
        echo "==> no MIPS musl compiler in PATH; building one (tools/musl_mipsbe.sh)"
        sh "$ROOT/tools/musl_mipsbe.sh"
        MIPSBE_CC=$(find_mipsbe_cc || true)
    fi
    if [ -z "$MIPSBE_CC" ]; then
        echo "ERROR: no big-endian MIPS musl compiler found (set CC_MIPSBE)" >&2
        exit 1
    fi
    make_stubs
    echo "==> keygen_mipsbe ($MIPSBE_CC)"
    $MIPSBE_CC $CFLAGS $DEFS -L"$STUBS" -o keygen_mipsbe keygen.c
fi

# ---- arm ------------------------------------------------------------------
if [ "$BUILD_ARM" -eq 1 ]; then
    ARM32_CC=$(find_arm32_cc || true)
    if [ -z "$ARM32_CC" ]; then
        echo "ERROR: no ARM cross compiler found (set CC_ARM; Ubuntu: gcc-arm-linux-gnueabi)" >&2
        exit 1
    fi
    echo "==> keygen_arm ($ARM32_CC)"
    $ARM32_CC $CFLAGS $DEFS -o keygen_arm keygen.c
fi

# ---- mmips / smips --------------------------------------------------------
if [ "$BUILD_MIPSLE" -eq 1 ]; then
    MIPSLE_CC=$(find_mipsle_cc || true)
    if [ -z "$MIPSLE_CC" ]; then
        echo "ERROR: no little-endian MIPS cross compiler found (set CC_MIPSLE; Ubuntu: gcc-mipsel-linux-gnu)" >&2
        exit 1
    fi
    echo "==> keygen_mipsle ($MIPSLE_CC)"
    $MIPSLE_CC $CFLAGS $DEFS -march=mips32 -mabi=32 -o keygen_mipsle keygen.c
fi

# ---- ppc ------------------------------------------------------------------
if [ "$BUILD_PPC" -eq 1 ]; then
    PPC_CC=$(find_ppc_cc || true)
    if [ -z "$PPC_CC" ]; then
        echo "ERROR: no PowerPC cross compiler found (set CC_PPC; Ubuntu: gcc-powerpc-linux-gnu)" >&2
        exit 1
    fi
    echo "==> keygen_ppc ($PPC_CC)"
    $PPC_CC $CFLAGS $DEFS -m32 -mbig-endian -o keygen_ppc keygen.c
fi

# ---- host -----------------------------------------------------------------
if [ "$BUILD_HOST" -eq 1 ]; then
    HOST_CC=${CC_HOST:-musl-gcc}
    make_stubs
    echo "==> keygen_host  ($HOST_CC)"
    $HOST_CC $CFLAGS $DEFS -L"$STUBS" -o keygen_host keygen.c
fi

echo "built:"
BUILT=""
[ "$BUILD_X86" -eq 1 ] && BUILT="$BUILT keygen_x86"
[ "$BUILD_ARM64" -eq 1 ] && BUILT="$BUILT keygen_arm64"
[ "$BUILD_MIPSBE" -eq 1 ] && BUILT="$BUILT keygen_mipsbe"
[ "$BUILD_ARM" -eq 1 ] && BUILT="$BUILT keygen_arm"
[ "$BUILD_MIPSLE" -eq 1 ] && BUILT="$BUILT keygen_mipsle"
[ "$BUILD_PPC" -eq 1 ] && BUILT="$BUILT keygen_ppc"
[ "$BUILD_HOST" -eq 1 ] && BUILT="$BUILT keygen_host"
ls -l $BUILT
file $BUILT 2>/dev/null || true
