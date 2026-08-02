#!/bin/sh
set -eu

# Builds an .ipk of GMenuNX for the Sharp Zaurus (piko ROM), installable
# with piko's opkg (tools/make-ipk.sh in the sibling piko repo -- see
# ../piko/docs/HOWTO-PACKAGES.md for the format and why "Architecture:
# piko", not "arm").
#
# Usage:
#   ./build-package.sh [--version VER] [--out DIR]
#
#   --version VER   package version (default: git describe --always --dirty)
#   --out DIR       where to write the .ipk (default: current directory)
#
# Cross-compiles gmenunx fresh via Makefile.zaurus (`make dist`, which also
# lays out skins/translations/input.conf/about.txt/COPYING alongside the
# binary -- gmenunx reads those relative to its own current directory, see
# src/utilities.cpp's data_path()), stages that tree under
# usr/share/gmenunx the way the card overlay expects
# (/mnt/card/.zaurus/usr/bin, /mnt/card/.zaurus/usr/share/{applications,
# gmenunx} -- see gmenunx.desktop and the gmenunx-run wrapper for why),
# adds a copy of the SDL runtime + its dependencies (this is the first
# SDL-based app on piko, so none of libSDL/libSDL_image/libSDL_ttf/libz/
# libpng/libfreetype/libstdc++/libgcc_s are deployed to the device yet --
# see Makefile.zaurus's rpath comment for why they're carried here rather
# than pushed to the NAND root), then hands that tree to make-ipk.sh.
#
# Install on the device with pkgadd, onto the card (this needs the card
# mounted, since gmenunx wants exclusive /dev/fb0 + input and the wrapper
# script hardcodes /mnt/card/.zaurus):
#   pkgadd /tmp/gmenunx_VERSION_piko.ipk card

REPO="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PIKO="$(CDPATH= cd -- "$REPO/../piko" 2>/dev/null && pwd)" || {
    echo "FAILED: sibling piko repo not found at $REPO/../piko" >&2
    echo "make-ipk.sh (package builder), the cross-toolchain, and the SDL" >&2
    echo "runtime staging trees all live there." >&2
    exit 1
}
MAKEIPK="$PIKO/tools/make-ipk.sh"
[ -x "$MAKEIPK" ] || { echo "FAILED: $MAKEIPK not found or not executable" >&2; exit 1; }

TOOLCHAIN_BIN_DIR="${TOOLCHAIN_BIN_DIR:-$PIKO/toolchain/x-tools/arm-unknown-linux-uclibcgnueabi/bin}"
SDL_RUNTIME="${SDL_RUNTIME:-$PIKO/userspace/stage-sdl-runtime}"
TOOLCHAIN_SYSROOT="${TOOLCHAIN_SYSROOT:-$PIKO/toolchain/x-tools/arm-unknown-linux-uclibcgnueabi/arm-unknown-linux-uclibcgnueabi/sysroot}"

VERSION=""
OUTDIR="."

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --out)     OUTDIR="${2:?--out needs a value}"; shift 2 ;;
        -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
        *) echo "FAILED: unknown option: $1" >&2; exit 1 ;;
    esac
done

[ -n "$VERSION" ] || VERSION="$(cd "$REPO" && git describe --always --dirty 2>/dev/null)"
[ -n "$VERSION" ] || VERSION="0.0.0-unknown"

if [ ! -d "$TOOLCHAIN_BIN_DIR" ]; then
    echo "FAILED: toolchain bin dir not found: $TOOLCHAIN_BIN_DIR" >&2
    exit 1
fi
if [ ! -x "$SDL_RUNTIME/usr/lib/libSDL-1.2.so.0" ]; then
    echo "FAILED: SDL runtime not staged at $SDL_RUNTIME." >&2
    echo "Run tools/build-sdl.sh, build-sdl-image.sh, build-sdl-ttf.sh in $PIKO first." >&2
    exit 1
fi

cd "$REPO"

echo "==> building gmenunx"
PATH="$TOOLCHAIN_BIN_DIR:$PATH"
export PATH
export CC=arm-unknown-linux-uclibcgnueabi-gcc
export CXX=arm-unknown-linux-uclibcgnueabi-g++
export STRIP=arm-unknown-linux-uclibcgnueabi-strip
make -f Makefile.zaurus clean
make -f Makefile.zaurus dist

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT INT TERM
# mktemp -d makes this 0700; make-ipk.sh tars it as the package's "./"
# entry, and opkg would apply that mode to the (already-existing, shared)
# dest root on install -- e.g. locking /mnt/card/.zaurus down to root
# only. 0755 matches what a plain `mkdir -p` would have given it.
chmod 755 "$STAGE"

mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib" "$STAGE/usr/share/applications" "$STAGE/usr/share/gmenunx" "$STAGE/usr/share/pixmaps"
cp -RH dist/zaurus/. "$STAGE/usr/share/gmenunx/"
rm -f "$STAGE/usr/share/gmenunx/gmenunx-debug" # unstripped intermediate, not for shipping
cp -p gmenunx-run "$STAGE/usr/bin/"
cp -p gmenunx.desktop "$STAGE/usr/share/applications/"
cp -p assets/zaurus/gmenunx.png "$STAGE/usr/share/pixmaps/"

echo "==> bundling the SDL runtime (first SDL app on this device -- see header)"
# The card is FAT (vfat has no symlinks at all -- confirmed live: opkg's
# libarchive extractor fails every symlink entry with errno=1/EPERM and
# silently drops it, no error, no missing-file complaint until runtime).
# So each library ships as ONE regular file named by its SONAME (exactly
# what the ELF NEEDED entries reference), not the usual versioned-file-
# plus-symlink layout SDL_RUNTIME/TOOLCHAIN_SYSROOT use on jffs2 (which
# does support symlinks). readlink -f dereferences whatever symlink chain
# the source uses down to the real bits before copying.
stage_flat_lib() {
    soname="$1"; srcdir="$2"
    src="$srcdir/$soname"
    [ -e "$src" ] || { echo "FAILED: $src not found" >&2; exit 1; }
    cp "$(readlink -f "$src")" "$STAGE/usr/lib/$soname"
    chmod u+w "$STAGE/usr/lib/$soname"
    arm-unknown-linux-uclibcgnueabi-strip --strip-unneeded "$STAGE/usr/lib/$soname" 2>/dev/null || true
}

# libc.so.0 and ld-uClibc.so.1 (the ELF interpreter itself -- yes,
# libstdc++.so.6 lists it as a regular DT_NEEDED entry, not just via
# PT_INTERP) are deliberately not staged here: both are already on the
# device root from the X11/matchbox stack bootstrap
# (tools/chunked-deploy.sh) -- nothing dynamically linked on this device
# works at all otherwise -- and the dynamic linker always searches /lib
# regardless of where the executable lives.
#
# This walks the full transitive closure, not just gmenunx's own direct
# NEEDED list: libSDL_image/libSDL_ttf themselves need libpng/libfreetype,
# which never appear in gmenunx's own dynamic section at all (an earlier
# version of this script missed exactly that and shipped a package that
# would have failed to load libSDL_image.so on the device).
queue="$(arm-unknown-linux-uclibcgnueabi-readelf -d dist/zaurus/gmenunx | awk '/NEEDED/{gsub(/[][]/,"",$NF); print $NF}')"
staged=""
while [ -n "$queue" ]; do
    next=""
    for soname in $queue; do
        case " $staged " in *" $soname "*) continue ;; esac
        staged="$staged $soname"
        case "$soname" in libc.so.0|ld-uClibc.so.1) continue ;; esac

        case "$soname" in
            libstdc++.so.6|libgcc_s.so.1) srcdir="$TOOLCHAIN_SYSROOT/lib" ;;
            *) srcdir="$SDL_RUNTIME/usr/lib" ;;
        esac
        stage_flat_lib "$soname" "$srcdir"

        real="$(readlink -f "$srcdir/$soname")"
        more="$(arm-unknown-linux-uclibcgnueabi-readelf -d "$real" | awk '/NEEDED/{gsub(/[][]/,"",$NF); print $NF}')"
        next="$next $more"
    done
    queue="$next"
done

echo "==> packaging"
"$MAKEIPK" \
    --name gmenunx \
    --version "$VERSION" \
    --root "$STAGE" \
    --arch piko \
    --desc "GMenuNX - application/game launcher" \
    --postinst "$REPO/postinst" \
    --out "$OUTDIR"
