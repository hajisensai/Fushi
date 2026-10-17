## BUG-3519 · 双语 SRT / VTT 多行字幕在屏上并成一排
- **报告**：2026-10-18（GitHub issue #2312，用户：「双语字幕没换行，会并成一排显示，其它播放器正常」）
- **真实性**：✅ 真 bug。根因 `packages/fushi_audio/lib/src/parsers/srt_parser.dart:117`（修复前）
  与 `packages/fushi_audio/lib/src/parsers/vtt_parser.dart:132`（修复前）：时间行之后的多行文本
  `lines...join(' ')` 合成一行再交给 `parseSubtitleMarkup`，作者的换行在解析层就丢了。渲染端
  `fushi/lib/src/media/video/video_subtitle_overlay.dart:2249` 只按
  `SubtitleMarkup.lineBreakGraphemes` 分行（注释原文「无 \N（含 srt/vtt）恒单行 Wrap」），于是
  「原文一行 + 译文一行」的双语 SRT 渲染成一长行。ASS 的 `\N` 不受影响（markup 解析记了断点），
  且断点读取不受「尊重字幕自带样式」门控，所以两档开关下 SRT/VTT 都并行、ASS 都正常。
- **[x] ① 已修复** — srt / vtt 解析器改用 ASS 硬换行 `\N`（新常量 `kSubtitleHardLineBreak`，
  `subtitle_markup.dart`）连接多行，复用既有 `\N` 语义：断点进 `lineBreakGraphemes`，`plainText`
  里仍替换成空格——查词 / 制卡 / DB 里的 cue 文本与旧的空格连接逐字节一致，只有渲染层分行。
  提交见分支 `worktree-fix-2312-subtitle-linebreak-style`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_srt_multiline_test.dart`：
  SRT / VTT 解析层断言 `text == '上行 下行'` 且 `lineBreakGraphemes == [2]`、单行无断点、跨行
  `<i>` 标签照常剥离；渲染层在 `respectAssStyle` 开 / 关两档下断言第二行落在第一行之下。
- **备注**：
  - `ass_parser.dart:32` 的文档注释仍写「`\N` 转为空格」，与实际（保留为硬换行断点）不符，本次未改。
  - 未做真机复验（widget 层几何证据）。
