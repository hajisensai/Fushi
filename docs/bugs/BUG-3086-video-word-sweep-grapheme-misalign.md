## BUG-3086 · 视频整句扫词：分词碎片劈开代理对/组合字符导致后续词首字下标整体错位
- **报告**：2026-10-09（PR #2017 合入前审查）
- **真实性**：✅ 真 bug。`buildSubtitleSweepTokens`（`fushi/lib/src/media/video/subtitle_word_sweep.dart:65-73`，PR #2017 原版行号）按「每个词前进几个 grapheme」累加下标：每个词至少前进一个 grapheme。`JapaneseLanguage.textToWords` 未命中时按 UTF-16 码元切（`text[pos]`），emoji / 代理对 / 组合字符会被劈成半个 grapheme 的碎片，每个碎片都被当成独立的词并各前进一格。之后所有词的首字下标整体错位：`"😀あい"` 切成 `[\uD83D, \uDE00, あ, い]`，得到下标 `0,1,2,3`，「あ」指向「い」，「い」越界，扫词就查到错的词或什么都查不到。
- **[x] ① 已修复**（`d51372c0`）— 先按切分不变式把各片段的 UTF-16 起点累加出来，再经「码元 → grapheme」映射表换算成 grapheme 下标（`subtitle_word_sweep.dart:76`）。起点落在某个 grapheme 中间的碎片并入前一个词（`:107`），空碎片丢弃。词的区间右端按向上取整计算，分词结果比原文长时忽略超出的部分。`SubtitleSweepToken` 新增 `graphemeEnd`，供落点函数 `resolveSubtitleSweepStop`（`:154`）使用。
  同一提交还修了 PR 的几个次要问题：
  - 手柄浮层键（`tryDictionaryPopupGamepadButton`）先于扫词处理；
  - 词落在未登记字符上时取词内第一个已登记字，整词都没有就跳过，最多走一圈；
  - 扫词加入 `kVideoPressEdgeOnlyActions`；
  - 四条输入通道统一经 `_runWordSweepAction` 派发，鼠标侧键与浮层回传 token 也已接上。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/video/subtitle_word_sweep_test.dart`：
    - 分组「分词碎片劈开 grapheme（BUG-3086）」覆盖半码元切分、组合浊点（か+゛）切分、词尾落在 grapheme 中间、纯 emoji、空句、违反不变式；
    - 分组 `resolveSubtitleSweepStop` 覆盖落点规则。
  - `fushi/test/pages/video_word_sweep_wiring_guard_test.dart`：四通道接线顺序。
  - `fushi/test/media/video/video_keyboard_editable_focus_test.dart`：扫词只认按下沿。
- **备注**：
