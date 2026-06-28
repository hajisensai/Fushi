## BUG-448 · 点击调试日志文字崩溃
- **报告**：2026-06-28（用户：点击调试日志的文字会崩溃，老问题）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/components/hibiki_material_components.dart`：`_HibikiLogPanelState.build` 里每行日志是 `Text(_lines[index], softWrap: false)`（旧 :2298-2302），**无宽度上限**；外层 :2284 `SelectionArea` + :2286 `ListView.builder`（只纵向滚动，水平方向无约束收口）。`softWrap:false` 让行 Text 的布局宽度 = 整行无界单行宽；点击 / 拖选触发 selection 时，`SelectionArea` 的命中测试 / `getBoxesForSelection` 对这种无界宽度的 Selectable 求交会落到超出视口的极端横坐标 → 越界（与 BUG-413/423 框选坐标错位、TODO-806/822 同族）。现有守卫 `logSelectionScrollDecision`（:2355-2362）只防拖拽期程序化滚动，对**单击 selection 命中测试**无防护。
- **[x] ① 已修复** —（**方案①：给每行加宽度约束，保留逐行选择**）
  - 每行 Text 包 `ClipRect(ConstrainedBox(maxWidth: constraints.maxWidth, child: Text(..., softWrap:false, overflow:TextOverflow.clip)))`，把布局宽度钉死在视口可用宽度内（`constraints` 取自外层 `LayoutBuilder`）。Selectable 矩形不再越界，消除无界单行宽度这个根因；超视口长行仍按原设计在右侧裁切（看全整段走常驻「复制全部」），逐行选择能力保留。
  - 选 ① 而非 ②（整体退出 selectable）的理由：① 在消除越界根因的同时**不丢逐行选择**能力，与 TODO-806/BUG-423 治理同手法（同族 bug 都从「无界单行宽度 + SelectionArea 命中放大」入手收口几何，而非砍掉 selection）；② 会丢逐行选择、是更稳但功能退化的下策，无必要。
  - **Windows 专项降级**：`_copyAllToClipboard` 的 `Clipboard.setData` 包 try（失败 debugPrint 降级，不让平台异常逃逸到 framework 顶层与崩溃签名混淆）。
  - 提交：见本轮 commit 哈希（fix(log): BUG-448）。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/log_panel_scroll_select_guard_test.dart` 追加：①widget 行为——20000 字超长单行日志点击 + 横向拖选不抛异常（`takeException` 为 null）、超长行 Text 有 `ConstrainedBox` 祖先；②源码守卫——每行 Text 受宽度约束（`ConstrainedBox` + `ClipRect` + `maxWidth: constraints.maxWidth` 在场，`softWrap: false` 仍在），复制全部的 `Clipboard.setData` 有平台异常降级。
- **备注**：崩溃签名（assertion vs 平台异常）最终需 Windows 真机确认——**静态根因已修，崩溃复现待真机最终验证**。headless 难稳定复现真实选区命中几何，故在最强可落地层（widget 行为 + 源码守卫）守住不变式。与 BUG-442（剪贴板查词面板超长文本 OOM，另一文件 `clipboard_lookup_text_panel.dart`）区分。
