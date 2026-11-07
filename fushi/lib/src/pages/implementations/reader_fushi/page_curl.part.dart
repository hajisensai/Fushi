part of '../reader_fushi_page.dart';

/// 小说阅读器的卷页宿主（[PageCurlHost]）：截图 / 预览相邻页 / 记账都落回本页已有
/// 的执行体。几何与动画在 `reader/page_curl/page_curl.dart`。
class _ReaderPageCurlHost implements PageCurlHost {
  _ReaderPageCurlHost(this._state);

  final _ReaderFushiPageState _state;

  @override
  bool get canCurl => !_state._paginationInFlight;

  @override
  Future<ui.Image?> capturePage() => capturePageCurlWebView(_state._controller);

  /// 单页：纸就是整个视口（页边距也是纸）。双页：在两页之间的中缝（正文 content-box
  /// 中线，与正文 CSS 的两栏 / 对开几何同一条线，折叠屏上就是折痕）处一分为二，外侧
  /// 那半是纸、靠里那半是对面页。竖排对开只在 WebView 真正排成两页（支持
  /// `column-wrap`）时才算双页——不支持时正文退回单页竖排，按单页卷。
  @override
  Future<PageCurlPaper?> paperRect() async {
    final ReaderSettings? settings = _state._settings;
    if (settings == null) return null;
    final ReaderSpreadLayout layout = _state._spreadLayout;
    if (!layout.isDouble) return null;
    if (layout.verticalSpread && !await _verticalSpreadRendered()) return null;
    final Size view = _state._pageCurlSize;
    final double marginLeftPx =
        view.width * math.max(0, settings.marginLeft) / 100;
    final double marginRightPx =
        view.width * math.max(0, settings.marginRight) / 100;
    return pageCurlSpreadPaper(
      view: view,
      spineX: marginLeftPx + (view.width - marginLeftPx - marginRightPx) / 2,
      mirror: !_state._readerSwipeLeftIsForward,
    );
  }

  /// 正文此刻是否真的排成了竖排对开（计算样式 `column-wrap: wrap`，与 JS 翻页轴的
  /// 判据同源）。
  Future<bool> _verticalSpreadRendered() async {
    final InAppWebViewController? controller = _state._controller;
    if (controller == null) return false;
    try {
      final Object? result = await controller.evaluateJavascript(
        source: kReaderVerticalSpreadRenderedInvocation,
      );
      return result == true;
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPageCurl.spreadProbe', e, stack);
      return false;
    }
  }

  @override
  Future<bool> previewNeighbour({required bool forward}) async {
    final InAppWebViewController? controller = _state._controller;
    if (controller == null || _state._paginationInFlight) return false;
    try {
      final Object? result = await controller.evaluateJavascript(
        source: ReaderPaginationScripts.curlPreviewInvocation(
          forward
              ? ReaderNavigationDirection.forward
              : ReaderNavigationDirection.backward,
        ),
      );
      return result == 'ok';
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPageCurl.preview', e, stack);
      return false;
    }
  }

  @override
  Future<void> revertPreview() async {
    try {
      await _state._controller?.evaluateJavascript(
        source: ReaderPaginationScripts.curlRevertInvocation,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderPageCurl.revert', e, stack);
    }
  }

  @override
  Future<void> commitTurn({required bool forward}) => _state._paginateStep(
    forward
        ? ReaderNavigationDirection.forward
        : ReaderNavigationDirection.backward,
  );

  @override
  Future<void> fallbackTurn({required bool forward}) async {
    final ReaderNavigationDirection direction = forward
        ? ReaderNavigationDirection.forward
        : ReaderNavigationDirection.backward;
    // 与 [_paginate] 同一个在飞闸门：换章 / 恢复中到达的翻页存成意图，content-ready
    // 之后由 _replayPendingPageTurn 重放（BUG-2424）。
    if (_state._paginationInFlight) {
      _state._pageTurnQueue.push(direction);
      return;
    }
    await _state._paginateStep(direction);
  }

  /// 与 onSwipe 同一个入口 [_paginate]：在飞时进 [_pageTurnQueue] 排队重放
  /// （BUG-2424），卷页开着时排在当前卷页后面再播一页。
  @override
  Future<void> swipeTurn({required bool forward}) => _state._paginate(
    forward
        ? ReaderNavigationDirection.forward
        : ReaderNavigationDirection.backward,
  );

  @override
  Future<void> waitForPaint() => waitPageCurlWebViewPaint(_state._controller);
}

/// 正文是否排成了竖排对开：`column-wrap` 只有支持它的 WebView（Chromium 145+）才会
/// 在计算样式里回读成 `wrap`（CSS 包在 `@supports` 里，不支持时整段不生效）。
const String kReaderVerticalSpreadRenderedInvocation =
    "(function(){try{return getComputedStyle(document.body).columnWrap === 'wrap';}"
    'catch(e){return false;}})();';

extension _ReaderPageCurl on _ReaderFushiPageState {
  /// 当前是否用卷页翻页：翻页模式（不含滚动 / VN / 歌词）且实际效果为卷页（墨水屏 /
  /// 减弱动态效果已在 [_effectivePageTurnAnimation] 降级）。
  bool get _pageCurlEnabled =>
      !_lyricsMode &&
      (_settings?.viewMode ?? 'paginated') == 'paginated' &&
      _effectivePageTurnAnimation == PageTurnAnimation.curl;

  PageCurlController _ensurePageCurl() {
    return _pageCurl ??= PageCurlController(
      host: _ReaderPageCurlHost(this),
      duration: () =>
          (_settings?.pageTurnAnimationSpeed ?? PageTurnAnimationSpeed.normal)
              .curlDuration,
    );
  }

  Size get _pageCurlSize {
    final RenderObject? box = _pageCurlOverlayKey.currentContext
        ?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return Size.zero;
  }

  /// 点按 / 按键 / 滚轮 / 有声书自动翻页的卷页入口（[_paginate] 过完闸门后调用）。
  Future<void> _pageCurlTurn(ReaderNavigationDirection direction) {
    return _ensurePageCurl().turn(
      size: _pageCurlSize,
      forward: direction == ReaderNavigationDirection.forward,
      mirror: !_readerSwipeLeftIsForward,
    );
  }

  /// JS 手势转发的卷页跟手（`onPageCurlDrag`）：phase, x, y, vx, startX, startY
  /// 全是视口比例（vx 为每毫秒的视口宽比例）。
  ///
  /// JS 发出 'start' 后就不再走 onSwipe，所以这里**每一次** start 都要接住：拿到的
  /// [PageCurlDrag] 句柄在卷页不可用 / 换章在飞 / 已有卷页会话时按普通滑动处理（松手
  /// 经 [_ReaderPageCurlHost.swipeTurn] 走 [_paginate]，在飞时排队重放），后续
  /// move / end / cancel 只交给这个句柄。
  void _onPageCurlDrag(List<dynamic> args) {
    if (args.isEmpty) return;
    final String phase = args[0] as String;
    double arg(int i) =>
        i < args.length && args[i] is num ? (args[i] as num).toDouble() : 0;
    final Size size = _pageCurlSize;
    final Offset position = Offset(arg(1) * size.width, arg(2) * size.height);
    switch (phase) {
      case 'start':
        _focusOwnership.reclaim(FocusReclaimCause.gesture);
        // 上一次手势的 end / cancel 丢了：不让它继续占着会话。
        _pageCurlDrag?.cancel();
        final Offset start = Offset(arg(4) * size.width, arg(5) * size.height);
        final bool leftIsForward = _readerSwipeLeftIsForward;
        final bool movedLeft = position.dx < start.dx;
        final PageCurlDrag drag = _ensurePageCurl().dragStart(
          position: start,
          size: size,
          forward: movedLeft == leftIsForward,
          mirror: !leftIsForward,
          allowCurl: _pageCurlEnabled,
        );
        _pageCurlDrag = drag;
        drag.update(position);
      case 'move':
        _pageCurlDrag?.update(position);
      case 'end':
        final PageCurlDrag? drag = _pageCurlDrag;
        _pageCurlDrag = null;
        drag?.end(position, arg(3) * size.width);
      case 'cancel':
        final PageCurlDrag? drag = _pageCurlDrag;
        _pageCurlDrag = null;
        drag?.cancel();
    }
  }

  Widget _buildPageCurlOverlay(Color paperColor) {
    return PageCurlOverlay(
      key: _pageCurlOverlayKey,
      controller: _ensurePageCurl(),
      paperColor: paperColor,
    );
  }
}
