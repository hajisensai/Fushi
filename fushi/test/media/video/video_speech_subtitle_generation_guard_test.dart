import 'dart:io';

import 'package:test/test.dart';

// The page requires the native media_kit surface. These guards cover its
// orchestration; ASR conversion and subtitle parsing have separate unit tests.
void main() {
  late String source;
  setUpAll(() {
    source = File(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    ).readAsStringSync();
  });

  test('PGS and videos without cues can generate learning subtitles', () {
    final String generation = source
        .split('Future<void> _generateSubtitleWithSpeechModel(')[1]
        .split('Future<String?> _transcribeVideoSpeech(')[0];
    expect(source, contains('_generateSubtitleWithSpeechModel(controller)'));
    expect(source, contains('t.video_subtitle_graphic_learning_hint'));
    expect(generation, isNot(contains('if (cues.isEmpty)')));
    expect(generation, contains('_importExternalSubtitle(controller, target)'));
    expect(generation, contains('_applyRemoteSubtitle(controller, target)'));
    expect(generation, contains('await _setDelayMs(0)'));
    expect(generation, contains('_episodeLoadSeq == loadSeq'));
    expect(generation, contains('identical(_controller, controller)'));
    expect(generation, contains('transcriptSrt == null || !isCurrent()'));
    expect(generation, contains('catch (error, stack)'));
    expect(generation, contains("'video.subtitleSpeechGeneration'"));
    expect(generation, contains('t.video_subtitle_import_failed'));
  });

  // 反馈 6Tj3ECtB0Q：「语音识别生成字幕」与「生成日语字幕」合并成一个入口。两条原流程
  // 都还在：管线面板里关掉「保存字幕文件」就回到本机转录弹层，AI 校对开关透传成
  // 转录完自动校对；管线走不了（蓝光 / 非互联远端流 / 不在库里 / host 播放列表后续
  // 集）时直接走本机转录。
  test('one generate-subtitles entry routes to both original flows', () {
    final String rows = source
        .split('Widget _buildSubtitleTrackRows(')[1]
        .split('const FushiDividerControl(height: 1)')[0];
    // 反馈 E1pq561P2q：入口改成「字幕工作台」，生成字幕是工作台里的一项工具；
    // 重定时与按内嵌字幕对齐也收进工作台，菜单里不再各占一行。
    expect(RegExp('video-subtitle-studio').allMatches(rows), hasLength(1));
    expect(rows, isNot(contains('video-subtitle-generate')));
    expect(rows, isNot(contains('video-subtitle-ai-generate')));
    expect(rows, contains('_subtitleStudioAvailable(controller)'));
    expect(rows, contains('_openSubtitleStudio(controller)'));
    expect(rows, isNot(contains('_openSubtitleGeneration(')));
    expect(rows, isNot(contains('_retimeSubtitleWithSpeechModel(')));
    expect(rows, isNot(contains('_alignSubtitleToEmbeddedTracks(')));
    expect(rows, isNot(contains('_openJapaneseSubtitlePipeline(')));
    expect(rows, isNot(contains('_generateSubtitleWithSpeechModel(')));

    final String studio = source
        .split('Future<void> _openSubtitleStudio(')[1]
        .split('Future<void> _extractJapaneseFromBilingualSubtitle(')[0];
    expect(
      studio,
      contains('_canTranscribeVideoSpeech || _canRunSubtitlePipeline'),
    );
    expect(studio, contains('_openSubtitleGeneration(controller)'));
    expect(studio, contains('_retimeSubtitleWithSpeechModel(controller)'));
    expect(studio, contains('_alignSubtitleToEmbeddedTracks(controller)'));
    expect(
      studio,
      contains('_extractJapaneseFromBilingualSubtitle(controller)'),
    );
    expect(studio, contains('controller.secondaryCues'));
    expect(studio, contains('controller.effectiveSecondaryDelayMs'));
    expect(studio, contains('controller.screenshot'));

    // 拆分产物另存新档、走既有外挂字幕链路，换集 / 换播放器后不落到新视频上。
    final String split = source
        .split('Future<void> _extractJapaneseFromBilingualSubtitle(')[1]
        .split('Future<void> _openSubtitleGeneration(')[0];
    expect(split, contains('extractJapaneseFromBilingual(input)'));
    expect(split, contains('_importExternalSubtitle(controller, target)'));
    expect(split, contains('_applyRemoteSubtitle(controller, target)'));
    expect(split, contains('identical(_controller, controller)'));
    expect(split, contains('_episodeLoadSeq == loadSeq'));
    expect(split, contains("'video.subtitleBilingualSplit'"));
    // 远端片名（「Re:Zero」）拼档名前必须清洗，否则 Windows 上写不出文件。
    expect(split, contains('safeWindowsFileName(rawBaseName)'));

    final String router = source
        .split('Future<void> _openSubtitleGeneration(')[1]
        .split('Future<void> _generateSubtitleWithSpeechModel(')[0];
    expect(router, contains('if (!_canRunSubtitlePipeline)'));
    expect(router, contains('autoProofread: proofread'));
    expect(router, contains('onTranscribeInApp: inApp'));

    final String local = source
        .split('Future<void> _openJapaneseSubtitlePipeline(')[1]
        .split('Future<void> _openRemoteJapaneseSubtitlePipeline(')[0];
    expect(local, contains('onTranscribeInApp: onTranscribeInApp'));
    expect(
      local,
      contains('await _generateSubtitleWithSpeechModel(controller)'),
    );
    final String remote = source
        .split('Future<void> _openRemoteJapaneseSubtitlePipeline(')[1]
        .split('Future<void> _applyRemotePipelineSubtitleWhenDone(')[0];
    expect(remote, contains('onTranscribeInApp: onTranscribeInApp'));
    // host 播放列表的任意一集都交给 host 管线（带集下标），本机转录作为面板里的
    // 「保存」选项保留；不再按集下标放弃 host 管线。
    expect(remote, contains('_remoteHostSubtitleTarget(videoId, episode)'));
    expect(remote, contains('episodeIndex: episode'));
    expect(remote, isNot(contains('episode > 0')));
    final String studioPanel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('final String? videoPath = _currentVideoPath;')[0];
    expect(studioPanel, contains('_remoteHostSubtitleTarget('));
    expect(studioPanel, contains('onTranscribeInApp: inApp'));
    expect(studioPanel, isNot(contains('episode > 0')));

    final String transcribe = source
        .split('Future<String?> _transcribeVideoSpeech(')[1]
        .split('Future<void> _retimeSubtitleWithSpeechModel(')[0];
    expect(transcribe, contains('autoProofread: autoProofread'));
  });

  test('ASR receives the selected audio track and the full episode', () {
    final String preparation = source
        .split('Future<String?> _transcribeVideoSpeech(')[1]
        .split('Future<void> _retimeSubtitleWithSpeechModel(')[0];
    expect(preparation, contains('extractAudioSegmentViaFfmpeg('));
    expect(preparation, contains('startMs: 0'));
    expect(preparation, contains('endMs: durationMs'));
    expect(preparation, contains('audioStreamIndex: audio.audioStreamIndex'));
    expect(preparation, contains('audioStreamCount: audio.audioStreamCount'));
    expect(preparation, contains('audioPaths: <String>[audioPath]'));
    // Video is mixed audio (BGM / effects): the sheet must get a mixedAudio
    // service. Without it the shared default is the audiobook (cleanSpeech)
    // service — Japanese then runs ReazonSpeech behind an energy gate instead of
    // Parakeet with sliding windows (8 anime episodes: kana CER 20.7% vs 13.9%).
    expect(preparation, contains('service: createAsrTranscriptionService('));
    expect(preparation, contains('audioProfile: AsrAudioProfile.mixedAudio'));
    // Both generating text and correcting existing text use that same track.
    // The call may forward the caller's `transcribe:` override (desktop CLI runs
    // the same transcription service headless) — the track preparation above is
    // still the single shared path, so match the call with optional named args.
    expect(
      RegExp(
        r'_transcribeVideoSpeech\(\s*controller\s*(?:,\s*transcribe:\s*transcribe\s*)?(?:,\s*autoProofread:\s*autoProofread\s*)?,?\s*\)',
      ).allMatches(source),
      hasLength(2),
    );
    final String retiming = source
        .split('Future<void> _retimeSubtitleWithSpeechModel(')[1]
        .split('Future<void> _alignSubtitleToEmbeddedTracks(')[0];
    expect(retiming, isNot(contains('if (!mounted) return;')));
    expect(retiming, contains('identical(_controller, controller)'));
    expect(retiming, contains('_episodeLoadSeq == loadSeq'));
    expect('if (!isCurrent()) return;'.allMatches(retiming), hasLength(3));
  });

  // 蓝光原盘会话也走完整管线：入口按原盘 VM 的可抽取性判（纯函数
  // canRunLocalVideoSubtitlePipeline），不再按「是不是原盘」一刀切；抽不了时说明原因。
  test('Blu-ray disc titles reach the full pipeline by extractability', () {
    final String gate = source
        .split('bool get _canRunSubtitlePipeline =>')[1]
        .split('bool _subtitleStudioAvailable(')[0];
    expect(gate, contains('canRunLocalVideoSubtitlePipeline('));
    expect(gate, contains('controller?.discMiningAvailable'));
    expect(gate, contains('!_discLearningBlocked'));
    expect(gate, isNot(contains('_discBookUid')));

    final String router = source
        .split('Future<void> _openSubtitleGeneration(')[1]
        .split('Future<void> _generateSubtitleWithSpeechModel(')[0];
    expect(
      router.indexOf('_discExtractionAllowed(controller)'),
      lessThan(router.indexOf('if (!_canRunSubtitlePipeline)')),
    );
    expect(router.indexOf('_discExtractionAllowed(controller)'), isNonNegative);
  });
}
