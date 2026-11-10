## BUG-4387 · host 视频清单与位置端点对同一断点给出不同的位置 / 时间戳
- **报告**：2026-11-10（用户：审计 sync-live 修复包 D4b）
- **真实性**：✅ 真 bug。host 视频位置有两套派生口径：
  - 清单：`packages/fushi_engine/lib/sync/local_library_host_service/videos.part.dart:274-284`（修复前）把 `VideoBooks.lastPositionMs` 按戳 `0` 参与 `resolvePositionLww`。
  - 位置端点：同文件 `:597-627` `getVideoPosition`（`GET .../position` 与 `PUT .../position` 的判定共用）按戳 `importedAt` 参与（BUG-996 只改了这一处）。
  - 后果：「host 只有行位置」时清单戳为 0、GET 戳为 importedAt；「prefs 戳早于 importedAt」时清单取 prefs 断点、GET 取行断点。client sweep 的 `readHost`（`fushi/lib/src/sync/sync_orchestrator/videos.part.dart:91-98`）读清单、host 判定读 GET 口径，两边对不上，后续前置条件比较与 `isSettled` 都无法收敛。
- **[x] ① 已修复** — 7d78ecaacba：`videos.part.dart` 抽出私有纯函数 `_hostVideoPositionOf`（行位置戳 = 行位置 > 0 ? importedAt : 0，再与 prefs 断点经 `resolvePositionLww` 取较新）；`getVideoPosition`（episodeIndex<=0）与清单构造都改调它，清单用已预取的 prefs 快照与行字段，零额外查询（整书键即第 0 集键）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_client_video_parity_test.dart` 组「BUG-4387 host 视频位置清单与位置端点同口径」（真 `FushiSyncServer` + 真 `LocalLibraryHostService` + 内存库，经 HTTP 比 `GET /api/library/videos` 与 `GET .../position`）：只有行位置、prefs 戳早于 importedAt、prefs 戳晚于 importedAt 三条。修复前前两条红（清单分别给出戳 0、prefs 断点）。
- **备注**：wire 字段不变；只有「host 只有行位置」条目在清单里的 `positionUpdatedAtMs` 从 0 变成 `importedAt`，与 `GET .../position` 同值。旧 client：有基线的条目按基线判不受影响；无基线的条目改按两端戳 LWW，与它自己读 GET 时的口径一致。
