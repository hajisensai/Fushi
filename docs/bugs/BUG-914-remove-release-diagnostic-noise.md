## BUG-914 · 发布版残留诊断日志/性能打点（查词·弹窗·按句同步热路径）

- **报告**：2026-07-19（审计复核）
- **真实性**：✅ 真问题（裸 `debugPrint`/`print`/`Stopwatch` 落在按句/按查词热路径，`debugPrint` release 不剥离）。
- **[x] ① 已清理** — 移除探针簇 + 收敛因探针而生的死代码。
- **[x] ② 已加自动化测试** — 源码扫描守卫：`hibiki/test/lookup/dict_perf_probe_removal_guard_test.dart`、`hibiki/test/media/audiobook/audiobook_probe_removal_guard_test.dart`、`hibiki/test/pages/popup_latch_and_longpress_guard_test.dart`、`hibiki/test/models/app_model_audit_hardening_guard_test.dart`。
- **备注**：竖排 `[792-*]`/`[753-DIAG]` 探针已由 BUG-902 单独移除，不在本条。`integration_test/lookup_latency_perf_itest.dart` 的 latency 探针是有意的性能测试，保留。

### 现象
release 构建下每次查词 / 每次弹窗推送 / 播放期每句高亮都打印 `[dict-perf]` / `[popup-perf]` / `[video-lookup]` / `[hibiki-autoread]` / `[sasayaki-hl]` / `[hibiki-crossChapter]` trace，污染日志、吃 UI 线程。

### 根因
一簇取证已完成的临时性能探针散落在最热路径上、无 `kDebugMode` 门控：
- 查词核心 `app_model.dart`：`normalizeSearchTerm` 三段 Stopwatch + `searchDictionary` 6 处 `[dict-perf]` debugPrint；探针耦合出一个 `NormalizedSearchTerm` record（三个 `*Micros` 字段纯为打点）。
- FFI `hoshidicts.dart` `[dict-perf] native call/convert`；历史落库 `dictionary_repository.dart` `[dict-perf] persistHistory`。
- 弹窗/结果 UI：`base_source_page.dart`、`dictionary_page_mixin.dart`、`popup_dictionary_page.dart`（`[popup-perf]`）、`dictionary_popup_webview.dart`（`[dict-perf] evaluateJavascript`）、`video_hibiki/lookup_favorite.part.dart`（`[video-lookup]`）。
- autoread `lookup_audio_playback.dart` `[hibiki-autoread]`。
- 按句同步 `audiobook_bridge.dart`（`[sasayaki-hl]` 逐 cue）、`audiobook_controller.dart`（`[hibiki-crossChapter]` print）。

### 修复
逐个核实为纯观测（无副作用）后移除 debugPrint/print/Stopwatch 及调用点，并收敛因探针而生的死代码：
- `NormalizedSearchTerm` typedef 删除，`normalizeSearchTerm` 返回类型收敛为 `String`（保留 emoji/标点/surrogate 清洗逻辑本身），同步改调用点与 `app_model_search_pure_logic_test.dart`。
- `audiobook_controller.dart` 删打点后 `_maybeEmitCrossChapter` 的 `quiet` 参数变死 plumbing，一并移除（签名/调用点/空 if 包裹）。
- `lookup_audio_playback.dart` 删打点后 `flutter/foundation.dart` import 与 `ok`/`sources` 局部变量变死，一并清理。
- 保留：catch 里的错误日志、`[Hibiki] init:` 一次性启动日志、ErrorLogService 管道、参与控制流的功能性 Stopwatch。
