## BUG-499 · SRT/有声书卡长按缺悬浮字幕菜单项
- **报告**：2026-07-01（用户：）· TODO-1068
- **真实性**：✅ 真 bug。根因：书架 EPUB 书卡长按菜单 `extraActions`（`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1158-1165`）有「悬浮字幕」项（`floating_lyric_toggle_action` → `_toggleFloatingLyricFromShelf`），但 SRT/有声书卡走另一套菜单 `_srtExtraActions`（`hibiki/lib/src/pages/implementations/reader_history/books.part.dart:121`，经 `_showSrtBookDialog:176` 调用），该菜单从未包含悬浮字幕项。用户长按 SRT/有声书卡时因此看不到「悬浮字幕」。
- **[x] ① 已修复** — 在 `_srtExtraActions` 的 `bookKey.isNotEmpty` 分支末尾对称补入悬浮字幕动作项（`hibiki/lib/src/pages/implementations/reader_history/books.part.dart:172-182`）：复用同一 i18n key `floating_lyric_toggle_action`、同一回调 `_toggleFloatingLyricFromShelf(bookKey)`、同一平台门控 `Platform.isAndroid || Platform.isWindows`、同一活动会话勾选逻辑 `_isBackgroundListeningBook`。未动 EPUB 侧、未改回调逻辑、未新增 i18n key。commit: <集成 owner 落地后补>
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/pages/booklongpress_floating_lyric_toggle_test.dart`：在 `srtActions` 切片新增三条断言（含 `floating_lyric_toggle_action` / `_toggleFloatingLyricFromShelf` / `Platform.isAndroid || Platform.isWindows`），防止 SRT 菜单再次丢失悬浮字幕入口。
- **备注**：host 测试跑不到 dialog 渲染与 Platform 分支，故用源码扫描守卫钉接线（与既有 EPUB 侧守卫同风格）。
