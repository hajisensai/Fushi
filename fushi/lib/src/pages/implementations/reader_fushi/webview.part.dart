// GENERATED-NOTE: extracted from reader_fushi_page.dart (TODO-589 batch8).
part of '../reader_fushi_page.dart';

/// webview (EPUB WebView 构建 / fushi.local 资源拦截 + 净化 / 单 IIFE setup 脚本)
/// 域 helper，经 part-of 抽出（TODO-589 batch8·最后一批）；与主壳共享私有作用域。
/// 行为保持：方法体逐字搬运（含引擎源码构造器整段内联 JS 模板字符串的
/// 反引号/转义/缩进/$ 插值，做过提取前后字节级对比自证），仅做下列扩展不可直接
/// 表达的等价转发改写：
///   (a) `_buildWebView`/`_onChapterLoadComplete` 里两处 `setState(` 改走主壳的
///       `_rebuild(` 转发器（扩展不能调 @protected State.setState）。
///   (d) `_buildWebView` 里调 @protected 的 `prunePopupStack` / `topPopupState`
///       改走主壳新增的 `_webviewPrunePopupStack` / `_webviewTopPopupState` 转发器
///       （扩展不能直接读写基类 @protected 成员），与 caret 域的 `_caret*` 转发同款。
///   (e) `_notFound` / `_forbidden` / `_isValidFontData` / `_buildFuriganaJs` /
///       `_stripScriptTags` 五个 static 连同其唯一调用者一起搬来，作扩展 static 保留
///       （裸名可解析）。
/// 样式/主题域（`_buildStyleTag` / `_computeStyleTag` / `_applyStylesLive` 等）被
/// chrome / lyrics / navigation part 广泛引用，属另一域，留在主壳；本 part 通过共享
/// 私有作用域调用它们（如 `_buildSanitizedChapterHtmlBytes` 调 `_buildStyleTag`）。
class _ReaderResourceResponse {
  const _ReaderResourceResponse({
    required this.contentType,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.data,
    this.contentEncoding,
  });

  final String contentType;
  final String? contentEncoding;
  final int statusCode;
  final String reasonPhrase;
  final Map<String, String> headers;
  final Uint8List data;
}

extension _ReaderWebView on _ReaderFushiPageState {
  // ── URL & Resource Serving (mirrors Hoshi Android's fushi.local scheme) ──

  String _chapterUrl(int index) {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return 'about:blank';
    }
    return ReaderFushiSource.epubUrl(_book!.chapters[index].href);
  }

  Future<void> _loadChapterDirectly(int index) async {
    final String url = _chapterUrl(index);
    // BUG-1280：交给 WebView 的是正文章节文档，清 spread 标记（见字段注释）。
    // spread 的兜底降级路径 `_loadSpreadPage` → `_loadChapterDirectly` 也经过
    // 这里，所以标记不会泄漏成「以为还在双页」。
    if (_spreadDocumentLoaded) {
      _rebuild(() {
        _spreadDocumentLoaded = false;
      });
    }
    _isNavigatingToChapter = true;
    try {
      await _controller!.loadUrl(
        urlRequest: URLRequest(url: WebUri(url)),
      );
    } catch (e) {
      _isNavigatingToChapter = false;
      rethrow;
    }
  }

  static bool get _usesReaderResourceCustomScheme =>
      Platform.isMacOS || Platform.isIOS;

  static bool _isReaderResourceUrl(WebUri url) {
    if (url.host != ReaderFushiSource.kHost) return false;
    return url.scheme == 'https' ||
        url.scheme == ReaderFushiSource.kResourceScheme;
  }

  static String? _contentEncodingForMime(String mime) {
    if (mime.startsWith('text/') ||
        mime.contains('xml') ||
        mime.contains('xhtml') ||
        mime == 'application/javascript') {
      return 'utf-8';
    }
    return null;
  }

  static _ReaderResourceResponse _notFound(String reason) {
    debugPrint('[ReaderFushi] 404: $reason');
    return _ReaderResourceResponse(
      contentType: 'text/plain',
      contentEncoding: 'utf-8',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  static _ReaderResourceResponse _forbidden(String reason) {
    debugPrint('[ReaderFushi] 403: $reason');
    return _ReaderResourceResponse(
      contentType: 'text/plain',
      contentEncoding: 'utf-8',
      statusCode: 403,
      reasonPhrase: 'Forbidden',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  Future<_ReaderResourceResponse> _readerResourcePayload(WebUri url) async {
    final String path = url.path;

    if (path.startsWith('/fonts/')) {
      final String raw = path.substring('/fonts/'.length);
      final String fontPath = Uri.decodeComponent(raw);
      final String? safeFontPath = ReaderFushiSource.safeCustomFontPath(
        fontPath,
        allowedRoots: <String>[
          p.join(appModel.appDirectory.path, 'custom_fonts')
        ],
      );
      if (safeFontPath == null) {
        return _forbidden('font outside allowed directory: $fontPath');
      }
      final Set<String> allowedPaths =
          (_settings?.customFonts ?? <Map<String, dynamic>>[])
              .map((e) => e['path'] as String?)
              .whereType<String>()
              .map(p.canonicalize)
              .toSet();
      if (!allowedPaths.contains(safeFontPath)) {
        return _forbidden('font not in whitelist: $fontPath');
      }
      final File fontFile = File(safeFontPath);
      if (!fontFile.existsSync()) {
        return _notFound('font not found: $fontPath');
      }
      final Uint8List data = await fontFile.readAsBytes();
      if (!_isValidFontData(data)) {
        return _notFound('font corrupted: $fontPath (${data.length} bytes)');
      }
      debugPrint(
          '[ReaderFushi] font served: $safeFontPath (${data.length} bytes)');
      final String mime = fallbackMimeType(safeFontPath);
      return _ReaderResourceResponse(
        contentType: mime,
        contentEncoding: _contentEncodingForMime(mime),
        statusCode: 200,
        reasonPhrase: 'OK',
        headers: <String, String>{
          'Access-Control-Allow-Origin': '*',
          'Cache-Control': 'max-age=3600',
        },
        data: data,
      );
    }

    if (!path.startsWith('/epub/')) return _notFound('unknown path: $path');
    if (_extractDir == null) return _notFound('extractDir not ready: $path');

    final String epubPath =
        Uri.decodeComponent(path.substring('/epub/'.length));
    // BUG-1218：边界校验用 canonicalize（大小写折叠，`../` 逃逸不被大小写绕过），
    // 真实读取路径用 normalize（**保留大小写**）。拿 canonicalize 的结果去 File()
    // 会把 `OEBPS/Dick_x.htm` 折成 `oebps/dick_x.htm` —— Windows 侥幸能读，
    // Android/Linux 上 existsSync 为 false，每个章节请求都 404。
    // 与 EpubParser._resolveWithinExtract / _safeArchivePath 同款。
    final String joinedPath = p.join(_extractDir!, epubPath);
    final String normExtractDir = p.normalize(_extractDir!);
    final String filePath = p.normalize(joinedPath);
    if (!p.isWithin(p.canonicalize(_extractDir!), p.canonicalize(joinedPath))) {
      return _forbidden('path traversal blocked: $epubPath');
    }
    final File file = File(filePath);
    if (!file.existsSync()) {
      return _notFound('resource not found: $epubPath (resolved: $filePath)');
    }

    Uint8List data = await file.readAsBytes();

    // BUG-1203：「这是不是一个该走 HTML 处理链的内容文档」以 **EPUB 自己声明的
    // media-type** 为准，扩展名表只在声明缺失/畸形时兜底。EPUB 不规定内容文档的
    // 文件扩展名，只规定 media-type，所以任何扩展名白名单都必然漏（BUG-1199 补了
    // `.htm`/`.xht` 之后，下一本用别的扩展名甚至无扩展名的书会以同样方式空白）。
    //
    // 查找键与 [EpubParser] 建 resources 表时同构造（相对 extractDir 的 posix 相对
    // 路径），所以用已归一化的 filePath 反推，而不是直接拿 URL 里的 epubPath——后者
    // 会被 `./`、百分号编码差异带偏而静默查不到。
    //
    // BUG-1218：两侧同时改成**保留大小写**的 normalize 形式。原先两侧都 canonicalize
    // （都被折成小写）也能互相匹配，但那让 filePath 在大小写敏感平台上根本读不到文件；
    // 现在 parser 的 resources 键与这里的 declaredHref 都是真实大小写，既能读到文件，
    // 也仍然对得上。
    final String declaredHref =
        p.relative(filePath, from: normExtractDir).replaceAll('\\', '/');
    final String extMime = fallbackMimeType(filePath);
    // [EpubBook.mediaType] 自带「manifest 未声明就按扩展名兜底」，故 book 未就绪 /
    // 资源不在 manifest / OPF 缺 media-type 三种情况都自然退回 extMime。
    final String declaredMime = _book?.mediaType(declaredHref) ?? extMime;
    // 两个真相源任一认它是 HTML 就当 HTML：只放宽不收紧，OPF 声明畸形（例如把 xhtml
    // 标成 text/plain）时仍由扩展名兜住，不会比改动前更差。
    final bool isHtmlDocument =
        isHtmlMediaType(declaredMime) || isHtmlMediaType(extMime);
    // ⚠️ 分类归分类，下发的 Content-Type 一律 `text/html`，绝不回
    // `application/xhtml+xml`：那会让渲染器切到严格 XML 解析，出版社 EPUB 常见的
    // well-formedness 瑕疵会变成整页 parse error，且 BUG-079 / BUG-737 的
    // `sanitizeXhtml` 是为 HTML5 解析语义写的补偿，切走后不再防护那两类故障。
    final String mime = isHtmlDocument ? 'text/html' : extMime;

    if (mime == 'text/css') {
      // 插入后按插入序逐出最老条目（[_kSanitizedCssCacheLimit] 封顶，见字段注释）。
      while (_sanitizedCssCache.length >=
              _ReaderFushiPageState._kSanitizedCssCacheLimit &&
          !_sanitizedCssCache.containsKey(filePath)) {
        _sanitizedCssCache.remove(_sanitizedCssCache.keys.first);
      }
      data = _sanitizedCssCache.putIfAbsent(filePath, () {
        // HBK-AUDIT-118: tolerate non-UTF-8 CSS bytes instead of throwing.
        final String cssText = utf8.decode(data, allowMalformed: true);
        final String sanitized = ReaderResourceSanitizer.sanitizeCss(cssText);
        return Uint8List.fromList(utf8.encode(sanitized));
      });
    }

    if (isHtmlDocument && _settings != null) {
      // BUG-270 (TODO-296 B): repeat chapter visits (forward/back paging,
      // prefetched chapters) reuse the sanitized + style-injected bytes from
      // the LRU cache instead of re-reading/decoding/sanitizing/injecting. The
      // cache is dropped on every style change (_invalidateStyleCache), so a
      // cached entry always carries the current styleTag.
      data = _chapterHtmlBytes(filePath, data);
    }

    // TODO-1074 (root cause B): images are immutable on disk and carry no live
    // style injection (unlike HTML/CSS which are re-sanitized per style change),
    // so let the WebView cache the decoded bitmap. Without this, every "text ->
    // image -> text" chapter round-trip re-reads the file off disk and re-decodes
    // it at full resolution (no-cache defeats the WebView bitmap cache). HTML/CSS
    // stay no-cache because their bytes change when the reader style changes.
    final bool isImage = mime.startsWith('image/');
    final String cacheControl = isImage ? 'max-age=3600' : 'no-cache';
    return _ReaderResourceResponse(
      contentType: mime,
      contentEncoding: _contentEncodingForMime(mime),
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: <String, String>{
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': cacheControl,
      },
      data: data,
    );
  }

  Future<WebResourceResponse?> _interceptRequest(WebUri url) async {
    if (!_isReaderResourceUrl(url)) return null;
    _ReaderResourceResponse response;
    try {
      response = await _readerResourcePayload(url);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderFushi.interceptResource', e, stack);
      response = _notFound('resource intercept failed: $url');
    }
    return WebResourceResponse(
      contentType: response.contentType,
      contentEncoding: response.contentEncoding,
      statusCode: response.statusCode,
      reasonPhrase: response.reasonPhrase,
      headers: response.headers,
      data: response.data,
    );
  }

  Future<CustomSchemeResponse> _loadResourceWithCustomScheme(
    WebResourceRequest request,
  ) async {
    _ReaderResourceResponse response;
    try {
      response = _isReaderResourceUrl(request.url)
          ? await _readerResourcePayload(request.url)
          : _notFound('unknown custom scheme URL: ${request.url}');
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderFushi.customSchemeResource', e, stack);
      response = _notFound('custom scheme resource failed: ${request.url}');
    }
    return CustomSchemeResponse(
      contentType: response.contentType,
      contentEncoding: response.contentEncoding ?? '',
      data: response.data,
    );
  }

  // BUG-270 (TODO-296 B): return the sanitized + style-injected chapter bytes
  // for [filePath], serving from the LRU cache on a hit and building+caching on
  // a miss. [rawData] is the already-read on-disk bytes from _interceptRequest
  // (avoids a second disk read on the cold path). On an LRU hit the entry is
  // moved to most-recently-used.
  Uint8List _chapterHtmlBytes(String filePath, Uint8List rawData) {
    final Uint8List? cached = _sanitizedHtmlCache.remove(filePath);
    if (cached != null) {
      _sanitizedHtmlCache[filePath] = cached; // bump to MRU
      return cached;
    }
    final Uint8List built = _buildSanitizedChapterHtmlBytes(
      rawData,
      chapterIndex: _chapterIndexForFilePath(filePath),
    );
    _putChapterHtml(filePath, built);
    return built;
  }

  // TODO-1128: reverse the served on-disk XHTML path back to its spine index so
  // the injection pipeline can look up absorbed single-image chapters. Linear
  // scan over chapters (tens–hundreds), only on the cold cache-miss/prefetch
  // path — never per frame. Returns -1 when the path is not a chapter document.
  int _chapterIndexForFilePath(String filePath) {
    final EpubBook? book = _book;
    if (book == null) return -1;
    for (int i = 0; i < book.chapters.length; i++) {
      if (_chapterFilePath(i) == filePath) return i;
    }
    return -1;
  }

  // BUG-270: insert into the LRU, evicting the least-recently-used entry when
  // over the size limit. LinkedHashMap preserves insertion order; the oldest key
  // is removed first.
  void _putChapterHtml(String filePath, Uint8List bytes) {
    _sanitizedHtmlCache.remove(filePath);
    _sanitizedHtmlCache[filePath] = bytes;
    while (_sanitizedHtmlCache.length >
        _ReaderFushiPageState._kChapterHtmlCacheLimit) {
      _sanitizedHtmlCache.remove(_sanitizedHtmlCache.keys.first);
    }
  }

  // BUG-270: the sanitize + style-inject pipeline, extracted from
  // _interceptRequest so it can also run during prefetch. Decodes the raw
  // chapter bytes (UTF-8/BOM tolerant, HBK-AUDIT-118), normalizes self-closing
  // raw-text elements (BUG-079), injects the FOUC cloak + reader styleTag, and
  // returns the final UTF-8 bytes served to the WebView.
  Uint8List _buildSanitizedChapterHtmlBytes(
    Uint8List rawData, {
    int chapterIndex = -1,
  }) {
    String html = utf8.decode(rawData, allowMalformed: true);
    html = ReaderResourceSanitizer.sanitizeXhtml(html);
    // TODO-perf（跨章·图片）：离屏插图不该拖住 window.load —— 属性必须写进 HTML 源码
    // 才对本次加载生效（JS 侧那次 lazy 跑在 load 之后，来不及，见 markImagesLazy）。
    // 纯图片章整章 eager：它的分页几何要靠插图真实撑开（TODO-1349）。判据用 EpubBook
    // 的 isImageOnlyChapter（比 JS 侧「正文无任何可匹配字符」宽松），保证这里 eager 的
    // 集合是 JS 侧 eager 集合的超集，不会倒挂。合并注入的前导插图自带显式
    // `loading="eager"`（见 [_injectMergedChapterImages]），故 TODO-1339 的 eager 不依赖
    // 本行与注入行的先后顺序；守卫 `test/reader/reader_image_lazy_pipeline_guard_test.dart`。
    html = ReaderResourceSanitizer.markImagesLazy(
      html,
      eagerAll: _isImageOnlyChapterCached(chapterIndex),
    );
    // TODO-1128 / TODO-1174: when this text chapter absorbs the preceding
    // single-image chapters (merge-image on), prepend their <img> to the *start*
    // of the flow before the reader style is injected, so the illustrations
    // render inline at the top of the chapter they introduce instead of each
    // taking their own virtual page. No-op on the common path.
    html = _injectMergedChapterImages(html, chapterIndex);
    final String styleTag = _buildStyleTag();
    const String hideUntilReady =
        '<style id="fushi-cloak">body{visibility:hidden!important}</style>';
    // Cloak goes early (right after <head>) to hide FOUC. Reader style goes last
    // (before </head>) so it wins over EPUB CSS in !important specificity ties.
    final RegExp headOpenPattern = RegExp('<head[^>]*>', caseSensitive: false);
    final RegExp headClosePattern = RegExp(r'</head\s*>', caseSensitive: false);
    final RegExpMatch? headOpen = headOpenPattern.firstMatch(html);
    final RegExpMatch? headClose = headClosePattern.firstMatch(html);
    if (headOpen != null && headClose != null) {
      html = '${html.substring(0, headOpen.end)}\n$hideUntilReady'
          '${html.substring(headOpen.end, headClose.start)}\n$styleTag\n'
          '${html.substring(headClose.start)}';
    } else if (headOpen != null) {
      html =
          '${html.substring(0, headOpen.end)}\n$hideUntilReady\n$styleTag${html.substring(headOpen.end)}';
    } else {
      html = '$hideUntilReady\n$styleTag\n$html';
    }
    return Uint8List.fromList(utf8.encode(html));
  }

  // TODO-1128 / TODO-1174: prepend the absorbed image-only chapters' images to
  // the *start* of [html]'s <body> when the spread map records this text chapter
  // as absorbing the images that precede it (merge-image on). Each absorbed
  // chapter contributes *all* of its image references (chapterImageSrcs covers
  // <img>, SVG <image>, and CSS background-image — TODO-1174 broadened the
  // classifier, so an SVG-only or multi-image illustration page must re-emit
  // every image or the merge would silently drop illustrations). Each relative
  // src is resolved to an absolute fushi.local /epub URL relative to *that* image
  // chapter's own href, so a text chapter absorbing images from a different
  // directory still points at the right files (the served text chapter's baseURI
  // would otherwise mis-resolve them); already-absolute (data:/scheme) refs pass
  // through untouched. The insertion position is a pure string op in
  // ReaderResourceSanitizer.injectImagesAfterBodyOpen (unit-tested). No-op unless
  // merge is on and the chapter absorbs images.
  String _injectMergedChapterImages(String html, int chapterIndex) {
    if (chapterIndex < 0) return html;
    final EpubBook? book = _book;
    final EpubSpreadMap? map = _spreadMap;
    if (book == null || map == null) return html;
    final List<int> merged = map.mergedImagesForChapter(chapterIndex);
    if (merged.isEmpty) return html;

    final StringBuffer figures = StringBuffer();
    for (final int imageChapter in merged) {
      final String chapterDir =
          p.posix.dirname(normalizeHref(book.chapters[imageChapter].href));
      for (final String src in book.chapterImageSrcs(imageChapter)) {
        if (src.trim().isEmpty) continue;
        final bool isAbsolute = src.startsWith('data:') || src.contains('://');
        final String absoluteUrl = isAbsolute
            ? src
            : ReaderFushiSource.epubUrl(
                p.posix.normalize(p.posix.join(chapterDir, src)));
        // TODO-1339 / BUG-1140 第二轮：显式 `loading="eager"`。这些前导插图是章首
        // **结构性**内容（firstContentEdge 只计入非零尺寸媒体，挂 lazy 会让章首锚跳过
        // 第一张）。JS 侧靠 `.fushi-merged-image` 放行，Dart 侧原本只靠「markImagesLazy
        // 排在本方法之前」这一条**调用顺序**——谁把两行调个个儿，守卫全绿而 bug 复活。
        // 写成显式 loading 属性后 [ReaderResourceSanitizer.markImagesLazy] 的
        // 「已有 loading= 就尊重原书」分支会跳过它们，顺序不再是正确性的承重墙。
        figures.write(
          '<div class="fushi-merged-image">'
          '<img src="${htmlEscape.convert(absoluteUrl)}" class="block-img" '
          'loading="eager"/>'
          '</div>',
        );
      }
    }
    if (figures.isEmpty) return html;

    return ReaderResourceSanitizer.injectImagesAfterBodyOpen(
      html,
      figures.toString(),
    );
  }

  // BUG-270: resolve the absolute on-disk path of chapter [index]'s XHTML, or
  // null when out of range / book not ready. Mirrors the path resolution in
  // _interceptRequest (extractDir + chapter href) so cache keys line up.
  String? _chapterFilePath(int index) {
    final EpubBook? book = _book;
    final String? dir = _extractDir;
    if (book == null || dir == null) return null;
    if (index < 0 || index >= book.chapters.length) return null;
    final String href = normalizeHref(book.chapters[index].href);
    // BUG-1218：必须与 [_readerResourcePayload] 用**同一种**路径形式（normalize，
    // 保留大小写），否则两边算出的 LRU cache key 一个折成小写一个原样，BUG-270 的
    // 章节缓存/预热永远不命中；在大小写敏感平台上更是直接指向不存在的文件。
    final String joined = p.join(dir, href);
    if (!p.isWithin(p.canonicalize(dir), p.canonicalize(joined))) return null;
    return p.normalize(joined);
  }

  // BUG-270: warm the LRU with the next chapter (in reading direction) so a
  // forward page-turn that crosses a chapter boundary hits the cache instead of
  // paying disk read + decode + sanitize + inject. Skips when already cached,
  // already in flight, or settings/book not ready.
  //
  // 调度纪律（渐进重建 phase2）：旧实现用 scheduleMicrotask + 同步读盘——microtask
  // 在当前任务展开后**立刻**执行，读盘+净化全落在同一帧内（还恰好在等
  // onRestoreComplete 的窗口里），「Runs off the UI frame」是错觉；同步执行也让
  // _prefetchingHtmlPath 在飞守卫形同虚设（同步不可能重入）。现改事件队列任务 +
  // 异步 IO：当前帧先收尾，IO 让出主 isolate，净化（单章 ms 级 sync CPU）保留；
  // 真异步后按 _styleEpoch 丢弃跨样式失效的过期结果（styleTag 烤进缓存条目），
  // 在飞守卫此时才真正有防重入意义。
  void _prefetchAdjacentChapter(int index) {
    if (_settings == null) return;
    final String? filePath = _chapterFilePath(index);
    if (filePath == null) return;
    if (_sanitizedHtmlCache.containsKey(filePath)) return;
    if (_prefetchingHtmlPath == filePath) return;
    _prefetchingHtmlPath = filePath;
    final int styleEpochAtStart = _styleEpoch;
    unawaited(Future<void>(() async {
      try {
        if (!mounted || _settings == null) return;
        if (_sanitizedHtmlCache.containsKey(filePath)) return;
        final File file = File(filePath);
        if (!await file.exists()) return;
        final Uint8List raw = await file.readAsBytes();
        if (!mounted || _settings == null) return;
        final Uint8List built =
            _buildSanitizedChapterHtmlBytes(raw, chapterIndex: index);
        if (!mounted || _styleEpoch != styleEpochAtStart) return;
        _putChapterHtml(filePath, built);
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderFushi._prefetchAdjacentChapter', e, stack);
      } finally {
        if (_prefetchingHtmlPath == filePath) {
          _prefetchingHtmlPath = null;
        }
      }
    }));
  }

  /// 章号非法 / 书未就绪时返回 true（保守走 eager，宁可慢一点也不冒「该 eager 的图
  /// 被挂 lazy」导致分页几何塌缩的风险）；其余委托 [EpubBook.isImageOnlyChapter]——
  /// 记忆化已下沉到数据拥有者，本拦截器热路径与 spread 配对 / 边缘分析 / 预取共享
  /// 同一份按章缓存，不再各存一份。
  bool _isImageOnlyChapterCached(int chapterIndex) {
    if (chapterIndex < 0) return true;
    final EpubBook? book = _book;
    if (book == null) return true;
    return book.isImageOnlyChapter(chapterIndex);
  }

  /// TODO-perf（跨章·图片）：把下一章的插图预热进 WebView 的 HTTP 缓存。
  ///
  /// 实测（`[chapter-perf]`，1600×2400 PNG × 3~4 张的章节）：**首次**进入带插图的章
  /// docLoad 689~717ms，其中 `nav.dcl` 只有 15~20ms——DOM 早就解析完了，剩下 670ms
  /// 全是在等图片读盘+解码；而**再次**进入同一章只要 66ms，因为图片命中了 WebView 缓存
  /// （图片响应带 `Cache-Control: max-age=3600`，见 [_readerResourcePayload]）。
  /// 遮罩正好盖住这整段（setup 脚本挂在 `window.load` 之后），所以带插图的跨章体感是
  /// 「翻一下要大半秒」。
  ///
  /// 这里在**当前章已经读起来之后**，用一个隐藏的 `new Image()` 把下一章的图按同样的
  /// URL 请求一遍：走的是同一个 `fushi.local` 拦截器、同一份缓存条目，等用户真的翻过去
  /// 时那些图已经在缓存里。纯预热，不改 DOM、不参与任何几何计算；失败静默（预热不到就
  /// 退回原来的现付现取）。
  ///
  /// **配额**（PR#469 审查）：预热是把整解码后的位图塞进 WebView 图片缓存，整页插图书
  /// （1600×2400 PNG × N）在移动端是实打实的内存压力，而 HTML 预取那边早有
  /// `_kChapterHtmlCacheLimit` LRU 上限。这里同样封顶：最多
  /// [_ReaderFushiPageState._kImagePrefetchMaxCount] 张、累计原始字节不超过
  /// [_ReaderFushiPageState._kImagePrefetchMaxBytes]（按磁盘文件大小计，读 stat 不读内容），
  /// 超出即停——预热本就是尽力而为，少热几张只是少省一点，不影响正确性。
  void _prefetchAdjacentChapterImages(int index) {
    final EpubBook? book = _book;
    final InAppWebViewController? controller = _controller;
    if (book == null || controller == null) return;
    if (index < 0 || index >= book.chapters.length) return;
    final List<String> srcs = book.chapterImageSrcs(index);
    if (srcs.isEmpty) return;
    final String? extractDir = _extractDir;
    final String chapterDir =
        p.posix.dirname(normalizeHref(book.chapters[index].href));
    final List<String> urls = <String>[];
    int budget = _ReaderFushiPageState._kImagePrefetchMaxBytes;
    for (final String src in srcs) {
      if (urls.length >= _ReaderFushiPageState._kImagePrefetchMaxCount) break;
      if (budget <= 0) break;
      final String trimmed = src.trim();
      if (trimmed.isEmpty) continue;
      // data: / 绝对 URL 不经我们的拦截器，预热无意义。
      if (trimmed.startsWith('data:') || trimmed.contains('://')) continue;
      final String rel = p.posix.normalize(p.posix.join(chapterDir, trimmed));
      budget -= _imageFileSizeBytes(extractDir, rel);
      urls.add(ReaderFushiSource.epubUrl(rel));
    }
    if (urls.isEmpty) return;
    final String json = jsonEncode(urls);
    unawaited(controller
        .evaluateJavascript(
          source: '(function(){try{var u=$json;'
              'for(var i=0;i<u.length;i++){var im=new Image();'
              'im.decoding="async";im.src=u[i];}}catch(e){}})();',
        )
        .catchError((Object _) => null));
  }

  /// 预热配额用的磁盘体量（只 stat 不读内容）。解出的路径必须仍在 extractDir 内
  /// （与 [_chapterFilePath] 同一条越界判据）；解析不到就按 0 计——配额是保护，不是
  /// 正确性依赖，宁可少扣也不因为一次 stat 失败把整章预热掐掉。
  int _imageFileSizeBytes(String? extractDir, String relativeHref) {
    if (extractDir == null) return 0;
    try {
      // BUG-1218：真实 stat 路径保留大小写（越界判据仍走 canonicalize）。
      final String joined = p.join(extractDir, relativeHref);
      if (!p.isWithin(p.canonicalize(extractDir), p.canonicalize(joined))) {
        return 0;
      }
      final String filePath = p.normalize(joined);
      final File file = File(filePath);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  static bool _isValidFontData(Uint8List data) => isValidFontData(data);

  /// BUG-1140 第二阶段①：三种 furigana 模式的监听器全部随引擎发一份，运行时按
  /// `C.furiganaMode` 选一个装（旧实现在 Dart 侧按 `s.furiganaMode` 三选一插值，
  /// 那会让引擎源码随设置变化 → 外链缓存与编译复用同时失效）。
  ///
  /// 值域与分支判据逐条对齐旧的 `switch (mode)`：`partial` 装 click 切换单个 ruby、
  /// `toggle` 装 dblclick 切换整页、其余（含 `off`）什么都不装。
  static String _buildFuriganaJs() {
    return '''
  if (C.furiganaMode === 'partial') {
    document.addEventListener('click', function(e) {
      var sel = window.getSelection();
      if (sel && !sel.isCollapsed) return;
      var node = e.target;
      while (node && node !== document.body) {
        if (node.tagName === 'RUBY') {
          node.classList.toggle('show-rt');
          return;
        }
        node = node.parentElement;
      }
    }, true);
  } else if (C.furiganaMode === 'toggle') {
    document.addEventListener('dblclick', function() {
      var sel = window.getSelection();
      if (sel && !sel.isCollapsed) return;
      document.body.classList.toggle('show-all-rt');
    });
  }''';
  }

  // ── Single IIFE setup script (mirrors Hoshi Android's readerSetupScript) ──

  /// BUG-1140 第二阶段①：本次导航的引擎参数。
  ///
  /// 这里聚齐的就是**改动前逐个插进脚本源码的那些值**——现在改成一份小 JSON 随
  /// boot 下发，引擎运行时读取。新增 per-nav 参数一律加在这里，不得回到脚本里插值。
  ReaderEngineConfig _buildReaderEngineConfig({
    required int navigationGeneration,
    String? sentenceAudioCuesJson,
  }) {
    final ReaderSettings s = _settings!;
    // TODO-113: 滑动翻页距离阈值随灵敏度系数缩放。基础值 44px（纯距离触发）/ 22px
    // （配合速度的快速短滑触发），系数 1.0 = 默认「轻快」手感，越大越迟钝（需滑得更远）。
    final ({int dist, int fastDist}) swipeThresholds =
        ReaderSettings.swipePageTurnDistThresholds(s.swipePageTurnSensitivity);
    // BUG-239: 连续模式靠原生滚动（滚动轴 = 书写轴），章间切换走边界手势 IIFE。
    // _gestureEnd 的 onSwipe（90% 整屏跳页）只在分页模式有意义；连续模式回传会与
    // 原生滚动产生轴向冲突，故注入 continuousMode 标志在 _gestureEnd 内门控。
    final bool continuousMode = s.isContinuousMode;
    // TODO-909: select the VN shell when view-mode == 'vn'. VN is mutually
    // exclusive with continuous (it is a page-flip stage, not native scroll),
    // so continuousMode stays false here.
    final bool vnMode = s.isVnMode;
    // TODO-909 M0: VN blank-tap advance. hoshi default clickAdvance=false
    // (commit `42c0bab`); M0 force-enables the tap binding so the device Gate
    // can verify click-to-advance. M1 falls back to s.visualNovelClickAdvance.
    const bool vnClickAdvanceM0ForceOn = true; // M1: s.visualNovelClickAdvance
    // TODO-909 M0: reveal（打字渐显）是 M1 功能。在 M0 强制 revealSpeed=0，使每屏
    // renderScreen 即 revealComplete=true、paginate 只返 "scrolled"/"limit"。否则
    // revealSpeed>0 时新屏停在 revealComplete=false，forward 翻屏会命中 paginate 的
    // `if(!revealComplete) completeCurrentReveal(); return "revealed"` 分支，而
    // Dart 的 _didScroll（chrome.part.dart）只认 "scrolled" 为真 → 误判章节边界
    // 触发 _handlePageTurnLimit 跨章。M1 去掉本强制、改走 s.visualNovelRevealSpeed。
    const int vnRevealSpeedM0ForceZero = 0; // M1: s.visualNovelRevealSpeed
    final Size screenSize = MediaQuery.of(context).size;
    // BUG-111: 这就是 JS 分页用的权威宽高（dartPageWidth/Height）。记下来作为
    // content-ready 后的「已分页基线」，供 _syncPageSize 与 settle 后的真实视口比对。
    _paginatedWidth = screenSize.width;
    _paginatedHeight = screenSize.height;
    return ReaderEngineConfig(
      navigationGeneration: navigationGeneration,
      continuousMode: continuousMode,
      vnMode: vnMode,
      vnClickAdvance: vnMode && vnClickAdvanceM0ForceOn,
      scanNonJapaneseText: appModel.scanNonJapaneseText,
      // TODO-756b：是否“鼠标悬停即自动查词”。live 变更经 _applyHoverAutoLookupLive
      // 改同一个 JS 全局，无需整章重注入。
      hoverAutoLookup: ReaderFushiSource.instance.hoverAutoLookup,
      highlightOnTap: ReaderFushiSource.instance.highlightOnTap,
      showChrome: _showChrome,
      debugLogging: DebugLogService.instance.enabled,
      swipeDistThreshold: swipeThresholds.dist,
      swipeFastDistThreshold: swipeThresholds.fastDist,
      wheelGestureQuietMs:
          ReaderFushiSource.instance.wheelPageTurnInterval.clamp(150, 800),
      furiganaMode: s.furiganaMode,
      caretColor: _caretRingColorCss(),
      caretInsetTop: _readerTopOffset,
      // TODO-975：与 chromeBottomInset 同源 _readerBottomReserve（悬浮 0 / 挤压含底栏）。
      caretInsetBottom: _readerBottomReserve,
      initialProgress: _initialProgress,
      initialCharOffset: _initialCharOffset,
      // BUG-461: 收藏句跳转的句尾锚（连续模式横排整句对齐进可见区）；非跳转/无句长 = -1。
      initialCharOffsetEnd: _initialCharOffsetEnd,
      initialFragment: _initialFragment,
      chromeTopInset: _readerTopOffset,
      // TODO-975：单一真相源 _readerBottomReserve（悬浮态 0 / 挤压态含底栏高 + 系统
      // inset），取代旧 `_showChrome ? height+inset : inset` 三元式。
      chromeBottomInset: _readerBottomReserve,
      dartPageWidth: screenSize.width,
      dartPageHeight: screenSize.height,
      marginTop: s.marginTop,
      marginBottom: s.marginBottom,
      marginLeft: s.marginLeft,
      marginRight: s.marginRight,
      blurImages: s.blurImages,
      // TODO-1289：把本次会话已揭开的防剧透图 key 下发，重载时不再重新遮罩。
      revealedKeys: _revealedImageKeys.toList(),
      // TODO-perf（跨章）：JS 侧埋点与 Dart 侧同一个开关。生产下恒 false，
      // perfMark / perfSnapshot 在 JS 里直接 early-return。
      perfTraceEnabled: ReaderChapterPerfTrace.enabled,
      vnRevealSpeed: vnMode ? vnRevealSpeedM0ForceZero : 0,
      vnScreenMode: s.visualNovelScreenMode,
      vnSentencesPerScreen: s.visualNovelSentencesPerScreen,
      vnPreserveDialogue: s.visualNovelPreserveDialogueBubbles,
      vnMergeCrossScreenSentenceAudioCues:
          s.visualNovelMergeCrossScreenSentenceAudioCues,
      sentenceAudioCuesJson: sentenceAudioCuesJson,
    );
  }

  /// 阅读器引擎的**静态**源码（零 per-nav 插值），按 view-mode 分三份。
  ///
  /// 原名 `_buildReaderSetupScript({sasayakiCuesJson})`——每次跨章把 insets /
  /// pageWidth / progress / charOffset / fragment / cue 列表逐个插进源码，于是**每次
  /// 导航都要重新拼装近万行、再整份过一遍 [ReaderScriptCompactor]**（实测
  /// `buildSetupScript` 中位数 9ms，纯 Dart 侧固定开销，与章节体量无关）。
  ///
  /// 现在整段 body 是 `window.__fushiEngine.install(C)` 的函数体，per-nav 参数一律
  /// 运行时读 `C`（[ReaderEngineConfig]）。源码只依赖 view-mode 与编译期常量，一个
  /// 进程里逐字不变，于是可以按模式 memoize（[readerEngineSource]）：拼装 + 压缩从
  /// 每章一次降为每模式一次。
  ///
  /// **注入方式与执行时刻都没变**：仍是 Dart 在 `onLoadStop` 之后一次
  /// `evaluateJavascript(引擎源码 + boot)`，同一时刻、同一同步执行序、同一次平台通道
  /// 往返。本改动**不碰**注入通道本身——实测那条通道的固定往返约 7.5ms、与载荷大小
  /// 几乎无关（发 2 字符 7.5ms vs 发 147459 字符 9.0ms），要压它得减少往返次数而不是
  /// 减少字节数，属另一件事。
  ///
  /// 因为不再读任何实例状态，本方法是 static + memoized。
  static String _buildReaderEngineSource({
    required bool vnMode,
    required bool continuousMode,
  }) {
    const int tapSlop = ReaderSettings.tapSlopPx;
    final String selectionJs = ReaderSelectionScripts.source();
    // TODO-1317: mobile long-press drag-select gesture IIFE (own touch
    // listeners, coordinates via window.__fushiTextSelectDragActive).
    final String longPressDragJs =
        ReaderSelectionScripts.longPressDragGestureScript();
    // 只嵌当前 view-mode 那一份 shell（注入体量与改动前一致）；运行时分流点仍在 JS
    // 侧读 C，Dart 不再把 per-nav 值插值进 shell。
    final String paginationJs = _stripScriptTags(
      ReaderPaginationScripts.engineShell(
        vnMode: vnMode,
        continuousMode: continuousMode,
      ),
    );

    // 三种 furigana 模式的监听器全部随引擎发，运行时按 C.furiganaMode 选一个装。
    final String furiganaJs = _buildFuriganaJs();

    final String caretJs = ReaderCaretScripts.source();

    return '''
window.__fushiEngine = {
install: function(C) {
  // BUG-1017: guarantee the `#fushi-cloak` FOUC guard is always removed, even if
  // any synchronous statement in this setup IIFE throws before the tail reaches
  // its removal (below). Without this a single unhandled sync error anywhere in
  // setup (init / caret / furigana) left `body{visibility:hidden}` stranded =
  // permanent blank book. The microtask runs after this task unwinds whether it
  // completed or threw; the tail removal stays as the fast synchronous path, and
  // this reveal is idempotent (a second remove() on an absent node is a no-op).
  Promise.resolve().then(function() {
    try { var c = document.getElementById('fushi-cloak'); if (c) c.remove(); } catch (_ignored) {}
  });
  window.scanNonJapaneseText = C.scanNonJapaneseText;
  // BUG-1812: WKWebView may report innerWidth/innerHeight as 0 even though
  // Dart has the real logical viewport. Raw vh/vw margins then collapse to
  // zero. Materialize all four percentages into px from the same Dart-sized
  // viewport used by pagination, and expose one resize hook to every shell.
  window.__fushiApplyReaderMargins = function(width, height) {
    var w = Math.max(0, Number(width) || 0);
    var h = Math.max(0, Number(height) || 0);
    var root = document.documentElement;
    function pct(value) {
      var n = Number(value);
      return Number.isFinite(n) ? Math.max(0, Math.min(50, n)) : 0;
    }
    root.style.setProperty('--reader-margin-top', (h * pct(C.marginTop) / 100) + 'px');
    root.style.setProperty('--reader-margin-bottom', (h * pct(C.marginBottom) / 100) + 'px');
    root.style.setProperty('--reader-margin-left', (w * pct(C.marginLeft) / 100) + 'px');
    root.style.setProperty('--reader-margin-right', (w * pct(C.marginRight) / 100) + 'px');
  };
  window.__fushiApplyReaderMargins(C.dartPageWidth, C.dartPageHeight);
  $selectionJs
  $paginationJs
  window.__fushiInstallShell(C);
  $caretJs
  // TODO-975：insetBottom 与 chromeBottomInset 同源 _readerBottomReserve
  // （悬浮 0 / 挤压含底栏），由 Dart 侧算好放进 C。
  window.fushiCaret.init({
    color: C.caretColor,
    insetTop: C.caretInsetTop,
    insetBottom: C.caretInsetBottom,
    scopeSelector: null
  });
  $furiganaJs
  // BUG-239: 连续模式不让 _gestureEnd 回传 onSwipe（交给原生滚动 + 边界 IIFE），
  // 消除横向滑动 90% 跳页与原生滚动的轴向冲突；分页模式照旧水平滑动翻页。
  var fushiContinuousMode = C.continuousMode;
  // TODO-909 M0: VN-mode blank-tap advance flag (see Dart above).
  var fushiVnMode = C.vnMode;
  var fushiVnClickAdvance = C.vnClickAdvance;
  window.__hoverAutoLookup = C.hoverAutoLookup;
  var startX = 0, startY = 0, startTime = 0, hasStart = false;
  var gestureExceededTapSlop = false;
  var imageLongPressTimer = null;
  var imageLongPressConsumed = false;
  var imageLongPressStartX = 0, imageLongPressStartY = 0;
  var _fushiReaderMouseDragActive = false;
  var _fushiReaderMouseDragClaimed = false;
  var _fushiReaderMouseNativeTextStart = false;
  var _fushiReaderMouseDragLastX = 0, _fushiReaderMouseDragLastY = 0;
  var _fushiReaderMouseDragPointerId = null;
  var _fushiReaderMouseDragPageDirection = null;
  var _fushiReaderMouseDragSwipeSent = false;
  var _fushiReaderMouseDragIgnoreTouchEnd = false;
  function _gestureStart(x, y) {
    hasStart = true;
    startX = x;
    startY = y;
    startTime = Date.now();
    gestureExceededTapSlop = false;
    // TODO-1317: a fresh gesture (touch-start or mouse pointerdown) never
    // inherits a prior drag-select's flag; the drag-select timer re-arms it.
    window.__fushiTextSelectDragActive = false;
  }
  function _gestureTrackMovement(x, y) {
    if (!hasStart || gestureExceededTapSlop) return;
    var tapDx = x - startX;
    var tapDy = y - startY;
    if ((tapDx * tapDx + tapDy * tapDy) > ($tapSlop * $tapSlop)) {
      gestureExceededTapSlop = true;
    }
  }
  // TODO-909 M0: a VN tap is "blank" when the user tapped margin/gap rather than
  // a word (blank -> paginate forward; word -> onTap lookup).
  // BUG-748: caretPositionFromPoint/caretRangeFromPoint CLAMP to the nearest
  // character even when the tap is in the margin. VN centers one short block in a
  // shrink-to-fit .fushi-vn-content, so the whole viewport outside that small box
  // is margin — yet every tap clamps to a text node, so "text node found" alone
  // judged EVERY tap (incl. margins) as a word -> blank-tap advance never fired
  // (a 289-point scan found 0 blank points in centred vertical layout). Fix:
  // after resolving the clamped caret, verify the point actually falls inside the
  // resolved character's client rect; a clamped-but-outside hit is real blank.
  function _fushiVnTapIsBlank(x, y) {
    try {
      var range = _fushiReaderCaretRangeAtPoint(x, y);
      if (!range || !range.startContainer) return true;
      var node = range.startContainer;
      if (node.nodeType !== Node.TEXT_NODE) return true;
      var text = String(node.textContent || '');
      if (!text.trim()) return true;
      // Hit-test the resolved glyph box. caretPositionFromPoint clamps offset to
      // the nearest boundary, so probe the character on each side of the offset
      // and treat the tap as a word only if it lands inside one of their rects.
      var tol = 2;
      var offsets = [range.startOffset, range.startOffset - 1];
      for (var oi = 0; oi < offsets.length; oi++) {
        var start = offsets[oi];
        if (start < 0 || start >= text.length) continue;
        var charRange = document.createRange();
        charRange.setStart(node, start);
        charRange.setEnd(node, start + 1);
        var rects = charRange.getClientRects();
        for (var i = 0; i < rects.length; i++) {
          var r = rects[i];
          if (x >= r.left - tol && x <= r.right + tol &&
              y >= r.top - tol && y <= r.bottom + tol) {
            return false;
          }
        }
      }
      return true;
    } catch (err) {
      return true;
    }
  }
  function _fushiReaderCaretRangeAtPoint(x, y) {
    try {
      var range = null;
      if (document.caretPositionFromPoint) {
        var pos = document.caretPositionFromPoint(x, y);
        if (pos) {
          range = document.createRange();
          range.setStart(pos.offsetNode, pos.offset);
          range.collapse(true);
        }
      } else if (document.caretRangeFromPoint) {
        range = document.caretRangeFromPoint(x, y);
      }
      if (!range || !range.startContainer) return null;
      return range.startContainer.nodeType === Node.TEXT_NODE ? range : null;
    } catch (err) {
      return null;
    }
  }
  function _fushiReaderClearMouseSelection() {
    try {
      var selected = window.getSelection && window.getSelection();
      if (selected && !selected.isCollapsed) selected.removeAllRanges();
    } catch (err) {}
  }
  function _fushiReaderPointerPrimaryButton(e) {
    return e && (e.pointerType === 'touch' || e.button === 0);
  }
  function _fushiReaderPointerStillDown(e) {
    return e && (e.pointerType === 'touch' || (e.buttons & 1) === 1);
  }
  // TODO-553: 触摸只在「连续模式」走 pointer 拖动状态机（8f095de78 的触摸拖滚）；
  // 分页模式下触摸交还给 touchstart/touchend → _gestureEnd → onSwipe 的滑动翻页路径
  // （890378f19 前的行为）。鼠标左键在两种模式都走 pointer 机（拖选/划词/拖动翻页）。
  function _fushiReaderPointerEngages(e) {
    if (!_fushiReaderPointerPrimaryButton(e)) return false;
    if (e.pointerType === 'touch') return fushiContinuousMode;
    return true;
  }
  function _fushiReaderPointerNoSelect(enabled) {
    try {
      var id = 'fushi-reader-pointer-drag-style';
      var style = document.getElementById(id);
      if (!style) {
        style = document.createElement('style');
        style.id = id;
        style.textContent = '.fushi-reader-pointer-dragging, .fushi-reader-pointer-dragging *{-webkit-user-select:none!important;user-select:none!important;}';
        document.head.appendChild(style);
      }
      document.documentElement.classList.toggle('fushi-reader-pointer-dragging', !!enabled);
    } catch (err) {}
  }
  function _fushiReaderMouseDragStartAllowed(e) {
    if (!_fushiReaderPointerPrimaryButton(e)) return false;
    var target = e.target || document.elementFromPoint(e.clientX, e.clientY);
    if (target && target.closest) {
      if (target.closest('a[href], ruby, rt, rp')) return false;
      if (target.closest('input, textarea, select, button, [contenteditable="true"], [data-fushi-clk], #fushi-caret-ring')) return false;
    }
    var selected = window.getSelection && window.getSelection();
    if (selected && !selected.isCollapsed) return false;
    // 砍掉 PC 鼠标左键拖动平移（连续模式）：鼠标左键回归原生选字/划词查词，连续模式
    // 桌面滚动改用滚轮。原来 return true 会让鼠标左键走 JS scrollBy 模拟平移——这是
    // 卡顿（每次 move 触发全文 progress 重算）+「鼠标拖动没到章首就跨章」的来源。
    // 分页模式仍走下方逻辑（鼠标拖动转翻页 BUG-368 不受影响）。
    if (fushiContinuousMode) return false;
    if (window.fushiSelection &&
        window.fushiSelection.getCharacterAtPoint &&
        window.fushiSelection.getCharacterAtPoint(e.clientX, e.clientY)) {
      return false;
    }
    return !_fushiReaderCaretRangeAtPoint(e.clientX, e.clientY);
  }
  function _fushiReaderMouseDragScrollBy(dx, dy) {
    // drag-to-pan「内容跟手」的方向与 writing-mode 无关：鼠标往右拖(dx>0)→内容往右移
    // →scrollLeft 减小→scrollBy({left: -dx})；鼠标往上拖(dy<0)→内容往上→scrollTop 增大
    // →scrollBy({top: -dy})。BUG-338: 旧实现给竖排加了 (vertical-rl ? -1 : 1) 的 sign
    // 翻符号，把 vertical-rl 写成 scrollBy({left: dx}) 致拖动方向反了；删掉该特殊情况。
    var r = window.fushiReader;
    var vertical = !!(r && r.isVertical && r.isVertical());
    if (vertical) {
      window.scrollBy({left: -dx, top: 0, behavior: 'auto'});
    } else {
      window.scrollBy({left: 0, top: -dy, behavior: 'auto'});
    }
  }
  function _fushiReaderMouseDragResolvePageDirection(x, y) {
    var dx = x - startX;
    var dy = y - startY;
    var elapsed = Date.now() - startTime;
    var absDx = Math.abs(dx);
    var absDy = Math.abs(dy);
    var velocity = absDx / Math.max(1, elapsed) * 1000;
    var horizontalEnough = absDx > absDy;
    var distanceEnough =
        absDx >= C.swipeDistThreshold ||
        (absDx >= C.swipeFastDistThreshold && velocity >= 900);
    if (horizontalEnough && distanceEnough) {
      return dx < 0 ? 'left' : 'right';
    }
    return null;
  }
  function _finishFushiReaderMouseDrag(e) {
    var claimed = _fushiReaderMouseDragClaimed;
    var direction = _fushiReaderMouseDragPageDirection;
    _fushiReaderMouseDragActive = false;
    _fushiReaderMouseDragClaimed = false;
    _fushiReaderMouseNativeTextStart = false;
    _fushiReaderMouseDragPointerId = null;
    _fushiReaderMouseDragPageDirection = null;
    _fushiReaderPointerNoSelect(false);
    hasStart = false;
    if (!claimed) return false;
    if (e && e.preventDefault) e.preventDefault();
    if (!fushiContinuousMode && direction) {
      if (_fushiReaderMouseDragSwipeSent) return true;
      _fushiReaderMouseDragSwipeSent = true;
      window.flutter_inappwebview.callHandler('onSwipe', direction);
    }
    return true;
  }
  // Resolve a block illustration under the tap to an absolute image URL, or
  // null when the tap isn't on one. Handles both raster <img> covers/figures
  // and fixed-layout EPUB <svg><image> covers (which are not IMG elements, so
  // their xlink:href must be resolved against document.baseURI).
  function _fushiBlockImageUrl(target) {
    if (!target) return null;
    if (target.tagName === 'IMG' && target.src) return target.src;
    var wrapper = target.closest ? target.closest('.block-img-wrapper') : null;
    if (!wrapper) return null;
    var img = wrapper.querySelector('img.block-img');
    if (img && img.src) return img.src;
    var svg = wrapper.querySelector('svg.block-img');
    if (svg) {
      var im = svg.querySelector('image');
      if (im) {
        var href = im.getAttribute('xlink:href') || im.getAttribute('href');
        if (href) {
          try { return new URL(href, document.baseURI).href; } catch (err) {}
        }
      }
    }
    return null;
  }
  // TODO-861④（移植 Hoshi `f286108`）：若点击落在仍带 `blurred` 类的防剧透大图上，
  // 先「揭开」（移除 blurred 类）并吞掉本次——不触发放大 lightbox；揭开后再点才正常
  // 放大。根因消解「点击=放大」与 iOS「点击=揭开」的语义冲突，无特例分支堆叠。
  function _fushiResolveBlockImageElement(target) {
    if (!target) return null;
    if ((target.tagName === 'IMG' || target.tagName === 'svg') && target.classList && target.classList.contains('block-img')) {
      return target;
    }
    var wrapper = target.closest ? target.closest('.block-img-wrapper') : null;
    if (!wrapper) return null;
    return wrapper.querySelector('img.block-img') || wrapper.querySelector('svg.block-img');
  }
  function _fushiRevealBlurredImage(target) {
    var el = _fushiResolveBlockImageElement(target);
    if (el && el.classList && el.classList.contains('blurred')) {
      el.classList.remove('blurred');
      // TODO-1289：揭开状态持久——回传稳定 key 给 Dart 会话集，章节重载不再重新遮罩。
      if (window.__fushiImageRevealKey && window.flutter_inappwebview) {
        var key = window.__fushiImageRevealKey(el);
        if (key) window.flutter_inappwebview.callHandler('onImageRevealed', key);
      }
      return true;
    }
    return false;
  }
  function clearImageLongPressTimer() {
    if (imageLongPressTimer) {
      clearTimeout(imageLongPressTimer);
      imageLongPressTimer = null;
    }
  }
  function _imageActionTarget(e) {
    return (e && e.target) || document.elementFromPoint(
      e && typeof e.clientX === 'number' ? e.clientX : startX,
      e && typeof e.clientY === 'number' ? e.clientY : startY
    );
  }
  document.addEventListener('contextmenu', function(e) {
    var target = _imageActionTarget(e);
    var imgUrl = _fushiBlockImageUrl(target);
    if (!imgUrl) return;
    e.preventDefault();
    window.flutter_inappwebview.callHandler(
      'onImageContextMenu',
      imgUrl,
      e.clientX || 0,
      e.clientY || 0
    );
  }, {passive: false});
  // BUG-712 ①：点词门控只读镜像的初始值（chrome 可见性 / highlightOnTap / 选词扫描
  // 上限）。Dart 是唯一写者：本脚本注入时带当前真值，之后 chrome 翻转与设置热更新由
  // _syncTapGateJs 刷新。tap 手势据此在 JS 侧直接 selectText（见 _gestureEnd 的 tap
  // 分支），砍掉 onTap→Dart→evaluateJavascript 的整个来回。
  window.__fushiTapGate = { chrome: C.showChrome, lookup: C.highlightOnTap, maxLen: 400 };
  function _gestureEnd(x, y, e) {
    if (!hasStart) return;
    // TODO-1317: a mobile long-press drag-select owns this gesture (finalized
    // by the drag-select IIFE); suppress tap / swipe / image-tap so there is
    // no double lookup or accidental page turn.
    if (window.__fushiTextSelectDragActive) {
      clearImageLongPressTimer();
      imageLongPressConsumed = false;
      hasStart = false;
      return;
    }
    clearImageLongPressTimer();
    if (imageLongPressConsumed) {
      imageLongPressConsumed = false;
      hasStart = false;
      if (e && e.preventDefault) e.preventDefault();
      return;
    }
    // BUG-iPhone 滑动误查词：必须在 hasStart 清掉前记录松手点，并结合每次
    // touchmove/pointermove 留下的最大轨迹位移。只看最终 dx/dy 会把“已滚动后回到
    // 起点附近”的手势重新判成 tap。
    _gestureTrackMovement(x, y);
    hasStart = false;
    var dx = x - startX;
    var dy = y - startY;
    var elapsed = Date.now() - startTime;
    var absDx = Math.abs(dx);
    var absDy = Math.abs(dy);
    var velocity = absDx / Math.max(1, elapsed) * 1000;
    // BUG-239: 连续模式（fushiContinuousMode）不在此回传 onSwipe——原生滚动沿书写轴
    // 翻屏，到边界由 onBoundarySwipe 跨章；此处的水平 onSwipe 只属分页模式。
    if (!fushiContinuousMode && absDx > absDy && (absDx >= C.swipeDistThreshold || (absDx >= C.swipeFastDistThreshold && velocity >= 900))) {
      if (e && e.preventDefault) e.preventDefault();
      if (dx < 0) {
        window.flutter_inappwebview.callHandler('onSwipe', 'left');
      } else {
        window.flutter_inappwebview.callHandler('onSwipe', 'right');
      }
    } else if (!gestureExceededTapSlop) {
      // BUG-手机翻短了会查词：查词框与翻页距离阈值**解耦**。旧判据把上界取成
      // swipe 距离阈值（72px），于是任何够不到翻页阈值的横滑（如 50px）都落进这里被
      // 当成点词。现在只允许完整触摸轨迹始终停在 $tapSlop px 径向半径内：正常手指
      // 抖动仍是 tap；任何 touchmove/pointermove 曾越界都永久归为 pan，即使松手回到
      // 起点附近也不查词。横向主导、够不到翻页阈值的短滑则落到本 if 之外 → 空操作。
      var tapEl = document.elementFromPoint(x, y);
      if (_fushiRevealBlurredImage(tapEl)) {
        if (e && e.preventDefault) e.preventDefault();
        return;
      }
      var imgUrl = _fushiBlockImageUrl(tapEl);
      if (imgUrl) {
        window.flutter_inappwebview.callHandler('onImageTap', imgUrl);
      } else if (fushiVnMode && fushiVnClickAdvance &&
          _fushiVnTapIsBlank(x, y) &&
          window.fushiReader && window.fushiReader.paginate) {
        // TODO-909 M0: VN blank-tap. Only when the tap is NOT over matchable
        // text (so word lookup still wins on text).
        // BUG-1195: 这里**不再**自己 paginate。旧实现直调
        // `window.fushiReader.paginate('forward')` 把每一次空白点都吃掉，而空白点
        // 同时是触屏唯一能唤出控制栏的手势（onTapEmpty）→ VN 下底栏一自动收起就
        // 永远唤不回来。翻页还是唤栏必须由 Dart 判（chrome 可见性只有 Dart 知道：
        // 悬浮态真值是 _chromeTransientVisible，JS 的 __fushiTapGate.chrome 镜像的
        // 是 _showChrome，悬浮态下恒 true，区分不出「已收起」）。见
        // chrome.part.dart 的 _handleVnBlankTap。
        if (e && e.preventDefault) e.preventDefault();
        window.flutter_inappwebview.callHandler('onVnBlankTap');
      } else {
        // TODO-806 [806-TAP] 框选点击坐标取证探针（默认 off，由 DebugLogService 门控：
        // C.debugLogging 为 false 时整段跳过，不打日志）。打印 onTap
        // 实际回传的点击坐标，口径=WebView CSS 视口像素（e.clientX/clientY），**不是** OS
        // 屏幕坐标——差一个 devicePixelRatio + 页面在屏内的偏移，这条标明口径以正本清源。
        // 走 console.log → onConsoleMessage → debugPrint → DebugLogService 环形缓冲。
        if (C.debugLogging) {
          try {
            console.log('[806-TAP] clientX=' + x + ' clientY=' + y
              + ' shift=' + !!(e && e.shiftKey)
              + ' dpr=' + window.devicePixelRatio
              + ' scrollX=' + window.scrollX + ' scrollY=' + window.scrollY);
          } catch (err) {}
        }
        var shiftTap = !!(e && e.shiftKey);
        var tapGate = window.__fushiTapGate;
        if (tapGate && window.fushiSelection &&
            (shiftTap || (tapGate.chrome && tapGate.lookup))) {
          // BUG-712 ①（查词时延）：门控通过时 JS 直接选词——与旧链 Dart onTap→
          // _selectTextAt→evaluateJavascript(selectText) 跑的是完全同一个 selectText
          // （命中→onTextSelected、空白→onTapEmpty、链接/同字 toggle→静默），只是
          // 砍掉 JS→Dart→JS 一整个跨语言来回（Windows WebView2 单跳 5-15ms）。
          // 门控镜像由 Dart 单写（_syncTapGateJs：chrome 翻转/设置热更新时刷新）；
          // 镜像缺失或 fushiSelection 未就绪时回落旧 onTap 链，行为不变。
          window.fushiSelection.selectText(x, y, tapGate.maxLen || 400, false);
        } else {
          window.flutter_inappwebview.callHandler('onTap', x, y, shiftTap);
        }
      }
    }
  }
  // BUG-117: intercept internal <a> link clicks in JS and route them through
  // Dart's paginated navigation. shouldOverrideUrlLoading does NOT fire for
  // clicks on the flutter_inappwebview_windows fork, so relying on it let link
  // clicks navigate the WebView natively (bypassing pagination → stale chapter
  // → broken page). Capturing the click here + preventDefault works on every
  // platform; a.href is the browser-resolved absolute URL. Selection/tap
  // gestures already skip <a> (selectText bails), so there is no conflict.
  document.addEventListener('click', function(e) {
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    var href = a.getAttribute('href');
    if (!href || href.charAt(0) === ' ') return;
    var lower = href.toLowerCase();
    if (lower.indexOf('javascript:') === 0) return;
    e.preventDefault();
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('onInternalLink', a.href);
    }
  }, true);
  document.addEventListener('touchstart', function(e) {
    var t = e.touches[0];
    imageLongPressConsumed = false;
    clearImageLongPressTimer();
    _gestureStart(t.clientX, t.clientY);
    var imgUrl = _fushiBlockImageUrl(e.target || document.elementFromPoint(t.clientX, t.clientY));
    if (!imgUrl) return;
    imageLongPressStartX = t.clientX;
    imageLongPressStartY = t.clientY;
    imageLongPressTimer = setTimeout(function() {
      imageLongPressTimer = null;
      imageLongPressConsumed = true;
      // TODO-861④：长按仍带 `blurred` 类的防剧透图时，先揭开（移除类）并吞掉本次——
      // 与单击（_gestureEnd）/键盘·手柄激活（reader_caret_scripts.dart）语义一致：
      // 「揭开优先」，揭开后再长按才弹出图片操作菜单。复用同一 _fushiRevealBlurredImage。
      var pressEl = document.elementFromPoint(imageLongPressStartX, imageLongPressStartY);
      if (_fushiRevealBlurredImage(pressEl)) return;
      window.flutter_inappwebview.callHandler('onImageLongPress', imgUrl);
    }, 550);
  }, {passive: true});
  document.addEventListener('touchmove', function(e) {
    if (!e.touches || !e.touches.length) return;
    var t = e.touches[0];
    // WKWebView 的 PointerEvent 序列不可作为唯一真相；直接从 TouchEvent 记录完整
    // 轨迹，确保连续滚动/短促 flick 都会取消 tap 查词候选。
    _gestureTrackMovement(t.clientX, t.clientY);
    if (!imageLongPressTimer) return;
    var dx = t.clientX - imageLongPressStartX;
    var dy = t.clientY - imageLongPressStartY;
    if ((dx * dx + dy * dy) > 144) clearImageLongPressTimer();
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    if (_fushiReaderMouseDragIgnoreTouchEnd) {
      _fushiReaderMouseDragIgnoreTouchEnd = false;
      if (e && e.preventDefault) e.preventDefault();
      return;
    }
    var t = e.changedTouches[0]; _gestureEnd(t.clientX, t.clientY, e);
  }, {passive: false});
  document.addEventListener('touchcancel', function(e) {
    clearImageLongPressTimer();
    imageLongPressConsumed = false;
    _fushiReaderMouseDragIgnoreTouchEnd = false;
    hasStart = false;
  }, {passive: true});
  document.addEventListener('pointerdown', function(e) {
    if (!_fushiReaderPointerEngages(e)) return;
    _fushiReaderMouseDragActive = _fushiReaderMouseDragStartAllowed(e);
    _fushiReaderMouseDragClaimed = false;
    _fushiReaderMouseNativeTextStart = !_fushiReaderMouseDragActive;
    _fushiReaderMouseDragLastX = e.clientX;
    _fushiReaderMouseDragLastY = e.clientY;
    _fushiReaderMouseDragPointerId = e.pointerId;
    _fushiReaderMouseDragPageDirection = null;
    _fushiReaderMouseDragSwipeSent = false;
    _gestureStart(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointermove', function(e) {
    _gestureTrackMovement(e.clientX, e.clientY);
    // TODO-553: pointermove 的 button 恒 -1，不能用 _fushiReaderPointerEngages
    // （它查 button===0）；分页模式触摸只需在此直接放行回 touch swipe 路径。
    if (e.pointerType === 'touch' && !fushiContinuousMode) return;
    if (_fushiReaderMouseDragPointerId !== null && e.pointerId !== _fushiReaderMouseDragPointerId) return;
    if (!_fushiReaderPointerStillDown(e) || !hasStart) return;
    var totalDx = e.clientX - startX;
    var totalDy = e.clientY - startY;
    var totalDistSq = totalDx * totalDx + totalDy * totalDy;
    if (_fushiReaderMouseNativeTextStart) {
      // BUG-368: 分页模式下，鼠标在正文上横向拖动应像手机端的「触摸横滑」一样翻页。
      // 旧实现里鼠标拖动起点落在正文（caret range 命中）时一律当作原生选词起点
      // （_fushiReaderMouseNativeTextStart），移动 >6px 就放弃手势交还原生选区，
      // 永不回传 onSwipe → 桌面鼠标在分页模式根本「翻不了页」（只有空白边距能拖、
      // 或全靠滚轮）。触摸路径（touchend→_gestureEnd）早已能在正文上横滑翻页，鼠标
      // 却被这道闸门挡住，造成「鼠标 ≠ 手机」的不对称。这里在仍是分页模式时，先判
      // 定这次拖动是否已构成一次明确的横向翻页手势（横向位移占优且达滑动阈值，与
      // _fushiReaderMouseDragResolvePageDirection / _gestureEnd 同款判据）：是→把
      // 本次手势从「原生选词」转换为「拖动翻页」（清掉已起的选区、接管 pointer、
      // 后续走 _finishFushiReaderMouseDrag 回传 onSwipe）；否→保持原行为（竖向/短拖
      // 交还原生选区，仍可正常划词查词）。
      var ntDir = (!fushiContinuousMode)
          ? _fushiReaderMouseDragResolvePageDirection(e.clientX, e.clientY)
          : null;
      if (ntDir) {
        _fushiReaderMouseNativeTextStart = false;
        _fushiReaderMouseDragActive = true;
        _fushiReaderMouseDragClaimed = true;
        _fushiReaderMouseDragPageDirection = ntDir;
        _fushiReaderPointerNoSelect(true);
        _fushiReaderClearMouseSelection();
        if (e.target && e.target.setPointerCapture) {
          try { e.target.setPointerCapture(e.pointerId); } catch (err) {}
        }
        e.preventDefault();
        return;
      }
      if (totalDistSq > 36) hasStart = false;
      return;
    }
    if (!_fushiReaderMouseDragActive) return;
    if (!_fushiReaderMouseDragClaimed) {
      if (totalDistSq < 36) return;
      _fushiReaderMouseDragClaimed = true;
      if (e.pointerType === 'touch') _fushiReaderMouseDragIgnoreTouchEnd = true;
      _fushiReaderPointerNoSelect(true);
      _fushiReaderClearMouseSelection();
      if (e.target && e.target.setPointerCapture) {
        try { e.target.setPointerCapture(e.pointerId); } catch (err) {}
      }
    }
    var dx = e.clientX - _fushiReaderMouseDragLastX;
    var dy = e.clientY - _fushiReaderMouseDragLastY;
    _fushiReaderMouseDragLastX = e.clientX;
    _fushiReaderMouseDragLastY = e.clientY;
    if (fushiContinuousMode) {
      _fushiReaderMouseDragScrollBy(dx, dy);
    } else {
      _fushiReaderMouseDragPageDirection =
          _fushiReaderMouseDragResolvePageDirection(e.clientX, e.clientY);
    }
    e.preventDefault();
  }, {passive: false});
  document.addEventListener('pointerup', function(e) {
    if (!_fushiReaderPointerEngages(e)) return;
    if (_fushiReaderMouseDragPointerId !== null && e.pointerId !== _fushiReaderMouseDragPointerId) return;
    if (_fushiReaderMouseDragClaimed) {
      if (!fushiContinuousMode && !_fushiReaderMouseDragPageDirection) {
        _fushiReaderMouseDragPageDirection =
            _fushiReaderMouseDragResolvePageDirection(e.clientX, e.clientY);
      }
      _finishFushiReaderMouseDrag(e);
      return;
    }
    if (_fushiReaderMouseNativeTextStart) {
      var nativeDx = e.clientX - startX;
      var nativeDy = e.clientY - startY;
      var nativeMoved = (nativeDx * nativeDx + nativeDy * nativeDy) > 36;
      _fushiReaderMouseNativeTextStart = false;
      _fushiReaderMouseDragActive = false;
      _fushiReaderMouseDragPointerId = null;
      _fushiReaderMouseDragPageDirection = null;
      _fushiReaderPointerNoSelect(false);
      // 只有「本次手势里指针真的移动过」(nativeMoved) 才当作用户在拖动划原生选区，
      // 保留选区供复制 / 桌面 Ctrl+C，不再当作查词 tap。
      // 旧代码还把「残留原生选区未折叠」也塞进这条早退：只要上一轮的选区还在，纯 tap
      //（未移动）也会在此提前 return，跳过 _gestureEnd -> selectText -> clearSelection
      // 整条链——于是残留选区会让之后每一次点击都被吞（查词永远打不开）。桌面细指针鼠标
      // 拖选/右键复制刻意保留原生选区，最容易触发这个死循环。纯 tap 时改为落到下方
      // _gestureEnd：selectText 会先 clearSelection(removeAllRanges) 再查词，既清掉残留
      // 选区又能正常弹词典。BUG-927。
      if (nativeMoved) {
        hasStart = false;
        return;
      }
    } else {
      _fushiReaderMouseDragActive = false;
      _fushiReaderMouseDragPointerId = null;
      _fushiReaderMouseDragPageDirection = null;
      _fushiReaderPointerNoSelect(false);
    }
    _gestureEnd(e.clientX, e.clientY, e);
  }, {passive: false});
  document.addEventListener('pointercancel', function(e) {
    if (e.pointerType === 'touch' && !fushiContinuousMode) return;
    if (_fushiReaderMouseDragPointerId !== null && e.pointerId !== _fushiReaderMouseDragPointerId) return;
    _fushiReaderMouseDragActive = false;
    _fushiReaderMouseDragClaimed = false;
    _fushiReaderMouseNativeTextStart = false;
    _fushiReaderMouseDragPointerId = null;
    _fushiReaderMouseDragPageDirection = null;
    _fushiReaderPointerNoSelect(false);
    hasStart = false;
  }, {passive: true});
  // 非左键（中键/侧键）：上报 Dart，由 resolveMouse 判定是否绑定「seek 到点击句」。
  // mousedown 一定触发，preventDefault 压掉中键自动滚动。触屏合成事件 button 恒 0，
  // 被首行排除，不干扰触摸手势。
  document.addEventListener('mousedown', function(e) {
    if (e.button === 0) return;
    if (e.button === 2 && _fushiBlockImageUrl(e.target || document.elementFromPoint(e.clientX, e.clientY))) {
      return;
    }
    e.preventDefault();
    window.flutter_inappwebview.callHandler('onPointerSeek', e.button, e.clientX, e.clientY);
  }, {passive: false});
  document.addEventListener('selectstart', function(e) {
    if (hasStart && !_fushiReaderMouseNativeTextStart && (Date.now() - startTime) < 400) e.preventDefault();
  });
  // TODO-1028: 砍掉双击建立的原生框选——它会盖住单击查词、并绊住振假名 dblclick
  // 切换（_buildFuriganaJs 'toggle' 分支带 `!sel.isCollapsed` 守卫）。原生双击选词在
  // mousedown/selectstart 阶段已发生，dblclick 只是结果，preventDefault 拦不住，故改
  // removeAllRanges 清掉既成选区。用 capture 让它先于振假名 handler（bubble 阶段）跑，
  // 从而振假名切换反而恢复正常（守卫不再被双击选区绊住）。单击查词走 onTap/_selectTextAt
  // 自管 CSS Highlight，不产生原生选区，零影响。
  document.addEventListener('dblclick', function() {
    var sel = window.getSelection && window.getSelection();
    if (sel && !sel.isCollapsed) sel.removeAllRanges();
  }, true);
$kPagedWheelGestureHelperJs
  // BUG-2015：连续模式的章节边界必须按「手势」而不是 wheel tick 判定。记录正文
  // document 内上一拍时间：从章中滚到末尾的同一段触摸板惯性只能把尾部留白滚完，
  // 只有静默后、起点已经在边界的新手势才表达跨章意图。真正跨 document 的残余惯性
  // 仍由 Dart 的 chapter-turn cooldown 承接。
  var _continuousWheelLastTickAt = 0;
  // TODO-656: 横排连续模式放行原生滚动时，记上一拍 scrollTop，下一拍无变化（原生卡
  // 在边界滚不动）才算到边界——替代瞬时 scrollTop<=2 几何。-1 = 尚无基线（首拍不卡）。
  var _wheelLastScrollPos = -1;
  // TODO-629 ②: 竖排连续滚动 rAF 缓动状态——wheel 事件只累积目标 scrollLeft，由
  // requestAnimationFrame 每帧指数逼近，消除逐事件 scrollBy 的离散颗粒感。
  var _vScrollTarget = null;   // 累积目标 scrollLeft（null = 无进行中的缓动）
  var _vScrollRaf = 0;         // 进行中的 rAF 句柄（0 = 无）
  function _vScrollEaseStep() {
    var root = document.scrollingElement || document.documentElement;
    if (_vScrollTarget === null) { _vScrollRaf = 0; return; }
    var current = root.scrollLeft;
    var remaining = _vScrollTarget - current;
    // 与纯函数 ReaderPaginationScripts.smoothScrollStep 同款常量（factor/snap）。
    if (Math.abs(remaining) <= 0.5) {
      root.scrollLeft = _vScrollTarget;
      _vScrollTarget = null;
      _vScrollRaf = 0;
      return;
    }
    root.scrollLeft = current + remaining * 0.18;
    _vScrollRaf = requestAnimationFrame(_vScrollEaseStep);
  }
  document.addEventListener('wheel', function(e) {
    // BUG-239 / TODO-345 同源门控：连续模式靠浏览器原生滚动（滚动轴 = 书写轴）。
    // 此处一旦在连续模式回传 onSwipe（90% 整屏跳页），就与原生滚动产生轴向冲突。
    var r = window.fushiReader;
    if (fushiContinuousMode) {
      // TODO-345: 横排连续滚动轴 = 纵向（与桌面鼠标滚轮的 deltaY 默认轴一致），
      // 放行原生滚动即可顺滑滚动。竖排连续滚动轴 = 横向（CSS overflow-x 可滚、
      // overflow-y:hidden），但桌面鼠标滚轮只产生 deltaY、不产生 deltaX，浏览器
      // 不会把垂直滚轮可靠地映射到横向可滚轴 → 竖排连续模式滚轮滚不动。故竖排
      // 显式把滚轮的主 delta 投影到横向 scrollBy（沿真实书写轴），方向与
      // fushiReader.paginate 一致（vertical-rl forward 往左 = scrollLeft 减小）。
      // TODO-627: 连续模式滚轮原本只放行/投影原生滚动，到章末/章首滚不出去（边界
      // 跨章原本只有触摸/指针的边界 IIFE 走 onBoundarySwipe，滚轮无此通道）。这里
      // 补滚轮的跨章通道：仅当原生滚动已到该内容轴尽头才回传 onBoundarySwipe，复用
      // 边界 IIFE 同款 atStart/atEnd 判定与 _handlePageTurnLimit；未到底仍放行/投影
      // 正常滚动，不打断滚动手感。统一手势纯谓词 continuousWheelBoundaryDirection。
      var root = document.scrollingElement || document.documentElement;
      var vertical = r && r.isVertical && r.isVertical();
      var wheelTickAt = Date.now();
      var wheelQuietMs = Math.max(150, C.wheelGestureQuietMs || 450);
      var startsNewWheelGesture = _continuousWheelLastTickAt === 0
        || wheelTickAt - _continuousWheelLastTickAt >= wheelQuietMs;
      _continuousWheelLastTickAt = wheelTickAt;
      // delta>0 一律归一化为「沿书写轴前进」：横排向下(deltaY>0)、竖排投影向前都为
      // forward（见纯函数注释）。
      var wheelDelta = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
      // TODO-656 真试滚：不再推算「到没到边界」，而是真的朝书写轴 scrollBy 一步、读实际
      // 位移——滚动了就是没到边界（不跨章），真的滚不动了才跨章。横排 scrollBy 纵向
      // (scrollTop)，竖排把 deltaY 投影到横向 scrollLeft（浏览器不会把垂直滚轮自动映射到
      // 横向可滚轴）。同步、权威，不靠 scrollTop<=2 / scrollWidth 几何推算（那套在快速滚 /
      // 图片未撑开 / 竖排负 scrollLeft 下误判 → 横排中部误翻、竖排滚不动）。
      if (wheelDelta === 0) return;
      e.preventDefault();
      var wheelDir = wheelDelta > 0 ? 'forward' : 'backward';
      var pointerKind = _isTrackpadWheel(e) ? 'trackpad' : 'wheel';
      var sign = vertical
        ? ((window.getComputedStyle(document.body).writingMode === 'vertical-rl') ? -1 : 1)
        : 1;
      // 用与键盘翻页 paginate 同款的已验证原语：window.scrollBy 滚动 + 沿书写轴测量实际
      // 位移（横排 root.scrollTop、竖排 window.scrollX）。此前用 root.scrollBy / root.scrollLeft
      // 在本 WebView 不生效/读不到 → moved 恒 false → 滚轮不滚动、直接翻章。
      var before = vertical ? window.scrollX : root.scrollTop;
      if (vertical) { window.scrollBy({left: wheelDelta * sign, top: 0, behavior: 'auto'}); }
      else { window.scrollBy({left: 0, top: wheelDelta, behavior: 'auto'}); }
      var after = vertical ? window.scrollX : root.scrollTop;
      var moved = Math.abs(after - before) > 1;
      // 诊断：仅在「滚不动」时打印，供真机定位为何不动（同时打 window.scrollX 与
      // root.scrollLeft，看哪个真的跟随滚动）。
      if (!moved) {
        console.log('[xchapter] wheel vertical=' + (vertical ? 1 : 0)
          + ' wheelDelta=' + Math.round(wheelDelta) + ' wheelDir=' + wheelDir
          + ' before=' + Math.round(before) + ' after=' + Math.round(after)
          + ' moved=' + (moved ? 1 : 0) + ' kind=' + pointerKind
          + ' newGesture=' + (startsNewWheelGesture ? 1 : 0)
          + ' winX=' + Math.round(window.scrollX) + ' winY=' + Math.round(window.scrollY)
          + ' rootL=' + Math.round(root.scrollLeft) + ' rootT=' + Math.round(root.scrollTop)
          + ' scrollW=' + root.scrollWidth + ' innerW=' + window.innerWidth);
      }
      if (moved) {
        // 真的滚动了 = 没到边界，不跨章。
        return;
      }
      // 触摸板：本手势若从章内一路滚到边界，余下的惯性 tick 全部停在这里；用户
      // 必须松手、静默后再滑一次才跨章。离散滚轮/数位板旋钮：一格通常只有一个
      // WheelEvent，不能再要求 arm-then-fire 的第二拍，否则设备会表现为完全无响应。
      if (pointerKind === 'trackpad' && !startsNewWheelGesture) return;
      window.flutter_inappwebview.callHandler(
        'onBoundarySwipe', wheelDir, pointerKind);
      return;
    }
    if (!r || !('paginationMetrics' in r)) return;
    // TODO-737: 分页滚轮方向脱钩 invertSwipeDirection——改回传新 handler onWheelPaginate
    // 产「语义意图」(forward/backward)，方向 deltaY>0=forward 对齐连续滚轮(沿书写轴
    // delta>0=前进)，不再经 onSwipe 被 invertSwipeDirection(默认 true) 连坐反向。
    // 节流统一到 Dart 侧 _paginate 入口时间戳闸门（throttleMs: wheelPageTurnInterval），
    // JS 不再自持固定窗口 _wheelTimer；横向触控板 burst 由跨文档 Dart State 聚合，
    // 纵向鼠标滚轮仍走 _paginate 固定窗口。invertSwipeDirection 只管触摸/鼠标拖动。
    _handlePagedWheelTick(e);
  }, {passive: false});
  var _shiftHoverLastX = -1, _shiftHoverLastY = -1;
  document.addEventListener('mousemove', function(e) {
    // TODO-756b：开了 window.__hoverAutoLookup 则纯悬停即查词（不要求 Shift）；
    // 否则退回 756a 的 Shift 门控。未触发分支仍复位节流锚，使下次进入即触发。
    if (!e.shiftKey && !window.__hoverAutoLookup) { _shiftHoverLastX = -1; _shiftHoverLastY = -1; return; }
    var dx = e.clientX - _shiftHoverLastX, dy = e.clientY - _shiftHoverLastY;
    if (dx * dx + dy * dy < 64) return;
    _shiftHoverLastX = e.clientX; _shiftHoverLastY = e.clientY;
    window.flutter_inappwebview.callHandler('onShiftHover', e.clientX, e.clientY);
  }, {passive: true});
  // TODO-1078：桌面 Windows 阅读器裸 Space 被 WebView2 吞成 Chromium 默认
  // scrollByPage（向下翻屏），而不是走 Flutter 的 Space 覆写（有声书激活→
  // 播放/暂停、否则→翻页）。桥接细节（为何需要、放行哪些情况）见
  // [webViewKeyBridgeScript]；回传的 onSpaceKey 在 Dart 侧经
  // resolveReaderSpaceOverride 统一解析，与 Flutter 焦点路径同款语义。
${webViewKeyBridgeScript(handlerName: 'onSpaceKey', keys: const <String>[' '])}
  window.fushiProgressDetails = function() {
    var r = window.fushiReader;
    if (!r) return '';
    var p = r.calculateProgress();
    var m = r.paginationMetrics;
    var total = (m && m.totalChars) ? m.totalChars : 0;
    if (total <= 0 && r.createWalker) {
      var walker = r.createWalker();
      var node;
      total = 0;
      while (node = walker.nextNode()) total += r.countChars(node.textContent);
    }
    // 纯图片章没有可匹配字符，但可能仍有多张分页图片。只有真实到达该章物理末端时
    // 才返回一个合成的 1/1 完成快照；中间图片页继续返空，由现有图片进度 UI 兜底，
    // 避免一进纯图片末章就提前标完。
    if (total <= 0) {
      var mediaAtEnd = typeof r.isAtEnd === 'function' && r.isAtEnd();
      return mediaAtEnd ? '1,1,-1' : '';
    }
    // BUG-162: 第三段 = section 内精确绝对字符偏移（视口首字符），落 DB char_offset
    // 作退出再进的恢复锚（成熟 getFirstVisibleCharOffset/scrollToCharOffset 路径）。
    // caretRangeFromPoint 失败时返 -1 → Dart 当「无精确偏移」回退分数。
    var off = (typeof r.getFirstVisibleCharOffset === 'function')
        ? r.getFirstVisibleCharOffset() : -1;
    // BUG-1241：阅读进度分数描述的是「视口首字符」，不是「是否到达末页」。
    // 到达分页末页 / 连续物理末端 / VN 末屏时把持久分子钳到 total，使自动完成和
    // 阅读统计都得到明确终态；中间页仍保留原字符级进度。
    var atEnd = typeof r.isAtEnd === 'function' && r.isAtEnd();
    // 第四段 = 当前可见字符区间的终点 end（半开 [start, end)，与第三段同口径），供
    // 统计「翻走即计 + 覆盖并集」逐次采样记区间；atEnd 时钳到 total。三种 shell 都实现
    // getLastVisibleCharOffset（分页版接受已算好的 start 免二次 caret）；没有该函数的
    // reader（旧 shell / 测试桩）不追加第四段，Dart 解析按缺省 -1 处理。
    var hasEnd = typeof r.getLastVisibleCharOffset === 'function';
    var end = atEnd ? total : (hasEnd ? r.getLastVisibleCharOffset(off) : -1);
    return (atEnd ? total : Math.round(p * total)) + ',' + total + ',' + off
        + (hasEnd ? ',' + end : '');
  };
  // BUG-213: 章内原生滚动（连续模式 window 滚动 / 分页模式触摸/trackpad/键盘箭头
  // 落 body 的原生滚动）没有进度回传通道，进度条要等 10s 轮询或翻章才更新。这里给
  // 两模式共享的 setup 脚本挂一条统一 scroll → Dart 通道：capture 阶段监听让 window
  // 与 body 内部滚动都进来；程序化重锚期（_reanchorPending）跳过，避免恢复/重排瞬态
  // 误触发（恢复期的 _restoreInFlight / 歌词模式由 Dart 侧 onReaderScroll 再门控一道）。
  //
  // BUG-380: 原实现是「纯尾沿去抖」——每个 scroll 事件都 clearTimeout 把 200ms 定时器
  // 推后，滑动期间永不上报，只在滑动停下 200ms 后才回传一次，进度条/百分比要等滑动
  // settle 才跳一下，不跟手。改成「rAF 节流 + 尾沿补一发」：滑动中每个动画帧最多回传
  // 一次（约 16ms/次，跟随刷新率，肉眼连续），滑停后短尾沿再补发一次最终位置，确保
  // 落点精确。Dart 侧 _refreshProgress 自带 in-flight 守卫（一次 evaluateJavascript
  // 未返回不再发起下一次），避免高频上报把较重的 fushiProgressDetails 调用堆积。
  (function() {
    var _progressScrollRaf = 0;
    var _progressScrollTimer = null;
    // TODO-718（回退式根治·2026-06-25）：原 userDriven 时间戳打点整套已删——它喂的是 798
    // 启发式拦截器（已删），且真机恒真致拦截器失效、与原始 _reanchorPending 机制打架。
    // 抗自发 reflow 归零回到干净的源头屏蔽：reflow 归零的 scroll 在重锚期被 `_reanchorPending`
    // 旗在此 return 挡掉、永不回传落库（见下方）。无需再区分「是否用户驱动」。
    function _reportReaderScroll() {
      var r = window.fushiReader;
      // TODO-151/164 / BUG-225 诊断：默认 off（C.debugLogging 由 DebugLogService
      // 下发），开了才打印。reanchorPending=true 会早返回不回传，
      // hasBridge=false 说明 callHandler 不可用——便于真机定位「滚动了但进度没动」哪一链断。
      // console.log 经 onConsoleMessage → debugPrint → DebugLogService 环形缓冲。
      if (C.debugLogging) {
        console.log('[ReaderDiag] scroll report'
          + ' reanchorPending=' + (r ? r._reanchorPending === true : 'noReader')
          + ' hasBridge=' + !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler));
      }
      if (r && r._reanchorPending === true) return;
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('onReaderScroll');
      }
    }
    function _onReaderScrollEvent() {
      // rAF 节流：滑动中每个动画帧最多回传一次（合并同帧内多次 scroll 事件），
      // 让进度边滑边实时跟随而不是每个事件都打桥（BUG-380）。
      if (!_progressScrollRaf) {
        _progressScrollRaf = requestAnimationFrame(function() {
          _progressScrollRaf = 0;
          _reportReaderScroll();
        });
      }
      // 尾沿补一发：滑停 120ms 后再回传一次最终位置，确保 rAF 节流可能漏掉的「最后
      // 一帧之后的停止位置」被精确落点（rAF 节流自身不保证捕捉到最终静止帧）。
      if (_progressScrollTimer) clearTimeout(_progressScrollTimer);
      _progressScrollTimer = setTimeout(function() {
        _progressScrollTimer = null;
        _reportReaderScroll();
      }, 120);
    }
    window.addEventListener('scroll', _onReaderScrollEvent, { passive: true, capture: true });
    document.addEventListener('scroll', _onReaderScrollEvent, { passive: true, capture: true });
  })();
  $longPressDragJs
  var cloak = document.getElementById('fushi-cloak');
  if (cloak) cloak.remove();
}
};
''';
  }

  /// 引擎源码只依赖 view-mode 与编译期常量，一个进程里逐字不变——每种模式建一次就够。
  /// 拼装 + 压缩要扫近万行（实测 9ms），绝不能每次跨章重跑。
  static final Map<String, String> _cachedEngineSource = <String, String>{};

  /// 注入用的引擎源码（按 view-mode memoized）。
  ///
  /// 注入前剥掉整行注释与空行（见 [ReaderScriptCompactor]）——传的是同一份语义的
  /// 脚本，只是不再把给人看的中文注释也编组、传输、解析一遍。
  static String readerEngineSource({
    required bool vnMode,
    required bool continuousMode,
  }) {
    final String key =
        vnMode ? 'vn' : (continuousMode ? 'continuous' : 'paged');
    return _cachedEngineSource.putIfAbsent(
      key,
      () => ReaderScriptCompactor.compact(
        _buildReaderEngineSource(
          vnMode: vnMode,
          continuousMode: continuousMode,
        ),
      ),
    );
  }

  /// 每次导航下发的那一小份：config + 一次 install 调用。
  ///
  /// 与引擎源码拼在**同一次** `evaluateJavascript` 里发出去（往返次数不变）；
  /// 分开写只是为了让引擎那半边可以 memoize。
  static String readerEngineBoot(ReaderEngineConfig config) =>
      'window.__fushiReaderConfig = ${config.toJsLiteral()};'
      'window.__fushiEngine.install(window.__fushiReaderConfig);';

  static String _stripScriptTags(String js) {
    return js
        .replaceFirst(RegExp(r'^<script[^>]*>\n?'), '')
        .replaceFirst(RegExp(r'\n?</script>$'), '');
  }

  // ── WebView ──────────────────────────────────────────────────────────

  Widget _buildWebView() {
    if (Platform.isLinux) {
      // flutter_inappwebview has no Linux backend; the EPUB renderer is
      // unsupported on Linux for now (see
      // docs/specs/2026-05-30-five-platform-build.md).
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.reader_unsupported_platform,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // KeyedSubtree carries [_webViewKey] (a GlobalKey) on the InAppWebView's own
    // render subtree so [onDismissBarrierHover] can read the WebView's RenderBox
    // for global→local coordinate mapping (TODO-806), while the ValueKey stays on
    // the InAppWebView itself for the integration-test finders (fushi_webview).
    final Widget webView = InAppWebView(
      key: const ValueKey<String>('fushi_webview'),
      // TODO-954：Windows 的文字选区右键改用 Flutter 菜单（`_showReaderTextContextMenu`，
      // 经 GestureDetector.onSecondaryTapDown 触发），它在 FushiAppUiScale 内能跟随界面
      // 大小缩放；故 Windows 下禁掉平台原生 WebView2 菜单（它不在 Flutter 树里、永远不
      // 缩放）。移动端无 onSecondaryTapDown，仍走原生 ContextMenu。
      // BUG-544：移动端此前不隐藏系统默认项（该标志曾设为 false），保留系统默认项
      // （复制/全选/粘贴），Android ActionMode 契约把自定义 menuItems 追加在系统项之后，
      // 「导出片段」永远垫底、淹没在系统项后。改为隐藏系统默认项、只留自定义项，顺序
      // [查词][导出片段][复制]，把导出提到第二位；因隐藏系统项会一并去掉系统「复制」，
      // 补一条自定义复制项（复用桌面右键菜单 `t.copy` / `t.copied_to_clipboard`，不丢功能）。
      contextMenu: isWindowsPlatform
          ? ContextMenu(
              settings: ContextMenuSettings(
                hideDefaultSystemContextMenuItems: true,
              ),
              menuItems: const [],
            )
          : ContextMenu(
              settings: ContextMenuSettings(
                hideDefaultSystemContextMenuItems: true,
              ),
              menuItems: [
                ContextMenuItem(
                  id: 1,
                  title: t.search,
                  action: () async {
                    final text = await _controller?.getSelectedText();
                    if (text == null || text.isEmpty) return;
                    if (!mounted) return;
                    final size = MediaQuery.of(context).size;
                    final rect = Rect.fromCenter(
                      center: Offset(size.width / 2, size.height / 3),
                      width: 1,
                      height: 1,
                    );
                    _webviewPrunePopupStack(0);
                    // BUG-455：原生菜单查词不经 tap（_handleTextSelected），必须显式把
                    // 原生选区写进查词状态，否则弹窗顶栏「收藏句子」读 currentSentence 为空
                    // → 误报「未选择句子」。句级解析失败也要满足非空契约：退回选中文本。
                    final ReaderSelectionData? sel =
                        await _fillLookupStateFromNativeSelection();
                    if (!mounted) return;
                    if (sel == null) {
                      appModel.currentMediaSource?.setCurrentSentence(
                        selection: FushiTextSelection(text: text),
                      );
                    }
                    // BUG-1344：先保留原生选区完成句子/夹图采集，再在打开弹窗前清除。
                    // WKWebView 否则会把失焦选区绘成灰块并残留到应用切换。
                    await _clearReaderAppSelection();
                    if (!mounted) return;
                    await searchDictionaryResult(
                      searchTerm: text,
                      selectionRect: rect,
                    );
                    if (mounted) _checkFavoriteStatus();
                  },
                ),
                // TODO-954：移动端选区右键也提供「导出片段」，与 Windows 一致都从选区
                // 触发；handler 内部判 hasCue/音频，无音频时走 noAudio 兜底 toast。
                // BUG-544：提到第二位（复制之前），不再垫底。
                ContextMenuItem(
                  id: 2,
                  title: t.audiobook_export_clip,
                  action: () async {
                    await _exportAudiobookClipFromSelection();
                  },
                ),
                // BUG-544：补自定义「复制」补偿被隐藏的系统复制项，逻辑与桌面右键菜单
                // 的 'copy' 分支同源（Clipboard.setData + copied_to_clipboard toast）。
                ContextMenuItem(
                  id: 3,
                  title: t.copy,
                  action: () async {
                    final text = await _controller?.getSelectedText();
                    if (text == null || text.isEmpty) return;
                    await Clipboard.setData(ClipboardData(text: text));
                    FushiToast.show(
                        msg: t.copied_to_clipboard,
                        severity: ToastSeverity.success);
                    // 复制后清掉 ActionMode 残留的原生选区，和桌面右键 'copy' 对齐，
                    // 避免残留选区卡住后续查词。BUG-927。
                    await _clearReaderAppSelection();
                  },
                ),
                if (isAndroidPlatform)
                  ContextMenuItem(
                    id: 4,
                    title: t.share,
                    action: () async {
                      final String? text = await _controller?.getSelectedText();
                      if (text == null || text.isEmpty) return;
                      final bool shared = await SelectionExternalActions
                          .instance
                          .shareText(text);
                      if (mounted && !shared) {
                        FushiToast.show(
                            msg: t.selection_share_failed,
                            severity: ToastSeverity.error);
                      }
                      await _clearReaderAppSelection();
                    },
                  ),
                if (isAndroidPlatform)
                  ContextMenuItem(
                    id: 5,
                    title: t.selection_web_search,
                    action: () async {
                      final String? text = await _controller?.getSelectedText();
                      if (text == null || text.isEmpty) return;
                      final bool opened = await SelectionExternalActions
                          .instance
                          .searchWeb(text);
                      if (mounted && !opened) {
                        FushiToast.show(
                            msg: t.selection_web_search_unavailable,
                            severity: ToastSeverity.error);
                      }
                      await _clearReaderAppSelection();
                    },
                  ),
              ],
            ),
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source:
              'window.onerror=function(m,s,l,c,e){console.error("__FUSHI_JS_ERROR__ "+m+" at "+s+":"+l+":"+c);return false;};',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        // BUG-468：Windows 上右键会同时弹两个菜单——Hibiki 自定义的 Flutter 菜单
        // （`_showReaderTextContextMenu`，经 onSecondaryTapDown）和 WebView2 原生菜单
        // （复制/打印/更多工具）。上面 `contextMenu` 的 `hideDefaultSystemContextMenuItems`
        // 是跨平台 ContextMenu API，在 WebView2 fork 上并不接到原生菜单开关；fork 里唯一
        // 压制原生菜单的真值是 `disableContextMenu`→`put_AreDefaultContextMenusEnabled`
        // （见 packages/flutter_inappwebview_windows/.../in_app_webview.cpp:231）。
        // 故 Windows 下显式禁掉原生菜单，只留 Flutter 菜单。移动端不设（值 false），原生
        // ContextMenu（查词+导出）仍可用，不回归。
        disableContextMenu: isWindowsPlatform,
        mediaPlaybackRequiresUserGesture: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        verticalScrollbarThumbColor: Colors.transparent,
        verticalScrollbarTrackColor: Colors.transparent,
        horizontalScrollbarThumbColor: Colors.transparent,
        horizontalScrollbarTrackColor: Colors.transparent,
        scrollbarFadingEnabled: false,
        databaseEnabled: false,
        domStorageEnabled: false,
        resourceCustomSchemes: _usesReaderResourceCustomScheme
            ? <String>[ReaderFushiSource.kResourceScheme]
            : const <String>[],
        useShouldInterceptRequest: !_usesReaderResourceCustomScheme,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        _openTrace.mark('webViewCreated');
        assert(() {
          // TODO-2603：调试钩子的生命周期属于**本页 State**，不属于单个 WebView
          // 实例。旧判据是「钩子必须为 null」——它把「同一页重装钩子」和「两个阅读器
          // 同时活着」混成一件事。renderer 死后换 key 重建时 State 不重建、
          // `onWebViewCreated` 会第二次触发，那一刻钩子还挂着上一代 controller，旧
          // 断言必炸（这是阅读器不敢走重建路径的硬阻塞之一）。
          //
          // 判据改成**所有者身份**：没有主人（首次安装 / 上一页已 dispose 释放），或
          // 主人就是本 State（重建重装），都合法；主人是**另一个** State 才是真的两个
          // 阅读器同时活着——检测力度与旧断言等价，只是不再误伤重装。
          assert(
            ReaderFushiPage.debugHookOwner == null ||
                identical(ReaderFushiPage.debugHookOwner, this),
            'reader debug hooks are owned by another live reader — a previous '
            'reader did not clear them on dispose, or two readers are live at '
            'once.',
          );
          ReaderFushiPage.debugHookOwner = this;
          ReaderFushiPage.debugEvaluateJavascript =
              (String source) => controller.evaluateJavascript(source: source);
          ReaderFushiPage.debugCaptureWebView =
              () => controller.takeScreenshot();
          ReaderFushiPage.debugCaretSurface = () => _caretSurface.name;
          ReaderFushiPage.debugEvaluateTopPopup =
              (String source) async => _webviewTopPopupState?.debugEval(source);
          ReaderFushiPage.debugInjectAudiobookBridge = () =>
              AudiobookBridge.inject(controller,
                  primaryColor: _themeSentenceAudioHighlightColor());
          return true;
        }());
        _startContentReadyTimeout();
        if (_lyricsMode && _audiobookController != null) {
          final List<AudioCue> allCues =
              _audiobookController!.allBookCuesSnapshot;
          if (allCues.isNotEmpty) {
            _audiobookController!.setChapterCues(allCues);
          }
          _lyricsEntryChapter = _currentChapter;
          // BUG-872：位置优先索引，避免暂停态重建时 _currentCue 未填充导致
          // 入场高亮 clamp 回第一句。
          _lyricsEntryCueIndex = allCues.isNotEmpty
              ? _audiobookController!.allBookCueIdxAtPosition
              : _audiobookController!.currentCueIdx;
          _loadLyricsPage();
        } else {
          _restoreInFlight = true;
          // TODO-1128：开书恢复落到被吸收单图片章（如封面 ch0 被吸收进 ch1，或旧存档
          // 停在某图片章后再开启合并）时，重定向到宿主文本章——只加载宿主（图片内联在
          // 顶部）那一份，绝不加载独立单图页（否则往后翻同图又在宿主顶部出现=重复）。
          final int hostChapter = _resolveNavChapter(_currentChapter);
          if (hostChapter != _currentChapter) {
            _currentChapter = hostChapter;
            _lastProgressSection = _currentChapter;
            // 重定向换了章，旧章的恢复锚必须一起归零——否则 _loadChapterDirectly
            // 会拿这三个字段给**宿主章**建恢复脚本（见下方 initialProgress /
            // initialCharOffset / initialCharOffsetEnd 三个参数）。真实存档里这不是
            // 假想值：合并关闭时往回翻到独立插图章会走 _handlePageTurnLimit 的
            // progress:0.99，而纯图片章 totalChars==0 让真实滚动值永远覆盖不掉它，
            // 退出落库 normCharOffset=9900；开启合并后冷开该书就会被甩到宿主正文章
            // 的 ~99% 处，整章正文被跳过。归零口径与另两个重定向点一致
            // （navigation.part.dart 的 _navigateToChapter、chrome.part.dart 的
            // reloadWithCurrentSettings）：宿主顶部就是那张被吸收的图。
            _initialProgress = 0.0;
            _initialCharOffset = -1;
            _initialCharOffsetEnd = -1;
            _lastProgressValue = 0.0;
            _lastProgressCharOffset = -1;
          }
          _loadChapterDirectly(_currentChapter);
        }

        controller.addJavaScriptHandler(
          handlerName: 'onTextSelected',
          callback: (args) async {
            if (args.isEmpty) return;
            try {
              final Map<String, dynamic> payload =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              await _handleTextSelected(ReaderSelectionData.fromJson(payload));
            } catch (e, stack) {
              ErrorLogService.instance
                  .log('ReaderFushi.onTextSelected', e, stack);
              debugPrint('[ReaderFushi] onTextSelected error: $e');
            }
          },
        );

        // TODO-1317: a mobile long-press *drag*-select fires this instead of
        // onTextSelected. Dart shows a selection menu (Copy / Lookup) so a
        // plain-text range selection (copy) and lookup/mining coexist -- the
        // drag no longer forces an immediate lookup (BUG-609 regression).
        controller.addJavaScriptHandler(
          handlerName: 'onSelectionMenu',
          callback: (args) async {
            if (args.isEmpty) return;
            try {
              final Map<String, dynamic> payload =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              await _handleSelectionMenu(ReaderSelectionData.fromJson(payload));
            } catch (e, stack) {
              ErrorLogService.instance
                  .log('ReaderFushi.onSelectionMenu', e, stack);
              debugPrint('[ReaderFushi] onSelectionMenu error: $e');
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onRestoreComplete',
          // args[0] = JS 侧 perfSnapshot()；args[1] = 文档安装引擎时捕获的
          // navigationGeneration。代次缺失/失配一律不能完成当前 restore，更不能
          // 消费当前代 pending。
          callback: (List<dynamic> args) {
            if (args.length < 2 || args[1] is! num) {
              debugPrint('[ReaderFushi] onRestoreComplete missing generation');
              return;
            }
            final num rawGeneration = args[1] as num;
            if (!rawGeneration.isFinite ||
                rawGeneration != rawGeneration.toInt()) {
              debugPrint('[ReaderFushi] onRestoreComplete invalid generation');
              return;
            }
            _acceptRestoreComplete(
              reportedGeneration: rawGeneration.toInt(),
              perfSnapshot: args.first,
            );
          },
        );

        // BUG-493 根因修复：JS 侧 `_reanchorPending` 清旗已单点化（_sharedJs 的
        // `_setReanchorPending`），true→false（重锚 settle）那一刻回调此处。settle 即补
        // 刷一次进度，事件驱动替代旧的 Dart 侧 120ms×8 轮询重试——commit 成功 / gate 不
        // 放行 / begin 采不到锚 / 已有别处重锚在飞等**所有**清旗路径都会通知，进度不再
        // 依赖轮询猜测清旗时机。图片/封面章的 null 稳态仍由 _refreshProgress 内的
        // _applyImagePageProgressFallback 兜底，不受影响。
        controller.addJavaScriptHandler(
          handlerName: 'onReanchorSettled',
          callback: (_) {
            if (!mounted) return;
            unawaited(_refreshProgress());
          },
        );

        // BUG-213: 章内原生滚动（连续模式 window 滚动 / 分页模式触摸·trackpad·键盘
        // 箭头落 body 的原生滚动）经 setup 脚本的 scroll reporter 回传，刷新章内进度
        // 条。门控由 readerScrollProgressRefreshAllowed 纯函数统一判定，恢复期/歌词/
        // 未就绪一律不触发（JS 侧已抑制 _reanchorPending 重锚瞬态）。
        controller.addJavaScriptHandler(
          handlerName: 'onReaderScroll',
          callback: (_) => _handleReaderScroll(),
        );

        // BUG-117: primary internal-link path. The JS click interceptor (in the
        // reader setup script) preventDefaults <a> clicks and forwards the
        // browser-resolved absolute href here, so link navigation works on every
        // platform — including the Windows fork, whose shouldOverrideUrlLoading
        // never fires for clicks.
        controller.addJavaScriptHandler(
          handlerName: 'onInternalLink',
          callback: (args) async {
            if (args.isEmpty) return;
            await _handleInternalLinkUrl(args[0] as String);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTap',
          callback: (args) {
            if (args.length < 2) return;
            final bool shiftKey = args.length >= 3 && args[2] == true;
            if (!_showChrome && !shiftKey) {
              _toggleChrome();
              // Tap handed OS focus to the WebView; reclaim it so ESC still
              // exits after a tap-to-toggle-chrome (BUG-136). _toggleChrome()
              // here does not move focus to the bar, so the reader keeps it.
              _focusOwnership.reclaim(FocusReclaimCause.gesture);
              return;
            }
            if (!shiftKey && !ReaderFushiSource.instance.highlightOnTap) {
              // Tap consumed without a selection/popup — reclaim reader focus.
              _focusOwnership.reclaim(FocusReclaimCause.gesture);
              return;
            }
            final double x = _ReaderFushiPageState._toDouble(args[0]) ?? 0;
            final double y = _ReaderFushiPageState._toDouble(args[1]) ?? 0;
            // Selection → onTextSelected → popup, which takes focus itself; do
            // not reclaim here or we would fight the popup for focus.
            _selectTextAt(x, y);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onShiftHover',
          callback: (args) {
            if (args.length < 2) return;
            // 连续查词（和鼠标一样）：**不再**门控 isDictionaryShown（旧 TODO-851
            // 放开）。弹窗未出时这里出首弹；某些平台弹窗出现后 WebView DOM 仍收
            // mousemove（barrier 不拦原生视图指针），此时也照常换词——与
            // onDismissBarrierHover 入口一致，防平台事件路由差异漏网。换词经
            // prunePopupStack(0) 复用热槽无缝替换，同词由 JS selectText 的 fromHover
            // 同词短路去重，二者协同不叠层不闪。
            final double x = _ReaderFushiPageState._toDouble(args[0]) ?? 0;
            final double y = _ReaderFushiPageState._toDouble(args[1]) ?? 0;
            // TODO-851：悬停路径传 fromHover:true，命中空白不触发 onTapEmpty。
            _selectTextAt(x, y, fromHover: true);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTapEmpty',
          callback: (_) {
            // TODO-1027：有可见查词弹窗时，本 onTapEmpty 是 dismiss barrier 转发的
            // 真点击命中空白（onDismissBarrierTap → _selectTextAt 命中真空白才 fire）。
            // 此时按 barrier 旧语义清整栈（clearDictionaryResult → onAllPopupsDismissed
            // 续播 BUG-072 / 保留热槽 BUG-092），不走下面的隐藏控制栏分支。命中词的
            // 情形不会到这里（走 onTextSelected）。无弹窗时（正常正文点空白）维持旧行为。
            if (isDictionaryShown) {
              clearDictionaryResult();
              return;
            }
            // TODO-1366：点空白取消残留的拖选（app 自绘选区 + 起止手柄）。拖选松手弹的
            // 菜单被 dismiss 后不再清选区（留着让用户拖手柄改选），于是「点空白 = 取消选择」
            // 成为自然清除路径；无选区时 clearSelection 是空操作，零副作用。
            _clearReaderAppSelection();
            // TODO-975 决策#3：开启「点空白处隐藏控制栏」即底栏悬浮模式。此时点空白
            // 走悬浮唤出/收起状态机（_handleFloatingChromeReveal，不改预留高、不重锚），
            // 而非旧的挤压 _toggleChrome。未开启（挤压）时维持旧行为（不响应空白点）。
            if (_anyChromeFloating) {
              _handleFloatingChromeReveal();
            } else if (ReaderFushiSource.instance.tapEmptyToHideChrome) {
              _toggleChrome();
            }
            // Tap on empty space handed OS focus to the WebView; reclaim it so
            // ESC still exits the book afterward (BUG-136).
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );

        // BUG-1195: VN（视觉小说）模式空白点击的专用桥。JS 只判「这一点落在字面外」，
        // 翻页还是唤出控制栏由 Dart 判（chrome 可见性的真值在 Dart 侧）。
        controller.addJavaScriptHandler(
          handlerName: 'onVnBlankTap',
          callback: (_) {
            _handleVnBlankTap();
          },
        );

        // BUG-756: 歌词模式空白点击的专用桥。歌词是独立文档（LyricsModeHtml），没有
        // 正文 fushiReader 的 onTap/onTapEmpty；歌词里点句子 = 查词，唯一能唤出底栏的
        // 手势就是点空白。故这里对隐藏的底栏**无条件唤出/收起**——不看
        // tapEmptyToHideChrome（那开关管的是正文点空白是否收起底栏，歌词没有别的唤出
        // 途径，绝不能被它关死）。挤压态直接 _toggleChrome（隐藏→出、可见→收，且其内部
        // 已 requestFocus reclaim）；悬浮态走同一唤出/收起状态机。收尾再 reclaim 一次
        // 阅读焦点：本次 pointer 手势把 OS 焦点交给了 WebView，不夺回 Flutter _focusNode
        // 就收不到 ESC，全局「Esc 退出整页」永不触发（正文每个手势都 reclaim，歌词此前
        // 一处都没有 → esc 退不出）。有可见查词弹窗时按正文语义清栈、不动底栏。
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsTapEmpty',
          callback: (_) {
            if (!_lyricsMode) return;
            if (isDictionaryShown) {
              clearDictionaryResult();
              return;
            }
            if (_anyChromeFloating) {
              _handleFloatingChromeReveal();
            } else {
              _toggleChrome();
            }
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );

        // BUG-1280：双页 spread 空白点击的专用桥，与上面的歌词桥同族。spread 是
        // [buildSpreadPageHtml] 生成的独立文档，HTML 本身不含正文 fushiReader 的
        // onTap/onTapEmpty，自带手势只有「点图片 → onImageTap」（弹图片查看器）。
        // 底栏一收起，spread 页就再没有唤出通道 → 看不到返回按钮 → 退不出书。
        // （修复前 Android 因 baseUrl 被保留而被误注入过正文引擎，见
        // _onChapterLoadComplete 的 spread 守卫；那条误注入已堵掉，本桥现在是两个
        // 平台上唯一且语义一致的唤出通道。）
        // 与歌词同理，这里对隐藏的底栏**无条件唤出/收起**——不看
        // tapEmptyToHideChrome（那开关管的是正文点空白是否收起底栏；spread 没有别的
        // 唤出途径，绝不能被它关死）。收尾 reclaim 阅读焦点：本次 pointer 手势把 OS
        // 焦点交给了 WebView，不夺回 Flutter _focusNode 就收不到 ESC（BUG-136）。
        controller.addJavaScriptHandler(
          handlerName: 'onSpreadTapEmpty',
          callback: (_) {
            if (isDictionaryShown) {
              clearDictionaryResult();
              return;
            }
            if (_anyChromeFloating) {
              _handleFloatingChromeReveal();
            } else {
              _toggleChrome();
            }
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );

        // BUG-1426：spread 独立文档的键桥落地点。JS 侧的表由
        // [spreadKeyBridgeTokens] 按注册表当前绑定导出（裸 Space 除外，那条归上面
        // 的 onSpaceKey 桥），所以这里只做「token → 动作」的反解析，解析走的是与
        // Flutter 焦点路径**同一个** resolveKeyboard——改键对两条路一起生效。
        // 收尾 reclaim：这一次按键说明 OS 焦点在 WebView2 手里，不夺回来后续按键
        // 还是只到 DOM（与 onSpaceKey / onSwipe 的 BUG-136 修复同款）。
        //
        // BUG-1442：反解析的 scope **不在这里硬编码**，而是由
        // [resolveSpreadKeyBridgeAction] 从 [kSpreadBridgedActions] 自身导出并逐个
        // 试（页面专属 scope 在前、兜底 scope 在后）。硬编码单 scope 时，往动作集
        // 里加任何非 reader scope 的动作都会静默失效：token 进了 JS 表、按下也回传
        // 到这里，但解析不到动作就早退，桥形同虚设。
        controller.addJavaScriptHandler(
          handlerName: 'onSpreadKey',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _lyricsMode) return;
            final InputBinding? binding =
                InputBinding.deserialize(args[0] as String);
            if (binding == null) return;
            final ShortcutAction? action = resolveSpreadKeyBridgeAction(
              appModel.shortcutRegistry,
              binding,
            );
            if (action == null) return;
            _executeShortcutAction(action);
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onSwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _lyricsMode) return;
            // The swipe/wheel gesture handed OS focus to the WebView; reclaim it
            // so ESC still exits the book after a page turn (BUG-136).
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
            final String dir = args[0] as String;
            final bool invert = ReaderFushiSource.instance.invertSwipeDirection;
            // BUG-横排滑动翻页方向不随书写方向翻转：滑动/鼠标拖动翻页此前只看
            // invertSwipeDirection 开关，不看书写方向，横排与竖排共用同一套映射。
            // 键盘方向键早已用 `leftIsForward = rtl ^ reverse` 按书写方向翻转
            // （resolveReaderArrowPageTurn），滑动却漏了。改用同构的纯谓词
            // swipeLeftIsForward(invert ^ rtl)：竖排(rtl=true)默认手感不变，横排
            // (rtl=false)整体反转——向左滑=前进（LTR 下一页在右，推内容向左露出）。
            final bool leftIsForward =
                swipeLeftIsForward(invert: invert, rtl: _isRtlReading);
            if (dir == 'left') {
              _paginate(leftIsForward
                  ? ReaderNavigationDirection.forward
                  : ReaderNavigationDirection.backward);
            } else if (dir == 'right') {
              _paginate(leftIsForward
                  ? ReaderNavigationDirection.backward
                  : ReaderNavigationDirection.forward);
            }
          },
        );

        // TODO-737: 分页滚轮翻页专用 handler。JS 已把滚轮方向归一成「语义意图」
        // (forward/backward·deltaY>0=forward 对齐连续滚轮)，这里**不读
        // invertSwipeDirection**（该开关从此只管触摸滑动 / 鼠标拖动，不管滚轮），
        // 直接映射成 _paginate 的导航方向。横向触控板惯性先经跨 document 持久的
        // ReaderWheelGestureGate 聚合为一次手势；纵向鼠标滚轮只走既有固定窗口节流。
        controller.addJavaScriptHandler(
          handlerName: 'onWheelPaginate',
          callback: (List<dynamic> args) {
            if (args.length < 2 || _lyricsMode) return;
            final String dir = args[0] as String;
            final String axis = args[1] as String;
            // BUG-1745：老 shell（或未来别的注入点）可能只传两个参数；缺省按
            // 「横向即触摸板」推断，与本次改动前的行为完全一致。
            final String pointerKind = args.length > 2
                ? args[2] as String
                : (axis == 'horizontal' ? 'trackpad' : 'mouse');
            final int throttleMs =
                ReaderFushiSource.instance.wheelPageTurnInterval;
            // BUG-1380：闸门的 token 消费必须晚于「这一 tick 能不能翻页」的确认。
            // 换章加载/restore 在飞时 _paginate 会直接丢弃这一 tick，若此刻仍认领
            // token，整段惯性的后续 tick 全在闸门早退 → 用户这一次滑动零反馈。
            // canTurnPage=false 时闸门只查询不认领，且仍放行到 _paginate——那里的
            // in-flight 分支要靠这些 tick 续跨章冷却窗（TODO-1229 v2）。
            // BUG-1745：闸门的判据从「轴」改成「输入设备」。
            //
            // 旧判据 `axis == 'horizontal'` 隐含假设「纵向 = 鼠标滚轮」，可
            // macOS 触摸板上下双指滑同样是纵向：一次滑动的惯性流持续 1~1.5 秒，
            // 全部漏过闸门、只受 _paginate 的固定 450ms 窗管，于是一次上下滑
            // 稳定翻 3 页；用户若把「滚轮翻页间隔」调到下限 150ms 就是 10 页。
            // 真正要区分的从来不是轴，而是「离散 tick（鼠标，一格一页）」与
            // 「连续惯性流（触摸板，一次滑动一页）」。
            if (pointerKind == 'trackpad' &&
                !_pagedWheelGestureGate.shouldStartNewGesture(
                  now: DateTime.now(),
                  settleInterval: Duration(milliseconds: throttleMs),
                  canTurnPage: !_paginationInFlight,
                )) {
              return;
            }
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
            if (dir == 'forward') {
              _paginate(ReaderNavigationDirection.forward,
                  throttleMs: throttleMs);
            } else if (dir == 'backward') {
              _paginate(ReaderNavigationDirection.backward,
                  throttleMs: throttleMs);
            }
          },
        );

        // TODO-1078：内容层捕获的裸 Space（Windows WebView2 抢焦点后 Flutter
        // _focusNode 收不到键，JS 已 preventDefault 掐掉 Chromium 默认 scrollByPage）。
        // 经 _resolveWebViewSpaceAction 走与键盘焦点路径同款解析：有声书激活 →
        // 播放/暂停，否则 → reader scope 裸 Space 的真实绑定（默认翻页）。执行后
        // reclaim 焦点，让后续按键回到 _handleKeyEvent（对齐 onSwipe/onTap 的 BUG-136
        // 修复）。带修饰键 / 文本框 / composing 的空格 JS 侧已放行，不会到这里。
        controller.addJavaScriptHandler(
          handlerName: 'onSpaceKey',
          callback: (List<dynamic> args) {
            if (_lyricsMode) return;
            final ShortcutAction? action = _resolveWebViewSpaceAction();
            if (action == null) return;
            _executeShortcutAction(action);
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onBoundarySwipe',
          callback: (List<dynamic> args) async {
            if (args.isEmpty || _lyricsMode) return;
            // TODO-1229 案A：跨章手势绕过 _paginate 入口直接调 _handlePageTurnLimit，
            // 故守卫在此单独收口——导航/恢复在飞时丢弃，否则连续滚轮跨章会在前一次章
            // 加载未落定时再次跨章 → 跳两章。与 _paginate 入口同一 _paginationInFlight。
            // BUG-1829：换章加载期到达的 tick 只丢弃，**不**滑动跨章冷却窗——与 _paginate
            // 入口同一处理。新章 content-ready 的重锚（_noteChapterTurnSettledIfPending）
            // 已经覆盖这段窗口；在这里 stamp 只会让持续输入自我续期、永远等不到放行。
            if (_paginationInFlight) {
              return;
            }
            // Boundary swipe → chapter turn also stole focus to the WebView
            // (BUG-136); reclaim it so ESC keeps exiting after a chapter flip.
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
            final String dir = args[0] as String;
            if (!_hasChapterTurnTarget(dir)) return;
            // TODO-737 节流分流（4 必补点 #1）：连续滚轮跨章直接调
            // _handlePageTurnLimit、**绕过 _paginate 入口闸门**，否则归一节流后连续
            // 滚轮跨章不受任何节流。这里就地用与 _paginate 同款 _lastPaginateTime
            // 时间戳闸门拦绕过路径；闸门只放这一处（不放 _handlePageTurnLimit 本体），
            // 故分页跨章经 _paginate 内部调 _handlePageTurnLimit 时不会被自己盖的戳
            // 吞掉（章末翻得过去）。
            final int throttleMs =
                ReaderFushiSource.instance.wheelPageTurnInterval;
            if (throttleMs > 0 && _lastPaginateTime != null) {
              final int elapsedMs =
                  DateTime.now().difference(_lastPaginateTime!).inMilliseconds;
              if (elapsedMs < throttleMs) return;
            }
            // TODO-1229 v2：跨章冷却闸门——同一惯性手势落地短章(插图/单页)后残余惯性
            // 在新章边界的二次跨章被拦。窗口不再被被拦的输入自我续期（BUG-1829）。
            // onBoundarySwipe 仅惯性/触摸路径，
            // 无键盘调用，故无条件过闸门。
            if (_chapterTurnCoolingDown()) return;
            if (!await _prepareContinuousChapterTransition()) return;
            if (!mounted ||
                _paginationInFlight ||
                !_hasChapterTurnTarget(dir)) {
              _discardIdleChapterTransitionSnapshot();
              return;
            }
            // BUG-369/TODO-656 诊断：跨章手势汇合点（滚轮/触摸/指针都经此）。
            debugPrint('[xchapter] onBoundarySwipe dir=$dir '
                'chapter=$_currentChapter');
            _noteChapterTurn();
            if (dir == 'forward') {
              _handlePageTurnLimit('forward', inertia: true);
            } else if (dir == 'backward') {
              _handlePageTurnLimit('backward', inertia: true);
            }
            // 导航真的开始时 _beginNavigation 已把 _readerContentReady 置 false（同步，
            // 早于本行）；仍为 true 就说明这次跨章被 _handlePageTurnLimit 内部守卫吃掉，
            // 快照没有消费者，必须就地丢弃。
            _discardIdleChapterTransitionSnapshot();
            if (throttleMs > 0) {
              _lastPaginateTime = DateTime.now();
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageDetected',
          callback: (_) => _audiobookController?.triggerImagePause(),
        );

        // TODO-1289 / BUG-898：JS 揭开防剧透图后回传稳定 key（extractDir 相对归一路径）。
        // 归一化后登记进本次阅读会话内存集（章节重载 _buildReaderHtml 嵌回分页脚本跳过重
        // 遮罩），并持久化到 Drift（跨 app 重启永久 + 图片库双向同步的真相源）。
        controller.addJavaScriptHandler(
          handlerName: 'onImageRevealed',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            final String? key =
                ImageRevealKey.normalize(args[0]?.toString() ?? '');
            if (key == null) return;
            // 仅新揭开才写库（省重复写）；DB 失败不阻塞 UI（内存集已生效）。
            // v82：revealed_images 键 = 书 uid（[_bookUid]）；uid 缺失只留内存
            // 集（本次会话有效），不拿 bookKey 兜底写孤儿行。
            if (_revealedImageKeys.add(key)) {
              final String? bookUid = _bookUid;
              if (bookUid == null) return;
              unawaited(appModel.database.markImageRevealed(
                bookUid,
                key,
                DateTime.now().millisecondsSinceEpoch,
              ));
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageTap',
          callback: (args) {
            if (args.isEmpty) return;
            // BUG-1280：点图片同样把 OS 焦点交给了 WebView，不 reclaim 则看完图
            // pop 回来后 ESC 退不出书（BUG-136 同族）。在 spread 页尤其致命：两张
            // 整页图铺满视口，点击几乎必然命中 img，于是「唤不出底栏」与「ESC 失效」
            // 同时成立，两条退出通道一起死——所以本轮先修这一条。
            //
            // 口径更正：onImageTap **不是**「全阅读器唯一没 reclaim 的手势入口」。
            // 同族至今仍有 7 处 JS 桥零 reclaim：onSelectionMenu、onImageRevealed、
            // onImageContextMenu、onImageLongPress、onCueTap、onPointerSeek、
            // onLyricsPointerSeek。其中 onImageRevealed / onImageContextMenu /
            // onImageLongPress / onCueTap 连兄弟桥兜底都没有。本轮只修 spread 退出
            // 路径必经的这一条，其余未覆盖——别把这里当作「此族已清干净」的证据。
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
            _openImageViewer(args[0] as String);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageContextMenu',
          callback: (args) async {
            if (args.isEmpty) return;
            final double x = args.length > 1
                ? (_ReaderFushiPageState._toDouble(args[1]) ?? 0)
                : 0;
            final double y = args.length > 2
                ? (_ReaderFushiPageState._toDouble(args[2]) ?? 0)
                : 0;
            await _showReaderImageContextMenu(args[0] as String, Offset(x, y));
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageLongPress',
          callback: (args) async {
            if (args.isEmpty) return;
            await _shareReaderImage(args[0] as String);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'spreadReady',
          callback: (_) {
            _isNavigatingToChapter = false;
            _restoreInFlight = false;
            if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
              _restoreCompleter!.complete(true);
            }
            _restoreCompleter = null;
            if (mounted) {
              // BUG-438 / TODO-889：spread 内容就绪，清兜底 deadline，下次导航拿新窗口。
              _clearContentReadyTimeout();
              _rebuild(() {
                _readerContentReady = true;
                // spread(漫画双页)路径只发 'spreadReady'，从不发 'onRestoreComplete'，
                // 故不走 _onRestoreComplete 的 _hasEverLoaded 置位。这里补齐，与另外
                // 三个 content-ready 完成点对齐 —— 否则 spread 书冷开时底栏(有声书条/
                // 设置条)要等 8s _startContentReadyTimeout 兜底才出现。set-once，不复位。
                _hasEverLoaded = true;
              });
              // TODO-1229 第三次复诉：spread 内容就绪同样消费 pending 并 stamp 冷却窗，
              // 挡住惯性跨章落地漫画页后残余滚轮的二次跨章（与 _onRestoreComplete 对齐）。
              _noteChapterTurnSettledIfPending();
              // BUG-467：spread 内容就绪同样补下 chrome insets（_hasEverLoaded 刚翻 true，
              // 初始 HTML 漏了底栏预留）。
              _reapplyChromeInsetsAfterFirstLoad();
              // TODO-700 T3：spread 内容就绪确定性落焦到正文（门控见 helper）。
              _focusOwnership.reclaim(FocusReclaimCause.contentReady);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onCueTap',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _audiobookController == null) return;
            final int sentenceIndex = (args[0] as num).toInt();
            final List<AudioCue>? allCues = _cachedAllCues;
            if (allCues == null) return;
            final int idx = allCues
                .indexWhere((AudioCue c) => c.sentenceIndex == sentenceIndex);
            if (idx >= 0) {
              _audiobookController!.playCueAndContinue(allCues[idx]);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onPointerSeek',
          callback: (List<dynamic> args) async {
            if (args.length < 3) return;
            final int button = (args[0] as num?)?.toInt() ?? -1;
            if (button < 0) return;
            final registry = appModel.shortcutRegistry;
            // ① **位置型动作**先行：「seek 到点击句」需要知道点在哪一句上，只有页内
            // JS 拿得到坐标，故它恒由本条路承担（Flutter 侧那个入口会跳过它，判据
            // [isSeekToClickedSentenceButton] 两侧共用）。仅有声书表面有意义，故仍需
            // controller。
            if (isSeekToClickedSentenceButton(registry, button)) {
              if (_audiobookController == null) return;
              final double x = _ReaderFushiPageState._toDouble(args[1]) ?? 0;
              final double y = _ReaderFushiPageState._toDouble(args[2]) ?? 0;
              await _seekToClickedSentence(x, y);
              return;
            }
            // ② 指针归宿主的平台（Windows 的 composition WebView）上，其余绑定由页面
            // 根 [Listener]（[_handleReaderPointerDown]）派发；这里再派一次就是同一次
            // 按下触发两回。判据与漫画、查词弹窗三处共用同一个
            // [hostOwnsWebViewPointerInput]。
            if (hostOwnsWebViewPointerInput) return;
            // ③ 其余一律走与键盘/手柄**完全相同**的执行体。
            //
            // 此前这里硬编码只判两件事（关词典 + seek 到点击句），于是 reader /
            // audiobook scope 明明开着 mouse 通道、设置页也给「添加鼠标按键」入口，
            // 但除这两个动作外**绑什么都没反应**——翻页、振假名、加入暂存……全是死项。
            // 那正是用户复诉的「有的支持鼠标有的没有」在页面内部的那一半。
            final ShortcutAction? action = resolveMouseBindingActionForButton(
              registry: registry,
              button: button,
              ladder: kReaderMouseLadder,
            );
            if (action == null) return;
            _executeShortcutAction(action);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onLyricsPointerSeek',
          callback: (List<dynamic> args) {
            if (args.length < 2 || _audiobookController == null) return;
            final int button = (args[0] as num?)?.toInt() ?? -1;
            final int idx = (args[1] as num?)?.toInt() ?? -1;
            final AudioCue? cue = cueForLyricsPointer(
              appModel.shortcutRegistry,
              button,
              idx,
              _lyricsCueList,
            );
            if (cue != null) _audiobookController!.playCueAndContinue(cue);
          },
        );

        // BUG-1809：iOS WKWebView 的 loadData() 可返回却不发 onLoadStop。
        // LyricsModeHtml 在 DOM API 全部就绪后主动回传；与 onLoadStop 共用幂等
        // finalize，谁先到谁完成，另一条只读到 ready 后早返回。
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsReady',
          callback: (args) {
            final dynamic raw = args.isEmpty ? null : args.first;
            final int? generation =
                raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
            if (generation == null) return false;
            return _finalizeLyricsDocumentIfReady(
              controller,
              generation: generation,
            );
          },
        );
      },
      shouldInterceptRequest: (controller, request) async {
        return await _interceptRequest(request.url);
      },
      onLoadResourceWithCustomScheme: (controller, request) {
        return _loadResourceWithCustomScheme(request);
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final String url = action.request.url?.toString() ?? '';
        if (_isNavigatingToChapter || _isCurrentLyricsDocumentUrl(url)) {
          return NavigationActionPolicy.ALLOW;
        }
        // BUG-117: shouldOverrideUrlLoading is NOT invoked for <a> clicks on the
        // flutter_inappwebview_windows fork (the WebView2 NavigationStarting hook
        // is unwired), so internal links navigated the WebView natively, bypassing
        // our paginated navigation — _currentChapter went stale and onLoadStop
        // then dropped the page as "stale", leaving the reader broken. Link clicks
        // are now intercepted in JS (onInternalLink handler) on every platform, so
        // this callback is only a fallback for non-click navigations (still fires
        // on mobile). Both paths funnel through _handleInternalLinkUrl.
        await _handleInternalLinkUrl(url);
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, url) async {
        _isNavigatingToChapter = false;
        ReaderChapterPerfTrace.mark('docLoad');
        final int chapterSnapshot = _currentChapter;
        debugPrint('[ReaderFushi] onLoadStop: url=$url '
            'chapter=$chapterSnapshot progress=$_initialProgress');
        if (_lyricsMode) {
          if (!await _finalizeLyricsDocumentIfReady(
            controller,
            generation: _lyricsLoadGeneration,
          )) {
            debugPrint('[ReaderFushi] onLoadStop: stale non-lyrics page '
                'while lyrics mode is active, ignoring');
          }
          return;
        }
        final String expectedUrl = _chapterUrl(chapterSnapshot);
        if (url != null &&
            Uri.parse(url.toString()).path != Uri.parse(expectedUrl).path) {
          debugPrint(
              '[ReaderFushi] onLoadStop: stale page (expected=$expectedUrl), ignoring');
          return;
        }
        await _onChapterLoadComplete(controller);
      },
      onReceivedError: (controller, request, error) async {
        // TODO-904: native WebView2 实例创建失败（Windows 反复开关书后
        // `Cannot create the InAppWebView instance!`）经 fork 合成的带 sentinel
        // 的 WebResourceError 转交到这里。普通页面加载错误不带 sentinel、不触发
        // 恢复。命中 sentinel 时走与 _initBook 同款可见恢复（toast + 退回书架），
        // 不再永久 spinner。
        if (error.description.contains(kReaderWebViewCreationFailedSentinel)) {
          debugPrint('[ReaderFushi] WebView creation failed: '
              '${error.description}');
          ErrorLogService.instance.log(
              'ReaderFushi.onWebViewCreationFailed', error.description, null);
          if (!mounted) return;
          FushiToast.show(
              msg: t.reader_open_failed, severity: ToastSeverity.error);
          Navigator.of(context).pop();
          return;
        }
        if (request.isForMainFrame ?? false) {
          final int? failedLyricsGeneration =
              _lyricsDocumentGenerationFromUrl(request.url.toString());
          if (failedLyricsGeneration != null &&
              failedLyricsGeneration == _lyricsDocumentLoadGeneration &&
              failedLyricsGeneration == _lyricsLoadGeneration) {
            _lyricsDocumentLoadGeneration = null;
          }
          debugPrint('[ReaderFushi] onReceivedError: ${error.description} '
              'url=${request.url}');
          // Windows 拦截域 (fushi.local) 的 NavigationCompleted 假失败已在 fork
          // 引擎层根治（packages/flutter_inappwebview_windows：主框架已注入 2xx
          // 时按成功走 onLoadStop），此处不再做事后补偿；下面是真实加载失败处理。
          if (_restoreExpectedGeneration != _navigateGeneration) return;
          _isNavigatingToChapter = false;
          _restoreInFlight = false;
          if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
            _restoreCompleter!.complete(false);
          }
          _restoreCompleter = null;
        }
      },
      onConsoleMessage: (controller, msg) {
        debugPrint('[WebView] ${msg.message}');
      },
      // 非 null 本身就是救命动作：Android 上 renderer 被 OOM 回收时，
      // `InAppWebViewClientCompat.onRenderProcessGone` 只有拿到非 null 回调才
      // `return true`；否则默认动作是把整个 app 进程一起杀掉。这里的处置刻意
      // **不重建**（见 [_webViewDeathGuard] 的注释：恢复锚陈旧会把进度写回退）。
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) =>
              unawaited(_webViewDeathGuard.handleDeath(
        didCrash: detail.didCrash,
        rendererPriorityAtExit: detail.rendererPriorityAtExit,
      )),
    );
    // KeyedSubtree carries [_webViewKey] (a GlobalKey) on the InAppWebView's own
    // render subtree so [onDismissBarrierHover] can read the WebView's RenderBox
    // for global→local coordinate mapping (TODO-806), while the ValueKey stays on
    // the InAppWebView itself for the integration-test finders (fushi_webview).
    final Widget keyed = KeyedSubtree(key: _webViewKey, child: webView);
    // TODO-954：Windows 文字选区右键。`HitTestBehavior.translucent` 让左键框选 / 滚动 /
    // 查词点击照常落进 WebView（与 dictionary_popup_webview 的 BUG-261 范式同），只额外
    // 截菜单键弹出 Flutter 菜单——后者随界面大小缩放。BUG-2111 之后「菜单键」由绑定表决定
    // （默认右键），阅读器阶梯里 reader / audiobook 先解析，故右键改绑翻页等动作时菜单让位。
    if (!isWindowsPlatform) return keyed;
    return ContextMenuTrigger(
      // 右键菜单改由绑定表决定唤出键（默认仍是右键）；右键被别的动作占用时自动让位。
      onInvoke: (Offset position) => _showReaderTextContextMenu(position),
      ladder: kReaderMouseLadder,
      child: keyed,
    );
  }

  Future<bool> _isLoadedLyricsDocument(
    InAppWebViewController controller, {
    required int generation,
  }) async {
    try {
      final dynamic result = await controller.evaluateJavascript(
        source:
            '''Boolean(window.__lyricsSetCue && document.getElementById('lc') && window.__fushiLyricsLoadGeneration === $generation)''',
      );
      return result == true || result == 'true' || result == 1 || result == '1';
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderFushi.isLoadedLyricsDocument', e, stack);
      return false;
    }
  }

  Future<bool> _finalizeLyricsDocumentIfReady(
    InAppWebViewController controller, {
    required int generation,
  }) async {
    if (!mounted || !_lyricsMode || generation != _lyricsLoadGeneration) {
      return false;
    }
    if (_lyricsPageReady) return true;
    if (_lyricsReadyFinalizingGeneration == generation) return false;
    _lyricsReadyFinalizingGeneration = generation;
    try {
      if (!await _isLoadedLyricsDocument(
        controller,
        generation: generation,
      )) {
        return false;
      }
      if (!mounted || !_lyricsMode || generation != _lyricsLoadGeneration) {
        return false;
      }
      if (!_lyricsPageReady) {
        await _onChapterLoadComplete(
          controller,
          lyricsGeneration: generation,
        );
      }
      if (!mounted || !_lyricsMode || generation != _lyricsLoadGeneration) {
        return false;
      }
      if (_lyricsDocumentLoadGeneration == generation) {
        _lyricsDocumentLoadGeneration = null;
      }
      return _lyricsPageReady;
    } finally {
      if (_lyricsReadyFinalizingGeneration == generation) {
        _lyricsReadyFinalizingGeneration = null;
      }
    }
  }

  int? _lyricsDocumentGenerationFromUrl(String? raw) {
    final Uri? uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null ||
        !uri.isScheme('https') ||
        uri.host != 'fushi.local' ||
        uri.path != '/lyrics') {
      return null;
    }
    return int.tryParse(uri.queryParameters['generation'] ?? '');
  }

  bool _isCurrentLyricsDocumentUrl(String raw) {
    final int? generation = _lyricsDocumentGenerationFromUrl(raw);
    return _lyricsMode &&
        generation != null &&
        generation == _lyricsDocumentLoadGeneration &&
        generation == _lyricsLoadGeneration;
  }

  Future<void> _onChapterLoadComplete(
    InAppWebViewController controller, {
    int? lyricsGeneration,
  }) async {
    // BUG-1280（平台分叉守卫）：spread 独立文档绝不注入正文引擎。
    //
    // `_loadSpreadPage` 传给 `loadData` 的 baseUrl 与 `_chapterUrl(_currentChapter)`
    // **逐字相同**，而上面 `onLoadStop` 的陈旧判据只比 `Uri.path`。于是同一份代码
    // 在两个平台走出相反的分支：
    //   - Windows fork 的 `loadData` 原生侧只取 data、丢掉 baseUrl
    //     （`webview_channel_delegate.cpp` → `NavigateToString`），文档 URL 变
    //     `about:blank`，path 为空 → 判 stale → 从来没走到这里；
    //   - Android 的 `loadDataWithBaseURL` 保留 baseUrl，path 完全相等 → 判据放行
    //     → 此前会把整份 `readerEngineSource` 注进 spread 文档。
    // 后果是 spread 文档上同时挂着引擎的 `onTapEmpty` 和本页自带的
    // `onSpreadTapEmpty`：一次空白点两个桥都收到，`onSpreadTapEmpty` 无条件翻转、
    // `onTapEmpty` 在悬浮态/开了「点空白隐藏控制栏」时也翻转一次，两次翻转互相抵消
    // → 底栏还是唤不出来，比没修更难查。
    //
    // 正确的模型是：spread 是独立文档（同歌词、VN），它的就绪与手势由它自己的
    // `spreadReady` / `onSpreadTapEmpty` 桥负责，正文引擎、有声书桥、章节高亮对
    // 「两张整页图、正文 ≤20 字」的 image-only 章都无意义。Windows 早就是这个行为，
    // 这里把 Android 拉齐，而不是给 Android 再加一层特例。
    if (_spreadDocumentLoaded) {
      debugPrint('[ReaderFushi] onChapterLoadComplete: spread document, '
          'skipping body engine injection');
      return;
    }
    if (_lyricsMode) {
      bool currentLyricsLoad() =>
          mounted &&
          _lyricsMode &&
          lyricsGeneration != null &&
          lyricsGeneration == _lyricsLoadGeneration;
      if (!currentLyricsLoad()) return;
      if (!_readerContentReady) {
        // BUG-438 / TODO-889：歌词模式内容就绪，清兜底 deadline，下次导航拿新窗口。
        _clearContentReadyTimeout();
        _rebuild(() {
          _readerContentReady = true;
          _hasEverLoaded = true;
        });
      }
      if (!currentLyricsLoad()) return;
      _lyricsPageReady = true;
      // 首次进入歌词模式的提示对话框：挂在歌词文档真正就绪的这一刻消费一次性旗
      // （_toggleLyricsMode 进入分支置位），替代旧的裸 delay 100ms（事件驱动，见旗注释）。
      if (_pendingLyricsHintOnReady) {
        _pendingLyricsHintOnReady = false;
        _showLyricsModeHintIfNeeded();
      }
      // 注入歌词专用行级 caret（键盘/手柄逐词查词），镜像 reader 的 fushiCaret 注入。
      // 文档刚加载，caret inactive；surface 在 _enterCaret 成功时才置 lyrics。
      await controller.evaluateJavascript(
          source: ReaderLyricsCaretScripts.source());
      if (!currentLyricsLoad()) return;
      if (mounted) {
        await controller.evaluateJavascript(
          source: ReaderLyricsCaretScripts.initInvocation(
            color: _caretRingColorCss(),
            insetTop: _readerTopOffset,
            insetBottom: 0,
          ),
        );
      }
      if (!currentLyricsLoad()) return;
      _onCueChanged();
      await _applyLyricsFavorites();
      if (!currentLyricsLoad()) return;
      // BUG-844: 歌词是独立文档，正文 setup 脚本（下发 window.__hoverAutoLookup 初值）
      // 不在此分支注入。歌词页的 mousemove 悬停查词监听据此全局跳过 Shift 门控（纯悬停即
      // 查词），必须在页面就绪时把当前开关值同步进新文档，否则纯悬停查词要等一次设置热更
      // 才生效。Shift-悬停不依赖此全局（监听器直接读 e.shiftKey），本行只补齐纯悬停路径。
      if (mounted) await _applyHoverAutoLookupLive();
      if (!currentLyricsLoad()) return;
      // BUG-767: 此前（BUG-755）在歌词页就绪即强夺阅读焦点，想让 ESC 从进入那刻就能退。
      // 但桌面 loadData 后强夺 Flutter 焦点会把原生 WebView2 顶焦、重置其滚动到顶
      // （→ 高亮看似回第一句），并与页面自身抢焦点抖动；一旦叠加重载路径每次 loadData
      // 都触发一次，放大成持续闪烁。故移除这处 on-load 强夺焦（本行下方原有的焦点 reclaim
      // 调用已删）。ESC 退出仍可用：点空白唤底栏走 onLyricsTapEmpty（内含焦点 reclaim）、
      // 查词弹窗关闭走 onAllPopupsDismissed reclaim——任一交互后焦点即回阅读内容，ESC 正常退出。
      return;
    }
    final int gen = _navigateGeneration;
    final int chapterSnapshot = _currentChapter;
    try {
      String? sentenceAudioCuesJson;
      if (_audiobookController != null) {
        sentenceAudioCuesJson = await _prepareSentenceAudioCuesJson();
      }
      ReaderChapterPerfTrace.mark('sentenceAudioCues');
      if (_currentChapter != chapterSnapshot || _navigateGeneration != gen) {
        return;
      }
      // per-nav 参数走 config，引擎源码按 view-mode memoized。两半拼成**一次**
      // evaluateJavascript 发出去——注入通道与执行时刻都与改动前逐字相同，省掉的是
      // Dart 侧每章重新拼装 + 压缩近万行（实测 buildSetupScript 中位数 9ms）。
      final ReaderEngineConfig engineConfig = _buildReaderEngineConfig(
        navigationGeneration: gen,
        sentenceAudioCuesJson: sentenceAudioCuesJson,
      );
      final String engineSource = readerEngineSource(
        vnMode: engineConfig.vnMode,
        continuousMode: engineConfig.continuousMode,
      );
      final String setupScript =
          '$engineSource\n${readerEngineBoot(engineConfig)}';
      ReaderChapterPerfTrace.mark('buildSetupScript');
      ReaderChapterPerfTrace.noteSize('setupChars', setupScript.length);
      await controller.evaluateJavascript(source: setupScript);
      ReaderChapterPerfTrace.mark('evalSetupScript');
      if (!mounted || _navigateGeneration != gen) return;

      // The setup script rebuilds window.fushiCaret fresh (inactive). If the
      // reading cursor was on the reader, restore it on the new chapter's first
      // page. (If it's on a popup, the reader ring is already hidden — leave it.)
      if (_caretOnReader) {
        await _caretReanchor(ReaderNavigationDirection.forward);
        if (!mounted || _navigateGeneration != gen) return;
      }
      ReaderChapterPerfTrace.mark('caretReanchor');

      _initialFragment = null;
      if (_audiobookController != null) {
        await _injectAudiobookBridge();
      }
      ReaderChapterPerfTrace.mark('audiobookBridge');
      if (!mounted || _navigateGeneration != gen) return;
      await HighlightBridge.inject(controller);
      await _applyChapterHighlights();
      ReaderChapterPerfTrace.mark('highlights');
      if (!mounted || _navigateGeneration != gen) return;
      // BUG-111: 基线取「JS 实际分页用的尺寸」(_paginatedWidth/Height)，不是当前
      // MediaQuery——这样后续 resize 才与真正生效的版面宽度比对。
      _lastSyncedWidth = _paginatedWidth;
      _lastSyncedHeight = _paginatedHeight;
      // BUG-270 (TODO-296 B): warm the next chapter so a forward boundary
      // page-turn hits the LRU cache instead of disk read + decode + sanitize +
      // inject. Background, single chapter, dropped if disposed/style-changed.
      _prefetchAdjacentChapter(chapterSnapshot + 1);
      // BUG-785: EPUB 正文首次就绪 + 有声书已挂载 → 恢复「上次退出时在歌词模式」。
      // 此刻正文已加载，切歌词等价用户手动切（已知安全），规避 fresh open 直接整页
      // 加载歌词 HTML 跳过 EPUB 的 iOS 白屏。一次性（下面立即清零）防每章重触发；
      // 无有声书（controller==null）则不恢复（歌词模式依赖音频），意图也一并清掉。
      if (_pendingLyricsRestore) {
        _pendingLyricsRestore = false;
        if (_audiobookController != null && !_lyricsMode) {
          unawaited(_toggleLyricsMode());
        }
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderFushi._onChapterLoadComplete', e, stack);
      debugPrint('[ReaderFushi] _onChapterLoadComplete failed: $e');
    }
  }
}

/// 静态引擎源码的公开入口（默认分页模式）。
///
/// 守卫测试用它断言「引擎里确实含有全部载荷」「引擎与导航状态无关」——这条链路
/// 此前完全没有：所有脚本守卫都只断言各 builder 的返回值，没人断言那些返回值真的
/// 进了注入物，漏装一个载荷 ~100 条测试照样全绿。
String readerFushiEngineSource({
  bool vnMode = false,
  bool continuousMode = false,
}) =>
    _ReaderWebView.readerEngineSource(
      vnMode: vnMode,
      continuousMode: continuousMode,
    );

/// 每次导航下发的那一小份（config + install 调用），供守卫测试断言它不含引擎本体。
String readerFushiEngineBoot(ReaderEngineConfig config) =>
    _ReaderWebView.readerEngineBoot(config);

/// 压缩**之前**的引擎源码 = 生产上真正交给 [ReaderScriptCompactor] 的那份。
///
/// 给压缩器守卫测试用：它要证明压缩器对**真实最终注入载荷**只删空行与整行注释、
/// 幂等、扫完词法状态干净。此前那份「最终拼装脚本」是把 `webview.part.dart` 的三引号
/// 模板抠出来、按一张手写替身表重建的——那张表是查找表，**新增**插值会 StateError
/// （响亮），**删掉**一个载荷完全静默：整份注入物少一块，压缩覆盖跟着少一块，而没有
/// 一条测试会红。现在直接向生产代码要同一份对象，那个不对称从根上没有了。
String readerFushiEngineSourceUncompacted({
  bool vnMode = false,
  bool continuousMode = false,
}) =>
    _ReaderWebView._buildReaderEngineSource(
      vnMode: vnMode,
      continuousMode: continuousMode,
    );

/// BUG-1745：分页滚轮手势桥的 JS 片段，**两个注入点的唯一真值源**。
///
/// 正文引擎（[_ReaderWebView._buildReaderEngineSource] 的 setup 段）与 spread 双页
/// 独立文档（[buildSpreadPageHtml]）是两份互不共享运行时的 document，却必须对
/// 「一次滚轮输入 = 翻几页」给出**逐字相同**的判定：落到 Dart 侧的是同一个
/// `onWheelPaginate` handler 和同一个 [ReaderWheelGestureGate]。
///
/// 改动前 spread 那份是**手抄的第二遍**，于是 BUG-1745 只在正文侧被修掉——spread
/// 仍是旧的「轴」判据、只传 2 个参数，落到 Dart 侧的兼容回落
/// `axis == 'horizontal' ? 'trackpad' : 'mouse'` 把纵向恒判成 mouse、绕过闸门，
/// 双页模式下触摸板上下滑一次照样翻 3 页。手抄正是漏改的直接原因，所以现在两个
/// 注入点都拼这一份常量，第二份拷贝在源码里不再存在
/// （守卫 `test/reader/pr912_paged_wheel_single_source_test.dart`）。
const String kPagedWheelGestureHelperJs = r'''
  // BEGIN PAGED_WHEEL_GESTURE_HELPER
  // BUG-1342：只把每个 tick 的语义方向和主轴交给 Dart。手势 session 不能存在 JS
  // document 中，因为翻章会重建 document、在同一段惯性中重置闸门。横向主轴由跨章节
  // 持久的 ReaderWheelGestureGate 聚合；纵向鼠标滚轮维持既有固定窗口节流。
  // BUG-1745：主轴判据要带抖动余量。一次横向触摸板滑动里总有几拍
  // |deltaY| >= |deltaX|（手指纵向漂移 / 惯性尾段轴向噪声）；用严格 > 分类会把
  // 这些拍标成 vertical，于是它们绕过闸门直接进 _paginate，一次横滑变成
  // 「闸门放行 1 页 + 若干漂移拍再各翻 1 页」。弹窗滚动路径（BUG-701）已经用
  // 同一配方修过，分页路径当时漏了。
  var PAGED_WHEEL_AXIS_MARGIN = 6;
  // BUG-1745：触摸板 vs 鼠标滚轮。二者对「一次输入 = 翻几页」的期望完全相反：
  // 鼠标一格就该翻一页（离散 tick），触摸板一次滑动连同惯性会喷 1~1.5 秒的 tick
  // 流、必须聚合成一次翻页。判据只用单事件可得的量（JS 侧不能存手势状态——翻章
  // 会重建 document，见下方注释），时间维度的聚合交给 Dart 侧跨 document 持久的
  // ReaderWheelGestureGate。
  function _isTrackpadWheel(e) {
    // line / page 模式只有真实滚轮会产生。
    if (e.deltaMode !== 0) return false;
    var dx = Math.abs(e.deltaX);
    var dy = Math.abs(e.deltaY);
    // 分数像素增量是触摸板独有的。
    if (dx % 1 !== 0 || dy % 1 !== 0) return true;
    // 两轴同时非零 = 二维手势，滚轮给不出。
    if (dx > 0 && dy > 0) return true;
    // Chromium 给鼠标滚轮的 wheelDelta 恒为 120 的整数倍；触摸板不是。
    var wd = e.wheelDeltaY;
    if (typeof wd === 'number' && wd !== 0 && Math.abs(wd) % 120 !== 0) return true;
    var wdx = e.wheelDeltaX;
    if (typeof wdx === 'number' && wdx !== 0 && Math.abs(wdx) % 120 !== 0) return true;
    return false;
  }
  function _handlePagedWheelTick(e) {
    var absX = Math.abs(e.deltaX);
    var absY = Math.abs(e.deltaY);
    var horizontal = absX > absY + PAGED_WHEEL_AXIS_MARGIN;
    var delta = horizontal ? e.deltaX : e.deltaY;
    if (delta === 0) return;
    e.preventDefault();
    var direction = delta > 0 ? 'forward' : 'backward';
    window.flutter_inappwebview.callHandler('onWheelPaginate', direction,
      horizontal ? 'horizontal' : 'vertical',
      _isTrackpadWheel(e) ? 'trackpad' : 'mouse');
  }
  // END PAGED_WHEEL_GESTURE_HELPER''';
