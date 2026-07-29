## BUG-1231 · 快捷键录入在 IME 下无法识别物理 Z
- **报告**：2026-07-29（用户：）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/shortcut_settings/binding_edit_dialog.part.dart:372-391`：录入层直接把 `KeyEvent.logicalKey` 存成 `InputBinding`，没有复用运行时已有的 IME 物理键回退。Windows IME 把物理 Z 的逻辑键改写成 `LogicalKeyboardKey.process` 时，稳定的 `event.physicalKey == PhysicalKeyboardKey.keyZ` 被丢弃，因此不能录成 `KeyZ`。这与显示冲突无关；`Z` 虽是视频字幕延迟默认键，但视频与阅读器分属不同 scope，本来就允许复用。
- **[x] ① 已修复** — `InputBinding.normalizeCapturedKey` 复用 `_logicalToPhysical` 真相源建立反向映射：仅当 `logicalKey == process` 时按 `physicalKey` 还原真实可录入键，正常逻辑键与非美式布局语义不变；快捷键录入 `_onKeyEvent` 在查重复/冲突前先走此规范化。
- **[x] ② 已加自动化测试** — `hibiki/test/shortcuts/input_binding_test.dart` 覆盖 `process + physical KeyZ → logical KeyZ`、正常逻辑键不被物理布局覆盖、未知物理键安全保留 `process`，并以源码接线守卫确认录入对话框同时传入 `event.logicalKey` 与 `event.physicalKey`。
- **备注**：物理键回退仍与既有运行时规则一样只在 `process` 时启用；若某个 IME 把 Z 改写为其它非 `process` 逻辑键，需要抓真机 KeyEvent 后再扩判据，不能无条件按 US-QWERTY 物理位置覆盖正常布局。
