## BUG-4479 · mine-shortcut-focused-entry
- **报告**：2026-11-12（用户：查词弹窗制卡快捷键讨论中发现）
- **真实性**：✅ 真 bug。Alt+滚轮 / 手柄十字键 / 键盘绑定把当前词条（`.entry-current`）移到第 N 个词条后，按制卡快捷键（Ctrl+Enter / 手柄 X）或发音键（手柄 Y），`fushiPopupMineFirstEntry` / `fushiPopupPlayFirstAudio` 仍取全文第一颗 `.mine-button` / `.audio-button`（`fushi/assets/popup/popup.js` 旧 6195 / 6211 行 `__fushiRootNode().querySelector(...)`），制出来的是第 1 个词条的卡、播的是第 1 个词条的音。阅读器（readerCreateCardFromPopup → `mineFirstVisibleEntry`）、视频页、texthooker、手柄弹窗兜底、gal 浮窗、app 外剪贴板面板与浏览器扩展都走这两个 JS 入口，全部受影响。
- **[x] ① 已修复** — 新增 `__fushiPopupEntryActionButton(selector)`（`fushi/assets/popup/popup.js:6213`）：有当前词条就只在当前词条里找按钮，当前词条没有这颗按钮时返回 null（不退回去点别的词条，那会制错卡）；没移动过时才取第一个词条。两个入口改用它，扩展两份镜像同步。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js`：`testShortcutMineFollowsFocusedEntry` / `testShortcutMineNeverFallsBackFromFocusedEntry` / `testShortcutAudioFollowsFocusedEntry`（旧代码三条全红）。
- **备注**：同一 PR 给可制卡的「＋」加了制卡快捷键提示（`window.i18nMineShortcutHint`，按宿主实际派发的动作取用户当前绑定；漫画 / 首页查词 / app 外查词窗没有键盘制卡派发，不提示）。
