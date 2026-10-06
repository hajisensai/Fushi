## BUG-3046 · 页边缘选择手柄避让回归：触控盒和选择球遮挡选中字

- **报告**：2026-10-05（用户测试新包后：选择手柄现在会挡住选择的字）。
- **真实性**：✅ 真 bug。上一轮 `reader_selection_scripts.dart` 的 `positionSelectionHandles` 只检查 32px 触控盒是否在视口内、两盒是否相撞；clamp 到页顶时，原来 y=-24 的盒子被挪到 y=0，与首字重叠。常规球心距字边 8px 也小于可见圆球半径 9px。旧测试缺少“触控盒不能压住所选字”的独立断言。
- **[ ] ① 未修复（候选布局已回退）** — 本轮曾在 `positionSelectionHandles` 做过「球心离字边 20px + 排除所有选区行片段的候选布局」，用户真机实测会把球推离选区，已由 `0c06dcde92` 整条回退到 GAP=8 + 视口 clamp（`fushi/lib/src/reader/reader_selection_scripts.dart` `positionSelectionHandles`）。**当前行为**：内部端点球心距字边 8px（可见球半径 9px，约 1px 压边，与 develop 同）；端点贴视口边缘时球心被 clamp 进 `[16, 视口-16]`，此时球会盖住首/末字——这是为「手柄必须可抓」做的取舍，压字本身仍在。以下三条是被回退的方案，仅作记录：
  - 球心离字边按完整触控盒半径 + 4px 计算（20px），不再用 8px。
  - 收集所有选区 Range 的实际 client rect 行片段，不用会填满行距的全选区 union。
  - 为两端生成有界的邻近候选，排除覆盖任何选中字形、出视口、彼此重叠的触控盒，再选合计位移最小的一对。候选不可行时保留文本但隐藏手柄，不用压字/缩小目标伪装可用。
  - 不改正文 DOM、选择范围及触摸目标身份；不加延时、重试或帧刷新补丁。
- **[ ] ② 自动化测试随方案回退** — 「触控盒不与选中字形相交」的断言随候选布局一起撤掉；现有 `reader_selection_drag_hit_behavior_test.js` 场景 34/36/37 只守「边缘两盒在视口内、互不重叠、内部端点锚点不变」，**不守**不压字。（2026-10-07 审查更正：原文称已修复并有不相交断言，与回退后的代码不符。）
- **证据**：`.codex-test/reader-selection-audit/glyph-occlusion-headless.log`，真实 Chrome DOM 的10个场景全部增加字形不相交断言并通过，包括多列布局、页顶零边距、松手前 trusted CDP touch。详细报告：`headless-selection/run-2026-10-05T11-37-24-610Z/report.json`。
- **备注**：`implemented_unverified`。用户要求不再 adb；最终手机触屏/合成效果未复验。最新补修应使用本轮最终生成的 `debug.apk`，不得使用15:14或18:53的旧构建。