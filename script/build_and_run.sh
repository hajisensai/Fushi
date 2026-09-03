#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
flutter_project="$repository_root/fushi"
flutter_sdk="${FUSHI_FLUTTER_SDK:-${HOME}/fvm/versions/3.41.6}"
flutter="$flutter_sdk/bin/flutter"
configuration="debug"
show_logs=false
verify_only=false

usage() {
  cat <<'EOF'
usage: script/build_and_run.sh [--debug|--release] [--logs] [--verify]

Builds the macOS app, bundles the pinned Aidoku and Mihon runtimes, and launches fushi.
Set FUSHI_FLUTTER_SDK to override the default Flutter SDK location.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) configuration="debug" ;;
    --release) configuration="release" ;;
    --logs|--telemetry) show_logs=true ;;
    --verify) verify_only=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS is required" >&2
  exit 1
fi

if [[ ! -x "$flutter" ]]; then
  echo "Flutter 3.41.6 was not found at $flutter_sdk" >&2
  echo "Set FUSHI_FLUTTER_SDK to an installed Flutter SDK." >&2
  exit 1
fi

if [[ "$configuration" == "debug" ]]; then
  configuration_directory="Debug"
else
  configuration_directory="Release"
fi
app="$flutter_project/build/macos/Build/Products/$configuration_directory/fushi.app"

if [[ "$verify_only" == false ]]; then
  pkill -x fushi >/dev/null 2>&1 || true
  (
    cd "$flutter_project"
    "$flutter" build macos "--$configuration"
  )

  # 本机开发只在本机跑，默认 host 架构省一次交叉编译；CI 走 universal（默认值），
  # 见 tool/aidoku/build_macos_runtime.sh 里的 BUG-1922 注释。
  FUSHI_AIDOKU_ARCHS="${FUSHI_AIDOKU_ARCHS:-host}" \
    "$repository_root/tool/aidoku/build_macos_runtime.sh" \
    "$app/Contents/Resources/aidoku_runtime"

  mihon_cache="$repository_root/.dart_tool/mihon_bridge"
  case "$(uname -m)" in
    arm64) mihon_host_runtime="runtime-macos-arm64" ;;
    x86_64) mihon_host_runtime="runtime-macos-x64" ;;
    *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  if [[ ! -f "$mihon_cache/m-extension-server.jar" || \
        ! -x "$mihon_cache/$mihon_host_runtime/bin/java" ]]; then
    FUSHI_MIHON_ARCHS=host bash "$repository_root/tool/mihon/build_desktop_runtime.sh" \
      "$mihon_cache" \
      "$repository_root/.dart_tool/mihon-downloads"
  fi
  mihon_bundle="$app/Contents/Resources/mihon_bridge"
  if [[ -e "$mihon_bundle" ]]; then
    mihon_backup="$mihon_bundle.backup.$$"
    mv "$mihon_bundle" "$mihon_backup"
  else
    mihon_backup=""
  fi
  if /usr/bin/ditto "$mihon_cache" "$mihon_bundle"; then
    if [[ -n "$mihon_backup" ]]; then
      rm -rf -- "$mihon_backup"
    fi
  else
    if [[ -n "$mihon_backup" && ! -e "$mihon_bundle" ]]; then
      mv "$mihon_backup" "$mihon_bundle"
    fi
    exit 1
  fi

  while IFS= read -r candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
      codesign --force --sign - --timestamp=none "$candidate"
    fi
  done < <(find "$mihon_bundle" -type f)
  bash "$repository_root/tool/mihon/verify_desktop_runtime.sh" "$mihon_bundle"

  codesign --force --deep --sign - \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    "$app"
fi

if [[ ! -x "$app/Contents/MacOS/fushi" ]]; then
  echo "macOS app was not produced at $app" >&2
  exit 1
fi

# 与两条 macOS CI job 用同一道门（BUG-1922）。本地是 host 构建，所以不传 app
# 本体做架构覆盖核对 —— 那条不变式只在出发布包的 CI 上成立。
bash "$repository_root/tool/aidoku/verify_macos_runtime.sh" \
  "$app/Contents/Resources/aidoku_runtime"

case "$(uname -m)" in
  arm64) mihon_host_runtime="runtime-macos-arm64" ;;
  x86_64) mihon_host_runtime="runtime-macos-x64" ;;
  *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac
if [[ ! -f "$app/Contents/Resources/mihon_bridge/m-extension-server.jar" || \
      ! -x "$app/Contents/Resources/mihon_bridge/$mihon_host_runtime/bin/java" ]]; then
  echo "Mihon runtime is missing from $app" >&2
  exit 1
fi

codesign --verify --deep --strict "$app"

if [[ "$verify_only" == true ]]; then
  echo "verified $app"
  exit 0
fi

open -n "$app"

if [[ "$show_logs" == true ]]; then
  log stream --style compact --level info \
    --predicate 'process == "fushi" OR process == "fushi-aidoku-runtime"'
fi
