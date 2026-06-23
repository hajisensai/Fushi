// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch5).
part of '../reader_hibiki_page.dart';

/// TODO-746　SRT cue cross-chapter in-chapter progress (0..1). When
/// `span = last - first <= 0` (single-cue chapter / no resolvable in-chapter
/// offset) returns null — callers must then preserve the current scroll and
/// never fall back to chapter-start zero. Reuses the restore-path formula
/// `((sentenceIndex - first) / span)`, removing three duplicated copies.
@visibleForTesting
double? audiobookSrtCrossChapterProgress({
  required int sentenceIndex,
  required int first,
  required int last,
}) {
  final int span = last - first;
  if (span <= 0) return null;
  return ((sentenceIndex - first) / span).clamp(0.0, 1.0);
}

/// TODO-746　sasayaki cue cross-chapter in-chapter progress (0..1). When
/// `chapterChars <= 0` (chapter char count unknown / empty chapter) returns
/// null — callers must then preserve the current scroll and never zero.
/// Reuses the restore-path formula `normCharStart / chapterChars`.
@visibleForTesting
double? audiobookSasayakiCrossChapterProgress({
  required int normCharStart,
  required int chapterChars,
}) {
  if (chapterChars <= 0) return null;
  return (normCharStart / chapterChars).clamp(0.0, 1.0);
}

/// audiobook domain helpers (profile resolution / audio-slot + session
/// attach / cue priming + SRT chapter map / position restore-from-cue /
/// volume-key sentence nav / cue-change sync + cross-chapter + boundary
/// skip / lookup-cue + sentence-audio-range resolution / audio import)
/// extracted via part-of (TODO-589 batch5); shared private scope.
/// Behaviour-preserving: bodies are byte-for-byte verbatim except the four
/// `setState(` calls (in `_attachExistingSession`, `_startAndAttachSession`,
/// `_openAudioImportDialog`, `_openSrtBookAudioPicker`) forwarded through the
/// main shell `_rebuild(` helper (extensions cannot call the @protected
/// State.setState directly). No class static is referenced, so no static
/// qualification was needed.
///
/// No member of this group is an `@override` or calls a `@protected`
/// `BaseSourcePageState` member, so nothing had to stay behind in the shell
/// on those grounds. The `@override` reader-audiobook-view forwarders
/// (`onReaderCueChanged` / `onCueCrossChapter` / `onBoundarySkip` /
/// `clearDictionaryResult` / `supportsSentenceDraft`), the open-book
/// orchestrator (`_initBook`) and the audiobook chrome (`_buildAudiobookBar`
/// / `buildPopupAudioControls` / `_currentChapterLabel`) remain in the shell,
/// reachable via the shared private class scope.
extension _ReaderAudiobook on _ReaderHibikiPageState {
  Future<void> _resolveAndApplyProfile(
    HibikiDatabase db, {
    String? mediaTypeOverride,
  }) async {
    try {
      final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
      final ProfileViewModel profileVm =
          ref.read(profileViewModelProvider.notifier);

      final String bookKey = widget.bookKey;

      String mediaType;
      if (mediaTypeOverride != null) {
        mediaType = mediaTypeOverride;
      } else {
        mediaType = 'epub';
        final abRow = await db.getAudiobookByBookKey(bookKey);
        if (abRow != null) {
          mediaType = 'audiobook';
        } else {
          final srtRow = await db.getSrtBookByBookKey(bookKey);
          if (srtRow != null) {
            mediaType = 'srtbook';
          }
        }
      }

      final int resolvedId = await profileRepo.resolveProfileId(
        bookUid: bookKey,
        mediaType: mediaType,
      );
      final int currentActiveId = await profileRepo.getActiveProfileId();
      if (resolvedId != currentActiveId) {
        await profileVm.switchProfile(resolvedId);
      }
    } catch (e, st) {
      debugPrint(
          '[ReaderHibiki] profile resolution failed (non-fatal): $e\n$st');
    }
  }

  /// TODO-131: profile 解析+应用 → 阅读器设置刷新。两步有依赖（profile 切换可能
  /// 改哪份 profile-scoped 设置生效），故内部串行；整条与书本定位/解析链并行。
  Future<void> _resolveProfileAndSettings(HibikiDatabase db) async {
    await _resolveAndApplyProfile(db);
    if (!mounted) return;
    if (ReaderHibikiSource.readerSettings == null) {
      final ReaderSettings rs = ReaderSettings(db);
      await rs.refreshFromDb();
      ReaderHibikiSource.readerSettings = rs;
    }
  }

  void _setupVolumeKeyHandlers() {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    VolumeKeyChannel.instance.setHandlers(
      onVolumeUp: () => _onVolumeKey(isUp: true),
      onVolumeDown: () => _onVolumeKey(isUp: false),
    );
    VolumeKeyChannel.instance.setInterceptEnabled(true);
    debugPrint('[ReaderHibiki] volume key handlers installed '
        '(inverted=${src.volumePageTurningInverted}, '
        'speed=${src.volumePageTurningSpeed}ms)');
  }

  void _onVolumeKey({required bool isUp}) {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    final int speedMs = src.volumePageTurningSpeed;
    final bool inverted = src.volumePageTurningInverted;
    final bool goForward = inverted ? isUp : !isUp;

    if (_audiobookController != null && src.volumeKeySentenceNavEnabled) {
      // 句子导航分支自带节流：沿用时间戳语义（HBK-AUDIT-120），与翻页节流不混。
      // speedMs<=0 关闭节流；读 speedMs 即生效，无残留 timer。
      if (speedMs > 0 && _lastVolumeKeyTime != null) {
        final int elapsedMs =
            DateTime.now().difference(_lastVolumeKeyTime!).inMilliseconds;
        if (elapsedMs < speedMs) return;
      }
      if (goForward) {
        _audiobookController!.skipToNextCue();
      } else {
        _audiobookController!.skipToPrevCue();
      }
      if (speedMs > 0) {
        _lastVolumeKeyTime = DateTime.now();
      }
      return;
    }

    // TODO-737: 翻页分支的节流归一到 _paginate 入口时间戳闸门（throttleMs:
    // volumePageTurningSpeed），与滚轮共用 _lastPaginateTime，删音量键自有翻页节流。
    _paginate(
      goForward
          ? ReaderNavigationDirection.forward
          : ReaderNavigationDirection.backward,
      throttleMs: speedMs,
    );
  }

  /// 解析并接管本书的有声书会话（TODO-291 阶段2）。
  ///
  /// 控制器现由进程级 [AudiobookSession] 持有。reader 不再自己 new / dispose 控制器，
  /// 而是：① 若已有同书的后台会话 → 直接复用（退书后台听书再进，无缝接回）；
  /// ② 否则让 session 起新会话；③ attach reader 的 WebView 侧回调。
  ///
  /// [forceReload] = true 时（导入新音频后重解析）先 stop 旧会话，逼 session 重新 load
  /// 新音频；首次开书 = false，优先复用既有后台会话。
  Future<void> _resolveAudioSlot({bool forceReload = false}) async {
    final AudiobookSession session = appModel.audiobookSession;
    final AudiobookPlayerController? old = _audiobookController;
    if (old != null) {
      // 旧引用是 session 控制器：先 detach（不 dispose）。reader 字段清掉等下面重接。
      session.detachReader(this);
      _audiobookController = null;
      _audiobookBookKey = null;
      _srtBookUid = null;
      _srtCueChapterMap = null;
      _srtChapterRanges = null;
    }
    if (forceReload && session.isActive) {
      // 导入了新音频：必须重 load，stop 旧会话让 session.start 走全新加载分支。
      await session.stop();
    }

    final HibikiDatabase db = appModel.database;
    final String bookKey = widget.bookKey;

    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(db);
    final AudiobookSessionStartRequest? req = await launcher.resolve(bookKey);
    if (req != null) {
      // 若进程级会话已持有本书控制器（退书后台听书后重进 / 同书重开），直接复用
      // （session.book.bookKey 对 EPUB 是 bookKey、对 SRT 是 uid，与 req.info.bookKey 同源）。
      if (session.isActive && session.book?.bookKey == req.info.bookKey) {
        await _attachExistingSession(session);
      } else {
        await _startAndAttachSession(session, req);
      }
    }

    await _primeAudioCuesForCurrentBook();

    if (_audiobookController == null && _lyricsMode) {
      _lyricsMode = false;
      await ReaderHibikiSource.instance.setLyricsMode(false);
    }
  }

  /// 复用 session 已持有的控制器：装 reader WebView 侧回调 + 监听 cue（经 session 转发）。
  Future<void> _attachExistingSession(AudiobookSession session) async {
    final AudiobookPlayerController? controller = session.controller;
    if (controller == null) return;
    final SessionBookInfo? info = session.book;
    // 恢复 SRT 路径标识（_srtBookUid / _audiobookBookKey），cue 同步分支据此走 SRT/EPUB。
    if (info != null) {
      if (info.audiobook.alignmentFormat == 'srt') {
        _srtBookUid = info.bookKey;
      } else {
        _audiobookBookKey = info.bookKey;
      }
    }
    _installReaderSessionSurfaces(session);
    session.attachReader(this);
    _rebuild(() {
      _audiobookController = controller;
    });
    // 同步一次当前 cue 到 WebView（暂停态也即时高亮）。
    _onCueChanged();
  }

  /// 起新会话并 attach。失败弹提示。
  Future<void> _startAndAttachSession(
    AudiobookSession session,
    AudiobookSessionStartRequest req,
  ) async {
    AudiobookPlayerController? controller;
    try {
      controller = await session.start(
        info: req.info,
        audioFiles: req.audioFiles,
        prefs: req.prefs,
        persist: req.persist,
        // 灌扁平全书 cue 作初值（_primeAudioCuesForCurrentBook 随后按章节精确覆盖）；
        // 与后台听书路径共用 req.cues，使 attach 前的瞬态也有 cue（TODO-354）。
        cues: req.cues,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.startSession', e, stack);
      debugPrint('[ReaderHibiki] audiobook session start failed: $e');
      if (mounted) HibikiToast.show(msg: t.audiobook_load_error);
      return;
    }
    if (controller == null) return;
    if (!mounted) {
      // 页面在 await 期间被弃：会话仍可在后台续播（用户决策①后台继续），不 stop。
      return;
    }
    if (req.info.audiobook.alignmentFormat == 'srt') {
      _srtBookUid = req.info.bookKey;
    } else {
      _audiobookBookKey = req.info.bookKey;
    }
    _installReaderSessionSurfaces(session);
    session.attachReader(this);
    _rebuild(() {
      _audiobookController = controller;
    });
  }

  /// 把 reader 主题样式 + reader 弹窗查词装进 session（attach 期悬浮窗用 reader 主题）。
  void _installReaderSessionSurfaces(AudiobookSession session) {
    session.installReaderSurfaces(
      floatingLyricStyle: _readerFloatingLyricStyle,
      onFloatingLyricLookup: _lookupFromFloatingLyric,
    );
  }

  Future<void> _primeAudioCuesForCurrentBook() async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;

    if (_srtBookUid != null) {
      final SrtBookRepository repo = SrtBookRepository(appModel.database);
      final List<AudioCue> cues = await repo.cuesFor(_srtBookUid!);
      controller.setChapterCues(cues);
      controller.setAllBookCues(cues);
      _cachedAllCues = cues;
      // BUG-395：SRT 书可被 matcher 匹配进真 EPUB（cue 为 sasayaki://），此处不能
      // 硬编码 false——与 _prepareSasayakiCuesJson 的判据保持一致，按 cue 内容计算。
      _cachedSasayaki = cues.any(
        (c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
      );
      final (Map<int, int> m, List<(int, int)> r) = _buildSrtChapterMap(cues);
      _srtCueChapterMap = m;
      _srtChapterRanges = r;
      return;
    }

    final String? bookKey = _audiobookBookKey;
    if (bookKey == null || _book == null) return;

    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<AudioCue> allCues = await repo.cuesForBook(bookKey);
    controller.setAllBookCues(allCues);
    _cachedAllCues = allCues;
    _cachedSasayaki = allCues.any(
      (c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
    );

    // SRT 格式导入的 Audiobook 在 matcher 全部失败时，cue 的
    // chapterHref 仍为 'srt://default'，按 EPUB 章节 href 查不到。
    // 与 SrtBook 路径对齐，直接用全部 cue。
    final bool allSrtDefault = allCues.isNotEmpty &&
        allCues
            .every((AudioCue c) => c.chapterHref == SrtParser.defaultChapter);

    if (_cachedSasayaki || allSrtDefault) {
      controller.setChapterCues(allCues);
      return;
    }

    final String chapterHref = _book!.chapters[_currentChapter].href;
    final List<AudioCue> chapterCues = await repo.cuesForChapter(
      bookKey: bookKey,
      chapterHref: chapterHref,
    );
    controller.setChapterCues(chapterCues);
  }

  (Map<int, int>, List<(int, int)>) _buildSrtChapterMap(List<AudioCue> cues) {
    if (cues.isEmpty) return (<int, int>{}, <(int, int)>[]);
    final Map<int, int> map = <int, int>{};
    final List<List<AudioCue>> chapters = CuesToEpub.splitChapters(cues);
    final List<(int, int)> ranges = <(int, int)>[];
    for (int ch = 0; ch < chapters.length; ch++) {
      ranges.add(
          (chapters[ch].first.sentenceIndex, chapters[ch].last.sentenceIndex));
      for (final AudioCue cue in chapters[ch]) {
        map[cue.sentenceIndex] = ch;
      }
    }
    return (map, ranges);
  }

  void _restoreFromCurrentAudioCue() {
    final AudioCue? cue = _audiobookController?.cueAtCurrentPositionInBook();
    if (cue == null || _book == null) return;

    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag != null &&
        frag.sectionIndex >= 0 &&
        frag.sectionIndex < _book!.chapters.length) {
      _currentChapter = frag.sectionIndex;
      // TODO-746: reuse the shared in-chapter progress helper (DRY). On initial
      // open a null (unknown char count) falls back to 0.0 = chapter start,
      // which is a sane initial anchor and preserves the original behaviour.
      _initialProgress = audiobookSasayakiCrossChapterProgress(
            normCharStart: frag.normCharStart,
            chapterChars: _chapterCharCounts[frag.sectionIndex],
          ) ??
          0.0;
      _lastProgressSection = _currentChapter;
      _lastProgressValue = _initialProgress;
      debugPrint('[ReaderHibiki] restore from audio cue: '
          'chapter=$_currentChapter progress=$_initialProgress');
      return;
    }

    if (_srtCueChapterMap != null && _srtChapterRanges != null) {
      final int? srtChapter = _srtCueChapterMap![cue.sentenceIndex];
      if (srtChapter != null &&
          srtChapter >= 0 &&
          srtChapter < _srtChapterRanges!.length &&
          srtChapter < _book!.chapters.length) {
        _currentChapter = srtChapter;
        final (int first, int last) = _srtChapterRanges![srtChapter];
        // TODO-746: reuse the shared in-chapter progress helper (DRY). On
        // initial open a null (single-cue chapter) falls back to 0.0 =
        // chapter start, preserving the original restore behaviour.
        _initialProgress = audiobookSrtCrossChapterProgress(
              sentenceIndex: cue.sentenceIndex,
              first: first,
              last: last,
            ) ??
            0.0;
        _lastProgressSection = srtChapter;
        _lastProgressValue = _initialProgress;
        debugPrint('[ReaderHibiki] restore from SRT cue: '
            'chapter=$srtChapter progress=$_initialProgress');
        return;
      }
    }

    final int chapter = _chapterIndexForCue(cue);
    final int fallbackChapter =
        chapter >= 0 ? chapter : _chapterIndexForText(cue.text);
    if (fallbackChapter < 0) return;
    _currentChapter = fallbackChapter;
    _initialProgress = 0.0;
    _lastProgressSection = fallbackChapter;
    _lastProgressValue = 0.0;
    debugPrint('[ReaderHibiki] restore from audio cue chapter: '
        'chapter=$_currentChapter href=${cue.chapterHref}');
  }

  int _chapterIndexForCue(AudioCue cue) {
    if (_book == null) return -1;
    final String chapterHref = cue.chapterHref.trim();
    if (chapterHref.isEmpty) return -1;
    for (int i = 0; i < _book!.chapters.length; i++) {
      if (_book!.chapters[i].href == chapterHref) {
        return i;
      }
    }
    return -1;
  }

  int _chapterIndexForText(String text) {
    if (_book == null) return -1;
    final String needle = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (needle.length < 6) return -1;
    for (int i = 0; i < _book!.chapters.length; i++) {
      final String chapterText = _book!.chapterPlainText(i);
      if (chapterText.contains(needle)) {
        return i;
      }
    }
    return -1;
  }

  void _onCueChanged() {
    if (!mounted || _controller == null) return;
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;

    if (_lyricsMode) {
      if (_lyricsPageReady) {
        final int idx = controller.allBookCuesSnapshot.isNotEmpty
            ? controller.allBookCueIdx
            : controller.currentCueIdx;
        if (idx >= 0) {
          // followAudio OFF → pass scroll=false so the lyrics page updates the
          // current-line highlight but does not auto-scroll (the toggle was a
          // no-op before: __lyricsSetCue always scrolled regardless).
          _controller!.evaluateJavascript(
            source: 'if(window.__lyricsSetCue)'
                'window.__lyricsSetCue($idx, ${controller.followAudio.value});',
          );
        }
      }
      _syncPositionFromCurrentCue();
      return;
    }

    final AudioCue? cue = controller.currentCue;
    if (cue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag != null && frag.sectionIndex != _currentChapter) {
        AudiobookBridge.highlight(_controller!);
        return;
      }
      if (frag == null && _srtCueChapterMap != null) {
        final int? cueChapter = _srtCueChapterMap![cue.sentenceIndex];
        if (cueChapter != null && cueChapter != _currentChapter) {
          if (controller.shouldRevealCurrentCue && !_restoreInFlight) {
            // TODO-746: land on the cue's real in-chapter position instead of
            // the default progress=0.0 → restoreProgress(0) → scrollToChapterStart
            // six-fold clear (the "slides to chapter 1" symptom). cueChapter is a
            // map hit, so the chapter has structure; a null progress (single-cue
            // chapter) falls back to that chapter's start, which is its real
            // position, not a zero sentinel.
            final List<(int, int)>? ranges = _srtChapterRanges;
            double? progress;
            if (ranges != null &&
                cueChapter >= 0 &&
                cueChapter < ranges.length) {
              final (int first, int last) = ranges[cueChapter];
              progress = audiobookSrtCrossChapterProgress(
                sentenceIndex: cue.sentenceIndex,
                first: first,
                last: last,
              );
            }
            _navigateToChapter(cueChapter, progress: progress ?? 0.0);
          } else {
            AudiobookBridge.highlight(_controller!);
          }
          return;
        }
      }
    }
    final bool forceReveal = controller.consumeForceReveal();
    final bool reveal = forceReveal || controller.shouldRevealCurrentCue;
    // TODO-724：仅当图片暂停开启（imagePauseSec>0）时，cue 推进跨过插图才把视口
    // 滚到插图（配合 Dart 的 triggerImagePause 暂停让用户看见）。imagePauseSec=0
    // 时图片暂停关闭，绝不滚图，否则视口会无预兆跳到不知哪张图（用户报告症状）。
    final bool pauseEnabled = controller.imagePauseSec.value > 0;
    AudiobookBridge.highlight(
      _controller!,
      cue: cue,
      reveal: reveal,
      pauseEnabled: pauseEnabled,
    );
    _syncPositionFromCurrentCue();
  }

  Future<void> _handleCueCrossChapter(int newSection) async {
    if (_lyricsMode) {
      _audiobookController?.cancelChapterTransition();
      return;
    }
    if (_restoreInFlight ||
        _book == null ||
        newSection < 0 ||
        newSection >= _book!.chapters.length) {
      _audiobookController?.cancelChapterTransition();
      return;
    }
    // TODO-746: reuse the same sasayaki in-chapter progress formula the restore
    // path already uses, so cross-chapter playback lands on the cue's real
    // in-chapter position instead of _navigateToChapter's default progress=0.0
    // → restoreProgress(0) → scrollToChapterStart six-fold clear (the "slides to
    // chapter 1" symptom). newSection here is the matched cue's own declared
    // section (frag.sectionIndex; a text-missing cue has a null/cleared fragment
    // and never reaches this path), so it legitimately belongs in newSection —
    // we only need its offset, not a chapter switch. A null progress (chapter
    // char count transiently 0 before the lazy recompute lands) falls back to
    // 0.0 = that chapter's own start, which is the original behaviour for a
    // matched cue and is NOT a zero-to-chapter-1 (it is its real chapter).
    final AudioCue? cue = _audiobookController?.currentCue;
    final SasayakiFragment? frag =
        cue == null ? null : SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    double? progress;
    if (frag != null && newSection < _chapterCharCounts.length) {
      progress = audiobookSasayakiCrossChapterProgress(
        normCharStart: frag.normCharStart,
        chapterChars: _chapterCharCounts[newSection],
      );
    }
    await _navigateToChapter(newSection, progress: progress ?? 0.0);
  }

  Future<void> _handleBoundarySkip(int delta) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final int targetSec = _currentChapter + delta;
    if (_book == null || targetSec < 0 || targetSec >= _book!.chapters.length) {
      return;
    }
    final List<AudioCue> targetCues =
        controller.sasayakiCuesForSection(targetSec);
    if (targetCues.isEmpty) {
      await _navigateToChapter(targetSec);
      return;
    }
    await controller.skipToCue(targetCues.first);
  }

  int get _lookupSectionIndex {
    if (_lyricsMode && _lookupCue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(_lookupCue!.textFragmentId);
      if (frag != null) return frag.sectionIndex;
    }
    return _currentChapter;
  }

  AudioCue? _findCueForOffset(int normalizedOffset) {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) return null;
    final List<AudioCue> cues = ctrl.sasayakiCuesForSection(_currentChapter);
    for (final AudioCue cue in cues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag == null) continue;
      if (frag.normCharStart <= normalizedOffset &&
          frag.normCharEnd > normalizedOffset) {
        return cue;
      }
    }
    return null;
  }

  AudioCue? _findCueForSentence(String sentence) {
    if (_srtBookUid == null) return null;
    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null || allCues.isEmpty) return null;

    final int chapter = _currentChapter;
    int startIdx = 0;
    int endIdx = allCues.length;
    if (_srtChapterRanges != null &&
        chapter >= 0 &&
        chapter < _srtChapterRanges!.length) {
      final (int first, int last) = _srtChapterRanges![chapter];
      startIdx = first;
      endIdx = last + 1;
    }

    final String needle = sentence.trim();
    if (needle.isEmpty) return null;

    for (int i = startIdx; i < endIdx && i < allCues.length; i++) {
      if (allCues[i].text.trim() == needle) return allCues[i];
    }
    for (int i = startIdx; i < endIdx && i < allCues.length; i++) {
      if (allCues[i].text.length > 2 && needle.contains(allCues[i].text)) {
        return allCues[i];
      }
    }
    return null;
  }

  List<AudioCue> _sentenceAudioMiningCues(AudioCue? cue) {
    if (_lyricsMode && _lyricsCueList.isNotEmpty) {
      return _lyricsCueList;
    }

    final List<AudioCue>? allCues = _cachedAllCues;
    if (_srtBookUid != null && allCues != null && allCues.isNotEmpty) {
      final int chapter = _currentChapter;
      if (_srtChapterRanges != null &&
          chapter >= 0 &&
          chapter < _srtChapterRanges!.length) {
        final (int first, int last) = _srtChapterRanges![chapter];
        final int safeFirst = first.clamp(0, allCues.length);
        final int safeLast = (last + 1).clamp(safeFirst, allCues.length);
        return allCues.sublist(safeFirst, safeLast);
      }
      return allCues;
    }

    final List<AudioCue> sectionCues =
        _audiobookController?.sasayakiCuesForSection(_lookupSectionIndex) ??
            const <AudioCue>[];
    if (sectionCues.isNotEmpty) {
      return sectionCues;
    }

    final List<AudioCue> chapterCues =
        _audiobookController?.chapterCuesSnapshot ?? const <AudioCue>[];
    if (chapterCues.isNotEmpty) {
      return chapterCues;
    }

    // Gap word with no cue and no section/chapter cues: nothing to clip.
    return cue != null ? <AudioCue>[cue] : const <AudioCue>[];
  }

  void _syncCueSentence() {
    final String cueText = _lookupCue?.text ?? '';
    if (cueText.isNotEmpty) {
      appModel.currentMediaSource?.setCurrentCueSentence(
        selection: HibikiTextSelection(text: cueText),
      );
    } else {
      appModel.currentMediaSource?.clearCurrentCueSentence();
    }
  }

  /// TODO-104a / BUG-172：当前正查这一句对应的句子音频区间（已含 A/V 同步偏移）。
  /// 抽出来给「制卡」与「上 N 句 / 下 N 句」上下文共用，确保两条路径裁的是同一句同一
  /// 区间。返回 null 表示无音频文件，或无法从当前 cue / 句子 span 解析出区间。
  AudioPlaybackRange? _currentSentenceAudioRange() {
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    return _sentenceAudioRangeFor(
      sentence: sentence,
      cue: _lookupCue,
      normOffset: _cachedSentenceRange?.offset,
      normLength: _cachedSentenceRange?.length,
    );
  }

  /// TODO-393：把任意一句（当前句或上下文句）按其整书归一化偏移解析成句子音频区间
  /// （已含 A/V 同步偏移）。上下文句没有 cue，[cue] 传 null，纯靠 [normOffset]/
  /// [normLength] 在本 section 的 cue 列表里定位（[miningSentenceAudioRange] 支持）。
  /// 无音频文件或解析不出区间时返回 null（调用方退化为只合文本）。
  AudioPlaybackRange? _sentenceAudioRangeFor({
    required String sentence,
    AudioCue? cue,
    int? normOffset,
    int? normLength,
  }) {
    final AudiobookPlayerController? audioController = _audiobookController;
    final List<File>? audioFiles = audioController?.audioFiles;
    if (audioFiles == null) return null;
    final AudioPlaybackRange? clip = miningSentenceAudioRange(
      cues: _sentenceAudioMiningCues(cue),
      cue: cue,
      sentence: sentence,
      sectionIndex: _lookupSectionIndex,
      sentenceNormCharOffset: normOffset,
      sentenceNormCharLength: normLength,
      delayMs: audioController?.delayMs.value ?? 0,
    );
    if (clip == null ||
        clip.audioFileIndex < 0 ||
        clip.audioFileIndex >= audioFiles.length) {
      return null;
    }
    return clip;
  }

  /// 有声书是否已激活（有控制器且本章有 cue）。Space 播放/暂停覆写的统一闸门，
  /// 正文焦点路径与底栏焦点路径（BUG-204）共用同一判据。
  bool get _hasActiveAudiobook =>
      _audiobookController != null && _audiobookController!.chapterCueCount > 0;

  Future<void> _openAudioImportDialog() async {
    if (_srtBookUid != null) {
      await _openSrtBookAudioPicker();
      return;
    }
    final AudiobookRepository repo = AudiobookRepository(appModel.database);

    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AudiobookImportDialog(
        bookKey: widget.bookKey,
        repo: repo,
        extractDir: _extractDir,
      ),
    );

    try {
      // 导入了新音频：强制重 load（停旧会话再起新），否则同书会复用旧控制器不换源。
      await _resolveAudioSlot(forceReload: true);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.openAudioImport', e, stack);
      debugPrint('[ReaderHibiki] resolveAudioSlot after import failed: $e');
    }
    if (mounted) _rebuild(() {});
  }

  Future<void> _openSrtBookAudioPicker() async {
    final SrtBookRepository repo = SrtBookRepository(appModel.database);
    final SrtBook? book = await repo.findByUid(_srtBookUid!);
    if (book == null || !mounted) return;

    final List<String>? newPaths = await showAppDialog<List<String>>(
      context: context,
      builder: (ctx) {
        final String currentLabel =
            book.audioPaths != null && book.audioPaths!.isNotEmpty
                ? t.srt_import_files_selected(n: book.audioPaths!.length)
                : (book.audioRoot ?? t.audio_panel_add_audio);
        return ReaderSrtAudioPickerDialog(
          currentLabel: currentLabel,
          onPickFiles: () => _pickSrtAudioFiles(ctx),
        );
      },
    );

    if (newPaths == null || newPaths.isEmpty || !mounted) return;

    HibikiToast.show(msg: t.dialog_importing);

    try {
      final Directory persistDir =
          await AudiobookStorage.ensurePersistDir(_srtBookUid!);
      await AudiobookStorage.cleanAudioFiles(persistDir);

      final List<String> persisted = <String>[];
      for (final String src in newPaths) {
        persisted.add(
          await AudiobookStorage.persistFileWithProgress(File(src), persistDir),
        );
      }

      book.audioPaths = persisted;
      book.audioRoot = null;
      await repo.save(book);

      // 换了 SRT 书的音频：强制重 load（停旧会话再起新）。
      await _resolveAudioSlot(forceReload: true);
      if (mounted) {
        _rebuild(() {});
        HibikiToast.show(msg: t.audiobook_import_success);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.srtBookAudioPicker', e, stack);
      debugPrint('[ReaderHibiki] srtBookAudioPicker failed: $e');
      if (mounted) HibikiToast.show(msg: t.audiobook_import_error);
    }
  }

  Future<void> _pickSrtAudioFiles(BuildContext dialogContext) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null) return;
    final List<String> paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList()
      ..sort(compareAudioFilePath);
    if (paths.isNotEmpty && dialogContext.mounted) {
      Navigator.pop(dialogContext, paths);
    }
  }
}
