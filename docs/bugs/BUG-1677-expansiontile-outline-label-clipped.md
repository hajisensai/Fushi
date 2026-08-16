## BUG-1677 · 折叠区首个下拉框的浮动标签被展开动画的 ClipRect 削掉上半截
- **报告**：2026-08-16（用户：截图 Anki「可视化编辑」右侧面板，「布局」展开区第一项「例句位置」的标签只剩下半截）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/anki/lapis_style_editor_page.dart:1155`（`_buildLayoutSection` 的 `childrenPadding` 只给了 `bottom`，top = 0）。

  机制是两个 Material 行为叠加：
  1. outline 边框的输入框在 label 浮起时，把 label **竖直居中压在顶边框线上**——`_RenderDecoration` 的 `floatingY = -labelHeight × 0.75 ÷ 2 + 边框宽 ÷ 2`，即约半个字高画在自身 RenderBox **外面**（widget 测试实测 5.5px = 16 × 0.75 ÷ 2 − 1 ÷ 2）。
  2. `ExpansionTile` 用 `ClipRect + Align(heightFactor)` 做展开动画，裁剪线正压在**第一个子控件的顶边**。

  「布局」区的第一个子控件恰好是 `_buildLayoutPicker` 生成的 `DropdownMenu`（`expandedInsets: EdgeInsets.zero`，且有 `initialSelection` 所以 label 一开始就是浮起状态），于是溢出的那半截落在裁剪线外被削掉。同区第二、三个下拉框（图片位置 / 音频按钮）前面有 `SizedBox(height: gap)`，溢出落在兄弟控件的空白上，所以只有第一个出问题。

  **排查范围**：全 app 输入框默认 outline（`theme_notifier.dart:1039` 的 `inputDecorationTheme`），所以这是个通用形状。仓库里另有 8 个文件用 `ExpansionTile`，逐处核过首个子控件：本页其余 4 处分别是 chips / slider / `FushiListItem` / 只有 `hintText`（无浮动 label）的 `TextField`，都不产生浮动标签溢出；唯一另一个「首项是带 `labelText` 的输入框」是 `anime_download_dialog.dart:1276` 的「通用下载」区，写了 widget 测试**实测**——`dense: true` + `isDense: true` 让它即使 top=0 也还有 4px 余量、不裁，**不是**同一 bug，故未改动、也未留下一条恒绿的守卫。

- **[x] ① 已修复** — `_buildLayoutSection` 的 `childrenPadding` 补 `top: tokens.spacing.gap`（8px > 实测溢出 5.5px），与本页其它下拉框之间「留一个 gap」的既有节奏一致；顺带把标签与折叠区标题挤在一起的观感也修了。
- **[x] ② 已加自动化测试** — `fushi/test/anki/lapis_visual_editor_label_clip_test.dart`：装载真实页面 → 展开「布局」→ 量标签相对**最近裁剪祖先**的顶部溢出，要求 ≤ 0。变异实测：把 `top` 改回 0 时报 `5.5px 露在裁剪线之外` 判红，还原后文件 sha256 与变异前完全一致。
  - 顺带把 `lapis_style_editor_harness.dart` 拆出 `pumpEditor`（只装载不保存），几何类用例不再被「保存按钮此刻可不可点」绑架；`openEditorAndSave` 改为复用它，行为不变。
- **备注**：这类几何 bug 不能用 `findsOneWidget` 守——被裁的控件照样 find 得到，必须量矩形。
