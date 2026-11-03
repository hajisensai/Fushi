part of '../manga_fushi_page.dart';

/// 漫画阅读器的卷页宿主（[PageCurlHost]）：预览 = JS 只把 strip 瞬时挪到相邻跨页
/// （`__mangaCurlPreview`，不碰 CURRENT 与翻页副作用），提交 = Dart 侧推进
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

  /// 预览的目标跨页（没有预览时为 null）。
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
      // 只挪 strip 的像素位置：不改 CURRENT / PAGE_HALF，不跑任何翻页副作用
      // （TURN_SERIAL / 重试失败页 / 闪屏 / 换页复位缩放）——那些只在提交时由
      // [_commitMangaSpread] 的 `__mangaApplyTranslate` 跑一次。目标跨页不在已加载
      // 窗口里时返回 false，交回普通翻页（重载窗口）。
      final Object? placed = await controller.evaluateJavascript(
        source: mangaCurlPreviewInvocation(target),
      );
      if (placed != true) return false;
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaPageCurl.preview', e, stack);
      return false;
    }
    _previewTarget = target;
    return true;
  }

  @override
  Future<void> revertPreview() async {
    if (_previewTarget == null) return;
    _previewTarget = null;
    try {
      await _state._controller?.evaluateJavascript(
        source: kMangaCurlRevertInvocation,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaPageCurl.revert', e, stack);
    }
  }

  @override
  Future<void> commitTurn({required bool forward}) async {
    final int? target = _previewTarget;
    _previewTarget = null;
    if (target == null || !_state.mounted) return;
    await _state._commitMangaSpread(target);
  }

  @override
  Future<void> fallbackTurn({required bool forward}) async {
    if (!_state.mounted) return;
    await _state._applyMangaTurnStepStages(forward ? 1 : -1, allowCurl: false);
  }

  /// 与 onMangaTurn 同一个入口 [_onMangaTurn]：进 [_turnQueue] 串行，窗口重载
  /// （`_navigating`）期间排队，换章装载期间按 BUG-3221 丢弃——与不开卷页时一致。
  @override
  Future<void> swipeTurn({required bool forward}) async {
    if (!_state.mounted) return;
    await _state._onMangaTurn(forward ? 'next' : 'prev');
  }

  @override
  Future<void> waitForPaint() => waitPageCurlWebViewPaint(_state._controller);
}

/// 跳到某个跨页的 JS 调用（翻页提交：CURRENT / 缩放复位 / 闪屏等副作用都在这里）。
String mangaApplyTranslateInvocation(int target) =>
    'window.__mangaApplyTranslate && window.__mangaApplyTranslate($target);';

/// 卷页预览：strip 瞬时挪到目标跨页、不记任何翻页账（返回 true = 已落位）。
String mangaCurlPreviewInvocation(int target) =>
    '!!(window.__mangaCurlPreview && window.__mangaCurlPreview($target));';

/// 撤销卷页预览：strip 挪回 CURRENT。
const String kMangaCurlRevertInvocation =
    'window.__mangaCurlRevert && window.__mangaCurlRevert();';

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
  ///
  /// JS 发出 'start' 后就吞掉了 onMangaTurn，所以每一次 start 都要接住：卷页不可用 /
  /// 窗口重载 / 换章中 / 已有卷页会话时句柄按普通滑动处理（松手经
  /// [_MangaPageCurlHost.swipeTurn] 走 [_onMangaTurn] 入队），后续事件只交给它。
  void _onMangaPageCurlDrag(List<dynamic> args) {
    if (args.isEmpty) return;
    final String phase = args[0] as String;
    double arg(int i) =>
        i < args.length && args[i] is num ? (args[i] as num).toDouble() : 0;
    final Size size = _mangaCurlSize;
    final Offset position = Offset(arg(1) * size.width, arg(2) * size.height);
    switch (phase) {
      case 'start':
        _focusOwnership.reclaim(FocusReclaimCause.gesture);
        // 上一次手势的 end / cancel 丢了：不让它继续占着会话。
        _pageCurlDrag?.cancel();
        final Offset start = Offset(arg(4) * size.width, arg(5) * size.height);
        // 页序语义：从左往右读时往左拖 = 下一页；右开时相反（与 JS 的
        // `swipeRight === IS_RTL` 同一镜像）。
        final bool leftIsNext = !_mangaCurlMirror;
        final bool movedLeft = position.dx < start.dx;
        final PageCurlDrag drag = _ensureMangaCurl().dragStart(
          position: start,
          size: size,
          forward: movedLeft == leftIsNext,
          mirror: _mangaCurlMirror,
          allowCurl: _mangaCurlEnabled,
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

  Widget _buildMangaCurlOverlay() {
    return PageCurlOverlay(
      key: _pageCurlOverlayKey,
      controller: _ensureMangaCurl(),
      // 漫画纸张是白纸：纸背面不跟阅读器底色（深色底下卷起来仍是纸）。
      paperColor: const Color(0xFFF7F5F0),
    );
  }
}
