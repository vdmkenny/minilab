#!/usr/bin/env bash
# usage: build-sane-macos.sh <arm64|x86_64> <out folder> [<downloads folder>]
#
# Builds SANE for one Mac architecture and lays it out in <out folder>, which must be empty or not
# there yet. That's the `sane` folder the macOS releases carry next to minilab, so scanning works
# with nothing to install: `src/scan/sane.zig` looks for it before it looks for the system's SANE.
# It's all built from source archives pinned by version and SHA-256, and nothing comes from
# Homebrew:
#
# - sane-backends: libsane and every backend that builds on macOS. The ones that need libraries
#   macOS doesn't have (escl, gphoto2, v4l and a few more) don't;
# - libusb, which the backends reach USB scanners through, as a library of its own (LGPL-2.1);
# - libjpeg-turbo, built into the backends that need JPEG, like pixma. It's the version minilab
#   builds for itself (`deps/libjpeg-turbo`).
#
# What ends up in <out folder>:
#
#   libsane.1.dylib, libusb-1.0.0.dylib
#   backends/              libsane-<name>.1.so for each backend
#   sane.d/                dll.conf, which says which backends load, and each backend's config
#   README.txt             what this is, the licences, and where the source is
#   LICENSE-*              the licences
#
# The source archives stay in <downloads folder> (a temporary folder if you don't give one), so the
# release can attach them. You need the Xcode command line tools and CMake. The build runs in a
# temporary folder, because libtool breaks on paths with spaces.
set -euo pipefail

sane_version=1.4.0
sane_url=https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-$sane_version.tar.gz
sane_sha256=f99205c903dfe2fb8990f0c531232c9a00ec9c2c66ac7cb0ce50b4af9f407a72
usb_version=1.0.30
usb_url=https://github.com/libusb/libusb/releases/download/v$usb_version/libusb-$usb_version.tar.bz2
usb_sha256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
jpeg_version=3.2.0
jpeg_url=https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$jpeg_version/libjpeg-turbo-$jpeg_version.tar.gz
jpeg_sha256=6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e

# Most backends carry SANE's exception to the GPL, which lets programs that aren't under the GPL use
# them. These don't, and they're under the GPL alone, and the kvs ones have no licence notice at
# all (docs/design.md, section 13, covers why they can still come with minilab). The debug info of
# a build lists the files that went into each backend, so check this again when sane-backends is
# updated.
gpl_only="agfafocus, canon_lide70, coolscan3, epson2, epsonds, genesys, hp4200, kodakaio,
  magicolor, niash, p5, pieusb, s9036, stv680 and tamarack"
no_notice="kvs1025, kvs20xx and kvs40xx"

# The oldest macOS minilab runs on, which is Zig's default for a macOS target.
export MACOSX_DEPLOYMENT_TARGET=15.0

# The paths SANE compiles in point nowhere. minilab tells it where its backends and configs are
# when it loads it.
prefix=/opt/minilab-sane

usage() {
    echo "usage: $0 <arm64|x86_64> <out folder> [<downloads folder>]" >&2
    exit 2
}
[ $# -ge 2 ] || usage
case $1 in
    arm64) arch=arm64 host=aarch64-apple-darwin ;;
    x86_64) arch=x86_64 host=x86_64-apple-darwin ;;
    *) usage ;;
esac
if [ -e "$2" ] && [ -n "$(ls -A "$2")" ]; then
    echo "$2 isn't empty" >&2
    exit 1
fi
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "${3:-$work/downloads}" "$work/src"
downloads=$(cd "${3:-$work/downloads}" && pwd)
deps=$work/deps
jobs=$(sysctl -n hw.ncpu)
flags="-arch $arch -O2"

# Downloads an archive unless it's there already, checks it and unpacks it.
fetch() {
    local url=$1 sha256=$2 file
    file=$downloads/${url##*/}
    [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$url"
    if ! echo "$sha256  $file" | shasum -a 256 -c --status -; then
        echo "$file doesn't match its SHA-256" >&2
        exit 1
    fi
    tar -xf "$file" -C "$work/src"
}
fetch "$sane_url" "$sane_sha256"
fetch "$usb_url" "$usb_sha256"
fetch "$jpeg_url" "$jpeg_sha256"

echo "Building libusb $usb_version for $arch"
(
    cd "$work/src/libusb-$usb_version"
    ./configure --host="$host" --prefix="$deps" --disable-static \
        CFLAGS="$flags" LDFLAGS="-arch $arch -Wl,-headerpad_max_install_names" > "$work/libusb.log"
    make -j"$jobs" install >> "$work/libusb.log"
) || { cat "$work/libusb.log" >&2; exit 1; }

echo "Building libjpeg-turbo $jpeg_version for $arch"
# Without the SIMD code, like minilab's own build, so it doesn't need NASM.
(
    cmake -S "$work/src/libjpeg-turbo-$jpeg_version" -B "$work/jpeg" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$deps" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
    cmake --build "$work/jpeg" -j "$jobs"
    cmake --install "$work/jpeg"
) > "$work/jpeg.log" 2>&1 || { cat "$work/jpeg.log" >&2; exit 1; }

echo "Building sane-backends $sane_version for $arch"
# Everything optional that would come from outside is off, and pkg-config only sees our libusb.
# configure picks every backend that can build without them.
(
    cd "$work/src/sane-backends-$sane_version"
    ./configure --host="$host" --prefix="$prefix" --disable-static --disable-nls --disable-locking \
        --disable-rpath --with-usb --without-gphoto2 --without-v4l --without-avahi --without-snmp \
        --without-systemd --without-libcurl --without-poppler-glib --without-usb-record-replay \
        CFLAGS="$flags" CXXFLAGS="$flags" CPPFLAGS="-I$deps/include" \
        LDFLAGS="-arch $arch -L$deps/lib -Wl,-headerpad_max_install_names" \
        USB_CFLAGS="-I$deps/include/libusb-1.0" USB_LIBS="-L$deps/lib -lusb-1.0" \
        PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig" > "$work/sane.log"
    make -j"$jobs" >> "$work/sane.log"
    make install DESTDIR="$work/stage" >> "$work/sane.log"
) 2> "$work/sane-errors.log" || { tail -50 "$work/sane.log" "$work/sane-errors.log" >&2; exit 1; }

echo "Laying out $out"
stage=$work/stage$prefix
mkdir -p "$out/backends" "$out/sane.d"
cp "$deps/lib/libusb-1.0.0.dylib" "$stage/lib/libsane.1.dylib" "$out/"
# Every backend but dll, which is libsane itself.
cp "$stage/lib/sane/"libsane-*.1.so "$out/backends/"
rm "$out/backends/libsane-dll.1.so"
# dll.conf as it comes, and each backend's config. dll.d stays out: without one here, SANE reads
# the system's, which is where drivers like epkowa are turned on.
cp "$stage/etc/sane.d/"*.conf "$out/sane.d/"
rm "$out/sane.d/saned.conf"

# The libraries find libusb next to libsane, through their rpath.
usb_id=$(otool -D "$out/libusb-1.0.0.dylib" | sed -n 2p)
install_name_tool -id @rpath/libusb-1.0.0.dylib "$out/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libsane.1.dylib -change "$usb_id" @rpath/libusb-1.0.0.dylib \
    -add_rpath @loader_path "$out/libsane.1.dylib"
for module in "$out"/backends/*.so; do
    install_name_tool -change "$usb_id" @rpath/libusb-1.0.0.dylib -add_rpath @loader_path/.. "$module"
done

# Every file may only use macOS's own libraries and libusb. Then each one gets stripped and signed
# again (ad hoc), since Apple silicon won't load a library whose signature doesn't match it.
for file in "$out"/*.dylib "$out"/backends/*.so; do
    outside=$(otool -L "$file" | awk 'NR > 1 { print $1 }' |
        grep -Ev '^(/usr/lib/|/System/Library/|@rpath/(libusb-1\.0\.0|libsane\.1)\.dylib$)' || true)
    if [ -n "$outside" ]; then
        echo "${file#"$out"/} uses libraries from outside: $outside" >&2
        exit 1
    fi
    strip -x "$file"
    codesign --force --sign - "$file" 2> /dev/null
done

src=$work/src
cp "$src/sane-backends-$sane_version/LICENSE" "$out/LICENSE-sane-backends.txt"
cp "$src/sane-backends-$sane_version/COPYING" "$out/LICENSE-sane-backends-gpl.txt"
cp "$src/libusb-$usb_version/COPYING" "$out/LICENSE-libusb-lgpl.txt"
cp "$src/libjpeg-turbo-$jpeg_version/LICENSE.md" "$out/LICENSE-libjpeg-turbo.md"
cp "$src/libjpeg-turbo-$jpeg_version/README.ijg" "$out/README-libjpeg-turbo.ijg"
cat > "$out/README.txt" << EOF
SANE for minilab

This folder holds SANE, the free scanner drivers minilab uses on macOS, so scanning works without
installing anything. minilab loads it from here when you open Scan.

It's sane-backends $sane_version, libusb $usb_version and libjpeg-turbo $jpeg_version, built for
macOS on $arch by scripts/build-sane-macos.sh in minilab's repository
(https://github.com/vdmkenny/minilab), with no changes to their code.

Licences:

- sane-backends: the GNU GPL (LICENSE-sane-backends-gpl.txt). libsane and most backends carry
  SANE's exception, which lets other programs use them (LICENSE-sane-backends.txt). These
  backends don't, and are under the GPL alone:
  $gpl_only.
  These have no licence notice of their own: $no_notice.
- libusb: the GNU LGPL 2.1 or later (LICENSE-libusb-lgpl.txt). You can swap libusb-1.0.0.dylib
  for your own build of it.
- libjpeg-turbo: the IJG and Modified BSD licences (LICENSE-libjpeg-turbo.md). This software is
  based in part on the work of the Independent JPEG Group.

The source, exactly as it was built:

- $sane_url
  SHA-256 $sane_sha256
- $usb_url
  SHA-256 $usb_sha256
- $jpeg_url
  SHA-256 $jpeg_sha256

The same archives are attached to the minilab release this download comes from.
EOF

echo "Done: $(find "$out/backends" -name '*.so' | wc -l | tr -d ' ') backends, $(du -sh "$out" | cut -f1)"
