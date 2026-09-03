## BUG-2061 · 合集字幕面板「下载全部」不贴底：两个 Flexible 分份额，用不满的部分落成死白
- **报告**：2026-09-03（用户：截图 QQ_1788367091057.png，「这个下载全部的按钮没在最下面」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/subtitle_collection_panel.dart:882`
  （修复前行号）原 `build()`：外层 `Column(mainAxisSize: MainAxisSize.min)` 下挂两个 `Flexible`(loose，flex 各 1)——
  上面是表单区 `SingleChildScrollView`，下面是成员 `ListView`。Scaffold body 给的是 **loose** 约束，
  而 `SingleChildScrollView` 在 loose 下会 shrink-wrap 到内容高度，用不满自己那一份 flex；
  这部分份额不会转给别人，直接落成 Column 底部的死白，底部操作条只能浮在内容尾巴上。
  实测（1000x1400 宿主、单成员）：按钮底边距宿主底边 **360px**。
- **[x] ① 已修复** — 表单区与成员列表并成**一个** `CustomScrollView`
  （`SliverToBoxAdapter` + `SliverList.builder`，保留懒加载），外层 `Column` 改
  `MainAxisSize.max` + `Expanded`(tight) 吃满剩余高度，底部操作条固定贴底。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_collection_panel_test.dart`
  「底部操作条贴宿主底边：内容撑不满时不浮在列表尾巴上」。判据取**宿主**（Scaffold）底边而不是面板
  自身底边——`MainAxisSize.min` 时面板高度就等于内容高度，两侧同源恒真。
  变异实测：把面板整体退回 HEAD 版实现 → 该断言实测 gap=360.0，红。
- **备注**：只把 `Expanded` 换回 `Flexible`、或只把 `max` 换回 `min`，都**不**会让这条红——
  单个 `CustomScrollView` 在 loose 约束下本来就撑满。这个 bug 的根因是「两个滚动区，第一个 shrink-wrap」，
  变异必须退回双滚动区结构才能复现。
