## BUG-3919 · collapsible-header-dialog-intrinsics
- **报告**：2026-10-31（合并审查：第三方 PR #2666「折叠分组头尾随区半宽上限」引入）
- **真实性**：✅ 真 bug（合并审查发现，未进 develop）。PR #2666 在 `fushi/lib/src/utils/components/settings_shared.dart` `AdaptiveSettingsSurface._buildContainedTitle`（合并后 `:394`）把折叠头包进 `LayoutBuilder` 以取半宽上限。`LayoutBuilder` 不回答 intrinsic（Flutter 3.47.6 `packages/flutter/lib/src/widgets/layout_builder.dart:397/478`：debug 抛「LayoutBuilder does not support returning intrinsic dimensions」，release 恒答 0），而 AlertDialog 把正文包在 `IntrinsicWidth` 里——折叠分组直接当对话框正文就重演 BUG-3501。另外固定半宽上限对短标题也把长摘要截到半宽，余量白白空着。
- **[x] ① 已修复** — `79705b1c6d4`（提交信息里写的是撞号前的 BUG-3915）：折叠头改用自定义布局 `_CollapsibleHeaderLayout`（`fushi/lib/src/utils/components/settings_shared.dart`）替代 `LayoutBuilder`，自己回答 intrinsic；尾随区上限 = max(半宽, 总宽 − 标题天然宽)。
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_collapsible_header_narrow_test.dart`（同一提交扩展）。记录在撞号重排时没跟着勾，2026-11-05 补勾。
- **备注**：同批修正 PR #2664 的 `_kAiChoiceTrailingWidth = 250`（手算、注释写箭头 24 实为 22、MD3 内边距吃主题默认值、Apple 形态宽度完全不同）：改由同一组常量推出。
