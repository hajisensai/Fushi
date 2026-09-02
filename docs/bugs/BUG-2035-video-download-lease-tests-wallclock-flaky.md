## BUG-2035 · 下载租约续期测试对宿主调度抖动零容差，本机并发下必红
- **报告**：2026-09-02（发现于 BUG-2030 的定向回归跑，非用户报告）
- **真实性**：✅ 真（测试脆弱，不是产品缺陷）。两条用例：
  - `fushi/test/media/video/download/video_download_pipeline_service_test.dart` · `long enqueue renews its lease and cannot be claimed by another worker`
  - `fushi/test/media/video/download/video_download_subscription_service_test.dart` · `long provider search renews the subscription lease`
  - 形状：`leaseDuration = 90ms` → `VideoDownloadLeaseGuard` 心跳 `leaseDuration ~/ 3 = 30ms`（`video_download_pipeline_service.dart:707`）→ 测试 `await Future.delayed(240ms)` 后断言 `claimExpiresAt > DateTime.now()`。也就是要求「最后一次心跳落在断言前 90ms 内」，**用真实墙钟、零容差**。本机 5~10 个 agent 并发时 Dart 定时器被拖 100~600ms 是常态，实测两次失败差 146ms / 593ms，第二条还顺带 30s 超时。
  - 与本仓已知的三类并发伪红（互抢 `sqlite3.dll` / 宿主 IPC 崩溃 / 结果文件被抢）**不同形态**：这条是「真实时钟断言被调度抖动打穿」，单跑也会红，所以不能按伪红放过。
- **[ ] ① 未修复** — 建议方向（未实施）：把租约续期的时序从墙钟解耦——要么给测试注入可控时钟 / `fake_async`（同仓 `media_kit_video_restart_hide_timer_guard_test.dart` 已有这个范式），要么把断言从「过期时刻晚于此刻」改成「续期回调被调用过 ≥N 次」这类与调度速率无关的判据。放宽 `leaseDuration` 只是把红的概率往后推，不算根因修复。
- **[ ] ② 未加自动化测试** — 修复本身就是改测试。
- **备注**：**与 BUG-2030 无关**，只是在同一批定向跑里暴露：两个测试文件的 import 闭包完全不含视频页/控制条代码（`grep -c 'video_fushi|pages/implementations'` = 0），静态上不可能受那次改动影响。本轮不修（超出用户当轮范围），单独记档。
