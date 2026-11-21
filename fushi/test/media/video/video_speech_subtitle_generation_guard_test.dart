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
    // 带上播放器当前音轨（host 识别那条轨；老 host 降级按语言挑）。
    expect(
      remote,
      matches(
        RegExp(
          r'_remoteHostSubtitleTarget\(\s*videoId,\s*episode,\s*'
          r'audioTrack: controller\.currentAudioStreamIndex',
        ),
      ),
    );
    expect(remote, contains('episodeIndex: episode'));
    expect(remote, isNot(contains('episode > 0')));
    final String studioPanel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('final String? videoPath = _localPipelineMediaPath;')[0];
    expect(studioPanel, contains('_remoteHostSubtitleTarget('));
    expect(
      studioPanel,
      matches(
        RegExp(
          r'_remoteHostSubtitleTarget\([^;]*'
          r'audioTrack: controller\.currentAudioStreamIndex',
        ),
      ),
    );
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

    // 完整管线与「仅本机转录」同口径：两个入口（工作台内嵌面板、菜单里的管线面板）
    // 都把播放器当前音轨交给目标解析，管线识别这条轨（批量 / 无播放上下文按语言挑）。
    final String panel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('Future<void> _openJapaneseSubtitlePipeline(')[0];
    final String menu = source
        .split('Future<void> _openJapaneseSubtitlePipeline(')[1]
        .split(
          'if (!context.mounted || _localPipelineMediaPath != videoPath)',
        )[0];
    for (final String entry in <String>[panel, menu]) {
      expect(
        entry,
        matches(
          RegExp(
            r'resolvePlaying\([^;]*audioTrack: controller\.currentAudioStreamIndex',
          ),
        ),
      );
    }
  });

  // 蓝光原盘会话也走完整管线：入口按原盘 VM 的可抽取性判（纯函数
  // canRunLocalVideoSubtitlePipeline），不再按「是不是原盘」一刀切；抽不了时说明原因。
  test('Blu-ray disc titles reach the full pipeline by extractability', () {
    final String gate = source
        .split('bool get _canRunSubtitlePipeline =>')[1]
        .split('bool _subtitleStudioAvailable(')[0];
    expect(gate, contains('canRunLocalVideoSubtitlePipeline('));
    // 管线读的是原盘 VM 的抽取路径（多角度 title 带当前角度），不是 title 身份路径。
    expect(gate, contains('videoPath: _localPipelineMediaPath,'));
    expect(gate, contains('controller?.discMiningAvailable'));
    expect(gate, contains('!_discLearningBlocked'));
    expect(gate, isNot(contains('_discBookUid')));

    // 入口的原盘闸门换成 _discSubtitleAudioAllowed：远端原盘会话的 title 由 host 读盘
    // （能在 host 上定位就放行），其余仍是制卡抽取同一道闸门 _discExtractionAllowed。
    final String router = source
        .split('Future<void> _openSubtitleGeneration(')[1]
        .split('Future<void> _generateSubtitleWithSpeechModel(')[0];
    expect(
      router.indexOf('_discSubtitleAudioAllowed(controller)'),
      lessThan(router.indexOf('if (!_canRunSubtitlePipeline)')),
    );
    expect(
      router.indexOf('_discSubtitleAudioAllowed(controller)'),
      isNonNegative,
    );
    final String discMenu = File(
      'lib/src/pages/implementations/video_fushi/disc_menu.part.dart',
    ).readAsStringSync();
    final String audioGate = discMenu
        .split('bool _discSubtitleAudioAllowed(')[1]
        .split('bool get _discOwnsInput')[0];
    expect(audioGate, contains('controller.isRemoteDiscSession'));
    expect(audioGate, contains('_remoteDiscHostTitle() != null'));
    expect(audioGate, contains('return _discExtractionAllowed(controller);'));
  });

  // 多角度蓝光 title：原盘 VM 按正在播的角度给抽取路径（角度成员路径），工作台内嵌面板
  // 与菜单入口都按它解析目标；任务结束按去掉角度后的 title 身份判「还停在这一集」。
  test('multi-angle Blu-ray titles run the pipeline on the playing angle', () {
    final String discVm = File(
      'lib/src/media/video/video_disc_menu.part.dart',
    ).readAsStringSync();
    final String bind = discVm
        .split('Future<void> bindDiscTitle(')[1]
        .split('Future<String?> _checkDiscExtractionSource(')[0];
    expect(bind, contains('discExtractionPathForAngle('));
    expect(bind, contains('_checkDiscExtractionSource(extractionPath)'));
    expect(bind, contains(': extractionPath;'));
    expect(discVm, isNot(contains("angle != 0) return 'multi-angle-source'")));
    // DVD 多角度 title 同样按正在播的角度抽（`TITLE_nn.aK.dvdtitle`），不再拒绝。
    expect(discVm, isNot(contains('multi-angle-source')));

    final String studioPanel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('Future<void> _openSubtitleStudio(')[0];
    expect(
      studioPanel,
      contains('final String? videoPath = _localPipelineMediaPath;'),
    );
    final String sheet = source
        .split('Future<void> _openJapaneseSubtitlePipeline(')[1]
        .split('Future<void> _openRemoteJapaneseSubtitlePipeline(')[0];
    expect(
      sheet,
      contains('final String? videoPath = _localPipelineMediaPath;'),
    );
    expect(sheet, contains('_localPipelineMediaPath != videoPath'));
    final String done = source
        .split('Future<void> _applyPipelineSubtitleWhenDone(')[1]
        .split('({String key, String title')[0];
    expect(
      done,
      contains('_currentVideoPath != discAngleBaseMemberPath(videoPath)'),
    );
  });

  // 互联远端的蓝光原盘会话（本机没有文件，盘在 host 上）：当前 title 在 host 上定位（有行
  // 用行，没有用同盘锚点 + discTitle），host 跑管线、产物随任务取回；工作台内嵌面板与菜单
  // 入口都走它，结束按（盘, title）+ 同一次加载 + 同一 title 世代自动选中；本机转录 /
  // 重定时 / 对轴的整集音源请 host 裁。
  test('remote Blu-ray disc sessions run the pipeline on the host', () {
    final String gate = source
        .split('bool get _canRunSubtitlePipeline =>')[1]
        .split('bool _subtitleStudioAvailable(')[0];
    expect(gate, contains('_remoteDiscHostTitle() != null'));

    final String locate = source
        .split('RemoteDiscHostTitle? _remoteDiscHostTitle() {')[1]
        .split('bool get _subtitleAppliesInMemory')[0];
    expect(locate, contains('controller.isRemoteDiscSession'));
    expect(locate, contains('_discLearningBlocked'));
    // 多角度 title 按正在播的角度交给 host（角度成员路径）。
    expect(locate, contains('discExtractionPathForAngle('));
    // DVD 会话的 title 也交给 host（dvdvideo 按 title 读），同样按正在播的角度。
    expect(locate, contains('final bool dvd = isDvdTitlePath(path);'));
    expect(locate, contains('dvd: dvd,'));
    expect(locate, contains('source.hostTitleFor(member)'));

    final String router = source
        .split('Future<void> _openSubtitleGeneration(')[1]
        .split('Future<void> _generateSubtitleWithSpeechModel(')[0];
    expect(router, contains('_openRemoteDiscSubtitlePipeline('));
    expect(
      router.indexOf('discTitle != null'),
      lessThan(router.indexOf('_isRemote && _remoteHostVideoTarget() == null')),
    );

    final String studioPanel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('Future<void> _openSubtitleStudio(')[0];
    expect(studioPanel, contains('_remoteDiscSubtitleTarget('));
    // 远端原盘 title 也带播放器当前音轨（面板与菜单两个入口）。
    final String discMenu = source
        .split('Future<void> _openRemoteDiscSubtitlePipeline(')[1]
        .split('RemoteVideoSubtitleTarget _remoteDiscSubtitleTarget(')[0];
    for (final String entry in <String>[studioPanel, discMenu]) {
      expect(
        entry,
        matches(
          RegExp(
            r'_remoteDiscSubtitleTarget\([^;]*'
            r'audioTrack: controller\.currentAudioStreamIndex',
          ),
        ),
      );
    }
    expect(
      studioPanel,
      contains(
        '_applyRemoteDiscPipelineSubtitleWhenDone(controller, job, discTitle)',
      ),
    );
    expect(
      studioPanel.indexOf('_remoteDiscHostTitle()'),
      lessThan(studioPanel.indexOf('if (_isRemote)')),
    );

    final String target = source
        .split('RemoteVideoSubtitleTarget _remoteDiscSubtitleTarget(')[1]
        .split('Future<void> _applyRemoteDiscPipelineSubtitleWhenDone(')[0];
    expect(target, contains('discTitle: title.discTitle'));
    expect(target, contains('audioTrack: audioTrack'));

    final String done = source
        .split('Future<void> _applyRemoteDiscPipelineSubtitleWhenDone(')[1]
        .split('Future<void> _applyRemotePipelineSubtitleWhenDone(')[0];
    expect(done, contains('_episodeLoadSeq != loadSeq'));
    expect(done, contains('controller.discTitleGeneration != generation'));
    expect(done, contains('_remoteDiscHostTitle() != title'));
    expect(done, contains('matchesDiscTitle(title.videoId, title.discTitle)'));
    expect(done, contains('_registerImportedSubtitleSource(path)'));
    expect(done, contains('_applyRemoteSubtitle(controller, path)'));

    // 整集音源：host 按（盘, title）裁当前音轨。
    final String timing = source
        .split('Future<_SubtitleTimingAudio?> _resolveSubtitleTimingAudio()')[1]
        .split('Future<_SubtitleTimingAudio?> _cachedRemoteTimingAudio(')[0];
    expect(timing, contains('widget.remoteDisc?.fetchTitleAudio'));
    expect(timing, contains("'disc|\${discTitle.key}|"));
    expect(
      source.split('bool get _hasLocalOrHostTimingAudio =>')[1].split(';')[0],
      contains('_remoteDiscHostTitle() != null'),
    );

    // 取回的字幕在远端原盘会话里只进内存（会话不写库）；Fushi 字幕接管原盘字幕选择。
    final String apply = source
        .split('Future<bool> _applyRemoteSubtitle(')[1]
        .split('String _remoteEmbeddedSubtitleSource(')[0];
    expect(apply, contains('controller.claimDiscTrackOwnership();'));
    expect(
      apply.indexOf('widget.remoteDisc != null'),
      lessThan(apply.indexOf('_rememberRemoteSubtitleSource(')),
    );
    final String select = source
        .split('Future<bool> _selectSubtitleSource(')[1]
        .split('final String bookUid = _activeBookUid;')[0];
    expect(select, contains('widget.remoteDisc != null'));
    expect(select, contains('_applyRemoteSubtitle('));
  });

  // 非互联的在线流（在线视频源 / 粘贴的流与 YouTube / 音乐 MV / 媒体服务器 / 云盘流）也走
  // 完整管线：整集音频拉到本机（拉前现取地址，有进度可取消），工作台内嵌面板与播放器
  // 菜单两处入口都通，结束后按同一视频 / 同一次加载自动选中。
  test('online streams reach the full pipeline from both entries', () {
    final String gate = source
        .split('bool get _canRunSubtitlePipeline =>')[1]
        .split('bool _subtitleStudioAvailable(')[0];
    expect(gate, contains('_canRunStreamSubtitlePipeline'));
    expect(gate, contains('_streamWholeAudioAvailable && isAsrSupported'));

    final String router = source
        .split('Future<void> _openSubtitleGeneration(')[1]
        .split('Future<void> _generateSubtitleWithSpeechModel(')[0];
    expect(router, contains('_isRemote && _remoteHostVideoTarget() == null'));
    expect(
      router,
      contains(
        '_openStreamSubtitlePipeline(controller, onTranscribeInApp: inApp)',
      ),
    );

    final String studioPanel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('final String? videoPath = _localPipelineMediaPath;')[0];
    expect(
      studioPanel,
      contains(
        'if (host == null) return _streamSubtitleStudioPanel(controller, inApp);',
      ),
    );

    final String aiReference = source
        .split(
          'Future<VideoSubtitleStudioAiReference?> _subtitleStudioAiReference(',
        )[1]
        .split(
          'Map<String, List<SubtitleEvidenceTrack>> _playerSubtitleEvidence(',
        )[0];
    expect(aiReference, contains('_canRunStreamSubtitlePipeline'));

    final String prepare = source
        .split(
          'Future<VideoStreamSubtitleAudioInput> _prepareStreamWholeAudio(',
        )[1]
        .split('VideoStreamSubtitleAudioStaging? _startStreamWholeAudio()')[0];
    // 拉前现取地址（短 TTL 签名链接），再按制卡同一判据走本机中继。
    expect(prepare, contains('is RemoteVideoSubtitleAudioRefresh'));
    expect(prepare, contains('.freshSubtitleAudio('));
    expect(prepare, contains('videoMiningInputUsesPlaybackRelay('));
    expect(prepare, contains('relayFfmpegRemoteInput('));

    final String dialog = source
        .split('Future<File?> _stageStreamWholeAudioWithDialog()')[1]
        .split('Future<AppVideoSubtitleTarget?> _streamSubtitleTarget(')[0];
    expect(dialog, contains('showFushiProgressDialog('));
    expect(dialog, contains('onCancel: staging.cancel'));
    expect(dialog, contains("'video.streamSubtitleAudio'"));

    final String target = source
        .split('Future<AppVideoSubtitleTarget?> _streamSubtitleTarget(')[1]
        .split('Future<void> _openStreamSubtitlePipeline(')[0];
    expect(target, contains('.resolveStream('));
    expect(target, contains('workTitle: remoteVideoWorkTitle(info)'));
    expect(target, contains('model.setRemoteSubtitleSource(subUid, subEp'));
    expect(target, contains('videoStreamSubtitleFrameSource('));

    final String done = source
        .split('Future<void> _applyStreamPipelineSubtitleWhenDone(')[1]
        .split('/// ASR 只接单音轨文件')[0];
    expect(done, contains('_episodeLoadSeq != loadSeq'));
    expect(done, contains('identical(_controller, controller)'));
    expect(done, contains('_streamWholeAudioIdentity()?.key != streamKey'));
    expect(done, contains('_registerImportedSubtitleSource(output)'));
    expect(done, contains('_applyRemoteSubtitle(controller, output)'));
    expect(done, contains('await _setDelayMs(0)'));

    // 本机转录 / 重定时用整集副本；自动对轴与波形仍只从流里裁要看的那一段。
    final String timing = source
        .split('Future<_SubtitleTimingAudio?> _resolveSubtitleTimingAudio()')[1]
        .split('String? get _streamAlignAudioSource')[0];
    expect(timing, contains('_stageStreamWholeAudioWithDialog()'));
    expect(
      source,
      contains(
        'if (_hasLocalOrHostTimingAudio) return _resolveSubtitleTimingAudio();',
      ),
    );
    expect(
      source,
      contains(
        'subtitleAlignProbeLimitMs(fromStream: !_hasLocalOrHostTimingAudio)',
      ),
    );
  });

  // 网页模式（站点自己的播放器）也走完整管线：媒体地址从页面取（YouTube 现取 audio-only
  // 流），整集音频与在线流同一个拉取器、同一个 resolveStream；产物登记到这一集的书上，作为
  // 「生成的字幕」轨并进站点轨、选中，重进时读回。字幕菜单里有工作台入口。
  test('web mode reaches the full pipeline and shows the generated track', () {
    final String web = File(
      'lib/src/pages/implementations/video_fushi/web_source.part.dart',
    ).readAsStringSync();

    final String gate = source
        .split('bool get _canRunSubtitlePipeline =>')[1]
        .split('bool _subtitleStudioAvailable(')[0];
    expect(gate, contains('_canRunWebSubtitlePipeline'));
    expect(
      web.split('bool get _canRunWebSubtitlePipeline =>')[1],
      contains('encrypted: _webSession?.lastState?.encrypted ?? false'),
    );

    final String router = source
        .split('Future<void> _openSubtitleGeneration(')[1]
        .split('Future<void> _generateSubtitleWithSpeechModel(')[0];
    expect(router, contains('await _openWebSubtitlePipeline(controller)'));
    expect(
      router.indexOf('if (_webMode)'),
      lessThan(router.indexOf('_remoteHostVideoTarget() == null')),
    );

    final String studioPanel = source
        .split('Future<WidgetBuilder?> _subtitleStudioGeneratePanel(')[1]
        .split('final String? videoPath = _localPipelineMediaPath;')[0];
    expect(
      studioPanel,
      contains('if (_webMode) return _webSubtitleStudioPanel(controller);'),
    );

    final String aiReference = source
        .split(
          'Future<VideoSubtitleStudioAiReference?> _subtitleStudioAiReference(',
        )[1]
        .split(
          'Map<String, List<SubtitleEvidenceTrack>> _playerSubtitleEvidence(',
        )[0];
    expect(aiReference, contains('_canRunWebSubtitlePipeline'));
    expect(aiReference, contains('_webSubtitleFrameInput(webSession)'));

    // 菜单：工作台入口在网页档轨列表里。
    final String rows = web
        .split('Widget _buildWebSubtitleTrackRows(')[1]
        .split('void _onWebPageLookup(')[0];
    expect(rows, contains("'video-web-subtitle-studio'"));
    expect(rows, contains('_subtitleStudioAvailable(controller)'));
    expect(rows, contains('_openSubtitleStudio(controller)'));

    // 取地址：页面回执 + cookie；拿不到时以说明原因的失败结束。
    final String prepare = web
        .split(
          'Future<VideoStreamSubtitleAudioInput> _prepareWebWholeAudio(',
        )[1]
        .split('VideoStreamSubtitleAudioStaging? _startWebWholeAudio()')[0];
    expect(prepare, contains('prepareWebVideoSubtitleAudio('));
    expect(prepare, contains("'window.__fushiWebVideo.mediaSource()'"));
    expect(prepare, contains('cookieHeader: session.cookieHeaderFor'));
    expect(prepare, contains('throw VideoStreamSubtitleAudioUnavailable('));
    expect(
      web.split('VideoStreamSubtitleAudioStaging? _startWebWholeAudio()')[1],
      contains('appVideoStreamSubtitleAudioStager.start('),
    );

    final String target = web
        .split('Future<AppVideoSubtitleTarget?> _webSubtitleTarget(')[1]
        .split('Future<void> _openWebSubtitlePipeline(')[0];
    expect(target, contains('.resolveStream('));
    expect(
      target,
      contains('repo.updateSubtitleSource(bookUid, subtitlePath)'),
    );
    expect(target, contains('videoStreamSubtitleFrameSource('));

    final String open = web
        .split('Future<void> _openWebSubtitlePipeline(')[1]
        .split('WidgetBuilder? _webSubtitleStudioPanel(')[0];
    expect(open, contains('_stageWholeAudioWithDialog('));
    expect(open, contains('showVideoSubtitleGenerateSheet('));
    expect(open, contains('_applyWebPipelineSubtitleWhenDone('));
    final String panel = web
        .split('WidgetBuilder? _webSubtitleStudioPanel(')[1]
        .split('Future<void> _applyWebPipelineSubtitleWhenDone(')[0];
    expect(panel, contains('VideoStreamSubtitleAudioPanel('));
    expect(panel, contains('embedded: true'));
    expect(panel, contains('_applyWebPipelineSubtitleWhenDone('));

    // 结束后：同一播放器、同一集才装上并选中。
    final String done = web
        .split('Future<void> _applyWebPipelineSubtitleWhenDone(')[1]
        .split('Future<void> _restoreWebGeneratedSubtitle()')[0];
    expect(done, contains('identical(_controller, controller)'));
    expect(done, contains('_activeBookUid == bookUid'));
    expect(done, contains('AppVideoSubtitleJobStatus.succeeded'));
    expect(done, contains('_installWebGeneratedTrack(select: true)'));

    // 重进：落书后读回登记；站点换视频 key 时按新 key 重挂；已选上时不被每集默认站点轨抢走。
    final String restore = web
        .split('Future<void> _restoreWebGeneratedSubtitle()')[1]
        .split('void _installWebGeneratedTrack(')[0];
    expect(restore, contains('getVideoBookByBookUid('));
    expect(restore, contains('row?.subtitleSource'));
    final String bind = web
        .split('Future<void> _bindWebEpisode(')[1]
        .split('Future<void> _linkWebSeries(')[0];
    expect(
      'unawaited(_restoreWebGeneratedSubtitle());'.allMatches(bind),
      hasLength(2),
    );
    expect(
      web
          .split('void _onWebState(')[1]
          .split('Future<void> _bindWebEpisode(')[0],
      contains('_installWebGeneratedTrack(select: generatedWasActive)'),
    );
    expect(
      web
          .split('void _maybeRequestDefaultSiteTrack()')[1]
          .split('void _syncWebAudioTracks(')[0],
      contains('webVideoGeneratedTrackKey(_webTrackSel.videoKey)'),
    );
    final String install = web
        .split('void _installWebGeneratedTrack(')[1]
        .split('void _onWebPageLookup(')[0];
    expect(install, contains('_webTrackSel.pendingKey = null'));
    expect(install, contains('_webTrackSel.pinnedKey = key'));
    expect(install, contains('_reselectWebTrack()'));

    // 工作台拆分的日语字幕在网页档作为本机轨选中（与手机下载字幕同一个 helper）。
    final String split = source
        .split('Future<void> _extractJapaneseFromBilingualSubtitle(')[1]
        .split('Future<void> _openSubtitleGeneration(')[0];
    expect(split, contains('_selectWebLocalSubtitleTrack(target, cues)'));
  });
}
