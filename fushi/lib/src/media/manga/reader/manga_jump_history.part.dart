part of 'manga_fushi_page.dart';

/// 漫画阅读器「跳转记录」（与小说阅读器 `reader_fushi/jump_history.part.dart`、
/// 视频播放器同一套口径，共用 [JumpHistory] 与 `fushi_jump_history_controls.dart`）。
///
/// 记录口径：**非连续**跳转在动手之前记下出发点——章节目录选章、底栏上一章 /
/// 下一章按钮、页码滑块拖动松手、跳页对话框、页面一览、「回到开头」、桌面控制
/// 通道（`fushi_cli reader`）跳页 / 跳章。逐页翻页、分镜导航、webtoon 锚点翻页、
/// 翻过章节边界自动换章、换单双页 / 阅读模式时的保位重排都**不**记。历史只活在
/// 本次阅读会话（State 生命周期），不落库。
///
/// 呈现（所有者 2026-11-02 定稿）：
///  * 顶栏动作胶囊最前面一组纯图标：↶ 返回，走过返回后多出 ↷ 前进；落点只进
///    tooltip。长按 / 右键打开「跳转记录」面板。没跳转过不出现，跟着顶栏显隐，
///    顶栏收着时跳转不做任何提示。设置可关（关了照样记录）、可按秒自动隐藏
///    （[JumpHistoryAutoHide]，只藏图标）。
///  * 「⋯」里的「跳转记录」：有历史时才有，打开面板（点哪条跳哪条，页头清除）。
///  * 底栏页码滑块上画**同一话内**的返回 / 前进落点刻度；跨话的点只在面板里。
extension _MangaJumpBack on _MangaFushiPageState {
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
  /// 不算跳转——滑块拖了又放回原处、跳页框填当前页都不该留历史。[source] 是这次
  /// 跳转的动作（面板副标题）。
  void _recordMangaJumpDeparture({
    required JumpSource source,
    int? targetPage,
  }) {
    if (_jumpHistoryRestoring || _switchingChapter || !mounted) return;
    if (targetPage != null &&
        MangaFushiPage.spreadIndexForPage(_spreads, targetPage) ==
            _currentSpread) {
      return;
    }
    final MangaJumpPoint? here = _currentMangaJumpPoint();
    if (here == null) return;
    _jumpHistory.recordDeparture(here, source: source);
    _onMangaJumpHistoryChanged(jumped: true);
  }

  /// 历史变了：重建 chrome（图标 / 刻度 / 菜单项）；[jumped] = 刚发生一次跳转
  /// （含返回 / 前进 / 面板跳转），自动隐藏重新计时。
  void _onMangaJumpHistoryChanged({required bool jumped}) {
    if (!mounted) return;
    if (jumped) {
      _jumpHistoryAutoHide.markJump();
    } else {
      _markMangaJumpHistoryDirty();
    }
  }

  Future<void> _mangaJumpHistoryBack() => _walkMangaJumpHistory(-1);

  Future<void> _mangaJumpHistoryForward() => _walkMangaJumpHistory(1);

  /// 走 [steps] 步：负 = 返回 N 步，正 = 前进 N 步（面板里点某一行同此）。
  Future<void> _walkMangaJumpHistory(int steps) async {
    if (steps == 0 || _jumpHistoryRestoring || _switchingChapter) return;
    final MangaJumpPoint? here = _currentMangaJumpPoint();
    if (here == null) return;
    final MangaJumpPoint? target = steps > 0
        ? _jumpHistory.goForwardSteps(here, steps)
        : _jumpHistory.goBackSteps(here, -steps);
    if (target == null) return;
    _jumpHistoryRestoring = true;
    _onMangaJumpHistoryChanged(jumped: true);
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
    _jumpHistoryAutoHide.reset();
    _onMangaJumpHistoryChanged(jumped: false);
  }

  String? _mangaChapterNameOf(String? chapterKey) {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    if (entry == null || chapterKey == null) return null;
    final int index = entry.indexOfChapterKey(chapterKey);
    if (index < 0) return null;
    return mangaChapterDisplayName(entry.chapters[index]);
  }

  /// 落点文案；[alwaysShowChapter] 见 [mangaJumpPointLabel]（面板用 true）。
  String _mangaJumpPointLabel(
    MangaJumpPoint point, {
    bool alwaysShowChapter = false,
  }) => mangaJumpPointLabel(
    point: point,
    currentChapterKey: _shelfChapterKey,
    chapterName: _mangaChapterNameOf(point.chapterKey),
    alwaysShowChapter: alwaysShowChapter,
  );

  /// 打开「跳转记录」面板：各行与当前位置都是 `第 N 话 · 页码`。
  Future<void> _showMangaJumpHistoryPanel() async {
    if (!mounted) return;
    final MangaJumpPoint? here = _currentMangaJumpPoint();
    await showJumpHistoryPanel<MangaJumpPoint>(
      context: context,
      history: _jumpHistory,
      labelOf: (MangaJumpPoint p) =>
          _mangaJumpPointLabel(p, alwaysShowChapter: true),
      currentLabel: here == null
          ? ''
          : _mangaJumpPointLabel(here, alwaysShowChapter: true),
      onWalk: (int steps) => unawaited(_walkMangaJumpHistory(steps)),
      onClear: _clearMangaJumpHistory,
    );
  }

  /// 顶栏动作胶囊最前面的返回 / 前进图标；设置关了、没历史、过了自动隐藏时限、
  /// 正文没就绪时为空。
  List<FushiToolbarItem> _mangaJumpToolbarItems() {
    if (!_chromeActionsEnabled ||
        !jumpHistoryToolbarVisible(
          enabled: appModel.jumpHistoryToolbar,
          hasHistory: !_jumpHistory.isEmpty,
          expired: _jumpHistoryAutoHide.expired,
        )) {
      return const <FushiToolbarItem>[];
    }
    final MangaJumpPoint? back = _jumpHistory.backTarget;
    final MangaJumpPoint? forward = _jumpHistory.forwardTarget;
    return jumpHistoryToolbarItems(
      backLabel: back == null ? null : _mangaJumpPointLabel(back),
      forwardLabel: forward == null ? null : _mangaJumpPointLabel(forward),
      onBack: () => unawaited(_mangaJumpHistoryBack()),
      onForward: () => unawaited(_mangaJumpHistoryForward()),
      onOpenPanel: () => unawaited(_showMangaJumpHistoryPanel()),
    );
  }

  /// 「⋯」里的「跳转记录」入口：有历史时才有（顶栏图标关掉 / 自动隐藏后仍能开面板）。
  MangaChromeAction? _mangaJumpHistoryMenuAction() {
    if (!_chromeActionsEnabled || _jumpHistory.isEmpty) return null;
    final FushiToolbarItem item = jumpHistoryPanelMenuItem(
      onOpen: () => unawaited(_showMangaJumpHistoryPanel()),
    );
    return MangaChromeAction(
      key: item.key,
      icon: item.icon,
      label: item.label,
      slot: MangaChromeSlot.overflow,
      onPressed: item.onPressed,
    );
  }

  /// 页码滑块上的落点刻度：只画本话内的点（跨话的只在面板里）；设置关了为 null。
  ({List<double> back, List<double> forward})? _mangaJumpMarks() {
    if (!appModel.jumpHistoryProgressMarks || _jumpHistory.isEmpty) {
      return null;
    }
    final int pageCount = _payload?.images.length ?? 0;
    final String? chapterKey = _shelfChapterKey;
    final bool rtl = _spreadDirection == 'rtl';
    return jumpHistoryMarkFractions<MangaJumpPoint>(
      _jumpHistory,
      (MangaJumpPoint p) => p.chapterKey != chapterKey
          ? null
          : mangaJumpMarkFraction(
              pageIndex: p.page,
              pageCount: pageCount,
              rtl: rtl,
            ),
    );
  }
}
