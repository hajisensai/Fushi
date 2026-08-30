## BUG-1963 · Windows 自定义标题栏下焦点环整体向下错位
- **报告**：2026-08-30（用户：Windows 视频字幕列表工具栏的蓝色焦点环落在 A+ 下方空白区域）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_focus_ring.dart:_computeFocusRect/build`：焦点控件矩形由 `localToGlobal` 得到窗口全局坐标，但绘制时直接当成 `FushiFocusRing` 内部 `Stack` 的局部坐标。Windows 自定义标题栏从外层把整个 app/焦点环子树下移 48px 后，这个偏移被绘制环再叠加一次，所以环稳定地落到实际按钮下方一行。
- **[x] ① 已修复** — 给焦点环 `Stack` 建立真实几何锚点，将焦点矩形的两个全局角点经 `globalToLocal` 转回该 `Stack` 的局部坐标后再绘制；同时保留 UI scale 下视觉 2px 外扩间距。修复属于全局几何边界，不对字幕列表做特例。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_focus_ring_test.dart`：构造一个与 Windows 自定义标题栏同构的 48px 外层偏移，并叠加 1.25× UI scale，断言焦点环在真实屏幕坐标上四边均紧贴控件外扩 2px。
- **备注**：Windows 真机原始路径（视频 → 字幕列表 → 键盘/手柄移动到 A+）仍待复测；按用户要求本轮不等待完整测试。
