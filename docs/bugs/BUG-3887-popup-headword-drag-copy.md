## BUG-3887 · 查词弹窗拖选词头后 Ctrl+C 复制不了
- **报告**：2026-10-30（用户：视频页查词弹窗，选中词典标题的文字按 Ctrl+C 不行）
- **真实性**：✅ 真 bug。拖选词头 `.expression` 松手时，浏览器在按下 / 抬起的共同祖先上补发 `click`；词头点击处理器 `fushi/assets/popup/popup.js:5259`（`createEntryHeader` 的 `expressionSpan` click）不看选区，直接 `onLinkClick` → `navigatePopupInPlace`（`dictionary_page_mixin.dart`）原地重查同一个词 → `_pushResults` → `renderPopup` 重建 DOM，原生选区丢失，`_copyNativeSelectionToClipboard` 读到空串。它自己 `stopPropagation`，文档级 `__fushiPopupClick` 的拖动 / 选区门对它无效。自 `b388da7f0b`（09-11，弹窗内点词头原地跳转）起，之前是叠子层、父层选区不受影响。
- **[x] ① 已修复** — popup.js 新增 `__fushiClickEndsTextSelection()`（click 时仍有非折叠选区 = 拖选收尾），词头、汉字卡大字、结构化链接三个点击即查词入口命中即放过，不发 `onLinkClick`、不动选区；浏览器扩展 `vendor/popup.js` 同步。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` 的 `testHeadwordClickEndingDragSelectionKeepsSelection`（node 真跑 popup.js；去掉词头门禁时变异实测变红），经 `fushi/test/pages/popup_headword_drag_copy_test.dart` 接进 flutter test（CI 缺 node 直接失败）。
- **备注**：另一条未证实的嫌疑：`dc5703a0ec`（10-28，BUG-3855）删了 `custom_platform_view.dart` 按下时的 `requestFocus()`，Windows 弹窗 Ctrl+C 拦截层（`dictionary_popup_webview.dart` `_handleDesktopCopyKey`）依赖「平台视图 FocusNode 持焦」的前提可能已不成立。若修复后仍偶发「按 Ctrl+C 无任何提示」，查这条。
