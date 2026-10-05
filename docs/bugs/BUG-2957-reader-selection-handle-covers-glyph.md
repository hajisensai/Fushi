## BUG-2957 · 页边缘选择手柄避让回归：触控盒和选择球遮挡选中字

- **报告**：2026-10-05（用户测试新包后：选择手柄现在会挡住选择的字）。
- **真实性**：✅ 真 bug。上一轮 `reader_selection_scripts.dart` 的 `positionSelectionHandles` 只检查 32px 触控盒是否在视口内、两盒是否相撞；clamp 到页顶时，原来 y=-24 的盒子被挪到 y=0，与首字重叠。常规球心距字边 8px 也小于可见圆球半径 9px。旧测试缺少“触控盒不能压住所选字”的独立断言。
- **[x] ① 已修复** — 本轮修复提交（见分支日志），`fushi/lib/src/reader/reader_selection_scripts.dart:2049`：
  - 球心离字边按完整触控盒半径 + 4px 计算（20px），不再用 8px。
  - 收集所有选区 Range 的实际 client rect 行片段，不用会填满行距的全选区 union。
  - 为两端生成有界的邻近候选，排除覆盖任何选中字形、出视口、彼此重叠的触控盒，再选合计位移最小的一对。候选不可行时保留文本但隐藏手柄，不用压字/缩小目标伪装可用。
  - 不改正文 DOM、选择范围及触摸目标身份；不加延时、重试或帧刷新补丁。
- **[x] ② 已加自动化测试** — `reader_selection_drag_hit_behavior_test.{js,dart}`：37 场景 / 26 个 mutation；保留32组角落组合，新增32组内部横/竖排、短词、多字、多行组合，逐步断言完整触控盒不与任一选中字形重叠。`reader_selection_handles_guard_test.dart` 钉住生产几何契约。
- **证据**：`.codex-test/reader-selection-audit/glyph-occlusion-headless.log`，真实 Chrome DOM 的10个场景全部增加字形不相交断言并通过，包括多列布局、页顶零边距、松手前 trusted CDP touch。详细报告：`headless-selection/run-2026-10-05T11-37-24-610Z/report.json`。
- **备注**：`implemented_unverified`。用户要求不再 adb；最终手机触屏/合成效果未复验。最新补修应使用本轮最终生成的 `debug.apk`，不得使用15:14或18:53的旧构建。