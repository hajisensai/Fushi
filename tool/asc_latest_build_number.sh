#!/usr/bin/env bash
# 打印 App Store Connect 上某个 bundle id 已上传的**最大构建号**（纯整数，一行）。
# 没有任何构建时打印 0。
#
# 谁在用：.github/workflows/testflight-debug.yml 的定时检查——develop 头的
# `tool/release_sequence.sh` 比这个数大才值得再传一份 debug 包到 TestFlight。
# 状态拥有者是 Apple 自己（不是 git tag、不是 Actions cache），所以不存在
# 「上传成功但本地记号没写上」的分叉；顺带挡住「构建号比已传的小、altool 拒收」。
#
# 用法：tool/asc_latest_build_number.sh [bundle_id]   （默认 app.fushi.reader）
# 环境：APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID / APPSTORE_API_PRIVATE_KEY
#
# 只取最近上传的 200 个构建里的数值最大者：TestFlight 构建号只要求同一
# CFBundleShortVersionString 下单调，按 uploadedDate 倒序取第一个不等价于最大值
# （从旧 commit 手动发 beta 会插进一个更小的号）。
set -euo pipefail

readonly ASC_API="https://api.appstoreconnect.apple.com"
bundle_id="${1:-app.fushi.reader}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for var in APPSTORE_API_KEY_ID APPSTORE_API_ISSUER_ID APPSTORE_API_PRIVATE_KEY; do
  if [ -z "${!var:-}" ]; then
    echo "::error title=Missing App Store Connect credential::$var is empty" >&2
    exit 2
  fi
done

token="$(ruby "$script_dir/asc_api_jwt.rb")"

api_get() {
  curl --fail-with-body --silent --show-error --get \
    -H "Authorization: Bearer $token" \
    "$ASC_API$1" "${@:2}"
}

app_id="$(api_get /v1/apps --data-urlencode "filter[bundleId]=$bundle_id" \
  | jq -r '.data[0].id // empty')"
if [ -z "$app_id" ]; then
  echo "::error title=App record missing::No App Store Connect app with bundle id $bundle_id" >&2
  exit 3
fi

api_get /v1/builds \
  --data-urlencode "filter[app]=$app_id" \
  --data-urlencode "sort=-uploadedDate" \
  --data-urlencode "fields[builds]=version" \
  --data-urlencode "limit=200" \
  | jq -r '[.data[].attributes.version | tonumber? // 0] | max // 0'
