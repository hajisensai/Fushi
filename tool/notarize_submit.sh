#!/usr/bin/env bash
# 提交 Apple 公证并按服务端结论判成败。
#
# 用法: tool/notarize_submit.sh <zip|dmg|pkg> <AuthKey.p8 路径> <key id> <issuer id>
#
# `notarytool submit --wait` 只要处理流程走完就退出 0，被拒（status: Invalid）也一样，
# 所以不能拿退出码判成败：2026-10-10 首次走 Developer ID 路径时公证被拒，退出码 0，
# 一路走到 `stapler staple` 才以「Record not found」65 失败，看不出真实原因。
# 这里以 JSON 里的 status 为准，非 Accepted 时把 `notarytool log`（逐个被拒二进制与原因）
# 打进构建日志再失败。
set -euo pipefail

ARTIFACT="$1"
KEY_PATH="$2"
KEY_ID="$3"
ISSUER="$4"

auth=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER")

result="$(xcrun notarytool submit "$ARTIFACT" "${auth[@]}" --wait --timeout 45m --output-format json)" || {
  echo "::error title=Notarization submit failed::notarytool submit exited $? for $ARTIFACT"
  echo "$result"
  exit 1
}
echo "$result"

# plutil 能直接读 JSON；macOS runner 自带，不依赖 jq / python。
json_field() {
  printf '%s' "$result" | plutil -extract "$1" raw -o - - 2>/dev/null || true
}
status="$(json_field status)"
submission_id="$(json_field id)"

if [ "$status" != "Accepted" ]; then
  echo "::error title=Notarization rejected::status=${status:-<missing>} id=${submission_id:-<missing>} for $ARTIFACT"
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" "${auth[@]}" || true
  fi
  exit 1
fi
echo "Notarization accepted: $submission_id"
