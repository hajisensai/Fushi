#!/usr/bin/env bash
set -euo pipefail

: "${HOSHIDICTS_SOURCE_DIR:?HOSHIDICTS_SOURCE_DIR is not set}"
: "${HOSHIDICTS_BUILD_DIR:?HOSHIDICTS_BUILD_DIR is not set}"
: "${HOSHIDICTS_MERGED_ARCHIVE:?HOSHIDICTS_MERGED_ARCHIVE is not set}"

# Homebrew cmake is not on Xcode's default PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

cmake_archs=""
for arch in ${ARCHS:-arm64}; do
  [[ -z "$arch" ]] && continue
  case ";$cmake_archs;" in
    *";$arch;"*) ;;
    *) cmake_archs="${cmake_archs:+$cmake_archs;}$arch" ;;
  esac
done
if [[ -z "$cmake_archs" ]]; then
  cmake_archs="arm64"
fi

cmake_sysroot="${SDKROOT:-}"
if [[ -z "$cmake_sysroot" || "$cmake_sysroot" != /* ]]; then
  cmake_sysroot="$(xcrun --sdk "${PLATFORM_NAME:-iphoneos}" --show-sdk-path)"
fi

cache="$HOSHIDICTS_BUILD_DIR/CMakeCache.txt"
if [[ -f "$cache" ]]; then
  cached_generator="$(sed -n 's/^CMAKE_GENERATOR:INTERNAL=//p' "$cache" | head -n 1)"
  cached_archs="$(sed -n 's/^CMAKE_OSX_ARCHITECTURES:.*=//p' "$cache" | head -n 1)"
  cached_sysroot="$(sed -n 's/^CMAKE_OSX_SYSROOT:.*=//p' "$cache" | head -n 1)"
  if [[ "$cached_generator" != "Unix Makefiles" ||
        "$cached_archs" != "$cmake_archs" ||
        "$cached_sysroot" != "$cmake_sysroot" ]]; then
    rm -rf "$HOSHIDICTS_BUILD_DIR"
  fi
fi

cmake -S "$HOSHIDICTS_SOURCE_DIR" -B "$HOSHIDICTS_BUILD_DIR" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$cmake_sysroot" \
  -DCMAKE_OSX_ARCHITECTURES="$cmake_archs" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
cmake --build "$HOSHIDICTS_BUILD_DIR" --target hoshidicts_ffi --config "$CONFIGURATION"

if [[ ! -f "$HOSHIDICTS_MERGED_ARCHIVE" ]]; then
  echo "error: $HOSHIDICTS_MERGED_ARCHIVE was not produced" >&2
  exit 1
fi
