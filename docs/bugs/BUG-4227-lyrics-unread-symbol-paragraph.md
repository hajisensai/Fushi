## BUG-4227 · lyrics-unread-symbol-paragraph
- **报告**：2026-11-07（用户：应用内反馈 Mvgfc0Ervz，Android）歌词模式开「显示未朗读原文」，单独成段的省略号「…………」、开闭引号「」不显示。
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/lyrics_cue_text.dart:112`（修前）`skippedTextBetween` 要求两条 cue 之间至少 `kLyricsSkippedTextMinChars`(=2) 个有读音的字，标点被归一化剥掉算 0 字 → 直接返回 null；而 `_gapSplit`（:211）在缝里有多个段落边界时，前一行止于第一个、后一行起于最后一个，中间整段符号两侧歌词行都不认领。两者叠加：单独成段的「…………」哪里都不显示。段内的标点缝由 `_gapSplit` 分给相邻歌词行，不丢。
- **[x] ① 已修复** — `skippedTextBetween` 门槛只滤 1 ~ 门槛-1 个有读音字的缝（模糊命中漏掉的词尾）；0 字缝照常取文本，段内标点缝取出为空串仍返回 null，只有段落之间的整段符号留下来灰显（含场景分隔「◇」「＊＊＊」，同属未朗读原文）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_cue_text_test.dart`「symbol-only paragraph between adjacent cues is shown as skipped」「symbol-only paragraph becomes a .ly-gap row in lyrics HTML」；去掉修复时两条均红（null / 0 行）。
- **备注**：纯显示，不改 cue 与匹配区间，已落库书无需重新对齐。
