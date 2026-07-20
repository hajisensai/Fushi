## BUG-913 · 常驻服务/Notifier/provider 未对称释放（泄漏）

- **报告**：2026-07-19（审计复核）
- **真实性**：✅ 真 bug（对照 initialise/dispose 确认只起未关）。
- **[x] ① 已修复** — dispose 补关 4 个常驻服务 + 2 个 family 加 autoDispose + notifier 补 dispose。
- **[x] ② 已加自动化测试** — `hibiki/test/models/app_model_audit_hardening_guard_test.dart`（dispose 体切片断言含 4 个 stop + syncServer dispose、两 family 含 `.autoDispose`）；base_source dispose 守卫在 `hibiki/test/lookup/dict_perf_probe_removal_guard_test.dart`。
- **备注**：AppModel 无法在单测实例化，取源码扫描守卫为最强可落地层。

### 现象
退出/切换后台仍有后台 socket/WS 连接、轮询 Timer、HttpServer bind 常驻；长会话内查词越多，provider 实例只增不减，内存单调增长。

### 根因
- **`AppModel.dispose`（app_model.dart）漏关 4 个 initialise 起的常驻子系统**：LAN sync server（`syncServerController.startIfEnabled()` @2029）、texthooker（`TexthookerWsClientHost.instance.start` @2060）、yomitan（`startYomitanApiServer()` @2048）、anime 下载服务（`AnimeDownloadService..start()` @2072）。它们各自的 `stop()` 都存在，但 dispose 从未调用——纯只起未关泄漏。
- **family provider 无界累积**：`quickActionColorProvider`（`FutureProvider.family`，:150）与 `visibleOnceProvider`（`StateProvider.family`，:168）key 为 `DictionaryEntry`，无 autoDispose，随查词单调增长（前者还缓存整份颜色 Map）。
- **`_isSearchingNotifier`**（`base_source_page.dart:118` ValueNotifier）创建后从未 dispose，且被 `Listenable.merge` 挂监听，泄漏面更实。

### 修复
- `dispose()` 在 `super.dispose()` 之前、走现有 notifier/repo dispose 之前，补 fire-and-forget 停 4 个常驻服务：`unawaited(syncServerController.stop())` + `syncServerController.dispose()`（包 `if (_isInitialised)`，与现有 dictRepo 守卫一致）、`TexthookerWsClientHost.instance.stop()`（单例安全）、`unawaited(stopYomitanApiServer())`（null 安全）、`_animeDownloadService?.stop()`（其 stop 是同步 `void`，不 unawaited）。不动 initialise 启动逻辑。
- 两 family 改 `.autoDispose.family`（弹窗内联颜色/一次性可见标记，弹窗关即应释放，autoDispose 语义正确）。reader Language family 有界，不动。
- `base_source_page.dart` dispose 在 `super.dispose()` 前补 `_isSearchingNotifier.dispose()`。
