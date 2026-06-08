## BUG-149 · 书籍制卡整句音频句尾被截断
- **报告**：2026-06-09（用户：书籍制卡，整句音频没播放完毕被截断了。）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2768` 直接用 `cue.startMs`/`cue.endMs` 导出 `SentenceAudio`，而 `TtsChannel.extractAudioSegment` 的桌面 ffmpeg 与 Android Media3 Transformer 都把 `endMs` 当硬结束；真实字幕/有声书 cue 结束点贴得太紧时，卡片里的整句音频没有尾部余量，句尾音素会被截断。
- **[x] ① 已修复** — 书籍制卡导出句子音频前通过 `miningSentenceAudioClip(cue)` 给句尾增加 350ms 余量，再把这个时间窗交给 `extractAudioSegment`；不改变集合播放、单句试听等非制卡路径。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/mining_audio_clip_test.dart` 覆盖制卡音频尾部余量、不破坏原 cue；`hibiki/test/reader/reader_mining_audio_guard_test.dart` 守住 reader 制卡必须用带尾巴的 clip end。
- **备注**：已跑 `flutter test test\media\audiobook\mining_audio_clip_test.dart test\reader\reader_mining_audio_guard_test.dart`。这次是代码路径级修复；仍建议用真实有声书制一张卡，听 Anki 中 `SentenceAudio` 验证句尾主观体验。
