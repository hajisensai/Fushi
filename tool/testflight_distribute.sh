#!/usr/bin/env bash
# 把 App Store Connect 上某个**已上传**的构建号挂到 TestFlight 的邮件邀请测试组。
#
# 背景：`altool --upload-app` 只是把构建传到 App Store Connect，传完构建只是躺在那里；
# 除非内部组开了「自动分发」，没有任何测试员会收到它。外部组更是必须逐个构建手动
# 加进去。这个脚本就是那一步「加进去」的自动化，专给**邮件邀请**的组：
#   - 默认选中该 app 下所有**没开公开链接**的组（内部 + 外部邮件邀请组）；
#   - 显式列出组名（TESTFLIGHT_BETA_GROUPS，逗号分隔）时只挂到这些组，且其中任何一个
#     开了公开链接就直接拒绝——公开链接组的人不是用户挑的，debug 包不该流向他们；
#   - `hasAccessToAllBuilds` 的内部组本来就看得到每个构建，跳过（API 也不让加）。
#
# 分发前先等 App Store Connect 把构建处理完（processingState=VALID，通常 5~30 分钟）；
# 处理失败（FAILED / INVALID）直接红。选中了外部组时再提交一次 Beta App Review
# （同一个短版本下的后续构建通常秒过）；已提交过的 409 视为完成。
#
# 用法：tool/testflight_distribute.sh <build_number> [bundle_id]   （默认 app.fushi.reader）
# 环境：APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID / APPSTORE_API_PRIVATE_KEY
#      TESTFLIGHT_BETA_GROUPS   可选，逗号分隔组名；空 = 所有未开公开链接的组
#      TESTFLIGHT_WAIT_MINUTES  可选，等处理完成的上限，默认 45
#      TESTFLIGHT_GROUPS_FIXTURE 可选，离线自检：指向一份 GET /v1/betaGroups 响应 JSON，
#                               不碰 App Store Connect、不需要凭据，只打印会选中的组名。
#
# 谁在用：.github/workflows/release-desktop.yml 的 testflight-distribute job
# （ios job 上传成功后自动跟一趟，或 dispatch 输入 testflight_distribute_build 只做分发）。
# 守卫：fushi/test/tools/apple_signing_workflow_guard_test.dart
set -euo pipefail

readonly ASC_API="https://api.appstoreconnect.apple.com"
build_number="${1:-}"
bundle_id="${2:-app.fushi.reader}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wait_minutes="${TESTFLIGHT_WAIT_MINUTES:-45}"
fixture="${TESTFLIGHT_GROUPS_FIXTURE:-}"

if ! [[ "$build_number" =~ ^[0-9]+$ ]]; then
  echo "::error title=Invalid build number::usage: $0 <build_number> [bundle_id] (got '${build_number}')" >&2
  exit 2
fi
if [ -z "$fixture" ]; then
  for var in APPSTORE_API_KEY_ID APPSTORE_API_ISSUER_ID APPSTORE_API_PRIVATE_KEY; do
    if [ -z "${!var:-}" ]; then
      echo "::error title=Missing App Store Connect credential::$var is empty" >&2
      exit 2
    fi
  done
fi

# JWT 有效期 ~18 分钟，等处理完成可能超过；每次请求前看一眼，过 15 分钟就重签。
token=""
token_at=0
ensure_token() {
  local now
  now="$(date +%s)"
  if [ -z "$token" ] || [ $((now - token_at)) -gt 900 ]; then
    token="$(ruby "$script_dir/asc_api_jwt.rb")"
    token_at="$now"
  fi
}

response_body=""
response_code=""
# api_call <method> <resource> [json body]：把 HTTP 状态码留给调用方判断（分发是幂等操作，
# 409「已在组里」要当成功而不是红），body 放 response_body。
api_call() {
  local method="$1" resource="$2" body="${3:-}"
  local tmp
  tmp="$(mktemp)"
  ensure_token
  local -a args=(--silent --show-error -X "$method"
    -H "Authorization: Bearer $token" -H "Content-Type: application/json"
    -o "$tmp" -w '%{http_code}')
  if [ -n "$body" ]; then
    args+=(--data "$body")
  fi
  response_code="$(curl "${args[@]}" "$ASC_API$resource")"
  response_body="$(cat "$tmp")"
  rm -f "$tmp"
}

api_get_or_die() {
  api_call GET "$1"
  if [ "$response_code" != 200 ]; then
    echo "::error title=App Store Connect API error::GET $1 -> HTTP $response_code: $response_body" >&2
    exit 3
  fi
}

urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

# 从一份 GET /v1/betaGroups 响应里挑出要挂的组，结果（JSON 数组）放 selected。
# 拒绝条件（exit 5）：点名的组不存在、点名的组开了公开链接、最后一个组都不剩。
select_groups() {
  local groups_json="$1"
  if [ -n "${TESTFLIGHT_BETA_GROUPS:-}" ]; then
    local wanted missing public
    wanted="$(jq -cn --arg s "$TESTFLIGHT_BETA_GROUPS" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
    missing="$(jq -r --argjson w "$wanted" '[.data[].attributes.name] as $have | $w - $have | .[]' <<<"$groups_json")"
    if [ -n "$missing" ]; then
      echo "::error title=TestFlight group not found::TESTFLIGHT_BETA_GROUPS names not in App Store Connect: $(tr '\n' ',' <<<"$missing" | sed 's/,$//')" >&2
      exit 5
    fi
    public="$(jq -r --argjson w "$wanted" '.data[] | select((.attributes.name as $n | $w | index($n)) != null and .attributes.publicLinkEnabled == true) | .attributes.name' <<<"$groups_json")"
    if [ -n "$public" ]; then
      echo "::error title=Refusing public-link group::these TESTFLIGHT_BETA_GROUPS have a public link enabled, only email-invited groups may receive this build: $(tr '\n' ',' <<<"$public" | sed 's/,$//')" >&2
      exit 5
    fi
    selected="$(jq -c --argjson w "$wanted" '[.data[] | select((.attributes.name as $n | $w | index($n)) != null)]' <<<"$groups_json")"
  else
    selected="$(jq -c '[.data[] | select(.attributes.publicLinkEnabled != true)]' <<<"$groups_json")"
  fi

  local skipped_public auto_groups
  skipped_public="$(jq -r '[.data[] | select(.attributes.publicLinkEnabled == true) | .attributes.name] | join(", ")' <<<"$groups_json")"
  if [ -n "$skipped_public" ]; then
    echo "public-link groups left untouched: $skipped_public"
  fi
  auto_groups="$(jq -r '[.[] | select(.attributes.hasAccessToAllBuilds == true) | .attributes.name] | join(", ")' <<<"$selected")"
  if [ -n "$auto_groups" ]; then
    echo "internal groups that already see every build (skipped): $auto_groups"
  fi
  selected="$(jq -c '[.[] | select(.attributes.hasAccessToAllBuilds != true)]' <<<"$selected")"
  if [ "$(jq 'length' <<<"$selected")" = 0 ]; then
    echo "::error title=No TestFlight group to distribute to::$bundle_id has no email-invited beta group (or TESTFLIGHT_BETA_GROUPS selected none). Create a group in App Store Connect → TestFlight, or set the TESTFLIGHT_BETA_GROUPS repository variable." >&2
    exit 5
  fi
}

selected=""
if [ -n "$fixture" ]; then
  select_groups "$(cat "$fixture")"
  echo "would distribute build $build_number to: $(jq -r '[.[] | .attributes.name] | join(", ")' <<<"$selected")"
  exit 0
fi

api_get_or_die "/v1/apps?filter%5BbundleId%5D=$(urlencode "$bundle_id")"
app_id="$(jq -r '.data[0].id // empty' <<<"$response_body")"
if [ -z "$app_id" ]; then
  echo "::error title=App record missing::No App Store Connect app with bundle id $bundle_id" >&2
  exit 3
fi

# ---- 1. 等构建处理完 -------------------------------------------------------
# 上传后几分钟内 builds 列表里可能还没有这条记录，「找不到」也在等待范围内。
deadline=$(( $(date +%s) + wait_minutes * 60 ))
build_id=""
while :; do
  api_get_or_die "/v1/builds?filter%5Bapp%5D=$app_id&filter%5Bversion%5D=$build_number&filter%5Bexpired%5D=false&sort=-uploadedDate&limit=5&fields%5Bbuilds%5D=version,processingState,uploadedDate,expired"
  build_id="$(jq -r '.data[0].id // empty' <<<"$response_body")"
  state="$(jq -r '.data[0].attributes.processingState // "MISSING"' <<<"$response_body")"
  case "$state" in
    VALID)
      break
      ;;
    FAILED|INVALID)
      echo "::error title=Build $build_number rejected by App Store Connect::processingState=$state; nothing to distribute." >&2
      exit 4
      ;;
    PROCESSING|MISSING)
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "::error title=Build $build_number not ready::processingState=$state after ${wait_minutes} minutes." >&2
        exit 4
      fi
      echo "build $build_number: $state, waiting..."
      sleep 60
      ;;
    *)
      echo "::error title=Unexpected processingState::$state for build $build_number" >&2
      exit 4
      ;;
  esac
done
echo "build $build_number is $state (id=$build_id)"

# ---- 2. 选组 ------------------------------------------------------------------
api_get_or_die "/v1/betaGroups?filter%5Bapp%5D=$app_id&limit=200&fields%5BbetaGroups%5D=name,isInternalGroup,publicLinkEnabled,hasAccessToAllBuilds"
select_groups "$response_body"

# ---- 3. 挂构建 ----------------------------------------------------------------
needs_review=false
while IFS=$'\t' read -r group_id group_name is_internal; do
  api_call POST "/v1/betaGroups/$group_id/relationships/builds" \
    "$(jq -cn --arg b "$build_id" '{data: [{type: "builds", id: $b}]}')"
  case "$response_code" in
    204) echo "attached build $build_number -> group '$group_name'" ;;
    409) echo "build $build_number already in group '$group_name'" ;;
    *)
      echo "::error title=Failed to attach build to group '$group_name'::HTTP $response_code: $response_body" >&2
      exit 6
      ;;
  esac
  if [ "$is_internal" != true ]; then
    needs_review=true
  fi
done < <(jq -r '.[] | [.id, .attributes.name, (.attributes.isInternalGroup | tostring)] | @tsv' <<<"$selected")

# ---- 4. 外部组要过 Beta App Review ---------------------------------------------
if [ "$needs_review" = true ]; then
  api_call GET "/v1/builds/$build_id/betaAppReviewSubmission"
  existing_state="$(jq -r '.data.attributes.betaReviewState // empty' <<<"$response_body" 2>/dev/null || true)"
  if [ -n "$existing_state" ]; then
    echo "beta app review already submitted for build $build_number: $existing_state"
  else
    api_call POST "/v1/betaAppReviewSubmissions" \
      "$(jq -cn --arg b "$build_id" '{data: {type: "betaAppReviewSubmissions", relationships: {build: {data: {type: "builds", id: $b}}}}}')"
    case "$response_code" in
      201) echo "submitted build $build_number for beta app review: $(jq -r '.data.attributes.betaReviewState // "?"' <<<"$response_body")" ;;
      409) echo "beta app review submission already exists for build $build_number" ;;
      *)
        echo "::error title=Beta App Review submission failed::HTTP $response_code: $response_body" >&2
        exit 7
        ;;
    esac
  fi
fi

echo "distributed build $build_number to $(jq -r '[.[] | .attributes.name] | join(", ")' <<<"$selected")"
