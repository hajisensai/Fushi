import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/highlight_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/sources/reader_hoshi_source.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_resource_sanitizer.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/volume_key_channel.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';

class ReaderHoshiPage extends BaseSourcePage {
  const ReaderHoshiPage({
    required this.bookId,
    super.item,
    this.initialBookmarkJump,
    super.key,
  });

  final int bookId;
  final Bookmark? initialBookmarkJump;

  @override
  BaseSourcePageState<ReaderHoshiPage> createState() => _ReaderHoshiPageState();
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
  double _initialProgress = 0;
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
  int _lastProgressSection = -1;
  double _lastProgressValue = 0;

  AudiobookPlayerController? _audiobookController;
  String? _audiobookBookUid;
  String? _srtBookUid;

  bool _audioSlotResolved = false;

  bool _lyricsMode = false;
  bool _lyricsModeTransition = false;

  @override
  bool get shouldDisablePopupScrim => _lyricsMode || super.shouldDisablePopupScrim;
  bool _lyricsPageReady = false;
  int _lyricsEntryChapter = 0;
  int _lyricsEntryCueIndex = 0;
  List<AudioCue> _lyricsCueList = const [];

  bool _pausedForLookup = false;

  ReadingTimeTracker? _readingTimeTracker;

  StreamSubscription<void>? _playStreamSub;
  StreamSubscription<Duration>? _seekStreamSub;
  StreamSubscription<void>? _skipNextSub;
  StreamSubscription<void>? _skipPrevSub;

  bool _showChrome = true;
  double _lastSyncedWidth = 0;
  double _lastSyncedHeight = 0;
  double _displayedProgress = 0;

  final FocusNode _focusNode = FocusNode();

  bool get _showTopProgress =>
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0;

  double get _readerTopOffset => _stableTopInset + _infoFontSize * 1.5;

  double get _readerBottomReserve => _readerChromeHeight + _stableBottomInset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReaderHoshiSource.onSettingsChangedLive = () {
      if (mounted) _applyStylesLive();
    };
    _initBook();
  }

  Future<void> _resolveAndApplyProfile(HibikiDatabase db) async {
    try {
      final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
      final ProfileViewModel profileVm =
          ref.read(profileViewModelProvider.notifier);

      final String bookUid = ReaderHoshiSource.bookUidFor(widget.bookId);

      // Determine media type: check for audiobook or srt binding.
      String mediaType = 'epub';
      final abRow = await db.getAudiobookByBookUid(bookUid);
      if (abRow != null) {
        mediaType = 'audiobook';
      } else {
        final srtRow = await db.getSrtBookByTtuBookId(widget.bookId);
        if (srtRow != null) {
          mediaType = 'video';
        }
      }

      final int resolvedId = await profileRepo.resolveProfileId(
        bookUid: bookUid,
        mediaType: mediaType,
      );
      final int currentActiveId = await profileRepo.getActiveProfileId();
      if (resolvedId != currentActiveId) {
        await profileVm.switchProfile(resolvedId);
      }
    } catch (e, st) {
      debugPrint(
          '[ReaderHoshi] profile resolution failed (non-fatal): $e\n$st');
    }
  }

  Future<void> _initBook() async {
    final HibikiDatabase db = appModelNoUpdate.database;

    await _resolveAndApplyProfile(db);

    _settings = ReaderHoshiSource.readerSettings ?? ReaderSettings(db);
    ReaderHoshiSource.readerSettings = _settings;
    await _settings!.ready;

    final bool exists = await EpubStorage.bookExists(widget.bookId);
    if (!exists) {
      debugPrint('[ReaderHoshi] book ${widget.bookId} not found on disk');
      if (mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    final String extractDir = await EpubStorage.bookDirectory(widget.bookId);
    _extractDir = extractDir;

    try {
      _book = EpubParser.parseFromExtracted(extractDir);
      debugPrint(
          '[ReaderHoshi] parsed EPUB: ${_book!.chapters.length} chapters');
    } on FormatException catch (e) {
      debugPrint('[ReaderHoshi] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookId, extractDir);
      _book ??= _buildLegacyBook(extractDir);
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderHoshi] chapter hrefs: $hrefs');

    _chapterCharCounts = List<int>.generate(
      _book!.chapters.length,
      (i) => _book!.chapterPlainText(i).length,
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
      _lastProgressSection = _currentChapter;
      _lastProgressValue = _initialProgress;
      debugPrint('[ReaderHoshi] restore from bookmark: '
          'chapter=$_currentChapter progress=$_initialProgress');
    } else {
      final ReaderPositionRepository repo = ReaderPositionRepository(db);
      final ReaderPosition? saved = await repo.findByTtuBookId(widget.bookId);
      debugPrint('[ReaderHoshi] restore lookup: bookId=${widget.bookId} '
          'saved=$saved section=${saved?.sectionIndex} '
          'offset=${saved?.normCharOffset}');
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < _book!.chapters.length) {
        _currentChapter = saved.sectionIndex;
        _initialProgress = saved.normCharOffset / 10000.0;
        _lastProgressSection = _currentChapter;
        _lastProgressValue = _initialProgress;
      } else {
        _restoreFromCurrentAudioCue();
      }
    }

    if (_settings!.keepScreenAwake) {
      try {
        WakelockPlus.enable();
      } catch (_) {}
    }

    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    if (src.volumePageTurningEnabled) {
      _setupVolumeKeyHandlers();
    }

    _syncDictionaryTheme();

    final bool savedLyricsMode =
        _audiobookController != null && ReaderHoshiSource.instance.lyricsMode;
    _lyricsMode = savedLyricsMode;
    if (!savedLyricsMode) {
      await ReaderHoshiSource.instance.setLyricsMode(false);
    }

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

    if (_audiobookController != null && src.volumeKeySentenceNavEnabled) {
      if (goForward) {
        _audiobookController!.skipToNextCue();
      } else {
        _audiobookController!.skipToPrevCue();
      }
    } else {
      _paginate(goForward
          ? ReaderNavigationDirection.forward
          : ReaderNavigationDirection.backward);
    }

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
      final Map<String, dynamic> ch = rawChapters[i] as Map<String, dynamic>;
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
      final List<dynamic> rawToc = jsonDecode(row.tocJson!) as List<dynamic>;
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
    final List<FileSystemEntity> htmlFiles =
        Directory(extractDir).listSync(recursive: true).where((e) {
      if (e is! File) return false;
      final String ext = p.extension(e.path).toLowerCase();
      return ext == '.html' || ext == '.xhtml' || ext == '.htm';
    }).toList()
          ..sort((a, b) => compareAudioFilePath(a.path, b.path));

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
      title: t.untitled_book(id: widget.bookId),
      chapters: chapters,
      rootDirectory: extractDir,
    );
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

    await _primeAudioCuesForCurrentBook();

    if (_audiobookController == null && _lyricsMode) {
      _lyricsMode = false;
      await ReaderHoshiSource.instance.setLyricsMode(false);
    }
  }

  Future<void> _primeAudioCuesForCurrentBook() async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;

    if (_srtBookUid != null) {
      final SrtBookRepository repo = SrtBookRepository(appModel.database);
      final List<AudioCue> cues = await repo.cuesFor(_srtBookUid!);
      controller.setChapterCues(cues);
      controller.setAllBookCues(cues);
      _cachedAllCues = cues;
      _cachedSasayaki = false;
      return;
    }

    final String? bookUid = _audiobookBookUid;
    if (bookUid == null || _book == null) return;

    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<AudioCue> allCues = await repo.cuesForBook(bookUid);
    controller.setAllBookCues(allCues);
    _cachedAllCues = allCues;
    _cachedSasayaki = allCues.any(
      (c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
    );

    if (_cachedSasayaki) {
      controller.setChapterCues(allCues);
      return;
    }

    final String chapterHref = _book!.chapters[_currentChapter].href;
    final List<AudioCue> chapterCues = await repo.cuesForChapter(
      bookUid: bookUid,
      chapterHref: chapterHref,
    );
    controller.setChapterCues(chapterCues);
  }

  void _restoreFromCurrentAudioCue() {
    final AudioCue? cue = _audiobookController?.cueAtCurrentPositionInBook();
    if (cue == null || _book == null) return;

    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag != null &&
        frag.sectionIndex >= 0 &&
        frag.sectionIndex < _book!.chapters.length) {
      _currentChapter = frag.sectionIndex;
      _initialProgress = _chapterCharCounts[frag.sectionIndex] > 0
          ? (frag.normCharStart / _chapterCharCounts[frag.sectionIndex])
              .clamp(0.0, 1.0)
          : 0.0;
      _lastProgressSection = _currentChapter;
      _lastProgressValue = _initialProgress;
      debugPrint('[ReaderHoshi] restore from audio cue: '
          'chapter=$_currentChapter progress=$_initialProgress');
      return;
    }

    final int chapter = _chapterIndexForCue(cue);
    final int fallbackChapter =
        chapter >= 0 ? chapter : _chapterIndexForText(cue.text);
    if (fallbackChapter < 0) return;
    _currentChapter = fallbackChapter;
    _initialProgress = 0.0;
    _lastProgressSection = fallbackChapter;
    _lastProgressValue = 0.0;
    debugPrint('[ReaderHoshi] restore from audio cue chapter: '
        'chapter=$_currentChapter href=${cue.chapterHref}');
  }

  int _chapterIndexForCue(AudioCue cue) {
    if (_book == null) return -1;
    final String chapterHref = cue.chapterHref.trim();
    if (chapterHref.isEmpty) return -1;
    for (int i = 0; i < _book!.chapters.length; i++) {
      if (_book!.chapters[i].href == chapterHref) {
        return i;
      }
    }
    return -1;
  }

  int _chapterIndexForText(String text) {
    if (_book == null) return -1;
    final String needle = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (needle.length < 6) return -1;
    for (int i = 0; i < _book!.chapters.length; i++) {
      final String chapterText = _book!.chapterPlainText(i);
      if (chapterText.contains(needle)) {
        return i;
      }
    }
    return -1;
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
    try {
      await controller.load(
        audiobook: audiobook,
        audioFiles: audioFiles,
        initialFollowAudio: prefs[0] as bool,
        initialDelayMs: prefs[1] as int,
        initialSpeed: prefs[2] as double,
        initialPositionMs: prefs[3] as int,
        initialImagePauseSec: prefs[4] as int,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshi.loadAudiobook', e, stack);
      debugPrint('[ReaderHoshi] audiobook load failed: $e');
      controller.dispose();
      if (mounted) {
        HibikiToast.show(msg: t.audiobook_load_error);
      }
      return;
    }

    if (!mounted) {
      controller.dispose();
      return;
    }

    controller.onPositionWrite = (uid, posMs) {
      repo.updatePositionMs(bookUid: uid, positionMs: posMs);
    };
    controller.onDelayPersist = (ms) async {
      await repo.updateDelayMs(bookUid: bookUid, ms: ms);
    };
    controller.onSpeedPersist = (speed) async {
      await repo.updateSpeed(bookUid: bookUid, speed: speed);
    };
    controller.onImagePausePersist = (sec) async {
      await repo.updateImagePauseSec(bookUid: bookUid, sec: sec);
    };
    controller.onFollowAudioPersist = (value) async {
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
    try {
      await controller.load(
        audiobook: syntheticAudiobook,
        audioFiles: audioFiles,
        initialDelayMs: prefs[0] as int,
        initialSpeed: prefs[1] as double,
        initialImagePauseSec: prefs[2] as int,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshi.loadSrtBook', e, stack);
      debugPrint('[ReaderHoshi] srt book load failed: $e');
      controller.dispose();
      if (mounted) {
        HibikiToast.show(msg: t.audiobook_load_error);
      }
      return;
    }

    if (!mounted) {
      controller.dispose();
      return;
    }

    controller.onDelayPersist = (ms) async {
      await abRepo.updateDelayMs(bookUid: srtBookUid, ms: ms);
    };
    controller.onSpeedPersist = (speed) async {
      await abRepo.updateSpeed(bookUid: srtBookUid, speed: speed);
    };
    controller.onImagePausePersist = (sec) async {
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
      final bool exists = await dir.exists();
      if (!exists) return <File>[];
      final List<FileSystemEntity> entries = await dir.list().toList();
      final List<File> files = entries
          .whereType<File>()
          .where((f) => AudiobookStorage.isAudioFile(f.path))
          .toList()
        ..sort((a, b) => compareAudioFilePath(a.path, b.path));
      return files;
    }
    return <File>[];
  }

  @override
  void dispose() {
    ReaderHoshiSource.onSettingsChangedLive = null;
    WidgetsBinding.instance.removeObserver(this);
    _progressPollTimer?.cancel();
    _saveDebounce?.cancel();
    _volumeThrottleTimer?.cancel();
    VolumeKeyChannel.instance.setHandlers();
    VolumeKeyChannel.instance.setInterceptEnabled(false);
    appModel.setOverrideDictionaryTheme(null);
    appModel.setOverrideDictionaryColor(null);
    if (_lyricsMode) {
      _syncPositionFromCurrentCue();
    }
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
    try {
      WakelockPlus.disable();
    } catch (_) {}
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
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    final Size screen = MediaQuery.of(context).size;
    final double w = screen.width;
    final double h = screen.height - _readerTopOffset - _readerBottomReserve;
    final bool widthChanged = _lastSyncedWidth > 0 && w != _lastSyncedWidth;
    final bool heightChanged = (h - _lastSyncedHeight).abs() >= 1;
    if (!widthChanged && !heightChanged) return;
    _lastSyncedWidth = w;
    _lastSyncedHeight = h;

    if (widthChanged) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.progressInvocation(),
      );
      final double? progress = ReaderPaginationScripts.doubleResult(result);
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final EdgeInsets vp = MediaQuery.of(context).viewPadding;
    _stableTopInset = vp.top;
    _stableBottomInset = vp.bottom;
  }

  // ── UI Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Color bgColor = _themeBackgroundColor();

    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, dynamic result) async {
          if (didPop) return;
          final nav = Navigator.of(context);
          final bool allow = await onWillPop();
          if (allow && mounted) nav.pop();
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
              AnimatedOpacity(
                opacity: _lyricsModeTransition ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_lyricsModeTransition,
                  child: ColoredBox(
                    color: _themeBackgroundColor(),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              if (_readerContentReady)
                const SizedBox.shrink(
                    key: ValueKey<String>('hoshi_content_ready')),
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

  Future<WebResourceResponse?> _interceptRequest(WebUri url) async {
    if (url.host != ReaderHoshiSource.kHost) return null;
    final String path = url.path;

    if (path.startsWith('/fonts/')) {
      final String raw = path.substring('/fonts/'.length);
      final String fontPath = Uri.decodeComponent(raw);
      final String? safeFontPath = ReaderHoshiSource.safeCustomFontPath(
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
      final Uint8List data = fontFile.readAsBytesSync();
      if (!_isValidFontData(data)) {
        return _notFound('font corrupted: $fontPath (${data.length} bytes)');
      }
      debugPrint(
          '[ReaderHoshi] font served: $safeFontPath (${data.length} bytes)');
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

    Uint8List data = file.readAsBytesSync();
    final String mime = fallbackMimeType(filePath);

    if (mime == 'text/css') {
      final String cssText = utf8.decode(data);
      final String sanitized = ReaderResourceSanitizer.sanitizeCss(cssText);
      data = Uint8List.fromList(utf8.encode(sanitized));
    }

    if ((mime == 'text/html' || mime.contains('xhtml')) && _settings != null) {
      String html = utf8.decode(data);
      final String styleTag = _buildStyleTag();
      const String hideUntilReady =
          '<style id="hoshi-cloak">body{visibility:hidden!important}</style>';
      final RegExp headPattern = RegExp('<head[^>]*>', caseSensitive: false);
      final RegExpMatch? headMatch = headPattern.firstMatch(html);
      if (headMatch != null) {
        html =
            '${html.substring(0, headMatch.end)}\n$hideUntilReady\n$styleTag${html.substring(headMatch.end)}';
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

  String _buildStyleTag() {
    return '<style id="hoshi-reader-style">\n${ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      customBg:
          appModel.appThemeKey == 'custom-theme' ? _readerBackgroundHex : null,
      customFg:
          appModel.appThemeKey == 'custom-theme' ? _customThemeTextCss : null,
      selectionColor: _colorToCssRgba(appModel.customThemeSelectionColor),
      sasayakiColor: _colorToCssRgba(appModel.customThemeSasayakiColor),
      linkColor: _colorToCssRgba(appModel.customThemeLinkColor),
    )}\n</style>';
  }

  Future<void> _applyStylesLive() async {
    if (_controller == null || _settings == null) return;
    await _syncSettingsFromHive();
    if (_lyricsMode) {
      await _loadLyricsPage();
      return;
    }
    final String css = ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      customBg:
          appModel.appThemeKey == 'custom-theme' ? _readerBackgroundHex : null,
      customFg:
          appModel.appThemeKey == 'custom-theme' ? _customThemeTextCss : null,
      selectionColor: _colorToCssRgba(appModel.customThemeSelectionColor),
      sasayakiColor: _colorToCssRgba(appModel.customThemeSasayakiColor),
      linkColor: _colorToCssRgba(appModel.customThemeLinkColor),
    );
    final String escaped = css
        .replaceAll('\\', '\\\\')
        .replaceAll('`', '\\`')
        .replaceAll('\$', '\\\$');
    await _controller!.evaluateJavascript(
      source: '''
(function(){
  var el = document.getElementById('hoshi-reader-style');
  if (!el) {
    el = document.createElement('style');
    el.id = 'hoshi-reader-style';
    document.head.appendChild(el);
  }
  el.textContent = `$escaped`;
})();
''',
    );
    setState(() {});
  }

  static bool _isValidFontData(Uint8List data) {
    if (data.length < 4) return false;
    final int sig =
        (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
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
    final String selectionJs = ReaderSelectionScripts.source();
    final String paginationJs = _stripScriptTags(
      ReaderPaginationScripts.shellScript(
        initialProgress: _initialProgress,
        continuousMode: s.isContinuousMode,
        fontSize: s.fontSize.round(),
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
  function _gestureStart(x, y) { hasStart = true; startX = x; startY = y; startTime = Date.now(); }
  function _gestureEnd(x, y, e) {
    if (!hasStart) return;
    hasStart = false;
    var dx = x - startX;
    var dy = y - startY;
    var elapsed = Date.now() - startTime;
    var absDx = Math.abs(dx);
    var absDy = Math.abs(dy);
    var velocity = absDx / Math.max(1, elapsed) * 1000;
    if (absDx > absDy && (absDx >= 72 || (absDx >= 36 && velocity >= 900))) {
      if (e && e.preventDefault) e.preventDefault();
      if (dx < 0) {
        window.flutter_inappwebview.callHandler('onSwipe', 'left');
      } else {
        window.flutter_inappwebview.callHandler('onSwipe', 'right');
      }
    } else if (absDx < 20 && absDy < 20 && elapsed < 500) {
      var target = document.elementFromPoint(x, y);
      if (target && target.tagName === 'IMG' && target.src) {
        window.flutter_inappwebview.callHandler('onImageTap', target.src);
      } else {
        window.flutter_inappwebview.callHandler('onTap', x, y);
      }
    }
  }
  document.addEventListener('touchstart', function(e) {
    var t = e.touches[0]; _gestureStart(t.clientX, t.clientY);
  }, {passive: true});
  document.addEventListener('touchend', function(e) {
    var t = e.changedTouches[0]; _gestureEnd(t.clientX, t.clientY, e);
  }, {passive: false});
  document.addEventListener('pointerdown', function(e) {
    if (e.pointerType === 'touch' || e.button !== 0) return;
    _gestureStart(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointerup', function(e) {
    if (e.pointerType === 'touch' || e.button !== 0) return;
    _gestureEnd(e.clientX, e.clientY, e);
  }, {passive: false});
  document.addEventListener('selectstart', function(e) {
    if (hasStart) e.preventDefault();
  });
  var _wheelTimer = null;
  document.addEventListener('wheel', function(e) {
    if (_wheelTimer) return;
    var r = window.hoshiReader;
    if (!r || !('paginationMetrics' in r)) return;
    _wheelTimer = setTimeout(function() { _wheelTimer = null; }, 250);
    var forward = (e.deltaY > 0 || e.deltaX > 0);
    window.flutter_inappwebview.callHandler('onSwipe', forward ? 'left' : 'right');
    e.preventDefault();
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
      key: const ValueKey<String>('hoshi_webview'),
      contextMenu: ContextMenu(
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
              await searchDictionaryResult(
                searchTerm: text,
                selectionRect: rect,
              );
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
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
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
                  .log('ReaderHoshi.onTextSelected', e, stack);
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
          callback: (args) {
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
            if (args.isEmpty || _lyricsMode) return;
            final String dir = args[0] as String;
            final bool invert = ReaderHoshiSource.instance.invertSwipeDirection;
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
            if (args.isEmpty || _lyricsMode) return;
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
          callback: (args) {
            if (args.isEmpty) return;
            _openImageViewer(args[0] as String);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onLyricsCueTap',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _audiobookController == null) return;
            final int index = (args[0] as num).toInt();
            if (index >= 0 && index < _lyricsCueList.length) {
              _audiobookController!.playCueAndContinue(_lyricsCueList[index]);
            }
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
        final ({int chapterIndex, String? fragment})? link =
            _book?.resolveInternalLink(url);
        if (link != null) {
          _navigateToChapterWithFragment(link.chapterIndex, link.fragment);
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, url) async {
        _isNavigatingToChapter = false;
        final int chapterSnapshot = _currentChapter;
        debugPrint('[ReaderHoshi] onLoadStop: url=$url '
            'chapter=$chapterSnapshot progress=$_initialProgress');
        if (_lyricsMode && _isLyricsUrl(url)) {
          await _onChapterLoadComplete(controller);
          return;
        }
        final String expectedUrl = _chapterUrl(chapterSnapshot);
        if (url != null &&
            Uri.parse(url.toString()).path != Uri.parse(expectedUrl).path) {
          debugPrint(
              '[ReaderHoshi] onLoadStop: stale page (expected=$expectedUrl), ignoring');
          return;
        }
        await _onChapterLoadComplete(controller);
      },
      onReceivedError: (controller, request, error) async {
        if (request.isForMainFrame ?? false) {
          debugPrint('[ReaderHoshi] onReceivedError: ${error.description} '
              'url=${request.url}');
          // WebView2 on Windows reports NavigationCompleted with isSuccess=false
          // for intercepted hoshi.local URLs because the domain doesn't resolve
          // at the network layer, even though shouldInterceptRequest provided a
          // valid response. The content IS rendered — treat as onLoadStop.
          if (Platform.isWindows &&
              request.url.host == ReaderHoshiSource.kHost) {
            debugPrint('[ReaderHoshi] Windows: treating intercepted navigation '
                'error as successful load');
            _isNavigatingToChapter = false;
            await _onChapterLoadComplete(controller);
            return;
          }
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
  }

  Future<void> _onChapterLoadComplete(InAppWebViewController controller) async {
    if (_lyricsMode) {
      if (!_readerContentReady) {
        setState(() {
          _readerContentReady = true;
          _hasEverLoaded = true;
        });
      }
      _lyricsPageReady = true;
      _onCueChanged();
      return;
    }
    final int chapterSnapshot = _currentChapter;
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
    if (!mounted) return;
    _lastSyncedWidth = MediaQuery.of(context).size.width;
  }

  Future<void> _applyChapterHighlights() async {
    if (_controller == null) return;
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);
    final List<FavoriteSentence> all = await repo.getAll();
    final List<FavoriteSentence> chapterFavs = all
        .where((s) =>
            s.ttuBookId == widget.bookId && s.sectionIndex == _currentChapter)
        .toList();
    if (chapterFavs.isNotEmpty) {
      await HighlightBridge.applyHighlights(_controller!, chapterFavs,
          backgroundHex: _readerBackgroundHex,
          customHighlightCss: _customHighlightCss);
      await _controller!.evaluateJavascript(
        source:
            'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
      );
      await _settings!.setTheme(appModel.appThemeKey);
    }
  }

  // ── Restore Complete ──────────────────────────────────────────────

  Completer<bool>? _restoreCompleter;
  int _navigateGeneration = 0;
  int _restoreExpectedGeneration = 0;

  void _onRestoreComplete() {
    if (!mounted) {
      return;
    }
    if (_restoreExpectedGeneration != _navigateGeneration) {
      debugPrint(
        '[ReaderHoshi] stale onRestoreComplete: '
        'expected=$_restoreExpectedGeneration current=$_navigateGeneration',
      );
      return;
    }
    _restoreInFlight = false;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(true);
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

  // ── Lyrics Mode ──────────────────────────────────────────────────

  Future<void> _toggleLyricsMode() async {
    if (_lyricsModeTransition) return;
    if (_controller == null || _audiobookController == null) return;
    final bool entering = !_lyricsMode;

    if (entering) {
      final List<AudioCue> cues =
          _audiobookController!.allBookCuesSnapshot.isNotEmpty
              ? _audiobookController!.allBookCuesSnapshot
              : _audiobookController!.chapterCuesSnapshot;
      if (cues.isEmpty) return;
    }

    setState(() => _lyricsModeTransition = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    setState(() => _lyricsMode = entering);
    await ReaderHoshiSource.instance.setLyricsMode(entering);

    if (entering) {
      final List<AudioCue> allCues = _audiobookController!.allBookCuesSnapshot;
      if (allCues.isNotEmpty) {
        _audiobookController!.setChapterCues(allCues);
      }
      _lyricsEntryChapter = _currentChapter;
      _lyricsEntryCueIndex =
          _audiobookController!.allBookCuesSnapshot.isNotEmpty
              ? _audiobookController!.allBookCueIdx
              : _audiobookController!.currentCueIdx;
      await _loadLyricsPage();
    } else {
      await _exitLyricsMode();
    }

    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (mounted) setState(() => _lyricsModeTransition = false);
  }

  Future<void> _loadLyricsPage() async {
    _lyricsPageReady = false;
    final AudiobookPlayerController ctrl = _audiobookController!;
    _lyricsCueList = ctrl.allBookCuesSnapshot.isNotEmpty
        ? ctrl.allBookCuesSnapshot
        : ctrl.chapterCuesSnapshot;
    if (_lyricsCueList.isEmpty) {
      await _exitLyricsMode();
      return;
    }

    final int currentIdx = ctrl.allBookCuesSnapshot.isNotEmpty
        ? ctrl.allBookCueIdx
        : ctrl.currentCueIdx;
    final int safeCurrentIdx =
        currentIdx >= 0 ? currentIdx : _lyricsEntryCueIndex;

    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final Color accent = _isReaderThemeDark
        ? const Color(0xFFFFDC00)
        : Theme.of(context).colorScheme.primary;

    String colorToCss(Color c) =>
        'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(2)})';

    final String html = LyricsModeHtml.generate(
      cues: _lyricsCueList,
      currentIndex: safeCurrentIdx.clamp(0, _lyricsCueList.length - 1),
      backgroundColor: colorToCss(bg),
      textColor: colorToCss(fg),
      accentColor: colorToCss(accent),
      fontSize: (_settings?.fontSize ?? 20).toDouble(),
    );

    await _controller!.loadData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf-8',
      baseUrl: WebUri('https://hoshi.local/lyrics'),
    );
  }

  bool _isLyricsUrl(WebUri? url) {
    if (url == null) return false;
    final Uri uri = Uri.parse(url.toString());
    return uri.host == ReaderHoshiSource.kHost && uri.path == '/lyrics';
  }

  Future<void> _exitLyricsMode() async {
    final AudiobookPlayerController ctrl = _audiobookController!;
    final AudioCue? cue = ctrl.currentCue;
    int targetChapter =
        _lastProgressSection >= 0 ? _lastProgressSection : _lyricsEntryChapter;
    double targetProgress = _lastProgressValue;

    if (cue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag != null) {
        targetChapter = frag.sectionIndex;
        if (targetChapter >= 0 &&
            targetChapter < _chapterCharCounts.length &&
            _chapterCharCounts[targetChapter] > 0) {
          targetProgress =
              frag.normCharStart / _chapterCharCounts[targetChapter];
          targetProgress = targetProgress.clamp(0.0, 1.0);
        }
      }
    }

    _lyricsPageReady = false;
    _lyricsCueList = const [];
    await _navigateToChapter(targetChapter, progress: targetProgress);
  }

  // ── Audiobook Cue Wiring ──────────────────────────────────────────

  void _onCueChanged() {
    if (!mounted || _controller == null) return;
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;

    if (_lyricsMode) {
      if (_lyricsPageReady) {
        final int idx = controller.allBookCuesSnapshot.isNotEmpty
            ? controller.allBookCueIdx
            : controller.currentCueIdx;
        if (idx >= 0) {
          _controller!.evaluateJavascript(
            source: 'if(window.__lyricsSetCue)window.__lyricsSetCue($idx);',
          );
        }
      }
      _syncPositionFromCurrentCue();
      _syncFloatingLyric(controller);
      _syncMediaNotification(controller);
      return;
    }

    final AudioCue? cue = controller.currentCue;
    if (cue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag != null && frag.sectionIndex != _currentChapter) {
        AudiobookBridge.highlight(_controller!);
        return;
      }
    }
    final bool forceReveal = controller.consumeForceReveal();
    final bool reveal = forceReveal || controller.shouldRevealCurrentCue;
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
    if (_lyricsMode) {
      _audiobookController?.cancelChapterTransition();
      return;
    }
    if (_restoreInFlight ||
        _book == null ||
        newSection < 0 ||
        newSection >= _book!.chapters.length) {
      _audiobookController?.cancelChapterTransition();
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
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';

    String? coverPath;
    if (_book?.coverHref != null && _extractDir != null) {
      final File coverFile = File(p.join(_extractDir!, _book!.coverHref));
      if (coverFile.existsSync()) coverPath = coverFile.path;
    }

    String? sasayakiAudioPath;
    final AudioCue? cue = _lookupCue;
    final List<File>? audioFiles = _audiobookController?.audioFiles;
    if (cue != null &&
        audioFiles != null &&
        cue.audioFileIndex < audioFiles.length) {
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
        HibikiToast.show(
          msg: t.card_exported(deck: settings.selectedDeckName ?? ''),
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM,
        );
        return true;
      case MineResult.duplicate:
        HibikiToast.show(msg: t.card_duplicate);
        return false;
      case MineResult.notConfigured:
        HibikiToast.show(msg: t.card_export_not_configured);
        return false;
      case MineResult.error:
        HibikiToast.show(msg: t.card_export_failed);
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
    final List<AudioCue> allCues = await repo.cuesForBook(_audiobookBookUid!);
    _cachedAllCues = allCues;
    _cachedSasayaki = allCues.any(
      (c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
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

    final Color highlightColor =
        appModel.customThemeSasayakiColor ?? const Color(0x6687CEEB);
    await AudiobookBridge.inject(_controller!, primaryColor: highlightColor);

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
        final AudiobookRepository repo = AudiobookRepository(appModel.database);
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

    if (_lyricsMode && _audiobookController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLyricsPage();
      });
    }
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

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();

    _currentChapter = index;
    _initialProgress = progress;
    _displayedProgress = progress;
    _lastProgressSection = index;
    _lastProgressValue = progress;
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
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  Future<bool> _navigateToChapterAndWait(int index) async {
    await _navigateToChapter(index);
    final bool success = await _restoreCompleter?.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('[ReaderHoshi] _navigateToChapterAndWait timed out');
            _isNavigatingToChapter = false;
            _restoreCompleter = null;
            _restoreInFlight = false;
            return false;
          },
        ) ??
        false;
    return success && _currentChapter == index;
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

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();

    _currentChapter = index;
    _initialProgress = 0.0;
    _displayedProgress = 0.0;
    _lastProgressSection = index;
    _lastProgressValue = 0.0;
    _initialFragment = fragment;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHoshi._navigateToChapterWithFragment', e, stack);
      debugPrint(
          '[ReaderHoshi] _navigateToChapterWithFragment loadUrl failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
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

  @override
  void onAllPopupsDismissed() {
    if (!mounted) return;
    _clearLookupState();
  }

  void _clearLookupState() {
    if (_pausedForLookup) {
      _pausedForLookup = false;
      _audiobookController?.play();
    }
    _controller?.evaluateJavascript(
      source: ReaderSelectionScripts.clearInvocation(),
    );
  }

  Future<void> _handleTextSelected(ReaderSelectionData data) async {
    if (data.text.isEmpty) {
      return;
    }

    final bool shouldPause =
        _lyricsMode || ReaderHoshiSource.instance.pauseOnLookup;
    if (shouldPause &&
        _audiobookController != null &&
        _audiobookController!.isPlaying) {
      _audiobookController!.pause();
      _pausedForLookup = true;
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

    if (_lyricsMode) {
      _lookupCue = null;
      final Object? ctxRaw = await _controller?.evaluateJavascript(
        source: 'JSON.stringify(window.__lyricsCueContext || null)',
      );
      if (ctxRaw is String && ctxRaw != 'null') {
        try {
          final Map<String, dynamic> ctx =
              jsonDecode(ctxRaw) as Map<String, dynamic>;
          final String? fragId = ctx['textFragmentId'] as String?;
          final int? cueIdx = (ctx['cueIndex'] as num?)?.toInt();
          if (fragId != null && fragId.isNotEmpty) {
            final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(fragId);
            if (frag != null) {
              _cachedSelectionRange = (
                offset: frag.normCharStart,
                length: frag.normCharEnd - frag.normCharStart,
                text: data.text,
              );
              _cachedSentenceRange = (
                offset: frag.normCharStart,
                length: frag.normCharEnd - frag.normCharStart,
              );
            }
          }
          if (cueIdx != null && cueIdx >= 0 && cueIdx < _lyricsCueList.length) {
            _lookupCue = _lyricsCueList[cueIdx];
          }
        } catch (_) {}
      }
      final int highlightCount = await searchDictionaryResult(
        searchTerm: data.text,
        selectionRect: selectionRect,
      );
      if (highlightCount > 0 && _controller != null) {
        await _controller!.evaluateJavascript(
          source: ReaderSelectionScripts.highlightInvocation(highlightCount),
        );
      }
      _checkFavoriteStatus();
      return;
    }

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
    final sentenceRange = _cachedSentenceRange ??
        (_cachedSelectionRange != null
            ? (
                offset: _cachedSelectionRange!.offset,
                length: _cachedSelectionRange!.length
              )
            : null);
    final bool favorited =
        await FavoriteSentenceRepository(appModel.database).isFavorited(
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
    if (_controller == null || _lyricsMode) return;
    final dynamic result = await _controller!.evaluateJavascript(
      source: 'window.hoshiProgressDetails()',
    );
    if (result == null || !mounted) return;
    final String str = result.toString().replaceAll('"', '').trim();
    if (str.isEmpty) return;

    final List<String> parts = str.split(',');
    if (parts.length != 2) return;
    final int? current = int.tryParse(parts[0]);
    final int? total = int.tryParse(parts[1]);
    if (current == null || total == null || total <= 0) return;

    final double progress = current / total;
    _displayedProgress = progress;
    _lastProgressSection = _currentChapter;
    _lastProgressValue = progress;
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
    _debouncedSaveReaderPosition(_currentChapter, progress);
  }

  void _debouncedSaveReaderPosition(int section, double progress) {
    if (_restoreInFlight) {
      return;
    }
    if (section == _lastSavedSection &&
        (progress - _lastSavedProgress).abs() < 0.001) {
      return;
    }

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistPosition(section, progress);
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

  void _syncPositionFromCurrentCue() {
    final AudioCue? cue = _audiobookController?.currentCue;
    if (cue == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag == null) return;
    _lastProgressSection = frag.sectionIndex;
    if (frag.sectionIndex >= 0 &&
        frag.sectionIndex < _chapterCharCounts.length &&
        _chapterCharCounts[frag.sectionIndex] > 0) {
      _lastProgressValue =
          frag.normCharStart / _chapterCharCounts[frag.sectionIndex];
      _lastProgressValue = _lastProgressValue.clamp(0.0, 1.0);
      _debouncedSaveReaderPosition(_lastProgressSection, _lastProgressValue);
    }
  }

  Future<void> _flushPosition() async {
    _saveDebounce?.cancel();
    if (!_hasEverLoaded || _lastProgressSection < 0) {
      return;
    }
    await _persistPosition(_lastProgressSection, _lastProgressValue);
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

    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _paginate(ReaderNavigationDirection.forward);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
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
    if (!p.isWithin(p.canonicalize(_extractDir!), p.canonicalize(filePath))) {
      return;
    }
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
            maxScale: 5,
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
    _seekStreamSub = appModel.seekStream.listen((pos) {
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
      final File coverFile = File(p.join(_extractDir!, _book!.coverHref));
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

  Future<void> _applyFloatingLyricStyle() async {
    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final bool dark = _isReaderThemeDark;
    await FloatingLyricChannel.updateStyle(
      fontSize: appModel.floatingLyricFontSize,
      textColor: fg.value,
      bgColor: bg.withAlpha(dark ? 230 : 220).value,
      buttonTextColor: fg.value,
      buttonBgColor:
          (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
    );
    await FloatingLyricChannel.updateLabels(
      previous: t.floating_lyric_previous,
      playPause: t.floating_lyric_play_pause,
      next: t.floating_lyric_next,
      lock: t.floating_lyric_lock,
      unlock: t.floating_lyric_unlock,
      close: t.floating_lyric_close,
    );
  }

  Future<void> _showFloatingLyricOverlay() async {
    await FloatingLyricChannel.show();
    await _applyFloatingLyricStyle();
    _setupFloatingLyricHandlers();
  }

  Future<bool> _toggleFloatingLyric() async {
    final bool current = appModel.showFloatingLyric;
    if (!current) {
      final bool shown = await FloatingLyricChannel.show();
      if (!shown) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t.floating_lyric_permission_hint),
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return false;
      }
      await _applyFloatingLyricStyle();
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
      onLockChanged: (bool locked) {},
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
      builder: (context, _) {
        return Positioned(
          key: const ValueKey<String>('hoshi_play_bar'),
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
      builder: (ctx) => AudiobookImportDialog(
        bookUid: bookUid,
        repo: repo,
        ttuBookId: widget.bookId,
      ),
    );

    try {
      await _resolveAudioSlot();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHoshi.openAudioImport', e, stack);
      debugPrint('[ReaderHoshi] resolveAudioSlot after import failed: $e');
    }
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

    await _syncSettingsToHive();

    final List<TtuTocEntry> toc = _buildTtuToc();
    final int bookId = widget.bookId;
    final BookmarkRepository bmRepo = BookmarkRepository(appModel.database);
    final FavoriteSentenceRepository favRepo =
        FavoriteSentenceRepository(appModel.database);

    List<Bookmark> bookmarks = await bmRepo.getBookmarks(bookId);
    final List<FavoriteSentence> allFavorites = await favRepo.getAll();
    final List<FavoriteSentence> favorites =
        allFavorites.where((f) => f.ttuBookId == bookId).toList();

    if (!mounted) return;

    final Widget sheetContent = AudiobookSettingsSheet(
      controller: _audiobookController,
      toc: toc,
      readerProgress: (_currentChapter + 1, _book!.chapters.length),
      onJumpSection: (index) async {
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
      onStyleChanged: _applyStylesLive,
      extractDir: _extractDir,
      onReloadChapter: _reloadWithCurrentSettings,
      lyricsMode: _lyricsMode,
      onToggleLyricsMode: _toggleLyricsMode,
      showFloatingLyric: appModel.showFloatingLyric,
      onToggleFloatingLyric: _toggleFloatingLyric,
      floatingLyricFontSize: appModel.floatingLyricFontSize,
      onFloatingLyricFontSizeChanged: (v) async {
        await appModel.setFloatingLyricFontSize(v);
        final Color bg = _themeBackgroundColor();
        final Color fg = _themeTextColor();
        final bool dark = _isReaderThemeDark;
        await FloatingLyricChannel.updateStyle(
          fontSize: v,
          textColor: fg.value,
          bgColor: bg.withAlpha(dark ? 230 : 220).value,
          buttonTextColor: fg.value,
          buttonBgColor:
              (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
        );
      },
      showMediaNotification: appModel.showMediaNotification,
      onToggleMediaNotification: _toggleMediaNotification,
      charProgress: _progressCurrentChars != null && _progressTotalChars != null
          ? (_progressCurrentChars!, _progressTotalChars!)
          : null,
      onJumpToCharOffset: (globalOffset) async {
        _jumpToGlobalCharOffset(globalOffset);
      },
      epubBook: _book,
      onSearchJump: (BookSearchResult result, String query) async {
        if (_book == null || _controller == null) return;
        if (result.sectionIndex != _currentChapter) {
          final bool ok = await _navigateToChapterAndWait(result.sectionIndex);
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
          await _navigateToChapterAndWait(bm.sectionIndex);
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
            bookId,
            sectionIndex: bookmark.sectionIndex,
            normCharOffset: bookmark.normCharOffset,
            createdAt: bookmark.createdAt,
          );
        }
        bookmarks = await bmRepo.getBookmarks(bookId);
      },
      favoriteSentences: favorites,
      onDeleteFavorite: (fav) async {
        await favRepo.removeById(fav.id);
      },
      onJumpToFavorite: (fav) async {
        if (fav.sectionIndex == null) return;
        if (fav.sectionIndex != _currentChapter) {
          await _navigateToChapterAndWait(fav.sectionIndex!);
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
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: sheetContent,
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => sheetContent,
      );
    }

    await _syncSettingsFromHive();
    _syncDictionaryTheme();
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
        ttuBookId: widget.bookId,
        bookTitle: _book?.title,
      );
      await BookmarkRepository(appModel.database)
          .addBookmark(widget.bookId, bm);
      return;
    }

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

    await BookmarkRepository(appModel.database).addBookmark(widget.bookId, bm);
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

  Future<void> _syncSettingsToHive() async {
    final ReaderSettings s = _settings!;
    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    await Future.wait(<Future<void>>[
      src.setTtuFontSize(s.fontSize),
      src.setTtuLineHeight(s.lineHeight),
      src.setTtuWritingMode(s.writingMode),
      src.setTtuViewMode(s.viewMode),
      src.setTtuTheme(s.theme),
      src.setTtuFuriganaMode(s.furiganaMode),
      src.setTtuTextIndentation(s.textIndentation),
      src.setTtuMarginTop(s.marginTop),
      src.setTtuMarginBottom(s.marginBottom),
      src.setTtuMarginLeft(s.marginLeft),
      src.setTtuMarginRight(s.marginRight),
      src.setTtuPageColumns(s.pageColumns),
      src.setTtuEnableVerticalFontKerning(s.enableVerticalFontKerning),
      src.setTtuEnableFontVPAL(s.enableFontVPAL),
      src.setTtuVerticalTextOrientation(s.verticalTextOrientation),
      src.setTtuEnableTextJustification(s.enableTextJustification),
      src.setTtuPrioritizeReaderStyles(s.prioritizeReaderStyles),
    ]);
  }

  Future<void> _syncSettingsFromHive() async {
    final ReaderSettings s = _settings!;
    final ReaderHoshiSource src = ReaderHoshiSource.instance;
    await Future.wait(<Future<void>>[
      s.setFontSize(src.ttuFontSize),
      s.setLineHeight(src.ttuLineHeight),
      s.setWritingMode(src.ttuWritingMode),
      s.setViewMode(src.ttuViewMode),
      s.setTheme(src.ttuTheme),
      s.setFuriganaMode(src.ttuFuriganaMode),
      s.setTextIndentation(src.ttuTextIndentation),
      s.setMarginTop(src.ttuMarginTop),
      s.setMarginBottom(src.ttuMarginBottom),
      s.setMarginLeft(src.ttuMarginLeft),
      s.setMarginRight(src.ttuMarginRight),
      s.setPageColumns(src.ttuPageColumns),
      s.setEnableVerticalFontKerning(src.ttuEnableVerticalFontKerning),
      s.setEnableFontVPAL(src.ttuEnableFontVPAL),
      s.setVerticalTextOrientation(src.ttuVerticalTextOrientation),
      s.setEnableTextJustification(src.ttuEnableTextJustification),
      s.setPrioritizeReaderStyles(src.ttuPrioritizeReaderStyles),
    ]);
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
    if (_lyricsMode) {
      await _loadLyricsPage();
      return;
    }
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.progressInvocation(),
    );
    final double? progress = _toDouble(result);
    _initialProgress = progress ?? 0.0;
    _lastProgressSection = _currentChapter;
    _lastProgressValue = _initialProgress;

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    _restoreInFlight = true;
    debugPrint('[ReaderHoshi] reloadWithCurrentSettings: '
        'chapter=$_currentChapter progress=$_initialProgress '
        'generation=$gen continuous=${_settings?.isContinuousMode}');

    setState(() {
      _readerContentReady = false;
    });

    await _loadChapterDirectly(_currentChapter);
  }

  // ── Top Progress Bar ──────────────────────────────────────────────

  Color _infoTextColor() {
    final String theme = appModel.appThemeKey;
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
    if (_lyricsMode || !_showTopProgress) {
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
          key: const ValueKey<String>('hoshi_progress'),
          style: TextStyle(fontSize: _infoFontSize, color: infoColor),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  // ── Theme Colors ──────────────────────────────────────────────────

  Color _themeBackgroundColor() {
    final String theme = appModel.appThemeKey;
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
        return appModel.customThemeBackgroundColor ?? const Color(0xFFFFFFFF);
      default:
        return const Color(0xFFFFFFFF);
    }
  }

  Color _themeTextColor() {
    final String theme = appModel.appThemeKey;
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
    final String theme = appModel.appThemeKey;
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
    return _colorToCssRgba(c);
  }

  static String? _colorToCssRgba(Color? c) {
    if (c == null) return null;
    final int r = (c.r * 255.0).round().clamp(0, 255);
    final int g = (c.g * 255.0).round().clamp(0, 255);
    final int b = (c.b * 255.0).round().clamp(0, 255);
    return 'rgba($r,$g,$b,${c.a.toStringAsFixed(2)})';
  }

  String? get _customHighlightCss {
    if (appModel.appThemeKey != 'custom-theme') return null;
    final Color? c = appModel.customThemePrimaryColor;
    if (c == null) return null;
    final int r = (c.r * 255.0).round().clamp(0, 255);
    final int g = (c.g * 255.0).round().clamp(0, 255);
    final int b = (c.b * 255.0).round().clamp(0, 255);
    return 'rgba($r,$g,$b,0.34)';
  }

  void _syncDictionaryTheme() {
    final Color bg = _themeBackgroundColor();
    final Color textColor = _themeTextColor();
    final Brightness brightness =
        _isReaderThemeDark ? Brightness.dark : Brightness.light;
    appModel.setOverrideDictionaryColor(bg);
    appModel.setOverrideDictionaryTheme(
      (brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light())
          .copyWith(
              colorScheme: ColorScheme.fromSeed(
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
      HibikiToast.show(msg: t.no_sentence_selected);
      return;
    }

    final sentenceRange = _cachedSentenceRange ??
        (_cachedSelectionRange != null
            ? (
                offset: _cachedSelectionRange!.offset,
                length: _cachedSelectionRange!.length
              )
            : null);
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
            .where((s) =>
                s.ttuBookId == widget.bookId &&
                s.sectionIndex == _currentChapter)
            .toList();
        await HighlightBridge.applyHighlights(_controller!, chapterFavs,
            backgroundHex: _readerBackgroundHex,
            customHighlightCss: _customHighlightCss);
        await _controller!.evaluateJavascript(
          source:
              'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
        );
      }
      HibikiToast.show(msg: t.favorite_removed);
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
          .where((s) =>
              s.ttuBookId == widget.bookId && s.sectionIndex == _currentChapter)
          .toList();
      await HighlightBridge.applyHighlights(_controller!, chapterFavs,
          backgroundHex: _readerBackgroundHex,
          customHighlightCss: _customHighlightCss);
      await _controller!.evaluateJavascript(
        source:
            'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
      );
    }
    HibikiToast.show(msg: t.favorite_added);
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
                onPressed: hasCue ? () => ctrl.playCueOnce(cue) : null,
                tooltip: t.repeat_cue,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  ctrl.isPlaying ? Icons.pause : Icons.play_arrow,
                  size: 24,
                ),
                onPressed: ctrl.togglePlayPause,
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
        builder: (context) => buildRow(Theme.of(context)),
      );
    }

    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
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
