## BUG-2960 · 阅读器选中时打开导航、插图、统计或有声书，选择控件残留在覆盖页面上

- **报告**：2026-10-05（用户：选中状态打开导航、浏览插图、阅读统计，手柄浮在上面；后续补充点击有声书仍会上浮）。
- **真实性**：✅ 真 bug。JS 手柄和 Flutter 非模态操作条是两个独立生命周期。原 `chrome.part.dart` 的 `_presentSideSheet`、画廊/看图/统计中心入口不清理选择；未绑定音频的耳机键直接进入 `audiobook.part.dart:2153` `_openAudioImportDialog`，绕过侧栏。操作条通过 `Overlay.insert` 插入，无法随阅读器路由自动收起；JS `clearSelection` 原来也不通知 Flutter。源路径均位于 `fushi/lib/src/pages/implementations/reader_fushi/`。
- **[x] ① 已修复** — 本轮修复提交（见分支日志）：
  - `chrome.part.dart:2141` 侧栏入口以及画廊/图片/统计中心先 await 完整选择清理，再呈现新页面。
  - `navigation.part.dart:1816` 所有压住正文的 modal 共用 `_withStudyClockPaused` 选择边界，覆盖有声书导入、SRT 重导、对齐文件、转录及歌词提示；在首个 await 前增加 depth，销毁后不继续开页，finally 恢复 depth。
  - `chrome.part.dart:402` 拒绝非当前路由、待开侧栏或 modal depth 非零时迟到的选区菜单。
  - `webview.part.dart:2056` 接 `onSelectionDragStarted` / `onSelectionCleared`，只移除宿主操作条，不反调 JS；JS 拖动中不再被旧工具条遮挡，清选区时跨层同步。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_selection_overlay_lifecycle_guard_test.dart` 覆盖共同边界、耳机键无音频分支、SRT/对齐/转录、首 await 顺序和迟到菜单；JS 事件链由 `reader_selection_drag_hit_behavior_test.js` / `reader_selection_viewport_behavior_test.js` 执行。既有布局、图集和学习计时测试无回归。
- **证据**：初审 `.codex-test/reader-selection-audit/overlay-review/` 的 Flutter probe 已复现独立 Overlay 在覆盖路由上仍可点击；最终定向验证记录 `.codex-test/reader-selection-audit/final-validation.log`。
- **备注**：`implemented_unverified`。用户后续明确要求不再 adb；最终补修未在 Android/iOS 重测。源码接线、JS 行为和独立 Flutter widget 测试不冒充手机平台合成验收。旧的 15:14 构建不包含最后的有声书共同边界和竖排避让。