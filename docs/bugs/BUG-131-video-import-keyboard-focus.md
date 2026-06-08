## BUG-131 · 导入字幕后键盘快捷键失灵
- **报告**：2026-06-08（用户：导入字幕那一下还是会快捷键失灵 / Windows 桌面）
- **真实性**：✅ 真 bug（加载遮罩夺焦后未归还），根因 `video_hibiki_page.dart:1816 _hideSubtitleLoadingOverlay`。

### 根因（真实代码路径取证）
导入链路 `_pickAndImportSubtitle → _importExternalSubtitle → _selectSubtitleSource`。其中 `_selectSubtitleSource` 对文本字幕会弹**不可关的模态加载遮罩**（`_showSubtitleLoadingOverlay`，BUG-104 抽内封字幕用），它夺走窗口键盘焦点。`_pickAndImportSubtitle:1747` 的 `_refocusVideo()` 发生在加载遮罩**之前**、无效；而 `_hideSubtitleLoadingOverlay` 只 `Navigator.pop` 关掉遮罩、**没归还焦点**。代码自身注释（`_refocusVideo`）已说明「media_kit 覆盖层关闭后 Flutter 不会自动把焦点还给 Video 的 FocusNode」→ 焦点悬空，空格冒泡到全局被中和为 `DoNothingIntent`（`global_navigation.dart`）→ 快捷键失灵。底栏菜单选字幕源路径同理（sheet 的 whenComplete refocus 在加载遮罩之前）。

### 修复
`_hideSubtitleLoadingOverlay` pop 后 `addPostFrameCallback` 调 `_refocusVideo()`（下一帧，让 pop 自身焦点变更先落定）。这是所有「弹加载遮罩」路径（导入/菜单选源/Jimaku 下载）的统一收口点。

- **[x] ① 已修复** — `video_hibiki_page.dart _hideSubtitleLoadingOverlay` pop 后 post-frame `_refocusVideo()`。
- **[x] ② 已加自动化测试** — `test/pages/video_subtitle_fixes_guard_test.dart`（`_hideSubtitleLoadingOverlay` 含 `_refocusVideo()` + `addPostFrameCallback` 守卫）。
- **备注**：media_kit 无 headless，真机「导入字幕后空格仍可暂停」待用户复验。
