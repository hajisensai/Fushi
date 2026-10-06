## BUG-2994 · 漫画/视频导入进行中对话框可被返回键/点遮罩关闭
- **报告**：2026-10-06（Codex 第六轮审查 HBK-AUDIT-037，历史遗留；复现 `fushi/test/media/import/import_dialog_busy_dismissal_repro.dart`，分支 `codex/sh-style-review-1006` `44de74851db`）
- **真实性**：✅ 真 bug（根因：共享守卫 `fushi/lib/src/media/import/import_flow_mixin.dart:96` `buildImportPopGuard` 只接进了书/有声书导入；`fushi/lib/src/media/manga/manga_import_dialog.dart:153`、`fushi/lib/src/media/video/video_import_dialog.dart:667` 的 build 没包它，漫画「取消」键 `manga_import_dialog.dart:169` 也不随 importing 禁用；同型遗漏还有 `iptv_playlist_import_dialog.dart` 与 `srt_book_reimport_dialog.dart`）
- **[x] ① 已修复** — 四个对话框的 build 统一包 `buildImportPopGuard`（`PopScope(canPop: !importing)`；返回键 / Esc / 点遮罩都走 maybePop，一并被挡），漫画取消键导入中禁用；导入成功路径用 `Navigator.pop` 显式关闭不受影响
- **[x] ② 已加自动化测试** — `fushi/test/media/import/import_dialog_busy_pop_guard_test.dart`（真实漫画/视频/IPTV 对话框 + 真 mixin，受控 Completer 挂起：maybePop 与点遮罩都关不掉，完成后可关闭；3 例）
- **备注**：仍没有真实取消协议；SRT 重导对话框未单独建测试（构造需要真书行），同一守卫。
