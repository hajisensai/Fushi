#!/usr/bin/env bash
set -euo pipefail

: "${AIDOKU_RUNTIME_SOURCE_DIR:?AIDOKU_RUNTIME_SOURCE_DIR is required}"
: "${AIDOKU_RUNTIME_BUILD_DIR:?AIDOKU_RUNTIME_BUILD_DIR is required}"
: "${AIDOKU_RUNTIME_ARCHIVE:?AIDOKU_RUNTIME_ARCHIVE is required}"

if [[ "${PLATFORM_NAME:-}" != "iphoneos" ]]; then
  echo "error: Aidoku embedded runtime is configured for a physical iOS device build (iphoneos), got ${PLATFORM_NAME:-unknown}." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build the embedded Aidoku runtime." >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required to verify the physical-device Rust target." >&2
  exit 1
fi

rust_target="aarch64-apple-ios"
if ! rustup target list --installed | grep -qx "$rust_target"; then
  echo "error: Rust target $rust_target is not installed. Install that device target explicitly; this build script never downloads toolchains or Simulator components." >&2
  exit 1
fi

profile="debug"
profile_args=(--profile dev)
case "${CONFIGURATION:-Debug}" in
  Release|Profile)
    profile="release"
    profile_args=(--release)
    ;;
esac

target_dir="$AIDOKU_RUNTIME_BUILD_DIR/target"
mkdir -p "$AIDOKU_RUNTIME_BUILD_DIR"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.1}"

CARGO_TARGET_DIR="$target_dir" cargo build \
  --manifest-path "$AIDOKU_RUNTIME_SOURCE_DIR/Cargo.toml" \
  --lib \
  --no-default-features \
  --features embedded \
  --target "$rust_target" \
  --locked \
  "${profile_args[@]}"

install -m 0644 \
  "$target_dir/$rust_target/$profile/libfushi_aidoku_runtime.a" \
  "$AIDOKU_RUNTIME_ARCHIVE"
