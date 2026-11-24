#!/usr/bin/env bash
# 把滚动调试版 release 的 tag（`fushi-debug-rolling`）挪到一个「现在」的提交上，
# 让它在 GitHub Releases 列表里永远排在顶部附近（拍板台 RRYro9vSEU，选 a）。
#
# 为什么是「挪 tag」而不是「删 release 再重建」：
#   - GitHub Releases 列表按 release 的 `created_at` 倒序排，而 `created_at` **就是
#     tag 所指提交的日期**（REST 文档 "Releases"：the date of the commit used for the
#     release），不是建 release 的时间。2026-11-24 实测：`fushi-debug-rolling` 的
#     created_at = 2026-08-10T09:33:10Z = 它的 tag 提交 2897aa85 的 committer date，
#     所以它一直沉在第 40 条左右。tag 不动只删了重建，created_at 还是 8 月，名次不变。
#   - 而且这个值是现算的：临时仓库实测 force 更新 tag 指向后，同一个 release
#     （id 不变、资产一个不少）的 created_at 立刻变成新提交的日期、排到最前。
#     所以只挪 tag 就够了：release id、资产、下载链接
#     （`releases/download/fushi-debug-rolling/<name>`）、更新清单全都不动，
#     没有「删了还没传完」的窗口期，也不会误删 Android / 桌面另一条 workflow
#     并行传上来的资产（两条 workflow 共用这一个 release，各管各的 prune）。
#
# 挪到哪个提交：新造一个提交，tree 与父提交都取**默认分支**（2026-11-25 起是 develop）尖端，日期是现在。
#   - 不直接指向本次构建的 develop sha：GitHub 拒绝用 GITHUB_TOKEN 更新「解析出的目标
#     提交相对默认分支改了 .github/workflows/」的 release（同 softprops 步骤的
#     target_commitish 注释，rolling_publish_and_r8_gate_guard_test.dart 守着），tag 指向
#     develop 提交就把下一次 release 更新暴露在这条限制下。tree 与默认分支一致则完全不涉。
#   - 该提交挂在 tag 上，可达、不会被 GC；构建来源的 develop sha 写进提交信息
#     （release 的 name / body 里本来也有）。GITHUB_TOKEN 触发的 ref 变更不会再触发 workflow。
#
# 失败处理：排序只是展示，资产此时已经发完，所以任何一步失败都只打 ::warning、退出 0，
# 不让发布变红；挪 tag 是幂等的，下一次 develop push 的发布会整套重做一遍（自愈）。
# Android（release.yml）与桌面（release-desktop.yml）两条 workflow 都在各自发布后调用，
# 并行时各造各的提交、force 更新同一个 ref，后写者赢，任何一种结果都满足「排在顶部」。
#
# 环境变量：
#   REPO            owner/name（必填）
#   PUBLISH_TAG     要挪的 tag（必填；只接受 `*-debug-rolling`，防止误挪正式版 tag）
#   DEFAULT_BRANCH  默认分支名（必填）
#   BUILD_SHA       本次构建的提交（可选，只进提交信息）
#   GH_TOKEN        gh CLI 的令牌（workflow 里给 secrets.GITHUB_TOKEN，需 contents: write）
#
# 守卫：fushi/test/tools/bump_rolling_release_tag_script_test.dart（假 gh 跑真脚本）。
set -uo pipefail

warn() {
  echo "::warning title=rolling debug tag bump::$*"
}

REPO="${REPO:-}"
PUBLISH_TAG="${PUBLISH_TAG:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
BUILD_SHA="${BUILD_SHA:-}"

if [ -z "$REPO" ] || [ -z "$PUBLISH_TAG" ] || [ -z "$DEFAULT_BRANCH" ]; then
  warn "REPO / PUBLISH_TAG / DEFAULT_BRANCH must all be set; skipping."
  exit 0
fi

case "$PUBLISH_TAG" in
  *-debug-rolling) ;;
  *)
    warn "refusing to move non-rolling tag '$PUBLISH_TAG'; only *-debug-rolling tags are bumped."
    exit 0
    ;;
esac

is_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# 先确认 tag 已存在：release 由前面的 softprops 步骤建好（首次发布时它连 tag 一起建），
# 这里只挪，不凭空造 tag。
if ! old_sha="$(gh api "repos/$REPO/git/ref/tags/$PUBLISH_TAG" --jq '.object.sha')" || ! is_sha "$old_sha"; then
  warn "tag $PUBLISH_TAG not found on $REPO; nothing to bump."
  exit 0
fi

if ! base_sha="$(gh api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha')" || ! is_sha "$base_sha"; then
  warn "cannot resolve $DEFAULT_BRANCH tip on $REPO; tag $PUBLISH_TAG left at $old_sha."
  exit 0
fi

if ! tree_sha="$(gh api "repos/$REPO/git/commits/$base_sha" --jq '.tree.sha')" || ! is_sha "$tree_sha"; then
  warn "cannot read tree of $DEFAULT_BRANCH@$base_sha; tag $PUBLISH_TAG left at $old_sha."
  exit 0
fi

message="$PUBLISH_TAG: debug build of ${BUILD_SHA:-unknown}

Tree and parent are $DEFAULT_BRANCH@$base_sha. This commit only exists to give
the rolling debug release a fresh date so it stays near the top of the Releases
list (GitHub orders releases by the tagged commit's date). The debug build's
source is ${BUILD_SHA:-unknown}; see tool/bump_rolling_release_tag.sh."

if ! new_sha="$(gh api -X POST "repos/$REPO/git/commits" \
  -f "message=$message" \
  -f "tree=$tree_sha" \
  -f "parents[]=$base_sha" \
  --jq '.sha')" || ! is_sha "$new_sha"; then
  warn "cannot create bump commit on $REPO; tag $PUBLISH_TAG left at $old_sha."
  exit 0
fi

if ! moved_sha="$(gh api -X PATCH "repos/$REPO/git/refs/tags/$PUBLISH_TAG" \
  -f "sha=$new_sha" \
  -F force=true \
  --jq '.object.sha')" || [ "$moved_sha" != "$new_sha" ]; then
  warn "cannot move tag $PUBLISH_TAG to $new_sha; it stays at $old_sha until the next publish."
  exit 0
fi

echo "Moved $PUBLISH_TAG: $old_sha -> $new_sha (tree of $DEFAULT_BRANCH@$base_sha, build ${BUILD_SHA:-unknown})."
exit 0
