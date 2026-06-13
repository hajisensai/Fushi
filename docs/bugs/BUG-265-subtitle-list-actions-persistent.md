## BUG-265 · 字幕列表行操作按钮应常驻
- **报告**：2026-06-14（用户：TODO-309）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/media/video/video_subtitle_jump_panel.dart`（原 `_buildRow`）：`final bool showActions = hovered || selected || selectedForCard;` 后 `if (showActions) _buildRowActions(...)`，行的播放/复制/收藏三个按钮仅在鼠标 hover、正在播、或挖词选中时显示，普通行（移动端无 hover）几乎看不到入口。
- **[x] ① 已修复** — 提交 `a2ad8bbb2（常驻按钮，随 _buildRow 重写）`
  - 删除 `showActions` 门控变量，`_buildRowActions(cs, cue, selected, favorited)` 在每行**常驻**渲染（不再条件包裹）。
  - 配合 BUG-263 的单行省略文本：长文本由 `Expanded` + `maxLines:1 + ellipsis` 让出按钮所需横向空间，常驻按钮不会挤坏布局。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_jump_panel_test.dart`（widget 行为）：无 current cue / 无 hover / 无选中时，两行都仍各有 play_arrow / content_copy / star_border（`findsNWidgets(2)`）——撤回旧 `showActions` 门控则 `findsNothing` → 红。
- **备注**：行级 UI 改动与 BUG-263（查词+不换行）、BUG-264（行收藏标记）同在 `_buildRow` 一次重写中物理交错，三者共担该文件的 `_buildRow` diff。
