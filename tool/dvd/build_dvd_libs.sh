#!/usr/bin/env bash
# Build libdvdcss -> libdvdread (linked against libdvdcss) -> libdvdnav from
# tool/dvd/recipe.env into ONE prefix that both libmpv (-Ddvdnav=enabled) and
# the unified FFmpeg (--enable-libdvdnav --enable-libdvdread) link.
#
# Usage: build_dvd_libs.sh <work-dir> <prefix> [meson-cross-file]
#   <work-dir>   new or empty directory for tarballs, sources and build trees
#   <prefix>     install prefix (lib/pkgconfig/{libdvdcss,dvdread,dvdnav}.pc);
#                on MSYS2 pass it mixed-style (C:/...), it is baked into .pc
#   cross-file   optional meson cross file (Android NDK / Apple SDK / mingw)
#
# Environment:
#   DVD_DEFAULT_LIBRARY  shared (default) or static. Shared is what "one copy"
#                        means on every platform that ships separate libmpv and
#                        FFmpeg binaries; static is only for a single image.
#   DVD_MESON_ARGS       extra meson arguments (space separated)
#
# Every tarball is verified against the recipe SHA256 before it is unpacked.
# The build fails unless libdvdread really linked libdvdcss: without it,
# encrypted discs silently fail to decrypt (libdvdread would otherwise try to
# dlopen a libdvdcss that the app does not ship).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=recipe.env
source "${HERE}/recipe.env"

WORK="${1:?usage: build_dvd_libs.sh <work-dir> <prefix> [meson-cross-file]}"
PREFIX="${2:?usage: build_dvd_libs.sh <work-dir> <prefix> [meson-cross-file]}"
CROSS="${3:-}"
LIBRARY_KIND="${DVD_DEFAULT_LIBRARY:-shared}"
case "${LIBRARY_KIND}" in shared|static) ;; *)
  echo "build_dvd_libs: DVD_DEFAULT_LIBRARY must be shared or static" >&2; exit 2 ;;
esac
for cmd in curl meson ninja pkg-config tar; do
  command -v "${cmd}" >/dev/null || { echo "build_dvd_libs: missing ${cmd}" >&2; exit 2; }
done

mkdir -p "${WORK}"
WORK="$(cd "${WORK}" && pwd)"
# PKG_CONFIG_PATH is ':'-separated; MSYS2 converts only POSIX path lists for
# native programs, so a mixed-style C:/ prefix is turned back into /c/... here.
PKG_DIR="${PREFIX}/lib/pkgconfig"
if command -v cygpath >/dev/null; then
  PKG_DIR="$(cygpath -u "${PKG_DIR}")"
fi
export PKG_CONFIG_PATH="${PKG_DIR}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
# A cross build must only ever see the target's .pc files.
if [ -n "${CROSS}" ]; then
  export PKG_CONFIG_LIBDIR="${PKG_DIR}"
fi

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# fetch <url> <sha256> -> path of the unpacked source directory on stdout
fetch() {
  local url="$1" want="$2" tarball got name
  tarball="${WORK}/$(basename "${url}")"
  if [ ! -f "${tarball}" ]; then
    curl --fail --location --silent --show-error --retry 3 -o "${tarball}.part" "${url}"
    mv "${tarball}.part" "${tarball}"
  fi
  got="$(sha256_of "${tarball}")"
  if [ "${got}" != "${want}" ]; then
    echo "build_dvd_libs: SHA256 mismatch for ${url}: ${got} != ${want}" >&2
    exit 3
  fi
  name="$(basename "${url}" .tar.xz)"
  rm -rf "${WORK:?}/src/${name}"
  mkdir -p "${WORK}/src"
  tar -xJf "${tarball}" -C "${WORK}/src"
  # Fushi patches: tool/dvd/patches/<library>/*.patch, applied in order.
  local patch_dir="${HERE}/patches/${name%-*}" p
  for p in "${patch_dir}"/*.patch; do
    [ -e "${p}" ] || continue
    if command -v patch >/dev/null; then
      patch -d "${WORK}/src/${name}" -p1 --quiet < "${p}" >&2
    else
      (cd "${WORK}/src/${name}" && git apply -p1 "${p}") >&2
    fi
  done
  echo "${WORK}/src/${name}"
}

# build <name> <source-dir> [meson options...]
build() {
  local name="$1" src="$2"
  shift 2
  local dir="${WORK}/build/${name}"
  rm -rf "${dir}"
  local args=(
    --prefix="${PREFIX}"
    --libdir=lib
    --buildtype=release
    --default-library="${LIBRARY_KIND}"
    -Denable_docs=false
  )
  [ -n "${CROSS}" ] && args+=(--cross-file="${CROSS}")
  # shellcheck disable=SC2206
  [ -n "${DVD_MESON_ARGS:-}" ] && args+=(${DVD_MESON_ARGS})
  meson setup "${dir}" "${src}" "${args[@]}" "$@"
  ninja -C "${dir}"
  ninja -C "${dir}" install
}

css_src="$(fetch "${LIBDVDCSS_URL}" "${LIBDVDCSS_SHA256}")"
read_src="$(fetch "${LIBDVDREAD_URL}" "${LIBDVDREAD_SHA256}")"
nav_src="$(fetch "${LIBDVDNAV_URL}" "${LIBDVDNAV_SHA256}")"

build libdvdcss "${css_src}"
build libdvdread "${read_src}" -Dlibdvdcss=enabled
build libdvdnav "${nav_src}" -Denable_examples=false

# libdvdread decrypts only when it was compiled against libdvdcss; a build that
# silently fell back to dlopen would play unencrypted discs only.
if ! grep -q 'HAVE_DVDCSS_DVDCSS_H' "${WORK}/build/libdvdread/config.h"; then
  echo "build_dvd_libs: libdvdread was not built against libdvdcss" >&2
  exit 4
fi
for pc in libdvdcss:"${LIBDVDCSS_VERSION}" dvdread:"${LIBDVDREAD_VERSION}" dvdnav:"${LIBDVDNAV_VERSION}"; do
  got="$(pkg-config --modversion "${pc%%:*}")"
  if [ "${got}" != "${pc#*:}" ]; then
    echo "build_dvd_libs: ${pc%%:*} resolves to ${got}, recipe says ${pc#*:}" >&2
    exit 5
  fi
done
mkdir -p "${PREFIX}/share/licenses/fushi-dvd"
cp "${css_src}/COPYING" "${PREFIX}/share/licenses/fushi-dvd/libdvdcss-COPYING"
cp "${read_src}/COPYING" "${PREFIX}/share/licenses/fushi-dvd/libdvdread-COPYING"
cp "${nav_src}/COPYING" "${PREFIX}/share/licenses/fushi-dvd/libdvdnav-COPYING"
echo "build_dvd_libs: libdvdcss ${LIBDVDCSS_VERSION}, libdvdread ${LIBDVDREAD_VERSION}" \
  "(+libdvdcss), libdvdnav ${LIBDVDNAV_VERSION} -> ${PREFIX} (${LIBRARY_KIND})"
