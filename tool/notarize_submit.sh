#!/usr/bin/env bash
# 提交 Apple 公证并按服务端结论判成败。
#
# 用法: tool/notarize_submit.sh <zip|dmg|pkg> <AuthKey.p8 路径> <key id> <issuer id>
#
# 1. 不能拿 `notarytool submit --wait` 的退出码判成败：只要处理流程走完它就退出 0，
#    被拒（status: Invalid）也一样。2026-10-10 首次走 Developer ID 路径时公证被拒，
#    退出码 0，一路走到 `stapler staple` 才以「Record not found」65 失败，看不出真实原因。
#    这里以 JSON 里的 status 为准，非 Accepted 时把 `notarytool log`（逐个被拒二进制与
#    原因）打进构建日志再失败。
# 2. 上传与等结论分开（BUG-5588）：`submit --wait` 把「上传」和「轮询状态」绑成一条命令，
#    轮询途中 runner 断一次网（2026-11-27 beta 构建 macOS 连续两次在提交后约 3 分钟报
#    NSURLErrorDomain -1009 / Resolved 0 endpoints），整条命令就退出 1，已上传、Apple
#    那边照常在审的 submission 被直接丢掉。公证结论在 Apple 服务端，本地查询失败不改变
#    它，所以这里先 `submit`（不带 --wait）拿 submission id，再按 id 轮询 `notarytool info`：
#    查询本身失败只记 warning、下一轮再查同一个 id，直到拿到终态或总时限
#    （NOTARIZE_TIMEOUT_SECONDS，默认 45 分钟）用完。上传失败仍立即判失败。
set -euo pipefail

ARTIFACT="$1"
KEY_PATH="$2"
KEY_ID="$3"
ISSUER="$4"

TIMEOUT_SECONDS="${NOTARIZE_TIMEOUT_SECONDS:-2700}"
POLL_SECONDS="${NOTARIZE_POLL_SECONDS:-30}"

auth=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER")

# plutil 能直接读 JSON；macOS runner 自带，不依赖 jq / python。
json_field() {
  printf '%s' "$2" | plutil -extract "$1" raw -o - - 2>/dev/null || true
}

submit_out="$(xcrun notarytool submit "$ARTIFACT" "${auth[@]}" --output-format json)" || {
  rc=$?
  echo "::error title=Notarization submit failed::notarytool submit (upload) exited $rc for $ARTIFACT"
  echo "$submit_out"
  exit 1
}
echo "$submit_out"
submission_id="$(json_field id "$submit_out")"
if [ -z "$submission_id" ]; then
  echo "::error title=Notarization submit failed::no submission id in notarytool output for $ARTIFACT"
  exit 1
fi
echo "Submitted $ARTIFACT for notarization: $submission_id"

deadline=$(( SECONDS + TIMEOUT_SECONDS ))
status=""
while :; do
  if info_out="$(xcrun notarytool info "$submission_id" "${auth[@]}" --output-format json 2>&1)"; then
    status="$(json_field status "$info_out")"
    case "$status" in
      Accepted|Invalid|Rejected) echo "$info_out"; break ;;
      *) echo "Notarization $submission_id: ${status:-<no status>}" ;;
    esac
  else
    # 本地查询失败（断网 / DNS / Apple 接口 5xx）：submission 仍在服务端，下轮再查。
    echo "::warning title=Notarization status query failed::$submission_id: $(printf '%s' "$info_out" | head -c 400)"
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error title=Notarization timed out::$submission_id still ${status:-unknown} after ${TIMEOUT_SECONDS}s for $ARTIFACT"
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

if [ "$status" != "Accepted" ]; then
  echo "::error title=Notarization rejected::status=${status:-<missing>} id=${submission_id} for $ARTIFACT"
  xcrun notarytool log "$submission_id" "${auth[@]}" || true
  exit 1
fi
echo "Notarization accepted: $submission_id"
