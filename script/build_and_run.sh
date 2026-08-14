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

Builds the macOS app, bundles the pinned Aidoku runtime, and launches fushi.
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

  "$repository_root/tool/aidoku/build_macos_runtime.sh" \
    "$app/Contents/Resources/aidoku_runtime"

  codesign --force --deep --sign - \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    "$app"
fi

if [[ ! -x "$app/Contents/MacOS/fushi" ]]; then
  echo "macOS app was not produced at $app" >&2
  exit 1
fi

if [[ ! -x "$app/Contents/Resources/aidoku_runtime/fushi-aidoku-runtime" ]]; then
  echo "Aidoku runtime is missing from $app" >&2
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
