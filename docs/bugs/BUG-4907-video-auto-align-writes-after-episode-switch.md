## BUG-4907 · 字幕自动对轴的结果可能写到换集后的视频上
- **报告**：2026-11-20（路线图 #3722 c36 / video-3：触发面是原地换集的远端 / 在线源合集）
- **真实性**：✅ 真 bug：`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` 的 `_autoAlignSubtitle` 在开始时取 `controller.cues`，随后 `await _resolveSubtitleAlignAudio()`（远端要先拉音轨）与 `await extractAudioEnergyEnvelope(...)`（ffmpeg 抽能量，几十秒），两处 await 之后只核 `mounted`。远端 / 在线合集原地换集复用同一个页面与 controller（`video_fushi_page.dart` 的 `++_episodeLoadSeq`），用户在抽音频期间换到下一集，旧集 cue 与旧集音频算出的平移量照样经 `_setDelayMs` 写进新一集，合集内还会落成系列级调轴。期间用户换字幕源同理。
- **[x] ① 已修复** — 开始时记 `_episodeLoadSeq`、controller 身份与新暴露的 `VideoPlayerController.cueSourceEpoch`（主字幕换源世代，`setCues` 每次 +1）；取音频与互相关收进 `fushi/lib/src/media/video/subtitle_auto_align.dart` 的 `runSubtitleAutoAlign`，取能量的 await 之后身份不符返回 null（作废，不互相关、不提示）；页面写延迟前再核一次，写完后的完成提示也按身份判。
- **[x] ② 已增加自动化测试** — `fushi/test/media/video/subtitle_auto_align_test.dart`「runSubtitleAutoAlign」组 2 项：取能量期间身份变化 → 结果作废、不再互相关；身份不变 → 按同一栅格互相关并返回结果。
- **备注**：页面层（`_autoAlignSubtitle` 的 seq / epoch 采集）没有页面级自动化测试，未做远端合集抽音频中换集的真机验证（本轮所有者定不做设备验证）。
