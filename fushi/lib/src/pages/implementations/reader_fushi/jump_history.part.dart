part of '../reader_fushi_page.dart';

/// 「跳转回退」：正文跳转（目录 / 内链 / 搜索 / 收藏 / 字数跳转 / 图库）与有声书
/// 大跨度音频跳转（拖进度 / 点句 / 章节定位，经
/// [AudiobookPlayerController.onBeforeAudioJump]）之前记下出发点，浮动胶囊
/// [FushiJumpHistoryPill] 上的「← 返回 / 前进 →」像浏览器历史一样来回走。历史只活
/// 在本次阅读会话（State 生命周期），不落库。
///
/// 记录口径（[ReaderJumpKind]）：正文跳转回去只恢复正文；音频跳转回去 seek 音频、
/// 正文强制跟随到那句。正文跳转紧接着带动了音频（2 秒内）时两者是同一次动作，栈顶
/// 那条升级成音频点，不压两条。
///
/// 显隐：没跳转过不画；有历史时，刚跳转 / 返回 / 前进后亮 [_flashDuration]，
/// 之后只在用户唤出 chrome 时随顶栏出现；× 清空历史。歌词模式下胶囊挂在歌词
/// 覆盖层歌词区的底边、紧贴底栏上方，歌词矩形为它让出一条带子、不压歌词行（反馈
/// 0AwuVqrNFn，见 [kLyricsNavigationAccessoryBand]；覆盖层本身就是常驻 chrome），
/// 正文点换算成对应句跳音频。
extension _ReaderJumpBack on _ReaderFushiPageState {
  /// 同一次用户动作里「正文跳转 → 音频跟着动」的最长间隔。
  static const Duration _sameGestureWindow = Duration(seconds: 2);

  /// 跳转 / 返回 / 前进之后胶囊在 chrome 收起时也亮着的时长。
  static const Duration _flashDuration = Duration(seconds: 6);

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
  Future<void> _recordTextJumpDeparture() async {
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
    );
    if (pushed) _lastTextJumpRecordedAt = DateTime.now();
    _onJumpHistoryChanged();
  }

  /// [AudiobookPlayerController.onBeforeAudioJump] 的接收端（同步：物理 seek
  /// 之前触发，此刻当前句仍是出发句）。
  void _recordAudioJumpDeparture(int fromGlobalMs) {
    if (_jumpHistoryRestoring || !mounted) return;
    final DateTime? textAt = _lastTextJumpRecordedAt;
    _lastTextJumpRecordedAt = null;
    final ReaderJumpPoint? top = _jumpHistory.backTarget;
    if (textAt != null &&
        top != null &&
        top.kind == ReaderJumpKind.text &&
        DateTime.now().difference(textAt) <= _sameGestureWindow) {
      // 正文跳转刚带动了音频：同一次动作，栈顶升级成音频点（正文锚保留正文
      // 跳转前采样到的那份，更准）。
      _jumpHistory.replaceBackTop(
        ReaderJumpPoint(
          kind: ReaderJumpKind.audio,
          chapter: top.chapter,
          progress: top.progress,
          charOffset: top.charOffset,
          audioGlobalMs: fromGlobalMs,
        ),
      );
    } else {
      _jumpHistory.recordDeparture(_audioJumpPointAt(fromGlobalMs));
    }
    _onJumpHistoryChanged();
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

  void _onJumpHistoryChanged() {
    if (!mounted) return;
    _jumpPillFlashTimer?.cancel();
    final bool flash = !_jumpHistory.isEmpty;
    if (flash) {
      _jumpPillFlashTimer = Timer(_flashDuration, () {
        _rebuild(() => _jumpPillFlashing = false);
      });
    }
    _rebuild(() => _jumpPillFlashing = flash);
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

  Future<void> _jumpHistoryBack() => _walkJumpHistory(forward: false);

  Future<void> _jumpHistoryForward() => _walkJumpHistory(forward: true);

  Future<void> _walkJumpHistory({required bool forward}) async {
    if (_jumpHistoryRestoring) return;
    final ReaderJumpPoint? peek = forward
        ? _jumpHistory.forwardTarget
        : _jumpHistory.backTarget;
    if (peek == null) return;
    final ReaderJumpPoint? here = await _currentJumpPoint(peek.kind);
    if (here == null || !mounted) return;
    final ReaderJumpPoint? target = forward
        ? _jumpHistory.goForward(here)
        : _jumpHistory.goBack(here);
    if (target == null) return;
    _jumpHistoryRestoring = true;
    _onJumpHistoryChanged();
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
    _onJumpHistoryChanged();
  }

  /// 胶囊上目标点的位置文案：音频点 = 全书时间（`1:02:03` / `12:34`），正文点 =
  /// 全书进度百分比（与收藏面板同一套字数账本）；账本未就绪时退回章内百分比。
  String _jumpPointLabel(ReaderJumpPoint point) {
    final int? ms = point.audioGlobalMs;
    if (point.kind == ReaderJumpKind.audio && ms != null) {
      return formatJumpHistoryTime(ms);
    }
    final int chapterLen =
        point.chapter >= 0 && point.chapter < _chapterCharCounts.length
        ? _chapterCharCounts[point.chapter]
        : 0;
    final int inChapter = point.charOffset >= 0
        ? point.charOffset
        : (point.progress * chapterLen).round();
    final double? fraction = favoriteBookProgressFraction(
      cumulativeChars: _chapterCumulativeChars,
      charCounts: _chapterCharCounts,
      sectionIndex: point.chapter,
      normCharOffset: inChapter,
    );
    final double shown = fraction ?? point.progress;
    return '${(shown * 100).toStringAsFixed(1)}%';
  }

  /// 胶囊本体（正文态与歌词态共用）。[from] 是滑入来向：正文态挂顶部（up），
  /// 歌词态挂在底栏上方（down）。
  Widget _jumpHistoryPill({
    required bool visible,
    AxisDirection from = AxisDirection.up,
  }) {
    final ReaderJumpPoint? back = _jumpHistory.backTarget;
    final ReaderJumpPoint? forward = _jumpHistory.forwardTarget;
    return FushiJumpHistoryPill(
      visible: visible,
      backLabel: back == null ? null : _jumpPointLabel(back),
      forwardLabel: forward == null ? null : _jumpPointLabel(forward),
      onBack: () => unawaited(_jumpHistoryBack()),
      onForward: () => unawaited(_jumpHistoryForward()),
      onClear: _clearJumpHistory,
      colors: _lyricsMode ? null : _floatingToolbarColors(),
      from: from,
    );
  }

  /// 正文态：顶部居中，chrome 唤出时坐在顶栏下方。歌词模式由覆盖层自己挂
  /// （[_buildLyricsOverlay] 的 navigationAccessory），这里不画。
  Widget _buildJumpHistoryPill() {
    if (!_hasEverLoaded || _lyricsMode || _jumpHistory.isEmpty) {
      return const SizedBox.shrink();
    }
    final bool chromeShown = _bottomBarShouldPaint;
    final double headerExtent = chromeShown
        ? (_floatingToolbars
              ? kReaderFloatingHeaderExtent
              : kReaderDesktopHeaderHeight)
        : 0;
    return AnimatedPositioned(
      key: const ValueKey<String>('fushi_reader_jump_history_pill'),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      top: _stableTopInset + headerExtent + kReaderFloatingBarMargin,
      left: 0,
      right: 0,
      child: RepaintBoundary(
        child: _jumpHistoryPill(visible: chromeShown || _jumpPillFlashing),
      ),
    );
  }
}
