import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/reading_time_tracker.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';
import 'package:hibiki/src/media/audiobook/reader_position_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_resource_sanitizer.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/misc/jidoujisho_text_selection.dart';
import 'package:wakelock/wakelock.dart';

class ReaderHoshiPage extends BaseSourcePage {
  const ReaderHoshiPage({
    super.item,
    required this.bookId,
    this.initialBookmarkJump,
    super.key,
  });

  final int bookId;
  final Bookmark? initialBookmarkJump;

  @override
  BaseSourcePageState<ReaderHoshiPage> createState() =>
      _ReaderHoshiPageState();
}

class _ReaderHoshiPageState extends BaseSourcePageState<ReaderHoshiPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  EpubBook? _book;
  ReaderSettings? _settings;
  String? _extractDir;

  int _currentChapter = 0;
  bool _readerContentReady = false;
  bool _restoreInFlight = false;
  double _initialProgress = 0.0;
  String? _initialFragment;

  double _stableTopInset = 0;
  double _stableBottomInset = 0;
  static const double _topProgressBarHeight = 36;
  static const double _readerChromeHeight = 56;

  int? _progressCurrentChars;
  int? _progressTotalChars;

  Timer? _saveDebounce;
  int _lastSavedSection = -1;
  double _lastSavedProgress = -1;

  AudiobookPlayerController? _audiobookController;
  bool _hasAudioSlot = false;
  bool _audioSlotResolved = false;

  ReadingTimeTracker? _readingTimeTracker;

  bool _showChrome = true;

  final FocusNode _focusNode = FocusNode();

  bool get _showTopProgress =>
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0;

  double get _readerTopOffset =>
      _stableTopInset + (_showTopProgress ? _topProgressBarHeight : 0);

  double get _readerBottomReserve =>
      (_showChrome ? _readerChromeHeight : 0) + _stableBottomInset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initBook();
  }

  Future<void> _initBook() async {
    final HibikiDatabase db = appModel.database;
    _settings = ReaderSettings(db);

    final bool exists = await EpubStorage.bookExists(widget.bookId);
    if (!exists) {
      debugPrint('[ReaderHoshi] book ${widget.bookId} not found on disk');
      if (mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    final String extractDir =
        await EpubStorage.bookDirectory(widget.bookId);
    _extractDir = extractDir;

    try {
      _book = EpubParser.parseFromExtracted(extractDir);
      debugPrint('[ReaderHoshi] parsed EPUB: ${_book!.chapters.length} chapters');
    } on FormatException catch (e) {
      debugPrint('[ReaderHoshi] EPUB parse failed ($e), using legacy mode');
      _book = _buildLegacyBook(extractDir);
    }

    final List<String> hrefs =
        _book!.chapters.map((EpubChapter ch) => ch.href).toList();
    debugPrint('[ReaderHoshi] chapter hrefs: $hrefs');

    await _resolveAudioSlot();

    final ReaderPositionRepository repo =
        ReaderPositionRepository(appModel.database);
    final ReaderPosition? saved = await repo.findByTtuBookId(widget.bookId);
    if (saved != null &&
        saved.sectionIndex >= 0 &&
        saved.sectionIndex < _book!.chapters.length) {
      _currentChapter = saved.sectionIndex;
      _initialProgress = saved.normCharOffset / 10000.0;
    }

    if (_settings!.keepScreenAwake) {
      Wakelock.enable();
    }

    if (mounted) {
      setState(() {});
    }
  }

  EpubBook _buildLegacyBook(String extractDir) {
    final List<FileSystemEntity> htmlFiles = Directory(extractDir)
        .listSync(recursive: true)
        .where((FileSystemEntity e) {
      if (e is! File) return false;
      final String ext = p.extension(e.path).toLowerCase();
      return ext == '.html' || ext == '.xhtml' || ext == '.htm';
    }).toList()
      ..sort((FileSystemEntity a, FileSystemEntity b) =>
          a.path.compareTo(b.path));

    final List<EpubChapter> chapters = <EpubChapter>[];
    for (int i = 0; i < htmlFiles.length; i++) {
      final File f = htmlFiles[i] as File;
      chapters.add(EpubChapter(
        id: 'section-$i',
        href: p.relative(f.path, from: extractDir).replaceAll('\\', '/'),
        mediaType: 'text/html',
        html: f.readAsStringSync(),
        spineIndex: i,
      ));
    }

    return EpubBook(
      title: 'Book ${widget.bookId}',
      chapters: chapters,
      rootDirectory: extractDir,
    );
  }

  Future<void> _resolveAudioSlot() async {
    final HibikiDatabase db = appModel.database;
    final String bookUid = widget.bookId.toString();
    final Audiobook? ab =
        (await db.getAudiobookByBookUid(bookUid))?.let(_audiobookFromRow);
    final SrtBook? srt =
        (await db.getSrtBookByTtuBookId(widget.bookId))?.let(_srtBookFromRow);

    _hasAudioSlot = ab != null || srt != null;
    _audioSlotResolved = true;

    if (_hasAudioSlot && ab != null) {
      // TODO: Initialize audiobook controller in Task 23
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveDebounce?.cancel();
    _flushPosition();
    _audiobookController?.dispose();
    _readingTimeTracker?.dispose();
    _focusNode.dispose();
    Wakelock.disable();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  // ── UI Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final EdgeInsets vp = MediaQuery.of(context).viewPadding;
    _stableTopInset = vp.top;
    _stableBottomInset = vp.bottom;

    final Color bgColor = _themeBackgroundColor();

    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: WillPopScope(
        onWillPop: onWillPop,
        child: Scaffold(
          backgroundColor: bgColor,
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(
                top: _readerTopOffset,
                bottom: _readerBottomReserve,
                child: _buildBody(),
              ),
              _buildTopProgressBar(),
              buildDictionary(),
              _buildBottomChrome(),
              if (!_readerContentReady)
                Positioned.fill(
                  top: _stableTopInset,
                  child: ColoredBox(color: bgColor),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_audioSlotResolved || _book == null || _extractDir == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _buildWebView();
  }

  // ── URL & Resource Serving (mirrors Hoshi Android's hoshi.local scheme) ──

  String _chapterUrl(int index) {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return 'about:blank';
    }
    return 'https://hoshi.local/epub/${_book!.chapters[index].href}';
  }

  WebResourceResponse? _interceptRequest(WebUri url) {
    if (url.host != 'hoshi.local') return null;
    final String path = url.path;

    if (path.startsWith('/fonts/')) {
      final String fontPath =
          Uri.decodeComponent(path.substring('/fonts/'.length));
      final File fontFile = File(fontPath);
      if (!fontFile.existsSync()) return null;
      final Uint8List data = fontFile.readAsBytesSync();
      final String mime = fallbackMimeType(fontPath);
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

    if (!path.startsWith('/epub/')) return null;
    if (_extractDir == null) return null;

    final String epubPath = Uri.decodeComponent(path.substring('/epub/'.length));
    final String filePath = p.join(_extractDir!, epubPath);
    final File file = File(filePath);
    if (!file.existsSync()) {
      debugPrint('[ReaderHoshi] resource not found: $epubPath');
      return null;
    }

    Uint8List data = file.readAsBytesSync();
    final String mime = fallbackMimeType(filePath);

    if (mime == 'text/css') {
      final String cssText = utf8.decode(data);
      final String sanitized = ReaderResourceSanitizer.sanitizeCss(cssText);
      data = Uint8List.fromList(utf8.encode(sanitized));
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

  // ── Single IIFE setup script (mirrors Hoshi Android's readerSetupScript) ──

  String _buildReaderSetupScript() {
    final ReaderSettings s = _settings!;
    final String css = ReaderContentStyles.css(settings: s);
    final String selectionJs = ReaderSelectionScripts.source();
    final String paginationJs = _stripScriptTags(
      ReaderPaginationScripts.shellScript(
        initialProgress: _initialProgress,
        continuousMode: s.isContinuousMode,
        initialFragment: _initialFragment,
      ),
    );

    return '''
(function() {
  var style = document.createElement('style');
  style.textContent = ${jsonEncode(css)};
  document.head.appendChild(style);
  window.scanNonJapaneseText = false;
  $selectionJs
  $paginationJs
  var startX = 0, startY = 0, startTime = 0;
  document.addEventListener('touchstart', function(e) {
    var t = e.touches[0];
    startX = t.clientX;
    startY = t.clientY;
    startTime = Date.now();
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    var t = e.changedTouches[0];
    var dx = t.clientX - startX;
    var dy = t.clientY - startY;
    var elapsed = Date.now() - startTime;
    var absDx = Math.abs(dx);
    var absDy = Math.abs(dy);
    var velocity = absDx / Math.max(1, elapsed) * 1000;
    if (absDx > absDy && (absDx >= 72 || (absDx >= 36 && velocity >= 900))) {
      e.preventDefault();
      if (dx < 0) {
        window.flutter_inappwebview.callHandler('onSwipe', 'left');
      } else {
        window.flutter_inappwebview.callHandler('onSwipe', 'right');
      }
    } else if (absDx < 20 && absDy < 20) {
      window.flutter_inappwebview.callHandler('onTap', t.clientX, t.clientY);
    }
  }, {passive: false});
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
    return Math.round(p * total) + ',' + total;
  };
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
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(_chapterUrl(_currentChapter)),
      ),
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source:
              'window.onerror=function(m,s,l,c,e){console.error("__HIBIKI_JS_ERROR__ "+m+" at "+s+":"+l+":"+c);return false;};',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
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
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        _controller = controller;

        controller.addJavaScriptHandler(
          handlerName: 'onTextSelected',
          callback: (List<dynamic> args) async {
            if (args.isEmpty) return;
            try {
              final Map<String, dynamic> payload =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              await _handleTextSelected(ReaderSelectionData.fromJson(payload));
            } catch (e) {
              debugPrint('[ReaderHoshi] onTextSelected error: $e');
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onRestoreComplete',
          callback: (_) => _onRestoreComplete(),
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTap',
          callback: (List<dynamic> args) {
            if (args.length < 2) return;
            final double x = _toDouble(args[0]) ?? 0;
            final double y = _toDouble(args[1]) ?? 0;
            _selectTextAt(x, y);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onSwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            final String dir = args[0] as String;
            if (dir == 'left') {
              _paginate(ReaderNavigationDirection.forward);
            } else if (dir == 'right') {
              _paginate(ReaderNavigationDirection.backward);
            }
          },
        );
      },
      shouldInterceptRequest:
          (InAppWebViewController controller, WebResourceRequest request) async {
        return _interceptRequest(request.url);
      },
      shouldOverrideUrlLoading:
          (InAppWebViewController controller, NavigationAction action) async {
        final String url = action.request.url?.toString() ?? '';
        final ({int chapterIndex, String? fragment})? link =
            _book?.resolveInternalLink(url);
        if (link != null) {
          _navigateToChapterWithFragment(link.chapterIndex, link.fragment);
          return NavigationActionPolicy.CANCEL;
        }
        if (url.startsWith('https://hoshi.local/')) {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        await controller.evaluateJavascript(source: _buildReaderSetupScript());
        _initialFragment = null;
      },
      onConsoleMessage:
          (InAppWebViewController controller, ConsoleMessage msg) {
        debugPrint('[WebView] ${msg.message}');
      },
    );
  }

  // ── Restore Complete ──────────────────────────────────────────────

  void _onRestoreComplete() {
    if (!mounted) {
      return;
    }
    _restoreInFlight = false;

    if (!_readerContentReady) {
      setState(() {
        _readerContentReady = true;
      });
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    _readingTimeTracker ??= ReadingTimeTracker(appModel.database);
    _readingTimeTracker!.start();

    _refreshProgress();
  }

  // ── Chapter Navigation ────────────────────────────────────────────

  Future<void> _navigateToChapter(int index, {double progress = 0.0}) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return;
    }
    if (_controller == null) {
      return;
    }

    _currentChapter = index;
    _initialProgress = progress;
    _restoreInFlight = true;

    final String url = _chapterUrl(index);
    await _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _navigateToChapterWithFragment(
    int index,
    String? fragment,
  ) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) return;
    if (_controller == null) return;

    _currentChapter = index;
    _initialProgress = 0.0;
    _initialFragment = fragment;
    _restoreInFlight = true;

    final String url = _chapterUrl(index);
    await _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void _handlePageTurnLimit(String direction) {
    if (_book == null) {
      return;
    }
    if (direction == 'forward') {
      if (_currentChapter < _book!.chapters.length - 1) {
        _navigateToChapter(_currentChapter + 1);
      }
    } else {
      if (_currentChapter > 0) {
        _navigateToChapter(_currentChapter - 1, progress: 0.99);
      }
    }
  }

  // ── Text Selection → Dictionary ───────────────────────────────────

  Future<void> _selectTextAt(double cssX, double cssY) async {
    if (_controller == null) return;
    const int maxLength = 400;
    await _controller!.evaluateJavascript(
      source: ReaderSelectionScripts.selectInvocation(cssX, cssY, maxLength),
    );
  }

  Future<void> _handleTextSelected(ReaderSelectionData data) async {
    if (data.text.isEmpty) {
      return;
    }

    final Rect selectionRect = data.rect != null
        ? Rect.fromLTWH(
            data.rect!['x']!,
            data.rect!['y']! + _readerTopOffset,
            data.rect!['width']!,
            data.rect!['height']!,
          )
        : Rect.fromCenter(
            center: Offset(
              MediaQuery.of(context).size.width / 2,
              MediaQuery.of(context).size.height / 2,
            ),
            width: 1,
            height: 1,
          );

    appModel.currentMediaSource?.setCurrentSentence(
      selection: JidoujishoTextSelection(text: data.sentence),
    );

    final int highlightCount = await searchDictionaryResult(
      searchTerm: data.text,
      selectionRect: selectionRect,
    );

    if (highlightCount > 0 && _controller != null) {
      await _controller!.evaluateJavascript(
        source: ReaderSelectionScripts.highlightInvocation(highlightCount),
      );
    }
  }

  // ── Progress Save/Restore ─────────────────────────────────────────

  Future<void> _refreshProgress() async {
    if (_controller == null) return;
    final dynamic result = await _controller!.evaluateJavascript(
      source: 'window.hoshiProgressDetails()',
    );
    if (result == null) return;
    final String str =
        result.toString().replaceAll('"', '').trim();
    if (str.isEmpty) return;

    final List<String> parts = str.split(',');
    if (parts.length != 2) return;
    final int? current = int.tryParse(parts[0]);
    final int? total = int.tryParse(parts[1]);
    if (current == null || total == null || total <= 0) return;

    final double progress = current / total;
    _debouncedSavePosition(progress);

    if (mounted) {
      setState(() {
        _progressCurrentChars = current;
        _progressTotalChars = total;
      });
    }
  }

  void _debouncedSavePosition(double progress) {
    if (_restoreInFlight) {
      return;
    }
    if (_currentChapter == _lastSavedSection &&
        (progress - _lastSavedProgress).abs() < 0.001) {
      return;
    }

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistPosition(_currentChapter, progress);
    });
  }

  Future<void> _persistPosition(int section, double progress) async {
    _lastSavedSection = section;
    _lastSavedProgress = progress;

    final int normOffset = (progress * 10000).round();
    final ReaderPositionRepository repo =
        ReaderPositionRepository(appModel.database);
    await repo.save(
      ttuBookId: widget.bookId,
      sectionIndex: section,
      normCharOffset: normOffset,
    );
  }

  Future<void> _flushPosition() async {
    _saveDebounce?.cancel();
    if (_controller == null || _lastSavedSection < 0) {
      return;
    }
    try {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.progressInvocation(),
      );
      final double? progress = _toDouble(result);
      if (progress != null) {
        await _persistPosition(_currentChapter, progress);
      }
    } catch (_) {}
  }

  // ── Key Navigation ────────────────────────────────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final LogicalKeyboardKey key = event.logicalKey;

    if (key == LogicalKeyboardKey.audioVolumeDown) {
      _paginate(ReaderNavigationDirection.forward);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.audioVolumeUp) {
      _paginate(ReaderNavigationDirection.backward);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _paginate(ReaderNavigationDirection.forward);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _paginate(ReaderNavigationDirection.backward);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Page Turn ─────────────────────────────────────────────────────

  Future<void> _paginate(ReaderNavigationDirection direction) async {
    if (_controller == null) {
      return;
    }
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.paginateInvocation(direction),
    );
    if (_didScroll(result)) {
      _refreshProgress();
    } else {
      _handlePageTurnLimit(direction.jsValue);
    }
  }

  // ── Bottom Chrome ─────────────────────────────────────────────────

  void _toggleChrome() {
    setState(() {
      _showChrome = !_showChrome;
      if (_showChrome) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
  }

  Widget _buildBottomChrome() {
    if (!_showChrome || !_readerContentReady) {
      return const SizedBox.shrink();
    }

    final Color textColor = _themeTextColor();
    return Positioned(
      bottom: _stableBottomInset,
      left: 0,
      right: 0,
      height: _readerChromeHeight,
      child: Container(
        color: _themeBackgroundColor().withValues(alpha: 0.95),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            IconButton(
              icon: Icon(Icons.chevron_left, color: textColor, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.tune, color: textColor),
              color: _themeBackgroundColor(),
              onSelected: (String value) {
                if (value == 'chapters') {
                  _showChapterSheet();
                } else if (value == 'appearance') {
                  _showAppearanceSheet();
                }
              },
              itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'appearance',
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.palette_outlined, color: textColor),
                      const SizedBox(width: 12),
                      Text('Appearance',
                          style: TextStyle(color: textColor)),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'chapters',
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.list, color: textColor),
                      const SizedBox(width: 12),
                      Text('Chapters',
                          style: TextStyle(color: textColor)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showChapterSheet() {
    if (_book == null) return;

    final List<EpubTocItem> toc = _book!.toc;
    final List<EpubChapter> chapters = _book!.chapters;

    final List<({String label, int chapterIndex})> items;
    if (toc.isNotEmpty) {
      items = _flattenToc(toc);
    } else {
      items = List<({String label, int chapterIndex})>.generate(
        chapters.length,
        (int i) => (label: 'Chapter ${i + 1}', chapterIndex: i),
      );
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _themeBackgroundColor(),
      builder: (BuildContext ctx) {
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (BuildContext ctx, int i) {
            final bool isCurrent = items[i].chapterIndex == _currentChapter;
            return ListTile(
              title: Text(
                items[i].label,
                style: TextStyle(
                  color: _themeTextColor(),
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              selected: isCurrent,
              onTap: () {
                Navigator.of(ctx).pop();
                _toggleChrome();
                _navigateToChapter(items[i].chapterIndex);
              },
            );
          },
        );
      },
    );
  }

  List<({String label, int chapterIndex})> _flattenToc(List<EpubTocItem> items) {
    final List<({String label, int chapterIndex})> result =
        <({String label, int chapterIndex})>[];
    for (final EpubTocItem item in items) {
      final int index = _tocHrefToChapterIndex(item.href);
      if (index >= 0) {
        result.add((label: item.label, chapterIndex: index));
      }
      result.addAll(_flattenToc(item.children));
    }
    return result;
  }

  int _tocHrefToChapterIndex(String? href) {
    if (href == null || _book == null) return -1;
    final String cleanHref = href.split('#').first;
    for (int i = 0; i < _book!.chapters.length; i++) {
      if (_book!.chapters[i].href == cleanHref) {
        return i;
      }
    }
    return -1;
  }

  void _showAppearanceSheet() {
    if (_settings == null) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _themeBackgroundColor(),
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheetState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (BuildContext ctx, ScrollController scrollCtrl) {
                return ListView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    _buildThemeSelector(setSheetState),
                    const SizedBox(height: 16),
                    _buildFontSizeSlider(setSheetState),
                    const SizedBox(height: 16),
                    _buildLineHeightSlider(setSheetState),
                    const SizedBox(height: 16),
                    _buildWritingModeToggle(setSheetState),
                    const SizedBox(height: 16),
                    _buildViewModeToggle(setSheetState),
                    const SizedBox(height: 16),
                    _buildFuriganaModeSelector(setSheetState),
                  ],
                );
              },
            );
          },
        );
      },
    ).then((_) => _reloadWithCurrentSettings());
  }

  Widget _buildThemeSelector(StateSetter setSheetState) {
    final List<(String, String, Color)> themes = <(String, String, Color)>[
      ('light-theme', 'Light', const Color(0xFFFFFFFF)),
      ('ecru-theme', 'Ecru', const Color(0xFFF7F6EB)),
      ('water-theme', 'Water', const Color(0xFFDFECF4)),
      ('gray-theme', 'Gray', const Color(0xFF23272A)),
      ('dark-theme', 'Dark', const Color(0xFF121212)),
      ('black-theme', 'Black', const Color(0xFF000000)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Theme', style: TextStyle(color: _themeTextColor(), fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: themes.map(((String, String, Color) t) {
            final bool selected = _settings!.theme == t.$1;
            return GestureDetector(
              onTap: () {
                _settings!.setTheme(t.$1);
                setSheetState(() {});
                setState(() {});
              },
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: t.$3,
                  border: Border.all(
                    color: selected ? Colors.blue : Colors.grey,
                    width: selected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildFontSizeSlider(StateSetter setSheetState) {
    return Row(
      children: <Widget>[
        Text('Font Size', style: TextStyle(color: _themeTextColor())),
        Expanded(
          child: Slider(
            value: _settings!.fontSize,
            min: 12,
            max: 60,
            divisions: 48,
            label: '${_settings!.fontSize.round()}',
            onChanged: (double v) {
              _settings!.setFontSize(v);
              setSheetState(() {});
            },
          ),
        ),
        Text('${_settings!.fontSize.round()}', style: TextStyle(color: _themeTextColor())),
      ],
    );
  }

  Widget _buildLineHeightSlider(StateSetter setSheetState) {
    return Row(
      children: <Widget>[
        Text('Line Height', style: TextStyle(color: _themeTextColor())),
        Expanded(
          child: Slider(
            value: _settings!.lineHeight,
            min: 1.0,
            max: 2.5,
            divisions: 15,
            label: _settings!.lineHeight.toStringAsFixed(1),
            onChanged: (double v) {
              _settings!.setLineHeight(v);
              setSheetState(() {});
            },
          ),
        ),
        Text(_settings!.lineHeight.toStringAsFixed(1),
            style: TextStyle(color: _themeTextColor())),
      ],
    );
  }

  Widget _buildWritingModeToggle(StateSetter setSheetState) {
    return Row(
      children: <Widget>[
        Text('Writing Mode', style: TextStyle(color: _themeTextColor())),
        const Spacer(),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'vertical-rl', label: Text('Vertical')),
            ButtonSegment<String>(value: 'horizontal-tb', label: Text('Horizontal')),
          ],
          selected: <String>{_settings!.writingMode},
          onSelectionChanged: (Set<String> v) {
            _settings!.setWritingMode(v.first);
            setSheetState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildViewModeToggle(StateSetter setSheetState) {
    return Row(
      children: <Widget>[
        Text('View Mode', style: TextStyle(color: _themeTextColor())),
        const Spacer(),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'paginated', label: Text('Paginated')),
            ButtonSegment<String>(value: 'continuous', label: Text('Continuous')),
          ],
          selected: <String>{_settings!.viewMode},
          onSelectionChanged: (Set<String> v) {
            _settings!.setViewMode(v.first);
            setSheetState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildFuriganaModeSelector(StateSetter setSheetState) {
    return Row(
      children: <Widget>[
        Text('Furigana', style: TextStyle(color: _themeTextColor())),
        const Spacer(),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'show', label: Text('Show')),
            ButtonSegment<String>(value: 'hide', label: Text('Hide')),
            ButtonSegment<String>(value: 'toggle', label: Text('Toggle')),
          ],
          selected: <String>{_settings!.furiganaMode},
          onSelectionChanged: (Set<String> v) {
            _settings!.setFuriganaMode(v.first);
            setSheetState(() {});
          },
        ),
      ],
    );
  }

  Future<void> _reloadWithCurrentSettings() async {
    if (_controller == null) return;
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.progressInvocation(),
    );
    final double? progress = _toDouble(result);
    _initialProgress = progress ?? 0.0;
    _restoreInFlight = true;

    setState(() {
      _readerContentReady = false;
    });

    final String url = _chapterUrl(_currentChapter);
    await _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  // ── Top Progress Bar ──────────────────────────────────────────────

  Widget _buildTopProgressBar() {
    if (!_showTopProgress) {
      return const SizedBox.shrink();
    }

    final double ratio =
        (_progressCurrentChars! / _progressTotalChars!).clamp(0.0, 1.0);
    final String title = _book?.title ?? '';
    final Color textColor = _themeTextColor();

    return Positioned(
      top: _stableTopInset,
      left: 0,
      right: 0,
      height: _topProgressBarHeight,
      child: GestureDetector(
        onTap: _toggleChrome,
        child: Container(
          color: _themeBackgroundColor(),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (title.isNotEmpty)
                Text(
                  title,
                  style: TextStyle(fontSize: 10, color: textColor),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              Text(
                '$_progressCurrentChars / $_progressTotalChars'
                '  ${(ratio * 100).toStringAsFixed(2)}%',
                style: TextStyle(fontSize: 10, color: textColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Theme Colors ──────────────────────────────────────────────────

  Color _themeBackgroundColor() {
    final String theme = _settings?.theme ?? 'light-theme';
    switch (theme) {
      case 'ecru-theme':
        return const Color(0xFFF7F6EB);
      case 'water-theme':
        return const Color(0xFFDFECF4);
      case 'gray-theme':
        return const Color(0xFF23272A);
      case 'dark-theme':
        return const Color(0xFF121212);
      case 'black-theme':
        return const Color(0xFF000000);
      default:
        return const Color(0xFFFFFFFF);
    }
  }

  Color _themeTextColor() {
    final String theme = _settings?.theme ?? 'light-theme';
    switch (theme) {
      case 'gray-theme':
      case 'black-theme':
        return const Color(0xDEFFFFFF);
      case 'dark-theme':
        return const Color(0x99FFFFFF);
      default:
        return const Color(0xDE000000);
    }
  }

  // ── JS result helpers (evaluateJavascript returns dynamic) ────────

  static double? _toDouble(dynamic result) {
    if (result is double) return result;
    if (result is int) return result.toDouble();
    if (result is String) {
      return double.tryParse(result.trim().replaceAll('"', ''));
    }
    return null;
  }

  static bool _didScroll(dynamic result) {
    if (result is String) {
      return result.trim().replaceAll('"', '') == 'scrolled';
    }
    return false;
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Audiobook _audiobookFromRow(AudiobookRow row) {
    final Audiobook ab = Audiobook()
      ..id = row.id
      ..bookUid = row.bookUid
      ..audioRoot = row.audioRoot
      ..alignmentFormat = row.alignmentFormat
      ..alignmentPath = row.alignmentPath;
    if (row.audioPathsJson != null) {
      ab.audioPaths =
          (jsonDecode(row.audioPathsJson!) as List<dynamic>).cast<String>();
    }
    return ab;
  }

  SrtBook _srtBookFromRow(SrtBookRow row) {
    final SrtBook book = SrtBook()
      ..id = row.id
      ..uid = row.uid
      ..title = row.title
      ..author = row.author
      ..audioRoot = row.audioRoot
      ..srtPath = row.srtPath
      ..coverPath = row.coverPath
      ..ttuBookId = row.ttuBookId;
    if (row.audioPathsJson != null) {
      book.audioPaths =
          (jsonDecode(row.audioPathsJson!) as List<dynamic>).cast<String>();
    }
    return book;
  }
}

extension _LetExtension<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
