part of '../manga_fushi_page.dart';

/// 漫画阅读器的卷页宿主（[PageCurlHost]）：预览 = JS 瞬时落到相邻跨页
/// （`__mangaApplyTranslate`，卷页下 JS 不播自己的动画），提交 = Dart 侧推进
/// `_currentSpread` + OCR + 进度（[_commitMangaSpread]）。几何与动画在
/// `reader/page_curl/page_curl.dart`。
class _MangaPageCurlHost implements PageCurlHost {
  _MangaPageCurlHost(this._state);

  final _MangaFushiPageState _state;

  @override
  bool get canCurl =>
      _state._spreads.isNotEmpty &&
      !_state._navigating &&
      !_state._switchingChapter;

  /// 预览起点 / 目标跨页（没有预览时为 null）。
  int? _previewFrom;
  int? _previewTarget;

  @override
  Future<ui.Image?> capturePage() => capturePageCurlWebView(_state._controller);

  @override
  Future<bool> previewNeighbour({required bool forward}) async {
    final _MangaFushiPageState s = _state;
    if (s._spreads.isEmpty || s._navigating || s._switchingChapter) {
      return false;
    }
    final int from = s._currentSpread;
    final int target = (from + (forward ? 1 : -1))
        .clamp(0, s._spreads.length - 1)
        .toInt();
    // 到章首 / 章末：不卷页，交回普通翻页（换章）。
    if (target == from) return false;
    final InAppWebViewController? controller = s._controller;
    if (controller == null) return false;
    try {
      await controller.evaluateJavascript(
        source: mangaApplyTranslateInvocation(target),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaPageCurl.preview', e, stack);
      return false;
    }
    _previewFrom = from;
    _previewTarget = target;
    return true;
  }

  @override
  Future<void> revertPreview() async {
    final int? from = _previewFrom;
    _previewFrom = null;
    _previewTarget = null;
    if (from == null) return;
    try {
      await _state._controller?.evaluateJavascript(
        source: mangaApplyTranslateInvocation(from),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaPageCurl.revert', e, stack);
    }
  }

  @override
  Future<void> commitTurn({required bool forward}) async {
    final int? target = _previewTarget;
    _previewFrom = null;
    _previewTarget = null;
    if (target == null || !_state.mounted) return;
    await _state._commitMangaSpread(target);
  }

  @override
  Future<void> fallbackTurn({required bool forward}) async {
    if (!_state.mounted) return;
    await _state._applyMangaTurnStepStages(forward ? 1 : -1, allowCurl: false);
  }

  @override
  Future<void> waitForPaint() => waitPageCurlWebViewPaint(_state._controller);
}

/// 跳到某个跨页的 JS 调用（翻页提交与卷页预览共用）。
String mangaApplyTranslateInvocation(int target) =>
    'window.__mangaApplyTranslate && window.__mangaApplyTranslate($target);';

extension _MangaPageCurl on _MangaFushiPageState {
  /// 当前是否用卷页：分页模式（条漫没有页可翻）且实际效果为卷页（墨水屏 / 减弱
  /// 动态效果已在 [_effectivePageAnimation] 降级）。
  bool get _mangaCurlEnabled =>
      !_mode.isContinuous && _effectivePageAnimation == PageTurnAnimation.curl;

  /// 右开（日漫默认）：书脊在右，卷页整体镜像。
  bool get _mangaCurlMirror => _spreadDirection == 'rtl';

  PageCurlController _ensureMangaCurl() {
    return _pageCurl ??= PageCurlController(
      host: _MangaPageCurlHost(this),
      duration: () => _pageAnimationSpeed.curlDuration,
    );
  }

  Size get _mangaCurlSize {
    final RenderObject? box = _pageCurlOverlayKey.currentContext
        ?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return Size.zero;
  }

  /// 点按 / 按键 / 滚轮翻页的卷页入口（翻页队列里的一步，[_applyMangaTurnStepStages]
  /// 已确认相邻跨页存在）。
  Future<void> _mangaCurlTurn({required bool forward}) {
    return _ensureMangaCurl().turn(
      size: _mangaCurlSize,
      forward: forward,
      mirror: _mangaCurlMirror,
    );
  }

  /// JS 手势转发的卷页跟手（`onPageCurlDrag`）：phase, x, y, vx, startX, startY，
  /// 全是视口比例（vx 为每毫秒的视口宽比例）。
  void _onMangaPageCurlDrag(List<dynamic> args) {
    if (args.isEmpty) return;
    final String phase = args[0] as String;
    double arg(int i) =>
        i < args.length && args[i] is num ? (args[i] as num).toDouble() : 0;
    final Size size = _mangaCurlSize;
    final PageCurlController curl = _ensureMangaCurl();
    final Offset position = Offset(arg(1) * size.width, arg(2) * size.height);
    switch (phase) {
      case 'start':
        if (!_mangaCurlEnabled || _navigating || _switchingChapter) return;
        _focusOwnership.reclaim(FocusReclaimCause.gesture);
        final Offset start = Offset(arg(4) * size.width, arg(5) * size.height);
        // 页序语义：从左往右读时往左拖 = 下一页；右开时相反（与 JS 的
        // `swipeRight === IS_RTL` 同一镜像）。
        final bool leftIsNext = !_mangaCurlMirror;
        final bool movedLeft = position.dx < start.dx;
        curl.dragStart(
          position: start,
          size: size,
          forward: movedLeft == leftIsNext,
          mirror: _mangaCurlMirror,
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

  Widget _buildMangaCurlOverlay() {
    return PageCurlOverlay(
      key: _pageCurlOverlayKey,
      controller: _ensureMangaCurl(),
      // 漫画纸张是白纸：纸背面不跟阅读器底色（深色底下卷起来仍是纸）。
      paperColor: const Color(0xFFF7F5F0),
    );
  }
}
