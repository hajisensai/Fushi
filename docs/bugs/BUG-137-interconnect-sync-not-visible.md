## BUG-137 · Hibiki互联同步后手机端内容不刷新且失败缺少明细
- **报告**：2026-06-08（用户：hibiki互联，我手机同步电脑上数据有6个失败，并且所有同步的内容没加到我手机上面（至少没显示）。而且同步速度好慢啊，内网应该很快才对）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/sync/sync_auto_trigger.dart:183-185` / `:259-261` 同步完成前后原本没有本地库刷新钩子，失败明细也没有落错误日志。
- **[x] ① 已修复** — 提交 `034d74cb6`
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_summary_test.dart` + `hibiki/test/sync/sync_progress_test.dart`
- **备注**：未在用户真机上复测互联全链路；本轮按真实同步代码路径修复并用聚焦测试覆盖。

### 根因
互联全量同步由 `triggerAutoSyncOnAppOpen`（打开 App 自动同步）和 `runManualFullSync`（设置页手动同步）进入 `SyncOrchestrator.run()`。`SyncOrchestrator` 会把远端书籍、词典、有声书、本地音频写入本机 Drift/文件系统，并在 `SyncRunReport` 里累计 `booksImported` / `dictionariesImported` / `audiobooksImported` / `localAudioImported`。

但同步入口拿到 `SyncRunReport` 后，原本只把冲突交给 `onReport` 或返回手动同步结果，没有刷新 `AppModel` 持有的词典缓存、路径缓存、首页 tab / Riverpod 依赖，也没有 `notifyListeners()`。因此手机端可能已经把数据拉下来了，但 UI 仍显示旧列表，直到之后某次重建或重启才可见，吻合“同步的内容没加到手机上面（至少没显示）”。

另一个问题是 `report.errors` 只参与“失败 N 项”的摘要展示，没有写入错误日志。用户看到“6 个失败”时无法直接定位是哪 6 个包/请求失败，后续排障只能猜。

同步慢的问题本轮没有伪装成已彻底解决：这次修的是“成功导入后不可见”和“失败缺少明细”。慢速还需要拿到新的 `SyncRunReport.errors` / 服务端日志 / 进度阶段耗时后继续定位，常见可能是失败重试、包导出/压缩、或旧暂存包清理路径。

### 修复
- `SyncRunReport` 新增 `needsLocalLibraryRefresh`，只在本机导入可见内容时返回 true，导出到远端的同步不会触发多余刷新。
- 自动同步和手动同步都新增 `onPostRun` 钩子，在 `orchestrator.run()` 完成后、展示冲突/摘要前执行。
- `AppModel.refreshAfterSyncRun` 在导入内容后刷新词典缓存、Hoshi 词典路径缓存、词典查询缓存、阅读/词典 tab，并 `notifyListeners()` 触发可见列表重算。
- `logSyncReportErrors` 把每项同步失败写入 `ErrorLogService`，下次“失败 6 项”时可以在错误日志里看到具体条目。

### 验证
- `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\sync\sync_summary_test.dart`
- `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\sync\sync_progress_test.dart`
