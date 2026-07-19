## BUG-911 · fail-open 静默吞异常致线上不可诊断（补 ErrorLogService 日志）

- **报告**：2026-07-19（审计复核）
- **真实性**：✅ 真 bug（沿真实代码路径定位，四处 catch 确认无日志）。
- **[x] ① 已修复** — 仅补日志，不改任何 fail-open 语义。
- **[x] ② 已加自动化测试** — `hibiki/test/diagnostics/fail_open_logging_guard_test.dart`（源码扫描守卫，方法体切片锚点）。
- **备注**：真机复测各失败路径的日志留痕待做。

### 现象
导出失败、Jimaku 搜索失败、视频观看统计写库失败、阅读统计/位置落盘失败等场景，异常被 catch 静默吞掉（继续降级 / 返回空 / fire-and-forget），线上无任何留痕，无法区分「真的没结果」与「出错了」。

### 根因
以下 catch 只降级不记日志（`ErrorLogService.instance.log(source, e, [stack])` 用户错误 / `.logDiagnostic(source, info)` 预期网络失败）：
- `AppModel` yomitan 自启动 `app_model.dart:2049` `.catchError((Object _) {})` 空吞（邻居 startSyncServer 已记日志，唯此不一致）。
- `collection_exporter.dart:917` `catch (_)` 只 `notify(导出失败)`，异常本体未进日志。
- `jimaku_client.dart` `_searchEntries:259` / `listFiles:277` / `downloadFile:291` catch 返回空/null；解析兜底 `parseJimakuEntries:95` / `parseJimakuFiles:207` 亦然——搜索失败与「无字幕」不可区分。
- `video_watch_tracker.dart` `_flush()` 整段 DB 写无 try/catch，由 `Timer.periodic(60s) → unawaited(_flush())` fire-and-forget 调用，异常未捕获静默丢弃。
- `navigation.part.dart` `_flushReadingStats:1190` 只 `debugPrint`（release 不可见）；`_persistPosition` 的 `repo.save` 无 catch。

### 修复
只在 catch 补日志，**return/降级/fire-and-forget 语义全部不变**：
- yomitan：`app_model.dart:2049` catchError 记 `ErrorLogService.instance.log('AppModel.startYomitanApiServer.autostart', e, s)`。
- 导出：`collection_exporter.dart:920` 记 `log('collectionExport.saveOrShareExport', e, s)`，保留 notify。
- Jimaku：5 处补 `logDiagnostic('JimakuClient.<method>', e)`（预期网络失败，不刷用户错误计数），仍返回空/null。
- 观看统计：`video_watch_tracker.dart:_flush()` DB 写段包 try/catch，`:175` `log('VideoWatchTracker.flush', e, st)`，`_tickStart` 复位与早返回留 try 外、异常不冒泡不阻塞播放。
- 阅读统计/位置：`navigation.part.dart:_flushReadingStats` catch 保留 debugPrint 并补 `log(...)`；`_persistPosition` 的 `repo.save` 包 catch 补 log（fail-open，下次 debounce/flush 重试）。
