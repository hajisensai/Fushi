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

# BUG-1922 / BUG-1668：`flutter build macos` 出的 fushi.app 是 universal
# （ARCHS_STANDARD = arm64 + x86_64），而裸 `cargo build --release` 只出 runner
# 的 host 架构。发布 runner 是 Apple Silicon，所以一份 arm64-only 的 helper 在 CI
# 上一路全绿，到了 Intel Mac 上被内核以 EBADARCH 拒掉 —— app 本体照常启动，表现
# 为「漫画源莫名其妙全废」。默认因此出 universal；本地开发想省时间才用
# FUSHI_AIDOKU_ARCHS=host（与 tool/mihon 的 FUSHI_MIHON_ARCHS 同形）。
requested_archs="${FUSHI_AIDOKU_ARCHS:-universal}"
case "$requested_archs" in
  universal)
    rust_targets=(aarch64-apple-darwin x86_64-apple-darwin)
    ;;
  host)
    case "$(uname -m)" in
      arm64) rust_targets=(aarch64-apple-darwin) ;;
      x86_64) rust_targets=(x86_64-apple-darwin) ;;
      *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "FUSHI_AIDOKU_ARCHS must be 'universal' or 'host', got '$requested_archs'" >&2
    exit 64
    ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build the Aidoku runtime." >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required to verify the Rust targets." >&2
  exit 1
fi

# 只校验、绝不自动安装工具链（与 fushi/ios/build_aidoku_runtime.sh 的显式安装
# 契约一致）：调用方负责 `rustup target add`。
for rust_target in "${rust_targets[@]}"; do
  if ! rustup target list --installed | grep -qx "$rust_target"; then
    echo "error: Rust target $rust_target is not installed. Install it explicitly with 'rustup target add $rust_target'; this build script never downloads toolchains." >&2
    exit 1
  fi
done

built_binaries=()
for rust_target in "${rust_targets[@]}"; do
  cargo build --locked --release --manifest-path "$manifest" --target "$rust_target"
  binary="$repository_root/native/aidoku_runtime/target/$rust_target/release/fushi-aidoku-runtime"
  if [[ ! -x "$binary" ]]; then
    echo "Aidoku runtime binary was not produced at $binary" >&2
    exit 1
  fi
  built_binaries+=("$binary")
done

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/fushi-aidoku-runtime.XXXXXX")"
trap 'rm -rf -- "$staging_directory"' EXIT

if [[ ${#built_binaries[@]} -eq 1 ]]; then
  install -m 755 "${built_binaries[0]}" "$staging_directory/fushi-aidoku-runtime"
else
  lipo -create "${built_binaries[@]}" -output "$staging_directory/fushi-aidoku-runtime"
  chmod 755 "$staging_directory/fushi-aidoku-runtime"
fi
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
lipo -archs "$output_directory/fushi-aidoku-runtime"
