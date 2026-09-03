#!/usr/bin/env bash
set -euo pipefail

: "${AIDOKU_RUNTIME_SOURCE_DIR:?AIDOKU_RUNTIME_SOURCE_DIR is required}"
: "${AIDOKU_RUNTIME_BUILD_DIR:?AIDOKU_RUNTIME_BUILD_DIR is required}"
: "${AIDOKU_RUNTIME_ARCHIVE:?AIDOKU_RUNTIME_ARCHIVE is required}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build the embedded Aidoku runtime." >&2
  exit 1
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required to verify the Rust target." >&2
  exit 1
fi

# BUG-1692：模拟器曾被硬性拒绝（脚本只认 iphoneos，其余 `exit 1`），于是 iOS 集成
# 测试在模拟器上**完全跑不起来**——查词 / 阅读器等与漫画源无关的用例也一并被挡在
# 构建阶段，iOS 侧的真机验证因此长期缺位。
#
# 改为按 PLATFORM_NAME + ARCHS 逐架构构建再 lipo 合并：Xcode 模拟器构建常传
# `ARCHS=arm64 x86_64`（通用），只挑其中一个会让另一半在链接期缺符号。
# 仍然只**校验**目标是否已安装、绝不自动下载工具链或 Simulator 组件
# （保持原脚本的显式安装契约）。
rust_targets=()
case "${PLATFORM_NAME:-}" in
  iphoneos)
    for arch in ${ARCHS:-arm64}; do
      case "$arch" in
        arm64|arm64e) rust_targets+=("aarch64-apple-ios") ;;
        *)
          echo "error: unsupported device arch '$arch' for the Aidoku runtime." >&2
          exit 1
          ;;
      esac
    done
    ;;
  iphonesimulator)
    for arch in ${ARCHS:-arm64}; do
      case "$arch" in
        arm64|arm64e) rust_targets+=("aarch64-apple-ios-sim") ;;
        x86_64) rust_targets+=("x86_64-apple-ios") ;;
        *)
          echo "error: unsupported simulator arch '$arch' for the Aidoku runtime." >&2
          exit 1
          ;;
      esac
    done
    ;;
  *)
    echo "error: Aidoku embedded runtime supports iphoneos / iphonesimulator, got ${PLATFORM_NAME:-unknown}." >&2
    exit 1
    ;;
esac

# 去重（ARCHS 可能把 arm64/arm64e 都列上，二者映射到同一个 Rust target）。
deduped=()
for t in "${rust_targets[@]}"; do
  seen=0
  for existing in "${deduped[@]:-}"; do
    [[ "$existing" == "$t" ]] && seen=1 && break
  done
  [[ $seen -eq 0 ]] && deduped+=("$t")
done
rust_targets=("${deduped[@]}")

for rust_target in "${rust_targets[@]}"; do
  if ! rustup target list --installed | grep -qx "$rust_target"; then
    echo "error: Rust target $rust_target is not installed (PLATFORM_NAME=${PLATFORM_NAME}, ARCHS=${ARCHS:-arm64}). Install it explicitly with \`rustup target add $rust_target\`; this build script never downloads toolchains or Simulator components." >&2
    exit 1
  fi
done

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

built_archives=()
for rust_target in "${rust_targets[@]}"; do
  CARGO_TARGET_DIR="$target_dir" cargo build \
    --manifest-path "$AIDOKU_RUNTIME_SOURCE_DIR/Cargo.toml" \
    --lib \
    --no-default-features \
    --features embedded \
    --target "$rust_target" \
    --locked \
    "${profile_args[@]}"
  built_archives+=("$target_dir/$rust_target/$profile/libfushi_aidoku_runtime.a")
done

if [[ ${#built_archives[@]} -eq 1 ]]; then
  install -m 0644 "${built_archives[0]}" "$AIDOKU_RUNTIME_ARCHIVE"
else
  # 通用构建：把各架构静态库合成一个 fat archive，供链接器按需取用。
  lipo -create "${built_archives[@]}" -output "$AIDOKU_RUNTIME_ARCHIVE"
  chmod 0644 "$AIDOKU_RUNTIME_ARCHIVE"
fi
