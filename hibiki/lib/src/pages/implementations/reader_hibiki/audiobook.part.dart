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

/// 普通 EPUB + SRT 音频在 matcher 未能落到 EPUB 章节时，cue 仍保留
/// `srt://default`。这种书没有可按 chapterHref 再筛的本章 cue，reader 应把全书
/// cue 当作当前章节 cue 使用。
@visibleForTesting
bool audiobookCuesUseWholeBookForChapter(List<AudioCue> allCues) {
  return allCues.isNotEmpty &&
      allCues.every(
        (AudioCue cue) => cue.chapterHref == SrtParser.defaultChapter,
      );
}

/// TODO-807　SRT 被动跨章导航目标决策（纯函数）。
///
/// `_srtCueChapterMap` 的 value 是 [CuesToEpub.splitChapters] 的人工切章序号，
/// 与 EPUB `_book!.chapters` 的真实 spine index **零映射**。把序号直接当 index
/// 导航会滑到错误章——常是目录/nav 页（日文 EPUB spine 首项常是目录）。本函数
/// 收口决策：
///   * [resolvedChapter] < 0（按 chapterHref / 正文都反查不到真实章）→ 返回 -1
///     「保位不跳」，**绝不**回退到 index 0。
///   * 反查到的章是目录/nav 页（[resolvedIsNav]）→ 返回 -1 保位。
///   * 与当前章相同 → 返回 -1（无需导航）。
///   * 否则返回 [resolvedChapter] 作为真实导航目标。
@visibleForTesting
int audiobookSrtCrossChapterTarget({
  required int resolvedChapter,
  required int currentChapter,
  required bool resolvedIsNav,
}) {
  if (resolvedChapter < 0) return -1;
  if (resolvedIsNav) return -1;
  if (resolvedChapter == currentChapter) return -1;
  return resolvedChapter;
}

/// TODO-1037　跨章推进经过的「独立成章纯图片页」决策（纯函数）。
///
/// 有声书章节推进完全由 cue 驱动；纯图片章没有 cue，于是 cue 驱动的跨章会一步从
/// 文本章 [fromChapter] 跳到下一个有文本的章 [toChapter]，中间整章是图片的章从不
/// 挂载、从不停留——即使用户开了「图片等待」也跳过（图片等待原本只在已渲染章同一
/// DOM 内相邻 cue 锚点间生效，跨章两锚点在不同章 DOM）。
///
/// 本函数收口决策：返回 [fromChapter] 与 [toChapter] **之间（开区间，两端都不含）**
/// 按阅读顺序排列、需要停留展示的纯图片章 index 列表。
///   * `pauseSec <= 0`（图片等待关）→ 返回空列表，调用方按原跨章直跳。
///   * `from`/`to` 任一越界、或 `from == to`、或两章相邻（中间无章）→ 空列表。
///   * 中间章里 [isImageOnly] 为真且 [isNav] 为假者按顺序收集；非图片章 / 目录页
///     不停留（目录页停留无意义，且与被动跨章不落 nav 页的既有语义一致）。
///
/// 支持 [fromChapter] > [toChapter]（理论上的回退跨章）：按从 from 向 to 的阅读
/// 方向逐章枚举，保证停留顺序对用户自然（先看见先经过的图）。
@visibleForTesting
List<int> imageOnlyChaptersToPauseBetween({
  required int fromChapter,
  required int toChapter,
  required int pauseSec,
  required int chapterCount,
  required bool Function(int index) isImageOnly,
  required bool Function(int index) isNav,
}) {
  if (pauseSec <= 0) return const <int>[];
  if (fromChapter == toChapter) return const <int>[];
  if (fromChapter < 0 || toChapter < 0) return const <int>[];
  if (fromChapter >= chapterCount || toChapter >= chapterCount) {
    return const <int>[];
  }
  final int step = toChapter > fromChapter ? 1 : -1;
  final List<int> out = <int>[];
  for (int i = fromChapter + step; i != toChapter; i += step) {
    if (i < 0 || i >= chapterCount) break;
    if (isNav(i)) continue;
    if (isImageOnly(i)) out.add(i);
  }
  return out;
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
    ProfileMediaKind? mediaTypeOverride,
  }) async {
    try {
      final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
      final ProfileViewModel profileVm =
          ref.read(profileViewModelProvider.notifier);

      final String bookKey = widget.bookKey;

      ProfileMediaKind mediaType;
      if (mediaTypeOverride != null) {
        mediaType = mediaTypeOverride;
      } else {
        mediaType = ProfileMediaKind.epub;
        final abRow = await db.getAudiobookByBookKey(bookKey);
        if (abRow != null) {
          mediaType = ProfileMediaKind.audiobook;
        } else {
          final srtRow = await db.getSrtBookByBookKey(bookKey);
          if (srtRow != null) {
            mediaType = ProfileMediaKind.srtbook;
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
        '(inverted=${src.volumePageTurningInverted})');
  }

  void _onVolumeKey({required bool isUp}) {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    // 音量键翻页/句子导航共用固定节流（原可调「翻页速度」已移除，TODO-737）。
    final int speedMs = ReaderHibikiSource.defaultScrollingSpeed;
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

    // TODO-737: 翻页分支的节流归一到 _paginate 入口时间戳闸门（固定 throttleMs =
    // defaultScrollingSpeed），与滚轮共用 _lastPaginateTime，删音量键自有翻页节流。
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
    // TODO-perf（开媒体反馈）：openMedia 已改为不阻塞等 audio_service 冷启，这里
    // 是 handler 的真正消费点（session attach/start 挂媒体通知与控制流）——await
    // 同一份记忆化 future 补齐时序契约；已就绪时立即返回，零额外开销。
    await appModel.initialiseAudioHandler();
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
      // 缓存生命周期 = 音频槽绑定：detach 即失效，重接后由
      // _primeAudioCuesForCurrentBook 重灌（_prepareSasayakiCuesJson 复用它，
      // 不再每章重查全书 cue）。
      _cachedAllCues = null;
      _cachedSasayaki = false;
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
      if (info.isSrtBookSource) {
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
    if (req.info.isSrtBookSource) {
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
    if (_cachedSasayaki || audiobookCuesUseWholeBookForChapter(allCues)) {
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

  /// TODO-807：把一条 SRT cue 反查回 `_book!.chapters` 的**真实** index。
  ///
  /// `_srtCueChapterMap` 的 value 是 [CuesToEpub.splitChapters] 的人工切章
  /// 序号，与 EPUB spine 无映射；直接当 chapters index 用会滑到错误章（常是
  /// 目录/nav 页）。这里先按 cue 的 `chapterHref` 精确匹配章节 href，匹配不到
  /// 再按 cue 正文文本在各章正文里查（短文本不可靠则放弃）。两者皆失败返回
  /// -1，调用方据此**保位不跳**，绝不回退到 index 0。
  int _resolveSrtCueChapter(AudioCue cue) {
    final int byHref = _chapterIndexForCue(cue);
    if (byHref >= 0) return byHref;
    return _chapterIndexForText(cue.text);
  }

  void _onCueChanged() {
    if (!mounted || _controller == null) return;
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;

    if (_lyricsMode) {
      // BUG-757: 消费 force-reveal 一次性旗（snapReaderToAudio 在 followAudio OFF→ON
      // 时置位并 notify）。必须**无条件**消费（哪怕本帧未就绪 / idx 越界也读一次），
      // 否则这枚挂在共享 controller 上的进程级一次性旗会泄漏到之后退回正文的
      // _onCueChanged，被那边 consumeForceReveal 读成过期 true → 凭空多滚一次。
      final bool forceReveal = controller.consumeForceReveal();
      if (_lyricsPageReady) {
        final int sourceIdx = _lyricsCueWindowUsesAllBookCues
            ? controller.allBookCueIdx
            : controller.currentCueIdx;
        // BUG-767: sourceIdx < 0 = 当前 cue 暂不可解析（cue 间隙 / setChapterCues 把
        // _currentCue 瞬时清空后 notify / 尚未匹配）。此时**保位不跳、绝不重载**。
        // 旧码在 `idx < 0` 分支无条件重开歌词页：重载又以 allBookCueIdx(-1) 回退到过期
        // `_lyricsEntryCueIndex`（≈0）生成 currentIndex → 高亮跳回第一句；且重载 onLoadStop
        // 落定那帧 sourceIdx 仍 -1 → 再次重载 → 无限重载 = 进歌词模式一直闪烁且恒高亮
        // 第一句（不是正在听的那句）。守卫在 sourceIdx>=0 才动作，从根上消除这个特殊分支
        // 制造的死循环。
        if (sourceIdx >= 0) {
          final int idx = sourceIdx - _lyricsCueIndexOffset;
          if (idx >= 0 && idx < _lyricsCueList.length) {
            // followAudio OFF → scroll=false：只换当前行高亮、不自动滚（用户可自由滚动
            // 歌词）。forceReveal（切「跟随音频」ON 触发的 snap 回中）也放行滚动。
            final bool scroll = controller.followAudio.value || forceReveal;
            _controller!.evaluateJavascript(
              source: 'if(window.__lyricsSetCue)'
                  'window.__lyricsSetCue($idx, $scroll);'
                  // BUG-757: snap 那一刻 cue 往往没变，__lyricsSetCue 的
                  // `index===_currentIdx` 早退会吞掉这次回中 → 打开跟随画面不动。
                  // forceReveal 下再显式 __lyricsScrollToCue 强制把当前句居中，绕过早退。
                  '${forceReveal ? 'if(window.__lyricsScrollToCue)'
                      'window.__lyricsScrollToCue($idx);' : ''}',
            );
          } else if (_lyricsCueWindowUsesAllBookCues) {
            // cue 真的移出已载窗口（sourceIdx>=0 但落在窗外）→ 重开窗口居中当前 cue。
            // 这是唯一合法的重载：currentIndex 用真实 sourceIdx，不会回退到第一句。
            unawaited(_loadLyricsPage());
          }
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
        // TODO-807 根因：_srtCueChapterMap 的 value 是 CuesToEpub.splitChapters
        // 的「人工切章序号」（≤500cue/≤10min 切），与 _book!.chapters 的真实
        // spine index 零映射。以前把 cueChapter 直接当 chapters index 喂给
        // _navigateToChapter → 跨章时滑到 chapters[cueChapter]，常命中目录/nav
        // 页（日文 EPUB spine 首项常是目录）。必须先把 cue 反查回真实章节
        // index（按 chapterHref，失败再按正文文本）；反查失败一律保位只高亮、
        // 绝不导航、绝不回退到 index 0。
        final int realChapter = _resolveSrtCueChapter(cue);
        final int navTarget = audiobookSrtCrossChapterTarget(
          resolvedChapter: realChapter,
          currentChapter: _currentChapter,
          resolvedIsNav: _book?.isChapterNav(realChapter) ?? false,
        );
        if (cueChapter != null && navTarget >= 0) {
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
            // 导航的是反查到的真实章节 index（navTarget），不是 splitChapters
            // 序号；navTarget 已剔除「反查不到 / 目录页 / 同章」三种保位情况。
            _navigateToChapter(navTarget, progress: progress ?? 0.0);
          } else {
            AudiobookBridge.highlight(_controller!);
          }
          return;
        }
        // splitChapters 分桶变了但反查不到真实章（chapterHref 不匹配、文本
        // 太短、或该 cue 属于一个不作为导航目标的页）→ 不跨章，落到下方统一
        // highlight 收尾（保位只高亮、不归零）。
      }
    }
    final bool forceReveal = controller.consumeForceReveal();
    final bool reveal = forceReveal || controller.shouldRevealCurrentCue;
    // TODO-724：仅当图片暂停开启（imagePauseSec>0）时，cue 推进跨过插图才把视口
    // 滚到插图（配合 Dart 的 triggerImagePause 暂停让用户看见）。imagePauseSec=0
    // 时图片暂停关闭，绝不滚图，否则视口会无预兆跳到不知哪张图（用户报告症状）。
    final bool pauseEnabled = controller.imagePauseSec.value > 0;
    // TODO-825：cue 权威驱动视口跟随时（reveal=true）AudiobookBridge.highlight 会经 JS
    // scrollToTarget 用 behavior:'smooth' 平滑滚动到当前句。这条程序化跟随滚动必须武装 B-3
    // settle 保护窗（与 恢复/缩放/换样式 三条 reanchor commit 同机制，见 eaa151581）：smooth
    // 动画跨多帧落定，落定那帧 WebView 回弹的 scroll 经 _handleReaderScroll 回传 → 若不抑制就
    // 触发 _refreshProgress setState 重绘 + 可能命中 TODO-798 非自愿归零判据被反手二次滚动 =
    // 「停下→被拽回」闪屏。在发起跟随滚动前打点 _reanchorClearedAt，使 readerScrollWithinReanchorSettle
    // 在落定尾沿 250ms 内一律 return 不落库/不复位，从源头消除二次反弹——动画保留，闪烁治住。
    // reveal=false（被动高亮/暂停态）不滚视口，不打点，不影响用户自控滚动落库。
    if (reveal) {
      _reanchorClearedAt = DateTime.now();
    }
    AudiobookBridge.highlight(
      _controller!,
      cue: cue,
      reveal: reveal,
      pauseEnabled: pauseEnabled,
    );
    // TODO-718（真机铁证·2026-06-25）：只有 cue 权威驱动视图时（reveal=播放跟随 / 显式
    // reveal / forceReveal）才用 cue 位置覆盖落库的阅读位置。**被动高亮**——重开 / 暂停态把
    // 当前 cue 高亮上去（reveal=false）——绝不覆盖用户的滚动阅读位置：否则恢复后的位置被
    // 暂停中的音频 cue 拽走（真机：restore=244 被 cue ns=995 覆盖成 440、charOffset 退化成
    // -1，无论阅读位置还是有声书位置每次重开都回到那条固定 cue ≈ 章首）。followAudio OFF +
    // 播放时 reveal 亦为 false（用户自控滚动，不自动跟读）→ 位置跟滚动不跟 cue，符合预期。
    // 播放且跟读期 reveal=true → 仍正常用 cue 落库，不回归 724。
    if (reveal) {
      _syncPositionFromCurrentCue();
    }
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
    // TODO-807（路径 B 守卫）：sasayaki 跨章用 frag.sectionIndex 当真实章 index，
    // 但若该 index 指向 EPUB 目录/nav 页（spine 含目录页时），导航过去就把用户
    // 甩到目录。命中 nav 页则保位不跳（取消跳章守卫、保留当前章），与「反查不到
    // 不跳」语义一致，绝不归零到 index 0。
    if (_book!.isChapterNav(newSection)) {
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
    // TODO-1037：cue 驱动的跨章会一步跳过「独立成章的纯图片页」（无 cue 故从不
    // 被推进看见），图片等待对它彻底失效。跨章落定前先把中间纯图片章逐个导航过去
    // 并停留 imagePauseSec 秒，让用户看见每张整章插图，再继续到目标文本章。
    await _pauseThroughImageOnlyChapters(newSection);
    await _navigateToChapter(newSection, progress: progress ?? 0.0);
  }

  /// TODO-1037：跨章推进若跨过「独立成章的纯图片章」，且图片等待开启
  /// (`imagePauseSec > 0`)，则在落到目标章 [targetSection] 前，按阅读顺序对每个
  /// 中间纯图片章导航过去并停留展示。
  ///
  /// 多个连续图片章逐个停留（先经过先看见，对用户最自然）。每章：
  ///   1. [_navigateToChapterAndWait] 导航并等其载入完成（拿到稳定渲染）；
  ///   2. [AudiobookPlayerController.awaitImageChapterPause] 暂停播放并 await
  ///      imagePauseSec 秒，复用 triggerImagePause 同一套暂停/恢复原语（坑1：进来
  ///      时正在跟随播放，由该方法主动 pause→等→play，不照搬「非播放即早退」）。
  ///
  /// 坑2（锚点重置时序）：每次导航完成时 `_onChapterLoadComplete` 会调
  /// `AudiobookBridge.resetImagePauseAnchor` 把 `__hoshiPrevHighlight` 归零，这对
  /// 本路径无害——纯图片章无 cue、不依赖 DOM 内相邻锚点判定，且到达目标章后锚点
  /// 自然重置，cue 推进干净续上。
  ///
  /// 序列期间用 [_imageChapterPauseInFlight] 防重入，并让控制器在整段序列里持住
  /// [AudiobookPlayerController.holdChapterTransition] 守卫——否则每个中间章载入完成
  /// 的 `notifySectionRestoreCompleted` 会把 `_chapterTransition` 清回 false，下一
  /// tick 可能重入 `onCrossChapter` 乱跳。
  Future<void> _pauseThroughImageOnlyChapters(int targetSection) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null || _book == null || _imageChapterPauseInFlight) {
      return;
    }
    final List<int> imageChapters = imageOnlyChaptersToPauseBetween(
      fromChapter: _currentChapter,
      toChapter: targetSection,
      pauseSec: controller.imagePauseSec.value,
      chapterCount: _book!.chapters.length,
      isImageOnly: _book!.isImageOnlyChapter,
      isNav: _book!.isChapterNav,
    );
    if (imageChapters.isEmpty) return;
    _imageChapterPauseInFlight = true;
    // TODO-1037（重入竞态根因修复）：整段序列期间让控制器持住跨章守卫。每个中间章
    // 载入完成会**同步**调 notifySectionRestoreCompleted——它原本无条件清
    // _chapterTransition 并同步 _updateCurrentCue，此刻音频仍在播放（pause 要等本次
    // 导航 await 返回后才发起）、cue 仍指目标文本章 → 重入 _maybeEmitCrossChapter
    // 一步跳过剩余图片章（f3e4d2e52 症状复现）。置此标志后 notifySectionRestoreCompleted
    // 见序列在途即保持守卫不放、不重算，序列收尾置回 false 由落到目标章的导航正常清。
    controller.setImageChapterPauseActive(true);
    try {
      // TODO-1128：被吸收单图片章与其宿主文本章共享同一虚拟页（图片内联在宿主顶部）。
      // 连续多张被吸收图片会 resolve 到同一宿主——只在该宿主上停留一次，不逐图重载宿主
      // （避免闪烁 + 重复停留）。非吸收图片章 resolve 到自身，行为不变。
      int lastResolved = -1;
      for (final int chapter in imageChapters) {
        if (!mounted || _lyricsMode) break;
        final int resolved = _resolveNavChapter(chapter);
        if (resolved == lastResolved) continue;
        lastResolved = resolved;
        // 中间章载入完成会清掉 _chapterTransition；序列未结束前重新持住，防重入跨章。
        controller.holdChapterTransition();
        final bool loaded = await _navigateToChapterAndWait(chapter);
        if (!mounted || _lyricsMode) break;
        if (!loaded) continue;
        // BUG-898：停留前揭开该纯图片章的防剧透模糊图（此路径无 cue，不经区间揭遮罩
        // 原语 __hoshiRevealBlurredBetween，否则音频停在一张仍模糊的图上）。
        final InAppWebViewController? webCtrl = _controller;
        if (webCtrl != null) {
          await AudiobookBridge.revealAllBlurred(webCtrl);
        }
        await controller.awaitImageChapterPause();
      }
    } finally {
      _imageChapterPauseInFlight = false;
      // 序列收尾：先解除控制器侧的序列守卫，再持住跨章守卫；最终的
      // _navigateToChapter(targetSection) 会再触发一次 notifySectionRestoreCompleted，
      // 此时 _imageChapterPauseActive 已为 false，正常清守卫并落到目标章。
      controller.setImageChapterPauseActive(false);
      controller.holdChapterTransition();
    }
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

  /// BUG-1107（断点 B·幻象字数）：显式跳句（[AudiobookPlayerController.skipToCue]
  /// 漏斗——音量键句子导航 / 快捷键 / 底栏「上一句·下一句」/ 媒体通知按钮全部汇聚
  /// 到那里）落定目标后，把本 session 统计字数水位抬到目标 cue 的绝对字符位置。
  ///
  /// 语义：**音频跳过的段落不算已读**。不抬水位时，跳句后的 WebView 跟随滚动会让
  /// `_refreshProgress` 把「旧位置 → 目标 cue」之间整段正文误计成本次读到的新字数。
  /// 后跳（上一句）目标位置低于水位，[sessionWatermarkAfterRestore] 的只升不降
  /// 语义天然 no-op（重听不重复计也不回退）。
  void _handleExplicitCueJump(AudioCue cue) {
    final int target = _absoluteCharPositionForCue(cue);
    _sessionMaxAbsoluteChars = sessionWatermarkAfterRestore(
      _sessionMaxAbsoluteChars,
      target,
    );
  }

  /// 目标 cue 的绝对字符位置（全书累计口径）。解析不出时返回 0（水位取 max，
  /// 0 恒为 no-op，fail-open 不影响统计）。
  ///
  /// - sasayaki cue：`textFragmentId` 解码出章号 + 章内 normCharStart（与章字数
  ///   同一归一化口径），走 [computeCharWatermark] 的精确锚分支。
  /// - SRT cue：无字符锚，按句号在本章 cue 区间内的比例（与跨章恢复共用的
  ///   [audiobookSrtCrossChapterProgress] 公式）折算成分数口径。
  int _absoluteCharPositionForCue(AudioCue cue) {
    if (_book == null || _chapterCumulativeChars.isEmpty) return 0;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag != null) {
      return computeCharWatermark(
        chapterCumulativeChars: _chapterCumulativeChars,
        chapterCharCounts: _chapterCharCounts,
        chapter: frag.sectionIndex,
        progress: 0.0,
        charOffset: frag.normCharStart,
      );
    }
    final int? srtChapter = _srtCueChapterMap?[cue.sentenceIndex];
    final List<(int, int)>? ranges = _srtChapterRanges;
    if (srtChapter == null ||
        ranges == null ||
        srtChapter < 0 ||
        srtChapter >= ranges.length) {
      return 0;
    }
    final (int first, int last) = ranges[srtChapter];
    final double progress = audiobookSrtCrossChapterProgress(
          sentenceIndex: cue.sentenceIndex,
          first: first,
          last: last,
        ) ??
        0.0;
    return computeCharWatermark(
      chapterCumulativeChars: _chapterCumulativeChars,
      chapterCharCounts: _chapterCharCounts,
      chapter: srtChapter,
      progress: progress,
      charOffset: -1,
    );
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
    final ({int offset, int length})? span = _miningSpanRange();
    return _sentenceAudioRangeFor(
      sentence: sentence,
      cue: _lookupCue,
      normOffset: span?.offset,
      normLength: span?.length,
    );
  }

  /// 归一化选区 span 的单一真相源（TODO-1278）：优先句级 span（[_cachedSentenceRange]），
  /// 句级缺失时回退到词/选区级 span（[_cachedSelectionRange]）。
  ///
  /// 片段导出 / Anki 句子音频的位置锚点**必须**和收藏、制卡历史
  /// （[_checkFavoriteStatus] / [_recordMinedSentence] / lookup.part / chrome.part）
  /// 用同一套回退——否则句级 span 偶发缺失（拖选跨 block / ruby / 图片相邻节点未进归一化
  /// 索引 → JS `sentenceNormalizedOffset` 为 null，见 reader_selection_scripts）时，导出
  /// 侧独自丢掉位置锚点：[miningSentenceAudioRange] 拿不到 sectionIndex+offset+length，
  /// 对 gap word（`_lookupCue==null`、currentSentence 为空）解析出 null 区间，被
  /// [classifyAudiobookClipSelection] 归成 `unsupportedRange`，弹出误导的「跨章或跨音频
  /// 文件」toast——而选区其实同章、Anki 收藏路径能正常定位。回退到选区级 span 后，位置
  /// 匹配重新生效，同章选区正常进入导出管线。
  ({int offset, int length})? _miningSpanRange() {
    final ({int offset, int length})? sentenceRange = _cachedSentenceRange;
    if (sentenceRange != null) {
      return sentenceRange;
    }
    final ({int offset, int length, String text})? selectionRange =
        _cachedSelectionRange;
    if (selectionRange != null) {
      return (offset: selectionRange.offset, length: selectionRange.length);
    }
    return null;
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

  /// TODO-945 M1：有声书查词弹窗「导出片段视频」入口。**M1 不做任何 ffmpeg / 视频
  /// 合成**——只把当前查词选区扩成整句 cue 区间（复用 [_currentSentenceAudioRange]），
  /// 用纯函数 [classifyAudiobookClipSelection] 判定四类边界（空选区 / 纯外字 / 跨章 /
  /// 跨音频文件），逐类打日志 + 安全兜底（toast，不崩），可导出时打出
  /// {文本, startMs, endMs, audioFileIndex, 文件路径} 供 M2 起步。
  ///
  /// 边界与数据流事实（实测，见 audiobook_clip_export_test.dart）：
  /// - 纯外字选区：JS 端选区文本剔除 gaiji 图 → [_cachedSelectionRange] 文本为空 →
  ///   走 emptySelection 分支（与「无选区」同一兜底）。
  /// - 跨章 / 跨音频文件：[_sentenceAudioRangeFor] 天生只返回**单个** [AudioPlaybackRange]
  ///   （单 audioFileIndex）；跨文件时只会落在它命中的那一段或返回 null，永不拼跨文件 →
  ///   null / 越界 → unsupportedRange 兜底。D-RANGE 限单 cue/单文件即由此事实兜底。
  void _exportAudiobookClip() {
    final String selectedText = _cachedSelectionRange?.text ??
        appModel.currentMediaSource?.currentSentence.text ??
        '';
    final AudiobookPlayerController? ctrl = _audiobookController;
    final int audioFileCount = ctrl?.audioFiles.length ?? 0;
    // BUG-1243：多句拖选必须先按「真实选区 span」建立动态计划，再决定最终裁剪范围。
    // 旧顺序先用 currentSentence 的单句 range 做分类，随后才建多句计划，导致最终传给
    // ffmpeg 的仍是第一句窗口；动态计划又优先拿 cachedSentenceRange，覆盖了跨句选区
    // span，因而退化成「只有第一句声音 + 整段静态高亮」。
    _AudiobookClipDynamicPlan? dynamicPlan = _buildAudiobookClipPlan(
      audioFileCount: audioFileCount,
    );
    final AudioPlaybackRange? sentenceRange = dynamicPlan == null
        ? _currentSentenceAudioRange()
        : AudioPlaybackRange(
            audioFileIndex: dynamicPlan.audioFileIndex,
            startMs: dynamicPlan.globalStartMs,
            endMs: dynamicPlan.globalEndMs,
          );

    final AudiobookClipBoundaryResult result = classifyAudiobookClipSelection(
      selectedText: selectedText,
      audioFileCount: audioFileCount,
      sentenceRange: sentenceRange,
    );

    switch (result.kind) {
      case AudiobookClipBoundaryKind.emptySelection:
        debugPrint(
          '[ReaderHibiki] export-clip M1: empty/gaiji-only selection — '
          'no renderable text (selectedText.isEmpty).',
        );
        // TODO-1005 / BUG-472：此前只 debugPrint，in-app 日志页空白。补 ErrorLogService
        // 让「ffmpeg 还没跑就失败」也落进可查日志。
        ErrorLogService.instance.log(
          'ReaderHibiki.exportClip.emptySelection',
          'empty/gaiji-only selection (no renderable text); '
              'audioFileCount=$audioFileCount',
          StackTrace.current,
        );
        HibikiToast.show(msg: t.audiobook_export_clip_no_text);
        return;
      case AudiobookClipBoundaryKind.noAudio:
        debugPrint(
          '[ReaderHibiki] export-clip M1: no audio files for this book '
          '(audioFileCount=$audioFileCount).',
        );
        // TODO-1005 / BUG-472：此前只 debugPrint，in-app 日志页空白。补 ErrorLogService。
        ErrorLogService.instance.log(
          'ReaderHibiki.exportClip.noAudio',
          'no audio files for this book (audioFileCount=$audioFileCount); '
              'selectedText="${selectedText.trim()}"',
          StackTrace.current,
        );
        HibikiToast.show(msg: t.audiobook_export_clip_no_selection);
        return;
      case AudiobookClipBoundaryKind.unsupportedRange:
        debugPrint(
          '[ReaderHibiki] export-clip M1: no single-file cue range '
          '(cross-chapter / cross-file / gap). sentenceRange='
          '${sentenceRange == null ? 'null' : 'file=${sentenceRange.audioFileIndex} '
              '${sentenceRange.startMs}->${sentenceRange.endMs}ms'}, '
          'audioFileCount=$audioFileCount.',
        );
        ErrorLogService.instance.log(
          'ReaderHibiki.exportClip.unsupportedRange',
          'selection has no single-file cue range (cross-chapter/cross-file)',
          StackTrace.current,
        );
        HibikiToast.show(msg: t.audiobook_export_clip_unsupported_range);
        return;
      case AudiobookClipBoundaryKind.exportable:
        final AudioPlaybackRange range = result.range!;
        final List<File> audioFiles = ctrl?.audioFiles ?? const <File>[];
        final File? inputFile = range.audioFileIndex < audioFiles.length
            ? audioFiles[range.audioFileIndex]
            : null;
        if (inputFile == null) {
          // 越界已被 classify 拦在 unsupportedRange，这里只是 null-safety 兜底。
          // TODO-1005 / BUG-472：此前只 toast、零日志，in-app 日志页空白。补
          // ErrorLogService（沿用同款 input/startMs/endMs 字段）让该兜底也可查。
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.inputFileNull',
            'exportable range has no input audio file '
                '(audioFileIndex=${range.audioFileIndex}, '
                'audioFileCount=${audioFiles.length}, '
                'startMs=${range.startMs}, endMs=${range.endMs}, '
                'durationMs=${range.endMs - range.startMs}, '
                'text="${selectedText.trim()}")',
            StackTrace.current,
          );
          HibikiToast.show(msg: t.audiobook_export_clip_unsupported_range);
          return;
        }
        // D4 时长安全上限 120s：单句天然短，仅兜底超长选区，避免巨型编码。超限走
        // unsupportedRange 文案（选区不可导出）而非崩溃。
        if (range.endMs - range.startMs > _kAudiobookClipMaxDurationMs) {
          debugPrint(
            '[ReaderHibiki] export-clip: range too long '
            '(${range.endMs - range.startMs}ms > '
            '${_kAudiobookClipMaxDurationMs}ms) — refusing export.',
          );
          // TODO-1005 / BUG-472：此前只 debugPrint + toast、in-app 日志页空白。补
          // ErrorLogService（沿用同款 input/startMs/endMs/durationMs 字段）。
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.rangeTooLong',
            'selection range too long, refusing export '
                '(durationMs=${range.endMs - range.startMs} > '
                'maxMs=$_kAudiobookClipMaxDurationMs, '
                'startMs=${range.startMs}, endMs=${range.endMs}, '
                'input=${inputFile.path}, text="${selectedText.trim()}")',
            StackTrace.current,
          );
          HibikiToast.show(msg: t.audiobook_export_clip_unsupported_range);
          return;
        }
        // M2-M5：裁音频 → 渲文本图 → mjpeg/.mov 合成 → 分享/存盘。异步推进，先给一个
        // 反馈 toast；失败在管线内各自 toast。防重入：导出进行中再点直接忽略。
        if (_audiobookClipExporting) return;
        // TODO-1115：尝试多句连读 + 逐句高亮跟随。把选区映射到有序 cue 列表；≥1 句即走
        // 动态路径（单句时自然退化为单句动态，仍可回退单句静态）。跨章/跨文件 span 为空
        // → dynamicPlan 为 null → 直接走原单句静态路径（never break userspace）。
        // TODO-1115 review M1：根因护栏。音频裁剪走静态 `range`（由 range.audioFileIndex
        // 选 inputFile），但起止 ms 走 dynamicPlan.globalStartMs/globalEndMs（由 span 独立
        // 解析出的 dynamicPlan.audioFileIndex 定的坐标系）。二者理论可分歧（静态走
        // `_expandAroundCue`/`_cueRange` 兜底，动态走 `_collectSpanCues` 优先序）；一旦
        // dynamicPlan.audioFileIndex != range.audioFileIndex，就会拿 A 文件的 ms 偏移去裁
        // B 文件 → 错音频 + 错高亮。此处不用 assert（release 会被剥离），用运行时判据：
        // 分歧则放弃动态、令 dynamicPlan=null，回退单句静态（宁可回退不出错产物）。
        if (dynamicPlan != null &&
            dynamicPlan.audioFileIndex != range.audioFileIndex) {
          debugPrint(
            '[ReaderHibiki] export-clip: dynamic/static audioFileIndex '
            'divergence (dynamic=${dynamicPlan.audioFileIndex} '
            'static=${range.audioFileIndex}) — falling back to single-cue '
            'static to avoid cutting the wrong audio file.',
          );
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.audioFileIndexDivergence',
            'dynamic audioFileIndex=${dynamicPlan.audioFileIndex} '
                '!= static range.audioFileIndex=${range.audioFileIndex}; '
                'dropping dynamic plan, falling back to single-cue static '
                '(dynamicCues=${dynamicPlan.cueSpans.length})',
            StackTrace.current,
          );
          dynamicPlan = null;
        }
        debugPrint(
          '[ReaderHibiki] export-clip start: text="${selectedText.trim()}" '
          'audioFileIndex=${range.audioFileIndex} '
          'startMs=${range.startMs} endMs=${range.endMs} '
          'durationMs=${range.endMs - range.startMs} '
          'file=${inputFile.path} '
          'dynamicCues=${dynamicPlan?.cueSpans.length ?? 0}',
        );
        unawaited(_runAudiobookClipPipeline(
          text: selectedText.trim(),
          inputFile: inputFile,
          startMs: range.startMs,
          endMs: range.endMs,
          dynamicPlan: dynamicPlan,
        ));
        return;
    }
  }

  /// TODO-1115：把当前选区映射成「多句连读 + 逐句高亮」动态导出计划。返回 null 表示无法
  /// 走动态路径（span 为空 / 跨文件 / 分类不可导出），调用方回退单句静态。
  ///
  /// 单一真相源：[globalRange] 用 [clipExportGlobalRange]（首句 head-padded ..
  /// 末句尾 padding 放宽到 [kClipExportTailPadMs]，中间句连续不被 tailCap 切），供音频
  /// 裁剪与帧计划共用，避免二者窗口漂移。
  _AudiobookClipDynamicPlan? _buildAudiobookClipPlan({
    required int audioFileCount,
  }) {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) return null;
    final ({int offset, int length, String text})? selection =
        _cachedSelectionRange;
    // BUG-1243：导出入口的主锚是用户真实选区；只有没有原生选区（普通点词导出）时
    // 才回退 currentSentence。不能复用 _miningSpanRange 的「句级优先」规则——那是
    // 单句制卡语义，会把跨多句 selection 收窄回当前句。
    final ({int offset, int length})? fallbackRange = _miningSpanRange();
    final AudiobookClipSelectionSpan resolvedSelection =
        resolveAudiobookClipSelectionSpan(
      selectedText: selection?.text,
      selectedOffset: selection?.offset,
      selectedLength: selection?.length,
      fallbackText: appModel.currentMediaSource?.currentSentence.text ?? '',
      fallbackOffset: fallbackRange?.offset,
      fallbackLength: fallbackRange?.length,
    );
    final String sentence = resolvedSelection.text;
    // TODO-1115 review M2：分类文本与静态路径（[_exportAudiobookClip] 的 selectedText）
    // 同源——`_cachedSelectionRange?.text ?? currentSentence.text`。此前动态侧只用
    // currentSentence.text，与静态侧 emptySelection 判据不同调（纯外字/无选区时可能一条
    // 判空、另一条判非空）。归一到同一真相源，消除两条路径的边界分歧。
    final String classifyText = resolvedSelection.text;
    final List<AudioCue> allCues = _sentenceAudioMiningCues(_lookupCue);
    final List<AudioCue> span = miningSentenceCueSpan(
      cues: allCues,
      cue: _lookupCue,
      sentence: sentence,
      sectionIndex: _lookupSectionIndex,
      sentenceNormCharOffset: resolvedSelection.offset,
      sentenceNormCharLength: resolvedSelection.length,
    );
    if (span.isEmpty) return null;

    final AudioPlaybackRange? globalRange = clipExportGlobalRange(
      span: span,
      allCues: allCues,
      delayMs: ctrl.delayMs.value,
    );
    // TODO-1147（用户回访「高亮迟钝」第二根因·时基不一致）：globalRange 已按 A/V
    // 偏移平移 +delayMs（cue 在音频里真实出现于 startMs+delayMs），帧计划拿它当
    // 时间轴；cue 起止必须同步平移，否则逐句高亮整体偏移 delayMs。
    final List<AudiobookClipCueSpan> cueSpans = clipCueSpansWithDelay(
      span: span,
      delayMs: ctrl.delayMs.value,
    );

    final AudiobookClipMultiCueResult result = classifyAudiobookClipMultiCue(
      selectedText: classifyText,
      audioFileCount: audioFileCount,
      globalRange: globalRange,
      cueSpans: cueSpans,
      maxDurationMs: _kAudiobookClipMaxDurationMs,
    );
    if (!result.isExportable) return null;

    // Aligned cues are subtitle data, not necessarily the exact EPUB text the
    // user selected. Mismatches must use the static exact-selection card.
    if (!audiobookClipCueTextMatchesSelection(
      selectedText: classifyText,
      cueSpans: result.cueSpans,
    )) {
      return null;
    }

    // TODO-1127：把选区里抽取到的插图按归一化文档位置分配到各 cue 段之后。cue 的
    // normCharStart 从 sasayaki 编码的 textFragmentId 解出（解不出的 cue 传 null，不作
    // 归属锚点）；`span` 与 result.cueSpans 同序等长（classify 只包一层不可变拷贝），故
    // 下标对齐。选区无夹图时 _cachedSelectionImages 为空 → 分配结果全空列表，零差异。
    final List<int?> cueNormStarts = span.map((AudioCue c) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(c.textFragmentId);
      return (frag != null && frag.normCharStart >= 0)
          ? frag.normCharStart
          : null;
    }).toList(growable: false);
    final List<List<Uint8List>> imagesByCueIndex = assignClipImagesToCues(
      cueNormStarts: cueNormStarts,
      images: _cachedSelectionImages,
    );
    return _AudiobookClipDynamicPlan(
      audioFileIndex: result.audioFileIndex,
      globalStartMs: result.globalStartMs,
      globalEndMs: result.globalEndMs,
      cueSpans: result.cueSpans,
      imagesByCueIndex: imagesByCueIndex,
    );
  }

  /// D4：片段视频时长安全上限（120s）。单句天然短，仅兜底超长选区。
  static const int _kAudiobookClipMaxDurationMs = 120 * 1000;

  /// TODO-945 M2-M5：把已验证的 {文本, 音频文件, 起止 ms} 走完整管线——裁音频片段
  /// （M2，复用 [extractAudioSegmentViaFfmpeg]）→ 文本离屏渲 PNG（M3，复用
  /// [renderAudiobookClipTextToPng]）→ 图+音频合成 mjpeg/.mov（M4，复用
  /// [synthAudiobookClipVideoViaFfmpeg]）→ 分享/存盘（M5，桌面 FilePicker / 移动
  /// Share）。任一步失败各自 toast，绝不崩。临时文件落 systemTemp，桌面导出后清理。
  Future<void> _runAudiobookClipPipeline({
    required String text,
    required File inputFile,
    required int startMs,
    required int endMs,
    _AudiobookClipDynamicPlan? dynamicPlan,
  }) async {
    _audiobookClipExporting = true;
    HibikiToast.show(msg: t.audiobook_export_clip_in_progress);

    // 渲图前先抓阅读主题色 + 写排方向 + 字号（在 await 前读，避免跨 await 用 context）。
    final ReaderThemeColors themeColors = _readerThemeColors;
    final bool vertical =
        _settings?.writingMode.startsWith('vertical') ?? false;
    final double baseFontSize = _settings?.fontSize ?? 22;
    final double lineHeight = _settings?.lineHeight ?? 1.65;
    final OverlayState? overlay = Overlay.maybeOf(context);

    File? audioClip;
    File? imageFile;
    File? videoFile;
    Directory? framesDir;
    final bool isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    // BUG-809：桌面走 H.264 + .mp4（ffmpeg-min 已编入 libx264+mp4，带帧间压缩把
    // 30 秒片段从 mjpeg 的 ~200MB 压到几 MB，且 .mp4 通用可直接播放/分享）；移动端
    // 自编 ffmpeg-kit min 无 libx264，保持 mjpeg + .mov（帧内 JPEG，两端都能编）。
    final bool useH264 = isDesktop;
    final String videoExt = useH264 ? 'mp4' : 'mov';
    try {
      final Directory tmpDir = await getTemporaryDirectory();
      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String base = p.join(tmpDir.path, 'audiobook_clip_$stamp');

      // M2：裁完整音频片段（AAC/ADTS）。动态多句时裁**整段** [globalStart, globalEnd]
      // （单一真相源，含 head/放宽的 tail padding）；否则裁单句 range。
      // 输出 .aac（adts 容器）而非 .m4a：捆绑的精简 ffmpeg（--disable-everything）
      // 只编入 adts/gif/mjpeg/image2 muxer，没有 ipod/mov/m4a muxer，写 .m4a 会让
      // ffmpeg 自动选不存在的 mov muxer → exit -22（EINVAL）。adts 是 ffmpeg-min
      // build 契约里句子音频的指定容器（docs/specs/2026-06-07-ffmpeg-min-build-pipeline.md）。
      final int clipStartMs = dynamicPlan?.globalStartMs ?? startMs;
      final int clipEndMs = dynamicPlan?.globalEndMs ?? endMs;
      final String? clipPath = await extractAudioSegmentViaFfmpeg(
        inputPath: inputFile.path,
        startMs: clipStartMs,
        endMs: clipEndMs,
        outputPath: '$base.aac',
      );
      if (clipPath == null) {
        // TODO-1005 / BUG-472：M2 裁音频返回 null 此前只弹 toast、零日志（底层早返回
        // 也曾静默）。在管线层补一条带完整上下文的 ErrorLogService，连同底层日志一起
        // 让用户/排障能看到「在哪一步、裁哪段、哪个文件」失败。
        ErrorLogService.instance.log(
          'ReaderHibiki.exportClip.audioClipFailed',
          'extractAudioSegmentViaFfmpeg returned null '
              '(startMs=$clipStartMs, endMs=$clipEndMs, '
              'durationMs=${clipEndMs - clipStartMs}, input=${inputFile.path})',
          StackTrace.current,
        );
        if (mounted) {
          HibikiToast.show(msg: t.audiobook_export_clip_failed);
        }
        return;
      }
      audioClip = File(clipPath);

      // M3：文本离屏渲 PNG（沿用阅读主题 / 写排方向 / 字号）。
      if (overlay == null) {
        // TODO-1005 / BUG-472：离屏渲染缺 Overlay 此前只 toast、零日志。
        ErrorLogService.instance.log(
          'ReaderHibiki.exportClip.noOverlay',
          'no Overlay available for offscreen text render '
              '(text="$text")',
          StackTrace.current,
        );
        if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_failed);
        return;
      }
      final AudiobookClipTextLayout layout = computeClipTextLayout(
        textLength: text.runes.length,
        baseFontSize: baseFontSize,
        vertical: vertical,
        lineHeight: lineHeight,
        background: themeColors.bg,
        foreground: themeColors.fg,
        // TODO-1013：逐句高亮跟随色 = 有声书当前句跟读高亮（sasayaki），与阅读器正文
        // `::highlight(hoshi-sasayaki)` 同一真相源（ReaderThemeColors.sasayaki），
        // 导出卡片把它当整句背景衬底，复刻「逐句高亮跟随」样式。
        highlight: themeColors.sasayaki,
      );

      videoFile = File('$base.$videoExt');

      // M3/M4：优先动态逐帧高亮跟随（多句序列帧 → image2 合成）；任一步失败回退单句静态。
      bool dynamicOk = false;
      if (dynamicPlan != null) {
        framesDir = Directory('${base}_frames');
        dynamicOk = await _synthDynamicClipVideo(
          plan: dynamicPlan,
          overlay: overlay,
          layout: layout,
          framesDir: framesDir,
          audioClip: audioClip,
          videoFile: videoFile,
          isDesktop: isDesktop,
        );
        if (!dynamicOk) {
          // 回退：清掉可能半成的序列帧目录，走单句静态。
          await _deleteClipFramesDir(framesDir);
          framesDir = null;
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.dynamicFallback',
            'dynamic multi-cue clip synth failed, falling back to static '
                '(cues=${dynamicPlan.cueSpans.length})',
            StackTrace.current,
          );
        }
      }

      if (!dynamicOk) {
        // 单句静态回退：整段文本单图 + `-loop 1` 单图合成（原有稳定路径）。
        // TODO-1147 option A: vertical uses the true-vertical offscreen WebView
        // render; horizontal keeps the Flutter raster path. If the WebView path
        // returns null (platform without WebView / render failure), gracefully
        // fall back to Flutter raster (readable horizontal) rather than hard-fail.
        Uint8List? pngBytes;
        if (layout.vertical) {
          pngBytes = await renderAudiobookClipTextViaWebView(
            text: text,
            layout: layout,
          );
        }
        pngBytes ??= await renderAudiobookClipTextToPng(
          overlay: overlay,
          text: text,
          layout: layout,
        );
        if (pngBytes == null) {
          // TODO-1005 / BUG-472：文本图渲染失败此前只 toast、零日志。
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.textRenderFailed',
            'renderAudiobookClipTextToPng returned null (text="$text")',
            StackTrace.current,
          );
          if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_failed);
          return;
        }
        // BUG-543：移动端 ffmpeg-kit min 变体无 png decoder（有 mjpeg decoder），
        // 桌面 ffmpeg-min 同样含 mjpeg decoder。Flutter 只能直出 png/rawRgba，故把
        // 渲出的 png 帧在 Dart 层重编码为 jpeg，让两端 ffmpeg 都走 mjpeg 解码，
        // 绕开缺失的 png decoder（此前移动端合成 exit 1 / "unspecified size"）。
        // TODO-1167：静态回退单帧编码同样卸到后台 isolate（UI 线程不被 2MP 解码/编码阻塞）。
        final Uint8List? jpgBytes =
            await encodeClipTextFrameAsJpgAsync(pngBytes);
        if (jpgBytes == null) {
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.jpgEncodeFailed',
            'encodeClipTextFrameAsJpgAsync returned null '
                '(pngLen=${pngBytes.length}, text="$text")',
            StackTrace.current,
          );
          if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_failed);
          return;
        }
        imageFile = File('$base.jpg');
        await imageFile.writeAsBytes(jpgBytes);

        final AudiobookClipSynthResult synth =
            await synthAudiobookClipVideoViaFfmpeg(
          imagePath: imageFile.path,
          audioPath: audioClip.path,
          outputPath: videoFile.path,
          width: layout.width,
          height: layout.height,
          // TODO-1147：桌面去色度下采样（yuvj444p）保留彩色文字边缘精度；移动端
          // ffmpeg-kit min 的 mjpeg encoder 收 444 需真机验合成不 exit，故保守 420
          // （仍靠 1080×1920 分辨率提升消模糊，不触碰移动合成 exit1 风险）。
          // BUG-809：桌面 h264/.mp4（pixFmt 被 yuv420p 覆盖），移动 mjpeg/.mov。
          pixFmt: isDesktop ? 'yuvj444p' : 'yuvj420p',
          h264: useH264,
        );
        if (!synth.isSuccess || synth.outputPath == null) {
          debugPrint(
            '[ReaderHibiki] export-clip synth failed: '
            '${synth.failure} ${synth.detail ?? ''}',
          );
          // TODO-1005 / BUG-472：synth 内部已记 ffmpeg 真因；这里补一条管线级摘要，
          // 让失败原因（inputMissing / ffmpegUnavailable / ffmpegFailed / outputMissing）
          // 与上下文一起出现在 in-app 日志页。
          ErrorLogService.instance.log(
            'ReaderHibiki.exportClip.synthFailed',
            'video synth failed: ${synth.failure} ${synth.detail ?? ''}',
            StackTrace.current,
          );
          if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_failed);
          return;
        }
      }
      final String outPath = videoFile.path;

      // M5：分享/存盘。桌面（含 Linux）走 FilePicker 存盘；移动走系统 Share。
      if (isDesktop) {
        final String? savePath = await FilePicker.platform.saveFile(
          dialogTitle: t.audiobook_export_clip,
          // BUG-809：桌面导出 .mp4（h264，通用可直接播放）。
          fileName: 'audiobook_clip_$stamp.$videoExt',
          type: FileType.custom,
          allowedExtensions: <String>[videoExt],
        );
        if (savePath != null) {
          await File(outPath).copy(savePath);
          if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_saved);
        }
      } else {
        final List<XFile> sharedFiles = audiobookClipMobileShareAttachments(
          videoPath: outPath,
          useH264: useH264,
        )
            .map(
              (AudiobookClipShareAttachment attachment) => XFile(
                attachment.path,
                mimeType: attachment.mimeType,
              ),
            )
            .toList(growable: false);
        // BUG-1243：ffmpeg 合成参数已显式 `-map 0:v:0 -map 1:a:0`，AAC 在 MOV 内。
        // 旧兼容兜底又把临时 .aac 当第二个附件分享，系统分享面板把它显示成一个多余
        // “字幕/音频文件”。产物契约收敛为单个带声视频，不再泄漏中间文件。
        await HibikiShare.shareFiles(sharedFiles, subject: text);
        if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_saved);
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.exportClip.pipeline', e, stack);
      debugPrint('[ReaderHibiki] export-clip pipeline error: $e');
      if (mounted) HibikiToast.show(msg: t.audiobook_export_clip_failed);
    } finally {
      _audiobookClipExporting = false;
      // 清理临时中间文件。桌面端最终视频已 copy 到用户选定路径，可一并清理；移动端
      // 系统 Share 异步读取 outPath，保留视频文件供其读取，仅清理音频/图中间产物。
      await _deleteClipTempFile(audioClip);
      await _deleteClipTempFile(imageFile);
      // TODO-1115：动态路径的 N 帧 JPEG 序列帧目录一并清理（无论成功/回退/桌面/移动）。
      await _deleteClipFramesDir(framesDir);
      if (isDesktop) await _deleteClipTempFile(videoFile);
    }
  }

  /// TODO-1115 动态逐帧高亮：按 [plan] 的 cue 列表批量渲「整段文本 + 逐句高亮」序列帧
  /// 到 [framesDir]，再用 image2 序列帧 + 完整音频合成 [videoFile]。全程成功返回 true；
  /// 任一步失败返回 false（调用方回退单句静态）。
  ///
  /// 每句只渲一次 PNG（去重），后台 isolate 编码为 JPEG 母帧落盘（encodeClipTextFrameAsJpgAsync，
  /// BUG-543 + TODO-1167），再按帧计划里各 [ClipFrameSpec.frameCount] 从母帧复制成连续帧
  /// 编号，喂给 image2 demuxer（`frame_%04d.jpg`），从而复刻「逐句高亮跟随」时间轴。
  Future<bool> _synthDynamicClipVideo({
    required _AudiobookClipDynamicPlan plan,
    required OverlayState overlay,
    required AudiobookClipTextLayout layout,
    required Directory framesDir,
    required File audioClip,
    required File videoFile,
    required bool isDesktop,
  }) async {
    // BUG-713（用户回访「导出片段高亮进度慢了」根因·帧量化残差）：逐句高亮切换被帧
    // 率量化到 Δ=1000/fps 的网格上。clipFramePlan 用帧中心（round）采样后，句起点 S 的
    // 高亮在视频时刻 round(S/Δ)·Δ 出现，与锁定音频对称误差 ≤Δ/2——12fps 下 Δ≈83ms、
    // 约一半 cue 的高亮晚最多 42ms（>人眼音画同步阈值 ≈45ms 的边缘，主观「滞后」）。
    // TODO-1147(floor→早)/TODO-1256(round→对称) 三次改采样都只在 ±Δ 里挪，没动 Δ 本身。
    // 真正的杠杆是 Δ=1000/fps：母帧按去重的 highlightCueIndex 逐句只渲一次（渲染开销
    // = O(不同句数)，与 fps 无关，见下方 distinctIndices），提 fps 只多廉价的 JPEG 母帧
    // 复制 + ffmpeg mjpeg 帧，不增内存（TODO-1167 流式，任一时刻只驻一帧）。24fps →
    // Δ≈41.7ms → 最大滞后 ≤20.8ms，两个方向都降到不可感知，从根上消除来回震荡。
    const int fps = 24;
    // 帧计划：每帧此刻高亮哪一句（相邻同句合并计数）。
    final List<AudioCue> planCues = plan.cueSpans
        .map((AudiobookClipCueSpan s) => AudioCue()
          ..bookKey = ''
          ..chapterHref = ''
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = s.text
          ..startMs = s.startMs
          ..endMs = s.endMs
          ..audioFileIndex = plan.audioFileIndex)
        .toList(growable: false);
    final List<ClipFrameSpec> frames = clipFramePlan(
      cues: planCues,
      globalStartMs: plan.globalStartMs,
      globalEndMs: plan.globalEndMs,
      fps: fps,
    );
    if (frames.isEmpty) return false;

    // 去重要渲的高亮下标（每句只渲一次），再批量离屏渲 PNG。TODO-1127：把该句后夹带的
    // 插图（plan.imagesByCueIndex[i]）一并挂进 segment，渲染层会渲在该句文本之下。
    final List<AudiobookClipTextSegment> segments = <AudiobookClipTextSegment>[
      for (int i = 0; i < plan.cueSpans.length; i++)
        AudiobookClipTextSegment(
          text: plan.cueSpans[i].text,
          images: i < plan.imagesByCueIndex.length
              ? plan.imagesByCueIndex[i]
              : const <Uint8List>[],
        ),
    ];
    final List<int> distinctIndices = <int>[];
    for (final ClipFrameSpec spec in frames) {
      if (!distinctIndices.contains(spec.highlightCueIndex)) {
        distinctIndices.add(spec.highlightCueIndex);
      }
    }
    // TODO-1167 流式渲染（安卓 ANR/OOM 根因修复）：原实现先把**全部** N 帧 1080×1920
    // PNG 攒进 pngs 列表（竖排每帧还叠 8.3MB native 位图）→ native OOM，再在 UI isolate
    // 同步无 await 逐帧 encodeClipTextFrameAsJpg（2MP 解码+编码）→ 冻死主线程 ANR。
    // 改为逐帧回调：渲一帧 → 后台 isolate 编码 JPEG → 立刻落盘为「母帧」→ 释放该帧
    // PNG/JPEG，内存里任一时刻只驻留一帧。母帧按去重的 highlightCueIndex 命名（image2
    // 只认 frame_%04d.jpg，master_* 不会被序列 demuxer 命中），帧计划展开时再从母帧复制
    // 成连续编号 frame_%04d.jpg，复刻「逐句高亮跟随」时间轴。横排/竖排同一回调路径同治。
    //
    // BUG-543：两端 ffmpeg 都无 png decoder 但有 mjpeg decoder，故母帧统一为 JPEG
    // （encodeClipTextFrameAsJpgAsync），下游 image2 序列帧契约不变。
    await framesDir.create(recursive: true);
    final Map<int, String> masterJpgPathByIndex = <int, String>{};
    bool frameFailed = false;
    Future<bool> onFrame(int highlightIndex, Uint8List? png) async {
      if (png == null) {
        frameFailed = true;
        return false; // 任一句渲染失败 → 停止渲染，回退单句静态。
      }
      final Uint8List? jpg = await encodeClipTextFrameAsJpgAsync(png);
      if (jpg == null) {
        frameFailed = true;
        return false; // 帧重编码失败 → 回退单句静态。
      }
      final String masterPath =
          p.join(framesDir.path, 'master_$highlightIndex.jpg');
      await File(masterPath).writeAsBytes(jpg);
      masterJpgPathByIndex[highlightIndex] = masterPath;
      return true;
    }

    // TODO-1147 option A: vertical renders true-vertical frames via offscreen
    // WebView; horizontal keeps the Flutter raster frames (never break). Any null
    // frame triggers the static fallback via onFrame returning false.
    if (layout.vertical) {
      await renderAudiobookClipFramesViaWebView(
        segments: segments,
        layout: layout,
        highlightIndices: distinctIndices,
        onFrame: onFrame,
      );
    } else {
      await renderAudiobookClipFrames(
        overlay: overlay,
        segments: segments,
        layout: layout,
        highlightIndices: distinctIndices,
        onFrame: onFrame,
      );
    }
    if (frameFailed) return false;

    // 落盘序列帧：按帧计划从母帧复制成连续编号 frame_0000.jpg, frame_0001.jpg ...
    int frameNo = 0;
    for (final ClipFrameSpec spec in frames) {
      final String? masterPath = masterJpgPathByIndex[spec.highlightCueIndex];
      if (masterPath == null) return false;
      final File master = File(masterPath);
      for (int i = 0; i < spec.frameCount; i++) {
        final String name = 'frame_${frameNo.toString().padLeft(4, '0')}.jpg';
        await master.copy(p.join(framesDir.path, name));
        frameNo += 1;
      }
    }
    if (frameNo == 0) return false;

    // image2 序列帧 + 完整音频 → mjpeg/.mov。
    final AudiobookClipSynthResult synth =
        await synthAudiobookClipFrameSeqVideoViaFfmpeg(
      framesDir: framesDir.path,
      audioPath: audioClip.path,
      outputPath: videoFile.path,
      width: layout.width,
      height: layout.height,
      fps: fps,
      // TODO-1147：同单图静态路径——桌面 444 / 移动保守 420（见上）。
      // BUG-809：桌面 h264（帧间压缩把逐句高亮的重复帧压到近零）/ 移动 mjpeg。
      pixFmt: isDesktop ? 'yuvj444p' : 'yuvj420p',
      h264: isDesktop,
    );
    if (!synth.isSuccess || synth.outputPath == null) {
      debugPrint(
        '[ReaderHibiki] export-clip dynamic synth failed: '
        '${synth.failure} ${synth.detail ?? ''}',
      );
      ErrorLogService.instance.log(
        'ReaderHibiki.exportClip.dynamicSynthFailed',
        'dynamic seq video synth failed: ${synth.failure} '
            '${synth.detail ?? ''} (frames=$frameNo)',
        StackTrace.current,
      );
      return false;
    }
    return true;
  }

  Future<void> _deleteClipTempFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _deleteClipFramesDir(Directory? dir) async {
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
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
      // TODO-1032：复制导入 + 改写 SrtBook.audioPaths（清 audioRoot）的核心写入逻辑
      // 已下沉到 SrtBookRepository.replaceAudio，三入口（书架重新定位/书架导入音频/
      // 阅读器内导入）共用同一写入路径，避免 SRT 书音频被误写进 Audiobooks 表。
      await repo.replaceAudio(uid: _srtBookUid!, pickedPaths: newPaths);

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
    final Set<String> audioExtensions = AudiobookStorage.audioExtensions
        .map((String ext) => ext.replaceFirst('.', ''))
        .toSet();
    final List<String> paths = await pickRealFilePaths(
      context: dialogContext,
      appModel: appModel,
      allowedExtensions: audioExtensions,
    )
      ..sort(compareAudioFilePath);
    if (paths.isNotEmpty && dialogContext.mounted) {
      Navigator.pop(dialogContext, paths);
    }
  }
}

/// TODO-1115：有声书片段视频「多句连读 + 逐句高亮跟随」动态导出计划（纯数据）。
///
/// [globalStartMs]/[globalEndMs] 是整段完整音频窗口（首句 head-padded start .. 末句
/// tail-padded end，含 A/V 偏移），音频裁剪与帧计划共用。[cueSpans] 是有序（升序）
/// 单文件多句，供逐句高亮渲帧。单句选区时 [cueSpans] 只有一元素，动态路径仍可跑（等价
/// 单句动态），失败时管线回退单句静态。
class _AudiobookClipDynamicPlan {
  const _AudiobookClipDynamicPlan({
    required this.audioFileIndex,
    required this.globalStartMs,
    required this.globalEndMs,
    required this.cueSpans,
    this.imagesByCueIndex = const <List<Uint8List>>[],
  });

  final int audioFileIndex;
  final int globalStartMs;
  final int globalEndMs;
  final List<AudiobookClipCueSpan> cueSpans;

  /// TODO-1127：与 [cueSpans] 同下标对齐的「每句后夹带插图」列表（选区里夹在该句之后的
  /// EPUB 插图字节，已降采样）。绝大多数句子为空列表；空则等价旧行为（只渲文本）。
  final List<List<Uint8List>> imagesByCueIndex;
}
