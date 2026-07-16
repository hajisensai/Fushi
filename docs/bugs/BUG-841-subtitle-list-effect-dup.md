## BUG-841 · 字幕列表特效叠加ASS未去重
- **报告**：2026-07-15（用户：截图 1:40 处 `ZH / JP / JP / ZH` 四行重复）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_jump_panel.dart:422`（`all` 档 `List.generate(cues.length)` 全量渲染，整条 cue 链路无去重）。特效叠加 / 多层 ASS 用多条 `Dialogue` 事件渲染同一句可见文本（不同 layer/style/位置做描边、辉光、逐字变色特效），`AssParser.parseString`（`packages/hibiki_audio/lib/src/parsers/ass_parser.dart:271`）逐条产 `AudioCue`、`VideoPlayerController.setCues`（`video_player_controller.dart:1014`）只 sort 不 dedup，列表遂一句话出多行。
- **[x] ① 已修复** — `video_subtitle_jump_panel.dart` 新增 `_dedupedRawIndexes`（按 `(startMs, text)` 折叠重复、保留首条代表行 + 建 raw→代表映射），三档过滤与计数 chip 全走去重集；当前播放句落在被折叠重复项时经 `_representativeRaw` 把高亮/自动滚动定位到代表行。画面 overlay 不走此路径，特效各层仍全渲染。提交 `4d4be72e9`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_list_effect_dedup_test.dart`：`ZH/JP/JP/ZH` 折叠成 2 行；代表行仍能 seek 到真实 cue；当前句落在重复项时代表行不脱靶。
- **备注**：双语（同时间不同文本）文本不同不折叠，日/中各占一行——与画面 overlay 的双语重叠是**另一个** bug（[[BUG-840]]，overlay 跨组避让）。
