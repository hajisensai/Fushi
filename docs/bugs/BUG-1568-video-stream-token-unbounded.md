## BUG-1568 · 视频流 token 签发侧无上限无过期清理
- **报告**：2026-08-12（用户：互联健壮性审计）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/fushi_sync_server.dart`（修复前
  GET `/api/library/videos/<id>/streamurl` 签发分支 ~1714 行）：`_generateVideoToken()`
  后直接插 `_videoStreamTokens`，签发侧既不 prune 也无上限；`_pruneVideoTokens()`
  （6h TTL）只挂在 GET `/stream` **消费侧**——只签发不取流的调用者（反复进出视频页 /
  爬清单脚本）让 map 无界堆积。audio token 的同形问题 BUG-908(a) 已修（POST 侧
  prune + `_maxAudioTokens=128` cap），video 漏了。
- **[x] ① 已修复** — 照 audio 修法补齐：签发前 `_pruneVideoTokens()` +
  `_enforceVideoTokenCap()`（`_maxVideoStreamTokens = 128`，TTL prune 后仍达上限则
  按 createdAt 淘汰最旧者，插入后总数 ≤ 上限）；新增 `@visibleForTesting
  videoStreamTokenCount` 测试钩子（对照 `remoteAudioTokenCount`）。
- **[x] ② 已加自动化测试** —
  `fushi/test/sync/fushi_sync_server_video_token_cap_test.dart`：固定时钟（TTL 清不掉
  任何 token）下狂发 150 次 streamurl 签发，断言驻留 token ≤ 128（镜像
  `fushi_sync_server_hardening_test.dart` 的 BUG-908(a) 组）。变异实测：注释掉签发侧
  `_enforceVideoTokenCap()` 用例红（150 > 128）。
- **备注**：cap 逐出按 createdAt（video token 无「命中续期」），极端场景下一次
  播放会话内发生 128 次新签发才可能逐出正在播放的 token，正常使用不可达；与
  audio 的既有取舍一致。
