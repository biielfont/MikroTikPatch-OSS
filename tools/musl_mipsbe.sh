#!/bin/sh
# Build a minimal big-endian MIPS musl toolchain for the keygen.
#
# The result is installed under .toolchain/mipsbe-musl and picked up
# automatically by keygen/build.sh.
#
# Usage: tools/musl_mipsbe.sh [musl-version]   (default 1.2.6)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-1.2.6}
PREFIX="$ROOT/.toolchain/mipsbe-musl"
CACHE="$ROOT/.toolchain/cache"
SRC="$ROOT/.toolchain/musl-$VERSION-mipsbe"

find_cc() {
    for c in "${CC_MIPSBE:-}" mips-linux-gnu-gcc; do
        [ -n "$c" ] || continue
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

CC_MIPSBE=$(find_cc || true)
if [ -z "$CC_MIPSBE" ]; then
    echo "ERROR: no big-endian MIPS cross compiler found (set CC_MIPSBE)" >&2
    echo "       Debian/Ubuntu: apt install gcc-mips-linux-gnu" >&2
    echo "       An mips-linux-musl-gcc already in PATH is used directly by" >&2
    echo "       keygen/build.sh and does not need this script." >&2
    exit 1
fi

target=$("$CC_MIPSBE" -dumpmachine 2>/dev/null)
case "$target" in
    mips-linux-gnu*) ;;
    *) echo "ERROR: $CC_MIPSBE targets $target, expected 32-bit big-endian MIPS" >&2; exit 1 ;;
esac
if ! printf '\n' | "$CC_MIPSBE" -dM -E - 2>/dev/null | grep -q '^#define __MIPSEB__'; then
    echo "ERROR: $CC_MIPSBE does not target big-endian MIPS" >&2
    exit 1
fi

mkdir -p "$CACHE"
TARBALL="$CACHE/musl-$VERSION.tar.gz"
if [ ! -f "$TARBALL" ]; then
    echo "==> downloading musl-$VERSION"
    wget -nv -O "$TARBALL" "https://musl.libc.org/releases/musl-$VERSION.tar.gz"
fi

rm -rf "$SRC" "$PREFIX"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1

echo "==> building musl-$VERSION for big-endian MIPS (static)"
cd "$SRC"
CC="$CC_MIPSBE" ./configure --target=mips-linux-musl --prefix="$PREFIX" \
    --disable-shared >/dev/null
make -j"$(nproc)" CROSS_COMPILE= AR=ar RANLIB=ranlib >/dev/null
make install CROSS_COMPILE= AR=ar RANLIB=ranlib >/dev/null

# Point the wrapper at the selected cross compiler and installed musl specs.
cat > "$PREFIX/bin/musl-gcc" <<EOF
#!/bin/sh
exec $CC_MIPSBE "\$@" -specs "$PREFIX/lib/musl-gcc.specs"
EOF
chmod +x "$PREFIX/bin/musl-gcc"

ar rcs "$PREFIX/lib/libatomic_asneeded.a"

echo "==> installed: $PREFIX/bin/musl-gcc"
