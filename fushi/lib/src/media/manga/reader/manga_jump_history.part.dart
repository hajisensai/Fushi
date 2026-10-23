part of 'manga_fushi_page.dart';

/// 漫画阅读器「跳转回退」（与小说阅读器 `reader_fushi/jump_history.part.dart`
/// 同一套口径，共用 [JumpHistory] 与 [FushiJumpHistoryPill]）。
///
/// 记录口径：**非连续**跳转在动手之前记下出发点——章节目录选章、底栏上一章 /
/// 下一章按钮、页码滑块拖动松手、跳页对话框、页面一览、「回到开头」、桌面控制
/// 通道（`fushi_cli reader`）跳页 / 跳章。逐页翻页、分镜导航、webtoon 锚点翻页、
/// 翻过章节边界自动换章、换单双页 / 阅读模式时的保位重排都**不**记。历史只活在
/// 本次阅读会话（State 生命周期），不落库。
///
/// 显隐：没跳转过不画；有历史时，刚跳转 / 返回 / 前进后亮 [_flashDuration]，
/// 之后只在 chrome（顶栏）显示时随之出现；× 清空历史。
extension _MangaJumpBack on _MangaFushiPageState {
  /// 跳转 / 返回 / 前进之后胶囊在 chrome 收起时也亮着的时长。
  static const Duration _flashDuration = Duration(seconds: 6);

  /// 当前位置。正文没装好（加载失败）返回 null；「本章未下载」态仍给章 + 第 0 页，
  /// 这样换去一个打不开的章之后还能「返回」原处。
  MangaJumpPoint? _currentMangaJumpPoint() {
    final MokuroPayload? payload = _payload;
    final String? chapterKey = _shelfChapterKey;
    if (payload == null) {
      if (_chapterNotDownloaded && chapterKey != null) {
        return MangaJumpPoint(chapterKey: chapterKey, page: 0, pageCount: 0);
      }
      return null;
    }
    return MangaJumpPoint(
      chapterKey: chapterKey,
      page: _currentPage,
      pageCount: payload.images.length,
      fraction: _mode.isContinuous ? _currentFraction : 0,
    );
  }

  /// 非连续跳转入口在动手**之前**调用（同步：位置全在 Dart 侧）。
  ///
  /// [targetPage]：章内跳页的落点（0-based）。落点就在当前屏（同一 spread）时
  /// 不算跳转——滑块拖了又放回原处、跳页框填当前页都不该留历史。
  void _recordMangaJumpDeparture({int? targetPage}) {
    if (_jumpHistoryRestoring || _switchingChapter || !mounted) return;
    if (targetPage != null &&
        MangaFushiPage.spreadIndexForPage(_spreads, targetPage) ==
            _currentSpread) {
      return;
    }
    final MangaJumpPoint? here = _currentMangaJumpPoint();
    if (here == null) return;
    _jumpHistory.recordDeparture(here);
    _onMangaJumpHistoryChanged();
  }

  void _onMangaJumpHistoryChanged() {
    if (!mounted) return;
    _jumpPillFlashTimer?.cancel();
    final bool flash = !_jumpHistory.isEmpty;
    if (flash) {
      _jumpPillFlashTimer = Timer(_flashDuration, () {
        _setJumpPillFlashing(false);
      });
    }
    _setJumpPillFlashing(flash);
  }

  Future<void> _mangaJumpHistoryBack() => _walkMangaJumpHistory(forward: false);

  Future<void> _mangaJumpHistoryForward() =>
      _walkMangaJumpHistory(forward: true);

  Future<void> _walkMangaJumpHistory({required bool forward}) async {
    if (_jumpHistoryRestoring || _switchingChapter) return;
    final MangaJumpPoint? here = _currentMangaJumpPoint();
    if (here == null) return;
    final MangaJumpPoint? target = forward
        ? _jumpHistory.goForward(here)
        : _jumpHistory.goBack(here);
    if (target == null) return;
    _jumpHistoryRestoring = true;
    _onMangaJumpHistoryChanged();
    try {
      await _restoreMangaJumpPoint(target);
    } finally {
      _jumpHistoryRestoring = false;
    }
  }

  Future<void> _restoreMangaJumpPoint(MangaJumpPoint point) async {
    final String? chapterKey = point.chapterKey;
    if (chapterKey != null && chapterKey != _shelfChapterKey) {
      final OnlineMangaLibraryEntry? entry = _shelfEntry;
      final int index = entry?.indexOfChapterKey(chapterKey) ?? -1;
      // 章已不在列表里（源刷新后被删）：落不了地，丢掉这一步。
      if (index < 0) return;
      await _switchToChapter(index, initialPage: point.page);
      if (!mounted || _shelfChapterKey != chapterKey) return;
      // 跨章装载只按页落地；webtoon 的页内偏移再补一步。
      if (point.fraction > 0 && _mode.isContinuous) {
        await _jumpToPage(point.page + 1, fraction: point.fraction);
      }
      return;
    }
    await _jumpToPage(point.page + 1, fraction: point.fraction);
  }

  void _clearMangaJumpHistory() {
    _jumpHistory.clear();
    _onMangaJumpHistoryChanged();
  }

  String _mangaJumpPointLabel(MangaJumpPoint point) {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    final String? key = point.chapterKey;
    String? chapterName;
    if (entry != null && key != null) {
      final int index = entry.indexOfChapterKey(key);
      if (index >= 0) {
        chapterName = mangaChapterDisplayName(entry.chapters[index]);
      }
    }
    return mangaJumpPointLabel(
      point: point,
      currentChapterKey: _shelfChapterKey,
      chapterName: chapterName,
    );
  }

  /// 顶部居中；chrome 显示时坐在顶栏下沿，收起时贴状态栏下方。OCR 进度浮标
  /// 也挂在顶栏下沿（右对齐），它在时胶囊再往下让一行，免得窄屏上重叠。
  Widget _buildMangaJumpHistoryPill({required bool chromeShown}) {
    if (_jumpHistory.isEmpty) return const SizedBox.shrink();
    final MangaJumpPoint? back = _jumpHistory.backTarget;
    final MangaJumpPoint? forward = _jumpHistory.forwardTarget;
    final double statusBar = MediaQuery.paddingOf(context).top;
    final bool badgeShown = _buildOcrProgressBadge() != null;
    final double top =
        statusBar +
        (chromeShown || badgeShown
            ? kMangaChromeBarHeight
            : kMangaChromeTopGap) +
        (badgeShown ? kMangaJumpPillBadgeClearance : 0);
    return AnimatedPositioned(
      key: const ValueKey<String>('manga_reader_jump_history_pill'),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.standard,
      top: top,
      left: kMangaChromeEdgeInset,
      right: kMangaChromeEdgeInset,
      child: RepaintBoundary(
        child: FushiAppleDarkTier(
          child: FushiJumpHistoryPill(
            visible: chromeShown || _jumpPillFlashing,
            backLabel: back == null ? null : _mangaJumpPointLabel(back),
            forwardLabel: forward == null
                ? null
                : _mangaJumpPointLabel(forward),
            onBack: () => unawaited(_mangaJumpHistoryBack()),
            onForward: () => unawaited(_mangaJumpHistoryForward()),
            onClear: _clearMangaJumpHistory,
          ),
        ),
      ),
    );
  }
}

/// OCR 进度浮标在时，跳转胶囊往下让的高度（浮标单行 + 进度条约 44，留 8 间距）。
const double kMangaJumpPillBadgeClearance = 52;
