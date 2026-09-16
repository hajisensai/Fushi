## BUG-2550 · 阅读设置面板窄窗下 stepper 行标签被压成一个字
- **报告**：2026-09-14（用户：截图「阅读设置的字号字重显示不全」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/settings_shared.dart:552`（修复前）的堆叠阈值
  `final double stackThreshold = (220.0 * textScale).clamp(220.0, 420.0);`。

  这个经验值只在 trailing 很窄（switch ≈60dp）时成立。stepper 的 trailing 实宽是
  `72(读数槽) + 2×(40 compact IconButton + 4 间距) = 160dp`，行内布局还要吃掉
  `32(行 padding) + 42(图标位) + 12(label↔trailing 间距)`，合计 246dp。于是行宽只要
  刚过阈值 `220 + 42 = 262dp`，标题拿到的就是 `262 − 246 = 16dp`——**一个汉字都装不下**，
  而判据仍认为「放得下，走行内」。阈值 262 与「标题真的读得了」所需的 ~342dp 之间是一段
  80dp 宽的坏区间，手机上的阅读设置面板正落在里面：截图里「字体大小」「字体粗细」只画得出
  「字」，「段落间距」只剩「段」，而两字的「行高」因为正好两行排得下，反而是完整的。

  受影响的是所有 `AdaptiveSettingsStepperRow`，阅读设置只是最显眼的一处
  （`fushi/lib/src/settings/settings_schema_reading.dart:359/382/397/414/431` 的
  字体大小 / 字体粗细 / 行高 / 段落缩进 / 段落间距）。

- **[x] ① 已修复** — `fushi/lib/src/utils/components/settings_shared.dart`：给
  `AdaptiveSettingsRow` 加 `trailingWidth`（trailing 的固有宽度，只喂堆叠判据、不参与布局），
  声明了它的行改按**真实需求**算阈值：
  `2×行padding + 图标位 + 标题最低可读宽 kSettingsRowLabelMinWidth(96) × 文字缩放 + 间距 + trailing 实宽`；
  没声明的行维持原经验值，不动它们已有的窄屏守卫。`AdaptiveSettingsStepperRow` 传
  新常量 `kSettingsStepperTrailingWidth(160)`。放不下时走的是 `AdaptiveSettingsRow`
  本来就有的堆叠退路（标题独占一行、控件下一行），不是新布局。

  判断依据与 BUG-1184 / BUG-1537 对说明文字的判断同一条：截断即失效，宁可让控件换行。

- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_stepper_row_label_width_test.dart`（50 条）：
  - 行为层：真实中文标题（字体大小 / 字体粗细 / 段落间距）× 宽度 {260, **265**, 300, 320, 340, 360}
    × 文字缩放 {1.0, 1.3}，用 `TextPainter` 在标题**实际渲染宽度**上复算 `didExceedMaxLines`
    断言没被省略号截断。**265dp 是截图的精确复现点**（旧阈值 262 刚好放行、标签只剩 19dp）——
    摘掉修复，这一档三个标题全部转红。
  - 契约层（语言无关）：标签列宽度 ≥ `kSettingsRowLabelMinWidth × 文字缩放`；摘掉修复
    265/300/320/340@1x 与 340/360@1.3x 共 6 档转红。
  - 反向：宽行（560dp）仍行内、不白白堆叠；并量 stepper 真实固有宽度钉住
    `kSettingsStepperTrailingWidth`，防声明值写错让堆叠点悄悄偏掉。

  注意：widget test 用 Ahem 字体（字形宽 = fontSize），对 CJK 度量接近真实、对西文高估一倍有余，
  所以「不截断」只用中文标题断言，语言无关的部分交给契约层那条。

- **备注**：阈值雷区已复核——`settings_shared_test.dart`（320@2x 必堆叠 / 360·400@1x 必行内）、
  `narrow_screen_overflow_test.dart`（200 堆叠 / 600 行内）、`settings_segmented_overflow_test.dart`
  （240 pane 必须仍行内滚动，离旧阈值只有 20dp 余量）全部不受影响：它们的 trailing 都没声明
  `trailingWidth`，走的还是原经验值那条路。
