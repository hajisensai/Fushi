#!/usr/bin/env bash
set -euo pipefail

# BUG-1922：macOS 发布包从来没装过 Aidoku runtime —— 构建脚本只被本地的
# script/build_and_run.sh 调用，两条 macOS CI job 里一步都没有，于是每个从
# release zip 装进 /Applications 的用户一碰 Aidoku 仓库就吃
# AidokuRuntimeException(RUNTIME_MISSING)，而 CI 全绿。这个脚本就是那道缺失的
# 硬门：打完包必须证明 runtime 真在 bundle 里、架构盖得住 app 本体、且真能起来。

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 RUNTIME_DIRECTORY [APP_EXECUTABLE]" >&2
  exit 64
fi

if [[ ! -d "$1" ]]; then
  echo "bundled Aidoku runtime directory is missing: $1" >&2
  exit 1
fi
runtime_directory="$(cd "$1" && pwd)"
app_executable="${2:-}"
runtime="$runtime_directory/fushi-aidoku-runtime"

for required in "$runtime" \
  "$runtime_directory/checksums.json" \
  "$runtime_directory/LICENSE-AIDOKU-RS.txt" \
  "$runtime_directory/NOTICE-AIDOKU-RUNTIME.txt"; do
  if [[ ! -f "$required" ]]; then
    echo "missing bundled Aidoku runtime asset: $required" >&2
    exit 1
  fi
done

if [[ ! -x "$runtime" ]]; then
  echo "bundled Aidoku runtime is not executable: $runtime" >&2
  exit 1
fi

# BUG-1668 的教训：下面的冒烟只证明**这台 runner 的架构**能跑它。真正的不变式是
# helper 的架构必须覆盖 app 本体的架构，所以直接按 app 本体的 lipo 结果逐个核对。
if [[ -n "$app_executable" ]]; then
  if [[ ! -x "$app_executable" ]]; then
    echo "app executable not found for the Aidoku runtime architecture gate: $app_executable" >&2
    exit 1
  fi
  app_archs="$(lipo -archs "$app_executable")"
  runtime_archs="$(lipo -archs "$runtime")"
  echo "app archs: $app_archs"
  echo "aidoku runtime archs: $runtime_archs"
  for want in $app_archs; do
    case " $runtime_archs " in
      *" $want "*) ;;
      *)
        echo "Aidoku runtime 缺 $want（app: $app_archs / runtime: $runtime_archs）。该架构的 Mac 上 helper 会被内核以 EBADARCH 拒掉，漫画 Aidoku 源整条链（仓库刷新、安装扩展、搜索、看图）全部失效。用 FUSHI_AIDOKU_ARCHS=universal 重新构建 runtime。" >&2
        exit 1
        ;;
    esac
  done
fi

# 无参调用打 usage 到 stderr 并以非零退出（native/aidoku_runtime/src/main.rs）。
# 能走到打 usage，说明进程真的起来了：架构、代码签名、动态库依赖都成立。
smoke_output="$("$runtime" 2>&1 || true)"
case "$smoke_output" in
  *"usage: fushi-aidoku-runtime"*) ;;
  *)
    echo "bundled Aidoku runtime did not start: $runtime" >&2
    echo "$smoke_output" >&2
    exit 1
    ;;
esac

echo "verified $runtime"
