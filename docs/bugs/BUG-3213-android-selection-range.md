## BUG-3213 · Android 长按选词高亮范围与实际不符
- **报告**：2026-10-09（用户：Android 上长按选词的蓝色高亮范围和实际不符；Windows / iOS 复现不了；附视频无法查看）
- **真实性**：❌ 未复现。本次没有可用的 Android 设备（`adb devices` 为空），也看不到用户视频。静态走查：触屏长按选区走
  `fushi/lib/src/reader/reader_selection_scripts.dart` 的 `beginRangeSelection` / `updateRangeSelection` / `endRangeSelection`（app 自绘
  `::highlight(fushi-selection)`，手柄色 `--fushi-sel-handle` 回落 `#3a5fad` 蓝），Android 走 `reader_content_styles.dart`
  `_touchNativeSelectionCss` 的非 iOS 分支（`user-select:none` 压掉原生选区）。若设备主指针不是 coarse（接鼠标 / 触控笔的平板），
  该 media query 不生效，原生 ICU 分词蓝色选区会与 app 的匹配范围并存——这是一个待验证的假设，不是结论。
- **[ ] ① 未修复** — 需在 Android 真机 / 模拟器复现并拿到用户的设备型号、阅读模式（翻页 / 滚动 / VN）与是否接外设后再定位。
- **[ ] ② 未加自动化测试** —
- **备注**：「去掉蓝色高亮」是产品取舍，不做。
