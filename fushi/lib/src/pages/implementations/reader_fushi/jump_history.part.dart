part of '../reader_fushi_page.dart';

/// 没有落点刻度（刻度关闭 / 没有历史）。
const ({List<double> back, List<double> forward}) _kNoJumpMarks = (
  back: <double>[],
  forward: <double>[],
);

/// 「跳转记录」：正文跳转（目录 / 内链 / 搜索 / 收藏 / 字数跳转 / 图库）与有声书
/// 大跨度音频跳转（拖进度 / 点句 / 章节定位，经
/// [AudiobookPlayerController.onBeforeAudioJump]）之前记下出发点与来源动作
/// （[JumpSource]），像浏览器历史一样来回走。历史只活在本次阅读会话（State 生命
/// 周期），不落库。
///
/// 记录口径（[ReaderJumpKind]）：正文跳转回去只恢复正文；音频跳转回去 seek 音频、
/// 正文强制跟随到那句。正文跳转紧接着带动了音频（2 秒内）时两者是同一次动作，栈顶
/// 那条升级成音频点，不压两条。
///
/// 界面（所有者 2026-11-02 定稿，共用件见 fushi_jump_history_controls.dart）：
///  * 顶栏右上角动作区最前面的纯图标 ↶ / ↷（[_jumpHistoryToolbarItems]）：悬浮顶栏、
///    桌面经典顶栏、歌词覆盖层顶栏三处同一份；跟着顶栏一起显隐，顶栏收着时跳转不做
///    任何提示。长按 / 右键开「跳转记录」面板。设置可关（关了照样记录）、可自动隐藏
///    （[_jumpAutoHide]，只藏图标）。
///  * 「⋯」菜单与导航页「位置」的「跳转记录」入口（有历史时才有）。
///  * 落点刻度：有声书迷你播放条 / 有声书面板整书进度条（音频点）、导航页全书进度条
///    （全书百分比）。
extension _ReaderJumpBack on _ReaderFushiPageState {
  /// 同一次用户动作里「正文跳转 → 音频跟着动」的最长间隔。
  static const Duration _sameGestureWindow = Duration(seconds: 2);

  /// 当前正文位置（章 + 章内锚）。恢复在飞时位置还没落定，返回 null（不记）。
  /// 有声书当前句拥有阅读位置时以当前句为准；否则先读一次 WebView 的视口首字符，
  /// 读不到退回最近一次采样缓存。
  Future<({int chapter, double progress, int charOffset})?>
  _sampleTextPosition() async {
    if (_book == null || _restoreInFlight || !_readerContentReady) return null;
    if (_cueOwnsReadingPosition) {
      final ({int section, double progress, int charOffset})? cue =
          _readingPositionFromCurrentCue();
      if (cue != null) {
        return (
          chapter: cue.section,
          progress: cue.progress,
          charOffset: cue.charOffset,
        );
      }
    }
    final int chapter = _currentChapter;
    double progress = _lastProgressSection == chapter ? _lastProgressValue : 0;
    int charOffset = _lastProgressSection == chapter
        ? _lastProgressCharOffset
        : -1;
    final InAppWebViewController? controller = _controller;
    if (controller != null) {
      try {
        final ReaderStableProgressDetails? live =
            parseReaderStableProgressDetails(
              await controller.evaluateJavascript(
                source: ReaderPaginationScripts.stableProgressInvocation(),
              ),
            );
        if (live != null && chapter == _currentChapter && !_restoreInFlight) {
          progress = live.progress;
          charOffset = live.charOffset;
        }
      } catch (e, stack) {
        ErrorLogService.instance.log(
          'ReaderFushi._sampleTextPosition',
          e,
          stack,
        );
      }
    }
    if (!mounted || chapter != _currentChapter) return null;
    return (chapter: chapter, progress: progress, charOffset: charOffset);
  }

  /// 正文跳转入口在动手**之前** await 它。歌词模式下的「跳章 / 跳收藏」实际是音频
  /// 跳转，由 [_recordAudioJumpDeparture] 记，这里不重复记。
  Future<void> _recordTextJumpDeparture({required JumpSource source}) async {
    if (_jumpHistoryRestoring || _lyricsMode) return;
    final ({int chapter, double progress, int charOffset})? at =
        await _sampleTextPosition();
    if (at == null || !mounted) return;
    final bool pushed = _jumpHistory.recordDeparture(
      ReaderJumpPoint(
        kind: ReaderJumpKind.text,
        chapter: at.chapter,
        progress: at.progress,
        charOffset: at.charOffset,
      ),
      source: source,
    );
    if (pushed) _lastTextJumpRecordedAt = DateTime.now();
    _jumpAutoHide.markJump();
  }

  /// [AudiobookPlayerController.onBeforeAudioJump] 的接收端（同步：物理 seek
  /// 之前触发，此刻当前句仍是出发句）。
  void _recordAudioJumpDeparture(int fromGlobalMs, JumpSource source) {
    if (_jumpHistoryRestoring || !mounted) return;
    final DateTime? textAt = _lastTextJumpRecordedAt;
    _lastTextJumpRecordedAt = null;
    final List<JumpHistoryEntry<ReaderJumpPoint>> back =
        _jumpHistory.backEntries;
    final JumpHistoryEntry<ReaderJumpPoint>? top = back.isEmpty
        ? null
        : back.last;
    if (textAt != null &&
        top != null &&
        top.point.kind == ReaderJumpKind.text &&
        DateTime.now().difference(textAt) <= _sameGestureWindow) {
      // 正文跳转刚带动了音频：同一次动作，栈顶升级成音频点（正文锚保留正文
      // 跳转前采样到的那份，更准）。来源沿用正文那次的动作；有声书面板「章节」
      // 页（先跳章再定音频）由音频侧报的「章节定位」更准，改用它。
      final ReaderJumpPoint upgraded = ReaderJumpPoint(
        kind: ReaderJumpKind.audio,
        chapter: top.point.chapter,
        progress: top.point.progress,
        charOffset: top.point.charOffset,
        audioGlobalMs: fromGlobalMs,
      );
      _jumpHistory.replaceBackTop(upgraded);
      if (source == JumpSource.chapter) {
        // 与栈顶同一处：只刷新栈顶的来源，不新增条目。
        _jumpHistory.recordDeparture(upgraded, source: source);
      }
    } else {
      _jumpHistory.recordDeparture(
        _audioJumpPointAt(fromGlobalMs),
        source: source,
      );
    }
    _jumpAutoHide.markJump();
  }

  /// 以当前句为正文锚的音频点（当前句映射不出时退回正文采样缓存）。
  ReaderJumpPoint _audioJumpPointAt(int globalMs) {
    final ({int section, double progress, int charOffset})? cue =
        _readingPositionFromCurrentCue();
    final int chapter = cue?.section ?? _currentChapter;
    final bool cached = _lastProgressSection == chapter;
    return ReaderJumpPoint(
      kind: ReaderJumpKind.audio,
      chapter: chapter,
      progress: cue?.progress ?? (cached ? _lastProgressValue : 0),
      charOffset: cue?.charOffset ?? (cached ? _lastProgressCharOffset : -1),
      audioGlobalMs: globalMs,
    );
  }

  /// 顶栏图标自动隐藏到时 / 重新计时：重建（图标收起或重新出现）。
  void _onJumpAutoHideChanged() {
    if (!mounted) return;
    _rebuild(() {});
  }

  /// 「当前在哪」：返回 / 前进时压进对侧栈的点，与要去的点同一种 [kind]
  /// （音频点要带当前全书毫秒，正文点只要正文锚）。歌词模式没有可采样的正文
  /// 视口，一律记成音频点。
  Future<ReaderJumpPoint?> _currentJumpPoint(ReaderJumpKind kind) async {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (kind == ReaderJumpKind.audio || _lyricsMode) {
      if (ctrl == null) return null;
      return _audioJumpPointAt(ctrl.globalPosition.inMilliseconds);
    }
    final ({int chapter, double progress, int charOffset})? at =
        await _sampleTextPosition();
    if (at == null) return null;
    return ReaderJumpPoint(
      kind: kind,
      chapter: at.chapter,
      progress: at.progress,
      charOffset: at.charOffset,
    );
  }

  /// 面板「当前位置」那一行用的同步快照（不读 WebView）：歌词模式取音频位置，
  /// 否则取最近一次正文采样缓存。
  ReaderJumpPoint _currentJumpPointSnapshot() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (_lyricsMode && ctrl != null) {
      return _audioJumpPointAt(ctrl.globalPosition.inMilliseconds);
    }
    final int chapter = _currentChapter;
    final bool cached = _lastProgressSection == chapter;
    return ReaderJumpPoint(
      kind: ReaderJumpKind.text,
      chapter: chapter,
      progress: cached ? _lastProgressValue : 0,
      charOffset: cached ? _lastProgressCharOffset : -1,
    );
  }

  Future<void> _jumpHistoryBack() => _walkJumpHistory(-1);

  Future<void> _jumpHistoryForward() => _walkJumpHistory(1);

  /// 走 [steps] 步：负 = 返回 |steps| 步，正 = 前进 [steps] 步（面板里点某一条；
  /// 顶栏 ↶ / ↷ 是 ±1）。落点按它自己的 [ReaderJumpKind] 恢复。
  Future<void> _walkJumpHistory(int steps) async {
    if (_jumpHistoryRestoring || steps == 0) return;
    final List<JumpHistoryEntry<ReaderJumpPoint>> entries = steps < 0
        ? _jumpHistory.backEntries
        : _jumpHistory.forwardEntries;
    final int n = steps.abs();
    if (n > entries.length) return;
    final ReaderJumpPoint peek = entries[entries.length - n].point;
    final ReaderJumpPoint? here = await _currentJumpPoint(peek.kind);
    if (here == null || !mounted) return;
    final ReaderJumpPoint? target = steps < 0
        ? _jumpHistory.goBackSteps(here, n)
        : _jumpHistory.goForwardSteps(here, n);
    if (target == null) return;
    _jumpHistoryRestoring = true;
    _jumpAutoHide.markJump();
    try {
      await _restoreJumpPoint(target);
    } finally {
      _jumpHistoryRestoring = false;
    }
  }

  Future<void> _restoreJumpPoint(ReaderJumpPoint point) async {
    final AudiobookPlayerController? ctrl = _audiobookController;
    final int? audioMs = point.audioGlobalMs;
    if (point.kind == ReaderJumpKind.audio && ctrl != null && audioMs != null) {
      // 音频点：回到那一刻的播放位置，正文强制跟随到那句（覆盖期间用户手翻的
      // 「不跟随」）。歌词覆盖层随 cue 自己滚过去。
      await ctrl.seekGlobalMs(audioMs);
      if (!mounted) return;
      ctrl.snapReaderToAudio();
      return;
    }
    if (_book == null) return;
    if (point.chapter < 0 || point.chapter >= _book!.chapters.length) return;
    if (_lyricsMode) {
      // 歌词模式里没有正文视口可恢复：正文点落到覆盖它的那句（与歌词模式跳收藏
      // 同一条 skipToCue 路）；该处没有对齐到句子就落该章首句。
      final AudioCue? cue =
          _cueCoveringTextPoint(point) ?? _firstCueOfSection(point.chapter);
      if (cue != null) await ctrl?.skipToCue(cue);
      return;
    }
    final int? charOffset = point.charOffset >= 0 ? point.charOffset : null;
    if (point.chapter != _currentChapter) {
      await _navigateToChapterAndWait(
        point.chapter,
        manual: true,
        progress: point.progress,
        charOffset: charOffset,
      );
      return;
    }
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    // 同章：与收藏 / 字数跳转同族的 restore 入口；不经 _beginNavigation，离开当前
    // 页在此结算（BUG-2225），并告诉有声书这是用户手动导航（不被音频拽回）。
    _readLedger.leave();
    ctrl?.noteManualReaderNavigation();
    await controller.evaluateJavascript(
      source: charOffset != null
          ? 'window.fushiReader && '
                'window.fushiReader.restoreToCharOffset($charOffset);'
          : 'window.fushiReader && '
                'window.fushiReader.restoreProgress(${point.progress});',
    );
  }

  /// 覆盖正文点的那句 cue（章内偏移落在 cue 的正文区间里，或之后最近的一句）。
  AudioCue? _cueCoveringTextPoint(ReaderJumpPoint point) {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) return null;
    final int chapterLen =
        point.chapter >= 0 && point.chapter < _chapterCharCounts.length
        ? _chapterCharCounts[point.chapter]
        : 0;
    final int offset = point.charOffset >= 0
        ? point.charOffset
        : (point.progress * chapterLen).round();
    for (final AudioCue cue in ctrl.sentenceAudioCuesForSection(
      point.chapter,
    )) {
      final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
        cue.textFragmentId,
      );
      if (frag == null) continue;
      if (frag.normCharEnd > offset) return cue;
    }
    return null;
  }

  void _clearJumpHistory() {
    _jumpHistory.clear();
    _lastTextJumpRecordedAt = null;
    _jumpAutoHide.reset();
  }

  /// 正文点在全书字数进度上的位置（0~1，与收藏面板同一套字数账本）；账本未就绪
  /// 返回 null。
  double? _jumpPointBookFraction(ReaderJumpPoint point) {
    final int chapterLen =
        point.chapter >= 0 && point.chapter < _chapterCharCounts.length
        ? _chapterCharCounts[point.chapter]
        : 0;
    final int inChapter = point.charOffset >= 0
        ? point.charOffset
        : (point.progress * chapterLen).round();
    return favoriteBookProgressFraction(
      cumulativeChars: _chapterCumulativeChars,
      charCounts: _chapterCharCounts,
      sectionIndex: point.chapter,
      normCharOffset: inChapter,
    );
  }

  /// 落点的位置文案（tooltip / 面板）：音频点 = 全书时间（`1:02:03` / `12:34`），
  /// 正文点 = 全书进度百分比；账本未就绪时退回章内百分比。
  String _jumpPointLabel(ReaderJumpPoint point) {
    final int? ms = point.audioGlobalMs;
    if (point.kind == ReaderJumpKind.audio && ms != null) {
      return formatJumpHistoryTime(ms);
    }
    final double shown = _jumpPointBookFraction(point) ?? point.progress;
    return '${(shown * 100).toStringAsFixed(1)}%';
  }

  /// 面板一行的位置文案：「12.4% · 第三章」/「1:02:03 · 第三章」。
  String _jumpPointPanelLabel(ReaderJumpPoint point) {
    final String chapter = _currentChapterLabelFor(
      point.chapter,
      charOffset: point.charOffset >= 0 ? point.charOffset : null,
    );
    final String position = _jumpPointLabel(point);
    return chapter.isEmpty ? position : '$position · $chapter';
  }

  /// 打开「跳转记录」面板：点哪条走到哪条（复用返回 / 前进的落地逻辑），页头清除。
  Future<void> _openJumpHistoryPanel() async {
    if (!mounted || _jumpHistory.isEmpty) return;
    await showJumpHistoryPanel<ReaderJumpPoint>(
      context: context,
      history: _jumpHistory,
      labelOf: _jumpPointPanelLabel,
      currentLabel: _jumpPointPanelLabel(_currentJumpPointSnapshot()),
      onWalk: (int steps) => unawaited(_walkJumpHistory(steps)),
      onClear: _clearJumpHistory,
    );
  }

  /// 顶栏最前面的 ↶ / ↷（悬浮顶栏 / 歌词覆盖层共用）。没跳转过、设置关掉、自动
  /// 隐藏到时返回空表。
  List<FushiToolbarItem> _jumpHistoryToolbarItems() {
    if (!_hasEverLoaded) return const <FushiToolbarItem>[];
    final AppModel model = appModelNoUpdate;
    if (!jumpHistoryToolbarVisible(
      enabled: model.jumpHistoryToolbar,
      hasHistory: !_jumpHistory.isEmpty,
      expired: _jumpAutoHide.expired,
    )) {
      return const <FushiToolbarItem>[];
    }
    final ReaderJumpPoint? back = _jumpHistory.backTarget;
    final ReaderJumpPoint? forward = _jumpHistory.forwardTarget;
    return jumpHistoryToolbarItems(
      backLabel: back == null ? null : _jumpPointLabel(back),
      forwardLabel: forward == null ? null : _jumpPointLabel(forward),
      onBack: () => unawaited(_jumpHistoryBack()),
      onForward: () => unawaited(_jumpHistoryForward()),
      onOpenPanel: () => unawaited(_openJumpHistoryPanel()),
    );
  }

  /// 桌面经典顶栏（[ReaderDesktopHeader]）用的同一组按钮：恒钉住（窄窗也不收进
  /// ⋮，收进去就没有长按了）。
  List<ReaderHeaderAction> _jumpHistoryHeaderActions() => <ReaderHeaderAction>[
    for (final FushiToolbarItem item in _jumpHistoryToolbarItems())
      ReaderHeaderAction(
        key: item.key,
        icon: item.icon,
        label: item.label,
        tooltip: item.tooltip,
        onPressed: item.onPressed,
        onLongPress: item.onLongPress,
        pinned: true,
      ),
  ];

  /// 「⋯」菜单里的「跳转记录」（有历史时才有；顶栏图标关掉 / 隐藏后仍能开面板）。
  List<FushiToolbarItem> _jumpHistoryMenuItems() => _jumpHistory.isEmpty
      ? const <FushiToolbarItem>[]
      : <FushiToolbarItem>[
          jumpHistoryPanelMenuItem(
            onOpen: () => unawaited(_openJumpHistoryPanel()),
          ),
        ];

  /// [_jumpHistoryMenuItems] 的 [ReaderHeaderAction] 版（桌面经典顶栏 ⋮、歌词 ⋯）。
  List<ReaderHeaderAction> _jumpHistoryMenuActions() => <ReaderHeaderAction>[
    for (final FushiToolbarItem item in _jumpHistoryMenuItems())
      ReaderHeaderAction(
        key: item.key,
        icon: item.icon,
        label: item.label,
        onPressed: item.onPressed,
      ),
  ];

  /// 刻度开关（设置「进度条刻度」）。
  bool get _jumpMarksEnabled =>
      appModelNoUpdate.jumpHistoryProgressMarks && !_jumpHistory.isEmpty;

  /// 有声书全书时间轴上的落点（迷你播放条、有声书面板整书进度条）：只有音频点
  /// 有时间；正文点不在这条轴上，不画。刻度关掉 / 时长未知返回 null。
  ({List<double> back, List<double> forward})? _audioJumpMarks() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (!_jumpMarksEnabled || ctrl == null) return null;
    final int totalMs = ctrl.totalDuration.inMilliseconds;
    if (totalMs <= 0) return null;
    return jumpHistoryMarkFractions<ReaderJumpPoint>(_jumpHistory, (
      ReaderJumpPoint p,
    ) {
      final int? ms = p.audioGlobalMs;
      return p.kind == ReaderJumpKind.audio && ms != null ? ms / totalMs : null;
    });
  }

  /// 全书字数进度上的落点（导航页「阅读进度」条）：正文点与音频点都有正文锚。
  ({List<double> back, List<double> forward})? _bookJumpMarks() {
    if (!_jumpMarksEnabled) return null;
    return jumpHistoryMarkFractions<ReaderJumpPoint>(
      _jumpHistory,
      _jumpPointBookFraction,
    );
  }
}
