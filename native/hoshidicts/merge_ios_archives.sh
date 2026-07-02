#!/bin/bash
# Merge the hoshidicts iOS static archives into one self-contained archive that
# the iOS Runner Xcode target force_loads, so the FFI symbols land in the Runner
# executable image (where Dart's DynamicLibrary.process() resolves them).
#
# Invoked as a POST_BUILD step on the CMake hoshidicts_ffi target. The iOS build
# uses CMake's default single-config generator (matching macOS), so every
# archive lands at a flat, deterministic path under the build dir. Args:
#   $1 = CMAKE_BINARY_DIR
#   $2 = output merged archive path
set -euo pipefail

binary_dir="$1"
out="$2"

deps=(
  "$binary_dir/libhoshidicts_ffi.a"
  "$binary_dir/libhoshidicts.a"
  "$binary_dir/hoshidicts_external/zstd/build/cmake/lib/libzstd.a"
  "$binary_dir/hoshidicts_external/libdeflate/libdeflate.a"
  "$binary_dir/hoshidicts_external/utf8proc/libutf8proc.a"
)

for a in "${deps[@]}"; do
  if [[ ! -f "$a" ]]; then
    echo "error: missing static archive for merge: $a" >&2
    exit 1
  fi
done

libtool -static -o "$out" "${deps[@]}"
echo "merged hoshidicts iOS archive -> $out"
