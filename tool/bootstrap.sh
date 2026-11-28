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

# Prebuilt third-party binaries (libmpv / ANGLE / libplacebo / FFmpegKit / LunaHook / jogamp ...)
# are not in git: tool/vendored_binaries.json pins them, this restores + verifies them
# (cached under ~/.cache/fushi/vendored-binaries; honours HTTPS_PROXY).
echo "==> vendored binaries"
if command -v python3 >/dev/null 2>&1 && python3 -c '' >/dev/null 2>&1; then
  python3 tool/vendored_binaries.py fetch
else
  python tool/vendored_binaries.py fetch
fi

echo "==> flutter pub get (fushi/)"
(cd fushi && flutter pub get)

echo "==> Applying pub-cache patches"
bash ci/apply-patches.sh

# fushi/lib/i18n/strings.g.dart is not tracked: generate it from the i18n json
# (stamped, a no-op when nothing changed).
echo "==> Generating i18n (fushi/tool/gen_i18n.dart)"
# The SDK pub get just used (flutter on PATH), not some other dart on PATH.
"$(dirname "$(command -v flutter)")/dart" fushi/tool/gen_i18n.dart
# A later branch switch / merge deletes or outdates it again: post-checkout /
# post-merge hooks regenerate it (marked block, existing hook lines kept).
echo "==> git hooks (tool/git_hooks/install.sh)"
sh tool/git_hooks/install.sh

# Rust 原生库（登记表 native/crates.json 里 `host_test_lib: true` 的 crate，经 tool/native_crates.py 读）是 app 与
# flutter test 的硬依赖：CMake / Xcode / Gradle 缺库直接构建失败，测试成片报库不可用。按主机平台各编一次；没有 cargo 就失败。
# （Windows 的 tool/native_libs.ps1 读同一份登记表，还会复用兄弟 worktree 的同源码产物；这里只编。）
# 登记表的 test_features（fushi_fsrs 的 raw_sql：测试专用的原始 SQL 通道，native/fushi_fsrs/Cargo.toml）经 FUSHI_FSRS_FEATURES
# 交给构建脚本：这份库同时给 flutter test 与本机 flutter run / build 用，所以本机自己编的 app 带它（与 tool/native_libs.ps1 同口径）。
# 出发布包的调用方（tool/linux/build_bundle.sh）设 FUSHI_RELEASE_NATIVE=1：不带，并在出包前核对（verify_raw_sql.sh absent）。
# `id_audit: true` 的 crate 另编一份带 ID 审计的库给调试构建 / 测试宿主（FUSHI_FSRS_ID_AUDIT_VARIANT=1，不随包，见脚本头）。
# 显式跳过：FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1（之后手动跑对应的 build_* 脚本）。
py=python3
python3 -c '' >/dev/null 2>&1 || py=python
native_crates="$("$py" tool/native_crates.py list --host-test | tr '\n' ' ')"
if [ -n "${FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE:-}" ]; then
  echo "WARNING: skipped native/{${native_crates% }} (required); run native/<crate>/build_<platform> before flutter build/test" >&2
else
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. native/{${native_crates% }} (Rust) are required native dependencies;" >&2
    echo "       install Rust (https://rustup.rs) and re-run, or set FUSHI_BOOTSTRAP_SKIP_NATIVE_COMPUTE=1 to skip explicitly." >&2
    exit 1
  fi
  case "$(uname -s)" in
    Darwin) platform=macos; echo "==> native Rust libraries (macOS arm64 dylib)" ;;
    *) platform=linux; echo "==> native Rust libraries (Linux x64 .so)" ;;
  esac
  for crate in $native_crates; do
    script="$("$py" tool/native_crates.py get "$crate" "build.$platform")"
    features="$("$py" tool/native_crates.py get "$crate" test_features)"
    build_env=()
    if [ -n "$features" ]; then
      # 发布包不带测试 feature；显式置空，不继承调用方环境里的值。
      if [ "${FUSHI_RELEASE_NATIVE:-}" = 1 ]; then features=""; fi
      build_env+=("FUSHI_FSRS_FEATURES=$features")
    fi
    if [ "$("$py" tool/native_crates.py get "$crate" id_audit)" = true ]; then build_env+=(FUSHI_FSRS_ID_AUDIT_VARIANT=1); fi
    env ${build_env[@]+"${build_env[@]}"} bash "native/$crate/$script"
  done
fi

echo ""
echo "Bootstrap complete. Build with, e.g.:"
echo "  cd fushi && flutter build apk --release --split-per-abi"
