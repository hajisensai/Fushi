## BUG-2973 · 输入框文字垂直不居中（自定义主题页 AI 输入框与名称框）
- **报告**：2026-10-05（用户转述协作者 shishamo，iPhone 暗色、Apple 设计系统「自定义主题」编辑页截图：AI 多行输入框两行占位符被裁、文字整体偏下；「名称」框文字偏下）
- **真实性**：✅ 真 bug，两套设计系统各一个根因，都在共享输入框层：
  1. **Apple**：`fushi/lib/src/utils/components/glass/fushi_glass_inputs.dart:670`（修前 `textAlignVertical: _c.textAlignVertical ?? (_c.maxLines == 1 ? TextAlignVertical.center : null)`）。内层是 `CupertinoTextField.borderless`；多行框传 `null` 时，CupertinoTextField 只要有占位符（`_hasDecoration`）就把缺省对齐当成 **center**。它的 `_BaselineAlignedStack` 高度取「占位符全部行」与「编辑区一行」的并集——空框里一行高的编辑区被居中进两行高的栈（下移半行），占位符再按基线贴到编辑区上，于是整段占位符下沉半行、第二行掉出框底被裁。所有 Apple 设计系统下 `maxLines > 1` 且有占位符的输入框都受影响。
  2. **MD3**：`fushi/lib/src/utils/components/fushi_material_components.dart:1255`（修前 `hintStyle: glass ? null : tokens.type.listSubtitle`）。`FushiTextField` 的占位符用比正文（`listTitle`）小一号、行高不同的样式，而 `InputDecorator` 把占位符首行基线对齐到正文首行基线，ascent 差让占位符整体下沉：两行占位符在 56 高的框里上边距 17、下边距 7（实测 Rect 偏下 5px）。M3 规格里占位符与正文同字号，只换颜色。
  - 单行框（含「名称」）在两套设计系统、Arial Unicode（CJK）真实字体下量墨迹：Apple 修后墨迹中心与框中心差 0.5px，单行本身没有独立的偏移源；截图里的「偏下」观感来自同屏多行框与名称框并列时多行框的下沉。
- **[x] ① 已修复** — Apple 多行框显式 `TextAlignVertical.top`（编辑区与占位符同从栈顶起，外层对称内边距居中）；MD3 占位符改用正文同一字号 / 行高 + `onSurfaceVariant` 色。A/B：去掉 Apple 修复 `Apple · minLines=1 maxLines=2` 红；去掉 MD3 修复 `MD3 · minLines=1 maxLines=2`（偏 5.02px）与 `minLines=2 maxLines=4` 红。另试过给 MD3 多行也加顶对齐，A/B 证明不需要，未保留。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_text_field_vertical_center_test.dart`：MD3 / Apple × 单行 / 1–2 行 / 2–4 行 × 带标题，断言占位符完整在框内、竖直中心与框中心差 ≤ 1.5px（输入区比占位符高时放宽两者高度差的一半）。
- **备注**：真实字体墨迹探针（Mac `Arial Unicode.ttf`）结果：Apple 单行 / 多行、有无标题，墨迹中心偏差均为 −0.5px。
