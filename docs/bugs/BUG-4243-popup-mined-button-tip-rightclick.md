## BUG-4243 · Windows 查词弹窗已制卡 ✓：提示错位、右键被宿主菜单抢
- **报告**：2026-11-09（应用内反馈 3UHYaFPP8g，windows 3.3.0-debug.24478：已制卡 ✓ 的提示飘到上一个词条上方；右键 ✓ 弹出「搜索 / 复制」；鼠标长按无效）
- **真实性**：✅ 真 bug（两处）：① `fushi/assets/popup/popup.js:5629`（修前）`setMineState` 直接写 `mineButton.title`，走 WebView2 原生提示；② `fushi/lib/src/pages/implementations/dictionary_popup_webview.dart:4148`（修前）Windows 宿主右键让位清单只有 `'.audio-button, .fushi-audio-menu'`，漏了已制卡 ✓
- **[x] ① 已修复** — popup.js 改走 `setInlineButtonTip(mineButton, …)`（三镜像同步）；宿主让位清单抽成 `kPopupOwnedContextMenuSelector`，加入 `.mine-button[data-mined="1"]:not([data-mining="1"])`
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js`（已制卡 / 已入队两条断言改为 `dataset.fushiTip` 且无 `title`）、`fushi/test/dictionary/popup_native_title_tooltip_guard_test.dart`、`fushi/test/pages/popup_owned_context_menu_selector_test.dart`
- **备注**：鼠标长按（`bindMinedCardManageTriggers` 只认 touch / pen）是否支持、或桌面提示文案只写「右键」，属产品决策，未改。

### 根因

① BUG-842 已规定弹窗内联按钮不得用原生 `title`：Windows WebView2 离屏合成，原生提示是独立 OS 窗口，
按父 HWND 原点 + 未拉伸逻辑坐标定位，与纹理实际合成位置错开。PR #2980 给已制卡 ✓ 加「管理」手势
提示时又写回了 `mineButton.title = …`，提示于是飘到上一个词条上方。

② Windows 宿主右键（`_showWindowsContextMenu`）按下即用 `elementFromPoint` 判断是否给 popup.js 自管右键的元素让位，
清单只写了 ♪ 和音频源菜单。PR #2980 新增的已制卡 ✓ 右键（`bindMinedCardManageTriggers` 的 contextmenu）不在清单里，
宿主的搜索 / 复制 `showMenu` 先弹出来，盖住了覆写 / 查看选择单。

### 修复

- `popup.js` `setMineState`：`setInlineButtonTip(mineButton, queued ? 入队提示 : (isMined ? 管理提示 : ''))`，
  空串时助手会清掉提示与 aria-label；三份镜像（`assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`）同步。
- `dictionary_popup_webview.dart`：新增 `kPopupOwnedContextMenuSelector`（与 popup.js 的 contextmenu 处理器一一对应，
  ✓ 按 popup.js 同一判据 `data-mined==='1' && data-mining!=='1'` 收窄，未制卡 + 仍弹宿主菜单）与
  `popupOwnedContextMenuHitTestJs`，`_secondaryClickHitsAudioButton` 改名 `_secondaryClickHitsPopupOwnedMenu`。

### 待验证（真机）

- Windows：悬停已制卡 ✓，提示贴在 ✓ 旁；右键 ✓ 弹覆写 / 查看选择单，不出现搜索 / 复制；右键未制卡 + 与正文仍弹宿主菜单。
