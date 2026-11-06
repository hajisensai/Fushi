#!/bin/bash
# Merge the fushidicts iOS static archives into one self-contained archive that
# the iOS Runner Xcode target force_loads, so the FFI symbols land in the Runner
# executable image (where Dart's DynamicLibrary.process() resolves them).
#
# Invoked as a POST_BUILD step on the CMake fushidicts_ffi target. The iOS build
# uses CMake's default single-config generator (matching macOS), so every
# archive lands at a flat, deterministic path under the build dir. Args:
#   $1 = CMAKE_BINARY_DIR
#   $2 = output merged archive path
set -euo pipefail

binary_dir="$1"
out="$2"

deps=(
  "$binary_dir/libfushidicts_ffi.a"
  "$binary_dir/libfushidicts.a"
  "$binary_dir/fushidicts_external/zstd/build/cmake/lib/libzstd.a"
  "$binary_dir/fushidicts_external/libdeflate/libdeflate.a"
  "$binary_dir/fushidicts_external/utf8proc/libutf8proc.a"
)

for a in "${deps[@]}"; do
  if [[ ! -f "$a" ]]; then
    echo "error: missing static archive for merge: $a" >&2
    exit 1
  fi
done

# One archive alone is not enough: the vendored zstd / libdeflate / utf8proc keep
# their global C names, and the Runner also force_loads the Rust umbrella
# (native/fushi_ios_umbrella), whose zstd-sys carries another zstd. Two copies of
# ZSTD_* in one static link = "duplicate symbols". So prelink everything into a
# single relocatable object per architecture (what Xcode calls single-object
# prelink): only the Dart FFI entry points (fushidicts_*) stay global, every
# other symbol becomes local to this object and can never collide again.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
libtool -static -o "$work/all.a" "${deps[@]}"
echo '_fushidicts_*' > "$work/exports.txt"

sdk="${PLATFORM_NAME:-iphoneos}"
min="${IPHONEOS_DEPLOYMENT_TARGET:-15.1}"
suffix=""
[[ "$sdk" == iphonesimulator ]] && suffix="-simulator"
archs="$(lipo -archs "$work/all.a")"
thin=()
for arch in $archs; do
  src="$work/all.a"
  if [[ "$(echo "$archs" | wc -w)" -gt 1 ]]; then
    src="$work/all-$arch.a"
    lipo -thin "$arch" "$work/all.a" -output "$src"
  fi
  # Through the clang driver, not bare ld: ld needs -platform_version, which
  # clang derives from the target triple.
  xcrun --sdk "$sdk" clang -r -nostdlib -target "$arch-apple-ios$min$suffix" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -Wl,-exported_symbols_list,"$work/exports.txt" \
    -Wl,-force_load,"$src" -o "$work/fushidicts-$arch.o"
  libtool -static -o "$work/fushidicts-$arch.a" "$work/fushidicts-$arch.o"
  thin+=("$work/fushidicts-$arch.a")
done
rm -f "$out"
if [[ "${#thin[@]}" -gt 1 ]]; then
  lipo -create "${thin[@]}" -output "$out"
else
  cp "${thin[0]}" "$out"
fi

# Gate: the merged archive must export exactly the FFI surface, at least the
# entry points the Dart bindings look up, and nothing else (no ZSTD_*, deflate_*).
# Tentative (common) definitions are exempt: ld -r keeps them global, but the
# final link merges same-named commons instead of reporting duplicates (zstd's
# g_ZSTD_threading_useless_symbol is the only one).
leaked="$(nm -gU -m "$out" 2>/dev/null | grep -v '(common)' | awk 'NF >= 3 { print $NF }' | grep -v '^_fushidicts_' | sort -u || true)"
if [[ -n "$leaked" ]]; then
  echo "error: fushidicts iOS archive still exports non-FFI symbols: $(echo "$leaked" | head -n 20 | tr '\n' ' ')" >&2
  exit 1
fi
count="$(nm -gU "$out" 2>/dev/null | awk 'NF >= 3 { print $NF }' | grep -c '^_fushidicts_' || true)"
if [[ "$count" -lt 30 ]]; then
  echo "error: fushidicts iOS archive exports only $count fushidicts_* symbols (<30)" >&2
  exit 1
fi
echo "merged fushidicts iOS archive -> $out ($count fushidicts_* symbols global, everything else local)"
