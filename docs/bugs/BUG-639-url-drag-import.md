## BUG-639 · 拖动链接(URL)进桌面窗口直接添加为视频（TODO-1306，feature）
- **报告**：2026-07-08（用户：功能诉求）
- **真实性**：✅ 真缺口（非崩溃）。浏览器地址栏/链接拖进 app 无任何反应。根因两层：
  ① 原生 desktop_drop 0.5.0 三桌面平台只抽文件路径，浏览器拖来的 URL 被丢：
     - Windows `Drop()` 只读 `CF_HDROP`（`third_party/desktop_drop/windows/desktop_drop_plugin.cpp:253` 附近），URL 走的 `CFSTR_INETURLW` 被忽略；
     - macOS `performDragOperation` 用 `urlReadingFileURLsOnly:true` 且只注册 `.fileURL`（`third_party/desktop_drop/macos/Classes/DesktopDropPlugin.swift:36/120`），`public.url` 收不到；
     - Linux 原生已转发整份 text/uri-list，但 Dart 通道 `performOperation_linux` 对每行 `Uri.toFilePath()`——http(s) URI 抛异常被吞成空串丢弃（`third_party/desktop_drop/lib/src/channel.dart:113`）。
  ② Dart 分类 `classifyDroppedFiles` 按扩展名分，URL 无扩展名 → unknown → ignore（`hibiki/lib/src/media/drag_drop/drop_classification.dart`）。
- **[x] ① 已修复** — 方案 A（vendor/fork desktop_drop → `third_party/desktop_drop`，pubspec dependency_overrides 指过去）：
  - Windows：`Drop()` 无 CF_HDROP 时抽 `CFSTR_INETURLW`（或 http 前缀守卫的 `CF_UNICODETEXT`），URL 走同一条 `performOperation` 列表（`windows/desktop_drop_plugin.cpp` `ExtractDroppedUrl`）。
  - macOS：注册 `.URL` 拖放类型 + 从 pasteboard 读非 file 的 `NSURL`，`absoluteString` 作 "path"（`macos/Classes/DesktopDropPlugin.swift`）。
  - Linux：`performOperation_linux` 保留 http(s) URI 不 toFilePath（`lib/src/channel.dart`）。
  - Dart：`DroppedFiles.urls` + `isImportableDropUrl`（按 scheme 甄别，`drop_classification.dart`）；`DropIntent.importVideoUrl`（`drop_decision.dart`，books/video 两表面自动切视频导入）；`VideoImportDialog.initialStreamUrl`（`video_import_dialog.dart`，预填 URL + 可播则自动走既有 `_importStreamUrl` 入库）；路由 `home_video_page.dart` / `reader_history/video.part.dart` `_openStreamImportPrefilled`。
  - 提交：见分支 `todo1306-url-drag-import`。
  - ⚠️ 原生 C++/Swift worktree 编不动，须 **CI Build Desktop（build-multiplatform.yml，workflow_dispatch / ci-** 触发）** 真机验证 Windows/macOS/Linux 拖 URL 入库；Dart 路由已 headless 覆盖。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/drag_drop/drop_classification_test.dart`：http(s) URL → urls（非 unknown/videos）、盘符路径不误判、混合拖入、hasAny。
  - `hibiki/test/media/drag_drop/drop_decision_test.dart`：books/video 两表面 urls → `importVideoUrl`、优先级。
  - `hibiki/test/media/drag_drop/url_drop_url_predicate_guard_test.dart`：`isImportableDropUrl` ⟺ `isPlayableStreamUrl` 单一真相源钉死。
  - `hibiki/test/media/drag_drop/url_drop_native_guard_test.dart`：源码扫描守卫三平台 URL 抽取分支（Windows CFSTR_INETURLW / macOS public.url / Linux http 保留）。
- **备注**：desktop_drop 由 pub-cache ci-patch 迁为 vendored fork（`third_party/desktop_drop/PATCHES.md`）；原 TODO-1275/BUG-361 reinitialize 不变量随迁，守卫 `desktop_drop_reinit_test.dart` 已重指向量 vendored 路径。与 TODO-1237（video_import_dialog）无冲突（仅新增 `initialStreamUrl` 参数与 initState 分支，不改既有逻辑）。
