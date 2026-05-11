import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/collection_audio_matcher.dart';
import 'package:hibiki/src/media/audiobook/highlight_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';
import 'package:hibiki/src/media/audiobook/reading_time_tracker.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';
import 'package:hibiki/src/media/audiobook/reader_position_repository.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_resource_sanitizer.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/utils/misc/jidoujisho_text_selection.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/volume_key_channel.dart';
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
  bool _hasEverLoaded = false;
  bool _restoreInFlight = false;
  bool _isNavigatingToChapter = false;
  double _initialProgress = 0.0;
  String? _initialFragment;

  double _stableTopInset = 0;
  double _stableBottomInset = 0;

  static const double _readerChromeHeight = 56;
  static const double _infoFontSize = 12;

  int? _progressCurrentChars;
  int? _progressTotalChars;

  int _sessionCharsRead = 0;
  int _lastAbsoluteCount = 0;
  DateTime _sessionStartTime = DateTime.now();

  List<int> _chapterCharCounts = [];
  List<int> _chapterCumulativeChars = [];

  Timer? _saveDebounce;
  Timer? _progressPollTimer;
  Timer? _volumeThrottleTimer;
  int _lastSavedSection = -1;
  double _lastSavedProgress = -1;

  AudiobookPlayerController? _audiobookController;
  String? _audiobookBookUid;
  String? _srtBookUid;

  bool _audioSlotResolved = false;

  ReadingTimeTracker? _readingTimeTracker;

  StreamSubscription<void>? _playStreamSub;
  StreamSubscription<Duration>? _seekStreamSub;
  StreamSubscription<void>? _skipNextSub;
  StreamSubscription<void>? _skipPrevSub;

  bool _showChrome = true;
  double _lastSyncedWidth = 0;
  double _lastSyncedHeight = 0;
  double _displayedProgress = 0.0;

  final FocusNode _focusNode = FocusNode();

  bool get _showTopProgress =>
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0;

  double get _readerTopOffset =>
      _stableTopInset + _infoFontSize * 1.5;

  double get _readerBottomReserve =>
      _readerChromeHeight + _stableBottomInset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initBook();
  }

  Future<void> _initBook() async {
    final HibikiDatabase db = appModel.database;
    _settings = ReaderSettings(db);
    await _settings!.ready;

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
      debugPrint('[ReaderHoshi] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookId, extractDir);
      _book ??= _buildLegacyBook(extractDir);
    }

    final List<String> hrefs =
        _book!.chapters.map((EpubChapter ch) => ch.href).toList();
    debugPrint('[ReaderHoshi] chapter hrefs: $hrefs');

    _chapterCharCounts = List<int>.generate(
      _book!.chapters.length,
      (int i) => _book!.chapterPlainText(i).length,
    );
    int cumulative = 0;
    _chapterCumulativeChars = <int>[];
    for (final int count in _chapterCharCounts) {
      _chapterCumulativeChars.add(cumulative);
      cumulative += count;
    }

    await _resolveAudioSlot();

    final Bookmark? bm = widget.initialBookmarkJump;
    if (bm != null &&
        bm.sectionIndex >= 0 &&
        bm.sectionIndex < _book!.chapters.length) {
      _currentChapter = bm.sectionIndex;
      _initialProgress = bm.normCharOffset / 10000.0;
      debugPrint('[ReaderHoshi] restore from bookmark: '
          'chapter=$_currentChapter progress=$_initialProgress');
    } else {
      final ReaderPositionRepository repo =
          ReaderPositionRepository(appModel.database);
      final ReaderPosition? saved = await repo.findByTtuBookId(widget.bookId);
      debugPrint('[ReaderHoshi] restore lookup: bookId=${widget.bookId} '
          'saved=$saved section=${saved?.sectionIndex} '
          'offset=${saved?.normCharOffset}');
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < _book!.chapters.length) {
        _currentChapter = saved.sectionIndex;
        _initialProgress = saved.normCharOffset / 10000.0;
      }
    }

    if (_settings!.keepScreenAwake) {
      Wakelock.enable();
    }

    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    if (src.volumePageTurningEnabled) {
      _setupVolumeKeyHandlers();
    }

    _syncDictionaryTheme();

    _audioSlotResolved = true;

    if (mounted) {
      setState(() {});
    }
  }

  void _setupVolumeKeyHandlers() {
    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    VolumeKeyChannel.instance.setHandlers(
      onVolumeUp: () => _onVolumeKey(isUp: true),
      onVolumeDown: () => _onVolumeKey(isUp: false),
    );
    VolumeKeyChannel.instance.setInterceptEnabled(true);
    debugPrint('[ReaderHoshi] volume key handlers installed '
        '(inverted=${src.volumePageTurningInverted}, '
        'speed=${src.volumePageTurningSpeed}ms)');
  }

  void _onVolumeKey({required bool isUp}) {
    if (_volumeThrottleTimer?.isActive ?? false) return;

    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    final bool inverted = src.volumePageTurningInverted;

    final bool goForward = inverted ? isUp : !isUp;
    _paginate(goForward
        ? ReaderNavigationDirection.forward
        : ReaderNavigationDirection.backward);

    final int speedMs = src.volumePageTurningSpeed;
    if (speedMs > 0) {
      _volumeThrottleTimer = Timer(Duration(milliseconds: speedMs), () {});
    }
  }

  Future<EpubBook?> _buildBookFromDb(
    HibikiDatabase db,
    int bookId,
    String extractDir,
  ) async {
    final EpubBookRow? row = await db.getEpubBook(bookId);
    if (row == null) return null;

    final List<dynamic> rawChapters =
        jsonDecode(row.chaptersJson) as List<dynamic>;
    if (rawChapters.isEmpty) return null;

    final List<EpubChapter> chapters = <EpubChapter>[];
    for (int i = 0; i < rawChapters.length; i++) {
      final Map<String, dynamic> ch =
          rawChapters[i] as Map<String, dynamic>;
      final String href = ch['href'] as String;
      final File file = File(p.join(extractDir, href));
      final String html = file.existsSync() ? file.readAsStringSync() : '';
      chapters.add(EpubChapter(
        id: ch['id'] as String? ?? 'section-$i',
        href: href,
        mediaType: ch['mediaType'] as String? ?? 'text/html',
        html: html,
        spineIndex: i,
      ));
    }

    List<EpubTocItem> toc = const <EpubTocItem>[];
    if (row.tocJson != null) {
      final List<dynamic> rawToc =
          jsonDecode(row.tocJson!) as List<dynamic>;
      toc = rawToc.map((dynamic e) {
        final Map<String, dynamic> item = e as Map<String, dynamic>;
        return EpubTocItem(
          label: item['title'] as String? ?? '',
          href: item['href'] as String?,
        );
      }).toList();
    }

    debugPrint('[ReaderHoshi] built from DB: ${chapters.length} chapters, '
        '${toc.length} toc entries');

    return EpubBook(
      title: row.title,
      author: row.author,
      chapters: chapters,
      toc: toc,
      rootDirectory: extractDir,
    );
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
          _naturalCompare(a.path, b.path));

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

  static final RegExp _chunkRe = RegExp(r'(\d+|\D+)');

  static int _naturalCompare(String a, String b) {
    final List<String> ac = _chunkRe.allMatches(a).map((m) => m[0]!).toList();
    final List<String> bc = _chunkRe.allMatches(b).map((m) => m[0]!).toList();
    final int len = ac.length < bc.length ? ac.length : bc.length;
    for (int i = 0; i < len; i++) {
      final int? an = int.tryParse(ac[i]);
      final int? bn = int.tryParse(bc[i]);
      if (an != null && bn != null) {
        if (an != bn) return an.compareTo(bn);
      } else {
        final int cmp = ac[i].compareTo(bc[i]);
        if (cmp != 0) return cmp;
      }
    }
    return ac.length.compareTo(bc.length);
  }

  Future<void> _resolveAudioSlot() async {
    final AudiobookPlayerController? old = _audiobookController;
    if (old != null) {
      old.removeListener(_onCueChanged);
      old.dispose();
      _audiobookController = null;
      _audiobookBookUid = null;
      _srtBookUid = null;
    }

    final HibikiDatabase db = appModel.database;
    final String bookUid = ReaderHoshiSource.bookUidFor(widget.bookId);
    final Audiobook? ab =
        (await db.getAudiobookByBookUid(bookUid))?.let(_audiobookFromRow);
    final SrtBook? srt =
        (await db.getSrtBookByTtuBookId(widget.bookId))?.let(_srtBookFromRow);

    if (ab != null) {
      await _initAudiobookController(ab, bookUid);
    } else if (srt != null) {
      await _initSrtBookController(srt);
    }
  }

  Future<void> _initAudiobookController(
    Audiobook audiobook,
    String bookUid,
  ) async {
    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<File> audioFiles = await _resolveAudioFiles(
      audioPaths: audiobook.audioPaths,
      audioRoot: audiobook.audioRoot,
    );
    if (audioFiles.isEmpty) {
      debugPrint('[ReaderHoshi] audiobook found but no audio files');
      debugPrint('[ReaderHoshi] audio slot cleared: no files found');
      return;
    }

    final AudiobookPlayerController controller = AudiobookPlayerController();
    final List<Object> prefs = await Future.wait(<Future<Object>>[
      repo.readFollowAudio(bookUid),
      repo.readDelayMs(bookUid),
      repo.readSpeed(bookUid),
      repo.readPositionMs(bookUid),
      repo.readImagePauseSec(bookUid),
    ]);
    await controller.load(
      audiobook: audiobook,
      audioFiles: audioFiles,
      initialFollowAudio: prefs[0] as bool,
      initialDelayMs: prefs[1] as int,
      initialSpeed: prefs[2] as double,
      initialPositionMs: prefs[3] as int,
      initialImagePauseSec: prefs[4] as int,
    );

    if (!mounted) {
      controller.dispose();
      return;
    }

    controller.onPositionWrite = (String uid, int posMs) {
      repo.updatePositionMs(bookUid: uid, positionMs: posMs);
    };
    controller.onDelayPersist = (int ms) async {
      await repo.updateDelayMs(bookUid: bookUid, ms: ms);
    };
    controller.onSpeedPersist = (double speed) async {
      await repo.updateSpeed(bookUid: bookUid, speed: speed);
    };
    controller.onImagePausePersist = (int sec) async {
      await repo.updateImagePauseSec(bookUid: bookUid, sec: sec);
    };
    controller.onFollowAudioPersist = (bool value) async {
      await repo.updateFollowAudio(bookUid: bookUid, value: value);
    };
    controller.getCurrentReaderSection = () => _currentChapter;
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.onBoundarySkip = _handleBoundarySkip;
    controller.addListener(_onCueChanged);

    _audiobookBookUid = bookUid;

    setState(() {
      _audiobookController = controller;
    });
    _initAudioFeatures(controller);
  }

  Future<void> _initSrtBookController(SrtBook srtBook) async {
    final List<File> audioFiles = await _resolveAudioFiles(
      audioPaths: srtBook.audioPaths,
      audioRoot: srtBook.audioRoot,
    );
    if (audioFiles.isEmpty) {
      debugPrint('[ReaderHoshi] srt book found but no audio files');
      debugPrint('[ReaderHoshi] audio slot cleared: no files found');
      return;
    }

    final Audiobook syntheticAudiobook = Audiobook()
      ..bookUid = srtBook.uid
      ..audioRoot = srtBook.audioRoot
      ..audioPaths = srtBook.audioPaths
      ..alignmentFormat = 'srt'
      ..alignmentPath = srtBook.srtPath;

    final String srtBookUid = srtBook.uid;
    final AudiobookRepository abRepo = AudiobookRepository(appModel.database);
    final AudiobookPlayerController controller = AudiobookPlayerController();

    final List<Object> prefs = await Future.wait(<Future<Object>>[
      abRepo.readDelayMs(srtBookUid),
      abRepo.readSpeed(srtBookUid),
      abRepo.readImagePauseSec(srtBookUid),
    ]);
    await controller.load(
      audiobook: syntheticAudiobook,
      audioFiles: audioFiles,
      initialDelayMs: prefs[0] as int,
      initialSpeed: prefs[1] as double,
      initialImagePauseSec: prefs[2] as int,
    );

    if (!mounted) {
      controller.dispose();
      return;
    }

    controller.onDelayPersist = (int ms) async {
      await abRepo.updateDelayMs(bookUid: srtBookUid, ms: ms);
    };
    controller.onSpeedPersist = (double speed) async {
      await abRepo.updateSpeed(bookUid: srtBookUid, speed: speed);
    };
    controller.onImagePausePersist = (int sec) async {
      await abRepo.updateImagePauseSec(bookUid: srtBookUid, sec: sec);
    };
    controller.getCurrentReaderSection = () => _currentChapter;
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.onBoundarySkip = _handleBoundarySkip;
    controller.addListener(_onCueChanged);

    _srtBookUid = srtBookUid;

    setState(() {
      _audiobookController = controller;
    });
    _initAudioFeatures(controller);
  }

  Future<List<File>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) async {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      final List<File> files = <File>[];
      for (final String path in audioPaths) {
        final File f = File(path);
        if (await f.exists()) files.add(f);
      }
      return files;
    }
    if (audioRoot != null) {
      final Directory dir = Directory(audioRoot);
      if (!await dir.exists()) return <File>[];
      final List<FileSystemEntity> entries = await dir.list().toList();
      final List<File> files = entries.whereType<File>().where((File f) {
        final String ext = f.path.toLowerCase();
        return ext.endsWith('.mp3') ||
            ext.endsWith('.m4a') ||
            ext.endsWith('.ogg') ||
            ext.endsWith('.aac') ||
            ext.endsWith('.wav') ||
            ext.endsWith('.mp4');
      }).toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
      return files;
    }
    return <File>[];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progressPollTimer?.cancel();
    _saveDebounce?.cancel();
    _volumeThrottleTimer?.cancel();
    VolumeKeyChannel.instance.setHandlers();
    VolumeKeyChannel.instance.setInterceptEnabled(false);
    appModel.setOverrideDictionaryTheme(null);
    appModel.setOverrideDictionaryColor(null);
    _flushPosition();
    _flushReadingStats();
    _audiobookController?.removeListener(_onCueChanged);
    _audiobookController?.dispose();
    _readingTimeTracker?.dispose();
    _focusNode.dispose();
    _playStreamSub?.cancel();
    _seekStreamSub?.cancel();
    _skipNextSub?.cancel();
    _skipPrevSub?.cancel();
    FloatingLyricChannel.clearEventHandlers();
    if (appModel.showFloatingLyric) {
      FloatingLyricChannel.hide();
    }
    appModel.audioHandler?.clearNotification();
    Wakelock.disable();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPageSize();
    });
  }

  Future<void> _syncPageSize() async {
    if (_controller == null || !_readerContentReady) return;
    final Size screen = MediaQuery.of(context).size;
    final double w = screen.width;
    final double h = screen.height - _readerTopOffset - _readerBottomReserve;
    final bool widthChanged =
        _lastSyncedWidth > 0 && w != _lastSyncedWidth;
    final bool heightChanged = (h - _lastSyncedHeight).abs() >= 1;
    if (!widthChanged && !heightChanged) return;
    _lastSyncedWidth = w;
    _lastSyncedHeight = h;

    if (widthChanged) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.progressInvocation(),
      );
      final double? progress =
          ReaderPaginationScripts.doubleResult(result);
      if (progress != null && progress > 0) {
        _displayedProgress = progress;
      }
      await _navigateToChapter(_currentChapter, progress: _displayedProgress);
    } else {
      await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.updatePageSizeInvocation(w, h),
      );
    }
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
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, dynamic result) async {
          if (didPop) return;
          final bool allow = await onWillPop();
          if (allow && mounted) Navigator.of(context).pop();
        },
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
              if (!_readerContentReady)
                Positioned.fill(
                  top: _hasEverLoaded ? _readerTopOffset : _stableTopInset,
                  bottom: _hasEverLoaded ? _readerBottomReserve : 0,
                  child: ColoredBox(color: bgColor),
                ),
              _buildTopProgressBar(),
              buildDictionary(),
              _buildBottomChrome(),
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
    return ReaderHoshiSource.epubUrl(_book!.chapters[index].href);
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
    debugPrint('[ReaderHoshi] 404: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  static WebResourceResponse _forbidden(String reason) {
    debugPrint('[ReaderHoshi] 403: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 403,
      reasonPhrase: 'Forbidden',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  WebResourceResponse? _interceptRequest(WebUri url) {
    if (url.host != ReaderHoshiSource.kHost) return null;
    final String path = url.path;

    if (path.startsWith('/fonts/')) {
      final String raw = path.substring('/fonts/'.length);
      final String fontPath = Uri.decodeComponent(raw);
      final Set<String> allowedPaths = (_settings?.customFonts ?? <Map<String, dynamic>>[])
          .map((Map<String, dynamic> e) => e['path'] as String?)
          .whereType<String>()
          .toSet();
      if (!allowedPaths.contains(fontPath)) {
        return _forbidden('font not in whitelist: $fontPath');
      }
      final File fontFile = File(fontPath);
      if (!fontFile.existsSync()) {
        return _notFound('font not found: $fontPath');
      }
      final Uint8List data = fontFile.readAsBytesSync();
      if (!_isValidFontData(data)) {
        return _notFound('font corrupted: $fontPath (${data.length} bytes)');
      }
      debugPrint('[ReaderHoshi] font served: $fontPath (${data.length} bytes)');
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

    if (!path.startsWith('/epub/')) return _notFound('unknown path: $path');
    if (_extractDir == null) return _notFound('extractDir not ready: $path');

    final String epubPath = Uri.decodeComponent(path.substring('/epub/'.length));
    final String filePath = p.canonicalize(p.join(_extractDir!, epubPath));
    if (!filePath.startsWith(p.canonicalize(_extractDir!))) {
      return _forbidden('path traversal blocked: $epubPath');
    }
    final File file = File(filePath);
    if (!file.existsSync()) {
      return _notFound('resource not found: $epubPath (resolved: $filePath)');
    }

    Uint8List data = file.readAsBytesSync();
    final String mime = fallbackMimeType(filePath);

    if (mime == 'text/css') {
      final String cssText = utf8.decode(data);
      final String sanitized = ReaderResourceSanitizer.sanitizeCss(cssText);
      data = Uint8List.fromList(utf8.encode(sanitized));
    }

    if ((mime == 'text/html' || mime.contains('xhtml')) && _settings != null) {
      String html = utf8.decode(data);
      final String styleTag = ReaderContentStyles.styleTag(
        settings: _settings!,
        customBg: _settings!.theme == 'custom-theme' ? _readerBackgroundHex : null,
        customFg: _settings!.theme == 'custom-theme' ? _customThemeTextCss : null,
      );
      const String hideUntilReady =
          '<style id="hoshi-cloak">body{visibility:hidden!important}</style>';
      final RegExp headPattern = RegExp(r'<head[^>]*>', caseSensitive: false);
      final RegExpMatch? headMatch = headPattern.firstMatch(html);
      if (headMatch != null) {
        html = '${html.substring(0, headMatch.end)}\n$hideUntilReady\n$styleTag${html.substring(headMatch.end)}';
      } else {
        html = '$hideUntilReady\n$styleTag\n$html';
      }
      data = Uint8List.fromList(utf8.encode(html));
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

  static bool _isValidFontData(Uint8List data) {
    if (data.length < 4) return false;
    final int sig = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
    return sig == 0x00010000 || // TrueType
        sig == 0x4F54544F || // OpenType CFF ("OTTO")
        sig == 0x774F4646 || // WOFF ("wOFF")
        sig == 0x774F4632 || // WOFF2 ("wOF2")
        sig == 0x74746366; // TTC ("ttcf")
  }

  static String _buildFuriganaJs(String mode) {
    switch (mode) {
      case 'partial':
        return '''
  document.addEventListener('click', function(e) {
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
    document.body.classList.toggle('show-all-rt');
  });''';
      default:
        return '';
    }
  }

  // ── Single IIFE setup script (mirrors Hoshi Android's readerSetupScript) ──

  String _buildReaderSetupScript({String? sasayakiCuesJson}) {
    final ReaderSettings s = _settings!;
    final String selectionJs = ReaderSelectionScripts.source();
    final String paginationJs = _stripScriptTags(
      ReaderPaginationScripts.shellScript(
        initialProgress: _initialProgress,
        continuousMode: s.isContinuousMode,
        initialFragment: _initialFragment,
        sasayakiCuesJson: sasayakiCuesJson,
      ),
    );

    final String furiganaJs = _buildFuriganaJs(s.furiganaMode);

    return '''
(function() {
  window.scanNonJapaneseText = true;
  $selectionJs
  $paginationJs
  $furiganaJs
  var startX = 0, startY = 0, startTime = 0, hasStart = false;
  document.addEventListener('touchstart', function(e) {
    var t = e.touches[0];
    hasStart = true;
    startX = t.clientX;
    startY = t.clientY;
    startTime = Date.now();
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    if (!hasStart) return;
    hasStart = false;
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
      var target = document.elementFromPoint(t.clientX, t.clientY);
      if (target && target.tagName === 'IMG' && target.src) {
        window.flutter_inappwebview.callHandler('onImageTap', target.src);
      } else {
        window.flutter_inappwebview.callHandler('onTap', t.clientX, t.clientY);
      }
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
    return InAppWebView(
      initialUrlRequest: null,
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source:
              'window.onerror=function(m,s,l,c,e){console.error("__HIBIKI_JS_ERROR__ "+m+" at "+s+":"+l+":"+c);return false;};',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
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
        _loadChapterDirectly(_currentChapter);

        controller.addJavaScriptHandler(
          handlerName: 'onTextSelected',
          callback: (List<dynamic> args) async {
            if (args.isEmpty) return;
            try {
              final Map<String, dynamic> payload =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              await _handleTextSelected(ReaderSelectionData.fromJson(payload));
            } catch (e, stack) {
              ErrorLogService.instance.log('ReaderHoshi.onTextSelected', e, stack);
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
            if (!_showChrome) {
              _toggleChrome();
              return;
            }
            if (!ReaderHoshiSource.instance.highlightOnTap) return;
            final double x = _toDouble(args[0]) ?? 0;
            final double y = _toDouble(args[1]) ?? 0;
            _selectTextAt(x, y);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTapEmpty',
          callback: (_) {
            if (ReaderHoshiSource.instance.tapEmptyToHideChrome) {
              _toggleChrome();
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onSwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            final String dir = args[0] as String;
            final bool invert =
                ReaderHoshiSource.instance.invertSwipeDirection;
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

        controller.addJavaScriptHandler(
          handlerName: 'onBoundarySwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            final String dir = args[0] as String;
            if (dir == 'forward') {
              _handlePageTurnLimit('forward');
            } else if (dir == 'backward') {
              _handlePageTurnLimit('backward');
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageDetected',
          callback: (_) => _audiobookController?.triggerImagePause(),
        );

        controller.addJavaScriptHandler(
          handlerName: 'onImageTap',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            _openImageViewer(args[0] as String);
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
        if (_isNavigatingToChapter) {
          return NavigationActionPolicy.ALLOW;
        }
        final ({int chapterIndex, String? fragment})? link =
            _book?.resolveInternalLink(url);
        if (link != null) {
          _navigateToChapterWithFragment(link.chapterIndex, link.fragment);
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        _isNavigatingToChapter = false;
        final int chapterSnapshot = _currentChapter;
        debugPrint('[ReaderHoshi] onLoadStop: url=$url '
            'chapter=$chapterSnapshot progress=$_initialProgress');
        final String expectedUrl = _chapterUrl(chapterSnapshot);
        if (url != null &&
            Uri.parse(url.toString()).path != Uri.parse(expectedUrl).path) {
          debugPrint('[ReaderHoshi] onLoadStop: stale page (expected=$expectedUrl), ignoring');
          return;
        }
        String? sasayakiCuesJson;
        if (_audiobookController != null) {
          sasayakiCuesJson = await _prepareSasayakiCuesJson();
        }
        if (_currentChapter != chapterSnapshot) return;
        await controller.evaluateJavascript(
          source: _buildReaderSetupScript(sasayakiCuesJson: sasayakiCuesJson),
        );
        _initialFragment = null;
        if (_audiobookController != null) {
          await _injectAudiobookBridge();
        }
        await HighlightBridge.inject(controller);
        await _applyChapterHighlights();
        _lastSyncedWidth = MediaQuery.of(context).size.width;
      },
      onReceivedError:
          (InAppWebViewController controller, WebResourceRequest request,
              WebResourceError error) {
        if (request.isForMainFrame ?? false) {
          debugPrint('[ReaderHoshi] onReceivedError: ${error.description}');
          _isNavigatingToChapter = false;
          _restoreInFlight = false;
          if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
            _restoreCompleter!.complete();
          }
          _restoreCompleter = null;
        }
      },
      onConsoleMessage:
          (InAppWebViewController controller, ConsoleMessage msg) {
        debugPrint('[WebView] ${msg.message}');
      },
    );
  }

  Future<void> _applyChapterHighlights() async {
    if (_controller == null) return;
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);
    final List<FavoriteSentence> all = await repo.getAll();
    final List<FavoriteSentence> chapterFavs = all
        .where((FavoriteSentence s) =>
            s.ttuBookId == widget.bookId &&
            s.sectionIndex == _currentChapter)
        .toList();
    if (chapterFavs.isNotEmpty) {
      await HighlightBridge.applyHighlights(_controller!, chapterFavs,
          backgroundHex: _readerBackgroundHex,
          customHighlightCss: _customHighlightCss);
      await _controller!.evaluateJavascript(
        source: 'window.hoshiReader && window.hoshiReader.buildNodeOffsets();',
      );
    }
  }

  // ── Restore Complete ──────────────────────────────────────────────

  Completer<void>? _restoreCompleter;

  void _onRestoreComplete() {
    if (!mounted) {
      return;
    }
    _restoreInFlight = false;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete();
    }
    _restoreCompleter = null;

    if (!_readerContentReady) {
      final Size screen = MediaQuery.of(context).size;
      _lastSyncedWidth = screen.width;
      _lastSyncedHeight =
          screen.height - _readerTopOffset - _readerBottomReserve;
      setState(() {
        _readerContentReady = true;
        _hasEverLoaded = true;
      });
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPageSize();
      });
    }

    _audiobookController?.notifySectionRestoreCompleted(
      currentReaderSection: _currentChapter,
      success: true,
    );

    _readingTimeTracker ??= ReadingTimeTracker(appModel.database);
    _readingTimeTracker!.start();
    _sessionStartTime = DateTime.now();
    _lastAbsoluteCount = _absoluteCharPosition(_initialProgress);

    _refreshProgress();
    _startProgressPoll();
  }

  void _startProgressPoll() {
    _progressPollTimer?.cancel();
    _progressPollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshProgress(),
    );
  }

  // ── Audiobook Cue Wiring ──────────────────────────────────────────

  void _onCueChanged() {
    if (!mounted || _controller == null) return;
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final AudioCue? cue = controller.currentCue;
    if (cue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag != null && frag.sectionIndex != _currentChapter) {
        AudiobookBridge.highlight(_controller!, cue: null);
        return;
      }
    }
    final bool forceReveal = controller.consumeForceReveal();
    final bool reveal =
        forceReveal || controller.shouldRevealCurrentCue;
    if (reveal) {
      debugPrint('[_onCueChanged] reveal cue=${cue?.textFragmentId} '
          'forceReveal=$forceReveal '
          'follow=${controller.followAudio.value} '
          'playing=${controller.isPlaying}');
    }
    AudiobookBridge.highlight(_controller!, cue: cue, reveal: reveal);
    _syncFloatingLyric(controller);
    _syncMediaNotification(controller);
  }

  Future<void> _handleCueCrossChapter(int newSection) async {
    if (_restoreInFlight) return;
    if (_book == null || newSection < 0 || newSection >= _book!.chapters.length) {
      return;
    }
    await _navigateToChapter(newSection);
  }

  Future<void> _handleBoundarySkip(int delta) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final int targetSec = _currentChapter + delta;
    if (_book == null || targetSec < 0 || targetSec >= _book!.chapters.length) {
      return;
    }
    final List<AudioCue> targetCues =
        controller.sasayakiCuesForSection(targetSec);
    if (targetCues.isEmpty) {
      await _navigateToChapter(targetSec);
      return;
    }
    await controller.skipToCue(targetCues.first);
  }

  AudioCue? _lookupCue;
  ({int offset, int length, String text})? _cachedSelectionRange;
  ({int offset, int length})? _cachedSentenceRange;
  bool _currentSentenceIsFavorited = false;

  AudioCue? _findCueForOffset(int normalizedOffset) {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) return null;
    final List<AudioCue> cues = ctrl.sasayakiCuesForSection(_currentChapter);
    for (final AudioCue cue in cues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag == null) continue;
      if (frag.normCharStart <= normalizedOffset &&
          frag.normCharEnd > normalizedOffset) {
        return cue;
      }
    }
    return null;
  }

  @override
  void clearDictionaryResult() {
    _lookupCue = null;
    _cachedSelectionRange = null;
    _cachedSentenceRange = null;
    _currentSentenceIsFavorited = false;
    super.clearDictionaryResult();
  }

  @override
  Future<bool> onMineFromPopup(Map<String, String> fields) async {
    final AnkiRepository repo = ref.read(ankiRepositoryProvider);
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';

    String? coverPath;
    if (_book?.coverHref != null && _extractDir != null) {
      final File coverFile = File(p.join(_extractDir!, _book!.coverHref!));
      if (coverFile.existsSync()) coverPath = coverFile.path;
    }

    String? sasayakiAudioPath;
    final AudioCue? cue = _lookupCue;
    final List<File>? audioFiles = _audiobookController?.audioFiles;
    if (cue != null && audioFiles != null && cue.audioFileIndex < audioFiles.length) {
      final File inputFile = audioFiles[cue.audioFileIndex];
      final String outputPath =
          '${Directory.systemTemp.path}/mine_sentence_audio.aac';
      sasayakiAudioPath = await TtsChannel.instance.extractAudioSegment(
        inputPath: inputFile.path,
        startMs: cue.startMs,
        endMs: cue.endMs,
        outputPath: outputPath,
      );
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      documentTitle: _book?.title,
      coverPath: coverPath,
      sasayakiAudioPath: sasayakiAudioPath,
      sentenceOffset: _cachedSentenceRange?.offset,
    );

    final MineResult result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );

    switch (result) {
      case MineResult.success:
        final AnkiSettings settings = await repo.loadSettings();
        Fluttertoast.showToast(
          msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
        );
        return true;
      case MineResult.duplicate:
        Fluttertoast.showToast(msg: t.card_duplicate);
        return false;
      case MineResult.notConfigured:
        Fluttertoast.showToast(msg: t.card_export_not_configured);
        return false;
      case MineResult.error:
        Fluttertoast.showToast(msg: t.card_export_failed);
        return false;
    }
  }

  List<AudioCue>? _cachedAllCues;
  bool _cachedSasayaki = false;

  Future<String?> _prepareSasayakiCuesJson() async {
    _cachedAllCues = null;
    _cachedSasayaki = false;

    if (_srtBookUid != null) {
      final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
      final List<AudioCue> cues = await srtRepo.cuesFor(_srtBookUid!);
      _cachedAllCues = cues;
      return null;
    }
    if (_audiobookBookUid == null) return null;

    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<AudioCue> allCues =
        await repo.cuesForBook(_audiobookBookUid!);
    _cachedAllCues = allCues;
    _cachedSasayaki = allCues.any(
      (AudioCue c) =>
          SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
    );

    if (!_cachedSasayaki) return null;

    final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];
    for (final AudioCue cue in allCues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag == null || frag.sectionIndex != _currentChapter) continue;
      payload.add(<String, dynamic>{
        'id': cue.textFragmentId,
        'start': frag.normCharStart,
        'length': frag.normCharEnd - frag.normCharStart,
      });
    }
    if (payload.isEmpty) return null;
    return jsonEncode(payload);
  }

  Future<void> _injectAudiobookBridge() async {
    if (_controller == null || _audiobookController == null) return;

    final Color primary = Theme.of(context).colorScheme.primary;
    await AudiobookBridge.inject(_controller!, primaryColor: primary);

    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) return;

    if (_srtBookUid != null) {
      _audiobookController!.setChapterCues(allCues);
      _audiobookController!.setAllBookCues(allCues);
    } else if (_audiobookBookUid != null) {
      if (_cachedSasayaki) {
        _audiobookController!.setChapterCues(allCues);
        _audiobookController!.setAllBookCues(allCues);
      } else {
        final String chapterHref = _book!.chapters[_currentChapter].href;
        final AudiobookRepository repo =
            AudiobookRepository(appModel.database);
        final List<AudioCue> cues = await repo.cuesForChapter(
          bookUid: _audiobookBookUid!,
          chapterHref: chapterHref,
        );
        _audiobookController!.setChapterCues(cues);
        _audiobookController!.setAllBookCues(allCues);
        if (cues.isEmpty) {
          await AudiobookBridge.annotate(
            _controller!,
            chapterHref: chapterHref,
          );
        }
      }
    }
    _onCueChanged();
  }

  // ── Chapter Navigation ────────────────────────────────────────────

  Future<void> _reloadAtCurrentProgress() async {
    if (_controller == null) return;
    await _navigateToChapter(_currentChapter, progress: _displayedProgress);
  }

  Future<void> _navigateToChapter(int index, {double progress = 0.0}) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return;
    }
    if (_controller == null) {
      return;
    }

    _progressPollTimer?.cancel();
    _flushReadingStats();

    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete();
    }
    _restoreCompleter = Completer<void>();

    _currentChapter = index;
    _initialProgress = progress;
    _displayedProgress = progress;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshi._navigateToChapter', e, stack);
      debugPrint('[ReaderHoshi] _navigateToChapter loadUrl failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete();
      }
      _restoreCompleter = null;
    }
  }

  Future<void> _navigateToChapterAndWait(int index) async {
    await _navigateToChapter(index);
    await _restoreCompleter?.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('[ReaderHoshi] _navigateToChapterAndWait timed out');
        _isNavigatingToChapter = false;
        _restoreCompleter = null;
        _restoreInFlight = false;
      },
    );
  }

  Future<void> _navigateToChapterWithFragment(
    int index,
    String? fragment,
  ) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) return;
    if (_controller == null) return;

    _progressPollTimer?.cancel();
    _audiobookController?.cancelChapterTransition();
    _flushReadingStats();

    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete();
    }
    _restoreCompleter = Completer<void>();

    _currentChapter = index;
    _initialProgress = 0.0;
    _displayedProgress = 0.0;
    _initialFragment = fragment;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshi._navigateToChapterWithFragment', e, stack);
      debugPrint('[ReaderHoshi] _navigateToChapterWithFragment loadUrl failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete();
      }
      _restoreCompleter = null;
    }
  }

  void _handlePageTurnLimit(String direction) {
    if (_book == null) {
      return;
    }
    _audiobookController?.cancelChapterTransition();
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

    _lookupCue = data.normalizedOffset != null
        ? _findCueForOffset(data.normalizedOffset!)
        : null;

    final int highlightCount = await searchDictionaryResult(
      searchTerm: data.text,
      selectionRect: selectionRect,
    );

    if (highlightCount > 0 && _controller != null) {
      await _controller!.evaluateJavascript(
        source: ReaderSelectionScripts.highlightInvocation(highlightCount),
      );
    }
    if (data.normalizedOffset != null && data.normalizedLength != null) {
      _cachedSelectionRange = (
        offset: data.normalizedOffset!,
        length: data.normalizedLength!,
        text: data.text,
      );
    } else {
      _cachedSelectionRange = null;
    }
    if (data.sentenceNormalizedOffset != null &&
        data.sentenceNormalizedLength != null) {
      _cachedSentenceRange = (
        offset: data.sentenceNormalizedOffset!,
        length: data.sentenceNormalizedLength!,
      );
    } else {
      _cachedSentenceRange = null;
    }
    _checkFavoriteStatus();
  }

  Future<void> _checkFavoriteStatus() async {
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    if (sentence.isEmpty) {
      if (_currentSentenceIsFavorited) {
        setState(() => _currentSentenceIsFavorited = false);
      }
      return;
    }
    final sentenceRange = _cachedSentenceRange ?? (
      _cachedSelectionRange != null
          ? (offset: _cachedSelectionRange!.offset,
             length: _cachedSelectionRange!.length)
          : null
    );
    final bool favorited = await FavoriteSentenceRepository(appModel.database)
        .isFavorited(
      text: sentence,
      ttuBookId: widget.bookId,
      sectionIndex: _currentChapter,
      normCharOffset: sentenceRange?.offset,
    );
    if (mounted && favorited != _currentSentenceIsFavorited) {
      setState(() => _currentSentenceIsFavorited = favorited);
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
    _displayedProgress = progress;
    final int absoluteChars = _absoluteCharPosition(progress);
    final int charDiff = absoluteChars - _lastAbsoluteCount;
    if (charDiff > 0) {
      _sessionCharsRead += charDiff;
    }
    _lastAbsoluteCount = absoluteChars;
    _debouncedSavePosition(progress);

    if (mounted) {
      setState(() {
        _progressCurrentChars = absoluteChars;
        _progressTotalChars = _chapterCumulativeChars.isNotEmpty
            ? _chapterCumulativeChars.last + _chapterCharCounts.last
            : total;
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
    debugPrint('[ReaderHoshi] save position: bookId=${widget.bookId} '
        'section=$section normOffset=$normOffset');
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
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshi._flushReadingStats', e, stack);
    }
  }

  int _absoluteCharPosition(double progress) {
    if (_chapterCumulativeChars.isEmpty ||
        _currentChapter >= _chapterCumulativeChars.length) {
      return 0;
    }
    return _chapterCumulativeChars[_currentChapter] +
        (progress * _chapterCharCounts[_currentChapter]).round();
  }

  Future<void> _jumpToGlobalCharOffset(int globalOffset) async {
    if (_chapterCumulativeChars.isEmpty || _controller == null) return;

    int targetChapter = 0;
    for (int i = 0; i < _chapterCumulativeChars.length; i++) {
      if (_chapterCumulativeChars[i] <= globalOffset) {
        targetChapter = i;
      } else {
        break;
      }
    }

    final int chapterStart = _chapterCumulativeChars[targetChapter];
    final int chapterLen = _chapterCharCounts[targetChapter];
    final double progress =
        chapterLen > 0 ? (globalOffset - chapterStart) / chapterLen : 0;

    if (targetChapter != _currentChapter) {
      _navigateToChapter(targetChapter, progress: progress.clamp(0.0, 1.0));
    } else {
      await _controller!.evaluateJavascript(
        source:
            'window.hoshiReader && window.hoshiReader.restoreProgress(${progress.clamp(0.0, 1.0)});',
      );
    }
  }

  void _flushReadingStats() {
    if (_sessionCharsRead <= 0 || _book == null) return;
    final DateTime now = DateTime.now();
    final int elapsedMs = now.difference(_sessionStartTime).inMilliseconds;
    final String dateKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    appModel.database
        .addReadingStatistic(
          title: _book!.title,
          dateKey: dateKey,
          charsRead: _sessionCharsRead,
          timeMs: elapsedMs,
        )
        .catchError((Object e) {
      debugPrint('[ReaderHoshi] stats flush error: $e');
    });
    _sessionCharsRead = 0;
    _sessionStartTime = DateTime.now();
  }

  // ── Key Navigation ────────────────────────────────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final LogicalKeyboardKey key = event.logicalKey;

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
    if (_settings?.isContinuousMode == true) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.paginateInvocation(direction),
      );
      if (!_didScroll(result)) {
        _handlePageTurnLimit(direction.jsValue);
      }
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

  // ── Image Viewer ──────────────────────────────────────────────────

  void _openImageViewer(String imgUrl) {
    final Uri? uri = Uri.tryParse(imgUrl);
    if (uri == null || _extractDir == null) return;
    if (uri.host != ReaderHoshiSource.kHost) return;
    final String epubPath =
        Uri.decodeComponent(uri.path.substring('/epub/'.length));
    final String filePath = p.join(_extractDir!, epubPath);
    final File file = File(filePath);
    if (!file.existsSync()) return;
    final Uint8List bytes = file.readAsBytesSync();
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5.0,
            child: Center(
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  // ── Audio Features Init ────────────────────────────────────────────

  Future<void> _initAudioFeatures(AudiobookPlayerController ctrl) async {
    _subscribeNotificationStreams(ctrl);
    if (appModel.showFloatingLyric) {
      final bool canDraw = await FloatingLyricChannel.canDrawOverlays();
      if (canDraw) {
        await _showFloatingLyricOverlay();
        _syncFloatingLyric(ctrl);
      }
    }
    if (appModel.showMediaNotification) {
      _setMediaItemWithCover(ctrl);
      _syncMediaNotification(ctrl);
    }
  }

  void _subscribeNotificationStreams(AudiobookPlayerController ctrl) {
    _playStreamSub?.cancel();
    _seekStreamSub?.cancel();
    _skipNextSub?.cancel();
    _skipPrevSub?.cancel();
    _playStreamSub = appModel.playStream.listen((_) {
      ctrl.togglePlayPause();
    });
    _seekStreamSub = appModel.seekStream.listen((Duration pos) {
      ctrl.seekMs(pos.inMilliseconds);
    });
    _skipNextSub = appModel.skipNextStream.listen((_) {
      ctrl.skipToNextCue();
    });
    _skipPrevSub = appModel.skipPreviousStream.listen((_) {
      ctrl.skipToPrevCue();
    });
  }

  void _setMediaItemWithCover(AudiobookPlayerController ctrl) {
    final handler = appModel.audioHandler;
    if (handler == null) return;
    Uri? artUri;
    if (_book?.coverHref != null && _extractDir != null) {
      final File coverFile = File(p.join(_extractDir!, _book!.coverHref!));
      if (coverFile.existsSync()) {
        artUri = coverFile.uri;
      }
    }
    handler.setMediaItemInfo(
      title: _book?.title ?? 'Hibiki',
      artist: _book?.author,
      duration: ctrl.duration,
      artUri: artUri,
    );
  }

  // ── Floating Lyric ─────────────────────────────────────────────────

  Future<void> _showFloatingLyricOverlay() async {
    await FloatingLyricChannel.show();
    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final bool dark = _isReaderThemeDark;
    await FloatingLyricChannel.updateStyle(
      fontSize: appModel.floatingLyricFontSize,
      textColor: fg.value,
      bgColor: bg.withAlpha(dark ? 230 : 220).value,
      buttonTextColor: fg.value,
      buttonBgColor: (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
    );
    await FloatingLyricChannel.updateLabels(
      previous: t.floating_lyric_previous,
      playPause: t.floating_lyric_play_pause,
      next: t.floating_lyric_next,
      lock: t.floating_lyric_lock,
      unlock: t.floating_lyric_unlock,
      close: t.floating_lyric_close,
    );
    _setupFloatingLyricHandlers();
  }

  Future<bool> _toggleFloatingLyric() async {
    final bool current = appModel.showFloatingLyric;
    if (!current) {
      final bool shown = await FloatingLyricChannel.show();
      if (!shown) return false;
      final Color bg = _themeBackgroundColor();
      final Color fg = _themeTextColor();
      final bool dark = _isReaderThemeDark;
      await FloatingLyricChannel.updateStyle(
        fontSize: appModel.floatingLyricFontSize,
        textColor: fg.value,
        bgColor: bg.withAlpha(dark ? 230 : 220).value,
        buttonTextColor: fg.value,
        buttonBgColor: (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
      );
      await FloatingLyricChannel.updateLabels(
        previous: t.floating_lyric_previous,
        playPause: t.floating_lyric_play_pause,
        next: t.floating_lyric_next,
        lock: t.floating_lyric_lock,
        unlock: t.floating_lyric_unlock,
        close: t.floating_lyric_close,
      );
      await appModel.setShowFloatingLyric(true);
      _setupFloatingLyricHandlers();
      if (_audiobookController != null) {
        _syncFloatingLyric(_audiobookController!);
      }
    } else {
      await FloatingLyricChannel.hide();
      FloatingLyricChannel.clearEventHandlers();
      await appModel.setShowFloatingLyric(false);
    }
    return true;
  }

  void _setupFloatingLyricHandlers() {
    FloatingLyricChannel.setEventHandlers(
      onPlayPause: () => _audiobookController?.togglePlayPause(),
      onPreviousCue: () => _audiobookController?.skipToPrevCue(),
      onNextCue: () => _audiobookController?.skipToNextCue(),
      onClose: () async {
        await FloatingLyricChannel.hide();
        FloatingLyricChannel.clearEventHandlers();
        await appModel.setShowFloatingLyric(false);
      },
    );
  }

  void _syncFloatingLyric(AudiobookPlayerController ctrl) {
    if (!appModel.showFloatingLyric) return;
    final AudioCue? cue = ctrl.currentCue;
    FloatingLyricChannel.updateText(cue?.text ?? '');
    FloatingLyricChannel.setPlaybackState(playing: ctrl.isPlaying);
  }

  // ── Media Notification ────────────────────────────────────────────

  void _syncMediaNotification(AudiobookPlayerController ctrl) {
    if (!appModel.showMediaNotification) return;
    final handler = appModel.audioHandler;
    if (handler == null) return;
    handler.updatePlaybackState(
      playing: ctrl.isPlaying,
      position: ctrl.position,
      speed: ctrl.speed,
      duration: ctrl.duration,
    );
    final AudioCue? cue = ctrl.currentCue;
    if (cue != null) {
      handler.updateNotificationSubtitle(
        title: _book?.title ?? 'Hibiki',
        subtitle: cue.text,
      );
    }
  }

  Future<void> _toggleMediaNotification() async {
    final bool newValue = !appModel.showMediaNotification;
    await appModel.setShowMediaNotification(newValue);
    if (newValue && _audiobookController != null) {
      _setMediaItemWithCover(_audiobookController!);
      _syncMediaNotification(_audiobookController!);
    } else {
      appModel.audioHandler?.clearNotification();
    }
  }

  // ── Bottom Chrome ─────────────────────────────────────────────────

  void _toggleChrome() {
    setState(() {
      _showChrome = !_showChrome;
    });
  }

  Widget _buildBottomChrome() {
    if (!_readerContentReady || !_showChrome) {
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
      builder: (BuildContext context, Widget? _) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AudiobookPlayBar(
                controller: ctrl,
                onOpenSettings: _showAppearanceSheet,
                backgroundColor: _themeBackgroundColor(),
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
        );
      },
    );
  }

  Widget _buildSettingsBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ColoredBox(
            color: _themeBackgroundColor(),
            child: SizedBox(
              height: _readerChromeHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      icon: Icon(Icons.headphones, color: _themeTextColor()),
                      iconSize: 22,
                      onPressed: _openAudioImportDialog,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.tune, color: _themeTextColor()),
                      iconSize: 20,
                      onPressed: _showAppearanceSheet,
                    ),
                  ],
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
    );
  }

  Future<void> _openAudioImportDialog() async {
    final String bookUid = ReaderHoshiSource.bookUidFor(widget.bookId);
    final AudiobookRepository repo = AudiobookRepository(appModel.database);

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AudiobookImportDialog(
        bookUid: bookUid,
        repo: repo,
        ttuBookId: widget.bookId,
      ),
    );

    await _resolveAudioSlot();
    if (mounted) setState(() {});
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

  Future<void> _showAppearanceSheet() async {
    if (_settings == null || _controller == null || _book == null) return;

    _syncSettingsToHive();

    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    final double snapshotFontSize = src.ttuFontSize;
    final double snapshotLineHeight = src.ttuLineHeight;
    final String snapshotWritingMode = src.ttuWritingMode;
    final String snapshotViewMode = src.ttuViewMode;
    final String snapshotTheme = src.ttuTheme;
    final String snapshotFuriganaMode = src.ttuFuriganaMode;
    final double snapshotTextIndentation = src.ttuTextIndentation;
    final double snapshotFirstDimensionMargin = src.ttuFirstDimensionMargin;
    final double snapshotSecondDimensionMargin = src.ttuSecondDimensionMargin;
    final double snapshotSecondDimensionMaxValue = src.ttuSecondDimensionMaxValue;
    final int snapshotPageColumns = src.ttuPageColumns;
    final bool snapshotVerticalFontKerning = src.ttuEnableVerticalFontKerning;
    final bool snapshotFontVPAL = src.ttuEnableFontVPAL;
    final String snapshotVerticalTextOrientation = src.ttuVerticalTextOrientation;
    final bool snapshotTextJustification = src.ttuEnableTextJustification;
    final bool snapshotPrioritizeReaderStyles = src.ttuPrioritizeReaderStyles;
    final String snapshotCustomFontsRaw =
        src.getPreference<String>(key: 'custom_fonts', defaultValue: '[]');

    final List<TtuTocEntry> toc = _buildTtuToc();
    final int bookId = widget.bookId;
    final BookmarkRepository bmRepo = BookmarkRepository(appModel.database);
    final FavoriteSentenceRepository favRepo =
        FavoriteSentenceRepository(appModel.database);

    List<Bookmark> bookmarks = await bmRepo.getBookmarks(bookId);
    final List<FavoriteSentence> allFavorites = await favRepo.getAll();
    final List<FavoriteSentence> favorites = allFavorites
        .where((FavoriteSentence f) => f.ttuBookId == bookId)
        .toList();

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        return AudiobookSettingsSheet(
          controller: _audiobookController,
          toc: toc,
          readerProgress: (_currentChapter + 1, _book!.chapters.length),
          onJumpSection: (int index) async {
            _navigateToChapter(index);
          },
          onBookmark: () async {
            await _addBookmarkAtCurrentPosition();
          },
          onExitReader: () {
            Navigator.of(context).pop();
          },
          webViewController: _controller!,
          appModel: appModel,
          isHoshiReader: true,
          showFloatingLyric: appModel.showFloatingLyric,
          onToggleFloatingLyric: _toggleFloatingLyric,
          floatingLyricFontSize: appModel.floatingLyricFontSize,
          onFloatingLyricFontSizeChanged: (double v) async {
            await appModel.setFloatingLyricFontSize(v);
            final Color bg = _themeBackgroundColor();
            final Color fg = _themeTextColor();
            final bool dark = _isReaderThemeDark;
            await FloatingLyricChannel.updateStyle(
              fontSize: v,
              textColor: fg.value,
              bgColor: bg.withAlpha(dark ? 230 : 220).value,
              buttonTextColor: fg.value,
              buttonBgColor: (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
            );
          },
          showMediaNotification: appModel.showMediaNotification,
          onToggleMediaNotification: _toggleMediaNotification,
          charProgress: _progressCurrentChars != null &&
                  _progressTotalChars != null
              ? (_progressCurrentChars!, _progressTotalChars!)
              : null,
          onJumpToCharOffset: (int globalOffset) async {
            _jumpToGlobalCharOffset(globalOffset);
          },
          bookmarks: bookmarks,
          onJumpToBookmark: (Bookmark bm) async {
            if (bm.sectionIndex != _currentChapter) {
              await _navigateToChapterAndWait(bm.sectionIndex);
            }
            final double progress = bm.normCharOffset / 10000.0;
            await _controller!.evaluateJavascript(
              source:
                  'window.hoshiReader && window.hoshiReader.restoreProgress($progress);',
            );
          },
          onDeleteBookmark: (int index) async {
            await bmRepo.removeBookmark(bookId, index);
            bookmarks = await bmRepo.getBookmarks(bookId);
          },
          favoriteSentences: favorites,
          onDeleteFavorite: (int index) async {
            if (index >= 0 && index < favorites.length) {
              await favRepo.removeById(favorites[index].id);
            }
          },
          onJumpToFavorite: (FavoriteSentence fav) async {
            if (fav.sectionIndex == null) return;
            if (fav.sectionIndex != _currentChapter) {
              await _navigateToChapterAndWait(fav.sectionIndex!);
            }
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
              : (FavoriteSentence fav) async {
                  if (fav.normCharOffset == null ||
                      fav.sectionIndex == null) {
                    return;
                  }
                  final int section = fav.sectionIndex!;
                  final List<AudioCue> cues = _audiobookController!
                      .sasayakiCuesForSection(section);
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
      },
    );

    final ReaderHoshiSource srcAfter = ReaderHoshiSource.instance;
    final bool changed = srcAfter.ttuFontSize != snapshotFontSize ||
        srcAfter.ttuLineHeight != snapshotLineHeight ||
        srcAfter.ttuWritingMode != snapshotWritingMode ||
        srcAfter.ttuViewMode != snapshotViewMode ||
        srcAfter.ttuTheme != snapshotTheme ||
        srcAfter.ttuFuriganaMode != snapshotFuriganaMode ||
        srcAfter.ttuTextIndentation != snapshotTextIndentation ||
        srcAfter.ttuFirstDimensionMargin != snapshotFirstDimensionMargin ||
        srcAfter.ttuSecondDimensionMargin != snapshotSecondDimensionMargin ||
        srcAfter.ttuSecondDimensionMaxValue != snapshotSecondDimensionMaxValue ||
        srcAfter.ttuPageColumns != snapshotPageColumns ||
        srcAfter.ttuEnableVerticalFontKerning != snapshotVerticalFontKerning ||
        srcAfter.ttuEnableFontVPAL != snapshotFontVPAL ||
        srcAfter.ttuVerticalTextOrientation != snapshotVerticalTextOrientation ||
        srcAfter.ttuEnableTextJustification != snapshotTextJustification ||
        srcAfter.ttuPrioritizeReaderStyles != snapshotPrioritizeReaderStyles ||
        srcAfter.getPreference<String>(
                key: 'custom_fonts', defaultValue: '[]') !=
            snapshotCustomFontsRaw;

    _syncSettingsFromHive();
    _syncDictionaryTheme();
    if (changed) {
      _reloadWithCurrentSettings();
    }
  }

  Future<void> _addBookmarkAtCurrentPosition() async {
    if (_controller == null) return;

    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.progressInvocation(),
    );
    final double? progress = _toDouble(result);
    if (progress == null) return;

    final int normOffset = (progress * 10000).round();
    final String label = _book?.toc.isNotEmpty == true
        ? _currentChapterLabel()
        : 'Ch. ${_currentChapter + 1}';

    final Bookmark bm = Bookmark(
      sectionIndex: _currentChapter,
      normCharOffset: normOffset,
      label: label,
      createdAt: DateTime.now(),
      ttuBookId: widget.bookId,
      bookTitle: _book?.title,
    );

    await BookmarkRepository(appModel.database)
        .addBookmark(widget.bookId, bm);
  }

  String _currentChapterLabel() {
    if (_book == null) return '';
    final List<TtuTocEntry> toc = _buildTtuToc();
    for (int i = toc.length - 1; i >= 0; i--) {
      if (toc[i].index <= _currentChapter) {
        return toc[i].label;
      }
    }
    return 'Ch. ${_currentChapter + 1}';
  }

  void _syncSettingsToHive() {
    final ReaderSettings s = _settings!;
    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    src.setTtuFontSize(s.fontSize);
    src.setTtuLineHeight(s.lineHeight);
    src.setTtuWritingMode(s.writingMode);
    src.setTtuViewMode(s.viewMode);
    src.setTtuTheme(s.theme);
    src.setTtuFuriganaMode(s.furiganaMode);
    src.setTtuTextIndentation(s.textIndentation);
    src.setTtuFirstDimensionMargin(s.firstDimensionMargin);
    src.setTtuSecondDimensionMaxValue(s.secondDimensionMaxValue);
    src.setTtuPageColumns(s.pageColumns);
    src.setTtuEnableVerticalFontKerning(s.enableVerticalFontKerning);
    src.setTtuEnableFontVPAL(s.enableFontVPAL);
    src.setTtuVerticalTextOrientation(s.verticalTextOrientation);
    src.setTtuEnableTextJustification(s.enableTextJustification);
    src.setTtuPrioritizeReaderStyles(s.prioritizeReaderStyles);
  }

  void _syncSettingsFromHive() {
    final ReaderSettings s = _settings!;
    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    s.setFontSize(src.ttuFontSize);
    s.setLineHeight(src.ttuLineHeight);
    s.setWritingMode(src.ttuWritingMode);
    s.setViewMode(src.ttuViewMode);
    s.setTheme(src.ttuTheme);
    s.setFuriganaMode(src.ttuFuriganaMode);
    s.setTextIndentation(src.ttuTextIndentation);
    s.setFirstDimensionMargin(src.ttuFirstDimensionMargin);
    s.setSecondDimensionMaxValue(src.ttuSecondDimensionMaxValue);
    s.setPageColumns(src.ttuPageColumns);
    s.setEnableVerticalFontKerning(src.ttuEnableVerticalFontKerning);
    s.setEnableFontVPAL(src.ttuEnableFontVPAL);
    s.setVerticalTextOrientation(src.ttuVerticalTextOrientation);
    s.setEnableTextJustification(src.ttuEnableTextJustification);
    s.setPrioritizeReaderStyles(src.ttuPrioritizeReaderStyles);
  }

  List<TtuTocEntry> _buildTtuToc() {
    final List<EpubTocItem> toc = _book!.toc;
    if (toc.isEmpty) {
      return List<TtuTocEntry>.generate(
        _book!.chapters.length,
        (int i) => TtuTocEntry(index: i, label: 'Chapter ${i + 1}'),
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
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.progressInvocation(),
    );
    final double? progress = _toDouble(result);
    _initialProgress = progress ?? 0.0;
    _restoreInFlight = true;
    debugPrint('[ReaderHoshi] reloadWithCurrentSettings: '
        'chapter=$_currentChapter progress=$_initialProgress '
        'continuous=${_settings?.isContinuousMode}');

    setState(() {
      _readerContentReady = false;
    });

    await _loadChapterDirectly(_currentChapter);
  }

  // ── Top Progress Bar ──────────────────────────────────────────────

  Color _infoTextColor() {
    final String theme = _settings?.theme ?? 'light-theme';
    switch (theme) {
      case 'gray-theme':
      case 'dark-theme':
      case 'black-theme':
        return const Color(0x99FFFFFF);
      case 'ecru-theme':
        return const Color(0x7A5C5448);
      default:
        return const Color(0x8A000000);
    }
  }

  Widget _buildTopProgressBar() {
    if (!_showTopProgress) {
      return const SizedBox.shrink();
    }

    final double ratio =
        (_progressCurrentChars! / _progressTotalChars!).clamp(0.0, 1.0);
    final Color infoColor = _infoTextColor();

    return Positioned(
      top: _stableTopInset,
      left: 96,
      right: 96,
      child: IgnorePointer(
        child: Text(
          '$_progressCurrentChars / $_progressTotalChars'
          '  ${(ratio * 100).toStringAsFixed(2)}%',
          style: TextStyle(fontSize: _infoFontSize, color: infoColor),
          textAlign: TextAlign.center,
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
      case 'custom-theme':
        return appModel.customThemeBackgroundColor ??
            const Color(0xFFFFFFFF);
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
      case 'custom-theme':
        final Color? fg = appModel.customThemeFontColor;
        if (fg != null) return fg;
        final bool dark = appModel.customThemeDark;
        return dark ? const Color(0xDEFFFFFF) : const Color(0xDE000000);
      default:
        return const Color(0xDE000000);
    }
  }

  bool get _isReaderThemeDark {
    final String theme = _settings?.theme ?? 'light-theme';
    if (theme == 'custom-theme') return appModel.customThemeDark;
    return theme == 'gray-theme' ||
        theme == 'dark-theme' ||
        theme == 'black-theme';
  }

  String get _readerBackgroundHex {
    final Color bg = _themeBackgroundColor();
    return '#${(bg.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  String? get _customThemeTextCss {
    final Color c = _themeTextColor();
    return 'rgba(${c.red},${c.green},${c.blue},${(c.alpha / 255).toStringAsFixed(2)})';
  }

  String? get _customHighlightCss {
    if (_settings?.theme != 'custom-theme') return null;
    final Color? c = appModel.customThemePrimaryColor;
    if (c == null) return null;
    return 'rgba(${c.red},${c.green},${c.blue},0.34)';
  }

  void _syncDictionaryTheme() {
    final Color bg = _themeBackgroundColor();
    final Color textColor = _themeTextColor();
    final Brightness brightness =
        _isReaderThemeDark ? Brightness.dark : Brightness.light;
    appModel.setOverrideDictionaryColor(bg);
    appModel.setOverrideDictionaryTheme(
      (brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light())
          .copyWith(colorScheme: ColorScheme.fromSeed(
        seedColor: bg,
        brightness: brightness,
      ).copyWith(
        onSurface: textColor,
      )),
    );
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

  // ── Popup Audio Controls ───────────────────────────────────────────

  Future<void> _toggleFavoriteSentence() async {
    if (_controller == null || _book == null) return;
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    if (sentence.isEmpty) {
      Fluttertoast.showToast(msg: t.no_sentence_selected);
      return;
    }

    final sentenceRange = _cachedSentenceRange ?? (
      _cachedSelectionRange != null
          ? (offset: _cachedSelectionRange!.offset,
             length: _cachedSelectionRange!.length)
          : null
    );
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);

    if (_currentSentenceIsFavorited) {
      await repo.removeByContent(
        text: sentence,
        ttuBookId: widget.bookId,
        sectionIndex: _currentChapter,
        normCharOffset: sentenceRange?.offset,
      );
      setState(() => _currentSentenceIsFavorited = false);
      if (sentenceRange != null) {
        final List<FavoriteSentence> all = await repo.getAll();
        final List<FavoriteSentence> chapterFavs = all
            .where((FavoriteSentence s) =>
                s.ttuBookId == widget.bookId &&
                s.sectionIndex == _currentChapter)
            .toList();
        await HighlightBridge.applyHighlights(_controller!, chapterFavs,
            backgroundHex: _readerBackgroundHex,
            customHighlightCss: _customHighlightCss);
        await _controller!.evaluateJavascript(
          source:
              'window.hoshiReader && window.hoshiReader.buildNodeOffsets();',
        );
      }
      Fluttertoast.showToast(msg: t.favorite_removed);
      return;
    }

    final FavoriteSentence fav = FavoriteSentence(
      text: sentence,
      bookTitle: _book!.title,
      chapterLabel: _currentChapter < _book!.chapters.length
          ? _book!.chapters[_currentChapter].href
          : null,
      createdAt: DateTime.now(),
      ttuBookId: widget.bookId,
      sectionIndex: _currentChapter,
      normCharOffset: sentenceRange?.offset,
      normCharLength: sentenceRange?.length,
    );
    await repo.add(fav);
    setState(() => _currentSentenceIsFavorited = true);
    if (sentenceRange != null) {
      final List<FavoriteSentence> all = await repo.getAll();
      final List<FavoriteSentence> chapterFavs = all
          .where((FavoriteSentence s) =>
              s.ttuBookId == widget.bookId &&
              s.sectionIndex == _currentChapter)
          .toList();
      await HighlightBridge.applyHighlights(_controller!, chapterFavs,
          backgroundHex: _readerBackgroundHex,
          customHighlightCss: _customHighlightCss);
      await _controller!.evaluateJavascript(
        source: 'window.hoshiReader && window.hoshiReader.buildNodeOffsets();',
      );
    }
    Fluttertoast.showToast(msg: t.favorite_added);
  }

  @override
  Widget? buildPopupAudioControls() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    final bool hasAudio = ctrl != null && ctrl.chapterCueCount > 0;

    Widget buildRow(ThemeData theme) {
      final AudioCue? cue = _lookupCue;
      final bool hasCue = cue != null;
      return Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor,
              width: 0.5,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(
                _currentSentenceIsFavorited ? Icons.star : Icons.star_border,
                size: 20,
                color: _currentSentenceIsFavorited
                    ? theme.colorScheme.primary
                    : null,
              ),
              onPressed: _toggleFavoriteSentence,
              tooltip: t.action_favorite,
              visualDensity: VisualDensity.compact,
            ),
            if (hasAudio) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.replay, size: 20),
                onPressed: hasCue
                    ? () => ctrl.playCueOnce(cue)
                    : null,
                tooltip: t.repeat_cue,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  ctrl.isPlaying ? Icons.pause : Icons.play_arrow,
                  size: 24,
                ),
                onPressed: () => ctrl.togglePlayPause(),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.play_circle_outline, size: 20),
                onPressed: hasCue
                    ? () {
                        ctrl.playCueAndContinue(cue);
                        clearDictionaryResult();
                      }
                    : null,
                tooltip: t.play_from_cue,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
      );
    }

    if (!hasAudio) {
      return Builder(
        builder: (BuildContext context) =>
            buildRow(Theme.of(context)),
      );
    }

    return ListenableBuilder(
      listenable: ctrl,
      builder: (BuildContext context, _) {
        return buildRow(Theme.of(context));
      },
    );
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
