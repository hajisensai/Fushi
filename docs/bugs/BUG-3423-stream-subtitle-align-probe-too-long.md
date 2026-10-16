## BUG-3423 · 媒体服务器 / 在线源视频字幕波形调轴要等太久（流只需前 3 分钟）
- **报告**：2026-10-16（反馈 #5m4b74SHhv，开发者 resolved 后反馈人 reopen：「读 20 分钟太长了，要等待很久，取 3 分钟就行了」）
- **真实性**：✅ 属实。流视频（无本地文件）的对轴音源经 `_fetchStreamAlignAudio`（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart`）用 ffmpeg 从流里裁 `0..kSubtitleAutoAlignProbeLimitMs`（`fushi/lib/src/media/video/audio_energy_probe.dart:40`，20 分钟）；读流最坏与实时播放一样慢，超时给到 `endMs + 120s`，用户要等很久。20 分钟上界是为本地磁盘文件定的，流不适用。
- **[x] ① 已修复** — 新增 `kStreamSubtitleAlignProbeLimitMs`（3 分钟）与纯函数 `subtitleAlignProbeLimitMs(fromStream:)`；页面 getter `_subtitleAlignProbeLimitMs` 统一供应流抽音 `endMs`、`extractAudioEnergyEnvelope` 的 `-t`、自动对轴 cue 栅格化上界、波形窗口（经 `VideoQuickSettingsHost.subtitleProbeLimitMs` -> `SubtitleWaveformAlignPanel.probeLimitMs`）——同一个值，两侧栅格长度一致、窗口不与实际音频错位。本地文件 / 互联 host 整集音源仍 20 分钟。3 分钟对白不足时互相关置信度低走既有低置信降级，不乱平移。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_auto_align_test.dart`（上界取值），`fushi/test/pages/video_disc_menu_and_stream_align_wiring_guard_test.dart`（流抽音 / 包络 / 窗口同源，页面不再直接用 20 分钟常量）。
- **备注**：后续如要「先 3 分钟可用、后台继续扩展」需要包络分段缓存，本次未做。
