## BUG-321 · TODO-569 视频字幕描边/残留黑字「一点没修好」（8 层模糊 Shadow glyph 拷贝伪描边）
- **报告**：2026-06-19（B03 验收第 6/7 条·真机·手机端最重。用户原话：第 7 条「一点没修好，还是不正常显示」、第 6 条「手机上不正常」。现象=字幕每个字应是【围绕文字的单层描边】，但切句/横竖屏切换时【残留在文字下方的黑字】（双重/残影黑字）。之前 BUG-222 标「已修」，用户验证根本没修好。）
- **真实性**：✅ 真 bug（渲染观感问题）——根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:_styleForGrapheme`（修复前的 `shadows:` 行）+ `video_subtitle_style.dart:buildSubtitleShadows`。

  **为什么 BUG-222 没修好（上次「假修好」）**：BUG-222 把字幕描边从「单个向下 `Offset(0,thickness)` drop shadow」改成「8 个方向各放一个 `Shadow(blurRadius: thickness, offset: thickness/2)`」想模拟 outline，并在备注里明写「dev=True，真机看观感」——**从未真机验证**，host 单测只断言了「8 个阴影对称、偏移和为 0」（结构对称 ≠ 视觉无残影）。

  **真根因（这次）**：Flutter 的 `Shadow` **不是**沿字形轮廓描边，而是把**整个字形 glyph 用阴影色（黑）重绘一遍**再做高斯模糊 + 偏移。8 个方向 = 8 份模糊的黑色字形拷贝叠加。由于 `blurRadius`(=thickness) **大于**偏移半径(=thickness/2)，这些模糊黑字大面积重叠并外溢到字身周围 → 白字下方/旁边浮现一团能看清字形轮廓的黑色虚影 = 用户说的「残留在文字下方的黑字、双重/残影」。
  - **横竖屏切换 / 手机端是「重灾区 / 必现」**：旋转后 `appUiScale` 变化把 thickness 经 `VideoSubtitleStyle.resolveShadowThickness(uiScale)` 放大（默认随缩放、clamp 到 12px）。thickness 越大，每个模糊黑字 glyph 拷贝越大越糊、外溢越多，残影越重。移动端默认缩放 + 横屏放大 → thickness 顶到接近上限 → 残影最明显。**这不是状态残留 / widget 没销毁，是 8 层模糊 glyph 拷贝在大 thickness 下的固有渲染产物**——所以「切句清除」「横竖屏重建」层面怎么查都查不到，因为每一帧都重画且每一帧都带这团残影。

- **[x] ① 已修复**（提交：`f77ba8e38`）— 废弃「8 个模糊 `Shadow` glyph 拷贝伪描边」，改用 Flutter **真**文字描边：
  - `video_subtitle_style.dart` 新增纯函数 `Paint? buildSubtitleStrokePaint(Color color, double thickness)`：`thickness<=0` 返回 null（无描边）；正粗细返回 `Paint()..style = PaintingStyle.stroke ..strokeWidth = thickness ..strokeJoin = round ..strokeCap = round ..color = color`。它沿字形**外轮廓画一圈**线，单层、无模糊、无偏移拷贝。
  - `video_subtitle_overlay.dart` 把逐字符渲染从「单层 `Text` + `style.shadows`」改成 `_buildStrokedChar(char, i, markup)` 的**双层** `Stack`：底层 stroke `Text`（`foreground = buildSubtitleStrokePaint(...)`、无 color）+ 上层 fill `Text`（正文填充色、无 foreground、无 shadows）。两层用同一份几何样式（字号/字重/字体/fallback/行高）→ 逐像素对齐、`Stack` 尺寸 == 字符尺寸 → 不改变 hit-test 几何（`_charContexts` 登记的字符矩形仍精确，逐字查词不受影响）。`thickness<=0` 时 strokePaint 为 null，直接渲染单层 fill `Text`（零多余层）。
  - `_styleForGrapheme` 移除 `shadows:`（伪描边源），现在只产填充层几何样式；markup span 的 `color`/`italic`/`bold`/下划线删除线仍只覆盖填充层，描边层从填充层 `copyWith(color: null, foreground: paint, decoration: none)` 同源派生（描边层不画装饰线，避免与填充层叠加加粗）。
  - **关键不变量**：任何 thickness / 缩放 / 横竖屏都只是描边线变粗变细的单层轮廓，绝不产生第二个错位/模糊的黑字 → 根除残留黑字。
  - 收藏星角标那枚 `Icon` 仍用 `buildSubtitleShadows`（图标无文字双层渲染对应物、尺寸小、不在字幕文字残影范围内），故保留该函数。

- **[x] ② 已加自动化测试** —
  - 纯逻辑单测 `hibiki/test/media/video/video_subtitle_style_test.dart` 新增 group `buildSubtitleStrokePaint`：`thickness<=0` 返回 null；正粗细返回 `PaintingStyle.stroke` 画笔、`strokeWidth == thickness`、`color` ARGB 匹配描边色、`strokeJoin/strokeCap == round`、`isAntiAlias`；strokeWidth 随 thickness 线性变化（2→2、12→12，证明缩放/横竖屏只改粗细）。原 `buildSubtitleShadows` group 保留（星角标仍用）。
  - widget 行为测试 `hibiki/test/widgets/video_subtitle_overlay_test.dart` 重写描边用例为 `renders real outline as double-layer stroke+fill Text, no shadow residue (BUG-321)`：断言字符 'A' 渲染成**两个** `Text`（双层），用 `foreground == null` 区分出 fill 层（有 color、**无 shadows**——残留黑字源已根除）与 stroke 层（`foreground.style == PaintingStyle.stroke`、`strokeWidth == thickness`、color 匹配、几何与 fill 层一致、无 shadows）；新增 `thickness<=0 renders single fill Text` 用例断言无描边时只有单层 fill `Text`、无空描边层。
  - 相邻测试同步适配双层渲染（`find.text(char)` 现命中 2 个）：`test/media/video/video_subtitle_overlay_test.dart`（getRect/getCenter/tapAt/moveTo 取 `.first`、字符计数 `findsNWidgets(2)`、字号断言取 fill 层）、`video_subtitle_overlay_markup_test.dart`（getCenter/tap 取 `.first`、italic span 取 fill 层）、`video_subtitle_font_consistency_test.dart`（新增 `_fillTextOf` helper 取 fill 层做回退链断言）、`test/widgets/video_subtitle_overlay_test.dart` 首个用例（双层字符计数）。
  - 验证：`flutter analyze`（改动文件）0 issues；`flutter test test/media/video/`（整目录）= `+806 ~2`（2 skipped=预存 golden 门控）全绿；`test/widgets/video_subtitle_overlay_test.dart` 全绿。全量 `flutter test` = `+5478 ~2 -9`，9 个失败经 baseline（develop@890b6768a，本改动前）对照确认**全部预存红、与本改动零关系**：7 个 `HibikiListTile` golden 像素基线（`@Tags(['golden'])` 门控）+ 1 个 `md3_design_system_static_test` 的 `MediaItemDialogFrame` cover 守卫（TODO-557 改了实现、守卫未同步，本人未碰该文件）。

- **备注**：**这是渲染观感 bug，host 单测只能证「描边渲染结构 = stroke 画笔单层 + fill 单层、绝无 Shadow 伪描边」，不能证视觉上残留黑字真的消失。** 真机/手机端横竖屏来回切换（必现路径）+ 切句必须由用户复测原始失败路径并留证据——这是上次 BUG-222「dev=True 没真机就声称修好」导致用户验证「根本没修好」的直接教训。本轮代码层根因清晰（8 层模糊 glyph 拷贝 → 真 stroke 轮廓），但不在此声称「真机已修好」，待用户真机确认。
- **编号**：BUG-321 由 worktree base develop@890b6768a 取下一空号（遍历所有 worktree 分支 BUG 号并集最大 320 → 321）。
