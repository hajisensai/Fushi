// GENERATED-NOTE: extracted from reader_fushi_page.dart (TODO-589 batch7).
part of '../reader_fushi_page.dart';

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
/// fully qualified as `_ReaderFushiPageState._colorToCssRgba` /
/// `_ReaderFushiPageState._toDouble`.
///
/// The two class statics whose only call sites moved with this domain
/// (`_themeMap`, used by `_readerThemeColors`; `_didScroll`, used by
/// `_paginate`) move here as extension statics and are referenced by bare name
/// (no qualification needed). The `@override` host member
/// `buildPopupAudioControls` (and the related `_readerChromeHeight` getter /
/// `_readerChromeBaseHeight` / `_readerPopupHeaderBaseHeight` constants) cannot
/// live on an extension and stay in the shell, reachable via the shared private
/// class scope.
extension _ReaderChrome on _ReaderFushiPageState {
  /// TODO-1229 案A：章界连续输入穿透守卫。滚轮惯性节流（450ms）远短于换章加载
  /// （数百 ms restore），跨章那一下之后排队的翻页 tick 会在新章 restore 未落定时
  /// 立即再翻——章首插图页/首页整页被越过；更糟 fushiReader 尚未就绪时
  /// evaluateJavascript 返 null → _didScroll(null)=false → 又 _handlePageTurnLimit →
  /// **跳两章**。本 getter 只在「导航在飞（_isNavigatingToChapter）/ 恢复在飞
  /// （_restoreInFlight）/ 内容未就绪（!_readerContentReady）」这三个瞬态窗口为真；
  /// 正常连续翻页三者皆稳态（false/false/true），不受影响。内容就绪有 8s 兜底超时
  /// （_startContentReadyTimeout）强制置真，故绝不会永久卡死翻页。
  bool get _paginationInFlight =>
      _restoreInFlight || !_readerContentReady || _isNavigatingToChapter;

  /// BUG-2424：消费一次积压的翻页意图并重放。
  ///
  /// 在 [_onRestoreComplete] 的收尾（新章内容就绪、`fushiReader` 可用）之后调用，
  /// 所以重放时的页边界判定是在**已就绪**的状态上做的——这正是原始「跳两章」
  /// （在飞时 `evaluateJavascript` 返 null 被 `_didScroll` 误读成页边界）消失的原因。
  ///
  /// 消费到「队列空」或「又进入在飞」为止，两种出口都必要：
  ///   * 重放导致**跨章** → `_paginationInFlight` 立刻为真 → 退出循环，剩余意图由那次
  ///     导航的 content-ready 再次进来消费，串成 1:1 的链；
  ///   * 重放只是**章内翻页**（新章还有下一页）→ 不会再有 content-ready 把我们叫醒，
  ///     必须就地继续消费，否则剩余意图一直压到下一次跨章才突然连翻。
  ///
  /// 重放**不过 [_lastPaginateTime] 节流**——该节流限的是「用户新输入的速率」，
  /// 而积压意图早已是用户按下过的、被延后执行的输入，再节流一次就等于又丢一遍。
  ///
  /// `_replayingPageTurns` 防重入：本方法在 await 期间可能被另一个 content-ready
  /// 完成点再次调用（spreadReady / 兜底超时与 onRestoreComplete 并非互斥），两个
  /// 循环同时消费同一个队列会让意图乱序落到不同章上。
  Future<void> _replayPendingPageTurn() async {
    if (_replayingPageTurns) return;
    _replayingPageTurns = true;
    try {
      while (mounted && _controller != null && !_paginationInFlight) {
        final ReaderNavigationDirection? next = _pageTurnQueue.consume();
        if (next == null) return;
        await _paginate(next);
      }
    } finally {
      _replayingPageTurns = false;
    }
  }

  Future<void> _paginate(
    ReaderNavigationDirection direction, {
    int throttleMs = 0,
  }) async {
    if (_controller == null) {
      return;
    }
    // TODO-737: 翻页输入节流闸门归一到此唯一入口。各源传不同 throttleMs：滚轮
    // wheelPageTurnInterval(450)、音量键固定 defaultScrollingSpeed(100)、键盘/手柄 0。
    // 时间戳语义（与音量键旧 _lastVolumeKeyTime / HBK-AUDIT-120 一致）：读 throttleMs
    // 时即生效，无残留 timer。
    //
    // BUG-2424：节流必须排在在飞判定**之前**。它是用户在设置里配的「滚轮翻页间隔」，
    // 语义是「每隔这么久接受一次翻页输入」——**统一管所有滚轮翻页，含跨章**，与分页/
    // 连续模式无关。放在在飞判定之后的话，换章加载期到达的输入会绕过限速直接入队，
    // 落定后一次性连翻，等于用户配的速率对跨章不生效。
    if (throttleMs > 0 && _lastPaginateTime != null) {
      final int elapsedMs =
          DateTime.now().difference(_lastPaginateTime!).inMilliseconds;
      if (elapsedMs < throttleMs) return;
    }
    // 过了节流 = 这一次输入被**接受**，占掉一个翻页配额，所以此刻就 stamp——哪怕它
    // 接着要进队列等重放。不 stamp 的话，加载期内的每一个 tick 都会被接受入队。
    if (throttleMs > 0) {
      _lastPaginateTime = DateTime.now();
    }
    if (_paginationInFlight) {
      // BUG-2424：换章加载期到达的输入**排队**而不是丢弃。旧实现在这里直接 return，
      // 用户在换章那几百毫秒里拨的滚轮石沉大海（「按了没反应，要再按一次」）。
      // 此刻仍不能就地执行——`fushiReader` 未就绪、`evaluateJavascript` 返 null 会被
      // `_didScroll` 误读成页边界而多跨一章（原始「跳两章」的成因之一）——所以存下
      // 意图，由 [_replayPendingPageTurn] 在 content-ready 之后重放，那时判定是在
      // 已就绪状态上做的。重放不再过节流：这一格在**入队前**就已经过了。
      _pageTurnQueue.push(direction);
      return;
    }
    // Lyrics mode renders LyricsModeHtml — a vertical cue list with no
    // fushiReader paginator. paginate() there no-ops in JS (the
    // `window.fushiReader && ...` guard short-circuits) and returns undefined,
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
      if (!_didConsumePageTurn(result)) {
        // BUG-2424：跨章冷却闸门已删除。这里的判定发生在 `fushiReader` 已就绪之后
        // （result 是真实的 paginate 返回值，不是在飞时的 null），所以「一次输入最多
        // 一次跨章」由这条路径本身保证，不需要再叠一层时间窗。
        _handlePageTurnLimit(direction.jsValue);
      } else {
        await _refreshProgress();
        if (!mounted || _controller == null) return;
        if (_didScroll(result)) await _caretReanchor(direction);
      }
      return;
    }
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.paginateInvocation(direction),
    );
    if (!mounted || _controller == null) return;
    if (_didConsumePageTurn(result)) {
      await _refreshProgress();
      if (!mounted || _controller == null) return;
      if (_didScroll(result)) await _caretReanchor(direction);
    } else {
      // BUG-2424：同上——分页模式的跨章判定同样发生在 JS 已就绪之后，冷却闸门已删除。
      _handlePageTurnLimit(direction.jsValue);
    }
  }

  // ── Image Viewer ──────────────────────────────────────────────────

  File? _readerImageFileForUrl(String imgUrl) {
    final Uri? uri = Uri.tryParse(imgUrl);
    if (uri == null || _extractDir == null) return null;
    if (uri.host != ReaderFushiSource.kHost) return null;
    if (!uri.path.startsWith('/epub/')) return null;
    final String epubPath =
        Uri.decodeComponent(uri.path.substring('/epub/'.length));
    // BUG-1218：真实路径保留大小写（越界判据仍走 canonicalize），否则大小写敏感
    // 平台上图片查看器/分享取不到 EPUB 内插图。
    final String joined = p.join(_extractDir!, epubPath);
    if (!p.isWithin(p.canonicalize(_extractDir!), p.canonicalize(joined))) {
      return null;
    }
    final String filePath = p.normalize(joined);
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
    // BUG-381: [globalPosition] 是真实屏幕坐标（右键路径来自阅读器 State 的 RenderBox
    // localToGlobal，放大图路径来自 details.globalPosition；两者都在「净缩放=1 的真实
    // 视口空间」——阅读器被 FushiAppUiScaleNeutralizer 中和回 1.0）。但 showMenu 的
    // RelativeRect 落在它路由 Overlay 的坐标系，而该 Overlay 在全局 FushiAppUiScale 的
    // FittedBox 之内（缩放后的画布空间）。直接把真实屏幕坐标当画布坐标喂给 showMenu，
    // 界面大小≠100% 时菜单会偏离图片 factor≈scale（BUG-261 同型，视频右键已修）。
    //
    // 修法与 BUG-129/261 同范式：不读 scale 数值逆算（自动模式下生效 scale ≠
    // appModel.appUiScale），而用 Overlay 的 RenderBox 把锚点从真实屏幕坐标沿真实渲染
    // 变换链映射到 Overlay 本地坐标系——其间的 FittedBox 缩放被 render transform 自动
    // 吸收，对任意 scale（含自动模式）自洽无残差；scale=1 时变换为单位阵，逐像素等价
    // （向后兼容）。
    //
    // BUG-1438：菜单内容**不能**再乘界面缩放。菜单渲染在根 Overlay，也就是全局
    // FushiAppUiScale 的缩放画布内，画布→屏幕这一跳已经把它按 scale 放大了一次；
    // 阅读器 chrome 之所以要手动 ×_readerChromeScale，是因为 chrome 在
    // FushiAppUiScaleNeutralizer **之内**（净缩放=1，不跟随），而菜单在**之外**。
    // 旧代码把 chrome 的规则错套到菜单上 → 视觉尺寸是 scale²：实测同样写
    // `fontSize: 14 * menuScale`，chrome 渲染成 40 而菜单 80（scale=2）。所以这里
    // 写常量，让菜单与 app 其它右键菜单（视频 / 合集 / 标签管理）口径一致。
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final String? action = await showMenu<String>(
      context: effectiveContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 112.0, maxWidth: 280.0),
      menuPadding: const EdgeInsets.symmetric(vertical: 8.0),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy',
          height: kMinInteractiveDimension,
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.copy_outlined, size: 18.0),
              const SizedBox(width: 12.0),
              Text(
                t.reader_copy_image,
                style: const TextStyle(fontSize: 14.0),
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
  // RenderBox 映射、菜单尺寸写常量」范式（见上方 BUG-381 / BUG-1438 长注释）：菜单随
  // 界面大小缩放这件事由它所在的缩放画布负责，代码不再手动乘 scale，而鼠标锚点与
  // WebView 命中测试不受影响。导出项仅在本书有音频 cue 时出现；其它两项恒在。
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
        ErrorLogService.instance.log(
          'ReaderFushi.showReaderTextContextMenu',
          e,
          stack,
        );
        return;
      }
      final String selectedText =
          ReaderSelectionScripts.nativeSelectionTextFromResult(rawText);
      if (selectedText.isEmpty) return;
      if (!mounted) return;

      // Capture before the Flutter menu takes focus. Favorite must consume
      // this immutable selection, never a later WebView selection or lookup cache.
      final int favoriteSection = _lookupSectionIndex;
      final ReaderSelectionData? favoriteSelection =
          await _fillLookupStateFromNativeSelection();
      if (!mounted) return;

      // A native WebView2 popup surface is above Flutter routes on Windows. Move
      // it back to the warm slot before opening the Flutter context menu; pruning
      // does not clear the reader's native text selection.
      _webviewPrunePopupStack(0);

      final RenderBox overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      // BUG-1438：与图片右键菜单同因——菜单在根 Overlay（缩放画布）内，不得再手动
      // 乘界面缩放，否则视觉尺寸是 scale²。详见上方 _showReaderImageContextMenu 注释。
      final Offset anchor = overlay.globalToLocal(globalPosition);

      final bool hasAudio = _audiobookController != null &&
          _audiobookController!.chapterCueCount > 0;

      final List<PopupMenuEntry<String>> items = <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'search',
          height: kMinInteractiveDimension,
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.search_outlined, size: 18.0),
              const SizedBox(width: 12.0),
              Text(t.search, style: TextStyle(fontSize: 14.0)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          height: kMinInteractiveDimension,
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.copy_outlined, size: 18.0),
              const SizedBox(width: 12.0),
              Text(t.copy, style: TextStyle(fontSize: 14.0)),
            ],
          ),
        ),
        // BUG-854：选区菜单补「收藏」——与桌面底栏 / 查词弹窗顶栏的收藏句子
        // （`_toggleFavoriteSentence`）同一后端，仅入口不同。触屏从不建原生选区
        // （TODO-1279），旧菜单只有查词 / 复制 / 导出，无从收藏当前句；此项填平缺口。
        PopupMenuItem<String>(
          value: 'favorite',
          height: kMinInteractiveDimension,
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.star_border, size: 18.0),
              const SizedBox(width: 12.0),
              Text(t.action_favorite, style: TextStyle(fontSize: 14.0)),
            ],
          ),
        ),
        if (hasAudio)
          PopupMenuItem<String>(
            value: 'export',
            height: kMinInteractiveDimension,
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.movie_creation_outlined, size: 18.0),
                const SizedBox(width: 12.0),
                Text(t.audiobook_export_clip, style: TextStyle(fontSize: 14.0)),
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
        constraints: const BoxConstraints(minWidth: 112.0, maxWidth: 280.0),
        menuPadding: const EdgeInsets.symmetric(vertical: 8.0),
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
              selection: FushiTextSelection(text: selectedText),
            );
          }
          // BUG-1344：状态/夹图提取完成后、打开弹窗前清原生选区。否则 WKWebView
          // 失焦时会留下灰色高亮，直到切换应用才触发下一次重绘。
          await _clearReaderAppSelection();
          if (!mounted) return;
          await searchDictionaryResult(
            searchTerm: selectedText,
            selectionRect: rect,
          );
          if (mounted) _checkFavoriteStatus();
          return;
        case 'copy':
          await Clipboard.setData(ClipboardData(text: selectedText));
          FushiToast.show(
            msg: t.copied_to_clipboard,
            severity: ToastSeverity.success,
          );
          // 复制是终结动作：清掉刻意保留的原生选区，和移动端拖选菜单的 'copy'
          // （_clearReaderAppSelection）对齐。否则残留的原生蓝色选区会一直卡住后续
          // 查词（见 webview.part.dart pointerup 里对 nativeMoved 的处理）。BUG-927。
          await _clearReaderAppSelection();
          return;
        case 'favorite':
          if (favoriteSelection == null) {
            FushiToast.show(
              msg: t.no_sentence_selected,
              severity: ToastSeverity.error,
            );
            return;
          }
          await _toggleFavoriteSentence(
              selection: favoriteSelection, selectionSection: favoriteSection);
          await _clearReaderAppSelection();
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
  // 文字查词了」）。这里让拖选出的 app 自绘选区（`window.fushiSelection.selection`，非原生
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

    // BUG-1236：这里必须是非模态 OverlayEntry。showMenu 会 push 带全屏
    // ModalBarrier 的 PopupRoute，菜单在场时 WebView 里的选区手柄收不到触摸。
    _selectionActionData = data;
    _selectionActionSectionIndex = _lookupSectionIndex;
    if (_selectionActionBarEntry != null) {
      _selectionActionBarEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext overlayContext) =>
          _buildSelectionActionBar(overlayContext),
    );
    _selectionActionBarEntry = entry;
    overlay.insert(entry);
  }

  void _removeSelectionActionBar() {
    _selectionActionBarEntry
      ?..remove()
      ..dispose();
    _selectionActionBarEntry = null;
    _selectionActionData = null;
    _selectionActionSectionIndex = null;
  }

  Widget _buildSelectionActionBar(BuildContext overlayContext) {
    final ReaderSelectionData? data = _selectionActionData;
    if (data == null) return const SizedBox.shrink();

    final RenderBox? overlayBox =
        Overlay.of(overlayContext).context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) {
      return const SizedBox.shrink();
    }
    final Size overlaySize = overlayBox.size;
    // BUG-1438：本操作条是插进**根 Overlay** 的 OverlayEntry，落在全局
    // FushiAppUiScale 的缩放画布内，已天然跟随界面大小；不得再乘
    // _readerImageMenuScale（那是给中和层内 chrome 用的），否则视觉尺寸是 scale²。
    const double barHeight = kMinInteractiveDimension;
    const double gap = 8;
    const double handleReserve = 32 + gap;

    final RenderBox? webBox =
        _webViewKey.currentContext?.findRenderObject() as RenderBox?;
    final Map<String, double>? r = data.rect;
    double selectionTop;
    double selectionBottom;
    if (r != null && webBox != null) {
      // BUG-1438：选区矩形的**两个角**都要过 localToGlobal→globalToLocal，不能只映射
      // 顶边再加上未换算的 height。`r` 来自 WebView（中和层内的真实像素），而
      // selectionTop 已在 Overlay 画布空间——两者相加是混量纲，界面大小≠100% 时
      // 「上方放不下→翻到选区下方」这一分支会偏 (1−1/scale)×选区高。
      final double rx = r['x'] ?? 0;
      final double ry = r['y'] ?? 0;
      final Offset topGlobal = webBox.localToGlobal(Offset(rx, ry));
      final Offset bottomGlobal = webBox.localToGlobal(
        Offset(rx, ry + (r['height'] ?? 0)),
      );
      selectionTop = overlayBox.globalToLocal(topGlobal).dy;
      selectionBottom = overlayBox.globalToLocal(bottomGlobal).dy;
    } else {
      selectionTop = overlaySize.height / 2;
      selectionBottom = selectionTop;
    }

    double top = selectionTop - gap - barHeight;
    if (top < gap) {
      top = selectionBottom + handleReserve;
    }
    top = top.clamp(
      gap,
      (overlaySize.height - barHeight - gap).clamp(gap, double.infinity),
    );

    final bool hasAudio = _audiobookController != null &&
        _audiobookController!.chapterCueCount > 0;
    final ThemeData theme = Theme.of(overlayContext);

    Widget button(IconData icon, String label, String action) {
      return InkWell(
        onTap: () => _runSelectionAction(action),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 12.0,
            vertical: 10.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18.0),
              const SizedBox(width: 8.0),
              Text(label, style: TextStyle(fontSize: 14.0)),
            ],
          ),
        ),
      );
    }

    return Positioned(
      left: gap,
      right: gap,
      top: top,
      child: Align(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Material(
            elevation: 6,
            color: theme.popupMenuTheme.color ??
                theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8.0),
            clipBehavior: Clip.antiAlias,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                button(Icons.search_outlined, t.search, 'search'),
                button(Icons.copy_outlined, t.copy, 'copy'),
                if (isAndroidPlatform)
                  button(Icons.share_outlined, t.share, 'share'),
                if (isAndroidPlatform)
                  button(Icons.travel_explore, t.selection_web_search,
                      'webSearch'),
                button(Icons.star_border, t.action_favorite, 'favorite'),
                if (hasAudio)
                  button(Icons.movie_creation_outlined, t.audiobook_export_clip,
                      'export'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _runSelectionAction(String action) async {
    final ReaderSelectionData? data = _selectionActionData;
    final int? selectionSection = _selectionActionSectionIndex;
    if (data == null) return;
    _removeSelectionActionBar();
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
        FushiToast.show(
          msg: t.copied_to_clipboard,
          severity: ToastSeverity.success,
        );
        await _clearReaderAppSelection();
        return;
      case 'share':
        final bool shared = await SelectionExternalActions.instance.shareText(
          data.text,
        );
        if (mounted && !shared) {
          FushiToast.show(
            msg: t.selection_share_failed,
            severity: ToastSeverity.error,
          );
        }
        await _clearReaderAppSelection();
        return;
      case 'webSearch':
        final bool opened = await SelectionExternalActions.instance.searchWeb(
          data.text,
        );
        if (mounted && !opened) {
          FushiToast.show(
            msg: t.selection_web_search_unavailable,
            severity: ToastSeverity.error,
          );
        }
        await _clearReaderAppSelection();
        return;
      case 'favorite':
        await _toggleFavoriteSentence(
            selection: data, selectionSection: selectionSection);
        await _clearReaderAppSelection();
        return;
      case 'export':
        // TODO-1366: same backend as desktop (_exportAudiobookClip) but fed from
        // the app-drawn selection payload; clear grips + highlight afterward.
        await _exportAudiobookClipFromSelectionData(data);
        await _clearReaderAppSelection();
        return;
      default:
        return;
    }
  }

  // Clear the reader's app-drawn selection (fushi-selection CSS Custom Highlight)
  // *and* the native selection with it: ReaderSelectionScripts.clearInvocation()
  // runs fushiSelection.clearSelection(), whose first statement is
  // `window.getSelection()?.removeAllRanges()` (reader_selection_scripts.dart
  // `clearSelection`). BUG-1344 depends on that — WKWebView otherwise paints the
  // defocused native selection as a grey block that survives app switching.
  // Best-effort: a half-torn-down WebView throws MissingPluginException on eval;
  // swallow it (nothing to clear).
  Future<void> _clearReaderAppSelection() async {
    _removeSelectionActionBar();
    try {
      await _controller?.evaluateJavascript(
        source: ReaderSelectionScripts.clearInvocation(),
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderFushi.clearReaderAppSelection', e, stack);
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
      // BUG-005 同根因（TODO-678）：半销毁 WebView / window.fushiSelection 未注入时
      // eval 抛 MissingPluginException / TypeError，且本方法被菜单 fire-and-forget 调用，
      // 异常会逃当前 zone。失败退回 null —— 菜单「查词」调用方据此用 selectedText 兜底
      // 补满 currentSentence 非空契约，导出路径走空选区文案。
      ErrorLogService.instance
          .log('ReaderFushi.fillLookupStateFromNativeSelection.eval', e, stack);
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
      selection: FushiTextSelection(
        text: ReaderSelectionScripts.resolveCurrentSentenceText(
          data.sentence,
          data.text,
        ),
      ),
    );
    _cachedSentenceOffset = data.sentenceOffset;
    _cacheMatchableSelection(data);
    // cue 解析三级回退，从最强的判据开始：
    // ① `audioCuePayload` 是 JS 在点击处直接回传的 **cue 身份**
    //    （`fushiReader.cueIdAtPoint` 的 `{type:'sid'|'frag', id}`），不做任何坐标
    //    运算，对本轮修的「学习单位 / 音频 UTF-16 两套坐标混用」天然免疫；
    // ② 没有 payload 的书（DOM 里不带 cue id）退到按**音频坐标** matchableOffset
    //    在本章 cue 的 fragment 区间里反查——比原先按句子文本找精确；
    // ③ 仍无命中再退到句子文本匹配（见下方 _findCueForSentence）。
    final List<AudioCue>? allCues = _cachedAllCues;
    if (data.audioCuePayload != null && allCues != null) {
      _lookupCue = cueForPointerPayload(data.audioCuePayload!, allCues);
    } else {
      _lookupCue = null;
    }
    _lookupCue ??= data.matchableOffset != null
        ? _findCueForOffset(data.matchableOffset!)
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
      FushiToast.show(
          msg: t.audiobook_export_clip_no_text, severity: ToastSeverity.error);
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
    _removeSelectionActionBar();
    try {
      await _controller?.evaluateJavascript(
        source: 'window.fushiSelection.hideSelectionHandles()',
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderFushi.hideReaderSelectionHandles', e, stack);
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
          .log('ReaderFushi.extractSelectionClipImages.eval', e, stack);
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
          'ReaderFushi.extractSelectionClipImages.skipSvg',
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
            .log('ReaderFushi.extractSelectionClipImages.read', e, stack);
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
      FushiToast.show(
          msg: t.audiobook_export_clip_no_text, severity: ToastSeverity.error);
      return;
    }
    _exportAudiobookClip();
  }

  Future<void> _shareReaderImage(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      FushiToast.show(
          msg: t.reader_image_file_unavailable, severity: ToastSeverity.error);
      return;
    }
    try {
      await FushiShare.shareFiles(
        <XFile>[XFile(file.path, mimeType: fallbackMimeType(file.path))],
        subject: p.basename(file.path),
      );
    } catch (e) {
      FushiToast.show(
          msg: t.reader_image_share_failed(error: e),
          severity: ToastSeverity.error);
    }
  }

  Future<void> _copyReaderImageToClipboard(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      FushiToast.show(
          msg: t.reader_image_file_unavailable, severity: ToastSeverity.error);
      return;
    }
    try {
      await FushiChannels.clipboardImage.invokeMethod<void>(
        'copyImageFile',
        <String, String>{'path': file.path},
      );
      FushiToast.show(
          msg: t.copied_to_clipboard, severity: ToastSeverity.success);
    } catch (e) {
      FushiToast.show(
          msg: t.reader_image_copy_failed(error: e),
          severity: ToastSeverity.error);
    }
  }

  void _openImageViewer(String imgUrl) {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) return;
    // BUG-2208：全屏看图期间停表（路由 pop 后按判据续表）。
    unawaited(
      _withStudyClockPaused(
        () => Navigator.push(
          context,
          PageRouteBuilder<void>(
            opaque: false,
            barrierColor: Theme.of(
              context,
            ).colorScheme.scrim.withValues(alpha: 0.87),
            barrierDismissible: true,
            pageBuilder: (BuildContext routeContext, __, ___) =>
                ContextMenuTrigger(
              // 右键菜单改由绑定表决定唤出键（默认仍是右键）；右键被别的动作占用时自动让位。
              onInvoke: isWindowsPlatform
                  ? (Offset position) => unawaited(
                        _showReaderImageContextMenuAtGlobalPosition(
                          imgUrl,
                          position,
                          menuContext: routeContext,
                        ),
                      )
                  : null,
              ladder: kReaderMouseLadder,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 10,
                  child: Center(
                    child: Image.file(file, fit: BoxFit.contain),
                  ),
                ),
              ),
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
    // BUG-2208：插图画廊是从阅读器 push 出去的全页路由，压住期间停表。
    unawaited(
      _withStudyClockPaused(
        () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (BuildContext routeContext) => ReaderGalleryPage(
              // 节头用真实章名（TOC 命中）；命不中时页面自己退到「第 N 章」。
              chapterLabelFor: _currentChapterLabelFor,
              images: images,
              currentChapter: currentChapter,
              blurImages: _settings?.blurImages ?? false,
              revealedImageKeys: _revealedImageKeys,
              onRevealImage: (String key) {
                if (!_revealedImageKeys.add(key)) return;
                final String? bookUid = _bookUid;
                if (bookUid != null) {
                  unawaited(appModel.database.markImageRevealed(
                    bookUid,
                    key,
                    DateTime.now().millisecondsSinceEpoch,
                  ));
                }
                unawaited(_controller?.evaluateJavascript(source: '''
                  (function() {
                    var key = ${jsonEncode(key)};
                    if (window.__fushiMarkImageRevealed) {
                      window.__fushiMarkImageRevealed(key);
                    }
                    if (!window.__fushiImageRevealKey) return;
                    document.querySelectorAll('img.blurred, svg.blurred').forEach(function(el) {
                      if (window.__fushiImageRevealKey(el) === key) el.classList.remove('blurred');
                    });
                  })();
                '''));
              },
              fileForRef: (EpubImageRef ref) =>
                  _readerImageFileForUrl(ReaderFushiSource.epubUrl(ref.src)),
              onOpenImage: (EpubImageRef ref) =>
                  _openImageViewer(ReaderFushiSource.epubUrl(ref.src)),
              onJumpTo: (EpubImageRef ref) {
                Navigator.pop(routeContext);
                unawaited(_navigateToChapter(ref.chapterIndex, manual: true));
              },
            ),
          ),
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

  /// BUG-1423：键盘 / 手柄的 `readerToggleChrome` 唯一入口。
  ///
  /// 悬浮底栏（TODO-975 默认形态）下 [_showChrome] 只是「底栏功能是否启用」这层
  /// **不可见**的持久开关，用户真正看到的是 [_chromeTransientVisible] + 自动收起
  /// 计时器 [_chromeAutoHideTimer]。直接调 [_toggleChrome] 只翻那个不可见旗标，
  /// 既不改真实可见态也不续期计时器 —— 表现就是「按快捷键什么都没发生，必须先用
  /// 鼠标点一下空白把栏唤出来」。指针路径（点空白 / 点顶部进度）走的是
  /// [_handleFloatingChromeReveal]，本方法让键盘/手柄进同一台状态机（可见即收起
  /// 并取消计时、隐藏即唤出并重新武装计时），随后与 [_toggleChrome] 一样用
  /// `FocusReclaimCause.chromeToggled` 把焦点确认回正文。
  ///
  /// 底栏仍是挤压模式时（悬浮开关关闭）没有临时可见态，保留 [_toggleChrome] 旧
  /// 语义；只开顶部进度悬浮、底栏挤压的混合形态同样走挤压分支，与指针路径一致。
  void _toggleChromeFromShortcut() {
    if (_bottomBarFloating) {
      // _bottomBarFloating ⇒ _anyChromeFloating，所以这里恒被消费；断言锁住这个
      // 蕴含关系，防止将来有人把 _anyChromeFloating 的定义改窄后此路静默变 no-op。
      final bool handled = _handleFloatingChromeReveal();
      assert(handled, 'a floating bottom bar must enable floating chrome');
      _focusOwnership.reclaim(FocusReclaimCause.chromeToggled);
      return;
    }
    _toggleChrome();
  }

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
    // never short-circuited by a focused bar.
    //
    // Cause is [FocusReclaimCause.chromeToggled], NOT `overlayClosed`: the bar is
    // this page's own chrome, not an overlay stacked on top of it, so there is no
    // other legitimate focus owner to yield to. `chromeToggled` therefore skips
    // the strict content-ready/lyrics/caret/popup gating that `overlayClosed`
    // carries — this reclaim is a re-assertion (a no-op when the content already
    // holds focus), and gating it would silently drop the keyboard in lyrics mode
    // or before content is ready.
    _focusOwnership.reclaim(FocusReclaimCause.chromeToggled);
  }

  Future<void> _applyChromeInsets() async {
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    // TODO-975：底栏预留经单一真相源 _readerBottomReserve（悬浮态恒 0、挤压态含底栏高
    // + 系统 inset），取代散落的 `_showChrome ? height+inset : inset` 三元式。
    final double top = _readerTopOffset;
    final double bottom = _readerBottomReserve;
    // 下发给 WebView 的 chrome 预留是「正文顶部/底部空带」的唯一来源；用户报「悬浮态
    // 顶部空带依旧在」时，导出的诊断日志里能直接看到每次下发的分项，不必再猜。
    studyDiag(
      'chrome',
      'insets top=$top bottom=$bottom '
          'sysTop=$_stableTopInset sysBottom=$_stableBottomInset '
          'header=$_desktopHeaderReserve progress=$_topProgressReserve '
          'bar=$_bottomChromeReserve footerBand=$_statusFooterBand '
          'floating=$_bottomBarFloating showChrome=$_showChrome',
    );
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
          .log('ReaderFushi.reapplyChromeInsetsAfterFirstLoad', e, s);
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

  void _cancelChromeAutoHide() => _chrome.cancelAutoHide();

  /// 武装自动收起：计时到点由 [ReaderChromeController] 收起临时可见态并通知重建。
  void _armChromeAutoHide() {
    final int millis = ReaderFushiSource.instance.autoHideChromeMillis;
    _chrome.armAutoHide(Duration(milliseconds: millis));
  }

  /// VN 空白点推进时用的「保证悬浮 chrome 可见并重新计时」——与
  /// [_handleFloatingChromeReveal] 的**区别是不 toggle**：那个在已可见时会立即收起
  /// （决策#4，给的是「点一下开、再点一下关」的开关语义），而 VN 空白点是「翻页」，
  /// 顺手把底栏顶上来只是副作用，绝不能因为连点两下就把菜单关掉。
  ///
  /// 每次推进都重新 [_armChromeAutoHide]：停手 3 秒后收起，连续翻页期间常驻。
  void _revealFloatingChromeForVnAdvance() {
    if (!_anyChromeFloating) return;
    if (!_chromeTransientVisible) {
      _rebuild(() {
        _chromeTransientVisible = true;
      });
    }
    _armChromeAutoHide();
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

  /// 鼠标在正文上移动 → 唤出 / 续命悬浮 chrome（与视频页同一手感）。
  ///
  /// 两条腿、同一门 [hostOwnsWebViewPointerInput]（与 [_handleReaderPointerDown]
  /// 逐字相同的互斥判据）：Windows 上 WebView 是纹理、Flutter 拿指针，页面根
  /// [Listener.onPointerHover] 直接进这里；其它平台原生 WebView 吃掉指针，由页内 JS
  /// `mousemove` 节流回传 `onPointerHoverReveal`（[_handleJsHoverReveal]）。
  ///
  /// 决策在纯函数 [readerHoverRevealAction]：非悬浮 / 非鼠标 → 不动；已收起 →
  /// 唤出 + 武装；已可见 → 只重新武装（移动中常驻，停手后按计时收起）。
  /// 替代了此前只占顶部 6px 的悬停热区——那条带子从正文中间横向移动碰不到，
  /// 用户的感受就是「控制栏没有自动恢复」。
  void _handleReaderPointerHover(PointerHoverEvent event) {
    if (!hostOwnsWebViewPointerInput) return;
    _applyHoverReveal(isMouse: event.kind == PointerDeviceKind.mouse);
  }

  /// JS 腿（非 Windows）：页内 mousemove 已按设备类型过滤（只有真实鼠标产生
  /// mousemove），这里视作鼠标。
  void _handleJsHoverReveal() {
    if (hostOwnsWebViewPointerInput) return;
    _applyHoverReveal(isMouse: true);
  }

  void _applyHoverReveal({required bool isMouse}) {
    if (!_hasEverLoaded || _sideSheetOpen || _appearanceSheetOpen) return;
    // 停在栏上：栏自己的 MouseRegion 已取消计时，这里不再 re-arm。
    if (_chromeHovered) return;
    switch (readerHoverRevealAction(
      floating: _anyChromeFloating,
      transientVisible: _chromeTransientVisible,
      isMouse: isMouse,
    )) {
      case ReaderHoverRevealAction.none:
        return;
      case ReaderHoverRevealAction.reveal:
        _rebuild(() {
          _chromeTransientVisible = true;
        });
        _armChromeAutoHide();
      case ReaderHoverRevealAction.rearm:
        _armChromeAutoHide();
    }
  }

  /// BUG-1195：VN（视觉小说）模式下一次「空白点击」的唯一落点。
  ///
  /// 旧实现在 JS 侧 [_gestureEnd] 里直接 `window.fushiReader.paginate('forward')`
  /// 并 return，抢在查词 / `onTapEmpty` 之前把每一次空白点都吃掉——而 `onTapEmpty`
  /// 是触屏唯一能唤出控制栏的通道，于是 VN 下底栏（悬浮态默认几秒后自动收起）一旦
  /// 收起就永远唤不回来。现在 JS 只回传「这是一次 VN 空白点」，翻页还是唤栏由 Dart
  /// 这个**状态拥有者**判定（chrome 可见性只有 Dart 知道：悬浮态的真值是
  /// `_chromeTransientVisible`，JS 侧 `__fushiTapGate.chrome` 镜像的是 `_showChrome`，
  /// 悬浮态下恒 true，根本区分不出「已自动收起」）。
  ///
  /// 顺带修好一处旧漏：JS 直调 paginate 会丢弃返回值，屏到章末返回 "limit" 也没人
  /// 处理 → VN 点击推进到章末就卡住。现在走 [_paginate] 这个唯一翻页入口，跨章
  /// （[_handlePageTurnLimit]）/ 节流 / caret 重锚全部与滑动、键盘路径一致。
  ///
  /// BUG-1245：悬浮底栏已隐藏时，这一下只唤栏、不推进。用户看到“底栏出来”的同时
  /// 丢掉当前句属于双重副作用；底栏已经可见时，下一次空白点击才推进。
  void _handleVnBlankTap() {
    if (_lyricsMode) return;
    // 与 onTapEmpty 同语义：有可见查词弹窗时，本次点击只清弹窗栈（BUG-072 续播 /
    // BUG-092 热槽），既不翻页也不动控制栏。
    if (isDictionaryShown) {
      clearDictionaryResult();
      return;
    }
    // 与 onTapEmpty 同语义（TODO-1366）：点空白顺带清掉残留的 app 自绘选区。
    _clearReaderAppSelection();
    // 本次 pointer 手势把 OS 焦点交给了 WebView，不夺回 Flutter _focusNode 就收不到
    // ESC（BUG-136）。翻页与唤栏两条分支都要。
    _focusOwnership.reclaim(FocusReclaimCause.gesture);
    dispatchReaderVnBlankTapAction(
      readerVnBlankTapAction(
        chromeExpanded: _showChrome,
        bottomBarFloating: _bottomBarFloating,
        transientVisible: _chromeTransientVisible,
      ),
      expandChrome: _toggleChrome,
      revealChrome: _revealFloatingChromeForVnAdvance,
      advance: () => unawaited(_paginate(ReaderNavigationDirection.forward)),
    );
  }

  /// TODO-693: appUiScale（整体界面缩放）变化时把连续模式阅读位置重锚回原字符，避免
  /// 弹回章节开头。
  ///
  /// 根因：连续模式阅读位置是裸 `window.scrollY`，没有分页模式的
  /// `registerSnapScroll`/`lockRootViewport` 保护。FushiAppUiScale 用新 scale 重建两层
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
  /// 模式即使误调，JS 侧 `beginUiScaleReanchor` 在分页 `window.fushiReader` 缺席，
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
        'ReaderFushi.reanchorContinuousForUiScale.begin',
        e,
        stack,
      ),
      onCommitError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderFushi.reanchorContinuousForUiScale.commit',
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
        'ReaderFushi.reanchorContinuousAfterRestore.begin',
        e,
        stack,
      ),
      onCommitError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderFushi.reanchorContinuousAfterRestore.commit',
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
        'ReaderFushi.reanchorForStyleChange.begin',
        e,
        stack,
      ),
      onCommitError: (Object e, StackTrace stack) =>
          ErrorLogService.instance.log(
        'ReaderFushi.reanchorForStyleChange.commit',
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
  // now always false, which the `gesture` branch of [_canOwnReaderFocus] relies
  // on. The audiobook bar passes a ValueKey so element identity survives the
  // play-bar ↔ settings-bar swap; the settings bar passes none (as before).
  Widget _wrapBottomChromeBar({Key? key, required Widget bar}) {
    return Positioned(
      key: key,
      left: MediaQuery.viewPaddingOf(context).left,
      right: MediaQuery.viewPaddingOf(context).right,
      // 桌面端底栏（有声书播放条）唤出时盖住状态行，但把状态行的文字并进播放条右端
      // （[_buildBarStatusText]）——底部只有一条，而不是播放条 + 状态行叠两条。
      // 窄屏读数独立成行时底栏坐在状态行的底部带之上（带已含系统底 inset）。
      bottom: _separatePlaybackStatus ? _statusFooterPaintedBand : 0,
      // BUG-1692：底栏排在 WebView **之后**绘制。不自带 RepaintBoundary 就会并进
      // 页面级 RepaintBoundary 那张 cull rect = 整窗的 PictureLayer，macOS engine
      // 把整窗写进 FlutterMutatorView 的 _hitTestIgnoreRegion，整块 WebView 收不到
      // 任何鼠标事件。包一层让底栏自成一张只覆盖自身高度的图层。
      child: RepaintBoundary(
        // 与顶栏同款：停在底栏上不自动收起，离开后重新武装。
        child: MouseRegion(
          onEnter: (_) => _onChromeHoverChanged(true),
          onExit: (_) => _onChromeHoverChanged(false),
          child: ExcludeFocus(
          child: FocusScope(
            node: _chromeFocusScope,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ReaderChromeScaler(
                  scale: _readerChromeScale,
                  baseHeight: _ReaderFushiPageState._readerChromeBaseHeight,
                  child: bar,
                ),
                ColoredBox(
                  color: _chromeSurfaceColor(),
                  child: SizedBox(
                    height: _separatePlaybackStatus ? 0 : _stableBottomInset,
                    width: double.infinity,
                  ),
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// 顶栏 / 底栏 MouseRegion 进出：进 → 停表，出 → 悬浮可见态下重新武装。
  void _onChromeHoverChanged(bool hovered) {
    _chromeHovered = hovered;
    if (hovered) {
      _chrome.cancelAutoHide();
    } else if (_anyChromeFloating && _chromeTransientVisible) {
      _armChromeAutoHide();
    }
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
    // 底栏三个槽位（用户在布局编辑器里拖进来的按钮）有货才画；默认布局底栏为空，
    // 全部职能在顶部工具栏 [_buildDesktopHeader]。有声书播放条是媒体传输面，
    // 在场时底栏槽位的按钮并进它的右端（[_buildAudiobookBar]）。
    if (!_bottomSlotsHaveButtons) {
      return const SizedBox.shrink();
    }
    return _buildSettingsBar();
  }

  // ── 按钮布局（ReaderControlLayout，与视频页同一套泛型模型）──────────────

  ReaderControlLayout get _controlLayout => appModel.readerControlLayout;

  /// 按钮在当前运行态下是否渲染（与布局正交：布局说「放哪」，这里说「此刻有没有」）。
  bool _shouldRenderReaderControl(ReaderControlItem item) {
    switch (item) {
      case ReaderControlItem.back:
      case ReaderControlItem.statistics:
      case ReaderControlItem.title:
      case ReaderControlItem.settings:
        return true;
      // 歌词模式必须挂着有声书控制器（[_toggleLyricsMode] 进入分支的前置），没有
      // 控制器就没有可切的歌词，这颗键整个不出现。
      case ReaderControlItem.modeToggle:
        return _audiobookController != null;
      case ReaderControlItem.navigation:
      case ReaderControlItem.gallery:
        return !_lyricsMode;
      // 「听书」模块关掉时整颗不渲染（不是画一个点了没反应的按钮）。
      case ReaderControlItem.audiobook:
        return _moduleVisibility.isEnabled(ModuleId.listening);
      // 桌面才有窗口可全屏，移动端不渲染这颗按钮。
      case ReaderControlItem.fullscreen:
        return desktopWindowFullscreenSupported;
    }
  }

  List<ReaderControlItem> _renderableControlsIn(ReaderControlSlot slot) =>
      _controlLayout
          .itemsIn(slot)
          .where(_shouldRenderReaderControl)
          .toList(growable: false);

  bool get _bottomSlotsHaveButtons => ReaderControlSlot.values
      .where((ReaderControlSlot s) => s.isBottom)
      .any((ReaderControlSlot s) => _renderableControlsIn(s).isNotEmpty);

  /// 一颗按钮的动作描述（图标按运行态、文案带快捷键、pinned 决定窄窗是否折进 ⋮）。
  /// 布局只决定它在哪个槽；这里是「按下去干什么」的唯一真相源。
  ReaderHeaderAction _readerControlAction(ReaderControlItem item) {
    final bool lyrics = _lyricsMode;
    switch (item) {
      case ReaderControlItem.back:
        return ReaderHeaderAction(
          icon: Icons.arrow_back,
          label: t.back,
          pinned: true,
          semanticsId: 'hibiki.reader.header.back',
          // 与面板「退出」同一条路：maybePop 触发 PopScope → onWillPop
          // （落位置 flush / closeMedia / 关书同步，BUG-782）。
          onPressed: () => unawaited(Navigator.of(context).maybePop()),
        );
      case ReaderControlItem.modeToggle:
        return ReaderHeaderAction(
          key: const ValueKey<String>('fushi_reader_lyrics_mode_button'),
          icon: lyrics ? Icons.auto_stories_outlined : Icons.lyrics_outlined,
          label: lyrics ? t.book_mode : t.lyrics_mode,
          pinned: lyrics,
          semanticsId: 'hibiki.reader.header.lyrics_mode',
          onPressed: () => unawaited(_toggleLyricsMode()),
        );
      case ReaderControlItem.navigation:
        return ReaderHeaderAction(
          icon: Icons.format_list_bulleted,
          label: _labelWithShortcut(
            t.section_navigation,
            ShortcutAction.readerOpenNavigation,
          ),
          pinned: true,
          semanticsId: 'hibiki.reader.header.navigation',
          onPressed: () => unawaited(
            _showAppearanceSheet(initialSubPage: 'location'),
          ),
        );
      case ReaderControlItem.gallery:
        return ReaderHeaderAction(
          icon: Icons.collections_outlined,
          label: _labelWithShortcut(
            t.reader_gallery_tooltip,
            ShortcutAction.readerOpenGallery,
          ),
          onPressed: _openGallery,
        );
      case ReaderControlItem.statistics:
        return ReaderHeaderAction(
          icon: Icons.insights_outlined,
          label: _labelWithShortcut(
            t.reading_statistics,
            ShortcutAction.readerOpenStatistics,
          ),
          semanticsId: 'hibiki.reader.header.statistics',
          onPressed: _openReadingStatistics,
        );
      case ReaderControlItem.title:
        // 书名不是按钮：顶栏由 showsTitle 决定画不画，底栏槽位不接受它。
        return ReaderHeaderAction(
          icon: Icons.title,
          label: _book?.title ?? '',
          onPressed: null,
        );
      case ReaderControlItem.audiobook:
        return ReaderHeaderAction(
          icon: Icons.headphones_outlined,
          label: _labelWithShortcut(
            t.section_audiobook,
            ShortcutAction.readerOpenAudiobook,
          ),
          semanticsId: 'hibiki.reader.header.audiobook',
          // 已挂有声书 → 侧栏面板；没有 → 直接进导入。
          onPressed: _audiobookController != null
              ? () => unawaited(
                    _showAppearanceSheet(initialSubPage: 'audiobook'),
                  )
              : _openAudioImportDialog,
        );
      case ReaderControlItem.fullscreen:
        return ReaderHeaderAction(
          key: const ValueKey<String>('fushi_reader_fullscreen_button'),
          icon: _isWindowFullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          label: t.shortcut_action_global_toggle_fullscreen,
          semanticsId: 'hibiki.reader.bottom.fullscreen',
          onPressed: () => unawaited(_changeReaderWindowFullscreen()),
        );
      case ReaderControlItem.settings:
        return ReaderHeaderAction(
          key: const ValueKey<String>('fushi_reader_settings_button'),
          icon: Icons.tune_outlined,
          label: _labelWithShortcut(
            t.reader_settings_section,
            ShortcutAction.readerOpenMenu,
          ),
          pinned: true,
          semanticsId: 'hibiki.reader.bottom.settings',
          onPressed: () => unawaited(_showAppearanceSheet()),
        );
    }
  }

  List<ReaderHeaderAction> _readerControlActionsIn(ReaderControlSlot slot) =>
      <ReaderHeaderAction>[
        for (final ReaderControlItem item in _renderableControlsIn(slot))
          if (item != ReaderControlItem.title) _readerControlAction(item),
      ];

  /// 底栏槽位里的一颗按钮（与顶栏同款图标按钮）。
  Widget _readerControlButton(ReaderHeaderAction a) => ReaderDesktopHeaderButton(
        key: a.key,
        icon: a.icon,
        tooltip: a.label,
        color: _themeTextColor(),
        semanticsId: a.semanticsId,
        onPressed: a.onPressed,
      );

  /// 底栏三槽（左 / 中 / 右）排成一行：`[左…] Spacer [中…] Spacer [右…]`；
  /// 中槽为空时只剩左右两端。
  List<Widget> _bottomSlotButtons() {
    final List<ReaderHeaderAction> left =
        _readerControlActionsIn(ReaderControlSlot.bottomLeft);
    final List<ReaderHeaderAction> center =
        _readerControlActionsIn(ReaderControlSlot.bottomCenter);
    final List<ReaderHeaderAction> right =
        _readerControlActionsIn(ReaderControlSlot.bottomRight);
    return <Widget>[
      for (final ReaderHeaderAction a in left) _readerControlButton(a),
      const Spacer(),
      for (final ReaderHeaderAction a in center) _readerControlButton(a),
      if (center.isNotEmpty) const Spacer(),
      for (final ReaderHeaderAction a in right) _readerControlButton(a),
    ];
  }

  Widget _buildAudiobookBar() {
    final AudiobookPlayerController ctrl = _audiobookController!;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        return _wrapBottomChromeBar(
          key: const ValueKey<String>('fushi_play_bar'),
          bar: AudiobookPlayBar(
            controller: ctrl,
            skipActionSeconds: ReaderFushiSource.instance.skipActionSeconds,
            onOpenSettings: () =>
                unawaited(_showAppearanceSheet(initialSubPage: 'audiobook')),
            backgroundColor: _chromeSurfaceColor(),
            foregroundColor: _themeTextColor(),
            reversed: appModel.reverseReaderBottomBar,
            // TODO-830: per-reader 功能反转（getter 内部走 readerSettings?
            // 分层，否则退化全局）；与 reversed 的位置镜像维度正交。
            invertSkip: ReaderFushiSource.instance.invertAudiobookSkipDirection,
            // 桌面端：播放条唤出时覆盖状态行，阅读追踪 / 进度并进条右端；传输键与
            // 有声书面板同一套（-10s / 上一句 / 播放 / 下一句 / +10s）。
            // 底栏槽位里的按钮并进播放条右端（播放条在场时底栏只有这一条），
            // 状态读数仍在最右。
            trailing: _buildAudiobookBarTrailing(),
            showSeekButtons:
                _desktopChromeEnabled && _readerControlsWidth >= 308,
            showSettingsButton: !_desktopChromeEnabled,
          ),
        );
      },
    );
  }

  Widget? _buildAudiobookBarTrailing() {
    final List<Widget> buttons = <Widget>[
      for (final ReaderControlSlot slot in ReaderControlSlot.values)
        if (slot.isBottom)
          for (final ReaderHeaderAction a in _readerControlActionsIn(slot))
            _readerControlButton(a),
    ];
    final Widget? status = _playbackStatusInline ? _buildBarStatusText() : null;
    if (buttons.isEmpty) return status;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ...buttons,
        if (status != null) ...<Widget>[const SizedBox(width: 8), status],
      ],
    );
  }

  /// 小说页的窗口全屏切换（底栏按钮的执行体）。
  ///
  /// 与漫画页 `_changeMangaFullscreen` 同一范式：**先读 native 真值再取反**，而不是翻
  /// 自己那份镜像——用户可能刚用快捷键（默认 F11）切过，镜像会落后，按镜像取反就会
  /// 出现「点一下没反应、要点两下」。镜像只用来选图标。
  ///
  /// 串行闸 [_ReaderFushiPageState._windowFullscreenTransitioning] 挡住 native 往返
  /// 期间的重入；按钮本身不置灰（状态更新常早于 finally 清闸，置灰会让按钮闪一下）。
  Future<void> _changeReaderWindowFullscreen() async {
    if (!desktopWindowFullscreenSupported || _windowFullscreenTransitioning) {
      return;
    }
    _windowFullscreenTransitioning = true;
    try {
      final bool next =
          !((await readDesktopWindowFullscreen()) ?? _isWindowFullscreen);
      if (!mounted) return;
      final bool? applied = await setDesktopWindowFullscreen(next);
      if (!mounted || applied == null) return;
      if (_isWindowFullscreen != applied) {
        _rebuild(() => _isWindowFullscreen = applied);
      }
    } finally {
      _windowFullscreenTransitioning = false;
    }
  }

  /// 「返回上一级」在小说页的最后一级：**先退窗口全屏，没有全屏才退书**。
  ///
  /// 用户裁定 Esc 也要能退全屏。放在退书之前是唯一合理的次序——全屏是盖在书上面的一层
  /// 呈现态，而「返回」在本页一贯是「退掉最上面那层」（词典弹窗先于退书是同一条阶梯）。
  /// 漫画页的 PopScope 里有等价的一级，视频页则由它自己的全屏路由阶梯负责。
  ///
  /// [Navigator.of] 必须在第一个 await **之前**取：await 之后 context 可能已失效，
  /// 跨 async gap 用 BuildContext 是 lint 明令禁止的（也确实会炸）。
  Future<void> _exitWindowFullscreenOrPopReader() async {
    final NavigatorState navigator = Navigator.of(context);
    if (await exitWindowFullscreenIfActive()) {
      // 镜像必须在**这条**路径上也复位。只在按钮那条成功路径上复位是不够的：Esc 退掉
      // 的是同一个全屏，不同步的话底栏图标会稳定停在「退出全屏」上，而窗口早已不是全屏
      // 了 —— 图标撒谎，而且不会自愈（下一次按按钮读的是 native 真值，图标只是在那之后
      // 才碰巧变对）。
      if (mounted && _isWindowFullscreen) {
        _rebuild(() => _isWindowFullscreen = false);
      }
      return;
    }
    if (!mounted) return;
    await navigator.maybePop();
  }

  /// 进页时把底栏全屏按钮的图标镜像对到 native 真值一次。
  ///
  /// 没有这一次读取，「在别处（漫画页 / 视频页 / 上一本书）进的全屏里打开本书」会让图标
  /// 从第一帧起就是错的 —— 镜像默认 false，而窗口是全屏的。漫画页的
  /// `_readInitialFullscreenState` 是同一件事的同一份做法。
  ///
  /// 只读不写：读到什么就照着画什么图标，绝不在进页时替用户改窗口状态。
  Future<void> _readInitialWindowFullscreenState() async {
    final bool? fullscreen = await readDesktopWindowFullscreen();
    if (!mounted || fullscreen == null || fullscreen == _isWindowFullscreen) {
      return;
    }
    _rebuild(() => _isWindowFullscreen = fullscreen);
  }

  /// 底栏（无有声书播放条时）：只在用户把按钮拖进底栏槽位后才出现，内容全部
  /// 来自 [ReaderControlLayout]（默认布局底栏为空，职能都在顶部工具栏）。
  /// 「反转底栏」（reverseReaderBottomBar）仍是整体镜像。
  Widget _buildSettingsBar() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool reversed = appModel.reverseReaderBottomBar;
    final List<Widget> barItems = _bottomSlotButtons();
    return _wrapBottomChromeBar(
      key: const ValueKey<String>('fushi_reader_bottom_slots_bar'),
      bar: ColoredBox(
        color: _chromeSurfaceColor(),
        child: SizedBox(
          height: _ReaderFushiPageState._readerChromeBaseHeight,
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
      // _settings 就是 ReaderFushiSource.readerSettings 本体（见 initState 绑定），
      // 面板控件经 ReaderFushiSource.instance.ttu* 实时读写同一对象，开面板前后都
      // 无需设置同步——旧 TTU 双存储时代的 _syncSettings*Hive 已是写回自身的死桥，
      // 且 _syncSettingsToHive 会触发 17× onSettingsChangedLive 的 DB/WebView 风暴。
      final FavoriteSentenceRepository favRepo =
          FavoriteSentenceRepository(appModel.database);

      final List<FavoriteSentence> favorites =
          await _favoriteSentencesForBook();

      if (!mounted) return;

      // 所有平台共用左侧导航与右侧设置；有声书面板桌面/宽窗同走右侧侧栏，
      // 手机保留全高 bottom sheet。
      final bool useAudiobookSideSheet = readerAudiobookUsesSideSheet(
        desktop: isDesktopPlatform,
        window: MediaQuery.sizeOf(context),
      );
      final bool audiobookPanel =
          initialSubPage == 'audiobook' && _audiobookController != null;
      final ReaderQuickSettingsPresentation presentation = audiobookPanel
          ? ReaderQuickSettingsPresentation.audiobookPanel
          : initialSubPage == 'location'
              ? ReaderQuickSettingsPresentation.sideSheetNavigation
              : ReaderQuickSettingsPresentation.sideSheetAppearance;
      final Widget sheetContent = _buildQuickSettingsSheet(
        favorites: favorites,
        favRepo: favRepo,
        presentation: presentation,
        initialSubPage: initialSubPage,
      );

      // BUG-2208：外观 / 导航 / 搜索 / 收藏 / 有声书面板压着正文期间停表。
      await _withStudyClockPaused(
        () => _presentQuickSettings(
          sheetContent: sheetContent,
          presentation: presentation,
          useAudiobookSideSheet: useAudiobookSideSheet,
        ),
      );

      _syncDictionaryTheme();
      // BUG-2213：面板里可能改了空闲门分钟数，关掉即生效（不必等下次 _ensureStudyClock）。
      _studyClock?.idleTimeout = appModel.readingIdleTimeout;
    } finally {
      _appearanceSheetOpen = false;
      // 复位后重建把 blur 挂回 pill（dispose 后不能 setState，纯赋值已够）。
      if (mounted) _rebuild(() {});
    }
  }

  /// [_showAppearanceSheet] 的呈现分派（移动端有声书 sheet / 其余一律左右侧栏），
  /// 返回的 Future 在面板关闭后完成。
  Future<void> _presentQuickSettings({
    required Widget sheetContent,
    required ReaderQuickSettingsPresentation presentation,
    required bool useAudiobookSideSheet,
  }) async {
    if (presentation == ReaderQuickSettingsPresentation.audiobookPanel &&
        !useAudiobookSideSheet) {
      // 手机：全高 bottom sheet 承载面板（面板内部 Flexible 需要有界高度）。
      await adaptiveModalSheet<void>(
        context: context,
        builder: (BuildContext ctx) => SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.9,
          child: sheetContent,
        ),
      );
      return;
    }
    // 有声书面板曾是 680px 居中对话框（FushiDialogFrame）；用户 2026-09-13 拍板
    // 「和设置一样」——与导航 / 设置共用同一条右侧侧栏路由。
    await _presentSideSheet(
      // ッツ 形态：导航 / 章节贴左，外观设置 / 有声书贴右。
      side: presentation == ReaderQuickSettingsPresentation.sideSheetNavigation
          ? ReaderSideSheetSide.left
          : ReaderSideSheetSide.right,
      builder: (_) => sheetContent,
    );
  }

  /// 侧栏路由的唯一入口（导航 / 设置 / 有声书 / 统计共用）：开着期间控制栏不
  /// 自动收起（否则用户改设置时工具栏在背后消失，关抽屉后又要再唤一次）；关掉后
  /// 若仍是悬浮可见态，重新武装计时。
  Future<void> _presentSideSheet({
    required ReaderSideSheetSide side,
    required WidgetBuilder builder,
  }) async {
    _cancelChromeAutoHide();
    // BUG-2276：透明遮罩形态开始 / 结束的唯一两点。旗只在这里翻，
    // [_closeSideSheetForWebViewPointer] 只读，不存在第二个所有者。
    _sideSheetOpen = true;
    try {
      await showReaderSideSheet<void>(
        context: context,
        side: side,
        builder: builder,
      );
    } finally {
      _sideSheetOpen = false;
    }
    if (mounted && _anyChromeFloating && _chromeTransientVisible) {
      _armChromeAutoHide();
    }
  }

  /// BUG-2276：正文 WebView 上报的一次点击落在「侧抽屉正压着正文」的状态里时，
  /// 把它当成对遮罩的点击——关掉抽屉并**吞掉**这次点击（返回 true，调用方立即
  /// return，不再翻页 / 查词 / 收放控制栏）。
  ///
  /// 抽屉是路由，故走 [Navigator.maybePop]（与面板内「退出书籍」按钮同款：不绕过
  /// 任何 PopScope）。判据与「为什么 macOS 上这次点击会漏过 modal barrier」见
  /// [readerWebViewPointerClosesSideSheet]；其它平台该判据恒假，此方法恒返回
  /// false，行为与修复前逐字相同。
  bool _closeSideSheetForWebViewPointer() {
    if (!mounted) return false;
    final ModalRoute<Object?>? owner = ModalRoute.of(context);
    if (!readerWebViewPointerClosesSideSheet(
      sideSheetOpen: _sideSheetOpen,
      readerRouteIsCurrent: owner == null || owner.isCurrent,
    )) {
      return false;
    }
    unawaited(Navigator.of(context).maybePop());
    return true;
  }

  /// 组装书内快捷设置面板（居中对话框 / 移动端 sheet / 桌面端右侧抽屉共用同一份
  /// 回调接线，只有 [presentation] 不同）。
  Widget _buildQuickSettingsSheet({
    required List<FavoriteSentence> favorites,
    required FavoriteSentenceRepository favRepo,
    required ReaderQuickSettingsPresentation presentation,
    String? initialSubPage,
  }) {
    final List<TtuTocEntry> toc = _buildTtuToc();
    final String? extractDir = _extractDir;
    // 快照一次：[AppModel.moduleVisibility] 每读一次都重新合成一个 Set，下面三个
    // 有声书回调都要问它。
    final bool listeningEnabled = _moduleVisibility.isEnabled(
      ModuleId.listening,
    );
    return ReaderQuickSettingsSheet(
      controller: _audiobookController,
      toc: toc,
      coverPath: extractDir == null
          ? null
          : ReaderFushiSource.resolveCoverFilePath(
              extractDir: extractDir,
              coverPath: _book?.coverHref,
            ),
      readerProgress: (_currentChapter, _book!.chapters.length),
      onJumpSection: (int index, String? fragment) async {
        await _jumpToChapterAnchor(index, fragment);
      },
      // BUG-782：退出必须走 maybePop() 而非直接 pop()。直接 Navigator.pop()
      // 会绕过阅读器 PopScope(canPop:false) 的 onPopInvokedWithResult，使
      // onWillPop 整条链全部跳过——onSourcePagePop 的最终位置 flush（BUG-203）、
      // appModel.closeMedia 里对 fushiBooksProvider/bookLastReadAtProvider 的
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
      isFushiReader: true,
      initialSubPage: initialSubPage,
      onStyleChanged: _applyStylesLive,
      onThemeChanged: _onThemeChanged,
      extractDir: _extractDir,
      onReloadChapter: _reloadWithCurrentSettings,
      onLyricsReload: _loadLyricsPage,
      // 「听书」关掉时三个有声书回调一律传 null——面板侧已有「回调为空就不渲染
      // 该行」的既有契约，用同一条通道关掉「导入音频 / 换对齐文件 / 设备端转录」。
      onAudioImport: listeningEnabled && _srtBookUid != null
          ? _openAudioImportDialog
          : null,
      // 有声书面板「资源」页：对齐文件 / 转录只对 EPUB 有声书开放（standalone
      // SRT 书走 _openSrtBookReimport 一条路）。
      onPickAlignment:
          listeningEnabled &&
              _srtBookUid == null &&
              _audiobookController != null
          ? () => unawaited(_openAlignmentImportDialog())
          : null,
      onTranscribe:
          listeningEnabled &&
              _srtBookUid == null &&
              _audiobookController != null &&
              isAsrSupported
          ? () => unawaited(_transcribeFromAudiobookPanel())
          : null,
      lyricsMode: _lyricsMode,
      onToggleLyricsMode: _toggleLyricsMode,
      showFloatingLyric: appModel.showFloatingLyric,
      onToggleFloatingLyric: _toggleFloatingLyric,
      floatingLyricFontSize: appModel.floatingLyricFontSize,
      onFloatingLyricFontSizeChanged: (v) async {
        await appModel.setFloatingLyricFontSize(v);
        final FloatingLyricStyle style = _readerFloatingLyricStyle(fontSize: v);
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
      charProgress: _progressCurrentChars != null && _progressTotalChars != null
          ? (_progressCurrentChars!, _progressTotalChars!)
          : null,
      onJumpToCharOffset: (globalOffset) async {
        _jumpToGlobalCharOffset(globalOffset);
      },
      epubBook: _book,
      chapterLabel: _currentChapterLabel(),
      onSearchJump: (BookSearchResult result, String query) async {
        if (!mounted || _book == null || _controller == null) return;
        // 搜索跳转是跳转不是阅读：字数账本（ReadUnitLedger）不需要播种——跳走前那页
        // 在落点的首个 arrive 时结算，命中处之前跳过的正文从未成为当前单元、不计。
        final String preciseLocateJs =
            ReaderPaginationScripts.scrollToSearchMatchInvocation(
          query,
          result.charOffset,
        );
        final ReaderSearchJumpAction action = decideReaderSearchJump(
          targetChapter: result.sectionIndex,
          currentChapter: _currentChapter,
          restoreInFlight: _restoreInFlight,
          readerContentReady: _readerContentReady,
        );
        switch (action) {
          case ReaderSearchJumpAction.navigate:
            // TODO-1309：跨章搜索跳转把「章内定位」排进导航的原子恢复链（settle 之后应用），
            // 不再在 restore 完成微任务里抢发被 settle-reflow / 连续重锚采样冲回章首（双跳，
            // 首跳只到章节）。去掉旧的首跳失败早退分支——旧代码首跳超时/代际 stale 时会停在
            // 章首、要点第二次才走「同章直接 restore」才生效；现在定位随恢复落定 settle
            // 之后由 _applyPendingPreciseLocate 确定性应用。文本命中无法用分数烘进 shell，故走
            // preciseLocateJs 队列（书签/收藏用 progress 烘进导航）。
            await _navigateToChapterAndWait(
              result.sectionIndex,
              manual: true,
              preciseLocateJs: preciseLocateJs,
            );
            return;
          case ReaderSearchJumpAction.replacePending:
            // _currentChapter 在 loadUrl 前就切到逻辑目标章。DOM 尚未 ready 时再次选择
            // 同章结果，必须更新本导航代际的 pending；直接 evaluate 会命中旧 DOM，
            // 且首条 pending 会在 restore settle 后反过来覆盖用户最后一次选择。
            _preciseLocateQueue.replace(
              generation: _navigateGeneration,
              js: preciseLocateJs,
            );
            return;
          case ReaderSearchJumpAction.evaluateNow:
            // 同章且 DOM 已 settle：直接定位（既有正常路径）。
            await _controller!.evaluateJavascript(source: preciseLocateJs);
            return;
        }
      },
      favoriteSentences: favorites,
      favoritePositionLabel: _favoritePositionLabel,
      onDeleteFavorite: (fav) async {
        await favRepo.removeById(fav.id);
        _invalidateFavoriteSentenceCache();
        if (fav.sectionIndex == _currentChapter || _lyricsMode) {
          await _refreshSectionHighlights(fav.sectionIndex ?? _currentChapter);
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
                  _audiobookController!.sentenceAudioCuesForSection(section);
              AudioCue? target;
              for (final AudioCue cue in cues) {
                final SubtitleRematchFragment? frag =
                    SubtitleRematchCodec.tryDecode(cue.textFragmentId);
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
      presentation: presentation,
      onOpenStatistics: _openReadingStatistics,
      // 导航抽屉（Ctrl+F / 工具栏目录键）在桌面端打开即聚焦书内搜索框；移动端
      // 不 autofocus，否则软键盘顶起来就把章节目录压掉半屏（见判据文档）。
      autofocusSearch: readerNavigationAutofocusesSearch(
        navigationPresentation:
            presentation == ReaderQuickSettingsPresentation.sideSheetNavigation,
        desktop: isDesktopPlatform,
      ),
      initialSideSheetTab: _chrome.lastSettingsTab,
      onSideSheetTabChanged: (String id) => _chrome.lastSettingsTab = id,
      expandedTocParents: _chrome.expandedTocParents,
    );
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
    final InAppWebViewController controller = _controller!;
    final int generation = _navigateGeneration;
    final int chapter = _currentChapter;
    final dynamic result;
    try {
      result = await controller.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
    } catch (e, stack) {
      // 半销毁的 WebView 上 evaluateJavascript 抛 PlatformException；此处尚未改
      // 任何恢复状态，安全 no-op 返回（此前这是 try 块外的孤儿 await，会逃 zone）。
      ErrorLogService.instance.log(
        'ReaderFushi.reloadWithCurrentSettings.eval',
        e,
        stack,
      );
      return;
    }
    if (!mounted ||
        generation != _navigateGeneration ||
        chapter != _currentChapter ||
        !identical(controller, _controller) ||
        _lyricsMode) {
      return;
    }
    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    final bool hasSameChapterCache = _lastProgressSection == _currentChapter;
    _initialProgress =
        snapshot?.progress ?? (hasSameChapterCache ? _lastProgressValue : 0.0);
    // BUG-162 / TODO-219: reload 是同章程序化重建，优先沿用稳定精确锚；
    // stable gate 暂时不给快照时保留同章缓存，避免把瞬态章首 0 当新位置。
    _initialCharOffset =
        snapshot?.charOffset ??
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
    debugPrint(
      '[ReaderFushi] reloadWithCurrentSettings: '
      'chapter=$_currentChapter progress=$_initialProgress '
      'generation=$gen continuous=${_settings?.isContinuousMode}',
    );

    _rebuild(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();

    try {
      await _loadChapterDirectly(_currentChapter);
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderFushi.reloadWithCurrentSettings',
        e,
        stack,
      );
      debugPrint('[ReaderFushi] reloadWithCurrentSettings failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  // ── Desktop header (ッツ / Hoshi Reader 形态) ──────────────────────

  /// 各平台顶部工具栏：左「← 返回 /（歌词⇄阅读）/ 导航 / 插图 / 统计」，居中书名，
  /// 右「有声书导入 / 全屏 / 外观设置」。取代桌面端的底部设置栏，与底栏同一台显隐
  /// 状态机（[_bottomBarShouldPaint]：悬浮态点空白唤出 + 自动收起；挤压态常驻并占
  /// [_desktopHeaderReserve]）。
  ///
  /// **歌词模式同样在场**（[_desktopChromeEnabled]），但动作按模式取舍：导航与插图
  /// 在歌词页是空转——翻章会把歌词文档换成 EPUB 章节（[_paginate] 为此专门早返回），
  /// 画廊也没有对应的正文位置——故只在正文模式挂；换来的是「歌词 ⇄ 阅读」这颗模式键，
  /// 歌词模式下它是**唯一**可见的回正文入口（另一处在设置抽屉的排版页里），所以那时
  /// 强制 `pinned`，窄窗也不许折进 ⋮ 溢出菜单。
  ///
  /// 纯指针面：包 ExcludeFocus，不进焦点遍历池（与 [_wrapBottomChromeBar] 同一规则，
  /// TODO-700 不变式）。BUG-1692：排在 WebView 之后绘制，必须自带 RepaintBoundary。
  /// 动作文案后缀绑定键（`插图画廊 · G`），让快捷键在工具栏 tooltip 里可见。
  String _labelWithShortcut(String label, ShortcutAction action) {
    final List<InputBinding> keys =
        appModel.shortcutRegistry.bindingsFor(action).keyboardBindings;
    if (keys.isEmpty) return label;
    return '$label · ${keys.first.displayLabel}';
  }

  Widget _buildDesktopHeader() {
    if (!_desktopChromeEnabled || !_bottomBarShouldPaint) {
      return const SizedBox.shrink();
    }
    final Color fg = _themeTextColor();
    final ReaderControlLayout layout = _controlLayout;
    return Positioned(
      top: _stableTopInset,
      left: MediaQuery.viewPaddingOf(context).left,
      right: MediaQuery.viewPaddingOf(context).right,
      // 焦点排除在 ReaderDesktopHeader 内部（纯指针面，TODO-700 不变式）；底栏的
      // ExcludeFocus 外壳仍唯一在 _wrapBottomChromeBar（守卫 reader_focus_chrome_excluded）。
      child: RepaintBoundary(
        // 悬停在工具栏上不自动收起（取消计时），离开后重新武装。
        child: MouseRegion(
          onEnter: (_) => _onChromeHoverChanged(true),
          onExit: (_) => _onChromeHoverChanged(false),
          child: ReaderDesktopHeader(
            key: const ValueKey<String>('fushi_desktop_header'),
            title: layout.showsTitle ? (_book?.title ?? '') : '',
            textColor: fg,
            backgroundColor: _chromeSurfaceColor(),
            // 左 / 右两组按钮来自布局的 topLeft / topRight 槽（用户可在设置里拖动）；
            // pinned = 窄窗紧凑形态仍保留的按钮，其余收进 ⋮ 溢出菜单。
            leading: _readerControlActionsIn(ReaderControlSlot.topLeft),
            trailing: _readerControlActionsIn(ReaderControlSlot.topRight),
          ),
        ),
      ),
    );
  }

  /// 顶部工具栏「统计」：右侧侧栏「书内统计」——实时秒表 + 暂停键 / 本次字数与
  /// 字时 / 阅读位置（本章、全书进度条）/ 今天（时长、字数、查词、制卡）/ 本书累计 /
  /// 预计读完 / 打开完整记录。
  ///
  /// 此前是 640px 居中对话框并经 `_withStudyClockPaused` 停表（BUG-2208：弹层压着
  /// 正文不算阅读）。侧栏不遮正文、正文照常可读，故**不停表**——样稿要的就是一块
  /// 实时走的秒表加一颗暂停键（[_toggleStudyClockManualPause]，与状态行计时块
  /// 同一入口）。
  void _openReadingStatistics() {
    if (_sideSheetOpen) return;
    unawaited(
      _presentSideSheet(
        side: ReaderSideSheetSide.right,
        builder: (_) => ReaderStatisticsSheet(
          bookTitle: _book?.title ?? '',
          sessionTotals: _readingSessionTotals,
          loadBookTotals: _loadReaderBookStatTotals,
          progress: () => (
            chapterCurrent: _footerChapterCurrentChars,
            chapterTotal: _footerChapterTotalChars,
            bookCurrent: _progressCurrentChars,
            bookTotal: _progressTotalChars,
          ),
          onTogglePause: _toggleStudyClockManualPause,
          onOpenFullRecords: () {
            Navigator.of(context).maybePop();
            unawaited(_openStatisticsCenter());
          },
        ),
      ),
    );
  }

  /// 统计侧栏「打开完整记录」→ 统计中心（阅读 tab）。
  Future<void> _openStatisticsCenter() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const StatisticsCenterPage(initialTab: StatsCenterTab.reading),
      ),
    );
  }

  /// 手动计时开关：暂停 → `stop()` 结算并封段；继续 → `start()` 重锚 tick 起点开
  /// 新段。旗标同时门住 [_ensureStudyClock] 与生命周期 resumed 的自动起表。
  ///
  /// 入口只有底部状态行左侧的计时器（[ReaderStatusFooter.onTapTracker]）——在正文
  /// 里点，停 / 续当场生效。统计浮层里曾另有一个同功能按钮，但开浮层本身就经
  /// [_withStudyClockPaused] 停表（BUG-2208），层内那个按钮改不动当下的运行态。
  void _toggleStudyClockManualPause() {
    _ensureStudyClock();
    final bool pause = !_studyClockManualPause;
    _rebuild(() => _studyClockManualPause = pause);
    // 统一判据（BUG-2209）：切后台期间点「继续」只是清旗、回前台再起表。
    _syncStudyClockRunState();
  }

  /// 有声书面板「对齐文件」：打开导入对话框并预填当前音频（对话框内可选文件 /
  /// 转录），关掉后按导入后的同一条路重载音频槽。
  Future<void> _openAlignmentImportDialog(
      {String? initialAlignmentPath}) async {
    final Audiobook? audiobook = _audiobookController?.audiobook;
    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    // BUG-2208：导入 / 对齐对话框压着正文期间停表。
    await _withStudyClockPaused(
      () => showAppDialog<void>(
        context: context,
        builder: (ctx) => AudiobookImportDialog(
          bookKey: widget.bookKey,
          repo: repo,
          extractDir: _extractDir,
          initialAudioPaths: audiobook?.audioPaths,
          initialAlignmentPath: initialAlignmentPath,
        ),
      ),
    );
    try {
      await _resolveAudioSlot(forceReload: true);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.openAlignmentImport', e, stack);
    }
    if (!mounted) return;
    _rebuild(() {});
    // 导入 / 对齐完成后回到有声书面板，「资源」页立刻显示新的对齐文件名。
    if (_audiobookController != null) {
      unawaited(_showAppearanceSheet(initialSubPage: 'audiobook'));
    }
  }

  /// 有声书面板「转录生成字幕」：对当前音频跑设备端 ASR，产物 SRT 作为对齐文件
  /// 预填进导入对话框由用户确认导入（与导入对话框里的转录入口同一条链路）。
  Future<void> _transcribeFromAudiobookPanel() async {
    final List<String>? audio = _audiobookController?.audiobook?.audioPaths;
    if (audio == null || audio.isEmpty) {
      FushiToast.show(
        msg: t.audiobook_transcribe_needs_audio,
        severity: ToastSeverity.warning,
      );
      return;
    }
    final EpubBookRow? book =
        await appModel.database.getEpubBook(widget.bookKey);
    if (!mounted) return;
    final String? srtPath = await _withStudyClockPaused(
      () => showAsrTranscribeSheet(
        context: context,
        audioPaths: List<String>.of(audio),
        languageHint: asrLanguageHintFromBookLanguage(book?.language),
      ),
    );
    if (srtPath == null || !mounted) return;
    await _openAlignmentImportDialog(initialAlignmentPath: srtPath);
  }

  /// 本书今日 / 累计：只经统一事实面 `loadStatFacts`（统计域 v92 读取纪律）。
  Future<ReaderBookStatTotals> _loadReaderBookStatTotals() async {
    // includeCounters：今天的查词 / 制卡数从 per-book 计数面切（`lookup_mining_counters`）。
    final StatFacts facts = await loadStatFacts(
      appModel.database,
      activityLimit: 0,
      includeCounters: true,
    );
    return summarizeReaderBookStats(
      facts.dailyBooks,
      counters: facts.counters.lookupCounters,
      bookKey: widget.bookKey,
      title: _book?.title,
      now: DateTime.now(),
    );
  }

  // ── Desktop status footer ─────────────────────────────────────────

  /// 桌面端底部状态行（ッツ Reader 风格）。左：计时器图标 + `<字/时> / h <本次时长>`；
  /// 右：`<已读> / <总字数>  <百分比>%`。常驻、挤压式（预留高见 [_statusFooterReserve]）。
  ///
  /// 绘制门控与底栏同源用 set-once `_hasEverLoaded`（不用每切章翻转的
  /// `_readerContentReady`，否则切章闪烁）；预留高**不**随它翻转，见 getter 注释。
  /// 悬浮底栏（默认形态）唤出时 `Positioned(bottom: 0)` 盖在状态行之上，与顶部进度
  /// pill 被底栏盖住是同一形态。底栏挤压模式下：宽屏读数并进底栏右端，状态行整条
  /// 让位（[_statusFooterAbsorbedByBar]，不画、不占预留，BUG-2467）；窄屏读数独立
  /// 成行时底栏坐在状态行之上（[_wrapBottomChromeBar]）。
  ///
  /// 状态行贴屏底 `bottom: 0`，整条带高 = max(行高, 系统底 inset)：iPhone 上读数落进
  /// home indicator 那 34pt 里，而不是在它上面再叠一条 28pt（BUG-2470）。
  ///
  /// 点状态行 = 点顶部进度 pill 的同义动作（悬浮态唤出 / 收起，挤压态切底栏）。
  /// 纯指针面，不进焦点遍历池（TODO-700 不变式）。
  Widget _buildStatusFooter() {
    if (!_statusFooterShouldPaint) return const SizedBox.shrink();
    return Positioned(
      left: MediaQuery.viewPaddingOf(context).left,
      right: MediaQuery.viewPaddingOf(context).right,
      bottom: 0,
      // BUG-1692：状态行排在 WebView **之后**绘制，必须自带 RepaintBoundary，否则并进
      // 页面级 PictureLayer 的整窗 cull rect，macOS 上整块 WebView 收不到鼠标事件。
      child: RepaintBoundary(
        child: ReaderStatusFooter(
          key: const ValueKey<String>('fushi_status_footer'),
          bottomInset: _stableBottomInset,
          sessionTotals: _readingSessionTotals,
          currentChars: _progressCurrentChars,
          totalChars: _progressTotalChars,
          showTimer: ReaderFushiSource.instance.showReadingTimer,
          showProgress: ReaderFushiSource.instance.showTopProgressBar,
          textColor: _themeTextColor(),
          backgroundColor: _chromeSurfaceColor(),
          onTap: _anyChromeFloating
              ? () => _handleFloatingChromeReveal()
              : _toggleChrome,
          // 左侧计时器 = 手动暂停 / 继续；右侧进度数字 = 打开统计浮层。
          onTapTracker: _toggleStudyClockManualPause,
          onTapProgress: _openReadingStatistics,
        ),
      ),
    );
  }

  /// 悬浮态状态行收起后留在屏底的细进度线（[ReaderProgressEdgeLine]）：
  /// 贴 `bottom: 0`，不占预留、不吃指针；状态行唤出时它让位（同一真相源
  /// [readerProgressEdgeLineVisible]）。
  Widget _buildProgressEdgeLine() {
    if (!_progressEdgeLineShouldPaint) return const SizedBox.shrink();
    final double ratio = readerProgressRatio(
      current: _progressCurrentChars,
      total: _progressTotalChars,
    )!;
    return Positioned(
      left: MediaQuery.viewPaddingOf(context).left,
      right: MediaQuery.viewPaddingOf(context).right,
      bottom: 0,
      // BUG-1692 同款：排在 WebView 之后绘制的层自带 RepaintBoundary。
      child: RepaintBoundary(
        child: ReaderProgressEdgeLine(
          key: const ValueKey<String>('fushi_progress_edge_line'),
          ratio: ratio,
          color: _themeTextColor(),
        ),
      ),
    );
  }

  /// 顶栏 / 底栏 / 状态行的底色：悬浮态半透明盖在正文上，挤压态即主题背景
  /// （[readerChromeSurfaceColor]）。
  Color _chromeSurfaceColor() => readerChromeSurfaceColor(
        _themeBackgroundColor(),
        floating: _bottomBarFloating,
      );

  /// 本章总字数 / 已读字数（状态行括号段 / 预计读完）——派生量在
  /// [ReaderProgressState]，这里只是按当前章取。
  int? get _footerChapterTotalChars => _progress.chapterTotal(_currentChapter);
  int? get _footerChapterCurrentChars =>
      _progress.chapterCurrent(_currentChapter);

  /// 播放条右端的状态文字（与状态行同一套文案 / 同一读口），只在桌面端播放条可见时用。
  Widget _buildBarStatusText() => ReaderStatusInline(
        sessionTotals: _readingSessionTotals,
        currentChars: _progressCurrentChars,
        totalChars: _progressTotalChars,
        showTimer: ReaderFushiSource.instance.showReadingTimer,
        showProgress: ReaderFushiSource.instance.showTopProgressBar,
        textColor: _themeTextColor(),
      );

  /// 状态行左侧的会话累计读口：账只在 [StudyClock] 一本（v92 纪律），时钟未建
  /// （首屏未就绪）时给零值 + 未计时。
  StudySessionTotals _readingSessionTotals() =>
      _studyClock?.sessionTotals() ?? (durationMs: 0, chars: 0, active: false);

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
    final String position = ReaderFushiSource.instance.topProgressPosition;

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
      key: const ValueKey<String>('fushi_progress'),
      style: TextStyle(
          fontSize: _ReaderFushiPageState._infoFontSize, color: infoColor),
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
          // BUG-1692：进度 pill 排在 WebView **之后**绘制。不自带 RepaintBoundary
          // 就会并进页面级 RepaintBoundary 那张 cull rect = 整窗的 PictureLayer，
          // macOS engine 把整窗写进 FlutterMutatorView 的 _hitTestIgnoreRegion，
          // 于是整块 WebView 收不到任何鼠标事件（点击/划词/翻页全死）。包一层让
          // 它自成一张紧致 bounds 的图层，忽略区只剩 pill 自己那一小块。
          child: RepaintBoundary(child: pill),
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
      sentenceAudioHighlight: Color(0x66A8C68C),
      selection: Color(0x59C2B280),
      link: Color(0xFF7A6232),
      dark: false,
    ),
    'water-theme': (
      bg: Color(0xFFDFECF4),
      fg: Color(0xDE000000),
      sentenceAudioHighlight: Color(0x6664B4DC),
      selection: Color(0x59C8AA6E),
      link: Color(0xFF3A5FAD),
      dark: false,
    ),
    // 护眼（豆沙绿）：与 reader_content_styles `_themeColors['eyecare-theme']` 的
    // rgba 预设逐一相等（ARGB 同值），作为五角色单一真相源透传。
    'eyecare-theme': (
      bg: Color(0xFFC7EDCC),
      fg: Color(0xDE000000),
      sentenceAudioHighlight: Color(0x66A0C878),
      selection: Color(0x5988B583),
      link: Color(0xFF4C7A3E),
      dark: false,
    ),
    'gray-theme': (
      bg: Color(0xFF23272A),
      fg: Color(0xDEFFFFFF),
      sentenceAudioHighlight: Color(0x595096C8),
      selection: Color(0x59BE9B64),
      link: Color(0xFF6FA8DC),
      dark: true,
    ),
    'dark-theme': (
      bg: Color(0xFF121212),
      fg: Color(0x99FFFFFF),
      sentenceAudioHighlight: Color(0x594682B4),
      selection: Color(0x59B4915A),
      link: Color(0xFF7AACDF),
      dark: true,
    ),
    'black-theme': (
      bg: Color(0xFF000000),
      fg: Color(0xDEFFFFFF),
      sentenceAudioHighlight: Color(0x663C78AA),
      selection: Color(0x66AA8750),
      link: Color(0xFF5B9BD5),
      dark: true,
    ),
  };

  /// 自定义主题在阅读器四角色上的显式覆盖（BUG-2187）：全部经 AppModel 的
  /// `activeCustomTheme*` getter 解析——条目优先、旧扁平偏好兜底、非自定义 key
  /// 恒 null；null 的角色由 [resolveReaderThemeColors] 按真实 ColorScheme 派生。
  ReaderThemeOverrides get _customReaderThemeOverrides => (
        bg: appModel.activeCustomThemeBackgroundColor,
        fg: appModel.activeCustomThemeFontColor,
        selection: appModel.activeCustomThemeSelectionColor,
        link: appModel.activeCustomThemeLinkColor,
      );

  /// 当前主题 key 解析出的阅读器角色色，统一经 [resolveReaderThemeColors]：
  /// preset 命中用手调底色，未命中（light/system/自定义/未来 key）跟随真实
  /// ColorScheme，自定义主题再盖上用户显式指定的角色。
  ReaderThemeColors get _readerThemeColors {
    return resolveReaderThemeColors(
      themeKey: appModel.appThemeKey,
      presetMap: _themeMap,
      scheme: appModel.buildColorScheme(
        appModel.isDarkMode ? Brightness.dark : Brightness.light,
      ),
      customOverrides: _customReaderThemeOverrides,
      // TODO-977：全局音频高亮色覆盖（与主题解耦），对所有主题生效。
      audioHighlightOverride: appModel.audioHighlightColor,
    );
  }

  Color _themeBackgroundColor() => _readerThemeColors.bg;

  Color _themeTextColor() => _readerThemeColors.fg;

  Color _themeSentenceAudioHighlightColor() =>
      _readerThemeColors.sentenceAudioHighlight;

  bool get _isReaderThemeDark => _readerThemeColors.dark;

  String get _readerBackgroundHex {
    final Color bg = _themeBackgroundColor();
    return '#${(bg.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  String? get _customThemeTextCss {
    final Color c = _themeTextColor();
    return _ReaderFushiPageState._colorToCssRgba(c);
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

  /// 把当前取值喂给 [resolveDictionaryPopupTheme]——弹窗覆盖主题的全部决策
  /// （含墨水屏两条不变式）都在那个纯函数里，本方法不再自己拼 ThemeData。
  ///
  /// 非墨水屏下的语义不变：app 真实 ColorScheme（主题色 / 高亮 / 描边跟用户主题）
  /// + 纸色与字色盖上去的中性角色。以前是拿纸色当 seed 重造整套 ColorScheme，
  /// 弹窗里的按钮、查到词高亮全由纸色派生，与用户设的主题色完全脱钩（改了主题色
  /// 最高频的查词面不变色）。中性梯度与编辑页预览 / ColorScheme 用同一个
  /// [deriveSurfaceRolesFrom]，所见即所得。
  void _syncDictionaryTheme() {
    // 决策全在 [resolveDictionaryPopupTheme]（纯函数、可直接断言）：它保证覆盖
    // 主题带上 FushiEinkTheme 扩展，并在墨水屏下跳过纸色派生。这里只负责把
    // AppModel / 阅读器主题的当前取值喂进去。
    final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
      eink: appModel.einkMode,
      einkDark: appModel.isDarkMode,
      readerBackground: _themeBackgroundColor(),
      readerForeground: _themeTextColor(),
      readerDark: _isReaderThemeDark,
      buildColorScheme: appModel.buildColorScheme,
    );
    appModel.setOverrideDictionaryColor(resolved.fillColor);
    appModel.setOverrideDictionaryTheme(resolved.theme);
  }

  // ── JS result helpers (evaluateJavascript returns dynamic) ────────

  static bool _didScroll(dynamic result) {
    if (result is String) {
      return result.trim().replaceAll('"', '') == 'scrolled';
    }
    return false;
  }

  static bool _didConsumePageTurn(dynamic result) {
    if (_didScroll(result)) return true;
    if (result is String) {
      // VN 的第一次前进可能只完成当前屏的打字渐显。它虽然没有移动屏索引，
      // 但已经完整消费了翻页意图，绝不能落进章节边界分支；同时它不算真实
      // 滚屏，调用方不会误跑 caret 的跨页重锚。
      return result.trim().replaceAll('"', '') == 'revealed';
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
    if (!mounted || _controller == null || section != _lookupSectionIndex) {
      return;
    }
    await HighlightBridge.applyHighlights(
      _controller!,
      chapterFavs,
      backgroundHex: _readerBackgroundHex,
    );
    await _controller!.evaluateJavascript(
      source:
          'if (!window.__fushiCssHighlightsSupported) { window.fushiReader && window.fushiReader.buildNodeOffsets(); }',
    );
  }

  Future<void> _toggleFavoriteSentence(
      {ReaderSelectionData? selection, int? selectionSection}) async {
    if (_controller == null || _book == null) return;
    final String sentence = selection?.text ??
        appModel.currentMediaSource?.currentSentence.text ??
        '';
    if (sentence.isEmpty) {
      FushiToast.show(
        msg: t.no_sentence_selected,
        severity: ToastSeverity.error,
      );
      return;
    }

    final int section = selectionSection ?? _favoriteSectionIndex;
    final sentenceRange = selection != null
        ? (selection.normalizedOffset != null &&
                selection.normalizedLength != null
            ? (
                offset: selection.normalizedOffset!,
                length: selection.normalizedLength!,
              )
            : null)
        : _cachedSentenceRange ??
            (_cachedSelectionRange != null
                ? (
                    offset: _cachedSelectionRange!.offset,
                    length: _cachedSelectionRange!.length,
                  )
                : null);
    debugPrint(
      '[fushi-hl] toggleFavorite: '
      'sentenceRange=${sentenceRange != null ? "(${sentenceRange.offset},${sentenceRange.length})" : "null"} '
      'cachedSentence=${_cachedSentenceRange != null} '
      'cachedSelection=${_cachedSelectionRange != null}',
    );
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );

    // Resolve identity for this action; cached lookup favorite state can belong
    // to another sentence, including when a right-click selection is used.
    final String? matchedId = await repo.matchedFavoriteId(
      text: sentence,
      bookKey: widget.bookKey,
      sectionIndex: section,
      normCharOffset: sentenceRange?.offset,
    );
    if (matchedId != null) {
      await repo.removeById(matchedId);
      _invalidateFavoriteSentenceCache();
      _rebuild(() => _currentSentenceIsFavorited = false);
      if (mounted) {
        await _refreshSectionHighlights(section);
      }
      FushiToast.show(msg: t.favorite_removed, severity: ToastSeverity.success);
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
    _invalidateFavoriteSentenceCache();
    _rebuild(() => _currentSentenceIsFavorited = true);
    if (mounted) {
      await _refreshSectionHighlights(section);
    }
    FushiToast.show(msg: t.favorite_added, severity: ToastSeverity.success);
  }

  /// TODO-1308 问题②（BUG-696 根因①）：书内收藏面板跳转的唯一真实路径——quick
  /// settings sheet 的 onJumpToFavorite 与 debugJumpToFavorite 测试钩子都走这里。
  Future<void> _jumpToFavoriteSentence(FavoriteSentence fav) async {
    if (fav.sectionIndex == null) return;
    final int? normCharOffset = fav.normCharOffset;
    // TODO-1308 问题②（BUG-696 根因①）：fav.normCharOffset 是写入端
    // （lookup.part / mining.part 的 sentenceNormalizedOffset，即 JS
    // getNormalizedOffset）产的**章内绝对学习单位索引**（0..数千），不是书签的
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
    // BUG-2225：同章收藏跳转不经 _beginNavigation，离开当前页在此结算（by-text
    // 回退路径只滚动、不 notifyRestoreComplete，旧页在落点首个 arrive 时照常结算，
    // 但同样属于「跳走」，一并在此 leave 保持同一语义）。
    _readLedger.leave();
    if (useOffset) {
      await _controller!.evaluateJavascript(
        source: 'window.fushiReader && window.fushiReader'
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
