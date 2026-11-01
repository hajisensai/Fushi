part of '../reader_fushi_page.dart';

/// 阅读器侧的 TTS 朗读入口：选择「从当前位置朗读 / 继续上次 / 声音设置 / 导入有声书」，
/// 起 [TtsReadAlong] 会话并像录音有声书一样 attach 到本页（高亮、跟随、歌词、制卡
/// 全走有声书既有路径）。
extension _ReaderTtsExtension on _ReaderFushiPageState {
  TtsServices get _ttsServices => TtsServices.of(appModel.prefsRepo);

  /// 当前挂着的是不是 TTS 朗读会话。
  TtsReadAlong? get _ttsReadAlong =>
      TtsReadAlong.forController(_audiobookController);

  /// 没挂有声书时听书入口（顶栏按钮 / 快捷键 B / 底栏）弹的选择。
  Future<void> _openListenEntry() async {
    if (!_moduleVisibility.isEnabled(ModuleId.listening)) return;
    final TtsServices tts = _ttsServices;
    await tts.seedBuiltinVoiceIfUnset();
    if (!mounted) return;
    final ({TtsVoicePreset preset, TtsProviderDescriptor descriptor})? voice =
        tts.activeVoice();
    final bool hasResume = tts.store.resumeFor(widget.bookKey) != null;
    final _ListenEntryChoice? choice = await _withStudyClockPaused(
      () => showFushiChoiceDialog<_ListenEntryChoice>(
        context: context,
        title: t.audiobook_tts_entry_title,
        icon: FushiIcons.audiobook,
        options: <FushiChoiceOption<_ListenEntryChoice>>[
          FushiChoiceOption<_ListenEntryChoice>(
            value: _ListenEntryChoice.readFromHere,
            label: t.audiobook_tts_read_from_here,
            subtitle: voice == null
                ? t.audiobook_tts_no_voice
                : _ttsVoiceName(voice.preset),
            icon: FushiIcons.voice,
          ),
          if (hasResume && voice != null)
            FushiChoiceOption<_ListenEntryChoice>(
              value: _ListenEntryChoice.resume,
              label: t.audiobook_tts_resume,
              icon: FushiIcons.playCircle,
            ),
          FushiChoiceOption<_ListenEntryChoice>(
            value: _ListenEntryChoice.voiceSettings,
            label: t.audiobook_tts_voice_settings,
            subtitle: t.audiobook_tts_voice_settings_hint,
            icon: FushiIcons.settings,
          ),
          FushiChoiceOption<_ListenEntryChoice>(
            value: _ListenEntryChoice.importAudiobook,
            label: t.audiobook_tts_import_audiobook,
            icon: FushiIcons.importFile,
          ),
          FushiChoiceOption<_ListenEntryChoice>(
            value: _ListenEntryChoice.makeAudiobook,
            label: t.audiobook_studio_title,
            subtitle: t.audiobook_studio_hint,
            icon: FushiIcons.audiobook,
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case _ListenEntryChoice.readFromHere:
        if (voice == null) {
          await _openTtsVoiceSettings();
          return;
        }
        await _startTtsReading(resume: false);
      case _ListenEntryChoice.resume:
        await _startTtsReading(resume: true);
      case _ListenEntryChoice.voiceSettings:
        await _openTtsVoiceSettings();
      case _ListenEntryChoice.importAudiobook:
        await _openAudioImportDialog();
      case _ListenEntryChoice.makeAudiobook:
        await _openTtsStudio();
    }
  }

  /// 「制作有声书」工作台。期间有本书的任务做完入库，回来时挂上新有声书。
  Future<void> _openTtsStudio() async {
    final TtsRenderQueue queue = ttsRenderQueueFor(appModel);
    final TtsRenderJob? before = queue.latestFor(widget.bookKey);
    final bool wasDone =
        before != null && before.status == TtsRenderJobStatus.done;
    await _withStudyClockPaused(
      () => openTtsStudioPage(
        context,
        appModel: appModel,
        bookKey: widget.bookKey,
      ),
    );
    if (!mounted) return;
    final TtsRenderJob? after = queue.latestFor(widget.bookKey);
    final bool completed =
        after != null &&
        after.status == TtsRenderJobStatus.done &&
        (!wasDone || !identical(after, before));
    if (!completed) return;
    try {
      await _resolveAudioSlot(forceReload: true);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.openTtsStudio', e, stack);
    }
    if (mounted) _rebuild(() {});
  }

  static String _ttsVoiceName(TtsVoicePreset preset) =>
      preset.name.isEmpty ? ttsProviderLabel(preset.providerId) : preset.name;

  /// 朗读声音设置页。朗读进行中时，回来后把「使用中」的声音应用到正在进行的
  /// 朗读（在设置页里换了声音 / 改了参数，回来就生效，不必停掉重开）。
  Future<void> _openTtsVoiceSettings() async {
    await _withStudyClockPaused(
      () => openTtsVoiceSettingsPage(context, _ttsServices),
    );
    if (!mounted || _ttsReadAlong == null) return;
    await _applyActiveTtsVoiceToReading();
  }

  /// 朗读中快速切换声音（播放条 / 有声书面板的声音入口）：选中即设为使用中并
  /// 热切换；「朗读声音」项进设置页。与其它音频模态一样经共享边界：先收起本页
  /// 选区 / 操作条、暂停学习时钟，再弹对话框。
  Future<void> _openTtsVoiceQuickSwitch() async {
    final TtsServices tts = _ttsServices;
    final TtsVoiceQuickSwitchChoice? choice = await _withStudyClockPaused(
      () => showTtsVoiceQuickSwitch(context, tts),
    );
    if (choice == null || !mounted) return;
    final String? presetId = choice.presetId;
    if (presetId == null) {
      await _openTtsVoiceSettings();
      return;
    }
    await tts.store.setActivePresetId(presetId);
    if (!mounted) return;
    await _applyActiveTtsVoiceToReading();
  }

  /// 把「使用中」的声音应用到正在进行的朗读：能热切换就从当前句句首换声音续播；
  /// 现有分句放不下新引擎的长度上限时，用新声音从当前句重起朗读会话。
  Future<void> _applyActiveTtsVoiceToReading() async {
    final TtsReadAlong? readAlong = _ttsReadAlong;
    if (readAlong == null) return;
    final ({TtsVoicePreset preset, TtsProviderDescriptor descriptor})? voice =
        _ttsServices.activeVoice();
    if (voice == null) {
      FushiToast.show(
        msg: t.audiobook_tts_no_voice,
        severity: ToastSeverity.warning,
      );
      return;
    }
    // 重起时保持原来的播放 / 暂停状态；位置取换声音那一刻的当前句。
    final bool wasPlaying = _audiobookController?.isPlaying ?? false;
    final TtsPlanSentence? sentence = readAlong.currentSentence;
    final TtsVoiceSwitchOutcome outcome;
    try {
      outcome = await readAlong.switchVoice(voice.preset, voice.descriptor);
    } on TtsStartException {
      if (mounted) {
        FushiToast.show(
          msg: t.audiobook_tts_voice_incomplete,
          severity: ToastSeverity.warning,
        );
      }
      return;
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.switchTtsVoice', e, stack);
      if (mounted) {
        FushiToast.show(
          msg: t.audiobook_tts_start_failed,
          severity: ToastSeverity.error,
        );
      }
      return;
    }
    if (!mounted) return;
    switch (outcome) {
      case TtsVoiceSwitchOutcome.unchanged:
        return;
      case TtsVoiceSwitchOutcome.switched:
        _rebuild(() {});
      case TtsVoiceSwitchOutcome.needsRestart:
        await _startTtsReading(
          resume: false,
          at: sentence == null
              ? null
              : TtsStartAtSentence(
                  section: sentence.section,
                  matchStart: sentence.matchStart,
                ),
          autoplay: wasPlaying,
        );
    }
  }

  /// 起朗读会话：从阅读器当前位置，或（[resume]）上次朗读的断点，或（[at]）
  /// 指定的一句。[autoplay] 为假时只定位不播放。
  Future<void> _startTtsReading({
    required bool resume,
    TtsStartPoint? at,
    bool autoplay = true,
  }) async {
    if (!_moduleVisibility.isEnabled(ModuleId.listening)) return;
    final EpubBook? book = _book;
    if (book == null) return;
    await appModel.initialiseAudioHandler();
    if (!mounted) return;
    final AudiobookSession session = appModel.audiobookSession;
    _detachAudioSlotFromReader(session);

    final TtsStartAtReader here = TtsStartAtReader(
      section: _currentChapter,
      studyOffset: _tocCharOffsetFor(_currentChapter) ?? 0,
    );
    final String? extractDir = _extractDir;
    final SessionBookInfo info = SessionBookInfo(
      bookKey: widget.bookKey,
      audiobook: Audiobook()
        ..bookKey = widget.bookKey
        ..alignmentFormat = 'tts'
        ..alignmentPath = '',
      title:
          ReaderFushiSource.instance.overrideTitleForBookKey(widget.bookKey) ??
          book.title,
      mediaIdentifier: 'fushi://book/${widget.bookKey}',
      isTtsSource: true,
      author: book.author,
      coverPath: extractDir == null
          ? null
          : ReaderFushiSource.resolveCoverFilePath(
              extractDir: extractDir,
              coverPath: book.coverHref,
            ),
      statsMediaKey: widget.bookKey,
    );

    FushiToast.show(msg: t.audiobook_tts_preparing);
    final TtsReadAlong readAlong;
    try {
      readAlong = await TtsReadAlong.start(
        session: session,
        services: _ttsServices,
        book: book,
        info: info,
        startPoint: at ?? (resume ? TtsStartAtResume(fallback: here) : here),
        autoplay: autoplay,
        // 制作台给角色配过声音的书：朗读也按角色换声音。
        cast: await ttsCastStoreFor(appModel).load(widget.bookKey),
      );
    } on TtsStartException catch (e) {
      if (!mounted) return;
      FushiToast.show(
        msg: switch (e.problem) {
          TtsStartProblem.noVoice => t.audiobook_tts_no_voice,
          TtsStartProblem.voiceIncomplete => t.audiobook_tts_voice_incomplete,
          TtsStartProblem.emptyBook => t.audiobook_tts_empty_book,
          TtsStartProblem.castVoiceUnavailable =>
            t.audiobook_tts_cast_voice_unavailable,
        },
        severity: ToastSeverity.warning,
      );
      switch (e.problem) {
        case TtsStartProblem.emptyBook:
          break;
        case TtsStartProblem.castVoiceUnavailable:
          // 角色声音在制作台的选角里改。
          await _openTtsStudio();
        case TtsStartProblem.noVoice:
        case TtsStartProblem.voiceIncomplete:
          await _openTtsVoiceSettings();
      }
      return;
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.startTts', e, stack);
      if (mounted) {
        FushiToast.show(
          msg: t.audiobook_tts_start_failed,
          severity: ToastSeverity.error,
        );
      }
      return;
    }
    // 提示里带上出错的声音名：声音能在播放中换、多声优时每个角色一个声音，用户
    // 要知道是哪个声音失败了。
    readAlong.onFailure = (TtsFailure failure) {
      final TtsResolvedVoice voice = readAlong.failedVoice;
      FushiToast.show(
        msg:
            '${ttsVoiceDisplayName(voice.preset)}: '
            '${ttsFailureText(failure, descriptor: voice.descriptor)}\n'
            '${t.audiobook_tts_retry_hint}',
        severity: ToastSeverity.error,
      );
    };
    final AudiobookPlayerController? controller = session.controller;
    if (!mounted || controller == null) return;
    await _attachTtsSession(session, readAlong, controller);
  }

  /// 把朗读会话接到本页：与 [_attachExistingSession] 同一套回调，cue 来自会话内存。
  Future<void> _attachTtsSession(
    AudiobookSession session,
    TtsReadAlong readAlong,
    AudiobookPlayerController controller,
  ) async {
    _ttsCues = readAlong.cues;
    _audiobookBookKey = widget.bookKey;
    _installReaderSessionSurfaces(session);
    session.attachReader(this);
    _rebuild(() {
      _audiobookController = controller;
      _syncChromePlaybackListener();
    });
    _reapplyLyricsFollowOverride();
    await _primeAudioCuesForCurrentBook();
    // 朗读是在章节已经加载之后开始的：本章的句子区间要现在交给 WebView，
    // 否则要等下一次章节加载才有高亮。
    final InAppWebViewController? web = _controller;
    if (web != null && mounted) {
      await AudiobookBridge.inject(
        web,
        primaryColor: _themeSentenceAudioHighlightColor(),
      );
      await AudiobookBridge.applySentenceAudioCues(
        web,
        sectionIndex: _currentChapter,
        cues: readAlong.cues,
      );
    }
    _onCueChanged();
  }

  /// 停止朗读（面板「停止朗读」）：停会话，本页回到无有声书状态。
  Future<void> _stopTtsReading() async {
    final AudiobookSession session = appModel.audiobookSession;
    if (_ttsReadAlong == null) return;
    _detachAudioSlotFromReader(session);
    await session.stop();
    if (_lyricsMode) {
      _lyricsMode = false;
      await ReaderFushiSource.instance.setLyricsMode(false);
    }
    final InAppWebViewController? web = _controller;
    if (web != null && mounted) await AudiobookBridge.highlight(web);
    if (mounted) _rebuild(() {});
  }
}

enum _ListenEntryChoice {
  readFromHere,
  resume,
  voiceSettings,
  importAudiobook,
  makeAudiobook,
}
