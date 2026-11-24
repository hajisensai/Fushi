## BUG-5424 · lyrics-illustration-viewer-right-click
- **报告**：2026-11-25（应用内反馈 oYQN9hgT9G，Windows：歌词模式插图大图浏览里右键没反应）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart`：插图大图页 `_buildUnlockedPage` 与插图卡 `_IllustrationCard` 的 `GestureDetector` 只挂了 `onLongPress: _longPressFor(...)`，没有任何右键入口；阅读器正文看图（`reader_fushi/chrome.part.dart` `_openImageViewer`）与书架插图册（`illustrations_viewer_page.dart` `_openZoom`）都是 Windows 用 `ContextMenuTrigger` 弹「保存 / 复制」、其余平台长按出图片动作面板，歌词模式插图漏接了 Windows 这条腿。
- **[x] ① 已修复** — 新增 `_illustrationContextMenu`：Windows 且有磁盘文件时用 `ContextMenuTrigger`（唤出键由绑定表决定、阶梯 `kReaderMouseLadder`）弹 `showImageCopyContextMenu`（保存 / 复制），插图卡与插图大图都包上；`_longPressFor` 在 Windows 不挂长按，与阅读器看图一致。`kReaderMouseLadder` 从阅读器页的 part 文件（`caret.part.dart`）挪到 `shortcuts/context_menu_trigger.dart`，media 层的插图大图才够得着同一条阶梯。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_illustration_view_test.dart`「Windows：右键插图卡 / 插图大图弹保存 / 复制菜单」；原长按用例钉成非 Windows 平台。
- **备注**：macOS / Linux 上图片右键在阅读器正文看图、书架插图册、歌词模式插图三处同样不挂（沿用现有 `isWindowsPlatform` 约定），本次不扩范围。
