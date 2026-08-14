#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  exit 64
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
manifest="$repository_root/native/aidoku_runtime/Cargo.toml"
output_parent="$(cd "$(dirname "$1")" && pwd)"
output_directory="$output_parent/$(basename "$1")"

case "$output_directory" in
  /|"")
    echo "refusing to write the Aidoku runtime to a filesystem root" >&2
    exit 64
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build_macos_runtime.sh must run on macOS" >&2
  exit 1
fi

cargo build --locked --release --manifest-path "$manifest"
binary="$repository_root/native/aidoku_runtime/target/release/fushi-aidoku-runtime"
if [[ ! -x "$binary" ]]; then
  echo "Aidoku runtime binary was not produced at $binary" >&2
  exit 1
fi

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/fushi-aidoku-runtime.XXXXXX")"
trap 'rm -rf -- "$staging_directory"' EXIT

install -m 755 "$binary" "$staging_directory/fushi-aidoku-runtime"
install -m 644 \
  "$repository_root/native/aidoku_runtime/LICENSE-AIDOKU-RS" \
  "$staging_directory/LICENSE-AIDOKU-RS.txt"
install -m 644 \
  "$repository_root/native/aidoku_runtime/NOTICE" \
  "$staging_directory/NOTICE-AIDOKU-RUNTIME.txt"

binary_sha256="$(shasum -a 256 "$staging_directory/fushi-aidoku-runtime" | awk '{print $1}')"
aidoku_revision="1a6bb691dd67c7151fc76fc852fb5a364d325f72"
printf '%s\n' \
  '{' \
  '  "protocolVersion": 1,' \
  "  \"aidokuRsRevision\": \"$aidoku_revision\"," \
  "  \"runtimeSha256\": \"$binary_sha256\"" \
  '}' >"$staging_directory/checksums.json"

mkdir -p "$output_directory"
install -m 755 \
  "$staging_directory/fushi-aidoku-runtime" \
  "$output_directory/fushi-aidoku-runtime"
install -m 644 "$staging_directory/LICENSE-AIDOKU-RS.txt" "$output_directory/LICENSE-AIDOKU-RS.txt"
install -m 644 "$staging_directory/NOTICE-AIDOKU-RUNTIME.txt" "$output_directory/NOTICE-AIDOKU-RUNTIME.txt"
install -m 644 "$staging_directory/checksums.json" "$output_directory/checksums.json"

file "$output_directory/fushi-aidoku-runtime"
