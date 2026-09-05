## BUG-2156 · 字幕列表字号上限还是不够（BUG-878 抬到 2.0× 后的第二次反馈）
- **报告**：2026-09-05（用户：「视频的字幕列表的字号放大，字号大小的上限再提高一些」）
- **真实性**：✅ 属实。`fushi/lib/src/media/video/video_subtitle_jump_panel.dart` 的档位数组
  `_kFontScaleSteps` 上限就是 `2.0`，注释里写明这是 BUG-878 时从 1.3× 抬上来的
  —— **同一句反馈的第二次**。有效字号 = `widget.fontSize * _fontScaleSteps`，
  基准 `fontSize` = `14 * appUiScale`，所以界面 1.0× 时实际上限只有 28px。
- **入口**：设置页里没有这一项；只有面板头部的 A− / A+ 两个按钮
  （i18n `video_subtitle_list_font_smaller` / `..._larger`）和 Ctrl/⌘+滚轮，两者共用 `_stepFont`。
- **[x] ① 已修复** — 往 `_kFontScaleSteps` **尾部追加** `2.25 / 2.5 / 2.75 / 3.0`，上限 2.0× → 3.0×
  （界面 1.0× 时 28px → 42px）。
  **只能追加、不能改既有元素**：下标本身就是持久化值（偏好键
  `video_subtitle_list_font_scale_index`，`preferences_repository.dart`），动了既有元素等于让所有
  存量用户的字号静默漂移。两处 clamp（seed 与 `_stepFont`）写的都是 `length - 1`，自动跟随，无需改动；
  偏好层不 clamp，也没有第二次夹取，所以被旧上限夹到下标 6 的用户只是停在 2.0×，按 A+ 就能继续往上。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_jump_panel_test.dart`：
  新增 `BUG-2156: the top step reaches 3.0x and only there does A+ disable`（下标 10 × 基准 14 = 42，
  且只有到顶档 A+ 才禁用）；同时修正既有 BUG-878 用例里「下标 6 已是最大档、A+ 应禁用」那半
  —— 追加档位后 2.0× 不再是顶档，那条断言必须翻面。BUG-878 的「下标 6 = 28.0」那半**刻意保持不变**，
  它正是「只追加不改既有元素」这条不变式的守卫。
  **变异实测**：撤掉追加的四档 → 两条用例双双变红。`test/media/video` 全目录 3280 条全绿。
- **备注**：收益在窄面板上递减。时间戳列宽（`subtitleTimestampColumnWidth`）与动作列宽
  （`subtitleRowActionsWidth`）都随字号线性放大，而面板宽下界 240px、正文列还有 48px 硬下界：
  最窄面板 + 带小时的时间戳时，2.0× 附近正文列就已经触底，再往上主要是时间戳和按钮变大。
  宽面板（≥420px）下高档位才真正有用。若要让顶档在最窄面板也有意义，得另做「超大字号下时间戳/动作列
  不再线性放大」——那是另一件事，本次未做。
