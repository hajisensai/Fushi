## BUG-4911 · 网页视频制卡整轮出错时提示仍是成功 0 失败 0
- **报告**：2026-11-20（路线图 #3722 遗留（docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md 第 3 节），c14 留下的「整轮准备步骤抛出时提示仍是成功 0 / 失败 0」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/web_video_fushi_page.dart` 的 `_runMineQueue` 在 `runWebMineQueueRound` 之后无条件 `_finishMining(status: WebMineAutoFinished(ok, failed, remaining))`，不区分这一轮是不是出错中止：准备步骤抛出时显示「已制卡 0，失败 0」，像是没东西可做；自动跑一行抛出 / 表面死亡后 `remaining > 0`，胶囊说成「你回来了，已暂停」。
- **[x] ① 已修复** — 本分支 c14 提交：`webMineRoundEndedOnError`（null / rowThrew / surfaceLost）进 `WebMineAutoFinished.errored`，胶囊与交接页 / 后台页 Toast 统一走 `webMineFinishedText`，出错时显示「制卡出错中止（详见错误日志）：成功 N，失败 M」；后台页即使 0 / 0 也提示。空闲放弃整本的判据复用同一函数。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/web_mine_auto_status_test.dart`（文案 + 胶囊 widget）、`fushi/test/mining/web_mine_queue_run_test.dart`（判据）、`fushi/test/media/video/web_video_mine_queue_guard_test.dart`（页面把判据带进结果）。
- **备注**：只做「出错」状态文案这一半；失败行的显示与重试入口（gap-webvideo-6）按拍板另做。真 app / Android 上的网页队列未验。
