#!/usr/bin/env bash
# Launch the Hibiki Flutter app in debug mode (bash / git-bash).
#
# Usage (from the repo root):
#   ./run.sh                   # run on Windows desktop (default)
#   ./run.sh emulator-5554     # run on a specific device id (see: flutter devices)
#   ./run.sh windows --profile # extra args after the device pass through to `flutter run`
#
# Flutter SDK resolution: $FLUTTER_BIN, then the known local SDK, then PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT/hibiki"

FLUTTER="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER" ]]; then
  if [[ -x "D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat" ]]; then
    FLUTTER="D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat"
  elif command -v flutter >/dev/null 2>&1; then
    FLUTTER="flutter"
  else
    echo "flutter not found. Set FLUTTER_BIN to your flutter(.bat) path." >&2
    exit 1
  fi
fi

DEVICE="${1:-windows}"
[[ $# -gt 0 ]] && shift  # remaining args (if any) pass through to `flutter run`

cd "$APP_DIR"

CMD=("$FLUTTER" run -d "$DEVICE")
CMD+=("$@")

echo "==> $FLUTTER pub get"
"$FLUTTER" pub get
echo "==> ${CMD[*]}"
exec "${CMD[@]}"
