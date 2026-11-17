## BUG-4791 · 阅读器关书（返回键）等着追踪上报，未映射的书会等一次站点搜索
- **报告**：2026-11-17（用户：小说优化清单 novel-12，代码复核确认）
- **真实性**：✅ 真 bug（沿代码路径确认，未做慢网复现）。根因是「一段没有延迟上界的网络调用被压在返回键的等待链上」：
  - `fushi/lib/src/pages/implementations/reader_fushi_page.dart` `onSourcePagePop` → `await _syncAndFlushPosition()` → `_flushPosition` → `_persistPosition`；修复前 `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1708-1713`（基准 4c347287835）在 `_persistPosition` 末尾 `await appModel.mediaTrackingService.recordBookProgress(...)`。
  - `packages/fushi_engine/lib/media/tracking/media_tracking_service.dart:2185-2207` `recordBookProgress` 先 `await _ensureAutoBookMapping`（无映射且已配置时内联一次 Bangumi 搜索，`searchSubjects` 没有请求级超时），再 `await _sendBookProgress`（卷号 > 1 时还会内联 `readEntry`）。
  - 窗口不只是「搜索在途时按返回」：打开一本未映射的书、没翻页就按返回，退出 flush 自己就是第一次 `_persistPosition`，搜索直接在退出路径上发起并被等待。慢网下返回键表现为按了没反应。
  - 附带：每次位置落库（500 ms 防抖，每翻一页一次）都调一次 `recordBookProgress`，其中 `_isIgnored` / `findMapping` / `loadBookTrackingSnapshot` 等库查询都在「没前进就跳过」的短路之前，章内翻页也照跑。
- **[x] ① 已修复** — `recordBookProgress` 挪出等待链：`_persistPosition`（`navigation.part.dart`）改经 `ReaderTrackingProgressReporter.report` 只发起、不等；同一份「完成章数 + 是否读完」只报一次（去重键含 `progress >= 0.999` 的 +1，不是章号）；失败记 `ErrorLogService`（`ReaderFushi.recordBookProgress`）并忘掉这份进度，下次落库照常再报。「读完」写库（`markEpubBookCompletedIfUnset`）仍在被等待的那一段。进程退出（`_flushAllForProcessExit`）在本地写穿之后把在途上报等完，仍受 `ExitFlushRegistry` 的单回调超时约束。新文件 `fushi/lib/src/reader/reader_tracking_progress_reporter.dart`。提交见本分支 `pr/reader-nav-lookup-state`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_tracking_progress_reporter_test.dart`：上报口真行为（send 挂着时 `report` 已返回、去重、只有「读完」变也报、失败后再报、同步抛错走 onError、`whenSettled`）+ 接线守卫（`_persistPosition` 不 await `recordBookProgress`、读完写库在前且被等待、追踪关着不发起、退出等完且排在本地写穿之后、返回键链不等上报）。
- **备注**：待真机复测原始失败路径——开追踪 + 未映射的书，限速 / 断网下翻一页立刻按返回，应立即退出；恢复网络后 Bangumi 进度仍应报上去。未做的原因：本轮多组并发共用设备，不做真机。
