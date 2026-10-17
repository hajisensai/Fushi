#!/usr/bin/env bash
# 反馈发布回填：一次发布上传成功后，告诉反馈服务「哪些已标记修复的反馈，
# 这个通道 / 平台的这个版本已经包含了修复」。
#
# 契约（服务端 services/leaderboard 的 CI 专用接口）：
#   GET  <API>/v1/ci/feedback/pending?channel=<c>&platform=<p>
#        → {"items": [{"id": "...", "sha": "<40hex>"}]}
#   POST <API>/v1/ci/feedback/released
#        {"channel": c, "platform": p, "version": v,
#         "ids": [{"id": "...", "sha": "<pending 返回的 sha>"}, ...]}
#        服务端只在 fix_sha 仍等于该 sha 时写入（防「拉 pending 后被重新标记」的竞态）。
# 两个都带 `Authorization: Bearer $FEEDBACK_CI_TOKEN`。
#
# 判定「本次构建包含修复」只在本地做：`git cat-file -e <fix>^{commit}` 认识这个
# 提交，且 `git merge-base --is-ancestor <fix> <HEAD_SHA>`。不认识的 sha（别的分支
# 没拉下来、被 force-push 掉的）一律跳过——下一次包含它的发布会再查到它。
#
# **本脚本绝不能让发布变红**：任何失败（没配 secret、网络、接口、JSON、git）都只打
# `::warning` / `::notice` 后 exit 0；调用它的 workflow 步骤另外还挂了
# `continue-on-error: true`。
#
# 环境变量：
#   CHANNEL            发布 workflow 的 manifest_channel：debug | beta | formal；
#                      formal / github-release / stable 都映射成 stable，其余跳过
#   PLATFORM           android | windows | macos | ios | linux
#   VERSION            build_version_name（如 2.3.0-debug.12345 / 2.3.0-beta.12001 / 2.3.0）
#   HEAD_SHA           本次构建的提交（workflow 里是 github.sha）
#   FEEDBACK_CI_TOKEN  secret；为空 → ::notice 后退出
#   FEEDBACK_API_BASE  接口根，空则 https://rank.fushi.moe
#
# 参数：
#   --dry-run          照常 GET pending 并做祖先判定，只打印将要回填的 id，不 POST
#
# 离线测试：fushi/test/tools/feedback_mark_released_script_test.dart（本地临时 git
# 仓库造祖先 / 非祖先 / 未知提交 + 本机假 HTTP 端点）。
set -uo pipefail

warn() { echo "::warning title=Feedback release backfill::$*"; }
notice() { echo "::notice title=Feedback release backfill::$*"; }

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) warn "unknown argument '$arg' ignored" ;;
  esac
done

TMP_DIR=""
cleanup() {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

map_channel() {
  case "$1" in
    debug) echo debug ;;
    beta) echo beta ;;
    formal | github-release | stable) echo stable ;;
    *) echo "" ;;
  esac
}

# 返回 0 = 已正常结束（包括「什么都不用做」）；任何异常路径也都 return 0，
# 只是先打 warning。真正的退出码由文件末尾统一给 0。
main() {
  local token="${FEEDBACK_CI_TOKEN:-}"
  if [ -z "$token" ]; then
    notice "FEEDBACK_CI_TOKEN is not configured; skipping feedback release backfill."
    return 0
  fi

  local api_base="${FEEDBACK_API_BASE:-}"
  if [ -z "$api_base" ]; then api_base="https://rank.fushi.moe"; fi
  api_base="${api_base%/}"

  local raw_channel="${CHANNEL:-}"
  local channel
  channel="$(map_channel "$raw_channel")"
  if [ -z "$channel" ]; then
    notice "channel '$raw_channel' is not an update channel (debug|beta|formal); nothing to backfill."
    return 0
  fi

  local platform="${PLATFORM:-}"
  case "$platform" in
    android | windows | macos | ios | linux) ;;
    *)
      warn "unknown PLATFORM '$platform'; skipping."
      return 0
      ;;
  esac

  local version="${VERSION:-}"
  if ! [[ "$version" =~ ^[A-Za-z0-9.+-]{1,64}$ ]]; then
    warn "VERSION '$version' is empty or not [A-Za-z0-9.+-]{1,64}; skipping."
    return 0
  fi

  local head_sha="${HEAD_SHA:-}"
  if [ -z "$head_sha" ] || ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
    warn "HEAD_SHA '$head_sha' is not a commit in this checkout; skipping."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping."
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node not found (needed to parse the pending list); skipping."
    return 0
  fi

  TMP_DIR="$(mktemp -d)" || {
    warn "mktemp failed; skipping."
    return 0
  }
  # token 走 header 文件，不出现在进程参数列表里。
  local header_file="$TMP_DIR/auth-header"
  (umask 077 && printf 'Authorization: Bearer %s\n' "$token" >"$header_file")

  local pending_file="$TMP_DIR/pending.json"
  local url="$api_base/v1/ci/feedback/pending?channel=$channel&platform=$platform"
  local status
  status="$(curl -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -H "@$header_file" -H 'Accept: application/json' \
    -o "$pending_file" -w '%{http_code}' "$url")"
  local curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    warn "GET pending failed (curl exit $curl_rc, http ${status:-?}); skipping."
    return 0
  fi
  if [ "$status" != "200" ]; then
    warn "GET pending returned HTTP $status; skipping."
    return 0
  fi

  # 只放行形状合法的 id / sha：它们之后会直接拼进 git 参数与 POST 正文。
  local pairs_file="$TMP_DIR/pairs.txt"
  if ! node -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const items = Array.isArray(j && j.items) ? j.items : [];
for (const it of items) {
  if (!it || typeof it.id !== "string" || typeof it.sha !== "string") continue;
  if (!/^[A-Za-z0-9_-]{8,16}$/.test(it.id)) continue;
  if (!/^[0-9a-fA-F]{40}$/.test(it.sha)) continue;
  console.log(it.id + " " + it.sha);
}
' "$pending_file" >"$pairs_file"; then
    warn "could not parse the pending list as JSON; skipping."
    return 0
  fi

  local ids=()
  local ids_json=""
  local unknown=0
  local not_included=0
  local id sha
  while read -r id sha; do
    [ -n "$id" ] || continue
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      unknown=$((unknown + 1))
      echo "skip $id: fix commit $sha is unknown to this checkout"
      continue
    fi
    if git merge-base --is-ancestor "$sha" "$head_sha" 2>/dev/null; then
      ids+=("$id")
      if [ -n "$ids_json" ]; then ids_json="$ids_json,"; fi
      ids_json="$ids_json{\"id\":\"$id\",\"sha\":\"$sha\"}"
      echo "include $id: $sha is an ancestor of $head_sha"
    else
      not_included=$((not_included + 1))
      echo "skip $id: $sha is not in this build"
    fi
  done <"$pairs_file"

  if [ "${#ids[@]}" -eq 0 ]; then
    echo "No pending feedback fixes are included in $channel/$platform $version (unknown: $unknown, not included: $not_included)."
    return 0
  fi

  local body
  body="$(printf '{"channel":"%s","platform":"%s","version":"%s","ids":[%s]}' \
    "$channel" "$platform" "$version" "$ids_json")"

  if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: would POST released for ${#ids[@]} feedback(s): ${ids[*]}"
    echo "DRY RUN body: $body"
    return 0
  fi

  local response_file="$TMP_DIR/released.json"
  status="$(curl -sS --connect-timeout 10 --max-time 30 --retry 2 \
    -X POST -H "@$header_file" -H 'Content-Type: application/json' \
    --data "$body" -o "$response_file" -w '%{http_code}' \
    "$api_base/v1/ci/feedback/released")"
  curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    warn "POST released failed (curl exit $curl_rc, http ${status:-?})."
    return 0
  fi
  if [ "$status" != "200" ]; then
    warn "POST released returned HTTP $status."
    return 0
  fi
  echo "Marked ${#ids[@]} feedback fix(es) as released in $channel/$platform $version: ${ids[*]}"
  echo "Server response: $(head -c 2000 "$response_file")"
  return 0
}

main || warn "unexpected failure (exit $?); release is unaffected."
exit 0
