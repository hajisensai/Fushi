## BUG-4839 · VN 模式下合成书（SRT / VTT / LRC）中键与「从此句播放」拿不到句子
- **报告**：2026-11-17（用户：小说阅读器优化清单复核 gap-readerjs2-4，代码审读发现，无用户报告）
- **真实性**：✅ 真 bug（真 Chrome 里用生产 VN shell 复现；未在真机复现）。根因：
  - `fushi/lib/src/reader/reader_visual_novel_scripts.dart:3572`（修前行号）VN 的 `cueIdAtDomPoint` 第二行 `if (!node || !cues || !cues.length) return null;`，只按 `sentenceAudioCues` 的章内区间找句、只回 `{type:'frag'}`；`:3564` 的 `cueIdAtPoint` 也没有 `[data-cue-id]` 分支。
  - 合成书的句子不进 VN 的 `sentenceAudioCues`：`fushi/lib/src/pages/implementations/reader_fushi/mining.part.dart:624` `_prepareSentenceAudioCuesJson` 在没有 sasayaki 编码 cue 时返回 null；它们的身份在正文的 `[data-cue-id]`（sentenceIndex）上，VN 屏上的克隆保留了这个属性（同文件 `textLeadsScreenCues` 就靠它取句）。
  - 共享段（分页 / 连续 shell）的两个函数都先认 `[data-cue-id]` 回 `{type:'sid'}`（`fushi/lib/src/reader/reader_pagination_scripts.dart:2104`、`:2127`）。BUG-3738 给 VN 补这对方法时只补了 `frag` 这一半。
  - 后果：VN + 合成书下，中键「跳到点击句」（Dart `_seekToClickedSentence` → `cueIdAtPoint`）与长按选区后的「从此句播放」（查词载荷 `audioCuePayload` → `cueIdAtDomPoint`）都恒拿到 null、静默无反应。`fushi/lib/src/media/audiobook/audiobook_bridge.dart` 写明合成书「跳到点击句」只走这两个入口。
- **[x] ① 已修复**（`95100a03887`）— `fushi/lib/src/reader/reader_visual_novel_scripts.dart`：`cueIdAtPoint`（`:3700`）先按 `elementFromPoint` 认 `[data-cue-id]`、`cueIdAtDomPoint`（`:3716`）先按命中节点的祖先链认 `[data-cue-id]`，回 `{type:'sid', id}`；顺序与共享段一致，先于 `sentenceAudioCues` 判空。Sasayaki 的 `frag` 路径不变。
- **[x] ② 已加自动化测试** — `fushi/test/reader/vn_pointer_seek_cue_hit_test.dart` + `vn_pointer_seek_cue_hit_harness.mjs`（扩 BUG-3738 的跑手，生产 VN shell + 生产 VN CSS、真 Chrome）：第二个页面不下发任何 cue、正文带 `[data-cue-id]`，按字形坐标点正文字 / ruby 基字 / 注音、换屏后的字，`cueIdAtPoint` 都回 `{type:'sid'}`；`cueIdAtDomPoint` 直接给（节点, 偏移）同样；句子之外的字两个入口都回 null。修前实测 11 个命中全部是 null。
- **备注**：关联 BUG-3738（同一对方法的 `frag` 一半）。真机未复测。待验：VN 模式开一本 SRT / VTT / LRC 合成书，中键点一句、触屏长按选区后点「从此句播放」，确认跳到该句。
