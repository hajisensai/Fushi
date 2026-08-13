#!/usr/bin/env bash
# 发布序号（release sequence）的**单一真相源**。
#
#   序号 = `git rev-list --count HEAD` + 一次性地板 RELEASE_SEQUENCE_FLOOR
#
# ## 为什么需要地板
#
# 提交计数只在「历史只增不减」的前提下单调。重写历史会让它**倒退**：
# 2026-08-12 develop 被强推成重写后的历史，计数从 10546 掉到 9466，而当时
# 已发布、已装到用户机器上的最大序号是 10405（fushi-debug-rolling）。
#
# 序号同时喂三处单调比较，倒退会把它们一起锁死：
#   1. Android versionCode = versionCodeBase + 100 * seq + abiOffset
#      （fushi/android/app/build.gradle）→ 比已装的小，系统安装器拒装；
#   2. app 内更新器按 releaseSequence 做全序比较
#      （fushi/lib/src/utils/misc/update_checker_release.dart）→ 判远端
#      「不比本机新」，永远提示已是最新，用户再也收不到任何更新；
#   3. tool/merge_update_manifest.py 的单调守卫「Never downgrades the
#      advertised top-level release」→ 新包压根写不进清单。
#
# 这三处都不是 bug——它们正确地拒绝了一个序号更小的包。错的是序号倒退。
# 同款手法已有先例：build.gradle 的 versionCodeBase = 1e9 就是一次性地板。
#
# ## 什么时候要再抬地板
#
# 只有**再次**重写历史、且新的 `count + FLOOR` 不再高于「已发布过的最大
# 序号」时才需要抬。抬之前先去查真实的最大已发布序号（GitHub Release 资产
# 名里的 `-debug.<seq>` / `-beta.<seq>`），别凭感觉加。
#
# 守卫：fushi/test/build/release_sequence_floor_guard_test.dart
set -euo pipefail

# 10546 = 重写前 develop 曾推上去的最大计数（已发布最大 10405）。加余量取
# 2000：重写后 develop 9473 + 2000 = 11473 > 10546；桥包分支 9114 + 2000
# = 11114 同样越过，跨分支发布不会再撞回旧序号。
RELEASE_SEQUENCE_FLOOR=2000

count=$(git rev-list --count HEAD)
if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
  echo "::error title=Invalid release sequence::Expected positive git rev-list count, got $count" >&2
  exit 1
fi

echo "$((count + RELEASE_SEQUENCE_FLOOR))"
