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
    }
  }

  static String _ttsVoiceName(TtsVoicePreset preset) =>
      preset.name.isEmpty ? ttsProviderLabel(preset.providerId) : preset.name;

  Future<void> _openTtsVoiceSettings() async {
    await _withStudyClockPaused(
      () => openTtsVoiceSettingsPage(context, _ttsServices),
    );
  }

  /// 起朗读会话：从阅读器当前位置，或（[resume]）上次朗读的断点。
  Future<void> _startTtsReading({required bool resume}) async {
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
        startPoint: resume ? TtsStartAtResume(fallback: here) : here,
      );
    } on TtsStartException catch (e) {
      if (!mounted) return;
      FushiToast.show(
        msg: switch (e.problem) {
          TtsStartProblem.noVoice => t.audiobook_tts_no_voice,
          TtsStartProblem.voiceIncomplete => t.audiobook_tts_voice_incomplete,
          TtsStartProblem.emptyBook => t.audiobook_tts_empty_book,
        },
        severity: ToastSeverity.warning,
      );
      if (e.problem != TtsStartProblem.emptyBook) {
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
    readAlong.onFailure = (TtsFailure failure) => FushiToast.show(
      msg: '${ttsFailureText(failure)}\n${t.audiobook_tts_retry_hint}',
      severity: ToastSeverity.error,
    );
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

enum _ListenEntryChoice { readFromHere, resume, voiceSettings, importAudiobook }
