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
  Future<void> _paginate(
    ReaderNavigationDirection direction, {
    int throttleMs = 0,
  }) async {
    if (_controller == null) {
      return;
    }
    // TODO-737: 翻页输入节流闸门归一到此唯一入口。各源传不同 throttleMs：滚轮
    // wheelPageTurnInterval(450)、音量键 volumePageTurningSpeed(100)、键盘/手柄 0。
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
        _handlePageTurnLimit(direction.jsValue);
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
      _handlePageTurnLimit(direction.jsValue);
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

  Future<void> _shareReaderImage(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await Share.shareXFiles(
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

  // TODO-728: single sink that makes the chrome visible/hidden. Shared by the
  // user toggle ([_toggleChrome]) and the gamepad-presence path
  // ([_applyGamepadPresence]). It ONLY flips _showChrome + reapplies insets +
  // requestFocus() -- it NEVER touches the focus model beyond the same cheap
  // requestFocus() the old _toggleChrome did (TODO-700 invariant: focus stays on
  // the reading content; the bottom bar remains ExcludeFocus and out of the
  // traversal pool). No-op when already in the requested state so a redundant
  // gamepad event does not re-run the WebView inset eval.
  void _setChromeVisible(bool visible) {
    if (_showChrome == visible) return;
    _rebuild(() {
      _showChrome = visible;
    });
    _applyChromeInsets();
    _focusNode.requestFocus();
  }

  /// TODO-728: applies the gamepad auto-immersive rule. [present] true while a
  /// controller is in use, false once it is gone. Hiding is recorded in
  /// [_chromeHiddenByGamepad] so only a gamepad-driven hide is auto-restored when
  /// the controller leaves; a manual toggle in between clears the flag and wins.
  void _applyGamepadPresence(bool present) {
    final GamepadImmersiveState next = resolveGamepadImmersive(
      present: present,
      showChrome: _showChrome,
      hiddenByGamepad: _chromeHiddenByGamepad,
    );
    _chromeHiddenByGamepad = next.hiddenByGamepad;
    _setChromeVisible(next.showChrome);
  }

  void _toggleChrome() {
    // A manual toggle takes ownership: clear the gamepad-hide flag so a later
    // controller-gone event does not override the user's explicit choice.
    _chromeHiddenByGamepad = false;
    _rebuild(() {
      _showChrome = !_showChrome;
    });
    _applyChromeInsets();
    // TODO-700 T8: the bottom chrome bar is wrapped in ExcludeFocus (see
    // [_buildAudiobookBar]/[_buildSettingsBar]), so its controls are never
    // focus-traversal targets — focus always lives on the reading content
    // ([_focusNode]). Showing the bar must NOT move focus into it (the old
    // `moveFocusToChrome` path is gone): the bar is a touch/mouse + key-glyph
    // surface, not a directional-nav destination. Keeping focus on the content
    // means directional keys keep turning the page and hidden shortcuts are
    // never short-circuited by a focused bar. requestFocus() is a cheap no-op
    // when the content already holds focus.
    _focusNode.requestFocus();
  }

  Future<void> _applyChromeInsets() async {
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    final double top = _readerTopOffset;
    final double bottom = _showChrome
        ? _readerChromeHeight + _stableBottomInset
        : _stableBottomInset;
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
      onAfterCommit: () => _refreshProgress(),
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

  Widget _buildBottomChrome() {
    // 底栏可见性只取决于用户意图（_showChrome）和「首次冷加载是否完成」
    // （_hasEverLoaded，只置 true、从不复位），不再耦合每次切章都会翻转的
    // _readerContentReady。否则切章时 _readerContentReady=false 会把底栏硬卸载
    // 成 SizedBox.shrink()，新章就绪后又突然挂回，造成底栏闪烁。冷启动首章
    // 渲染前 _hasEverLoaded 仍为 false，底栏照旧不显示，行为不变。
    if (!_hasEverLoaded || !_showChrome) {
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
        return Positioned(
          key: const ValueKey<String>('hoshi_play_bar'),
          left: 0,
          right: 0,
          bottom: 0,
          // TODO-700 T8: ExcludeFocus removes every bar control from the
          // focus traversal pool so the reading content ([_focusNode]) is the
          // only home for focus. The bar stays operable by touch/mouse but is
          // never a directional-nav destination, so it can neither steal a
          // hidden shortcut nor strand the page-turn keys. _chromeFocusScope is
          // kept as the bar's structural scope; its `.hasFocus` is now always
          // false, which [_reclaimReaderFocusAfterGesture] relies on.
          child: ExcludeFocus(
            child: FocusScope(
              node: _chromeFocusScope,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ReaderChromeScaler(
                    scale: _readerChromeScale,
                    baseHeight: _ReaderHibikiPageState._readerChromeBaseHeight,
                    child: AudiobookPlayBar(
                      controller: ctrl,
                      skipActionSeconds:
                          ReaderHibikiSource.instance.skipActionSeconds,
                      onOpenSettings: _showAppearanceSheet,
                      backgroundColor: _themeBackgroundColor(),
                      foregroundColor: _themeTextColor(),
                      reversed: appModel.reverseReaderBottomBar,
                      // TODO-830: per-reader 功能反转（getter 内部走 readerSettings?
                      // 分层，否则退化全局）；与 reversed 的位置镜像维度正交。
                      invertSkip: ReaderHibikiSource
                          .instance.invertAudiobookSkipDirection,
                      // TODO-728: per-reader toggle for the current-sentence cue.
                      showCue: ReaderHibikiSource.instance.showBottomBarCue,
                    ),
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
      IconButton(
        icon: Icon(Icons.tune_outlined, color: _themeTextColor()),
        iconSize: 20,
        tooltip: t.reader_settings_section,
        onPressed: _showAppearanceSheet,
      ),
    ];
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // TODO-700 T8: see [_buildAudiobookBar] — ExcludeFocus keeps the settings
      // bar out of the focus traversal pool so focus stays on the reading
      // content. _chromeFocusScope is kept as the structural scope only.
      child: ExcludeFocus(
        child: FocusScope(
          node: _chromeFocusScope,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ReaderChromeScaler(
                scale: _readerChromeScale,
                baseHeight: _ReaderHibikiPageState._readerChromeBaseHeight,
                child: ColoredBox(
                  color: _themeBackgroundColor(),
                  child: SizedBox(
                    height: _ReaderHibikiPageState._readerChromeBaseHeight,
                    child: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
                      child: Row(
                        children:
                            reversed ? barItems.reversed.toList() : barItems,
                      ),
                    ),
                  ),
                ),
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

  // TODO-796: resolve a TOC entry's href to its spine chapter index through the
  // same canonicalization [EpubBook.resolveInternalLink] uses, so a cover/front-
  // matter entry whose href differs only by `./` / `%xx` / case is matched (not
  // dropped, which used to shove the real first chapter into row 0 and make a
  // "Cover" tap jump to chapter 1).
  int _tocHrefToChapterIndex(String? href) {
    if (_book == null) return -1;
    return _book!.chapterIndexForHref(href);
  }

  Future<void> _showAppearanceSheet() async {
    if (_settings == null || _controller == null || _book == null) return;
    // 重入守卫：快速连点时按钮按下到 show 之间的 DB 读 await 期间会二次进入、弹出
    // 两个面板。标志置位必须在第一个 await 之前，复位放 finally（异常也复位）。
    if (_appearanceSheetOpen) return;
    _appearanceSheetOpen = true;
    try {
      // _settings 就是 ReaderHibikiSource.readerSettings 本体（见 initState 绑定），
      // 面板控件经 ReaderHibikiSource.instance.ttu* 实时读写同一对象，开面板前后都
      // 无需设置同步——旧 TTU 双存储时代的 _syncSettings*Hive 已是写回自身的死桥，
      // 且 _syncSettingsToHive 会触发 17× onSettingsChangedLive 的 DB/WebView 风暴。
      final List<TtuTocEntry> toc = _buildTtuToc();
      final String bookKey = widget.bookKey;
      final BookmarkRepository bmRepo = BookmarkRepository(appModel.database);
      final FavoriteSentenceRepository favRepo =
          FavoriteSentenceRepository(appModel.database);

      List<Bookmark> bookmarks = await bmRepo.getBookmarks(bookKey);
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
        onBookmark: () async {
          await _addBookmarkAtCurrentPosition();
        },
        onExitReader: () {
          Navigator.of(context).pop();
        },
        webViewController: _controller!,
        appModel: appModel,
        ref: ref,
        isHibikiReader: true,
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
            final bool ok = await _navigateToChapterAndWait(
              result.sectionIndex,
              manual: true,
            );
            if (!ok || !mounted || _controller == null) return;
          }
          await _controller!.evaluateJavascript(
            source: ReaderPaginationScripts.scrollToSearchMatchInvocation(
              query,
              result.charOffset,
            ),
          );
        },
        bookmarks: bookmarks,
        onJumpToBookmark: (bm) async {
          if (bm.sectionIndex != _currentChapter) {
            await _navigateToChapterAndWait(bm.sectionIndex, manual: true);
          }
          if (!mounted || _controller == null) return;
          final double progress = bm.normCharOffset / 10000.0;
          await _controller!.evaluateJavascript(
            source:
                'window.hoshiReader && window.hoshiReader.restoreProgress($progress);',
          );
        },
        onDeleteBookmark: (bookmark) async {
          final int? id = bookmark.id;
          if (id != null) {
            await bmRepo.removeBookmarkById(id);
          } else {
            await bmRepo.removeBookmarkMatching(
              bookKey,
              sectionIndex: bookmark.sectionIndex,
              normCharOffset: bookmark.normCharOffset,
              createdAt: bookmark.createdAt,
            );
          }
          bookmarks = await bmRepo.getBookmarks(bookKey);
        },
        favoriteSentences: favorites,
        onDeleteFavorite: (fav) async {
          await favRepo.removeById(fav.id);
          _invalidateFavoriteSentenceCache();
          if (fav.sectionIndex == _currentChapter || _lyricsMode) {
            await _refreshSectionHighlights(
                fav.sectionIndex ?? _currentChapter);
          }
        },
        onJumpToFavorite: (fav) async {
          if (fav.sectionIndex == null) return;
          if (fav.sectionIndex != _currentChapter) {
            await _navigateToChapterAndWait(fav.sectionIndex!, manual: true);
          }
          if (!mounted || _controller == null) return;
          if (fav.normCharOffset != null) {
            final double progress = fav.normCharOffset! / 10000.0;
            await _controller!.evaluateJavascript(
              source:
                  'window.hoshiReader && window.hoshiReader.restoreProgress($progress);',
            );
          }
        },
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
            maxWidth: 900,
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
    }
  }

  Future<void> _addBookmarkAtCurrentPosition() async {
    if (_controller == null) return;
    if (_lyricsMode) {
      _syncPositionFromCurrentCue();
      if (_lastProgressSection < 0) return;
      final int normOffset = (_lastProgressValue * 10000).round();
      final String label = _book?.toc.isNotEmpty == true
          ? _currentChapterLabelFor(_lastProgressSection)
          : 'Ch. ${_lastProgressSection + 1}';
      final Bookmark bm = Bookmark(
        sectionIndex: _lastProgressSection,
        normCharOffset: normOffset,
        label: label,
        createdAt: DateTime.now(),
        bookKey: widget.bookKey,
        bookTitle: _book?.title,
      );
      await BookmarkRepository(appModel.database)
          .addBookmark(widget.bookKey, bm);
      return;
    }

    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.progressInvocation(),
    );
    final double? progress = _ReaderHibikiPageState._toDouble(result);
    if (progress == null) return;

    final int normOffset = (progress * 10000).round();
    final String label = _book?.toc.isNotEmpty == true
        ? _currentChapterLabel()
        : 'Ch. ${_currentChapter + 1}';

    final (int, int)? pageInfo = await _probePageInfo();

    final Bookmark bm = Bookmark(
      sectionIndex: _currentChapter,
      normCharOffset: normOffset,
      label: label,
      createdAt: DateTime.now(),
      bookKey: widget.bookKey,
      bookTitle: _book?.title,
      pageInChapter: pageInfo?.$1,
      totalPagesInChapter: pageInfo?.$2,
    );

    await BookmarkRepository(appModel.database).addBookmark(widget.bookKey, bm);
  }

  /// Probes the paginated reader engine for the current page / total pages
  /// within the loaded chapter. Returns `null` in continuous mode (no pages)
  /// or when the engine isn't ready.
  Future<(int, int)?> _probePageInfo() async {
    if (_controller == null) return null;
    final Object? raw = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.pageInfoInvocation(),
    );
    if (raw is! String) return null;
    final String trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'null') return null;
    try {
      final Map<String, dynamic> info =
          jsonDecode(trimmed) as Map<String, dynamic>;
      final int? current = (info['currentPage'] as num?)?.toInt();
      final int? total = (info['totalPages'] as num?)?.toInt();
      if (current == null || total == null || total <= 0) return null;
      return (current, total);
    } catch (_) {
      return null;
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
    final List<TtuTocEntry> result = <TtuTocEntry>[];
    _flattenTocToTtu(toc, result, null);
    return result;
  }

  void _flattenTocToTtu(
    List<EpubTocItem> items,
    List<TtuTocEntry> result,
    String? parentLabel,
  ) {
    for (final EpubTocItem item in items) {
      final int index = _tocHrefToChapterIndex(item.href);
      if (index >= 0) {
        result.add(TtuTocEntry(
          index: index,
          label: item.label,
          parent: parentLabel,
        ));
      }
      _flattenTocToTtu(item.children, result, item.label);
    }
  }

  Future<void> _reloadWithCurrentSettings() async {
    if (_controller == null) return;
    _sanitizedCssCache.clear();
    _invalidateStyleCache();
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
    if (_lyricsMode || !_showTopProgress) {
      return const SizedBox.shrink();
    }

    final double ratio =
        (_progressCurrentChars! / _progressTotalChars!).clamp(0.0, 1.0);
    final Color infoColor = _themeTextColor();
    final String position = ReaderHibikiSource.instance.topProgressPosition;

    // TODO-728: position-aware top progress + tap-to-toggle chrome.
    //  - The Positioned strip spans the available width (16px side margins);
    //    [Align] pushes the text to the configured side (left/center/right).
    //  - The opaque [GestureDetector] wraps ONLY the [Text], so its hit box is
    //    the text's own bounds. A tap on the text toggles the chrome (the
    //    pointer-only mouse/touch equivalent of the readerToggleChrome shortcut
    //    used by M / gamepad-Y); a tap anywhere ELSE in the strip is NOT inside
    //    the GestureDetector child, so it passes through to the WebView and does
    //    not swallow text selection (penetration guard).
    //  - No Focus/canRequestFocus wrapper: this stays a pure pointer surface and
    //    must never enter the focus-traversal pool (TODO-700 invariant).
    return Positioned(
      top: _stableTopInset,
      left: 16,
      right: 16,
      child: Align(
        alignment: readerTopProgressAlignment(position),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChrome,
          child: Text(
            '$_progressCurrentChars / $_progressTotalChars'
            '  ${(ratio * 100).toStringAsFixed(2)}%',
            key: const ValueKey<String>('hoshi_progress'),
            style: TextStyle(
                fontSize: _ReaderHibikiPageState._infoFontSize,
                color: infoColor),
            textAlign: readerTopProgressTextAlign(position),
          ),
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

    final int section = _lookupSectionIndex;
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
      await repo.removeByContent(
        text: sentence,
        bookKey: widget.bookKey,
        sectionIndex: section,
        normCharOffset: sentenceRange?.offset,
      );
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
    );
    await repo.add(fav);
    _invalidateFavoriteSentenceCache();
    _rebuild(() => _currentSentenceIsFavorited = true);
    if (sentenceRange != null || _lyricsMode) {
      await _refreshSectionHighlights(section);
    }
    HibikiToast.show(msg: t.favorite_added);
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
