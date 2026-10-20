#!/usr/bin/env bash
set -euo pipefail

# One-command setup for a fresh checkout. Collapses the manual pre-build steps
# (flutter pub get -> apply pub-cache patches) into a single entry point so
# "git clone + tool/bootstrap.sh + flutter build" works.
#
# Use this when you are NOT going through `melos bootstrap` (which runs the same
# follow-up steps via its post hook). CI invokes `flutter pub get` +
# `ci/apply-patches.sh` directly and does not need this wrapper.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "==> flutter pub get (fushi/)"
(cd fushi && flutter pub get)

echo "==> Applying pub-cache patches"
bash ci/apply-patches.sh

# native/fushi_compute（Rust 计算内核）是 app 与 flutter test 的硬依赖：CMake / Xcode /
# Gradle 缺库都直接构建失败。按主机平台编一次；没有 cargo 就失败。
# 显式跳过：FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1（之后手动跑对应的 build_* 脚本）。
if [ -n "${FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE:-}" ]; then
  echo "WARNING: skipped native/fushi_compute and native/fushi_rwkv (both required); run their build_<platform> scripts before flutter build/test" >&2
else
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. native/fushi_compute (Rust compute kernel) is a required native dependency;" >&2
    echo "       install Rust (https://rustup.rs) and re-run, or set FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1 to skip explicitly." >&2
    exit 1
  fi
  case "$(uname -s)" in
    Darwin) echo "==> native/fushi_compute (macOS arm64 dylib)"; bash native/fushi_compute/build_macos_dylib.sh ;;
    *) echo "==> native/fushi_compute (Linux x64 .so)"; bash native/fushi_compute/build_linux_so.sh ;;
  esac
  # native/fushi_rwkv（RWKV-Instant 排程推理，AGPL-3.0-or-later）同为硬依赖；同一个跳过开关。
  case "$(uname -s)" in
    Darwin) echo "==> native/fushi_rwkv (macOS arm64 dylib)"; bash native/fushi_rwkv/build_macos_dylib.sh ;;
    *) echo "==> native/fushi_rwkv (Linux x64 .so)"; bash native/fushi_rwkv/build_linux_so.sh ;;
  esac
fi

echo ""
echo "Bootstrap complete. Build with, e.g.:"
echo "  cd fushi && flutter build apk --release --split-per-abi"
