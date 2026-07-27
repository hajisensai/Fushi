// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch7).
part of '../reader_hibiki_page.dart';

/// chrome domain (page-turn pagination / reader image viewer + context menu /
/// media-notification toggle / bottom chrome bars + chrome insets / appearance
/// settings sheet / bookmarks + TOC labels / page-info probe / chapter reload /
/// top reading-progress bar / reader theme colours / dictionary-theme sync /
/// section-highlight refresh / favourite-sentence toggle) extracted via
/// part-of (TODO-589 batch7); shared private scope.
///
/// Behaviour-preserving: bodies are byte-for-byte verbatim except (1) the five
/// `setState(` calls (`_toggleChrome`, `_reloadWithCurrentSettings`,
/// `_onThemeChanged`, and the two in `_toggleFavoriteSentence`) forwarded
/// through the main-shell `_rebuild(` helper (extensions cannot call the
/// @protected `State.setState` directly), and (2) the two class statics that
/// stay in the shell because their other call sites live in the still-in-shell
/// WebView region — `_colorToCssRgba` (called from `_customThemeTextCss`) and
/// `_toDouble` (called from `_addBookmarkAtCurrentPosition`) — referenced here
/// fully qualified as `_ReaderHibikiPageState._colorToCssRgba` /
/// `_ReaderHibikiPageState._toDouble`.
///
/// The two class statics whose only call sites moved with this domain
/// (`_themeMap`, used by `_readerThemeColors`; `_didScroll`, used by
/// `_paginate`) move here as extension statics and are referenced by bare name
/// (no qualification needed). The `@override` host member
/// `buildPopupAudioControls` (and the related `_readerChromeHeight` getter /
/// `_readerChromeBaseHeight` / `_readerPopupHeaderBaseHeight` constants) cannot
/// live on an extension and stay in the shell, reachable via the shared private
/// class scope.
extension _ReaderChrome on _ReaderHibikiPageState {
  /// TODO-1229 案A：章界连续输入穿透守卫。滚轮惯性节流（450ms）远短于换章加载
  /// （数百 ms restore），跨章那一下之后排队的翻页 tick 会在新章 restore 未落定时
  /// 立即再翻——章首插图页/首页整页被越过；更糟 hoshiReader 尚未就绪时
  /// evaluateJavascript 返 null → _didScroll(null)=false → 又 _handlePageTurnLimit →
  /// **跳两章**。本 getter 只在「导航在飞（_isNavigatingToChapter）/ 恢复在飞
  /// （_restoreInFlight）/ 内容未就绪（!_readerContentReady）」这三个瞬态窗口为真；
  /// 正常连续翻页三者皆稳态（false/false/true），不受影响。内容就绪有 8s 兜底超时
  /// （_startContentReadyTimeout）强制置真，故绝不会永久卡死翻页。
  bool get _paginationInFlight =>
      _restoreInFlight || !_readerContentReady || _isNavigatingToChapter;

  /// TODO-1229 v2：记一次「跨章相关的惯性输入」发生时刻，把跨章冷却窗滑到当下。
  /// 在两处调用：① 惯性 tick 被 [_paginationInFlight] 丢弃时（换章加载期的残余惯性）；
  /// ② 冷却期内被拒的跨章尝试。持续惯性会不断把冷却窗前推，直到输入静默才让窗关闭。
  void _noteChapterTurnInput() {
    _lastChapterTurnInputAt = DateTime.now();
  }

  /// TODO-1229 第三次复诉：标记「一次惯性跨章已真正发起导航」。只在惯性输入
  /// (滚轮/触摸，throttleMs>0)确实调 [_handlePageTurnLimit] 且其内部真的触发了
  /// 导航时置位（末章/首章边界不导航则不置位，避免旗子悬空）。等新章 content-ready
  /// 时由 [_noteChapterTurnSettledIfPending] 消费。
  void _markInertiaChapterTurnPending() {
    _inertiaChapterTurnPending = true;
  }

  /// TODO-1229 第三次复诉：惯性跨章落地的新章内容就绪那一刻，把跨章冷却窗重新 stamp
  /// 到当下——保证新章刚出现时总有一个完整 [_kChapterTurnCooldown] 窗口挡住残余滚轮/
  /// 惯性，即使换章加载耗时超过冷却窗、期间没有续窗 tick（鼠标滚轮离散事件的真因）。
  /// 只在 pending 时生效并复位旗子；非惯性来源(初次开书/恢复/键盘跨章)不置旗、不受影响。
  void _noteChapterTurnSettledIfPending() {
    if (!_inertiaChapterTurnPending) return;
    _inertiaChapterTurnPending = false;
    _noteChapterTurnInput();
  }

  /// TODO-1229 v2：跨章冷却闸门。距上次「跨章输入/跨章」不足 [_kChapterTurnCooldown] 则
  /// 判为同一手势的残余惯性、拒绝本次跨章并把冷却窗滑到当下（返回 true=正在冷却=拦截）；
  /// 已静默超过冷却窗则放行（返回 false），不刷新——让真正落地的那次跨章自行 stamp。
  /// 只在惯性型输入(滚轮/触摸)的跨章决策处调用；键盘/手柄(throttleMs==0)不经此闸门。
  bool _chapterTurnCoolingDown() {
    final bool cooling = chapterTurnCoolingDown(
      lastInputAt: _lastChapterTurnInputAt,
      now: DateTime.now(),
      cooldown: _ReaderHibikiPageState._kChapterTurnCooldown,
    );
    if (cooling) _lastChapterTurnInputAt = DateTime.now();
    return cooling;
  }

  Future<void> _paginate(
    ReaderNavigationDirection direction, {
    int throttleMs = 0,
  }) async {
    if (_controller == null) {
      return;
    }
    // TODO-1229 案A：导航/恢复在飞窗口直接丢弃输入（放在节流戳之前，被丢弃的输入
    // 不推进 _lastPaginateTime，恢复后首个真实输入不被误吞）。守卫只在瞬态窗口生效，
    // 不误杀正常连续翻页（见 _paginationInFlight 文档）。
    if (_paginationInFlight) {
      // TODO-1229 v2：换章加载期到达的惯性 tick 属同一手势，滑动跨章冷却窗，避免
      // restore 落定后残余惯性立刻在短章边界再次跨章（跳两章真因）。
      if (throttleMs > 0) _noteChapterTurnInput();
      return;
    }
    // TODO-737: 翻页输入节流闸门归一到此唯一入口。各源传不同 throttleMs：滚轮
    // wheelPageTurnInterval(450)、音量键固定 defaultScrollingSpeed(100)、键盘/手柄 0。
    // 时间戳语义（与音量键旧 _lastVolumeKeyTime / HBK-AUDIT-120 一致）：读 throttleMs
    // 时即生效，无残留 timer。**只盖在 _paginate 入口**——内部跨章（_handlePageTurnLimit）
    // 已在闸门内、不重复节流，故分页到章末经 _paginate 仍翻得过去（不自吞，4 必补点 #1）。
    if (throttleMs > 0 && _lastPaginateTime != null) {
      final int elapsedMs =
          DateTime.now().difference(_lastPaginateTime!).inMilliseconds;
      if (elapsedMs < throttleMs) return;
    }
    if (throttleMs > 0) {
      _lastPaginateTime = DateTime.now();
    }
    // Lyrics mode renders LyricsModeHtml — a vertical cue list with no
    // hoshiReader paginator. paginate() there no-ops in JS (the
    // `window.hoshiReader && ...` guard short-circuits) and returns undefined,
    // which _didScroll reads as a page edge → _handlePageTurnLimit →
    // _navigateToChapter, swapping the lyrics page for an EPUB chapter (the
    // text vanishes). Swipe paths already guard this (onSwipe/onBoundarySwipe);
    // the keyboard/gamepad/volume shortcut path funnels through here, so this is
    // the single choke point that must bail in lyrics mode.
    if (_lyricsMode) {
      return;
    }
    if (_settings?.isContinuousMode == true) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.paginateInvocation(direction),
      );
      if (!mounted || _controller == null) return;
      if (!_didScroll(result)) {
        // TODO-1229 v2：惯性型输入(throttleMs>0)跨章前过冷却闸门——同一手势残余惯性
        // 在短章边界的二次跨章被拦（并滑动冷却窗）；键盘/手柄(throttleMs==0)不受限。
        if (throttleMs > 0 && _chapterTurnCoolingDown()) return;
        _noteChapterTurnInput();
        _handlePageTurnLimit(direction.jsValue, inertia: throttleMs > 0);
      } else {
        await _refreshProgress();
        if (!mounted || _controller == null) return;
        await _caretReanchor(direction);
      }
      return;
    }
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.paginateInvocation(direction),
    );
    if (!mounted || _controller == null) return;
    if (_didScroll(result)) {
      await _refreshProgress();
      if (!mounted || _controller == null) return;
      await _caretReanchor(direction);
    } else {
      // TODO-1229 v2：同上——分页模式惯性跨章过冷却闸门，拦同一手势的二次跨章。
      if (throttleMs > 0 && _chapterTurnCoolingDown()) return;
      _noteChapterTurnInput();
      _handlePageTurnLimit(direction.jsValue, inertia: throttleMs > 0);
    }
  }

  // ── Image Viewer ──────────────────────────────────────────────────

  File? _readerImageFileForUrl(String imgUrl) {
    final Uri? uri = Uri.tryParse(imgUrl);
    if (uri == null || _extractDir == null) return null;
    if (uri.host != ReaderHibikiSource.kHost) return null;
    if (!uri.path.startsWith('/epub/')) return null;
    final String epubPath =
        Uri.decodeComponent(uri.path.substring('/epub/'.length));
    final String extractRoot = p.canonicalize(_extractDir!);
    final String filePath = p.canonicalize(p.join(extractRoot, epubPath));
    if (!p.isWithin(extractRoot, filePath)) {
      return null;
    }
    final File file = File(filePath);
    if (!file.existsSync()) return null;
    return file;
  }

  Future<void> _showReaderImageContextMenu(
    String imgUrl,
    Offset webViewOffset,
  ) async {
    if (!mounted) return;
    if (!isWindowsPlatform) {
      await _shareReaderImage(imgUrl);
      return;
    }
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset global = box?.localToGlobal(webViewOffset) ?? webViewOffset;
    await _showReaderImageContextMenuAtGlobalPosition(imgUrl, global);
  }

  Future<void> _showReaderImageContextMenuAtGlobalPosition(
    String imgUrl,
    Offset globalPosition, {
    BuildContext? menuContext,
  }) async {
    if (!mounted || !isWindowsPlatform) return;
    final BuildContext effectiveContext = menuContext ?? context;
    final RenderBox overlay =
        Overlay.of(effectiveContext).context.findRenderObject()! as RenderBox;
    final double menuScale = _readerImageMenuScale;
    // BUG-381: [globalPosition] 是真实屏幕坐标（右键路径来自阅读器 State 的 RenderBox
    // localToGlobal，放大图路径来自 details.globalPosition；两者都在「净缩放=1 的真实
    // 视口空间」——阅读器被 HibikiAppUiScaleNeutralizer 中和回 1.0）。但 showMenu 的
    // RelativeRect 落在它路由 Overlay 的坐标系，而该 Overlay 在全局 HibikiAppUiScale 的
    // FittedBox 之内（缩放后的画布空间）。直接把真实屏幕坐标当画布坐标喂给 showMenu，
    // 界面大小≠100% 时菜单会偏离图片 factor≈scale（BUG-261 同型，视频右键已修）。
    //
    // 修法与 BUG-129/261 同范式：不读 scale 数值逆算（自动模式下生效 scale ≠
    // appModel.appUiScale），而用 Overlay 的 RenderBox 把锚点从真实屏幕坐标沿真实渲染
    // 变换链映射到 Overlay 本地坐标系——其间的 FittedBox 缩放被 render transform 自动
    // 吸收，对任意 scale（含自动模式）自洽无残差；scale=1 时变换为单位阵，逐像素等价
    // （向后兼容）。菜单内容缩放（menuScale）是另一回事，保持不动。
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final String? action = await showMenu<String>(
      context: effectiveContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints(
        minWidth: 112.0 * menuScale,
        maxWidth: 280.0 * menuScale,
      ),
      menuPadding: EdgeInsets.symmetric(vertical: 8.0 * menuScale),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy',
          height: kMinInteractiveDimension * menuScale,
          padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.copy_outlined, size: 18.0 * menuScale),
              SizedBox(width: 12.0 * menuScale),
              Text(
                t.reader_copy_image,
                style: TextStyle(fontSize: 14.0 * menuScale),
              ),
            ],
          ),
        ),
      ],
    );
    if (action == 'copy') {
      await _copyReaderImageToClipboard(imgUrl);
    }
  }

  // TODO-954：阅读器文字选区右键菜单（Windows）。完全复用图片右键的「锚点经 Overlay
  // RenderBox 映射 + menuScale 只缩放菜单自身」范式（见上方 BUG-381 长注释），让查词/
  // 复制/导出三项随界面大小缩放，而鼠标锚点与 WebView 命中测试不受影响。导出项仅在本书
  // 有音频 cue 时出现；其它两项恒在。
  Future<void> _showReaderTextContextMenu(Offset globalPosition) async {
    if (!mounted || !isWindowsPlatform || _readerTextContextMenuActive) {
      return;
    }
    // onSecondaryTapDown does not await this Future. Gate before the first JS
    // await so repeated right-clicks cannot stack multiple PopupMenuRoutes.
    _readerTextContextMenuActive = true;
    try {
      // 没有原生选区文本就不弹菜单（右键空白处不打扰）。
      // 本方法从 onSecondaryTapDown fire-and-forget 调用，异常会逃出当前 zone 被记为
      // fatal（main.dart runZonedGuarded）——WebView 半销毁 / 插件通道异常时右键
      // evaluateJavascript 会抛 PlatformException / MissingPluginException，表现为闪退。
      // 与孪生的 _fillLookupStateFromNativeSelection / _copyNativeSelectionToClipboard
      // 同款：eval 必须 try/catch 吞掉。BUG-927。
      Object? rawText;
      try {
        rawText = await _controller?.evaluateJavascript(
          source: ReaderSelectionScripts.nativeSelectionTextInvocation(),
        );
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderHibiki.showReaderTextContextMenu', e, stack);
        return;
      }
      final String selectedText =
          ReaderSelectionScripts.nativeSelectionTextFromResult(rawText);
      if (selectedText.isEmpty) return;
      if (!mounted) return;

      // A native WebView2 popup surface is above Flutter routes on Windows. Move
      // it back to the warm slot before opening the Flutter context menu; pruning
      // does not clear the reader's native text selection.
      _webviewPrunePopupStack(0);

      final RenderBox overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final double menuScale = _readerImageMenuScale;
      final Offset anchor = overlay.globalToLocal(globalPosition);

      final bool hasAudio = _audiobookController != null &&
          _audiobookController!.chapterCueCount > 0;

      final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'search',
          height: kMinInteractiveDimension * menuScale,
          padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.search_outlined, size: 18.0 * menuScale),
              SizedBox(width: 12.0 * menuScale),
              Text(t.search, style: TextStyle(fontSize: 14.0 * menuScale)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          height: kMinInteractiveDimension * menuScale,
          padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.copy_outlined, size: 18.0 * menuScale),
              SizedBox(width: 12.0 * menuScale),
              Text(t.copy, style: TextStyle(fontSize: 14.0 * menuScale)),
            ],
          ),
        ),
        // BUG-854：选区菜单补「收藏」——与桌面底栏 / 查词弹窗顶栏的收藏句子
        // （`_toggleFavoriteSentence`）同一后端，仅入口不同。触屏从不建原生选区
        // （TODO-1279），旧菜单只有查词 / 复制 / 导出，无从收藏当前句；此项填平缺口。
        PopupMenuItem<String>(
          value: 'favorite',
          height: kMinInteractiveDimension * menuScale,
          padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.star_border, size: 18.0 * menuScale),
              SizedBox(width: 12.0 * menuScale),
              Text(t.action_favorite,
                  style: TextStyle(fontSize: 14.0 * menuScale)),
            ],
          ),
        ),
        if (hasAudio)
          PopupMenuItem<String>(
            value: 'export',
            height: kMinInteractiveDimension * menuScale,
            padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.movie_creation_outlined, size: 18.0 * menuScale),
                SizedBox(width: 12.0 * menuScale),
                Text(t.audiobook_export_clip,
                    style: TextStyle(fontSize: 14.0 * menuScale)),
              ],
            ),
          ),
      ];

      final String? action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
          Offset.zero & overlay.size,
        ),
        constraints: BoxConstraints(
          minWidth: 112.0 * menuScale,
          maxWidth: 280.0 * menuScale,
        ),
        menuPadding: EdgeInsets.symmetric(vertical: 8.0 * menuScale),
        items: items,
      );
      if (!mounted) return;
      switch (action) {
        case 'search':
          final size = MediaQuery.of(context).size;
          final Rect rect = Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 3),
            width: 1,
            height: 1,
          );
          _webviewPrunePopupStack(0);
          // BUG-455：右键查词不经 tap（_handleTextSelected），必须显式把原生选区写进查词
          // 状态，否则弹窗顶栏「收藏句子」读 currentSentence 为空 → 误报「未选择句子」。
          // 句级解析失败（无 norm 区间）也要满足非空契约：退回选中文本本身。
          final ReaderSelectionData? sel =
              await _fillLookupStateFromNativeSelection();
          if (!mounted) return;
          if (sel == null) {
            appModel.currentMediaSource?.setCurrentSentence(
              selection: HibikiTextSelection(text: selectedText),
            );
          }
          await searchDictionaryResult(
              searchTerm: selectedText, selectionRect: rect);
          if (mounted) _checkFavoriteStatus();
          return;
        case 'copy':
          await Clipboard.setData(ClipboardData(text: selectedText));
          HibikiToast.show(msg: t.copied_to_clipboard);
          // 复制是终结动作：清掉刻意保留的原生选区，和移动端拖选菜单的 'copy'
          // （_clearReaderAppSelection）对齐。否则残留的原生蓝色选区会一直卡住后续
          // 查词（见 webview.part.dart pointerup 里对 nativeMoved 的处理）。BUG-927。
          await _clearReaderAppSelection();
          return;
        case 'favorite':
          // BUG-854：右键收藏也走「原生选区 → 查词状态」补写（与 search 同源），确保
          // _toggleFavoriteSentence 读到的 currentSentence / 句级区间非空；解析失败退回
          // 选中文本本身满足非空契约。
          final ReaderSelectionData? favSel =
              await _fillLookupStateFromNativeSelection();
          if (!mounted) return;
          if (favSel == null) {
            appModel.currentMediaSource?.setCurrentSentence(
              selection: HibikiTextSelection(text: selectedText),
            );
          }
          await _toggleFavoriteSentence();
          return;
        case 'export':
          await _exportAudiobookClipFromSelection();
          return;
        default:
          return;
      }
    } finally {
      _readerTextContextMenuActive = false;
    }
  }

  // TODO-1317：移动端「长按拖选」松手后弹的选区菜单（复制 / 查词）。BUG-609 把拖选松手直接
  // 送去查词，丢了「选中一段文本区间复制」的原有能力（用户报「长按没有选择了，变成长按选择
  // 文字查词了」）。这里让拖选出的 app 自绘选区（`window.hoshiSelection.selection`，非原生
  // 选区，不复活 TODO-1279 掉的双选区）在松手后弹菜单：选「复制」把整段选区文本进剪贴板，选
  // 「查词」复用 tap 查词的 [_handleTextSelected]（查词弹窗内含制卡）。两者共存，不再二选一
  // 只剩查词。锚点用与图片右键同一套「WebView 局部坐标经 [_webViewKey] RenderBox ->
  // 全局 -> Overlay 本地」映射（BUG-381 范式，界面缩放被渲染变换链自动吸收）。菜单被取消或
  // 复制完都清掉 app 选区高亮；查词路径由 [_handleTextSelected] 自行收敛到词典匹配长度。
  Future<void> _handleSelectionMenu(ReaderSelectionData data) async {
    if (!mounted) return;
    if (data.text.isEmpty) {
      await _clearReaderAppSelection();
      return;
    }

    final RenderBox? webBox =
        _webViewKey.currentContext?.findRenderObject() as RenderBox?;
    final Map<String, double>? r = data.rect;
    // Anchor just below the selection's start glyph (WebView-local coords).
    final Offset localAnchor = r != null
        ? Offset(r['x'] ?? 0, (r['y'] ?? 0) + (r['height'] ?? 0))
        : Offset(
            MediaQuery.of(context).size.width / 2,
            MediaQuery.of(context).size.height / 2,
          );
    final Offset global = webBox?.localToGlobal(localAnchor) ?? localAnchor;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset anchor = overlay.globalToLocal(global);
    final double menuScale = _readerImageMenuScale;

    // TODO-1366: mobile drag-select "export clip" -- same gate (book has audio
    // cues) and same backend as the desktop right-click / native ActionMode
    // menus, driven from the app-drawn selection payload instead of a native
    // selection (mobile touch never builds one, TODO-1279).
    final bool hasAudio = _audiobookController != null &&
        _audiobookController!.chapterCueCount > 0;
    final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: 'search',
        height: kMinInteractiveDimension * menuScale,
        padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.search_outlined, size: 18.0 * menuScale),
            SizedBox(width: 12.0 * menuScale),
            Text(t.search, style: TextStyle(fontSize: 14.0 * menuScale)),
          ],
        ),
      ),
      PopupMenuItem<String>(
        value: 'copy',
        height: kMinInteractiveDimension * menuScale,
        padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.copy_outlined, size: 18.0 * menuScale),
            SizedBox(width: 12.0 * menuScale),
            Text(t.copy, style: TextStyle(fontSize: 14.0 * menuScale)),
          ],
        ),
      ),
      // BUG-854：选区菜单补「收藏」——与桌面底栏 / 查词弹窗顶栏的收藏句子
      // （`_toggleFavoriteSentence`）同一后端，仅入口不同。触屏从不建原生选区
      // （TODO-1279），旧菜单只有查词 / 复制 / 导出，无从收藏当前句；此项填平缺口。
      PopupMenuItem<String>(
        value: 'favorite',
        height: kMinInteractiveDimension * menuScale,
        padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.star_border, size: 18.0 * menuScale),
            SizedBox(width: 12.0 * menuScale),
            Text(t.action_favorite,
                style: TextStyle(fontSize: 14.0 * menuScale)),
          ],
        ),
      ),
      if (hasAudio)
        PopupMenuItem<String>(
          value: 'export',
          height: kMinInteractiveDimension * menuScale,
          padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.movie_creation_outlined, size: 18.0 * menuScale),
              SizedBox(width: 12.0 * menuScale),
              Text(t.audiobook_export_clip,
                  style: TextStyle(fontSize: 14.0 * menuScale)),
            ],
          ),
        ),
    ];

    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints(
        minWidth: 112.0 * menuScale,
        maxWidth: 280.0 * menuScale,
      ),
      menuPadding: EdgeInsets.symmetric(vertical: 8.0 * menuScale),
      items: items,
    );
    if (!mounted) return;
    switch (action) {
      case 'search':
        // Reuse the tap lookup pipeline verbatim: the drag payload IS a
        // ReaderSelectionData, so currentSentence / cue / highlight convergence
        // / popup all behave exactly like a tap-word lookup. The grips are for
        // adjusting the range before lookup; once we converge to the matched
        // word they no longer describe the selection, so drop the grips (the
        // converged highlight stays for the popup).
        await _hideReaderSelectionHandles();
        await _handleTextSelected(data);
        return;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: data.text));
        HibikiToast.show(msg: t.copied_to_clipboard);
        await _clearReaderAppSelection();
        return;
      case 'favorite':
        // BUG-854：拖选是 app 自绘选区（无原生选区），从菜单 payload 填查词状态
        // （currentSentence 非空契约 + 句级区间），与「导出片段」共用
        // _fillLookupStateFromSelectionData，再走既有收藏句子后端；收藏完清掉选区高亮。
        await _fillLookupStateFromSelectionData(data,
            extractNativeImages: false);
        await _toggleFavoriteSentence();
        await _clearReaderAppSelection();
        return;
      case 'export':
        // TODO-1366: same backend as desktop (_exportAudiobookClip) but fed from
        // the app-drawn selection payload; clear grips + highlight afterward.
        await _exportAudiobookClipFromSelectionData(data);
        await _clearReaderAppSelection();
        return;
      default:
        // TODO-1366: dismissing the menu no longer cancels the selection -- keep
        // the highlight + grips live so the user can drag a handle to adjust the
        // range and re-open the menu (lookup only on an explicit confirm). Any
        // later tap clears it: tap on text -> selectText clears + looks up; tap
        // on empty -> onTapEmpty -> _clearReaderAppSelection.
        return;
    }
  }

  // Clear the reader's app-drawn selection (hoshi-selection CSS Custom Highlight)
  // without touching any native selection. Best-effort: a half-torn-down WebView
  // throws MissingPluginException on eval; swallow it (nothing to clear).
  Future<void> _clearReaderAppSelection() async {
    try {
      await _controller?.evaluateJavascript(
        source: ReaderSelectionScripts.clearInvocation(),
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.clearReaderAppSelection', e, stack);
    }
  }

  // TODO-954 / BUG-455：把当前**原生选区**（`window.getSelection()`）解析成与 tap 查词
  // （onTextSelected → [_handleTextSelected]）等价的查词状态——currentSentence /
  // [_lookupCue] / [_cachedSelectionRange] / [_cachedSentenceRange] /
  // [_cachedSentenceOffset]，但**不**触发 highlight / 弹窗 / 暂停。右键「查词」「导出片段」
  // 与移动端原生菜单「查词」都不经 tap 查词，必须显式补这套状态，否则：导出读不到 cue 区间；
  // 查词弹窗顶栏「收藏句子」读 currentSentence 为空 → 误报「未选择句子」(BUG-455)。
  // 用 [ReaderSelectionScripts.nativeSelectionSentenceRangeInvocation] 从原生选区端点算句级
  // normOffset/normLength（复用 tap 路径同一套 JS）；currentSentence 经
  // [ReaderSelectionScripts.resolveCurrentSentenceText] 保证非空（句子优先、派生不出退回
  // 选中词）。返回解析出的 [ReaderSelectionData]；无选区 / 选区文本为空时返回 null（调用方
  // 据此走各自的空选区兜底，查词路径再对 null 退回选中文本本身补满非空契约）。
  Future<ReaderSelectionData?> _fillLookupStateFromNativeSelection() async {
    Object? raw;
    try {
      raw = await _controller?.evaluateJavascript(
        source: ReaderSelectionScripts.nativeSelectionSentenceRangeInvocation(),
      );
    } catch (e, stack) {
      // BUG-005 同根因（TODO-678）：半销毁 WebView / window.hoshiSelection 未注入时
      // eval 抛 MissingPluginException / TypeError，且本方法被菜单 fire-and-forget 调用，
      // 异常会逃当前 zone。失败退回 null —— 菜单「查词」调用方据此用 selectedText 兜底
      // 补满 currentSentence 非空契约，导出路径走空选区文案。
      ErrorLogService.instance.log(
          'ReaderHibiki.fillLookupStateFromNativeSelection.eval', e, stack);
      return null;
    }
    if (!mounted) return null;
    Map<String, dynamic>? json;
    if (raw is String) {
      final String trimmed = raw.trim();
      if (trimmed.isNotEmpty && trimmed != 'null') {
        try {
          final Object? decoded = jsonDecode(trimmed);
          if (decoded is Map) json = Map<String, dynamic>.from(decoded);
        } catch (_) {
          json = null;
        }
      }
    } else if (raw is Map) {
      json = Map<String, dynamic>.from(raw);
    }
    if (json == null) return null;
    final ReaderSelectionData data = ReaderSelectionData.fromJson(json);
    if (data.text.isEmpty) return null;

    // TODO-1366：状态填充与移动端拖选菜单「导出片段」共用 _fillLookupStateFromSelectionData
    // （currentSentence 非空契约 + cue + 归一化区间 + 章号）。原生选区路径的选区此刻仍在，
    // 故抽取选区夹带插图（extractNativeImages: true）；移动端自绘拖选无原生选区，传 false。
    await _fillLookupStateFromSelectionData(data, extractNativeImages: true);
    return data;
  }

  /// TODO-1366：把一个已解析的 [ReaderSelectionData]（tap 查词 / 移动端拖选菜单 payload /
  /// 原生选区解析结果同构）填进导出/查词所需的选区状态——currentSentence（非空契约）、
  /// [_lookupCue]、[_cachedSelectionRange]、[_cachedSentenceRange]、[_cachedSentenceOffset]、
  /// [_cachedSelectionSectionIndex]——但**不**触发 highlight / 弹窗 / 暂停。
  /// [extractNativeImages] 为 true 时（右键 / 原生 ActionMode 菜单，选区仍是原生选区）额外
  /// 抽取选区夹带的 EPUB 插图；移动端自绘拖选无原生选区，传 false → 插图列表清空（不泄漏
  /// 上一次原生选区抽出的图）。
  Future<void> _fillLookupStateFromSelectionData(
    ReaderSelectionData data, {
    required bool extractNativeImages,
  }) async {
    // currentSentence 非空契约（与 lookup.part.dart tap 写点一致）：句子优先、退回选中词。
    appModel.currentMediaSource?.setCurrentSentence(
      selection: HibikiTextSelection(
        text: ReaderSelectionScripts.resolveCurrentSentenceText(
          data.sentence,
          data.text,
        ),
      ),
    );
    _cachedSentenceOffset = data.sentenceOffset;
    _lookupCue = data.normalizedOffset != null
        ? _findCueForOffset(data.normalizedOffset!)
        : null;
    if (_lookupCue == null && _srtBookUid != null) {
      _lookupCue = _findCueForSentence(data.sentence);
    }
    _cachedSelectionRange =
        (data.normalizedOffset != null && data.normalizedLength != null)
            ? (
                offset: data.normalizedOffset!,
                length: data.normalizedLength!,
                text: data.text,
              )
            : null;
    _cachedSentenceRange = (data.sentenceNormalizedOffset != null &&
            data.sentenceNormalizedLength != null)
        ? (
            offset: data.sentenceNormalizedOffset!,
            length: data.sentenceNormalizedLength!,
          )
        : null;
    // BUG-492：选区路径同样锁定所属章号（详见 _cachedSelectionSectionIndex）。
    _cachedSelectionSectionIndex = _lookupSectionIndex;
    // TODO-1127：与选区状态同批抽取选区里夹带的 EPUB 插图（供片段导出把图渲进卡片）。
    _cachedSelectionImages = extractNativeImages
        ? await _extractSelectionClipImages()
        : const <({int normOffset, Uint8List bytes})>[];
  }

  /// TODO-1366：移动端拖选菜单「导出片段」。拖选是 app 自绘选区（无原生选区），故从菜单
  /// payload [data]（含句级 normOffset/normLength，与 tap / 原生选区同构）填状态，再走既有
  /// [_exportAudiobookClip] 导出链（四类边界兜底：空选区 / 无音频 / 跨章跨文件 / 可导出
  /// 原样生效）。与桌面右键 / 原生 ActionMode 的「导出片段」共用同一后端动作。
  Future<void> _exportAudiobookClipFromSelectionData(
      ReaderSelectionData data) async {
    if (data.text.isEmpty) {
      HibikiToast.show(msg: t.audiobook_export_clip_no_text);
      return;
    }
    await _fillLookupStateFromSelectionData(data, extractNativeImages: false);
    if (!mounted) return;
    _exportAudiobookClip();
  }

  /// TODO-1366：只隐藏拖选起止手柄（不清选区 / 高亮）——查词收敛到匹配词后，手柄不再描述
  /// 整段拖选区间，隐藏它们但保留收敛后的查词高亮供弹窗用。半销毁 WebView 上 eval 抛异常，
  /// 吞掉（无手柄可隐藏）。
  Future<void> _hideReaderSelectionHandles() async {
    try {
      await _controller?.evaluateJavascript(
        source: 'window.hoshiSelection.hideSelectionHandles()',
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.hideReaderSelectionHandles', e, stack);
    }
  }

  /// TODO-1127：从**当前原生选区**抽取夹带的 EPUB 插图字节（供片段导出渲进卡片）。
  /// JS `nativeSelectionImages` 返回图的绝对 URL + 归一化文档位置；这里把每个 URL 经
  /// [_readerImageFileForUrl] 解析成解压目录文件（**不走网络**），读字节、按需降采样
  /// （复用 [downsampleCardScreenshot] 护体积）。裸矢量 `.svg` 文件 `Image.memory` 无法
  /// 解码 → 跳过并记日志（光栅封面 <svg><image> 的内层位图已由 JS 侧解析为真实位图 URL）。
  Future<List<({int normOffset, Uint8List bytes})>>
      _extractSelectionClipImages() async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) {
      return const <({int normOffset, Uint8List bytes})>[];
    }
    Object? raw;
    try {
      raw = await controller.evaluateJavascript(
        source: ReaderSelectionScripts.nativeSelectionImagesInvocation(),
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.extractSelectionClipImages.eval', e, stack);
      return const <({int normOffset, Uint8List bytes})>[];
    }
    if (!mounted) return const <({int normOffset, Uint8List bytes})>[];
    final List<({String src, int normOffset})> refs =
        ReaderSelectionScripts.clipSelectionImagesFromResult(raw);
    if (refs.isEmpty) return const <({int normOffset, Uint8List bytes})>[];
    final List<({int normOffset, Uint8List bytes})> images =
        <({int normOffset, Uint8List bytes})>[];
    for (final ({String src, int normOffset}) ref in refs) {
      final File? file = _readerImageFileForUrl(ref.src);
      if (file == null) continue;
      final String ext = p.extension(file.path).toLowerCase();
      if (ext == '.svg') {
        // 裸矢量 SVG：Image.memory 不解码矢量图，跳过（光栅封面内层位图另由 JS 解析）。
        ErrorLogService.instance.log(
          'ReaderHibiki.extractSelectionClipImages.skipSvg',
          'skip vector SVG clip image (Image.memory cannot decode): '
              '${file.path}',
          StackTrace.current,
        );
        continue;
      }
      try {
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        // 降采样护体积（长边 1000px / JPEG q90，与制卡截图同档）；小图/无法解码时
        // downsampleCardScreenshot 原样返回，绝不把有效插图变空。BUG-933：解码/编码
        // 卸到后台 isolate，避免逐张插图的纯 Dart CPU 阻塞 UI。
        final Uint8List downsampled =
            await downsampleCardScreenshotAsync(bytes);
        images.add((normOffset: ref.normOffset, bytes: downsampled));
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderHibiki.extractSelectionClipImages.read', e, stack);
      }
    }
    return images;
  }

  // TODO-954：从当前**原生选区**解析句级 cue 区间后走既有导出链 [_exportAudiobookClip]。
  // 右键导出没经过 tap 查词（onTextSelected），故先经 [_fillLookupStateFromNativeSelection]
  // 把 _lookupCue / _cachedSelectionRange / _cachedSentenceRange / currentSentence 填成与
  // tap 路径同样的状态（不含 highlight / popup / 暂停）——导出与查词解耦正是本 TODO 的诉求——
  // 让 [_exportAudiobookClip] 的四类边界兜底（空选区 / 无音频 / 跨章跨文件 / 可导出）原样生效。
  Future<void> _exportAudiobookClipFromSelection() async {
    final ReaderSelectionData? data =
        await _fillLookupStateFromNativeSelection();
    if (!mounted) return;
    if (data == null) {
      // 无选区 / 解析失败：走与 _exportAudiobookClip 空选区分支一致的兜底文案。
      HibikiToast.show(msg: t.audiobook_export_clip_no_text);
      return;
    }
    _exportAudiobookClip();
  }

  Future<void> _shareReaderImage(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await HibikiShare.shareFiles(
        <XFile>[XFile(file.path, mimeType: fallbackMimeType(file.path))],
        subject: p.basename(file.path),
      );
    } catch (e) {
      HibikiToast.show(msg: t.reader_image_share_failed(error: e));
    }
  }

  Future<void> _copyReaderImageToClipboard(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await HibikiChannels.clipboardImage.invokeMethod<void>(
        'copyImageFile',
        <String, String>{'path': file.path},
      );
      HibikiToast.show(msg: t.copied_to_clipboard);
    } catch (e) {
      HibikiToast.show(msg: t.reader_image_copy_failed(error: e));
    }
  }

  void _openImageViewer(String imgUrl) {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) return;
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor:
            Theme.of(context).colorScheme.scrim.withValues(alpha: 0.87),
        barrierDismissible: true,
        pageBuilder: (BuildContext routeContext, __, ___) => GestureDetector(
          onTap: () => Navigator.pop(context),
          onSecondaryTapDown: isWindowsPlatform
              ? (TapDownDetails details) {
                  unawaited(
                    _showReaderImageContextMenuAtGlobalPosition(
                      imgUrl,
                      details.globalPosition,
                      menuContext: routeContext,
                    ),
                  );
                }
              : null,
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 10,
            child: Center(
              child: Image.file(file, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  // ── Illustration Gallery (TODO-723) ───────────────────────────────────
  // Browse every image in the book in reading order, with the image(s) in the
  // current chapter marked, scrolled into view on open. Tapping a thumbnail
  // reuses [_openImageViewer] (no second zoom path); "jump to this illustration"
  // reuses [_navigateToChapter] (no second navigation path). Reads
  // [_currentChapter] only -- never writes reader/WebView state.

  void _openGallery() {
    final EpubBook? book = _book;
    if (book == null) return;
    final List<EpubImageRef> images = book.images;
    final int currentChapter = _currentChapter;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext routeContext) => _ReaderGalleryPage(
          images: images,
          currentChapter: currentChapter,
          fileForRef: (EpubImageRef ref) =>
              _readerImageFileForUrl(ReaderHibikiSource.epubUrl(ref.src)),
          onOpenImage: (EpubImageRef ref) =>
              _openImageViewer(ReaderHibikiSource.epubUrl(ref.src)),
          onJumpTo: (EpubImageRef ref) {
            Navigator.pop(routeContext);
            unawaited(_navigateToChapter(ref.chapterIndex, manual: true));
          },
        ),
      ),
    );
  }

  // ── Media Notification ────────────────────────────────────────────
  // TODO-291 阶段2：媒体通知的 cue/播放态同步已上移到 [AudiobookSession] 常驻执行。
  // reader 只保留设置开关，翻转后委托 session 装/清通知卡片。

  Future<void> _toggleMediaNotification() async {
    final bool newValue = !appModel.showMediaNotification;
    await appModel.setShowMediaNotification(newValue);
    appModel.audiobookSession.onMediaNotificationToggled(enabled: newValue);
  }

  // ── Bottom Chrome ─────────────────────────────────────────────────

  void _toggleChrome() {
    _rebuild(() {
      _showChrome = !_showChrome;
    });
    _applyChromeInsets();
    // BUG-712 ①：chrome 可见性是 JS 侧点词门控镜像的一半，翻转即同步。
    _syncTapGateJs();
    // TODO-700 T8: the bottom chrome bar is wrapped in ExcludeFocus (see
    // [_buildAudiobookBar]/[_buildSettingsBar]), so its controls are never
    // focus-traversal targets — focus always lives on the reading content
    // ([_focusNode]). Showing the bar must NOT move focus into it (the old
    // `moveFocusToChrome` path is gone): the bar is a touch/mouse + key-glyph
    // surface, not a directional-nav destination. Keeping focus on the content
    // means directional keys keep turning the page and hidden shortcuts are
    // never short-circuited by a focused bar. The reclaim is a cheap no-op when
    // the content already holds focus.
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  Future<void> _applyChromeInsets() async {
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    // TODO-975：底栏预留经单一真相源 _readerBottomReserve（悬浮态恒 0、挤压态含底栏高
    // + 系统 inset），取代散落的 `_showChrome ? height+inset : inset` 三元式。
    final double top = _readerTopOffset;
    final double bottom = _readerBottomReserve;
    await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.setChromeInsetsInvocation(top, bottom),
    );
    if (!mounted || _controller == null) return;
    // Keep the cursor's "is on the current page" viewport in sync with the chrome
    // (it changes the usable bottom inset) so the next enter()/move() lands inside
    // the visible page, and re-measure the ring for the reflow.
    await _controller!.evaluateJavascript(
      source: ReaderCaretScripts.initInvocation(
        color: _caretRingColorCss(),
        insetTop: top,
        insetBottom: bottom,
      ),
    );
    await _caretRefresh();
  }

  /// BUG-467（TODO-975 回归修复）：内容首次就绪时确定性补下一次 chrome insets。
  ///
  /// 根因——底栏预留 [_bottomChromeReserve] 经 TODO-975 改为门控 `_hasEverLoaded &&
  /// _showChrome`，但**初始 WebView HTML** 在 [_buildWebView] 里用 `chromeBottomInset:
  /// _readerBottomReserve` 求值时 `_hasEverLoaded` 仍为 false → 初始 HTML 只预留了系统
  /// 底 inset（多数桌面/手势导航机为 0），把底栏高度漏掉。TODO-975 之前的旧式
  /// `_showChrome ? _readerChromeHeight + _stableBottomInset : _stableBottomInset`
  /// 不依赖 `_hasEverLoaded`、`_showChrome` 默认 true，故首屏即正确预留；而内容就绪后
  /// （`_hasEverLoaded` 翻 true）又**没有任何代码重下 chrome insets**，于是 WebView 永远
  /// 停在「底栏未预留」状态——正文列（尤其竖排 vertical-rl，字形沿物理纵轴流到屏底）
  /// 直接画进底栏区域（BUG-467「文字去到底栏」）。
  ///
  /// 修复：在每个内容首次就绪的落点（`_hasEverLoaded` 翻 true 处）补一次
  /// [_applyChromeInsets]，把此刻已正确的 [_readerBottomReserve]（含底栏高）下发给
  /// WebView。幂等且零行为变化于 975 语义——悬浮态仍预留 0、关进度仍 0，因为读的还是
  /// 同一组派生 getter；只是把「内容就绪后从未补发」这个漏洞补上。歌词模式由
  /// [_applyChromeInsets] 自身的 `_lyricsMode` 早返回挡掉（歌词走 Flutter 侧 padding）。
  void _reapplyChromeInsetsAfterFirstLoad() {
    unawaited(_applyChromeInsets().catchError((Object e, StackTrace s) {
      ErrorLogService.instance
          .log('ReaderHibiki.reapplyChromeInsetsAfterFirstLoad', e, s);
    }));
  }

  /// TODO-975：预留高发生变化（开/关顶部进度、挤压↔悬浮切换）后，先下发新 chrome
  /// insets，再走样式重锚编排保住连续模式滚动位置。复用 [_reanchorForStyleChange]
  /// 的两阶段 begin→commit + `_reanchorPending` 串行旗（传当前样式 JSON，begin 重设
  /// CSS 是幂等的），避免裸改 inset 引发的 reflow 把 window.scrollY 归零弹回章首。
  /// 分页模式 JS 侧整体 no-op，连续模式才真重锚（与现有重锚路径门控一致）。
  Future<void> _applyChromeInsetsAndReanchor() async {
    await _applyChromeInsets();
    if (!mounted || _controller == null || _settings == null || _lyricsMode) {
      return;
    }
    await _reanchorForStyleChange(_currentStyleJson());
  }

  // ── Floating chrome reveal / auto-hide (TODO-975) ─────────────────────
  // 悬浮模式（顶部进度 / 底栏）：点击唤出 → 临时可见 + 武装定时器 → 计时到自动收起；
  // 唤出期间再点一下立即收起（决策#4：不续命）。改 _chromeTransientVisible 不改预留高
  // （悬浮恒 0），故纯显隐不重锚。挤压模式不调用这套（无 timer）。

  void _cancelChromeAutoHide() {
    _chromeAutoHideTimer?.cancel();
    _chromeAutoHideTimer = null;
  }

  void _armChromeAutoHide() {
    _cancelChromeAutoHide();
    final int millis = ReaderHibikiSource.instance.autoHideChromeMillis;
    _chromeAutoHideTimer = Timer(Duration(milliseconds: millis), () {
      if (!mounted) return;
      _rebuild(() {
        _chromeTransientVisible = false;
      });
    });
  }

  /// 点击空白 / 顶部进度时调用（仅当存在任一悬浮 chrome）。可见时立即收起（决策#4），
  /// 隐藏时唤出 + 武装自动收起。返回 true 表示本次点击被悬浮唤出/收起逻辑消费。
  bool _handleFloatingChromeReveal() {
    if (!_anyChromeFloating) return false;
    if (_chromeTransientVisible) {
      _cancelChromeAutoHide();
      _rebuild(() {
        _chromeTransientVisible = false;
      });
      return true;
    }
    _rebuild(() {
      _chromeTransientVisible = true;
    });
    _armChromeAutoHide();
    return true;
  }

  /// TODO-693: appUiScale（整体界面缩放）变化时把连续模式阅读位置重锚回原字符，避免
  /// 弹回章节开头。
  ///
  /// 根因：连续模式阅读位置是裸 `window.scrollY`，没有分页模式的
  /// `registerSnapScroll`/`lockRootViewport` 保护。HibikiAppUiScale 用新 scale 重建两层
  /// FittedBox/SizedBox → reader 子树（含 WebView 平台视图）box.size 过渡帧抖动 → 击穿
  /// SetSizeDedup → native put_Bounds → WebView2 reflow 把 document scrollY 瞬时归 0；
  /// 归零后连续模式无任何机制拉回，于是被章内 scroll 回传通道（onReaderScroll）当作真实
  /// 滚动落库 progress≈0 → 弹回章节开头。
  ///
  /// 方案（镜像 JS 侧 setChromeInsets 的 `_reanchorPending` 串行契约，Dart 两阶段编排）：
  /// 1. 在缩放重建那一帧**同步**采样首个可见字符偏移并置 `_reanchorPending`
  ///    （[ReaderPaginationScripts.beginUiScaleReanchorInvocation]）——置旗挡住 reflow
  ///    自发的归零 scroll 经 webview.part.dart 的 `_reanchorPending` 守卫不再回传，
  ///    污染不到 `_lastProgressValue`/落库。
  /// 2. 等过渡帧 settle（box.size 是 FittedBox 逐帧过渡，单帧 rAF 不保证稳定，沿用
  ///    [_syncPageSize] 的 `addPostFrameCallback` settle 时机）后把锚滚回视口首边并清旗
  ///    （[ReaderPaginationScripts.commitUiScaleReanchorInvocation]）。
  ///
  /// 门控（与 [_syncPageSize] / [_applyChromeInsets] / [_refreshProgress] 一致）：控制器
  /// 释放 / 内容未就绪 / 歌词模式 / 恢复期（`_restoreInFlight`）/ 分页模式都不触发。分页
  /// 模式即使误调，JS 侧 `beginUiScaleReanchor` 在分页 `window.hoshiReader` 缺席，
  /// `typeof` 守卫使其整体 no-op。
  Future<void> _reanchorContinuousForUiScale() {
    // 实际两阶段编排（门控 → begin → intResult → postFrame → commit）抽到 top-level
    // [runUiScaleReanchorOrchestration]，用回调注入 WebView 求值 / postFrame 调度 /
    // 存活复检 / 错误上报，使其能在 headless 单测下真执行（TODO-697）。这里只负责把本
    // State 的实例字段绑进那些回调，行为与原内联实现逐句等价。
    return runUiScaleReanchorOrchestration(
      // 运行中改缩放：门控含 !restoreInFlight 早返回（恢复期程序化滚动中不重锚）。
      gateAllowed: readerUiScaleReanchorAllowed(
        controllerAvailable: _controller != null,
        readerContentReady: _readerContentReady,
        lyricsMode: _lyricsMode,
        restoreInFlight: _restoreInFlight,
        continuousMode: _settings?.isContinuousMode == true,
      ),
      // 阶段 1：同步采样锚 + 置旗。必须先于过渡帧落地，使后续 reflow 归零 scroll 被
      // _reanchorPending 守卫挡在落库之外。
      evalBegin: () => _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.beginUiScaleReanchorInvocation(),
      ),
      // 阶段 2：等过渡帧 settle 后提交滚动并清旗，并打 _reanchorClearedAt 武装 B-3 窗。
      evalCommit: () async {
        await _controller!.evaluateJavascript(
          source: ReaderPaginationScripts.commitUiScaleReanchorInvocation(),
        );
        // TODO-797 同根因 sibling：appUiScale 缩放（TODO-693）重锚 commit 清旗后的 settle 尾沿与
        // 恢复重锚同样会被 reflow 归零落库 progress≈0 → 弹回章首；删 B-4 后此路径同样裸奔。对齐
        // 样式/恢复路径打点 _reanchorClearedAt，让 B-3 窗一并覆盖缩放 settle 尾沿。
        if (mounted) _reanchorClearedAt = DateTime.now();
      },
      schedulePostFrame: (void Function() commit) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => commit()),
      stillAlive: () => mounted && _controller != null,
      onBeginError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderHibiki.reanchorContinuousForUiScale.begin',
        e,
        stack,
      ),
      onCommitError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderHibiki.reanchorContinuousForUiScale.commit',
        e,
        stack,
      ),
    );
  }

  /// TODO-718: 退出再进的**恢复完成重锚**（连续模式）。在 [_onRestoreComplete] 里、
  /// `_restoreInFlight` 刚被置 false 之后那一刻调用——此时恢复脚本
  /// （`restoreToCharOffset`/`restoreProgress`）已把视口滚到锚点落定，但随后的 WebView
  /// settle reflow 会把裸 `window.scrollY` 瞬时归 0（连续模式无分页的 snap/lock 保护），
  /// 归零后被 [_handleReaderScroll]（门控已全放行）当真实滚动落库 progress≈0 → 弹回章首。
  ///
  /// 复用与 [_reanchorContinuousForUiScale] 完全相同的两阶段 begin→commit 序列与
  /// `_reanchorPending` 串行旗（[runUiScaleReanchorOrchestration]）：阶段1 同步采样恢复后
  /// 落定的首个可见字符锚 + 置旗（webview.part.dart 的 `_reanchorPending` 守卫挡住归零
  /// scroll 不回传落库），阶段2 等过渡帧 settle 后把锚滚回视口首边并清旗。差异只在门控：
  /// 走 [readerRestoreReanchorAllowed]（不含 restoreInFlight 早返回——本路径下它必为 false）。
  Future<void> _reanchorContinuousAfterRestore() {
    return runUiScaleReanchorOrchestration(
      // 恢复完成路径专用门控：调用点已置 _restoreInFlight=false，故不复用含 !restoreInFlight
      // 早返回的 readerUiScaleReanchorAllowed（要求②：避开会早返回的那个门控）。
      gateAllowed: readerRestoreReanchorAllowed(
        controllerAvailable: _controller != null,
        readerContentReady: _readerContentReady,
        lyricsMode: _lyricsMode,
        continuousMode: _settings?.isContinuousMode == true,
      ),
      // 阶段 1：在归零前同步采样恢复落定的锚 + 置旗（要求①③：采锚必须在 reflow 归零前）。
      evalBegin: () => _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.beginUiScaleReanchorInvocation(),
      ),
      // 阶段 2：等过渡帧 settle 后提交滚动并清旗，并打 _reanchorClearedAt 武装 B-3 窗。
      evalCommit: () async {
        await _controller!.evaluateJavascript(
          source: ReaderPaginationScripts.commitUiScaleReanchorInvocation(),
        );
        // TODO-797 回归根因：commit 清旗后，连续模式 WebView settle reflow 仍会在随后几帧把裸
        // window.scrollY 瞬时归 0，归零 scroll 经 _handleReaderScroll 落库 progress≈0 → 退出再进恒
        // 章首。ea096d866 删 B-4 伪归零守卫时论证「commit 清旗后的 settle 尾沿由 B-3 250ms 窗拦掉」
        // 只对样式重锚成立（_reanchorForStyleChange 的 commit 打 _reanchorClearedAt）——本恢复重锚
        // （TODO-718）路径从未打点 B-3，故归零裸奔落库 → 滚动模式历史记录恒回章首。对齐样式路径
        // 打点，让既有 B-3 窗覆盖恢复 settle 尾沿（根因式，复用已测机制，不复用被证伪的「无输入=伪」）。
        if (mounted) _reanchorClearedAt = DateTime.now();
      },
      schedulePostFrame: (void Function() commit) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => commit()),
      stillAlive: () => mounted && _controller != null,
      onBeginError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderHibiki.reanchorContinuousAfterRestore.begin',
        e,
        stack,
      ),
      onCommitError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderHibiki.reanchorContinuousAfterRestore.commit',
        e,
        stack,
      ),
      // TODO-933：恢复重锚 commit 清旗后确定性补刷一次进度。根因——_onRestoreComplete 里
      // 紧跟 _reanchorContinuousAfterRestore() 调的首发 _refreshProgress() 撞上 begin 刚同步
      // 置的 _reanchorPending=true，stableProgressInvocation 返 null → 早退 → _progressCurrentChars
      // 保持 null → 顶部进度条隐藏（要滑一下旗清后才出）。这里挂在清旗之后补刷，旗已清不再撞旗，
      // 首屏进度条确定性可见。只此恢复路径补刷；缩放/样式重锚不传 onAfterCommit，行为不变。
      //
      // TODO-1309：连续模式在 commit 清 `_reanchorPending` + 打 B-3 settle 窗**之后**应用
      // 排队的章内精确定位（跨章文本搜索跳转的 scrollToSearchMatch）——此刻已 settle，落点
      // 不会被尾沿 reflow 冲回章首；先应用再补刷，让随后的 _refreshProgress 读到并落库 match
      // 位置（等价于「同章已 settle 时直接 scrollToSearchMatch」那条本就正常的路径）。
      onAfterCommit: () async {
        await _applyPendingPreciseLocate();
        await _refreshProgress();
      },
    );
  }

  /// TODO-736 B-1/B-2（必补点2）：样式变更（字号/字体/主题）两阶段 settle-aware 重锚。
  ///
  /// 由 [_applyStylesLive] 在裸套 CSS 兜底后调用。复用与 [_reanchorContinuousForUiScale]
  /// 完全相同的两阶段 begin→commit 编排（[runUiScaleReanchorOrchestration]）与
  /// `_reanchorPending` 串行旗，差异：
  ///   ① 用样式专用入口 [ReaderPaginationScripts.beginStyleReanchorInvocation]（同步换 CSS
  ///      + 采精确锚 + 失效 metrics + 置旗）/ [commitStyleReanchorInvocation]（settle 后滚回
  ///      + 清旗），**不复用** appUiScale 那对（那对只采锚滚回不换 CSS，改字号会坏）。
  ///   ② 门控走 [readerStyleReanchorAllowed]（两种排版模式都放行，不限连续）。
  ///   ③ commit 完成（无论成败）写 `_reanchorClearedAt`（B-3）：清旗那一刻打点，
  ///      [_handleReaderScroll] 进门若距此 250ms 内则尾沿 scroll 直接 return 不落库，
  ///      治 reflow settle 尾沿把瞬态归零 scroll 当真实滚动落库 → 翻页多次改字号跳章首。
  ///
  /// settle 检测沿用 [_syncPageSize] 的单帧 `addPostFrameCallback`（与 TODO-718 编排一致·
  /// 保守首版）。真机若改字号锚偏一点再加多帧探测（follow-up，本次不做）。
  Future<void> _reanchorForStyleChange(String jsonCss) {
    return runUiScaleReanchorOrchestration(
      gateAllowed: readerStyleReanchorAllowed(
        controllerAvailable: _controller != null,
        readerContentReady: _readerContentReady,
        lyricsMode: _lyricsMode,
      ),
      // 阶段 1：同步换 CSS + 采精确锚 + 置旗（必须先于 reflow 落地，挡住归零 scroll 污染落库）。
      evalBegin: () => _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.beginStyleReanchorInvocation(jsonCss),
      ),
      // 阶段 2：等过渡帧 settle 后滚回 + 清旗 + 打 _reanchorClearedAt（B-3 去抖打点）。
      evalCommit: () async {
        await _controller!.evaluateJavascript(
          source: ReaderPaginationScripts.commitStyleReanchorInvocation(),
        );
        // B-3：清旗那一刻打点（commit 即清 _reanchorPending）。距此 250ms 内的尾沿 scroll
        // 由 _handleReaderScroll 抑制落库。无论 JS 是否真有锚可滚，settle 都已发生。
        if (mounted) _reanchorClearedAt = DateTime.now();
      },
      schedulePostFrame: (void Function() commit) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => commit()),
      stillAlive: () => mounted && _controller != null,
      onBeginError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderHibiki.reanchorForStyleChange.begin',
        e,
        stack,
      ),
      onCommitError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderHibiki.reanchorForStyleChange.commit',
        e,
        stack,
      ),
    );
  }

  // Shared scaffold for the two bottom chrome bars ([_buildAudiobookBar] /
  // [_buildSettingsBar]): Positioned(bottom) -> ExcludeFocus -> FocusScope ->
  // Column(min) -> ReaderChromeScaler-scaled bar -> bottom-inset ColoredBox.
  //
  // TODO-700 T8: ExcludeFocus removes every bar control from the focus traversal
  // pool so the reading content ([_focusNode]) is the only home for focus. The
  // bar stays operable by touch/mouse but is never a directional-nav destination,
  // so it can neither steal a hidden shortcut nor strand the page-turn keys.
  // _chromeFocusScope is kept as the bar's structural scope; its `.hasFocus` is
  // now always false, which [_canOwnReaderFocus] 的 gesture 分支 relies on. The
  // audiobook bar passes a ValueKey so element identity survives the play-bar ↔
  // settings-bar swap; the settings bar passes none (as before).
  Widget _wrapBottomChromeBar({Key? key, required Widget bar}) {
    return Positioned(
      key: key,
      left: 0,
      right: 0,
      bottom: 0,
      child: ExcludeFocus(
        child: FocusScope(
          node: _chromeFocusScope,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ReaderChromeScaler(
                scale: _readerChromeScale,
                baseHeight: _ReaderHibikiPageState._readerChromeBaseHeight,
                child: bar,
              ),
              ColoredBox(
                color: _themeBackgroundColor(),
                child: SizedBox(
                  height: _stableBottomInset,
                  width: double.infinity,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomChrome() {
    // 底栏可见性只取决于用户意图（_showChrome）和「首次冷加载是否完成」
    // （_hasEverLoaded，只置 true、从不复位），不再耦合每次切章都会翻转的
    // _readerContentReady。否则切章时 _readerContentReady=false 会把底栏硬卸载
    // 成 SizedBox.shrink()，新章就绪后又突然挂回，造成底栏闪烁。冷启动首章
    // 渲染前 _hasEverLoaded 仍为 false，底栏照旧不显示，行为不变。
    // TODO-975：悬浮模式额外受 _chromeTransientVisible 门控（_bottomBarShouldPaint）；
    // 挤压模式恒随 _hasEverLoaded && _showChrome（旧行为）。
    if (!_bottomBarShouldPaint) {
      return const SizedBox.shrink();
    }
    if (_audiobookController != null) {
      return _buildAudiobookBar();
    }
    return _buildSettingsBar();
  }

  Widget _buildAudiobookBar() {
    final AudiobookPlayerController ctrl = _audiobookController!;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        return _wrapBottomChromeBar(
          key: const ValueKey<String>('hoshi_play_bar'),
          bar: AudiobookPlayBar(
            controller: ctrl,
            skipActionSeconds: ReaderHibikiSource.instance.skipActionSeconds,
            onOpenSettings: _showAppearanceSheet,
            backgroundColor: _themeBackgroundColor(),
            foregroundColor: _themeTextColor(),
            reversed: appModel.reverseReaderBottomBar,
            // TODO-830: per-reader 功能反转（getter 内部走 readerSettings?
            // 分层，否则退化全局）；与 reversed 的位置镜像维度正交。
            invertSkip:
                ReaderHibikiSource.instance.invertAudiobookSkipDirection,
            // TODO-728: per-reader toggle for the current-sentence cue.
            showCue: ReaderHibikiSource.instance.showBottomBarCue,
          ),
        );
      },
    );
  }

  Widget _buildSettingsBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool reversed = appModel.reverseReaderBottomBar;
    final List<Widget> barItems = <Widget>[
      IconButton(
        icon: Icon(Icons.headphones_outlined, color: _themeTextColor()),
        iconSize: 22,
        tooltip: t.audio_import,
        onPressed: _openAudioImportDialog,
      ),
      // TODO-723: illustration gallery -- browse every image in the book around
      // the current reading position. Reuses the existing image viewer + chapter
      // navigation; never touches WebView pagination/restore/lookup.
      IconButton(
        icon: Icon(Icons.collections_outlined, color: _themeTextColor()),
        iconSize: 22,
        tooltip: t.reader_gallery_tooltip,
        onPressed: _openGallery,
      ),
      const Spacer(),
      Semantics(
        identifier: 'hibiki.reader.bottom.settings',
        child: IconButton(
          key: const ValueKey<String>('hoshi_reader_settings_button'),
          icon: Icon(Icons.tune_outlined, color: _themeTextColor()),
          iconSize: 20,
          tooltip: t.reader_settings_section,
          onPressed: _showAppearanceSheet,
        ),
      ),
    ];
    return _wrapBottomChromeBar(
      bar: ColoredBox(
        color: _themeBackgroundColor(),
        child: SizedBox(
          height: _ReaderHibikiPageState._readerChromeBaseHeight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
            child: Row(
              children: reversed ? barItems.reversed.toList() : barItems,
            ),
          ),
        ),
      ),
    );
  }

  // TODO-796: resolve a TOC entry's href to its spine chapter index through the
  // same canonicalization [EpubBook.resolveInternalLink] uses, so a cover/front-
  // matter entry whose href differs only by `./` / `%xx` / case is matched (not
  // dropped, which used to shove the real first chapter into row 0 and make a
  // "Cover" tap jump to chapter 1).
  int _tocHrefToChapterIndex(String? href) {
    if (_book == null) return -1;
    return _book!.chapterIndexForHref(href);
  }

  Future<void> _showAppearanceSheet({String? initialSubPage}) async {
    if (_settings == null || _controller == null || _book == null) return;
    // 重入守卫：快速连点时按钮按下到 show 之间的 DB 读 await 期间会二次进入、弹出
    // 两个面板。标志置位必须在第一个 await 之前，复位放 finally（异常也复位）。
    if (_appearanceSheetOpen) return;
    // BUG-969：_rebuild 让顶部进度 pill 在抽屉打开期间摘掉 BackdropFilter blur
    // （见 _buildTopProgressBar / topProgressPillShowsBlur），关闭后再挂回。
    _rebuild(() => _appearanceSheetOpen = true);
    try {
      // _settings 就是 ReaderHibikiSource.readerSettings 本体（见 initState 绑定），
      // 面板控件经 ReaderHibikiSource.instance.ttu* 实时读写同一对象，开面板前后都
      // 无需设置同步——旧 TTU 双存储时代的 _syncSettings*Hive 已是写回自身的死桥，
      // 且 _syncSettingsToHive 会触发 17× onSettingsChangedLive 的 DB/WebView 风暴。
      final List<TtuTocEntry> toc = _buildTtuToc();
      final FavoriteSentenceRepository favRepo =
          FavoriteSentenceRepository(appModel.database);

      final List<FavoriteSentence> favorites =
          await _favoriteSentencesForBook();

      if (!mounted) return;

      final Widget sheetContent = ReaderQuickSettingsSheet(
        controller: _audiobookController,
        toc: toc,
        readerProgress: (_currentChapter, _book!.chapters.length),
        onJumpSection: (index) async {
          _navigateToChapter(index, manual: true);
        },
        // BUG-782：退出必须走 maybePop() 而非直接 pop()。直接 Navigator.pop()
        // 会绕过阅读器 PopScope(canPop:false) 的 onPopInvokedWithResult，使
        // onWillPop 整条链全部跳过——onSourcePagePop 的最终位置 flush（BUG-203）、
        // appModel.closeMedia 里对 hibikiBooksProvider/bookLastReadAtProvider 的
        // invalidate（BUG-777 依赖它刷新书架「继续阅读」hero 与进度）、以及
        // triggerAutoSyncAfterClose 关书自动同步都不会触发。maybePop() 触发
        // PopScope 回调 → onWillPop() → nav.pop()，与「退出书籍」快捷键分支
        // （caret.part.dart 的 readerExitBook，schema v6 从 readerDismissDict
        // 拆出）走的是同一条退出路径。
        onExitReader: () {
          unawaited(Navigator.of(context).maybePop());
        },
        webViewController: _controller!,
        appModel: appModel,
        ref: ref,
        isHibikiReader: true,
        initialSubPage: initialSubPage,
        onStyleChanged: _applyStylesLive,
        onThemeChanged: _onThemeChanged,
        extractDir: _extractDir,
        onReloadChapter: _reloadWithCurrentSettings,
        onLyricsReload: _loadLyricsPage,
        onAudioImport: _srtBookUid != null ? _openAudioImportDialog : null,
        lyricsMode: _lyricsMode,
        onToggleLyricsMode: _toggleLyricsMode,
        showFloatingLyric: appModel.showFloatingLyric,
        onToggleFloatingLyric: _toggleFloatingLyric,
        floatingLyricFontSize: appModel.floatingLyricFontSize,
        onFloatingLyricFontSizeChanged: (v) async {
          await appModel.setFloatingLyricFontSize(v);
          final FloatingLyricStyle style =
              _readerFloatingLyricStyle(fontSize: v);
          await FloatingLyricChannel.updateStyle(
            fontSize: style.fontSize,
            textColor: style.textColor,
            bgColor: style.bgColor,
            buttonTextColor: style.buttonTextColor,
            buttonBgColor: style.buttonBgColor,
            highlightColor: style.highlightColor,
            activeColor: style.activeColor,
          );
        },
        floatingLyricClickLookup: appModel.floatingLyricClickLookup,
        onFloatingLyricClickLookupChanged: (bool value) async {
          await appModel.setFloatingLyricClickLookup(value);
          await FloatingLyricChannel.setClickLookupEnabled(value);
        },
        showMediaNotification: appModel.showMediaNotification,
        onToggleMediaNotification: _toggleMediaNotification,
        charProgress:
            _progressCurrentChars != null && _progressTotalChars != null
                ? (_progressCurrentChars!, _progressTotalChars!)
                : null,
        onJumpToCharOffset: (globalOffset) async {
          _jumpToGlobalCharOffset(globalOffset);
        },
        epubBook: _book,
        chapterLabel: _currentChapterLabel(),
        onSearchJump: (BookSearchResult result, String query) async {
          if (_book == null || _controller == null) return;
          if (result.sectionIndex != _currentChapter) {
            // TODO-1309：跨章搜索跳转把「章内定位」排进导航的原子恢复链（settle 之后应用），
            // 不再在 restore 完成微任务里抢发被 settle-reflow / 连续重锚采样冲回章首（双跳，
            // 首跳只到章节）。去掉旧的首跳失败早退分支——旧代码首跳超时/代际 stale 时会停在
            // 章首、要点第二次才走「同章直接 restore」才生效；现在定位随恢复落定 settle
            // 之后由 _applyPendingPreciseLocate 确定性应用。文本命中无法用分数烘进 shell，故走
            // preciseLocateJs 队列（书签/收藏用 progress 烘进导航）。
            await _navigateToChapterAndWait(
              result.sectionIndex,
              manual: true,
              preciseLocateJs:
                  ReaderPaginationScripts.scrollToSearchMatchInvocation(
                query,
                result.charOffset,
              ),
            );
            return;
          }
          // 同章：章节已 settle，直接定位（既有正常路径，双跳的「第二次点」本就走这里）。
          await _controller!.evaluateJavascript(
            source: ReaderPaginationScripts.scrollToSearchMatchInvocation(
              query,
              result.charOffset,
            ),
          );
        },
        favoriteSentences: favorites,
        favoritePositionLabel: _favoritePositionLabel,
        onDeleteFavorite: (fav) async {
          await favRepo.removeById(fav.id);
          _invalidateFavoriteSentenceCache();
          if (fav.sectionIndex == _currentChapter || _lyricsMode) {
            await _refreshSectionHighlights(
                fav.sectionIndex ?? _currentChapter);
          }
        },
        onJumpToFavorite: _jumpToFavoriteSentence,
        onPlayFavorite: _audiobookController == null
            ? null
            : (fav) async {
                if (fav.normCharOffset == null || fav.sectionIndex == null) {
                  return;
                }
                final int section = fav.sectionIndex!;
                final List<AudioCue> cues =
                    _audiobookController!.sasayakiCuesForSection(section);
                AudioCue? target;
                for (final AudioCue cue in cues) {
                  final SasayakiFragment? frag =
                      SasayakiMatchCodec.tryDecode(cue.textFragmentId);
                  if (frag == null) continue;
                  if (frag.normCharStart <= fav.normCharOffset! &&
                      frag.normCharEnd > fav.normCharOffset!) {
                    target = cue;
                    break;
                  }
                }
                if (target != null) {
                  await _audiobookController!.playRange(
                    AudioPlaybackRange(
                      audioFileIndex: target.audioFileIndex,
                      startMs: target.startMs,
                      endMs: target.endMs,
                    ),
                  );
                }
              },
      );

      if (isDesktopPlatform) {
        await showAppDialog(
          context: context,
          builder: (_) => HibikiDialogFrame(
            // master-detail（左父菜单 + 右详情）需要更宽画布；窄于 640 的窗口
            // 由面板内部 LayoutBuilder 自动降级回单列 push。
            maxWidth: kHibikiSettingsDialogMaxWidth,
            maxHeightFactor: 0.80,
            scrollable: false,
            child: sheetContent,
          ),
        );
      } else {
        await adaptiveModalSheet<void>(
          context: context,
          builder: (_) => sheetContent,
        );
      }

      _syncDictionaryTheme();
    } finally {
      _appearanceSheetOpen = false;
      // 复位后重建把 blur 挂回 pill（dispose 后不能 setState，纯赋值已够）。
      if (mounted) _rebuild(() {});
    }
  }

  String _currentChapterLabel() {
    return _currentChapterLabelFor(_currentChapter);
  }

  String _currentChapterLabelFor(int chapterIndex) {
    if (_book == null) return '';
    final List<TtuTocEntry> toc = _buildTtuToc();
    for (int i = toc.length - 1; i >= 0; i--) {
      if (toc[i].index <= chapterIndex) {
        return toc[i].label;
      }
    }
    return 'Ch. ${chapterIndex + 1}';
  }

  List<TtuTocEntry> _buildTtuToc() {
    final List<EpubTocItem> toc = _book!.toc;
    if (toc.isEmpty) {
      return List<TtuTocEntry>.generate(
        _book!.chapters.length,
        (i) => TtuTocEntry(index: i, label: t.auto_chapter(n: i + 1)),
      );
    }
    // TODO-1333: 压平交给纯函数 flattenTtuTocEntries，它保留所有解析到的章、不再因
    // 「图片合并」把被吸收的单图片章从目录里删掉（那会在整本书目录都指向被吸收图片章
    // 时清空章节列表）。被吸收章的目录跳转由导航层 _resolveNavChapter 重定向到宿主章。
    return flattenTtuTocEntries(toc, _tocHrefToChapterIndex);
  }

  Future<void> _reloadWithCurrentSettings() async {
    if (_controller == null) return;
    _sanitizedCssCache.clear();
    _invalidateStyleCache();
    // TODO-1128: structural layout changes routed through onLayoutReloadLive
    // (spread mode/direction, merge-image toggle) may change the virtual-page
    // map, so rebuild it from the current settings before reloading. Cheap and
    // idempotent when nothing structural changed.
    _rebuildSpreadMap();
    // TODO-1128：结构性重载（含开/关「图片合并」）可能把当前章变成被吸收单图片章
    // （它没有自己的页）。重建 map 后立即重定向到宿主文本章章首，使重载加载宿主
    // （图片内联在顶部）而非独立单图页，避免重复。非吸收章 no-op。
    final int hostChapter = _resolveNavChapter(_currentChapter);
    if (hostChapter != _currentChapter) {
      _currentChapter = hostChapter;
      _lastProgressSection = _currentChapter;
      _lastProgressValue = 0.0;
      _lastProgressCharOffset = -1;
    }
    if (_lyricsMode) {
      await _loadLyricsPage();
      return;
    }
    final dynamic result;
    try {
      result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
    } catch (e, stack) {
      // 半销毁的 WebView 上 evaluateJavascript 抛 PlatformException；此处尚未改
      // 任何恢复状态，安全 no-op 返回（此前这是 try 块外的孤儿 await，会逃 zone）。
      ErrorLogService.instance
          .log('ReaderHibiki.reloadWithCurrentSettings.eval', e, stack);
      return;
    }
    if (!mounted || _controller == null) return;
    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    final bool hasSameChapterCache = _lastProgressSection == _currentChapter;
    _initialProgress =
        snapshot?.progress ?? (hasSameChapterCache ? _lastProgressValue : 0.0);
    // BUG-162 / TODO-219: reload 是同章程序化重建，优先沿用稳定精确锚；
    // stable gate 暂时不给快照时保留同章缓存，避免把瞬态章首 0 当新位置。
    _initialCharOffset = snapshot?.charOffset ??
        (hasSameChapterCache ? _lastProgressCharOffset : -1);
    _lastProgressSection = _currentChapter;
    _lastProgressValue = _initialProgress;
    _lastProgressCharOffset = _initialCharOffset;

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();
    _restoreInFlight = true;
    debugPrint('[ReaderHibiki] reloadWithCurrentSettings: '
        'chapter=$_currentChapter progress=$_initialProgress '
        'generation=$gen continuous=${_settings?.isContinuousMode}');

    _rebuild(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();

    try {
      await _loadChapterDirectly(_currentChapter);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.reloadWithCurrentSettings', e, stack);
      debugPrint('[ReaderHibiki] reloadWithCurrentSettings failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  // ── Top Progress Bar ──────────────────────────────────────────────

  Widget _buildTopProgressBar() {
    // TODO-975：悬浮模式额外受 _chromeTransientVisible 门控（_topProgressShouldPaint）；
    // 挤压模式恒随 _showTopProgress（旧行为）。
    if (_lyricsMode || !_topProgressShouldPaint) {
      return const SizedBox.shrink();
    }

    final double ratio =
        (_progressCurrentChars! / _progressTotalChars!).clamp(0.0, 1.0);
    final Color infoColor = _themeTextColor();
    final String position = ReaderHibikiSource.instance.topProgressPosition;

    // TODO-1136 / BUG-frosted：进度文字直接叠在正文上，浅色书/复杂背景下看不清，
    //  在文字后面加一层毛玻璃（frosted glass）背景提升可读性——经典配方
    //  （ClipRRect > BackdropFilter(ImageFilter.blur) > 半透明 Container），背景/文字
    //  色跟随当前主题（_themeBackgroundColor / _themeTextColor），不硬编码。
    //  BUG-887：毛玻璃只在**悬浮**模式有意义——那时进度真正浮在正文之上。挤压模式
    //  下 strip 预留了自身高度、正文被推到其下方，pill 落在预留区（正文空白顶边距
    //  = 主题背景）之上，背后并无正文，毛玻璃既无意义又会显出一块贴着正文首行的模糊
    //  矩形（横线字如「一」「ー」尤为明显）。故 frostedFill 仅悬浮态使用。
    final Color frostedFill = _themeBackgroundColor()
        .withValues(alpha: _isReaderThemeDark ? 0.42 : 0.55);

    // TODO-728: position-aware top progress + tap-to-toggle chrome.
    //  - The Positioned strip spans the available width (16px side margins);
    //    [Align] pushes the pill to the configured side (left/center/right).
    //  - The opaque [GestureDetector] wraps ONLY the frosted pill, so its hit
    //    box is the pill's own bounds. A tap on it toggles/collapses the chrome
    //    (the pointer-only equivalent of readerToggleChrome / M / gamepad-Y); a
    //    tap anywhere ELSE in the strip is NOT inside the GestureDetector child,
    //    so it passes through to the WebView and does not swallow text selection
    //    (penetration guard).
    //  - No Focus/canRequestFocus wrapper: this stays a pure pointer surface and
    //    must never enter the focus-traversal pool (TODO-700 invariant).
    final Text label = Text(
      '$_progressCurrentChars / $_progressTotalChars'
      '  ${(ratio * 100).toStringAsFixed(2)}%',
      key: const ValueKey<String>('hoshi_progress'),
      style: TextStyle(
          fontSize: _ReaderHibikiPageState._infoFontSize, color: infoColor),
      textAlign: readerTopProgressTextAlign(position),
    );

    // BUG-887：仅悬浮态套毛玻璃；挤压态是纯文字，无背景无模糊（见上方 frostedFill
    //  注释）。两态纵向内边距同源 [kTopProgressPillVerticalPadding]，pill 实高不超
    //  预留 [_infoStripHeight]（= [kTopProgressStripHeight]，BUG-547 已把预留同步含
    //  该内边距），保证挤压态 pill 落在预留区内、绝不压住正文首行。
    // BUG-969：BackdropFilter 每个栅格化帧都重采背景+重跑高斯，与内容是否变化
    //  无关。快速设置抽屉开着时 pill 压在 modal scrim 下，blur 与纯半透明底肉眼
    //  无差，抽屉滚动的每一帧却仍付 saveLayer+回读 → 120Hz 直接掉帧。被遮挡期间
    //  保留半透明底（形状/可读性不变）、只跳过 blur（topProgressPillShowsBlur）。
    final Widget frostedInner = Container(
      color: frostedFill,
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: kTopProgressPillVerticalPadding,
      ),
      child: label,
    );
    final Widget pill =
        topProgressUsesFrostedGlass(floating: _topProgressFloating)
            ? ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: topProgressPillShowsBlur(
                  floating: _topProgressFloating,
                  obscured: _appearanceSheetOpen,
                )
                    ? BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: frostedInner,
                      )
                    : frostedInner,
              )
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: kTopProgressPillVerticalPadding,
                ),
                child: label,
              );

    return Positioned(
      top: _stableTopInset,
      left: 16,
      right: 16,
      child: Align(
        alignment: readerTopProgressAlignment(position),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // TODO-975：悬浮态点进度条立即收起（决策#4，走 _handleFloatingChromeReveal
          // 的「可见→收起」分支）；挤压态维持旧语义 _toggleChrome（切底栏）。
          onTap: _anyChromeFloating
              ? () => _handleFloatingChromeReveal()
              : _toggleChrome,
          child: pill,
        ),
      ),
    );
  }

  // ── Theme Colors ──────────────────────────────────────────────────

  // BUG-396：selection/link 与 css `_themeColors` switch 的预设值逐一相等（ARGB 即
  // rgba 同值），作为五角色单一真相源透传，preset 零变化；system/light 走解析器派生。
  static const Map<String, ReaderThemeColors> _themeMap = {
    'ecru-theme': (
      bg: Color(0xFFF7F6EB),
      fg: Color(0xDE000000),
      sasayaki: Color(0x66A8C68C),
      selection: Color(0x59C2B280),
      link: Color(0xFF7A6232),
      dark: false,
    ),
    'water-theme': (
      bg: Color(0xFFDFECF4),
      fg: Color(0xDE000000),
      sasayaki: Color(0x6664B4DC),
      selection: Color(0x59C8AA6E),
      link: Color(0xFF3A5FAD),
      dark: false,
    ),
    // 护眼（豆沙绿）：与 reader_content_styles `_themeColors['eyecare-theme']` 的
    // rgba 预设逐一相等（ARGB 同值），作为五角色单一真相源透传。
    'eyecare-theme': (
      bg: Color(0xFFC7EDCC),
      fg: Color(0xDE000000),
      sasayaki: Color(0x66A0C878),
      selection: Color(0x5988B583),
      link: Color(0xFF4C7A3E),
      dark: false,
    ),
    'gray-theme': (
      bg: Color(0xFF23272A),
      fg: Color(0xDEFFFFFF),
      sasayaki: Color(0x595096C8),
      selection: Color(0x59BE9B64),
      link: Color(0xFF6FA8DC),
      dark: true,
    ),
    'dark-theme': (
      bg: Color(0xFF121212),
      fg: Color(0x99FFFFFF),
      sasayaki: Color(0x594682B4),
      selection: Color(0x59B4915A),
      link: Color(0xFF7AACDF),
      dark: true,
    ),
    'black-theme': (
      bg: Color(0xFF000000),
      fg: Color(0xDEFFFFFF),
      sasayaki: Color(0x663C78AA),
      selection: Color(0x66AA8750),
      link: Color(0xFF5B9BD5),
      dark: true,
    ),
  };

  /// custom-theme 的角色色（用户自定义；任一项缺省回落到合理默认）。
  ReaderThemeColors get _customReaderThemeColors {
    // TODO-928: 自定义主题跟随当前全局明暗，不再读已停写的 `custom_theme_dark`。
    final bool dark = appModel.isDarkMode;
    return (
      bg: appModel.customThemeBackgroundColor ?? const Color(0xFFFFFFFF),
      fg: appModel.customThemeFontColor ??
          (dark ? const Color(0xDEFFFFFF) : const Color(0xDE000000)),
      sasayaki:
          appModel.customThemeSasayakiColor ?? HibikiColor.defaultSasayakiColor,
      // 回退值与 ReaderContentStyles `_ThemeColors` 默认一致（灰选区 / 蓝链接）。
      selection: appModel.customThemeSelectionColor ?? const Color(0x66A0A0A0),
      link: appModel.customThemeLinkColor ?? const Color(0xFF426CF5),
      dark: dark,
    );
  }

  /// 当前主题 key 解析出的四个阅读器角色色，统一经 [resolveReaderThemeColors]：
  /// preset 命中用手调底色，未命中（light/system/未来 key）跟随真实 ColorScheme。
  ReaderThemeColors get _readerThemeColors {
    final String key = appModel.appThemeKey;
    return resolveReaderThemeColors(
      themeKey: key,
      presetMap: _themeMap,
      scheme: appModel.buildColorScheme(
        appModel.isDarkMode ? Brightness.dark : Brightness.light,
      ),
      customColors: key == 'custom-theme' ? _customReaderThemeColors : null,
      // TODO-977：全局音频高亮色覆盖（与主题解耦），对所有主题生效。
      audioHighlightOverride: appModel.audioHighlightColor,
    );
  }

  Color _themeBackgroundColor() => _readerThemeColors.bg;

  Color _themeTextColor() => _readerThemeColors.fg;

  Color _themeSasayakiColor() => _readerThemeColors.sasayaki;

  bool get _isReaderThemeDark => _readerThemeColors.dark;

  String get _readerBackgroundHex {
    final Color bg = _themeBackgroundColor();
    return '#${(bg.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  String? get _customThemeTextCss {
    final Color c = _themeTextColor();
    return _ReaderHibikiPageState._colorToCssRgba(c);
  }

  String? get _customHighlightCss {
    if (appModel.appThemeKey != 'custom-theme') return null;
    final Color? c = appModel.customThemePrimaryColor;
    if (c == null) return null;
    return readerColorToCssRgba(c, alphaOverride: 0.34);
  }

  Future<void> _onThemeChanged() async {
    // HBK-AUDIT-117: persist the reader theme here, in the theme-change flow,
    // instead of as a hidden side effect of _applyChapterHighlights (which only
    // ran when the chapter had favorites).
    await _settings?.setTheme(appModel.appThemeKey);
    _syncDictionaryTheme();
    if (appModel.showFloatingLyric) {
      // reader 主题变了：让 session 用新的 reader 样式重刷悬浮窗
      // （reader 样式已在 attach 时 install 进 session）。
      await appModel.audiobookSession.applyFloatingLyricStyle();
    }
    if (_lyricsMode) {
      await _updateLyricsStyleLive();
    }
    if (mounted) _rebuild(() {});
  }

  void _syncDictionaryTheme() {
    final Color bg = _themeBackgroundColor();
    final Color textColor = _themeTextColor();
    final Brightness brightness =
        _isReaderThemeDark ? Brightness.dark : Brightness.light;
    appModel.setOverrideDictionaryColor(bg);
    appModel.setOverrideDictionaryTheme(
      ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: bg,
          brightness: brightness,
        ).copyWith(
          onSurface: textColor,
        ),
      ),
    );
  }

  // ── JS result helpers (evaluateJavascript returns dynamic) ────────

  static bool _didScroll(dynamic result) {
    if (result is String) {
      return result.trim().replaceAll('"', '') == 'scrolled';
    }
    return false;
  }

  // ── Popup Audio Controls ───────────────────────────────────────────

  Future<void> _refreshSectionHighlights(int section) async {
    if (_controller == null) return;
    if (_lyricsMode) {
      await _applyLyricsFavorites();
      return;
    }
    final List<FavoriteSentence> chapterFavs =
        await _favoriteSentencesForSection(section);
    await HighlightBridge.applyHighlights(_controller!, chapterFavs,
        backgroundHex: _readerBackgroundHex,
        customHighlightCss: _customHighlightCss);
    await _controller!.evaluateJavascript(
      source:
          'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
    );
  }

  Future<void> _toggleFavoriteSentence() async {
    if (_controller == null || _book == null) return;
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    if (sentence.isEmpty) {
      HibikiToast.show(msg: t.no_sentence_selected);
      return;
    }

    final int section = _favoriteSectionIndex;
    final sentenceRange = _cachedSentenceRange ??
        (_cachedSelectionRange != null
            ? (
                offset: _cachedSelectionRange!.offset,
                length: _cachedSelectionRange!.length
              )
            : null);
    debugPrint('[hoshi-hl] toggleFavorite: '
        'sentenceRange=${sentenceRange != null ? "(${sentenceRange.offset},${sentenceRange.length})" : "null"} '
        'cachedSentence=${_cachedSentenceRange != null} '
        'cachedSelection=${_cachedSelectionRange != null}');
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);

    if (_currentSentenceIsFavorited) {
      // BUG-494：优先按 _checkFavoriteStatus 缓存的精确条目 id 删单条（身份键坍缩下不连坐
      // 误删同内容的另一条）；无缓存 id（老路径 / 未经 checkFavoriteStatus）回退内容键删单条。
      final String? favId = _currentFavoriteId;
      if (favId != null) {
        await repo.removeById(favId);
      } else {
        await repo.removeByContent(
          text: sentence,
          bookKey: widget.bookKey,
          sectionIndex: section,
          normCharOffset: sentenceRange?.offset,
        );
      }
      _currentFavoriteId = null;
      _invalidateFavoriteSentenceCache();
      _rebuild(() => _currentSentenceIsFavorited = false);
      if (sentenceRange != null || _lyricsMode) {
        await _refreshSectionHighlights(section);
      }
      HibikiToast.show(msg: t.favorite_removed);
      return;
    }

    final FavoriteSentence fav = FavoriteSentence(
      text: sentence,
      bookTitle: _book!.title,
      chapterLabel: _currentChapterLabelFor(section),
      createdAt: DateTime.now(),
      bookKey: widget.bookKey,
      sectionIndex: section,
      normCharOffset: sentenceRange?.offset,
      normCharLength: sentenceRange?.length,
      // BUG-893：补 dateKey，否则阅读统计「收藏语句」计数恒为 0（视频收藏路径早已带
      // dateKey，唯独书内收藏漏了）。source 用默认（书籍），与统计分桶口径一致。
      dateKey: statTodayKey(),
    );
    await repo.add(fav);
    // BUG-494：记住刚写入条目的精确 id，供随后取消收藏 removeById 精确删单条。
    _currentFavoriteId = fav.id;
    _invalidateFavoriteSentenceCache();
    _rebuild(() => _currentSentenceIsFavorited = true);
    if (sentenceRange != null || _lyricsMode) {
      await _refreshSectionHighlights(section);
    }
    HibikiToast.show(msg: t.favorite_added);
  }

  /// TODO-1308 问题②（BUG-696 根因①）：书内收藏面板跳转的唯一真实路径——quick
  /// settings sheet 的 onJumpToFavorite 与 debugJumpToFavorite 测试钩子都走这里。
  Future<void> _jumpToFavoriteSentence(FavoriteSentence fav) async {
    if (fav.sectionIndex == null) return;
    final int? normCharOffset = fav.normCharOffset;
    // TODO-1308 问题②（BUG-696 根因①）：fav.normCharOffset 是写入端
    // （lookup.part / mining.part 的 sentenceNormalizedOffset，即 JS
    // getNormalizedOffset）产的**章内绝对可匹配字符索引**（0..数千），不是书签的
    // 0-10000 进度分数。旧代码把它 /10000.0 当分数还原 → 0.0x 分数恒落章节开头。
    // BUG-459 只修了收藏页冷启动入口（charAnchor 绝对锚），书内收藏面板这条
    // 从未修到；TODO-1309 重写 handler 时又原样保留了 /10000。改走与冷启动
    // 同构的绝对字符锚链：跨章把 charOffset（+句尾锚，BUG-461 整句对齐）烘进
    // 导航原子恢复；同章直接 restoreToCharOffset（与 restoreProgress 同族
    // restore 入口，notifyRestoreComplete 副作用形状一致）。书签（onJumpToBookmark）
    // 的 normCharOffset 才是真分数，/10000 保持不变。
    final int? favLen = fav.normCharLength;
    final int charOffsetEnd =
        (normCharOffset != null && favLen != null && favLen > 0)
            ? normCharOffset + favLen
            : -1;
    // BUG-876（「点收藏有时跳不过去」根因修复）：normCharOffset 可能缺失——收藏写入端
    // （`_toggleFavoriteSentence`）的 `sentenceRange?.offset` 依赖 JS getNormalizedOffset
    // 解析出章内偏移，跨 ruby / 复杂节点的选区可能返 null → 存 null。此时旧跳转：同章
    // `restoreToCharOffset` 被 `normCharOffset != null` 门吞成**静默 no-op**（什么都不动），
    // 跨章 charOffset=null → progress 0 落**章首**——正是用户报的「有时能跳、有时跳不过去」
    // （能否跳取决于该条收藏写入时有没有拿到 offset）。收藏条目**总有文本**，故缺 offset 时
    // 回退到与「搜索跳转」同一条 by-text 定位原语 `scrollToSearchMatch`（按句文本在章内命中，
    // 不依赖脆弱的持久化 offset；整句文本在章内通常唯一，hint=0 即命中）。有效 offset 仍走
    // 精确 `restoreToCharOffset` / 字符锚导航（现有正常路径逐字节不变，向后兼容既有可跳收藏）。
    final String favText = fav.text.trim();
    final bool useOffset = normCharOffset != null;
    final String? textLocateJs = useOffset || favText.isEmpty
        ? null
        : ReaderPaginationScripts.scrollToSearchMatchInvocation(favText, 0);
    if (fav.sectionIndex != _currentChapter) {
      await _navigateToChapterAndWait(
        fav.sectionIndex!,
        manual: true,
        charOffset: useOffset ? normCharOffset : null,
        charOffsetEnd: charOffsetEnd,
        preciseLocateJs: textLocateJs,
      );
      return;
    }
    if (!mounted || _controller == null) return;
    if (useOffset) {
      await _controller!.evaluateJavascript(
        source: 'window.hoshiReader && window.hoshiReader'
            '.restoreToCharOffset($normCharOffset, $charOffsetEnd);',
      );
    } else if (textLocateJs != null) {
      await _controller!.evaluateJavascript(source: textLocateJs);
    }
  }

  /// 收藏面板每行的「阅读位置」标签（如 `78.6%`）。用本次阅读会话已建好的每章字符
  /// 账本（`_chapterCumulativeChars` / `_chapterCharCounts`，与顶栏进度同源）把收藏的
  /// (章节, 章内偏移) 折算成全书进度分数（[favoriteBookProgressFraction]）。账本未就绪
  /// / 无 sectionIndex / 折算失败时返回 null（不显示，绝不显示错误位置）。
  String? _favoritePositionLabel(FavoriteSentence fav) {
    final int? section = fav.sectionIndex;
    if (section == null) return null;
    final double? fraction = favoriteBookProgressFraction(
      cumulativeChars: _chapterCumulativeChars,
      charCounts: _chapterCharCounts,
      sectionIndex: section,
      normCharOffset: fav.normCharOffset,
    );
    if (fraction == null) return null;
    return '${(fraction * 100).toStringAsFixed(1)}%';
  }
}

/// TODO-723: full-screen illustration gallery for the reader. Shows every
/// [EpubImageRef] in reading order as a thumbnail grid; the image(s) in the
/// current chapter are marked ("Reading here") and scrolled into view on open.
/// Decoupled from reader page state -- the page passes in a resolver
/// ([fileForRef]) plus open/jump callbacks so this widget owns no reader logic.
class _ReaderGalleryPage extends StatefulWidget {
  const _ReaderGalleryPage({
    required this.images,
    required this.currentChapter,
    required this.fileForRef,
    required this.onOpenImage,
    required this.onJumpTo,
  });

  final List<EpubImageRef> images;
  final int currentChapter;
  final File? Function(EpubImageRef ref) fileForRef;
  final void Function(EpubImageRef ref) onOpenImage;
  final void Function(EpubImageRef ref) onJumpTo;

  @override
  State<_ReaderGalleryPage> createState() => _ReaderGalleryPageState();
}

class _ReaderGalleryPageState extends State<_ReaderGalleryPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Auto-scroll to the first image of the current chapter once laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int _columnCount(double width) {
    const double target = 150.0;
    final int count = (width / target).floor();
    return count < 2 ? 2 : count;
  }

  // Grid layout constants — single source of truth shared by [build] and
  // [_scrollToCurrent] so the auto-scroll estimate matches the real layout.
  static const double _kGridPadding = 8.0;
  static const double _kGridSpacing = 8.0;
  static const double _kTileAspect = 0.78;

  void _scrollToCurrent() {
    if (!_scrollController.hasClients) return;
    final int firstCurrent = widget.images.indexWhere(
        (EpubImageRef r) => r.chapterIndex == widget.currentChapter);
    if (firstCurrent < 0) return;
    final double width = MediaQuery.of(context).size.width;
    final int columns = _columnCount(width);
    final int row = firstCurrent ~/ columns;
    // Reproduce the grid's row pitch: subtract the horizontal padding, split the
    // remaining width across columns (minus inter-column spacing), divide tile
    // width by the aspect ratio for the tile height, then add the main-axis
    // spacing between rows. Clamped to the scroll extent so an over-estimate
    // never throws.
    final double availWidth =
        (width - _kGridPadding * 2 - _kGridSpacing * (columns - 1))
            .clamp(0.0, double.infinity);
    final double tileWidth = availWidth / columns;
    final double rowPitch = tileWidth / _kTileAspect + _kGridSpacing;
    final double target =
        (row * rowPitch).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.reader_gallery)),
      body: widget.images.isEmpty
          ? Center(
              child: Text(
                t.reader_gallery_empty,
                style: theme.textTheme.bodyLarge,
              ),
            )
          : LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final int columns = _columnCount(constraints.maxWidth);
                return GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(_kGridPadding),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: _kGridSpacing,
                    mainAxisSpacing: _kGridSpacing,
                    childAspectRatio: _kTileAspect,
                  ),
                  itemCount: widget.images.length,
                  itemBuilder: (BuildContext context, int index) =>
                      _buildTile(theme, widget.images[index]),
                );
              },
            ),
    );
  }

  Widget _buildTile(ThemeData theme, EpubImageRef ref) {
    final bool isCurrent = ref.chapterIndex == widget.currentChapter;
    final File? file = widget.fileForRef(ref);
    final Widget thumbnail = file == null
        ? ColoredBox(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        : Image.file(file, fit: BoxFit.cover);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: GestureDetector(
            onTap: () => widget.onOpenImage(ref),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: isCurrent
                    ? Border.all(color: theme.colorScheme.primary, width: 2)
                    : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: thumbnail,
              ),
            ),
          ),
        ),
        if (isCurrent)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Flexible(
                  child: Text(
                    t.reader_gallery_current,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.primary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  iconSize: 18,
                  tooltip: t.reader_gallery_jump,
                  icon: const Icon(Icons.my_location_outlined),
                  onPressed: () => widget.onJumpTo(ref),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 18,
                tooltip: t.reader_gallery_jump,
                icon: const Icon(Icons.my_location_outlined),
                onPressed: () => widget.onJumpTo(ref),
              ),
            ),
          ),
      ],
    );
  }
}
