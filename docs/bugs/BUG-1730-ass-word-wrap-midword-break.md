## BUG-1730 · ass 字幕英文单词中间断行（Wrap 逐字符换行无词边界）
- **报告**：2026-08-19（用户：Discord 用户报 .ass 字幕在英文单词中间断行，其他播放器不会；底部锚定为主，窗口放大后触发）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_subtitle_overlay.dart:1692` + `:1749-1766`（修复前行号）：一条字幕行被 `text.characters.toList()` 拆成每个 grapheme 一个 `Text`（`_buildSubtitleChar`），直接塞进 `Wrap`——Wrap 的换行单位是 child=单字符，对单词边界一无所知，整行超宽 1px 就把单词最后一个字符甩下一行。字号基准（视频内容高/PlayResY，`_assFontScale`）与可用宽度基准（容器宽）不同源，窗口宽高比变化把满宽行推过阈值。底部更严重：底部默认锚定（`forcedAnchor=null`）时 ASS Style 的 MarginL/MarginR 经 `_paddingFor` 变成真实 Padding 压缩换行宽度（典型双侧 26-80px）；`\pos` 字幕走 `_absolutePositioned` 无界约束永不换行，不受影响。
- **[x] ① 已修复** — 换行单位从「单字符」提升为「断行机会组」：新纯函数 `groupSubtitleGraphemesForWrap`（拉丁/数字/词内标点连续段整组不可断、CJK 逐字成组可断、空白附着前词尾部并闭合组，≈libass WrapStyle 1 语义），词组包成 `Row(mainAxisSize: min)` 作 Wrap child。逐字形样式（\fscx/\blur/描边分层/竖排旋转）与 `_charEntries` 逐字登记零改动（charWidget 仍按 grapheme 下标递增序构建）。提交：见本 commit。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_word_wrap_test.dart`：widget 测试「容器放不下整行但放得下每个单词的拉丁句 → 按渲染几何重建可视行，断言拼回的词序列与原句逐词一致（修复前给出 hello wo / rld agai / n 即红）」+「CJK 无空格句仍逐字断行」；另有 7 条 `groupSubtitleGraphemesForWrap` 分组规则单测（撇号/连字符词内、NBSP 不可断、CJK 后空格附着等）。
- **备注**：
  - 未动（评估后判影响面大，留后续项）：`video_subtitle_overlay.dart` 强制锚定路径 `posMarkup = forcedAnchor != null ? null : ownMarkup` 把竖直强制锚定外溢成丢失水平 MarginL/MarginR——顶/底行为不对称（选顶部时换行宽度反而更大）。若修应只保留水平 Margin、竖直交给 forcedAnchor；牵动 posMarkup 全部下游消费点（pos/anchor/margins 多处），单独立项。
  - 后续项：WrapStyle（`\q`）未解析（仅 subtitle_markup.dart 注释提及），当前恒 ≈WrapStyle 1 语义；字幕盒 24px 固定内边距未参数化。
  - 已知极限：单词本身宽过容器时词组 Row 不再拆词（溢出裁切）——病态输入，libass 此时会强拆中词，暂不追。
