## BUG-149 · 书籍制卡整句音频句尾被截断
- **报告**：2026-06-09（用户：书籍制卡，整句音频没播放完毕被截断了。）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2797` 制卡时以 `_lookupCue` 单条 cue 作为 `SentenceAudio` 的导出范围；但 `_lookupCue` 可能只是完整句子的一个 Sasayaki 片段，尤其当前词落在句中短 cue 时，`cue.endMs` 会早于完整句子的最后一个 cue，导致导出的整句音频被截断。
- **[x] ① 已修复** — 书籍制卡导出句子音频改为 `miningSentenceAudioRange(...)`：优先使用 JS 缓存的完整句子 normalized range 合并所有重叠 cue；缺少 range 时参考 Hoshi Android 的 `SasayakiCueAudioRangeResolver`，从当前 cue 向前/向后扩展到文本属于当前句子的相邻 cue；最后才回退当前 cue 原始范围。用户设置的 `delayMs` 只作为整体 A/V 同步平移，不作为句尾 padding。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/mining_audio_clip_test.dart` 覆盖按完整句子 range 合并多 cue、按相邻文本扩展、无固定尾巴回退、整体 delay 平移；`hibiki/test/reader/reader_mining_audio_guard_test.dart` 守住 reader 制卡必须传 `_cachedSentenceRange` 给完整句子音频 resolver，且不再使用固定 `kMiningSentenceAudioTailPaddingMs`。
- **备注**：已跑 `flutter test test\media\audiobook\mining_audio_clip_test.dart test\reader\reader_mining_audio_guard_test.dart`。这次是代码路径级修复；仍建议用真实有声书制一张卡，听 Anki 中 `SentenceAudio` 验证整句范围。
