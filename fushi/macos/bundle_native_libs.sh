#!/usr/bin/env bash
# Xcode 构建阶段「Bundle native libraries」：把登记表 native/crates.json 里 macOS 上 bundled_by=app 的
# 原生库（native/<crate>/prebuilt/macos/<产物>，各 crate 的 build_macos_dylib.sh 产出）拷进
# Contents/Frameworks（Runner 的 LD_RUNPATH_SEARCH_PATHS 含 @executable_path/../Frameworks，Dart 侧按裸名
# 或 <exe>/../Frameworks 绝对路径加载）。清单与缺库语义只取自登记表（tool/native_crates.py bundle macos），
# 本脚本不列 crate 名；与 Windows / Linux（native/fushi_native_libs.cmake）同一份判据：
#   always   缺库本阶段失败、整个构建失败（没有 Dart 回退；Mac 上构建 app 前必须先装 Rust 编它）；
#   release  Profile/Release 缺库失败，Debug 只告警（运行时用到时如实报错）；
#   optional 有则随包，缺失时 note 一行（登记表 fallback 写明降级的是什么）。
# 上一次构建拷进去的旧库在缺库时一律删掉，不能留着冒充本次产物。发布流水线（release-desktop.yml /
# build-multiplatform.yml）先跑构建脚本，出包后再核对。libaacs 从源码编，另有 bundle_fushi_aacs.sh。
set -euo pipefail

repo="${PROJECT_DIR}/../.."
destination_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
py=python3
command -v python3 >/dev/null 2>&1 || py=/usr/bin/python3
listing="$("$py" "$repo/tool/native_crates.py" bundle macos)"
[[ -n "$listing" ]] || { echo "error: tool/native_crates.py bundle macos listed nothing (native/crates.json)" >&2; exit 1; }

failed=0
while IFS=$'\t' read -r crate name required script; do
  source="$repo/native/${crate}/prebuilt/macos/${name}"
  destination="${destination_dir}/${name}"
  build_hint="native/${crate}/${script}"

  if [[ ! -f "$source" ]]; then
    rm -f "$destination"
    case "$required" in
      always)
        echo "error: ${crate} is a required native dependency, but ${source} is missing; run ${build_hint} first (needs Rust: rustup target add aarch64-apple-darwin)" >&2
        failed=1
        ;;
      release)
        case "${CONFIGURATION:-}" in
          Release*|Profile*)
            echo "error: ${source} not found; ${crate} is a required native library. Run ${build_hint} first." >&2
            failed=1
            ;;
          *) echo "warning: ${source} not found; ${crate} is not bundled in this ${CONFIGURATION:-Debug} build (it reports itself missing at runtime)" ;;
        esac
        ;;
      optional) echo "note: ${source} not found; ${crate} is not bundled ($("$py" "$repo/tool/native_crates.py" get "$crate" platforms.macos.fallback))" ;;
      *) echo "error: native/crates.json: ${crate}.platforms.macos.required is '${required}'" >&2; failed=1 ;;
    esac
    continue
  fi

  # 库在、但缺本次要出的架构（macOS 版只出 arm64）：带进去也加载失败，比「没带」更难查。
  available_archs=" $(lipo -archs "$source") "
  for arch in ${ARCHS:-$(uname -m)}; do
    case "$available_archs" in
      *" $arch "*) ;;
      *)
        echo "error: ${source} lacks ${arch} (has:${available_archs}); rebuild with ${build_hint}" >&2
        exit 1
        ;;
    esac
  done

  mkdir -p "$destination_dir"
  cp -f "$source" "$destination"
  install_name_tool -id "@rpath/${name}" "$destination"

  if [[ "${CODE_SIGNING_ALLOWED:-}" != "NO" ]] && command -v codesign >/dev/null 2>&1; then
    sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
    if [[ -z "$sign_identity" ]]; then
      sign_identity="-"
    fi
    codesign --force --sign "$sign_identity" --timestamp=none "$destination"
  fi
done <<< "$listing"

exit "$failed"
