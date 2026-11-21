part of '../manga_fushi_page.dart';

/// 低清页 AI 超分的阅读器接线（设计文档 `docs/specs/2026-11-20-manga-upscale-design.md` §4）。
///
/// 引擎（队列 / 预取 / 缓存 / 推理）在 Rust；这里只把阅读器的事实交给它：哪页被以多大的显示宽度请求
/// （拦截器 → [_noteUpscaleDemand]）、当前页是哪页（[_upscaleAround]）、某页好了换图（[_onUpscaleReady]
/// → 页面脚本 `__mangaSrReady` 把 `<img data-src>` 换成带 `sr=` 的 URL；整页与气泡放大层都从
/// `data-src` 取图）。在线直读章不做（页图是懒取的临时文件，不值得为它跑数秒推理）。
extension _MangaUpscaleGlue on _MangaFushiPageState {
  /// 按当前偏好与页会话重建超分控制器。[force]：换了页会话（开书 / 换章），旧控制器的页号作废。
  void _syncUpscale({bool force = false}) {
    final FfcUpscaleTier? want = MangaUpscaleTier.fromPreference(
      _readerPreferences.aiUpscale,
    ).engineTier;
    final MangaReaderSession? session = _pageSession;
    final bool eligible =
        want != null &&
        session != null &&
        session is! OnlineMangaReaderSession &&
        _pageScope != null;
    final MangaUpscaleController? current = _upscale;
    if (!force && eligible && current != null && current.requested == want) {
      return;
    }
    current?.dispose();
    _upscale = null;
    if (!eligible) return;
    final MangaUpscaleController controller = MangaUpscaleController(
      requested: want,
      onReady: _onUpscaleReady,
      onNotice: _onUpscaleNotice,
    );
    _upscale = controller;
    controller.focus(_currentPage);
    unawaited(controller.ensureActive());
  }

  /// 本页在超分缓存里的身份：卷作用域 + 会话给的稳定页身份。
  String? _upscaleIdentity(int page) {
    final MangaReaderSession? session = _pageSession;
    final String? scope = _pageScope;
    if (session == null || scope == null) return null;
    if (page < 0 || page >= session.pageCount) return null;
    return '$scope|${session.cacheIdentity(page)}';
  }

  Float32List _upscaleBoxes(int page) {
    final List<MokuroImage>? images = _payload?.images;
    if (images == null || page < 0 || page >= images.length) {
      return Float32List(0);
    }
    return mangaTextBoxesOf(images[page]);
  }

  /// 本页当前（按现有文字框）的超分结果已在缓存里时返回它的标签。
  String? _upscaleTagIfCached(int page) {
    final MangaUpscaleController? controller = _upscale;
    final String? identity = _upscaleIdentity(page);
    if (controller == null || identity == null) return null;
    final String? tag = controller.tagFor(_upscaleBoxes(page));
    if (tag == null || !controller.isCached(identity, tag)) return null;
    return tag;
  }

  /// URL 上的 `sr=` 标签对应的结果文件（没有 / 被淘汰 / 超分已关返回 null）。
  String? _upscaleCachedPath(int page, String tag) {
    final MangaUpscaleController? controller = _upscale;
    final String? identity = _upscaleIdentity(page);
    if (controller == null || identity == null) return null;
    return controller.cachedPath(identity, tag);
  }

  /// 拦截器看到本页以 [fitWidth] 的显示宽度被请求：显示得比原图大才值得超分。
  void _noteUpscaleDemand(
    int page,
    int? fitWidth,
    Future<Uint8List> Function() loadSource,
  ) {
    final MangaUpscaleController? controller = _upscale;
    final List<MokuroImage>? images = _payload?.images;
    if (controller == null ||
        fitWidth == null ||
        images == null ||
        page < 0 ||
        page >= images.length) {
      return;
    }
    final double sourceWidth = images[page].size.width;
    if (!mangaUpscaleWanted(fitWidth: fitWidth, sourceWidth: sourceWidth)) {
      return;
    }
    controller.lastRatio = fitWidth / sourceWidth;
    _requestUpscale(page, loadSource);
  }

  void _requestUpscale(int page, Future<Uint8List> Function() loadSource) {
    final MangaUpscaleController? controller = _upscale;
    final String? identity = _upscaleIdentity(page);
    if (controller == null || identity == null) return;
    // 引擎按当前页取舍任务（窗口外的直接丢）：每次提交前把读者此刻所在的页告诉它。控制器是在页会话装上时
    // 建的，那时恢复进度还没落到 _currentPage，单靠建时的页号会把恢复到的那页当成「翻走了」丢掉。
    controller.focus(_currentPage);
    unawaited(
      controller
          .request(
            page: page,
            pageIdentity: identity,
            boxes: _upscaleBoxes(page),
            loadSource: loadSource,
          )
          .catchError((Object error, StackTrace stackTrace) {
            ErrorLogService.instance.log(
              'MangaFushiPage.upscale',
              error,
              stackTrace,
            );
          }),
    );
  }

  /// 当前页变了：引擎换优先级，并往后预取（沿用最近一次请求的放大比例判断值不值得）。
  void _upscaleAround(int page) {
    final MangaUpscaleController? controller = _upscale;
    final MangaReaderSession? session = _pageSession;
    if (controller == null || session == null) return;
    controller.focus(page);
    if (controller.lastRatio < kMangaUpscaleMinRatio) return;
    final int last = math.min(
      session.pageCount - 1,
      page + controller.prefetchWindow,
    );
    for (int next = page + 1; next <= last; next++) {
      final int target = next;
      _requestUpscale(target, () async => (await session.page(target)).bytes);
    }
  }

  /// 后台 OCR 换了本页的文字框：按新框重做（标签变了，旧结果不再匹配）。
  void _upscaleAfterOcrChange(int page) {
    final MangaUpscaleController? controller = _upscale;
    final MangaReaderSession? session = _pageSession;
    if (controller == null ||
        session == null ||
        controller.lastRatio < kMangaUpscaleMinRatio) {
      return;
    }
    _requestUpscale(page, () async => (await session.page(page)).bytes);
  }

  void _onUpscaleReady(int page) {
    if (!mounted) return;
    final List<MokuroImage>? images = _payload?.images;
    final String? tag = _upscaleTagIfCached(page);
    if (images == null || page >= images.length || tag == null) return;
    final String url = MangaFushiPage.mangaImageUrl(
      images[page].url,
      useCustomScheme: webViewUsesCustomSchemeTransport,
      version: _pageSessionGeneration,
      scope: _pageScope,
      upscaleTag: tag,
    );
    unawaited(
      _controller?.evaluateJavascript(
        source:
            'window.__mangaSrReady && '
            'window.__mangaSrReady($page, ${jsonEncode(url)});',
      ),
    );
  }

  void _onUpscaleNotice(MangaUpscaleNotice notice) {
    if (!mounted) return;
    switch (notice) {
      case MangaUpscaleNotice.downloading:
        FushiToast.show(msg: t.manga_reader_ai_upscale_downloading);
      case MangaUpscaleNotice.lightOnly:
        FushiToast.show(msg: t.manga_reader_ai_upscale_light_only);
      case MangaUpscaleNotice.unavailable:
        FushiToast.show(
          msg: t.manga_reader_ai_upscale_unavailable,
          severity: ToastSeverity.warning,
        );
    }
  }
}
