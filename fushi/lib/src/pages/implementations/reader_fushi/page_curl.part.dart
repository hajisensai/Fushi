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

  @override
  Future<void> waitForPaint() => waitPageCurlWebViewPaint(_state._controller);
}

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
  void _onPageCurlDrag(List<dynamic> args) {
    if (args.isEmpty) return;
    final String phase = args[0] as String;
    double arg(int i) =>
        i < args.length && args[i] is num ? (args[i] as num).toDouble() : 0;
    final Size size = _pageCurlSize;
    final PageCurlController curl = _ensurePageCurl();
    final Offset position = Offset(arg(1) * size.width, arg(2) * size.height);
    switch (phase) {
      case 'start':
        if (!_pageCurlEnabled || _paginationInFlight) return;
        _focusOwnership.reclaim(FocusReclaimCause.gesture);
        final Offset start = Offset(arg(4) * size.width, arg(5) * size.height);
        final bool leftIsForward = _readerSwipeLeftIsForward;
        final bool movedLeft = position.dx < start.dx;
        curl.dragStart(
          position: start,
          size: size,
          forward: movedLeft == leftIsForward,
          mirror: !leftIsForward,
        );
        curl.dragUpdate(position);
      case 'move':
        curl.dragUpdate(position);
      case 'end':
        curl.dragEnd(position, arg(3) * size.width);
      case 'cancel':
        curl.dragCancel();
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
