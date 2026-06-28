// GENERATED-NOTE: extracted from reader_hibiki_page.dart (TODO-589 batch8).
part of '../reader_hibiki_page.dart';

/// webview (EPUB WebView 构建 / hoshi.local 资源拦截 + 净化 / 单 IIFE setup 脚本)
/// 域 helper，经 part-of 抽出（TODO-589 batch8·最后一批）；与主壳共享私有作用域。
/// 行为保持：方法体逐字搬运（含 _buildReaderSetupScript 整段内联 JS 模板字符串的
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
extension _ReaderWebView on _ReaderHibikiPageState {
  // ── URL & Resource Serving (mirrors Hoshi Android's hoshi.local scheme) ──

  String _chapterUrl(int index) {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return 'about:blank';
    }
    return ReaderHibikiSource.epubUrl(_book!.chapters[index].href);
  }

  Future<void> _loadChapterDirectly(int index) async {
    final String url = _chapterUrl(index);
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

  static WebResourceResponse _notFound(String reason) {
    debugPrint('[ReaderHibiki] 404: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  static WebResourceResponse _forbidden(String reason) {
    debugPrint('[ReaderHibiki] 403: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 403,
      reasonPhrase: 'Forbidden',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  Future<WebResourceResponse?> _interceptRequest(WebUri url) async {
    if (url.host != ReaderHibikiSource.kHost) return null;
    final String path = url.path;

    if (path.startsWith('/fonts/')) {
      final String raw = path.substring('/fonts/'.length);
      final String fontPath = Uri.decodeComponent(raw);
      final String? safeFontPath = ReaderHibikiSource.safeCustomFontPath(
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
          '[ReaderHibiki] font served: $safeFontPath (${data.length} bytes)');
      final String mime = fallbackMimeType(safeFontPath);
      return WebResourceResponse(
        contentType: mime,
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
    final String filePath = p.canonicalize(p.join(_extractDir!, epubPath));
    if (!p.isWithin(p.canonicalize(_extractDir!), filePath)) {
      return _forbidden('path traversal blocked: $epubPath');
    }
    final File file = File(filePath);
    if (!file.existsSync()) {
      return _notFound('resource not found: $epubPath (resolved: $filePath)');
    }

    Uint8List data = await file.readAsBytes();
    final String mime = fallbackMimeType(filePath);

    if (mime == 'text/css') {
      data = _sanitizedCssCache.putIfAbsent(filePath, () {
        // HBK-AUDIT-118: tolerate non-UTF-8 CSS bytes instead of throwing.
        final String cssText = utf8.decode(data, allowMalformed: true);
        final String sanitized = ReaderResourceSanitizer.sanitizeCss(cssText);
        return Uint8List.fromList(utf8.encode(sanitized));
      });
    }

    if ((mime == 'text/html' || mime.contains('xhtml')) && _settings != null) {
      // BUG-270 (TODO-296 B): repeat chapter visits (forward/back paging,
      // prefetched chapters) reuse the sanitized + style-injected bytes from
      // the LRU cache instead of re-reading/decoding/sanitizing/injecting. The
      // cache is dropped on every style change (_invalidateStyleCache), so a
      // cached entry always carries the current styleTag.
      data = _chapterHtmlBytes(filePath, data);
    }

    return WebResourceResponse(
      contentType: mime,
      contentEncoding: mime.startsWith('text/') ? 'utf-8' : null,
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: <String, String>{
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache',
      },
      data: data,
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
    final Uint8List built = _buildSanitizedChapterHtmlBytes(rawData);
    _putChapterHtml(filePath, built);
    return built;
  }

  // BUG-270: insert into the LRU, evicting the least-recently-used entry when
  // over the size limit. LinkedHashMap preserves insertion order; the oldest key
  // is removed first.
  void _putChapterHtml(String filePath, Uint8List bytes) {
    _sanitizedHtmlCache.remove(filePath);
    _sanitizedHtmlCache[filePath] = bytes;
    while (_sanitizedHtmlCache.length >
        _ReaderHibikiPageState._kChapterHtmlCacheLimit) {
      _sanitizedHtmlCache.remove(_sanitizedHtmlCache.keys.first);
    }
  }

  // BUG-270: the sanitize + style-inject pipeline, extracted from
  // _interceptRequest so it can also run during prefetch. Decodes the raw
  // chapter bytes (UTF-8/BOM tolerant, HBK-AUDIT-118), normalizes self-closing
  // raw-text elements (BUG-079), injects the FOUC cloak + reader styleTag, and
  // returns the final UTF-8 bytes served to the WebView.
  Uint8List _buildSanitizedChapterHtmlBytes(Uint8List rawData) {
    String html = utf8.decode(rawData, allowMalformed: true);
    html = ReaderResourceSanitizer.sanitizeXhtml(html);
    final String styleTag = _buildStyleTag();
    const String hideUntilReady =
        '<style id="hoshi-cloak">body{visibility:hidden!important}</style>';
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

  // BUG-270: resolve the absolute on-disk path of chapter [index]'s XHTML, or
  // null when out of range / book not ready. Mirrors the path resolution in
  // _interceptRequest (extractDir + chapter href) so cache keys line up.
  String? _chapterFilePath(int index) {
    final EpubBook? book = _book;
    final String? dir = _extractDir;
    if (book == null || dir == null) return null;
    if (index < 0 || index >= book.chapters.length) return null;
    final String href = normalizeHref(book.chapters[index].href);
    final String filePath = p.canonicalize(p.join(dir, href));
    if (!p.isWithin(p.canonicalize(dir), filePath)) return null;
    return filePath;
  }

  // BUG-270: warm the LRU with the next chapter (in reading direction) so a
  // forward page-turn that crosses a chapter boundary hits the cache instead of
  // paying disk read + decode + sanitize + inject. Runs off the UI frame; skips
  // when already cached, already in flight, or settings/book not ready. Reads on
  // the main isolate (sanitizeXhtml is sync) but only one chapter at a time, and
  // the result is dropped if the page was disposed or styles changed meanwhile.
  void _prefetchAdjacentChapter(int index) {
    if (_settings == null) return;
    final String? filePath = _chapterFilePath(index);
    if (filePath == null) return;
    if (_sanitizedHtmlCache.containsKey(filePath)) return;
    if (_prefetchingHtmlPath == filePath) return;
    _prefetchingHtmlPath = filePath;
    scheduleMicrotask(() {
      try {
        if (!mounted || _settings == null) return;
        if (_sanitizedHtmlCache.containsKey(filePath)) return;
        final File file = File(filePath);
        if (!file.existsSync()) return;
        final Uint8List raw = file.readAsBytesSync();
        final Uint8List built = _buildSanitizedChapterHtmlBytes(raw);
        if (!mounted) return;
        _putChapterHtml(filePath, built);
      } catch (e, stack) {
        ErrorLogService.instance
            .log('ReaderHibiki._prefetchAdjacentChapter', e, stack);
      } finally {
        if (_prefetchingHtmlPath == filePath) {
          _prefetchingHtmlPath = null;
        }
      }
    });
  }

  static bool _isValidFontData(Uint8List data) => isValidFontData(data);

  static String _buildFuriganaJs(String mode) {
    switch (mode) {
      case 'partial':
        return '''
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
  }, true);''';
      case 'toggle':
        return '''
  document.addEventListener('dblclick', function() {
    var sel = window.getSelection();
    if (sel && !sel.isCollapsed) return;
    document.body.classList.toggle('show-all-rt');
  });''';
      default:
        return '';
    }
  }

  // ── Single IIFE setup script (mirrors Hoshi Android's readerSetupScript) ──

  String _buildReaderSetupScript({String? sasayakiCuesJson}) {
    final ReaderSettings s = _settings!;
    // TODO-113: 滑动翻页距离阈值随灵敏度系数缩放。基础值 72px（纯距离触发）/ 36px
    // （配合速度的快速短滑触发），系数 1.0 = 原手感，越大越迟钝（需滑得更远）。
    final ({int dist, int fastDist}) swipeThresholds =
        ReaderSettings.swipePageTurnDistThresholds(s.swipePageTurnSensitivity);
    final int swipeDistThreshold = swipeThresholds.dist;
    final int swipeFastDistThreshold = swipeThresholds.fastDist;
    // BUG-239: 连续模式靠原生滚动（滚动轴 = 书写轴），章间切换走边界手势 IIFE。
    // _gestureEnd 的 onSwipe（90% 整屏跳页）只在分页模式有意义；连续模式回传会与
    // 原生滚动产生轴向冲突，故注入 continuousMode 标志在 _gestureEnd 内门控。
    final bool continuousMode = s.isContinuousMode;
    // TODO-909 M0: VN blank-tap advance. hoshi default clickAdvance=false
    // (commit `42c0bab`); M0 force-enables the tap binding so the device Gate
    // can verify click-to-advance. M1 falls back to s.visualNovelClickAdvance.
    final bool vnMode = s.isVnMode;
    const bool vnClickAdvanceM0ForceOn = true; // M1: s.visualNovelClickAdvance
    final bool vnClickAdvance = vnMode && vnClickAdvanceM0ForceOn;
    // TODO-909 M0: reveal（打字渐显）是 M1 功能。在 M0 强制 revealSpeed=0，使每屏
    // renderScreen 即 revealComplete=true、paginate 只返 "scrolled"/"limit"。否则
    // revealSpeed>0 时新屏停在 revealComplete=false，forward 翻屏会命中 paginate 的
    // `if(!revealComplete) completeCurrentReveal(); return "revealed"` 分支，而
    // Dart 的 _didScroll（chrome.part.dart）只认 "scrolled" 为真 → 误判章节边界
    // 触发 _handlePageTurnLimit 跨章。M1 去掉本强制、改走 s.visualNovelRevealSpeed
    // 即可放开渐显。
    const int vnRevealSpeedM0ForceZero = 0; // M1: s.visualNovelRevealSpeed
    final int vnRevealSpeed = vnMode ? vnRevealSpeedM0ForceZero : 0;
    // TODO-756b：是否“鼠标悬停即自动查词”。注入为 JS 全局初值，mousemove 监听器
    // 据此跳过 Shift 门控（纯悬停查词）。live 变更经 _applyHoverAutoLookupLive
    // 改同一全局，无需整章重注入。
    final bool hoverAutoLookup = ReaderHibikiSource.instance.hoverAutoLookup;
    final String selectionJs = ReaderSelectionScripts.source();
    final Size screenSize = MediaQuery.of(context).size;
    // BUG-111: 这就是 JS 分页用的权威宽高（dartPageWidth/Height）。记下来作为
    // content-ready 后的「已分页基线」，供 _syncPageSize 与 settle 后的真实视口比对。
    _paginatedWidth = screenSize.width;
    _paginatedHeight = screenSize.height;
    final String paginationJs = _stripScriptTags(
      ReaderPaginationScripts.shellScript(
        initialProgress: _initialProgress,
        initialCharOffset: _initialCharOffset,
        continuousMode: s.isContinuousMode,
        // TODO-909: select the VN shell when view-mode == 'vn'. VN is mutually
        // exclusive with continuous (it is a page-flip stage, not native
        // scroll), so continuousMode stays false here.
        vnMode: s.isVnMode,
        fontSize: s.fontSize.round(),
        initialFragment: _initialFragment,
        sasayakiCuesJson: sasayakiCuesJson,
        chromeTopInset: _readerTopOffset,
        chromeBottomInset: _showChrome
            ? _readerChromeHeight + _stableBottomInset
            : _stableBottomInset,
        dartPageWidth: screenSize.width,
        dartPageHeight: screenSize.height,
        blurImages: s.blurImages,
        vnRevealSpeed: vnRevealSpeed,
        vnScreenMode: s.visualNovelScreenMode,
        vnSentencesPerScreen: s.visualNovelSentencesPerScreen,
        vnPreserveDialogue: s.visualNovelPreserveDialogueBubbles,
        vnMergeCrossScreenSasayakiCues:
            s.visualNovelMergeCrossScreenSasayakiCues,
      ),
    );

    final String furiganaJs = _buildFuriganaJs(s.furiganaMode);

    final String caretJs = ReaderCaretScripts.source();
    final double caretBottomInset = _showChrome
        ? _readerChromeHeight + _stableBottomInset
        : _stableBottomInset;
    final String caretInit = ReaderCaretScripts.initInvocation(
      color: _caretRingColorCss(),
      insetTop: _readerTopOffset,
      insetBottom: caretBottomInset,
    );

    return '''
(function() {
  window.scanNonJapaneseText = ${appModel.scanNonJapaneseText};
  $selectionJs
  $paginationJs
  $caretJs
  $caretInit;
  $furiganaJs
  // BUG-239: 连续模式不让 _gestureEnd 回传 onSwipe（交给原生滚动 + 边界 IIFE），
  // 消除横向滑动 90% 跳页与原生滚动的轴向冲突；分页模式照旧水平滑动翻页。
  var hoshiContinuousMode = $continuousMode;
  // TODO-909 M0: VN-mode blank-tap advance flag (see Dart above).
  var hoshiVnMode = $vnMode;
  var hoshiVnClickAdvance = $vnClickAdvance;
  window.__hoverAutoLookup = $hoverAutoLookup;
  var startX = 0, startY = 0, startTime = 0, hasStart = false;
  var imageLongPressTimer = null;
  var imageLongPressConsumed = false;
  var imageLongPressStartX = 0, imageLongPressStartY = 0;
  var _hoshiReaderMouseDragActive = false;
  var _hoshiReaderMouseDragClaimed = false;
  var _hoshiReaderMouseNativeTextStart = false;
  var _hoshiReaderMouseDragLastX = 0, _hoshiReaderMouseDragLastY = 0;
  var _hoshiReaderMouseDragPointerId = null;
  var _hoshiReaderMouseDragPageDirection = null;
  var _hoshiReaderMouseDragSwipeSent = false;
  var _hoshiReaderMouseDragIgnoreTouchEnd = false;
  function _gestureStart(x, y) { hasStart = true; startX = x; startY = y; startTime = Date.now(); }
  // TODO-909 M0: a VN tap is "blank" when caretRangeFromPoint resolves to no
  // text node (or an empty/whitespace one), i.e. the user tapped margin/gap
  // rather than a word. Text taps still go to onTap (word lookup).
  function _hoshiVnTapIsBlank(x, y) {
    try {
      var range = _hoshiReaderCaretRangeAtPoint(x, y);
      if (!range || !range.startContainer) return true;
      var node = range.startContainer;
      if (node.nodeType !== Node.TEXT_NODE) return true;
      return !String(node.textContent || '').trim();
    } catch (err) {
      return true;
    }
  }
  function _hoshiReaderCaretRangeAtPoint(x, y) {
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
  function _hoshiReaderClearMouseSelection() {
    try {
      var selected = window.getSelection && window.getSelection();
      if (selected && !selected.isCollapsed) selected.removeAllRanges();
    } catch (err) {}
  }
  function _hoshiReaderPointerPrimaryButton(e) {
    return e && (e.pointerType === 'touch' || e.button === 0);
  }
  function _hoshiReaderPointerStillDown(e) {
    return e && (e.pointerType === 'touch' || (e.buttons & 1) === 1);
  }
  // TODO-553: 触摸只在「连续模式」走 pointer 拖动状态机（8f095de78 的触摸拖滚）；
  // 分页模式下触摸交还给 touchstart/touchend → _gestureEnd → onSwipe 的滑动翻页路径
  // （890378f19 前的行为）。鼠标左键在两种模式都走 pointer 机（拖选/划词/拖动翻页）。
  function _hoshiReaderPointerEngages(e) {
    if (!_hoshiReaderPointerPrimaryButton(e)) return false;
    if (e.pointerType === 'touch') return hoshiContinuousMode;
    return true;
  }
  function _hoshiReaderPointerNoSelect(enabled) {
    try {
      var id = 'hoshi-reader-pointer-drag-style';
      var style = document.getElementById(id);
      if (!style) {
        style = document.createElement('style');
        style.id = id;
        style.textContent = '.hoshi-reader-pointer-dragging, .hoshi-reader-pointer-dragging *{-webkit-user-select:none!important;user-select:none!important;}';
        document.head.appendChild(style);
      }
      document.documentElement.classList.toggle('hoshi-reader-pointer-dragging', !!enabled);
    } catch (err) {}
  }
  function _hoshiReaderMouseDragStartAllowed(e) {
    if (!_hoshiReaderPointerPrimaryButton(e)) return false;
    var target = e.target || document.elementFromPoint(e.clientX, e.clientY);
    if (target && target.closest) {
      if (target.closest('a[href], ruby, rt, rp')) return false;
      if (target.closest('input, textarea, select, button, [contenteditable="true"], [data-hoshi-clk], #hoshi-caret-ring')) return false;
    }
    var selected = window.getSelection && window.getSelection();
    if (selected && !selected.isCollapsed) return false;
    // 砍掉 PC 鼠标左键拖动平移（连续模式）：鼠标左键回归原生选字/划词查词，连续模式
    // 桌面滚动改用滚轮。原来 return true 会让鼠标左键走 JS scrollBy 模拟平移——这是
    // 卡顿（每次 move 触发全文 progress 重算）+「鼠标拖动没到章首就跨章」的来源。
    // 分页模式仍走下方逻辑（鼠标拖动转翻页 BUG-368 不受影响）。
    if (hoshiContinuousMode) return false;
    if (window.hoshiSelection &&
        window.hoshiSelection.getCharacterAtPoint &&
        window.hoshiSelection.getCharacterAtPoint(e.clientX, e.clientY)) {
      return false;
    }
    return !_hoshiReaderCaretRangeAtPoint(e.clientX, e.clientY);
  }
  function _hoshiReaderMouseDragScrollBy(dx, dy) {
    // drag-to-pan「内容跟手」的方向与 writing-mode 无关：鼠标往右拖(dx>0)→内容往右移
    // →scrollLeft 减小→scrollBy({left: -dx})；鼠标往上拖(dy<0)→内容往上→scrollTop 增大
    // →scrollBy({top: -dy})。BUG-338: 旧实现给竖排加了 (vertical-rl ? -1 : 1) 的 sign
    // 翻符号，把 vertical-rl 写成 scrollBy({left: dx}) 致拖动方向反了；删掉该特殊情况。
    var r = window.hoshiReader;
    var vertical = !!(r && r.isVertical && r.isVertical());
    if (vertical) {
      window.scrollBy({left: -dx, top: 0, behavior: 'auto'});
    } else {
      window.scrollBy({left: 0, top: -dy, behavior: 'auto'});
    }
  }
  function _hoshiReaderMouseDragResolvePageDirection(x, y) {
    var dx = x - startX;
    var dy = y - startY;
    var elapsed = Date.now() - startTime;
    var absDx = Math.abs(dx);
    var absDy = Math.abs(dy);
    var velocity = absDx / Math.max(1, elapsed) * 1000;
    var horizontalEnough = absDx > absDy;
    var distanceEnough =
        absDx >= $swipeDistThreshold ||
        (absDx >= $swipeFastDistThreshold && velocity >= 900);
    if (horizontalEnough && distanceEnough) {
      return dx < 0 ? 'left' : 'right';
    }
    return null;
  }
  function _finishHoshiReaderMouseDrag(e) {
    var claimed = _hoshiReaderMouseDragClaimed;
    var direction = _hoshiReaderMouseDragPageDirection;
    _hoshiReaderMouseDragActive = false;
    _hoshiReaderMouseDragClaimed = false;
    _hoshiReaderMouseNativeTextStart = false;
    _hoshiReaderMouseDragPointerId = null;
    _hoshiReaderMouseDragPageDirection = null;
    _hoshiReaderPointerNoSelect(false);
    hasStart = false;
    if (!claimed) return false;
    if (e && e.preventDefault) e.preventDefault();
    if (!hoshiContinuousMode && direction) {
      if (_hoshiReaderMouseDragSwipeSent) return true;
      _hoshiReaderMouseDragSwipeSent = true;
      window.flutter_inappwebview.callHandler('onSwipe', direction);
    }
    return true;
  }
  // Resolve a block illustration under the tap to an absolute image URL, or
  // null when the tap isn't on one. Handles both raster <img> covers/figures
  // and fixed-layout EPUB <svg><image> covers (which are not IMG elements, so
  // their xlink:href must be resolved against document.baseURI).
  function _hoshiBlockImageUrl(target) {
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
  function _hoshiResolveBlockImageElement(target) {
    if (!target) return null;
    if ((target.tagName === 'IMG' || target.tagName === 'svg') && target.classList && target.classList.contains('block-img')) {
      return target;
    }
    var wrapper = target.closest ? target.closest('.block-img-wrapper') : null;
    if (!wrapper) return null;
    return wrapper.querySelector('img.block-img') || wrapper.querySelector('svg.block-img');
  }
  function _hoshiRevealBlurredImage(target) {
    var el = _hoshiResolveBlockImageElement(target);
    if (el && el.classList && el.classList.contains('blurred')) {
      el.classList.remove('blurred');
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
    var imgUrl = _hoshiBlockImageUrl(target);
    if (!imgUrl) return;
    e.preventDefault();
    window.flutter_inappwebview.callHandler(
      'onImageContextMenu',
      imgUrl,
      e.clientX || 0,
      e.clientY || 0
    );
  }, {passive: false});
  function _gestureEnd(x, y, e) {
    if (!hasStart) return;
    clearImageLongPressTimer();
    if (imageLongPressConsumed) {
      imageLongPressConsumed = false;
      hasStart = false;
      if (e && e.preventDefault) e.preventDefault();
      return;
    }
    hasStart = false;
    var dx = x - startX;
    var dy = y - startY;
    var elapsed = Date.now() - startTime;
    var absDx = Math.abs(dx);
    var absDy = Math.abs(dy);
    var velocity = absDx / Math.max(1, elapsed) * 1000;
    // BUG-239: 连续模式（hoshiContinuousMode）不在此回传 onSwipe——原生滚动沿书写轴
    // 翻屏，到边界由 onBoundarySwipe 跨章；此处的水平 onSwipe 只属分页模式。
    if (!hoshiContinuousMode && absDx > absDy && (absDx >= $swipeDistThreshold || (absDx >= $swipeFastDistThreshold && velocity >= 900))) {
      if (e && e.preventDefault) e.preventDefault();
      if (dx < 0) {
        window.flutter_inappwebview.callHandler('onSwipe', 'left');
      } else {
        window.flutter_inappwebview.callHandler('onSwipe', 'right');
      }
    } else if (absDx < 20 && absDy < 20 && elapsed < 500) {
      var tapEl = document.elementFromPoint(x, y);
      if (_hoshiRevealBlurredImage(tapEl)) {
        if (e && e.preventDefault) e.preventDefault();
        return;
      }
      var imgUrl = _hoshiBlockImageUrl(tapEl);
      if (imgUrl) {
        window.flutter_inappwebview.callHandler('onImageTap', imgUrl);
      } else if (hoshiVnMode && hoshiVnClickAdvance &&
          _hoshiVnTapIsBlank(x, y) &&
          window.hoshiReader && window.hoshiReader.paginate) {
        // TODO-909 M0: VN blank-tap advance. Only when the tap is NOT over
        // matchable text (so word lookup still wins on text). Mirrors hoshi a's
        // host binding blank-tap -> paginate("forward").
        if (e && e.preventDefault) e.preventDefault();
        window.hoshiReader.paginate('forward');
      } else {
        // TODO-806 [806-TAP] 框选点击坐标取证探针（默认 off，由 DebugLogService 门控
        // 注入：${DebugLogService.instance.enabled} 为 false 时整段不进 JS）。打印 onTap
        // 实际回传的点击坐标，口径=WebView CSS 视口像素（e.clientX/clientY），**不是** OS
        // 屏幕坐标——差一个 devicePixelRatio + 页面在屏内的偏移。用户曾把 [792-REVEAL]
        // 的 WebView 内部滚动几何探针误当框选坐标，这条标明口径以正本清源。走 console.log
        // → onConsoleMessage → debugPrint → DebugLogService 环形缓冲，与 [792-REVEAL] 同管道。
        if (${DebugLogService.instance.enabled}) {
          try {
            console.log('[806-TAP] clientX=' + x + ' clientY=' + y
              + ' shift=' + !!(e && e.shiftKey)
              + ' dpr=' + window.devicePixelRatio
              + ' scrollX=' + window.scrollX + ' scrollY=' + window.scrollY);
          } catch (err) {}
        }
        window.flutter_inappwebview.callHandler('onTap', x, y, !!(e && e.shiftKey));
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
    var imgUrl = _hoshiBlockImageUrl(e.target || document.elementFromPoint(t.clientX, t.clientY));
    if (!imgUrl) return;
    imageLongPressStartX = t.clientX;
    imageLongPressStartY = t.clientY;
    imageLongPressTimer = setTimeout(function() {
      imageLongPressTimer = null;
      imageLongPressConsumed = true;
      // TODO-861④：长按仍带 `blurred` 类的防剧透图时，先揭开（移除类）并吞掉本次——
      // 与单击（_gestureEnd）/键盘·手柄激活（reader_caret_scripts.dart）语义一致：
      // 「揭开优先」，揭开后再长按才弹出图片操作菜单。复用同一 _hoshiRevealBlurredImage。
      var pressEl = document.elementFromPoint(imageLongPressStartX, imageLongPressStartY);
      if (_hoshiRevealBlurredImage(pressEl)) return;
      window.flutter_inappwebview.callHandler('onImageLongPress', imgUrl);
    }, 550);
  }, {passive: true});
  document.addEventListener('touchmove', function(e) {
    if (!imageLongPressTimer || !e.touches || !e.touches.length) return;
    var t = e.touches[0];
    var dx = t.clientX - imageLongPressStartX;
    var dy = t.clientY - imageLongPressStartY;
    if ((dx * dx + dy * dy) > 144) clearImageLongPressTimer();
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    if (_hoshiReaderMouseDragIgnoreTouchEnd) {
      _hoshiReaderMouseDragIgnoreTouchEnd = false;
      if (e && e.preventDefault) e.preventDefault();
      return;
    }
    var t = e.changedTouches[0]; _gestureEnd(t.clientX, t.clientY, e);
  }, {passive: false});
  document.addEventListener('touchcancel', function(e) {
    clearImageLongPressTimer();
    imageLongPressConsumed = false;
    _hoshiReaderMouseDragIgnoreTouchEnd = false;
    hasStart = false;
  }, {passive: true});
  document.addEventListener('pointerdown', function(e) {
    if (!_hoshiReaderPointerEngages(e)) return;
    _hoshiReaderMouseDragActive = _hoshiReaderMouseDragStartAllowed(e);
    _hoshiReaderMouseDragClaimed = false;
    _hoshiReaderMouseNativeTextStart = !_hoshiReaderMouseDragActive;
    _hoshiReaderMouseDragLastX = e.clientX;
    _hoshiReaderMouseDragLastY = e.clientY;
    _hoshiReaderMouseDragPointerId = e.pointerId;
    _hoshiReaderMouseDragPageDirection = null;
    _hoshiReaderMouseDragSwipeSent = false;
    _gestureStart(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointermove', function(e) {
    // TODO-553: pointermove 的 button 恒 -1，不能用 _hoshiReaderPointerEngages
    // （它查 button===0）；分页模式触摸只需在此直接放行回 touch swipe 路径。
    if (e.pointerType === 'touch' && !hoshiContinuousMode) return;
    if (_hoshiReaderMouseDragPointerId !== null && e.pointerId !== _hoshiReaderMouseDragPointerId) return;
    if (!_hoshiReaderPointerStillDown(e) || !hasStart) return;
    var totalDx = e.clientX - startX;
    var totalDy = e.clientY - startY;
    var totalDistSq = totalDx * totalDx + totalDy * totalDy;
    if (_hoshiReaderMouseNativeTextStart) {
      // BUG-368: 分页模式下，鼠标在正文上横向拖动应像手机端的「触摸横滑」一样翻页。
      // 旧实现里鼠标拖动起点落在正文（caret range 命中）时一律当作原生选词起点
      // （_hoshiReaderMouseNativeTextStart），移动 >6px 就放弃手势交还原生选区，
      // 永不回传 onSwipe → 桌面鼠标在分页模式根本「翻不了页」（只有空白边距能拖、
      // 或全靠滚轮）。触摸路径（touchend→_gestureEnd）早已能在正文上横滑翻页，鼠标
      // 却被这道闸门挡住，造成「鼠标 ≠ 手机」的不对称。这里在仍是分页模式时，先判
      // 定这次拖动是否已构成一次明确的横向翻页手势（横向位移占优且达滑动阈值，与
      // _hoshiReaderMouseDragResolvePageDirection / _gestureEnd 同款判据）：是→把
      // 本次手势从「原生选词」转换为「拖动翻页」（清掉已起的选区、接管 pointer、
      // 后续走 _finishHoshiReaderMouseDrag 回传 onSwipe）；否→保持原行为（竖向/短拖
      // 交还原生选区，仍可正常划词查词）。
      var ntDir = (!hoshiContinuousMode)
          ? _hoshiReaderMouseDragResolvePageDirection(e.clientX, e.clientY)
          : null;
      if (ntDir) {
        _hoshiReaderMouseNativeTextStart = false;
        _hoshiReaderMouseDragActive = true;
        _hoshiReaderMouseDragClaimed = true;
        _hoshiReaderMouseDragPageDirection = ntDir;
        _hoshiReaderPointerNoSelect(true);
        _hoshiReaderClearMouseSelection();
        if (e.target && e.target.setPointerCapture) {
          try { e.target.setPointerCapture(e.pointerId); } catch (err) {}
        }
        e.preventDefault();
        return;
      }
      if (totalDistSq > 36) hasStart = false;
      return;
    }
    if (!_hoshiReaderMouseDragActive) return;
    if (!_hoshiReaderMouseDragClaimed) {
      if (totalDistSq < 36) return;
      _hoshiReaderMouseDragClaimed = true;
      if (e.pointerType === 'touch') _hoshiReaderMouseDragIgnoreTouchEnd = true;
      _hoshiReaderPointerNoSelect(true);
      _hoshiReaderClearMouseSelection();
      if (e.target && e.target.setPointerCapture) {
        try { e.target.setPointerCapture(e.pointerId); } catch (err) {}
      }
    }
    var dx = e.clientX - _hoshiReaderMouseDragLastX;
    var dy = e.clientY - _hoshiReaderMouseDragLastY;
    _hoshiReaderMouseDragLastX = e.clientX;
    _hoshiReaderMouseDragLastY = e.clientY;
    if (hoshiContinuousMode) {
      _hoshiReaderMouseDragScrollBy(dx, dy);
    } else {
      _hoshiReaderMouseDragPageDirection =
          _hoshiReaderMouseDragResolvePageDirection(e.clientX, e.clientY);
    }
    e.preventDefault();
  }, {passive: false});
  document.addEventListener('pointerup', function(e) {
    if (!_hoshiReaderPointerEngages(e)) return;
    if (_hoshiReaderMouseDragPointerId !== null && e.pointerId !== _hoshiReaderMouseDragPointerId) return;
    if (_hoshiReaderMouseDragClaimed) {
      if (!hoshiContinuousMode && !_hoshiReaderMouseDragPageDirection) {
        _hoshiReaderMouseDragPageDirection =
            _hoshiReaderMouseDragResolvePageDirection(e.clientX, e.clientY);
      }
      _finishHoshiReaderMouseDrag(e);
      return;
    }
    if (_hoshiReaderMouseNativeTextStart) {
      var nativeDx = e.clientX - startX;
      var nativeDy = e.clientY - startY;
      var nativeMoved = (nativeDx * nativeDx + nativeDy * nativeDy) > 36;
      var nativeSelection = window.getSelection && window.getSelection();
      var hasNativeSelection = nativeSelection && !nativeSelection.isCollapsed;
      _hoshiReaderMouseNativeTextStart = false;
      _hoshiReaderMouseDragActive = false;
      _hoshiReaderMouseDragPointerId = null;
      _hoshiReaderMouseDragPageDirection = null;
      _hoshiReaderPointerNoSelect(false);
      if (nativeMoved || hasNativeSelection) {
        hasStart = false;
        return;
      }
    } else {
      _hoshiReaderMouseDragActive = false;
      _hoshiReaderMouseDragPointerId = null;
      _hoshiReaderMouseDragPageDirection = null;
      _hoshiReaderPointerNoSelect(false);
    }
    _gestureEnd(e.clientX, e.clientY, e);
  }, {passive: false});
  document.addEventListener('pointercancel', function(e) {
    if (e.pointerType === 'touch' && !hoshiContinuousMode) return;
    if (_hoshiReaderMouseDragPointerId !== null && e.pointerId !== _hoshiReaderMouseDragPointerId) return;
    _hoshiReaderMouseDragActive = false;
    _hoshiReaderMouseDragClaimed = false;
    _hoshiReaderMouseNativeTextStart = false;
    _hoshiReaderMouseDragPointerId = null;
    _hoshiReaderMouseDragPageDirection = null;
    _hoshiReaderPointerNoSelect(false);
    hasStart = false;
  }, {passive: true});
  // 非左键（中键/侧键）：上报 Dart，由 resolveMouse 判定是否绑定「seek 到点击句」。
  // mousedown 一定触发，preventDefault 压掉中键自动滚动。触屏合成事件 button 恒 0，
  // 被首行排除，不干扰触摸手势。
  document.addEventListener('mousedown', function(e) {
    if (e.button === 0) return;
    if (e.button === 2 && _hoshiBlockImageUrl(e.target || document.elementFromPoint(e.clientX, e.clientY))) {
      return;
    }
    e.preventDefault();
    window.flutter_inappwebview.callHandler('onPointerSeek', e.button, e.clientX, e.clientY);
  }, {passive: false});
  document.addEventListener('selectstart', function(e) {
    if (hasStart && !_hoshiReaderMouseNativeTextStart && (Date.now() - startTime) < 400) e.preventDefault();
  });
  // BUG-369: 滚动模式滚轮跨章的「arm-then-fire 二次确认」状态——记上一次已武装
  // 的边界方向（null=未武装）。惯性/竖排缓动擦边的单次瞬态只武装、不跨章；同方向
  // 再来一次才真正跨章，消除「还没到章首就切上一章」。与纯函数
  // ReaderPaginationScripts.continuousWheelBoundaryEmit 同款语义。
  var _wheelBoundaryArmed = null;
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
    var r = window.hoshiReader;
    if (hoshiContinuousMode) {
      // TODO-345: 横排连续滚动轴 = 纵向（与桌面鼠标滚轮的 deltaY 默认轴一致），
      // 放行原生滚动即可顺滑滚动。竖排连续滚动轴 = 横向（CSS overflow-x 可滚、
      // overflow-y:hidden），但桌面鼠标滚轮只产生 deltaY、不产生 deltaX，浏览器
      // 不会把垂直滚轮可靠地映射到横向可滚轴 → 竖排连续模式滚轮滚不动。故竖排
      // 显式把滚轮的主 delta 投影到横向 scrollBy（沿真实书写轴），方向与
      // hoshiReader.paginate 一致（vertical-rl forward 往左 = scrollLeft 减小）。
      // TODO-627: 连续模式滚轮原本只放行/投影原生滚动，到章末/章首滚不出去（边界
      // 跨章原本只有触摸/指针的边界 IIFE 走 onBoundarySwipe，滚轮无此通道）。这里
      // 补滚轮的跨章通道：仅当原生滚动已到该内容轴尽头才回传 onBoundarySwipe，复用
      // 边界 IIFE 同款 atStart/atEnd 判定与 _handlePageTurnLimit；未到底仍放行/投影
      // 正常滚动，不打断滚动手感。统一手势纯谓词 continuousWheelBoundaryDirection。
      var root = document.scrollingElement || document.documentElement;
      var vertical = r && r.isVertical && r.isVertical();
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
      // 诊断：仅在「滚不动」或「已武装」时打印，供真机定位为何不动（同时打 window.scrollX 与
      // root.scrollLeft，看哪个真的跟随滚动）。
      if (!moved || _wheelBoundaryArmed) {
        console.log('[xchapter] wheel vertical=' + (vertical ? 1 : 0)
          + ' wheelDelta=' + Math.round(wheelDelta) + ' wheelDir=' + wheelDir
          + ' before=' + Math.round(before) + ' after=' + Math.round(after)
          + ' moved=' + (moved ? 1 : 0) + ' armed=' + _wheelBoundaryArmed
          + ' winX=' + Math.round(window.scrollX) + ' winY=' + Math.round(window.scrollY)
          + ' rootL=' + Math.round(root.scrollLeft) + ' rootT=' + Math.round(root.scrollTop)
          + ' scrollW=' + root.scrollWidth + ' innerW=' + window.innerWidth);
      }
      if (moved) {
        // 真的滚动了 = 没到边界，不跨章；解武装。
        _wheelBoundaryArmed = null;
        return;
      }
      // 真的滚不动了 = 到边界 → arm-then-fire 二次确认（吸收单次擦边）才跨章。
      // TODO-737: 节流闸门已统一到 Dart 侧（onBoundarySwipe handler 的 _lastPaginateTime
      // 时间戳），JS 不再自持 _wheelTimer。arm-then-fire 二次确认（_wheelBoundaryArmed）
      // 才是防 BUG-369 擦边误跨章的防线，与节流无关、完整保留。
      if (_wheelBoundaryArmed === wheelDir) {
        _wheelBoundaryArmed = null;
        window.flutter_inappwebview.callHandler('onBoundarySwipe', wheelDir);
      } else {
        _wheelBoundaryArmed = wheelDir;
      }
      return;
    }
    if (!r || !('paginationMetrics' in r)) return;
    // TODO-737: 分页滚轮方向脱钩 invertSwipeDirection——改回传新 handler onWheelPaginate
    // 产「语义意图」(forward/backward)，方向 deltaY>0=forward 对齐连续滚轮(沿书写轴
    // delta>0=前进)，不再经 onSwipe 被 invertSwipeDirection(默认 true) 连坐反向。
    // 节流统一到 Dart 侧 _paginate 入口时间戳闸门（throttleMs: wheelPageTurnInterval），
    // JS 不再自持 _wheelTimer。invertSwipeDirection 从此只管触摸滑动 / 鼠标拖动。
    var forward = (e.deltaY > 0 || e.deltaX > 0);
    window.flutter_inappwebview.callHandler('onWheelPaginate', forward ? 'forward' : 'backward');
    e.preventDefault();
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
  window.hoshiProgressDetails = function() {
    var r = window.hoshiReader;
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
    if (total <= 0) return '';
    // BUG-162: 第三段 = section 内精确绝对字符偏移（视口首字符），落 DB char_offset
    // 作退出再进的恢复锚（成熟 getFirstVisibleCharOffset/scrollToCharOffset 路径）。
    // caretRangeFromPoint 失败时返 -1 → Dart 当「无精确偏移」回退分数。
    var off = (typeof r.getFirstVisibleCharOffset === 'function')
        ? r.getFirstVisibleCharOffset() : -1;
    return Math.round(p * total) + ',' + total + ',' + off;
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
  // 未返回不再发起下一次），避免高频上报把较重的 hoshiProgressDetails 调用堆积。
  (function() {
    var _progressScrollRaf = 0;
    var _progressScrollTimer = null;
    // TODO-718（回退式根治·2026-06-25）：原 userDriven 时间戳打点整套已删——它喂的是 798
    // 启发式拦截器（已删），且真机恒真致拦截器失效、与原始 _reanchorPending 机制打架。
    // 抗自发 reflow 归零回到干净的源头屏蔽：reflow 归零的 scroll 在重锚期被 `_reanchorPending`
    // 旗在此 return 挡掉、永不回传落库（见下方）。无需再区分「是否用户驱动」。
    function _reportReaderScroll() {
      var r = window.hoshiReader;
      // TODO-151/164 / BUG-225 诊断：默认 off（${DebugLogService.instance.enabled}
      // 由 DebugLogService 门控注入），开了才打印。reanchorPending=true 会早返回不回传，
      // hasBridge=false 说明 callHandler 不可用——便于真机定位「滚动了但进度没动」哪一链断。
      // console.log 经 onConsoleMessage → debugPrint → DebugLogService 环形缓冲。
      if (${DebugLogService.instance.enabled}) {
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
  var cloak = document.getElementById('hoshi-cloak');
  if (cloak) cloak.remove();
})();
''';
  }

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
    // the InAppWebView itself for the integration-test finders (hoshi_webview).
    final Widget webView = InAppWebView(
      key: const ValueKey<String>('hoshi_webview'),
      // TODO-954：Windows 的文字选区右键改用 Flutter 菜单（`_showReaderTextContextMenu`，
      // 经 GestureDetector.onSecondaryTapDown 触发），它在 HibikiAppUiScale 内能跟随界面
      // 大小缩放；故 Windows 下禁掉平台原生 WebView2 菜单（它不在 Flutter 树里、永远不
      // 缩放）。移动端无 onSecondaryTapDown，仍走原生 ContextMenu（查词 + 导出）。
      contextMenu: isWindowsPlatform
          ? ContextMenu(
              settings: ContextMenuSettings(
                hideDefaultSystemContextMenuItems: true,
              ),
              menuItems: const [],
            )
          : ContextMenu(
              settings: ContextMenuSettings(
                hideDefaultSystemContextMenuItems: false,
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
                    await searchDictionaryResult(
                      searchTerm: text,
                      selectionRect: rect,
                    );
                  },
                ),
                // TODO-954：移动端选区右键也提供「导出片段」，与 Windows 一致都从选区
                // 触发；handler 内部判 hasCue/音频，无音频时走 noAudio 兜底 toast。
                ContextMenuItem(
                  id: 2,
                  title: t.audiobook_export_clip,
                  action: () async {
                    await _exportAudiobookClipFromSelection();
                  },
                ),
              ],
            ),
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source:
              'window.onerror=function(m,s,l,c,e){console.error("__HIBIKI_JS_ERROR__ "+m+" at "+s+":"+l+":"+c);return false;};',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
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
        useShouldInterceptRequest: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        assert(() {
          assert(
            ReaderHibikiPage.debugEvaluateJavascript == null,
            'debugEvaluateJavascript already set — a previous reader did not '
            'clear it on dispose, or two readers are live at once.',
          );
          ReaderHibikiPage.debugEvaluateJavascript =
              (String source) => controller.evaluateJavascript(source: source);
          ReaderHibikiPage.debugCaretSurface = () => _caretSurface.name;
          ReaderHibikiPage.debugEvaluateTopPopup =
              (String source) async => _webviewTopPopupState?.debugEval(source);
          ReaderHibikiPage.debugInjectAudiobookBridge = () =>
              AudiobookBridge.inject(controller,
                  primaryColor: _themeSasayakiColor());
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
          _lyricsEntryCueIndex = allCues.isNotEmpty
              ? _audiobookController!.allBookCueIdx
              : _audiobookController!.currentCueIdx;
          _loadLyricsPage();
        } else {
          _restoreInFlight = true;
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
                  .log('ReaderHibiki.onTextSelected', e, stack);
              debugPrint('[ReaderHibiki] onTextSelected error: $e');
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onRestoreComplete',
          callback: (_) => _onRestoreComplete(),
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
              _reclaimReaderFocusAfterGesture();
              return;
            }
            if (!shiftKey && !ReaderHibikiSource.instance.highlightOnTap) {
              // Tap consumed without a selection/popup — reclaim reader focus.
              _reclaimReaderFocusAfterGesture();
              return;
            }
            final double x = _ReaderHibikiPageState._toDouble(args[0]) ?? 0;
            final double y = _ReaderHibikiPageState._toDouble(args[1]) ?? 0;
            // Selection → onTextSelected → popup, which takes focus itself; do
            // not reclaim here or we would fight the popup for focus.
            _selectTextAt(x, y);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onShiftHover',
          callback: (args) {
            if (args.length < 2) return;
            // TODO-851「限一级弹窗」：已有可见弹窗时悬停不再查词，保证 hover 最多
            // 叠一层（不在已有弹窗之上再起查词）。两个 hover 入口都要门控
            // （另一处见 reader_hibiki_page.dart onDismissBarrierHover）。
            if (isDictionaryShown) return;
            final double x = _ReaderHibikiPageState._toDouble(args[0]) ?? 0;
            final double y = _ReaderHibikiPageState._toDouble(args[1]) ?? 0;
            // TODO-851：悬停路径传 fromHover:true，命中空白不触发 onTapEmpty。
            _selectTextAt(x, y, fromHover: true);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTapEmpty',
          callback: (_) {
            if (ReaderHibikiSource.instance.tapEmptyToHideChrome) {
              _toggleChrome();
            }
            // Tap on empty space handed OS focus to the WebView; reclaim it so
            // ESC still exits the book afterward (BUG-136).
            _reclaimReaderFocusAfterGesture();
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onSwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _lyricsMode) return;
            // The swipe/wheel gesture handed OS focus to the WebView; reclaim it
            // so ESC still exits the book after a page turn (BUG-136).
            _reclaimReaderFocusAfterGesture();
            final String dir = args[0] as String;
            final bool invert =
                ReaderHibikiSource.instance.invertSwipeDirection;
            if (dir == 'left') {
              _paginate(invert
                  ? ReaderNavigationDirection.backward
                  : ReaderNavigationDirection.forward);
            } else if (dir == 'right') {
              _paginate(invert
                  ? ReaderNavigationDirection.forward
                  : ReaderNavigationDirection.backward);
            }
          },
        );

        // TODO-737: 分页滚轮翻页专用 handler。JS 已把滚轮方向归一成「语义意图」
        // (forward/backward·deltaY>0=forward 对齐连续滚轮)，这里**不读
        // invertSwipeDirection**（该开关从此只管触摸滑动 / 鼠标拖动，不管滚轮），
        // 直接映射成 _paginate 的导航方向。节流统一走 _paginate 入口时间戳闸门
        // （throttleMs: wheelPageTurnInterval），不再依赖 JS _wheelTimer。
        controller.addJavaScriptHandler(
          handlerName: 'onWheelPaginate',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _lyricsMode) return;
            _reclaimReaderFocusAfterGesture();
            final String dir = args[0] as String;
            final int throttleMs =
                ReaderHibikiSource.instance.wheelPageTurnInterval;
            if (dir == 'forward') {
              _paginate(ReaderNavigationDirection.forward,
                  throttleMs: throttleMs);
            } else if (dir == 'backward') {
              _paginate(ReaderNavigationDirection.backward,
                  throttleMs: throttleMs);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onBoundarySwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _lyricsMode) return;
            // Boundary swipe → chapter turn also stole focus to the WebView
            // (BUG-136); reclaim it so ESC keeps exiting after a chapter flip.
            _reclaimReaderFocusAfterGesture();
            final String dir = args[0] as String;
            // TODO-737 节流分流（4 必补点 #1）：连续滚轮跨章直接调
            // _handlePageTurnLimit、**绕过 _paginate 入口闸门**，否则归一节流后连续
            // 滚轮跨章不受任何节流。这里就地用与 _paginate 同款 _lastPaginateTime
            // 时间戳闸门拦绕过路径；闸门只放这一处（不放 _handlePageTurnLimit 本体），
            // 故分页跨章经 _paginate 内部调 _handlePageTurnLimit 时不会被自己盖的戳
            // 吞掉（章末翻得过去）。
            final int throttleMs =
                ReaderHibikiSource.instance.wheelPageTurnInterval;
            if (throttleMs > 0 && _lastPaginateTime != null) {
              final int elapsedMs =
                  DateTime.now().difference(_lastPaginateTime!).inMilliseconds;
              if (elapsedMs < throttleMs) return;
            }
            // BUG-369/TODO-656 诊断：跨章手势汇合点（滚轮/触摸/指针都经此）。
            debugPrint('[xchapter] onBoundarySwipe dir=$dir '
                'chapter=$_currentChapter');
            if (dir == 'forward') {
              _handlePageTurnLimit('forward');
            } else if (dir == 'backward') {
              _handlePageTurnLimit('backward');
            }
            if (throttleMs > 0) {
              _lastPaginateTime = DateTime.now();
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageDetected',
          callback: (_) => _audiobookController?.triggerImagePause(),
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageTap',
          callback: (args) {
            if (args.isEmpty) return;
            _openImageViewer(args[0] as String);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageContextMenu',
          callback: (args) async {
            if (args.isEmpty) return;
            final double x = args.length > 1
                ? (_ReaderHibikiPageState._toDouble(args[1]) ?? 0)
                : 0;
            final double y = args.length > 2
                ? (_ReaderHibikiPageState._toDouble(args[2]) ?? 0)
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
              // TODO-700 T3：spread 内容就绪确定性落焦到正文（门控见 helper）。
              _settleFocusOnContentReady();
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
            if (args.length < 3 || _audiobookController == null) return;
            final int button = (args[0] as num?)?.toInt() ?? -1;
            if (!isSeekToClickedSentenceButton(
                appModel.shortcutRegistry, button)) {
              return;
            }
            final double x = _ReaderHibikiPageState._toDouble(args[1]) ?? 0;
            final double y = _ReaderHibikiPageState._toDouble(args[2]) ?? 0;
            await _seekToClickedSentence(x, y);
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
      },
      shouldInterceptRequest: (controller, request) async {
        return await _interceptRequest(request.url);
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final String url = action.request.url?.toString() ?? '';
        if (_isNavigatingToChapter) {
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
        final int chapterSnapshot = _currentChapter;
        debugPrint('[ReaderHibiki] onLoadStop: url=$url '
            'chapter=$chapterSnapshot progress=$_initialProgress');
        if (_lyricsMode) {
          await _onChapterLoadComplete(controller);
          return;
        }
        final String expectedUrl = _chapterUrl(chapterSnapshot);
        if (url != null &&
            Uri.parse(url.toString()).path != Uri.parse(expectedUrl).path) {
          debugPrint(
              '[ReaderHibiki] onLoadStop: stale page (expected=$expectedUrl), ignoring');
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
          debugPrint('[ReaderHibiki] WebView creation failed: '
              '${error.description}');
          ErrorLogService.instance.log(
              'ReaderHibiki.onWebViewCreationFailed', error.description, null);
          if (!mounted) return;
          HibikiToast.show(msg: t.reader_open_failed);
          Navigator.of(context).pop();
          return;
        }
        if (request.isForMainFrame ?? false) {
          debugPrint('[ReaderHibiki] onReceivedError: ${error.description} '
              'url=${request.url}');
          // Windows 拦截域 (hoshi.local) 的 NavigationCompleted 假失败已在 fork
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
    );
    // KeyedSubtree carries [_webViewKey] (a GlobalKey) on the InAppWebView's own
    // render subtree so [onDismissBarrierHover] can read the WebView's RenderBox
    // for global→local coordinate mapping (TODO-806), while the ValueKey stays on
    // the InAppWebView itself for the integration-test finders (hoshi_webview).
    final Widget keyed = KeyedSubtree(key: _webViewKey, child: webView);
    // TODO-954：Windows 文字选区右键。`HitTestBehavior.translucent` 让左键框选 / 滚动 /
    // 查词点击照常落进 WebView（与 dictionary_popup_webview 的 BUG-261 范式同），只额外
    // 截右键（onSecondaryTapDown）弹出 Flutter 菜单——后者随界面大小缩放。
    if (!isWindowsPlatform) return keyed;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (TapDownDetails details) {
        _showReaderTextContextMenu(details.globalPosition);
      },
      child: keyed,
    );
  }

  Future<void> _onChapterLoadComplete(InAppWebViewController controller) async {
    if (_lyricsMode) {
      if (!_readerContentReady) {
        // BUG-438 / TODO-889：歌词模式内容就绪，清兜底 deadline，下次导航拿新窗口。
        _clearContentReadyTimeout();
        _rebuild(() {
          _readerContentReady = true;
          _hasEverLoaded = true;
        });
      }
      _lyricsPageReady = true;
      // 注入歌词专用行级 caret（键盘/手柄逐词查词），镜像 reader 的 hoshiCaret 注入。
      // 文档刚加载，caret inactive；surface 在 _enterCaret 成功时才置 lyrics。
      await controller.evaluateJavascript(
          source: ReaderLyricsCaretScripts.source());
      if (mounted) {
        await controller.evaluateJavascript(
          source: ReaderLyricsCaretScripts.initInvocation(
            color: _caretRingColorCss(),
            insetTop: _readerTopOffset,
            insetBottom: 0,
          ),
        );
      }
      _onCueChanged();
      await _applyLyricsFavorites();
      return;
    }
    final int gen = _navigateGeneration;
    final int chapterSnapshot = _currentChapter;
    try {
      String? sasayakiCuesJson;
      if (_audiobookController != null) {
        sasayakiCuesJson = await _prepareSasayakiCuesJson();
      }
      if (_currentChapter != chapterSnapshot || _navigateGeneration != gen) {
        return;
      }
      await controller.evaluateJavascript(
        source: _buildReaderSetupScript(sasayakiCuesJson: sasayakiCuesJson),
      );
      if (!mounted || _navigateGeneration != gen) return;

      // The setup script rebuilds window.hoshiCaret fresh (inactive). If the
      // reading cursor was on the reader, restore it on the new chapter's first
      // page. (If it's on a popup, the reader ring is already hidden — leave it.)
      if (_caretOnReader) {
        await _caretReanchor(ReaderNavigationDirection.forward);
        if (!mounted || _navigateGeneration != gen) return;
      }

      _initialFragment = null;
      if (_audiobookController != null) {
        await _injectAudiobookBridge();
      }
      if (!mounted || _navigateGeneration != gen) return;
      await HighlightBridge.inject(controller);
      await _applyChapterHighlights();
      if (!mounted || _navigateGeneration != gen) return;
      // BUG-111: 基线取「JS 实际分页用的尺寸」(_paginatedWidth/Height)，不是当前
      // MediaQuery——这样后续 resize 才与真正生效的版面宽度比对。
      _lastSyncedWidth = _paginatedWidth;
      _lastSyncedHeight = _paginatedHeight;
      // BUG-270 (TODO-296 B): warm the next chapter so a forward boundary
      // page-turn hits the LRU cache instead of disk read + decode + sanitize +
      // inject. Background, single chapter, dropped if disposed/style-changed.
      _prefetchAdjacentChapter(chapterSnapshot + 1);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._onChapterLoadComplete', e, stack);
      debugPrint('[ReaderHibiki] _onChapterLoadComplete failed: $e');
    }
  }
}
