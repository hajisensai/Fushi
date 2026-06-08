## BUG-156 · 自动同步书籍和有声书文件开关误拉远端独有内容
- **报告**：2026-06-09（用户：自动同步里的“书籍/有声书文件”应是上传语义，不能再自动拉取远端独有内容）。
- **真实性**：是 bug。旧实现把 `syncContent` / `syncAudioBookFiles` 当成双向文件并集同步：互联书籍/有声书路径会处理 `diff.toPull`，云端书籍会先导入远端独有书籍，有声书包同步会拉取远端独有包，`SyncManager._handleImport` 在导入远端元数据时还会顺手补下载内容文件。修复落点：`hibiki/lib/src/sync/sync_orchestrator.dart:352`、`hibiki/lib/src/sync/sync_orchestrator.dart:740`、`hibiki/lib/src/sync/sync_orchestrator.dart:908`，以及 `hibiki/lib/src/sync/sync_manager.dart:468`。
- **[x] ① 已修复** - 提交：`a80acc1a6`。本次把“书籍文件/有声书文件”改成上传语义：自动同步只上传本机独有 EPUB / 有声书包，不再自动拉取远端独有内容；远端元数据、阅读进度、视频/有声书位置等仍走 SyncManager 的冲突解决和导入路径，但不会附带下载文件。同步设置文案改成“上传书籍文件 / 上传有声书文件”，并移除有声书位置开关、仓库层强制返回开启。
- **[x] ② 已加自动化测试** - `hibiki/test/sync/sync_orchestrator_live_book_test.dart`、`hibiki/test/sync/sync_orchestrator_live_audio_test.dart`、`hibiki/test/sync/sync_orchestrator_test.dart`、`hibiki/test/sync/sync_gating_test.dart`、`hibiki/test/sync/sync_repository_test.dart`、`hibiki/test/sync/sync_settings_visibility_test.dart`、`hibiki/test/settings/settings_schema_coverage_test.dart`、`hibiki/test/settings/settings_redesign_static_test.dart` 覆盖上传语义、元数据导入不下载文件、有声书位置强制开启和设置项移除。
- **备注**：远端独有书籍/有声书文件如需落本机，必须走显式下载入口；不能由后台自动同步悄悄拉取。
