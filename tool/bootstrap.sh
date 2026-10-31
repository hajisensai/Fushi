#!/usr/bin/env bash
set -euo pipefail

# One-command setup for a fresh checkout. Collapses the manual pre-build steps
# (flutter pub get -> apply pub-cache patches) into a single entry point so
# "git clone + tool/bootstrap.sh + flutter build" works.
#
# Use this when you are NOT going through `melos bootstrap` (which runs the same
# follow-up steps via its post hook). CI invokes `flutter pub get` +
# `ci/apply-patches.sh` + the .github/actions/gen-i18n action directly and
# does not need this wrapper.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "==> flutter pub get (fushi/)"
(cd fushi && flutter pub get)

echo "==> Applying pub-cache patches"
bash ci/apply-patches.sh

# fushi/lib/i18n/strings.g.dart is not tracked: generate it from the i18n json
# (stamped, a no-op when nothing changed).
echo "==> Generating i18n (fushi/tool/gen_i18n.dart)"
# The SDK pub get just used (flutter on PATH), not some other dart on PATH.
"$(dirname "$(command -v flutter)")/dart" fushi/tool/gen_i18n.dart

# Rust 原生库 native/fushi_compute / fushi_fsrs / fushi_web_core / fushi_rwkv / fushi_music / fushi_corpus 是 app 与 flutter test 的硬依赖：
# CMake / Xcode / Gradle 缺库直接构建失败，测试成片报库不可用。按主机平台各编一次；没有 cargo 就失败。
# （Windows 的 tool/native_libs.ps1 还会复用兄弟 worktree 的同源码产物；这里只编。与它的 crate 清单保持一致。）
# fushi_rwkv 是 RWKV-Instant 排程推理（AGPL-3.0-or-later）。
# 显式跳过：FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1（之后手动跑对应的 build_* 脚本）。
if [ -n "${FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE:-}" ]; then
  echo "WARNING: skipped native/fushi_compute, fushi_fsrs, fushi_web_core, fushi_rwkv, fushi_music, fushi_corpus (required); run native/<crate>/build_<platform> before flutter build/test" >&2
else
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. native/fushi_compute, fushi_fsrs, fushi_web_core, fushi_rwkv, fushi_music, fushi_corpus (Rust) are required native dependencies;" >&2
    echo "       install Rust (https://rustup.rs) and re-run, or set FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1 to skip explicitly." >&2
    exit 1
  fi
  case "$(uname -s)" in
    Darwin)
      echo "==> native Rust libraries (macOS arm64 dylib)"
      bash native/fushi_compute/build_macos_dylib.sh
      bash native/fushi_fsrs/build_macos_dylib.sh
      bash native/fushi_web_core/build_macos_dylib.sh
      bash native/fushi_rwkv/build_macos_dylib.sh
      bash native/fushi_music/build_macos_dylib.sh
      bash native/fushi_corpus/build_macos_dylib.sh
      ;;
    *)
      echo "==> native Rust libraries (Linux x64 .so)"
      bash native/fushi_compute/build_linux_so.sh
      bash native/fushi_fsrs/build_linux_so.sh
      bash native/fushi_web_core/build_linux_so.sh
      bash native/fushi_rwkv/build_linux_so.sh
      bash native/fushi_music/build_linux_so.sh
      bash native/fushi_corpus/build_linux_so.sh
      ;;
  esac
fi

echo ""
echo "Bootstrap complete. Build with, e.g.:"
echo "  cd fushi && flutter build apk --release --split-per-abi"
