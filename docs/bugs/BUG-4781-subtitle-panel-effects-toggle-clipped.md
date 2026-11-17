## BUG-4781 · 经典版式字幕列表收藏档里「显示特效字幕」开关被挤出可视区，窄面板要横向拖才看得到
- **报告**：2026-11-17（#3545 合入后的遗留核实，拍板台 H7r4mf_z2n 的开关）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_subtitle_jump_panel.dart:2007`（修前）经典版式筛选行是 `Expanded > HorizontalDragScrollable > SingleChildScrollView(horizontal)`，开关排在分段按钮之后、在可滚区里；收藏档时导出钮与「收藏 N」计数（修前 :2061-2090）在 Expanded 外占固定宽度，可滚区被压窄，开关被裁到视口外，又没有任何可滚动提示。面板 520 宽就已看不到（原测试用 `ensureVisible` 绕开），最窄 240 更严重。
- **[x] ① 已修复**（a5692d65a4）— 开关移出可滚区，与导出钮 / 计数同排，固定宽、恒完整可见；筛选可滚区与收藏计数改为松弛 `Flexible`（flex 1）：收藏档里两者各以剩余宽度的一半为上限、取 min(自身宽度, 一半)（筛选区超出一半时截到一半并可横向拖，计数超出一半时省略号截断；一方用不满的宽度不回补给另一方），非收藏档筛选区独占剩余宽度，整行不右溢（单纯把开关挪出去在 240 宽会右溢 ~20px）。m3e 版式本就走 `adaptiveOverflow`，未动。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_list_show_effects_toggle_test.dart`：新增 `classic favorites @520 / @240` 两例，断言开关 `hitTestable()`（不经滚动直接命中）、整颗落在面板内、点一下即落盘；原「hidden effect favorites are not counted」去掉 `ensureVisible`。撤掉修复时三例都红（实测：Found 0 widgets ... hitTestable）。
- **备注**：真机未复测（本轮按规则不做真机验证），240 宽下的排布只有 widget 测试证据。
