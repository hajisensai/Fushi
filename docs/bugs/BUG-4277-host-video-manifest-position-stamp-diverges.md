## BUG-4277 · host 视频清单与位置端点对同一断点给出不同的位置 / 时间戳
- **报告**：2026-11-10（用户：审计 sync-live 修复包 D4b）
- **真实性**：✅ 真 bug。host 视频位置有两套派生口径：
  - 清单：`packages/fushi_engine/lib/sync/local_library_host_service/videos.part.dart:274-284`（修复前）把 `VideoBooks.lastPositionMs` 按戳 `0` 参与 `resolvePositionLww`。
  - 位置端点：同文件 `:597-627` `getVideoPosition`（`GET .../position` 与 `PUT .../position` 的判定共用）按戳 `importedAt` 参与（BUG-996 只改了这一处）。
  - 后果：「host 只有行位置」时清单戳为 0、GET 戳为 importedAt；「prefs 戳早于 importedAt」时清单取 prefs 断点、GET 取行断点。client sweep 的 `readHost`（`fushi/lib/src/sync/sync_orchestrator/videos.part.dart:91-98`）读清单、host 判定读 GET 口径，两边对不上，后续前置条件比较与 `isSettled` 都无法收敛。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：wire 字段不变；只有「host 只有行位置」条目在清单里的 `positionUpdatedAtMs` 从 0 变成 `importedAt`，与 `GET .../position` 同值。旧 client：有基线的条目按基线判不受影响；无基线的条目改按两端戳 LWW，与它自己读 GET 时的口径一致。
