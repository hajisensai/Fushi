#!/usr/bin/env bash
set -euo pipefail

: "${FUSHIDICTS_SOURCE_DIR:?FUSHIDICTS_SOURCE_DIR is not set}"
: "${FUSHIDICTS_BUILD_DIR:?FUSHIDICTS_BUILD_DIR is not set}"
: "${FUSHIDICTS_MERGED_ARCHIVE:?FUSHIDICTS_MERGED_ARCHIVE is not set}"

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

cache="$FUSHIDICTS_BUILD_DIR/CMakeCache.txt"
if [[ -f "$cache" ]]; then
  cached_generator="$(sed -n 's/^CMAKE_GENERATOR:INTERNAL=//p' "$cache" | head -n 1)"
  cached_archs="$(sed -n 's/^CMAKE_OSX_ARCHITECTURES:.*=//p' "$cache" | head -n 1)"
  cached_sysroot="$(sed -n 's/^CMAKE_OSX_SYSROOT:.*=//p' "$cache" | head -n 1)"
  if [[ "$cached_generator" != "Unix Makefiles" ||
        "$cached_archs" != "$cmake_archs" ||
        "$cached_sysroot" != "$cmake_sysroot" ]]; then
    rm -rf "$FUSHIDICTS_BUILD_DIR"
  fi
fi

cmake -S "$FUSHIDICTS_SOURCE_DIR" -B "$FUSHIDICTS_BUILD_DIR" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$cmake_sysroot" \
  -DCMAKE_OSX_ARCHITECTURES="$cmake_archs" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.1}"
cmake --build "$FUSHIDICTS_BUILD_DIR" --target fushidicts_ffi --config "$CONFIGURATION"

if [[ ! -f "$FUSHIDICTS_MERGED_ARCHIVE" ]]; then
  echo "error: $FUSHIDICTS_MERGED_ARCHIVE was not produced" >&2
  exit 1
fi
