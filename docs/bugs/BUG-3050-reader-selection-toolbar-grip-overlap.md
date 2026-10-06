## BUG-3050 · 竖排选择操作条遮挡选择球，视口边缘手柄难以抓取

- **报告**：2026-10-05（用户截图 `Screenshot_20261005_153531.jpg`：竖排时操作条与选择球过近，上球部分被遮挡）。
- **真实性**：✅ 真 bug。`chrome.part.dart` 的旧 `_buildSelectionActionBar` 以首个字的 `rect` 和假定 48px 高度摆工具条，上方仅留 8px；竖排起始手柄球心在字顶上方 8px，32px 触摸盒还向上延伸 16px，因此操作条直接盖住触摸区。页顶零边距时，`reader_selection_scripts.dart` 的旧 `positionSelectionHandles` 还会得到 y=-24 的触摸盒，真实 headless DOM 已复现。
- **[x] ① 已修复** — 本轮修复提交（见分支日志）：
  - `reader_selection_scripts.dart:2121` 输出两端实际触控盒的 union `handlesRect`；与查词单字 `rect` 分离，保留既有查词锚点契约。
  - `reader_selection_data.dart` 解析并校验边界；`chrome.part.dart:443` 经 WebView→global→Overlay 的两角转换消费它，不重复乘 UI 缩放。
  - `reader_selection_toolbar_layout.dart` 按工具条实际测量高度，优先放完整手柄边界上方，否则下方，并考虑安全区；空间确实不足时选遮挡较少的屏幕边缘，不假定能始终零遮挡。
  - JS 按完整 32×32 触控盒限制视口边缘，并解开 clamp 后两盒重叠；原始端点已离屏时不伪造可见端点、不改变选中文字。小到容不下两盒的视口隐藏控件而非缩小目标。
- **[x] ② 已加自动化测试** — `reader_selection_toolbar_layout_test.dart` 覆盖竖排/横排、上下边缘、安全区、大字号高度、1×/1.5×变换及工具条外透传点击；`reader_selection_data_test.dart` 覆盖新/旧 payload、非有限与无效边界。JS harness 覆盖视口边缘与 touch target 避让，并用 mutation 验证断言有效。
- **证据**：`.codex-test/reader-selection-audit/headless-selection/run-2026-10-05T09-53-26-701Z/report.json`：真实 Chrome DOM 10/10，原页顶 start 盒 top -24→0，两盒 y=0–32、32–64，中心均命中自身；字仍为“春”。浏览器已退出。
- **备注**：`implemented_unverified`。按用户要求未继续 adb。Headless Chrome 是真实 DOM/Range/TreeWalker/Popover，不是 Android WebView 或 Flutter 平台纹理验收。
### 后续回归：不能以压字换取“手柄在屏内”

用户验证上一轮边缘 clamp 后发现选择球盖字，见 BUG-3046。此前 headless 只证明盒子在屏内、可各自命中，未断言与字形不相交；该结论不能用来宣称视觉正确。最终实现改为排除**所有选区行片段**的候选布局，球心间隙为触控盒半径+4px。真实浏览器相同场景新增不遮字断言后10/10通过，仍不替代手机验收。

（2026-10-07 审查更正：上面「最终实现改为排除所有选区行片段的候选布局」已被 `0c06dcde92` 回退，手柄定位回到 GAP=8 + 视口 clamp，页边缘压字仍在，见 BUG-3046。操作条一侧的最终实现是 `7b900d904b` / `96a9c83913`：锚点取选区正文首字 rect，按两球各自的触控盒 `handlesBoxes` 生成候选并做碰撞复验。）
