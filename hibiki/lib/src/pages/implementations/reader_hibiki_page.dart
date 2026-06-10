import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_spread_analyzer.dart';
import 'package:hibiki/src/epub/epub_spread_map.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/highlight_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState;
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_chrome_scaler.dart';
import 'package:hibiki/src/reader/reader_lyrics_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_resource_sanitizer.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/media/audiobook/pointer_seek.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/volume_key_channel.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki/src/utils/misc/hibiki_color.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show GamepadButton, ModifierKey;
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent, GamepadLongPressIntent;
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/reader_caret_router.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';

/// Which WebView surface the char-level reading cursor lives on. The cursor is
/// on the reader content, or — after a dictionary lookup — on the top popup,
/// following the popup stack as the user looks up deeper words and backs out.
enum CaretSurface { none, reader, popup, lyrics }

/// What the reader-surface caret move resolves to in Dart, given the physical
/// key direction and the `status` hoshiCaret.move returned.
enum ReaderCaretMoveOutcome {
  /// In-page move (status `moved`) or a benign block — nothing for Dart to do.
  none,
  paginateForward,
  paginateBackward,

  /// Physical Down ran off the bottom of the reading content — drop focus into
  /// the bottom chrome bar (the sibling layer below), mirroring the popup's
  /// top-edge Up→header promotion. Down never turns the page; paging is on
  /// Left/Right and the LB/RB shoulders.
  promoteChrome,
}

/// Pure mapping from (physical direction, move status) → Dart action for the
/// reader caret. Extracted so the BUG-020 edge rule is unit-tested without a
/// WebView. Only an explicit physical `down` promotes to the chrome bar; the
/// logical `forward` (Tab / vertical-rl reading advance) still paginates, so
/// reading-order stepping is unaffected.
ReaderCaretMoveOutcome readerCaretMoveOutcome(
    String physicalDir, String status) {
  if (physicalDir == 'down' &&
      (status == 'pageForward' || status == 'blocked')) {
    return ReaderCaretMoveOutcome.promoteChrome;
  }
  if (status == 'pageForward') return ReaderCaretMoveOutcome.paginateForward;
  if (status == 'pageBackward') return ReaderCaretMoveOutcome.paginateBackward;
  return ReaderCaretMoveOutcome.none;
}

/// Whether a handled reader-WebView pointer gesture (swipe / wheel / boundary
/// turn / tap-to-toggle-chrome) should reclaim Flutter keyboard focus for the
/// reading content. The native WebView captures the OS focus on any pointer
/// gesture, silently dropping the reader's [FocusNode]; without reclaiming it,
/// ESC and every reader shortcut stop reaching the page's key handler
/// (BUG-136 — same failure `onAllPopupsDismissed` repairs after a popup's
/// WebView steals focus). Returns false when another Flutter focus owner — a
/// visible dictionary popup, or the bottom chrome bar — legitimately holds it,
/// so reclaiming never yanks focus away from them.
bool shouldReclaimReaderFocusAfterGesture({
  required bool popupVisible,
  required bool chromeHasFocus,
}) =>
    !popupVisible && !chromeHasFocus;

/// 解析结果 + 每章字符数，一次 isolate 往返同时算好，避免把整本书
/// （含全部章节 HTML）二次序列化进新 isolate 只为数字符。
class ParsedBookData {
  const ParsedBookData(this.book, this.charCounts);
  final EpubBook book;
  final List<int> charCounts;
}

/// 逐章纯文本长度。成功路径在解析 isolate 内调用；fallback 路径经 compute()
/// 调用（书已在内存，但仍放后台 isolate，避免在 UI 线程跑 html 解析）。
List<int> countChapterChars(EpubBook book) {
  return List<int>.generate(
    book.chapters.length,
    (int i) => book.chapterPlainText(i).length,
  );
}

/// 在单个 isolate 内解析 EPUB 并计算每章纯文本长度。供 compute() 调用，
/// 也可直接调用做等价性校验。
ParsedBookData parseAndCountChapters(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  return ParsedBookData(book, countChapterChars(book));
}

class ReaderHibikiPage extends BaseSourcePage {
  const ReaderHibikiPage({
    required this.bookKey,
    super.item,
    this.initialBookmarkJump,
    super.key,
  });

  /// EpubBooks primary key (= sanitized title). Identifies the book across all
  /// reading data (positions, bookmarks, audiobook, profile).
  final String bookKey;
  final Bookmark? initialBookmarkJump;

  /// Debug-only hook for integration tests to evaluate JS inside the reader
  /// WebView. Set when the controller is created, cleared on dispose. Guarded
  /// by `assert` so it is tree-shaken out of release builds.
  ///
  /// Assumes a single live reader at a time (the normal case — the reader is a
  /// full-screen route). The reentrancy `assert` in [onWebViewCreated] fires in
  /// debug if a second reader is created before the first disposes.
  @visibleForTesting
  static Future<dynamic> Function(String source)? debugEvaluateJavascript;

  /// Test hook: reports which surface the char cursor lives on
  /// (`none`/`reader`/`popup`). Set in build, cleared on dispose, asserted out of
  /// release builds. Lets integration tests observe the cursor↔popup transfer.
  @visibleForTesting
  static String Function()? debugCaretSurface;

  /// Test hook: evaluate JS on the top visible dictionary popup (resolved via
  /// `topPopupState`, the same path production uses). Null when no popup is up.
  @visibleForTesting
  static Future<dynamic> Function(String source)? debugEvaluateTopPopup;

  /// Test hook: inject the real audiobook bridge JS (`__hoshiHighlight`,
  /// image-pause helpers, sasayaki highlight) on demand. Lets integration tests
  /// drive the production highlight / image-pause reveal path on a plain
  /// (non-audiobook) book in the real paginated WebView, without seeding a full
  /// audiobook. Set in build, cleared on dispose.
  @visibleForTesting
  static Future<void> Function()? debugInjectAudiobookBridge;

  @override
  BaseSourcePageState<ReaderHibikiPage> createState() =>
      _ReaderHibikiPageState();
}

class _ReaderHibikiPageState extends BaseSourcePageState<ReaderHibikiPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  EpubBook? _book;
  EpubSpreadMap? _spreadMap;
  ReaderSettings? _settings;
  String? _extractDir;

  // BUG-099: true for right-to-left reading (vertical-rl, the Japanese default),
  // which flips the bare Left/Right arrow page-turn direction.
  bool get _isRtlReading =>
      (_settings?.writingMode ?? 'vertical-rl') == 'vertical-rl';

  int _currentChapter = 0;
  bool _readerContentReady = false;
  bool _hasEverLoaded = false;
  bool _restoreInFlight = false;
  bool _isNavigatingToChapter = false;
  double _initialProgress = 0;
  // BUG-162: 退出再进的精确恢复锚（section 内绝对字符偏移）。-1 = 无精确锚（旧
  // 存档 / 书签跳转）→ 走粗粒度 restoreProgress 分数。
  int _initialCharOffset = -1;
  // _refreshProgress 算得的最新精确字符偏移，供退出 flush 与 debounce 保存共用。
  int _lastProgressCharOffset = -1;
  String? _initialFragment;

  double _stableTopInset = 0;
  double _stableBottomInset = 0;

  /// 底栏内容行的自然（未缩放）高度。
  static const double _readerChromeBaseHeight = 56;

  /// 查词弹窗顶部四按钮栏的自然（未缩放）高度。
  static const double _readerPopupHeaderBaseHeight = 48;

  /// 阅读器底栏的隐形界面缩放系数：取自全局 appUiScale（阅读器子树被中和器改写成
  /// 1.0，故不能用 HibikiAppUiScale.of）。在 build 里读 appModel 会随缩放变化重建。
  double get _readerChromeScale => appModel.appUiScale;

  /// 缩放后底栏在屏高度。所有把底栏高度喂给 WebView/光标/焦点环/正文预留的地方都
  /// 走这个 getter，保证视觉高度与预留高度恒等。
  double get _readerChromeHeight => ReaderChromeScaler.scaledHeight(
      _readerChromeBaseHeight, _readerChromeScale);
  static const double _infoFontSize = 12;

  int? _progressCurrentChars;
  int? _progressTotalChars;

  int _sessionCharsRead = 0;
  int _lastAbsoluteCount = 0;
  DateTime _sessionStartTime = DateTime.now();

  List<int> _chapterCharCounts = [];
  List<int> _chapterCumulativeChars = [];

  final Map<String, Uint8List> _sanitizedCssCache = {};
  String? _cachedStyleTag;

  Timer? _saveDebounce;
  Timer? _progressPollTimer;
  Timer? _contentReadyTimer;
  Timer? _gamepadAHoldTimer;
  // HBK-AUDIT-120: volume-key throttle uses a last-fire timestamp instead of an
  // empty-callback Timer. The old timer-as-flag pattern obscured intent and left
  // a stale timer gating the next press after a speed-setting change.
  DateTime? _lastVolumeKeyTime;
  int _lastSavedSection = -1;
  double _lastSavedProgress = -1;
  int _lastProgressSection = -1;
  double _lastProgressValue = 0;

  AudiobookPlayerController? _audiobookController;
  String? _audiobookBookKey;
  String? _srtBookUid;
  Map<int, int>? _srtCueChapterMap;
  List<(int firstIdx, int lastIdx)>? _srtChapterRanges;

  bool _audioSlotResolved = false;

  bool _lyricsMode = false;
  bool _lyricsModeTransition = false;
  bool _gamepadALongFired = false;
  // 重入守卫：「调整」面板从点击到 show 之间有 DB 读 await，快速连点会二次进入并
  // 弹出两个面板（BUG-026）。打开期间置 true、关闭后于 finally 复位。
  bool _appearanceSheetOpen = false;

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
  // BUG-111: 记录最近一次 setup 脚本注入 JS 时实际用作 dartPageWidth/Height 的尺寸
  // （= 当时 MediaQuery 读到的视口）。content-ready 后必须用它作为「已分页基线」喂给
  // _syncPageSize，而不是用 content-ready 那一刻的当前 MediaQuery——否则初始重排校验
  // 永远 no-op（见 _onRestoreComplete）。界面缩放(scale!=1.0)未 settle 时初始分页宽度
  // 会偏窄，靠这条基线让 content-ready 后的 _syncPageSize 检出差异并重排。
  double _paginatedWidth = 0;
  double _paginatedHeight = 0;
  double _displayedProgress = 0;

  final FocusNode _focusNode = FocusNode();

  // Focus scope for the bottom chrome (settings/audiobook bar). When a chrome
  // control holds focus, directional keys must traverse the chrome instead of
  // turning the page — gated in [_handleKeyEvent] via this scope's [hasFocus].
  // This intentionally keys off chrome focus (not root focus) so page-turn keys
  // keep working after a tap lands focus inside the WebView (HBK #1).
  final FocusScopeNode _chromeFocusScope =
      FocusScopeNode(debugLabel: 'readerChrome');

  // The dictionary popup's Flutter header toolbar (favourite / replay / play /
  // play-from-cue) is a sibling layer of the popup WebView content, reached by
  // Up at the top of the content — exactly like the reader bottom bar relative
  // to the reading content. Its own scope so focus can move into it and back.
  final FocusScopeNode _popupHeaderScope =
      FocusScopeNode(debugLabel: 'popupHeader');

  // Which surface holds the char-level reading cursor (a focused character inside
  // a WebView's DOM, driven from JS via [ReaderCaretScripts]). The cursor lives
  // on the reader content, or — after a lookup — on the top dictionary popup, and
  // follows the popup stack as the user goes deeper / backs out. While active,
  // A/Enter looks up the word at the cursor, B/Esc backs out a layer, and
  // directional keys / Tab step the cursor.
  CaretSurface _caretSurface = CaretSurface.none;

  // The popup-WebView state that currently holds the cursor (when _caretSurface
  // == popup), so a re-render of the SAME popup (load-more) only re-measures the
  // ring instead of re-seeding the cursor.
  DictionaryPopupWebViewState? _caretPopupState;

  bool get _caretActive => _caretSurface != CaretSurface.none;
  bool get _caretOnReader => _caretSurface == CaretSurface.reader;
  bool get _caretOnLyrics => _caretSurface == CaretSurface.lyrics;

  // The WebView char caret and focus-layer hops are part of the experimental
  // keyboard/gamepad focus navigation system. Page-turn and media shortcuts stay
  // active when the switch is off.
  bool get _focusNavEnabled => appModel.experimentalFocusNavigationEnabled;

  // Serializes the cursor's async JS operations. A gamepad D-pad auto-repeats
  // ~9×/s and a move that turns the page (move → _paginate → reanchor) round-
  // trips slower than that, so overlapping calls would evaluate against a mid-
  // pagination DOM and make the cursor jump. New directional input is dropped
  // while an op is in flight; the next auto-repeat tick moves instead.
  bool _caretBusy = false;

  bool get _showTopProgress =>
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0;

  double get _readerTopOffset => _stableTopInset + _infoFontSize * 1.5;

  double get _readerBottomReserve => _readerChromeHeight + _stableBottomInset;

  @override
  double get popupBottomReserve =>
      // 与 _buildBottomChrome 的可见条件保持一致：底栏占位 ⟺ 弹窗预留底部空间，
      // 否则切章期间底栏可见但预留为 0，弹窗可能被底栏遮挡。
      (_hasEverLoaded && _showChrome) ? _readerBottomReserve : 0;

  @override
  double get popupTopReserve => _stableTopInset;

  @override
  bool get popupVerticalWriting =>
      !_lyricsMode && (_settings?.writingMode.startsWith('vertical') ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The inset reading-content focus ring only paints in traditional
    // (keyboard/gamepad) highlight mode; rebuild it when the mode flips so it
    // appears/disappears with the input device, not only on focus changes.
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
    ReaderHibikiSource.onSettingsChangedLive = () {
      if (!mounted) return;
      // fire-and-forget 必须 catchError：否则 await 边界之后的异步异常（如
      // WebView 半销毁时 evaluateJavascript 抛 PlatformException）会逃进当前
      // zone，绕过 FlutterError.onError/takeException/platformDispatcher，
      // 生产里成未捕获异步错误、测试里让 binding 断言。
      unawaited(_applyStylesLive().catchError((Object e, StackTrace s) {
        ErrorLogService.instance
            .log('ReaderHibiki.onSettingsChangedLive', e, s);
      }));
      setState(() {});
    };
    ReaderHibikiSource.onLayoutReloadLive = () {
      if (!mounted) return;
      unawaited(
          _reloadWithCurrentSettings().catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('ReaderHibiki.onLayoutReloadLive', e, s);
      }));
    };
    _initBook();
  }

  Future<void> _resolveAndApplyProfile(
    HibikiDatabase db, {
    String? mediaTypeOverride,
  }) async {
    try {
      final ProfileRepository profileRepo = ref.read(profileRepositoryProvider);
      final ProfileViewModel profileVm =
          ref.read(profileViewModelProvider.notifier);

      final String bookKey = widget.bookKey;

      String mediaType;
      if (mediaTypeOverride != null) {
        mediaType = mediaTypeOverride;
      } else {
        mediaType = 'epub';
        final abRow = await db.getAudiobookByBookKey(bookKey);
        if (abRow != null) {
          mediaType = 'audiobook';
        } else {
          final srtRow = await db.getSrtBookByBookKey(bookKey);
          if (srtRow != null) {
            mediaType = 'srtbook';
          }
        }
      }

      final int resolvedId = await profileRepo.resolveProfileId(
        bookUid: bookKey,
        mediaType: mediaType,
      );
      final int currentActiveId = await profileRepo.getActiveProfileId();
      if (resolvedId != currentActiveId) {
        await profileVm.switchProfile(resolvedId);
      }
    } catch (e, st) {
      debugPrint(
          '[ReaderHibiki] profile resolution failed (non-fatal): $e\n$st');
    }
  }

  Future<void> _initBook() async {
    final HibikiDatabase db = appModelNoUpdate.database;

    await _resolveAndApplyProfile(db);
    if (!mounted) return;

    if (ReaderHibikiSource.readerSettings == null) {
      final rs = ReaderSettings(db);
      await rs.refreshFromDb();
      ReaderHibikiSource.readerSettings = rs;
    }
    _settings = ReaderHibikiSource.readerSettings;
    if (!mounted) return;

    // Locate the book on disk by its stored extract_dir column (the on-disk
    // folder name may still be a legacy int id; the column is the truth).
    final EpubBookRow? bookRow = await db.getEpubBook(widget.bookKey);
    if (!mounted) return;
    final String extractDir = bookRow?.extractDir ?? '';
    final bool exists = await EpubStorage.bookDirExists(extractDir);
    if (!mounted) return;
    if (!exists) {
      debugPrint('[ReaderHibiki] book ${widget.bookKey} not found on disk');
      HibikiToast.show(msg: t.book_file_not_found);
      Navigator.of(context).pop();
      return;
    }

    _extractDir = extractDir;

    try {
      final ParsedBookData parsed =
          await compute(parseAndCountChapters, extractDir);
      _book = parsed.book;
      _chapterCharCounts = parsed.charCounts;
      debugPrint(
          '[ReaderHibiki] parsed EPUB: ${_book!.chapters.length} chapters');
    } on FormatException catch (e) {
      debugPrint('[ReaderHibiki] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookKey, extractDir);
      if (!mounted) return;
      _book ??= _buildLegacyBook(extractDir);
      // fallback 路径没在解析 isolate 里算字符数，这里补一趟；书已在内存，
      // 但仍走 compute() 放后台 isolate，避免在 UI 线程跑 html 解析。
      _chapterCharCounts = await compute(countChapterChars, _book!);
      if (!mounted) return;
      HibikiToast.show(msg: t.epub_parse_fallback);
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderHibiki] chapter hrefs: $hrefs');

    int cumulative = 0;
    _chapterCumulativeChars = <int>[];
    for (final int count in _chapterCharCounts) {
      _chapterCumulativeChars.add(cumulative);
      cumulative += count;
    }

    await _initSpreadMap(appModelNoUpdate.database);

    await _resolveAudioSlot();
    if (!mounted) return;

    final Bookmark? bm = widget.initialBookmarkJump;
    if (bm != null &&
        bm.sectionIndex >= 0 &&
        bm.sectionIndex < _book!.chapters.length) {
      _currentChapter = bm.sectionIndex;
      _initialProgress = bm.normCharOffset / 10000.0;
      _initialCharOffset = -1; // BUG-162: 书签按 normCharOffset 分数跳转，非 char 锚。
      _lastProgressSection = _currentChapter;
      _lastProgressValue = _initialProgress;
      debugPrint('[ReaderHibiki] restore from bookmark: '
          'chapter=$_currentChapter progress=$_initialProgress');
    } else {
      final ReaderPositionRepository repo = ReaderPositionRepository(db);
      final ReaderPosition? saved = await repo.findByBookKey(widget.bookKey);
      if (!mounted) return;
      debugPrint('[ReaderHibiki] restore lookup: bookKey=${widget.bookKey} '
          'saved=$saved section=${saved?.sectionIndex} '
          'offset=${saved?.normCharOffset}');
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < _book!.chapters.length) {
        _currentChapter = saved.sectionIndex;
        _initialProgress = saved.normCharOffset / 10000.0;
        // BUG-162: 有精确锚就用它（restoreToCharOffset 不动点），否则 -1 回退分数。
        _initialCharOffset = saved.charOffset ?? -1;
        _lastProgressSection = _currentChapter;
        _lastProgressValue = _initialProgress;
        _lastProgressCharOffset = _initialCharOffset;
      } else {
        _restoreFromCurrentAudioCue();
      }
    }

    if (_settings!.keepScreenAwake) {
      try {
        WakelockPlus.enable();
      } catch (e) {
        debugPrint('[Hibiki] wakelock enable failed: $e');
      }
    }

    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    if (src.volumePageTurningEnabled) {
      _setupVolumeKeyHandlers();
    }

    _syncDictionaryTheme();

    final bool savedLyricsMode =
        _audiobookController != null && ReaderHibikiSource.instance.lyricsMode;
    _lyricsMode = savedLyricsMode;
    if (!savedLyricsMode) {
      await ReaderHibikiSource.instance.setLyricsMode(false);
      if (!mounted) return;
    }

    _audioSlotResolved = true;

    setState(() {});
  }

  void _setupVolumeKeyHandlers() {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    VolumeKeyChannel.instance.setHandlers(
      onVolumeUp: () => _onVolumeKey(isUp: true),
      onVolumeDown: () => _onVolumeKey(isUp: false),
    );
    VolumeKeyChannel.instance.setInterceptEnabled(true);
    debugPrint('[ReaderHibiki] volume key handlers installed '
        '(inverted=${src.volumePageTurningInverted}, '
        'speed=${src.volumePageTurningSpeed}ms)');
  }

  void _onVolumeKey({required bool isUp}) {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    final int speedMs = src.volumePageTurningSpeed;
    // HBK-AUDIT-120: throttle by elapsed time since the last accepted press.
    // speedMs<=0 disables throttling; reading speedMs here means a speed-setting
    // change takes effect immediately (no stale timer gating the next press).
    if (speedMs > 0 && _lastVolumeKeyTime != null) {
      final int elapsedMs =
          DateTime.now().difference(_lastVolumeKeyTime!).inMilliseconds;
      if (elapsedMs < speedMs) return;
    }

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

    // HBK-AUDIT-120: record the accepted-press time so the next press is gated
    // by elapsed time rather than an empty-body Timer.
    if (speedMs > 0) {
      _lastVolumeKeyTime = DateTime.now();
    }
  }

  Future<EpubBook?> _buildBookFromDb(
    HibikiDatabase db,
    String bookKey,
    String extractDir,
  ) async {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
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

    debugPrint('[ReaderHibiki] built from DB: ${chapters.length} chapters, '
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
      title: t.untitled_book(id: widget.bookKey),
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
      _audiobookBookKey = null;
      _srtBookUid = null;
      _srtCueChapterMap = null;
      _srtChapterRanges = null;
    }

    final HibikiDatabase db = appModel.database;
    final String bookKey = widget.bookKey;
    final Audiobook? ab =
        (await db.getAudiobookByBookKey(bookKey))?.let(_audiobookFromRow);
    final SrtBook? srt =
        (await db.getSrtBookByBookKey(bookKey))?.let(_srtBookFromRow);

    if (ab != null) {
      await _initAudiobookController(ab, bookKey);
    }
    // Audiobook 记录存在但无音频文件时 _initAudiobookController 提前返回，
    // controller 仍为 null → 回退到 SrtBook 路径加载音频。
    if (_audiobookController == null && srt != null) {
      await _initSrtBookController(srt);
    }

    await _primeAudioCuesForCurrentBook();

    if (_audiobookController == null && _lyricsMode) {
      _lyricsMode = false;
      await ReaderHibikiSource.instance.setLyricsMode(false);
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
      final (Map<int, int> m, List<(int, int)> r) = _buildSrtChapterMap(cues);
      _srtCueChapterMap = m;
      _srtChapterRanges = r;
      return;
    }

    final String? bookKey = _audiobookBookKey;
    if (bookKey == null || _book == null) return;

    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<AudioCue> allCues = await repo.cuesForBook(bookKey);
    controller.setAllBookCues(allCues);
    _cachedAllCues = allCues;
    _cachedSasayaki = allCues.any(
      (c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
    );

    // SRT 格式导入的 Audiobook 在 matcher 全部失败时，cue 的
    // chapterHref 仍为 'srt://default'，按 EPUB 章节 href 查不到。
    // 与 SrtBook 路径对齐，直接用全部 cue。
    final bool allSrtDefault = allCues.isNotEmpty &&
        allCues
            .every((AudioCue c) => c.chapterHref == SrtParser.defaultChapter);

    if (_cachedSasayaki || allSrtDefault) {
      controller.setChapterCues(allCues);
      return;
    }

    final String chapterHref = _book!.chapters[_currentChapter].href;
    final List<AudioCue> chapterCues = await repo.cuesForChapter(
      bookKey: bookKey,
      chapterHref: chapterHref,
    );
    controller.setChapterCues(chapterCues);
  }

  (Map<int, int>, List<(int, int)>) _buildSrtChapterMap(List<AudioCue> cues) {
    if (cues.isEmpty) return (<int, int>{}, <(int, int)>[]);
    final Map<int, int> map = <int, int>{};
    final List<List<AudioCue>> chapters = CuesToEpub.splitChapters(cues);
    final List<(int, int)> ranges = <(int, int)>[];
    for (int ch = 0; ch < chapters.length; ch++) {
      ranges.add(
          (chapters[ch].first.sentenceIndex, chapters[ch].last.sentenceIndex));
      for (final AudioCue cue in chapters[ch]) {
        map[cue.sentenceIndex] = ch;
      }
    }
    return (map, ranges);
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
      debugPrint('[ReaderHibiki] restore from audio cue: '
          'chapter=$_currentChapter progress=$_initialProgress');
      return;
    }

    if (_srtCueChapterMap != null && _srtChapterRanges != null) {
      final int? srtChapter = _srtCueChapterMap![cue.sentenceIndex];
      if (srtChapter != null &&
          srtChapter >= 0 &&
          srtChapter < _srtChapterRanges!.length &&
          srtChapter < _book!.chapters.length) {
        _currentChapter = srtChapter;
        final (int first, int last) = _srtChapterRanges![srtChapter];
        final int span = last - first;
        _initialProgress = span > 0
            ? ((cue.sentenceIndex - first) / span).clamp(0.0, 1.0)
            : 0.0;
        _lastProgressSection = srtChapter;
        _lastProgressValue = _initialProgress;
        debugPrint('[ReaderHibiki] restore from SRT cue: '
            'chapter=$srtChapter progress=$_initialProgress');
        return;
      }
    }

    final int chapter = _chapterIndexForCue(cue);
    final int fallbackChapter =
        chapter >= 0 ? chapter : _chapterIndexForText(cue.text);
    if (fallbackChapter < 0) return;
    _currentChapter = fallbackChapter;
    _initialProgress = 0.0;
    _lastProgressSection = fallbackChapter;
    _lastProgressValue = 0.0;
    debugPrint('[ReaderHibiki] restore from audio cue chapter: '
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
    String bookKey,
  ) async {
    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<File> audioFiles = await _resolveAudioFiles(
      audioPaths: audiobook.audioPaths,
      audioRoot: audiobook.audioRoot,
    );
    if (audioFiles.isEmpty) {
      debugPrint('[ReaderHibiki] audiobook found but no audio files');
      debugPrint('[ReaderHibiki] audio slot cleared: no files found');
      return;
    }

    final AudiobookPlayerController controller = AudiobookPlayerController();
    final List<Object> prefs = await Future.wait(<Future<Object>>[
      repo.readFollowAudio(bookKey),
      repo.readDelayMs(bookKey),
      repo.readSpeed(bookKey),
      repo.readPositionMs(bookKey),
      repo.readImagePauseSec(bookKey),
      repo.readVolume(bookKey),
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
        initialVolume: prefs[5] as double,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.loadAudiobook', e, stack);
      debugPrint('[ReaderHibiki] audiobook load failed: $e');
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

    controller.onPositionWrite =
        (key, posMs) => repo.updatePositionMs(bookKey: key, positionMs: posMs);
    controller.onDelayPersist = (ms) async {
      await repo.updateDelayMs(bookKey: bookKey, ms: ms);
    };
    controller.onSpeedPersist = (speed) async {
      await repo.updateSpeed(bookKey: bookKey, speed: speed);
    };
    controller.onVolumePersist = (volume) async {
      await repo.updateVolume(bookKey: bookKey, volume: volume);
    };
    controller.onImagePausePersist = (sec) async {
      await repo.updateImagePauseSec(bookKey: bookKey, sec: sec);
    };
    controller.onFollowAudioPersist = (value) async {
      await repo.updateFollowAudio(bookKey: bookKey, value: value);
    };
    controller.getCurrentReaderSection = () => _currentChapter;
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.onBoundarySkip = _handleBoundarySkip;
    controller.addListener(_onCueChanged);

    _audiobookBookKey = bookKey;

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
      debugPrint('[ReaderHibiki] srt book found but no audio files');
      debugPrint('[ReaderHibiki] audio slot cleared: no files found');
      return;
    }

    final Audiobook syntheticAudiobook = Audiobook()
      ..bookKey = srtBook.uid
      ..audioRoot = srtBook.audioRoot
      ..audioPaths = srtBook.audioPaths
      ..alignmentFormat = 'srt'
      ..alignmentPath = srtBook.srtPath;

    final String srtBookUid = srtBook.uid;
    final AudiobookRepository abRepo = AudiobookRepository(appModel.database);
    final AudiobookPlayerController controller = AudiobookPlayerController();

    final List<Object> prefs = await Future.wait(<Future<Object>>[
      abRepo.readFollowAudio(srtBookUid),
      abRepo.readDelayMs(srtBookUid),
      abRepo.readSpeed(srtBookUid),
      abRepo.readPositionMs(srtBookUid),
      abRepo.readImagePauseSec(srtBookUid),
      abRepo.readVolume(srtBookUid),
    ]);
    try {
      await controller.load(
        audiobook: syntheticAudiobook,
        audioFiles: audioFiles,
        initialFollowAudio: prefs[0] as bool,
        initialDelayMs: prefs[1] as int,
        initialSpeed: prefs[2] as double,
        initialPositionMs: prefs[3] as int,
        initialImagePauseSec: prefs[4] as int,
        initialVolume: prefs[5] as double,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.loadSrtBook', e, stack);
      debugPrint('[ReaderHibiki] srt book load failed: $e');
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

    controller.onPositionWrite = (String key, int posMs) =>
        abRepo.updatePositionMs(bookKey: key, positionMs: posMs);
    controller.onDelayPersist = (int ms) async {
      await abRepo.updateDelayMs(bookKey: srtBookUid, ms: ms);
    };
    controller.onSpeedPersist = (double speed) async {
      await abRepo.updateSpeed(bookKey: srtBookUid, speed: speed);
    };
    controller.onVolumePersist = (double volume) async {
      await abRepo.updateVolume(bookKey: srtBookUid, volume: volume);
    };
    controller.onImagePausePersist = (int sec) async {
      await abRepo.updateImagePauseSec(bookKey: srtBookUid, sec: sec);
    };
    controller.onFollowAudioPersist = (bool value) async {
      await abRepo.updateFollowAudio(bookKey: srtBookUid, value: value);
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
    assert(() {
      ReaderHibikiPage.debugEvaluateJavascript = null;
      ReaderHibikiPage.debugCaretSurface = null;
      ReaderHibikiPage.debugEvaluateTopPopup = null;
      ReaderHibikiPage.debugInjectAudiobookBridge = null;
      return true;
    }());
    ReaderHibikiSource.onSettingsChangedLive = null;
    ReaderHibikiSource.onLayoutReloadLive = null;
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    WidgetsBinding.instance.removeObserver(this);
    _progressPollTimer?.cancel();
    _saveDebounce?.cancel();
    _contentReadyTimer?.cancel();
    _clearGamepadAHold();
    VolumeKeyChannel.instance.setHandlers();
    VolumeKeyChannel.instance.setInterceptEnabled(false);
    appModel.setOverrideDictionaryTheme(null);
    appModel.setOverrideDictionaryColor(null);
    // HBK-AUDIT-122: shared sync-then-flush (also used by lifecycle handler).
    _syncAndFlushPosition();
    _flushReadingStats();
    _audiobookController?.removeListener(_onCueChanged);
    _audiobookController?.dispose();
    _readingTimeTracker?.dispose();
    _focusNode.dispose();
    _chromeFocusScope.dispose();
    _popupHeaderScope.dispose();
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
    } catch (e) {
      debugPrint('[Hibiki] wakelock disable failed: $e');
    }
    super.dispose();
  }

  // The input device flipped between touch (mouse/pointer) and keyboard/gamepad.
  void _onHighlightModeChanged(FocusHighlightMode mode) {
    if (!mounted) return;
    // The char caret is a keyboard/gamepad affordance: hide its ring on the
    // mouse ("用鼠标的时候焦点应消失") and bring it back on hardware nav. Crucially
    // we SUSPEND (hide the ring) rather than exit — the caret keeps its surface,
    // so when the controller is picked back up the directions still drive the
    // popup/reader caret instead of falling through to the reader's page-turn.
    if (_caretActive) {
      final bool suspend = mode == FocusHighlightMode.touch;
      switch (_caretSurface) {
        case CaretSurface.popup:
          if (suspend) {
            topPopupState?.caretSuspend();
          } else {
            _resumePopupCaretForHardwareNav();
          }
          break;
        case CaretSurface.reader:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderCaretScripts.suspendInvocation()
                : ReaderCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.lyrics:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderLyricsCaretScripts.suspendInvocation()
                : ReaderLyricsCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.none:
          break;
      }
    }
    setState(() {});
  }

  void _resumePopupCaretForHardwareNav() {
    final DictionaryPopupWebViewState? state = topPopupState;
    if (state == null) {
      _caretPopupState = null;
      _caretSurface = CaretSurface.none;
      return;
    }
    if (!identical(state, _caretPopupState)) {
      unawaited(_transferCaretToTopPopup(state));
      return;
    }
    state.caretResume();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // HBK-AUDIT-122: sync lyrics cue position before flushing so backgrounding
      // in lyrics mode persists the current playback position, not a stale scroll.
      _syncAndFlushPosition();
      _flushReadingStats();
    }
  }

  Future<void> _syncPageSize() async {
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    final Size screen = MediaQuery.of(context).size;
    final double w = screen.width;
    final double h = screen.height;
    final bool widthChanged = _lastSyncedWidth > 0 && w != _lastSyncedWidth;
    final bool heightChanged = (h - _lastSyncedHeight).abs() >= 1;
    if (!widthChanged && !heightChanged) return;
    // BUG-111: 诊断——窗口/缩放 settle 或 resize 后，把真实视口与已分页基线比对。
    // 若 content-ready 后这里报 widthChanged，说明初始分页宽度偏窄、正在自动重排铺满。
    debugPrint('[ReaderHibiki] _syncPageSize w=$w h=$h '
        'paginated=$_paginatedWidth x $_paginatedHeight '
        'widthChanged=$widthChanged heightChanged=$heightChanged');
    _lastSyncedWidth = w;
    _lastSyncedHeight = h;

    if (widthChanged) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.progressInvocation(),
      );
      if (!mounted || _controller == null) return;
      final double? progress = ReaderPaginationScripts.doubleResult(result);
      if (progress != null && progress > 0) {
        _displayedProgress = progress;
      }
      await _navigateToChapter(
        _currentChapter,
        progress: _displayedProgress,
      );
    } else {
      await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.updatePageSizeInvocation(w, h),
      );
      if (!mounted || _controller == null) return;
      await _caretRefresh();
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

    return Actions(
      // Desktop gamepad path: the GamepadService dispatches GamepadButtonIntent
      // here (no gameButton* key events on desktop). Resolving it against the
      // reader/audiobook scopes routes polled controller input through the exact
      // same actions as the Android key-event path.
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) =>
              _handleGamepadButton(intent.button),
        ),
        GamepadLongPressIntent: CallbackAction<GamepadLongPressIntent>(
          onInvoke: (GamepadLongPressIntent intent) =>
              _handleGamepadLongPress(intent.button),
        ),
      },
      child: Focus(
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
                  child: _buildBody(),
                ),
                if (!_readerContentReady)
                  Positioned.fill(
                    child: ColoredBox(color: bgColor),
                  ),
                if (_readerContentReady)
                  const SizedBox.shrink(
                      key: ValueKey<String>('hoshi_content_ready')),
                // On-screen focus indicator for the "reading content" layer,
                // matching the app's standard focus ring (HibikiFocusRing:
                // colorScheme.primary, 2.5px, 8px radius). Shown while the reader
                // content holds primary focus and no char cursor is active (the
                // cursor draws its own ring). Inset by the chrome insets so the
                // ring sits inside the reading viewport and the bottom bar never
                // occludes it — and so it is always on-screen (unlike the native
                // WebView focus outline, which drew off-screen at the scroll pos).
                if (_readerContentReady && !_lyricsMode)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _focusNode,
                        builder: (context, _) {
                          // Only in keyboard/gamepad highlight mode — matches the
                          // app-wide HibikiFocusRing convention (no focus ring in
                          // touch mode). Rebuilt on highlight change via
                          // _onHighlightModeChanged.
                          final bool show = _focusNavEnabled &&
                              _focusNode.hasPrimaryFocus &&
                              _caretSurface == CaretSurface.none &&
                              FocusManager.instance.highlightMode ==
                                  FocusHighlightMode.traditional;
                          if (!show) return const SizedBox.shrink();
                          final double bottomInset = _showChrome
                              ? _readerChromeHeight + _stableBottomInset
                              : _stableBottomInset;
                          return Padding(
                            padding: EdgeInsets.fromLTRB(
                                1.5, _readerTopOffset, 1.5, bottomInset),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                _buildTopProgressBar(),
                buildDictionary(),
                // The bottom chrome returns a Positioned; it MUST stay a direct
                // child of this Stack. The chrome FocusScope is mounted INSIDE
                // the Positioned (see _buildAudiobookBar / _buildSettingsBar) so
                // it never detaches the Positioned's StackParentData (which would
                // drop the bar to the Stack's top-start alignment).
                _buildBottomChrome(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_audioSlotResolved || _book == null || _extractDir == null) {
      return Center(child: adaptiveIndicator(context: context));
    }
    return _buildWebView();
  }

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
      // HBK-AUDIT-118: legacy Japanese XHTML can be Shift_JIS/EUC-JP; strict
      // utf8.decode throws FormatException here and the chapter fails to load.
      // Degrade gracefully (malformed bytes -> U+FFFD) to match epub_parser's
      // _readText contract (HBK-AUDIT-033) instead of crashing the load.
      String html = utf8.decode(data, allowMalformed: true);
      // BUG-079: XHTML self-closing raw-text elements (e.g. `<script .../>` with
      // no `</script>`) swallow the whole body under the HTML5 parser, blanking
      // the page. Normalize them to paired tags before injecting reader styles.
      html = ReaderResourceSanitizer.sanitizeXhtml(html);
      final String styleTag = _buildStyleTag();
      const String hideUntilReady =
          '<style id="hoshi-cloak">body{visibility:hidden!important}</style>';
      // Cloak goes early (right after <head>) to hide FOUC.
      // Reader style goes last (before </head>) so it wins over EPUB
      // CSS in !important specificity ties (later declaration wins).
      final RegExp headOpenPattern =
          RegExp('<head[^>]*>', caseSensitive: false);
      final RegExp headClosePattern =
          RegExp(r'</head\s*>', caseSensitive: false);
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

  bool get _isCustomTheme => appModel.appThemeKey == 'custom-theme';

  String _buildStyleTag() {
    return _cachedStyleTag ??= _computeStyleTag();
  }

  String _computeStyleTag() {
    return '<style id="hoshi-reader-style">\n${ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      customBg: _isCustomTheme ? _readerBackgroundHex : null,
      customFg: _isCustomTheme ? _customThemeTextCss : null,
      selectionColor: _isCustomTheme
          ? _colorToCssRgba(appModel.customThemeSelectionColor)
          : null,
      sasayakiColor: _isCustomTheme
          ? _colorToCssRgba(appModel.customThemeSasayakiColor)
          : null,
      linkColor: _isCustomTheme
          ? _colorToCssRgba(appModel.customThemeLinkColor)
          : null,
    )}\n</style>';
  }

  void _invalidateStyleCache() {
    _cachedStyleTag = null;
  }

  Future<void> _applyStylesLive() async {
    if (_controller == null || _settings == null) return;
    _invalidateStyleCache();
    // _settings 即 ReaderHibikiSource.readerSettings 本体，setTtu* 已在触发本
    // 回调前写穿同一对象，无需再 _syncSettingsFromHive 自拷贝（旧 TTU 死桥）。
    if (!mounted || _controller == null) return;
    if (_lyricsMode) {
      await _updateLyricsStyleLive();
      return;
    }
    final String css = ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      customBg: _isCustomTheme ? _readerBackgroundHex : null,
      customFg: _isCustomTheme ? _customThemeTextCss : null,
      selectionColor: _isCustomTheme
          ? _colorToCssRgba(appModel.customThemeSelectionColor)
          : null,
      sasayakiColor: _isCustomTheme
          ? _colorToCssRgba(appModel.customThemeSasayakiColor)
          : null,
      linkColor: _isCustomTheme
          ? _colorToCssRgba(appModel.customThemeLinkColor)
          : null,
    );
    final String jsonCss = jsonEncode(css);
    try {
      await _controller!.evaluateJavascript(
        source: '''
(function(){
  var el = document.getElementById('hoshi-reader-style');
  if (!el) {
    el = document.createElement('style');
    el.id = 'hoshi-reader-style';
    document.head.appendChild(el);
  }
  var css = $jsonCss;
  // 字体大小/行间/余白等 live 变更会让 body 重新分页排版。仅换 textContent 会让
  // 视口停在错位滚动量、最上一行被裁（BUG-023）。reanchorAfterStyleChange 在换样式
  // 的同时按既有重锚机制（捕捉进度→失效 metrics→rAF 重锚到分页边界）回正；仅在
  // pagination 未就绪 / 非 reader 页（无 hoshiReader）时回退裸 textContent。
  var r = window.hoshiReader;
  if (r && typeof r.reanchorAfterStyleChange === 'function') {
    r.reanchorAfterStyleChange(el, css);
  } else {
    el.textContent = css;
  }
})();
''',
      );
    } catch (e, stack) {
      // controller 非 null 但底层 WebView 平台视图已销毁时 evaluateJavascript
      // 抛 PlatformException。无活动 WebView 时套样式本就无意义 → 安全 no-op。
      ErrorLogService.instance
          .log('ReaderHibiki.applyStylesLive.eval', e, stack);
      return;
    }
    if (mounted) setState(() {});
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
        fontSize: s.fontSize.round(),
        initialFragment: _initialFragment,
        sasayakiCuesJson: sasayakiCuesJson,
        chromeTopInset: _readerTopOffset,
        chromeBottomInset: _showChrome
            ? _readerChromeHeight + _stableBottomInset
            : _stableBottomInset,
        dartPageWidth: screenSize.width,
        dartPageHeight: screenSize.height,
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
  window.scanNonJapaneseText = true;
  $selectionJs
  $paginationJs
  $caretJs
  $caretInit;
  $furiganaJs
  var startX = 0, startY = 0, startTime = 0, hasStart = false;
  var imageLongPressTimer = null;
  var imageLongPressConsumed = false;
  var imageLongPressStartX = 0, imageLongPressStartY = 0;
  function _gestureStart(x, y) { hasStart = true; startX = x; startY = y; startTime = Date.now(); }
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
    if (absDx > absDy && (absDx >= 72 || (absDx >= 36 && velocity >= 900))) {
      if (e && e.preventDefault) e.preventDefault();
      if (dx < 0) {
        window.flutter_inappwebview.callHandler('onSwipe', 'left');
      } else {
        window.flutter_inappwebview.callHandler('onSwipe', 'right');
      }
    } else if (absDx < 20 && absDy < 20 && elapsed < 500) {
      var imgUrl = _hoshiBlockImageUrl(document.elementFromPoint(x, y));
      if (imgUrl) {
        window.flutter_inappwebview.callHandler('onImageTap', imgUrl);
      } else {
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
    var t = e.changedTouches[0]; _gestureEnd(t.clientX, t.clientY, e);
  }, {passive: false});
  document.addEventListener('touchcancel', function(e) {
    clearImageLongPressTimer();
    imageLongPressConsumed = false;
    hasStart = false;
  }, {passive: true});
  document.addEventListener('pointerdown', function(e) {
    if (e.pointerType === 'touch' || e.button !== 0) return;
    _gestureStart(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointerup', function(e) {
    if (e.pointerType === 'touch' || e.button !== 0) return;
    _gestureEnd(e.clientX, e.clientY, e);
  }, {passive: false});
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
    if (hasStart && (Date.now() - startTime) < 400) e.preventDefault();
  });
  var _wheelTimer = null;
  document.addEventListener('wheel', function(e) {
    if (_wheelTimer) return;
    var r = window.hoshiReader;
    if (!r || !('paginationMetrics' in r)) return;
    _wheelTimer = setTimeout(function() { _wheelTimer = null; }, ${s.wheelPageTurnInterval});
    var forward = (e.deltaY < 0 || e.deltaX > 0);
    window.flutter_inappwebview.callHandler('onSwipe', forward ? 'left' : 'right');
    e.preventDefault();
  }, {passive: false});
  var _shiftHoverLastX = -1, _shiftHoverLastY = -1;
  document.addEventListener('mousemove', function(e) {
    if (!e.shiftKey) { _shiftHoverLastX = -1; _shiftHoverLastY = -1; return; }
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
              prunePopupStack(0);
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
              (String source) async => topPopupState?.debugEval(source);
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
            final double x = _toDouble(args[0]) ?? 0;
            final double y = _toDouble(args[1]) ?? 0;
            // Selection → onTextSelected → popup, which takes focus itself; do
            // not reclaim here or we would fight the popup for focus.
            _selectTextAt(x, y);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onShiftHover',
          callback: (args) {
            if (args.length < 2) return;
            final double x = _toDouble(args[0]) ?? 0;
            final double y = _toDouble(args[1]) ?? 0;
            _selectTextAt(x, y);
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

        controller.addJavaScriptHandler(
          handlerName: 'onBoundarySwipe',
          callback: (List<dynamic> args) {
            if (args.isEmpty || _lyricsMode) return;
            // Boundary swipe → chapter turn also stole focus to the WebView
            // (BUG-136); reclaim it so ESC keeps exiting after a chapter flip.
            _reclaimReaderFocusAfterGesture();
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
          handlerName: 'onImageContextMenu',
          callback: (args) async {
            if (args.isEmpty) return;
            final double x = args.length > 1 ? (_toDouble(args[1]) ?? 0) : 0;
            final double y = args.length > 2 ? (_toDouble(args[2]) ?? 0) : 0;
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
              setState(() {
                _readerContentReady = true;
                // spread(漫画双页)路径只发 'spreadReady'，从不发 'onRestoreComplete'，
                // 故不走 _onRestoreComplete 的 _hasEverLoaded 置位。这里补齐，与另外
                // 三个 content-ready 完成点对齐 —— 否则 spread 书冷开时底栏(有声书条/
                // 设置条)要等 8s _startContentReadyTimeout 兜底才出现。set-once，不复位。
                _hasEverLoaded = true;
              });
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
            final double x = _toDouble(args[1]) ?? 0;
            final double y = _toDouble(args[2]) ?? 0;
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
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._onChapterLoadComplete', e, stack);
      debugPrint('[ReaderHibiki] _onChapterLoadComplete failed: $e');
    }
  }

  Future<void> _applyChapterHighlights() async {
    if (_controller == null) return;
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);
    final List<FavoriteSentence> all = await repo.getAll();
    if (!mounted || _controller == null) return;
    final List<FavoriteSentence> chapterFavs = all
        .where((s) =>
            s.bookKey == widget.bookKey && s.sectionIndex == _currentChapter)
        .toList();
    final int withOffsets =
        chapterFavs.where((s) => s.normCharOffset != null).length;
    debugPrint('[hoshi-hl] chapter=$_currentChapter '
        'total=${all.length} chapterFavs=${chapterFavs.length} '
        'withOffsets=$withOffsets');
    if (chapterFavs.isNotEmpty) {
      await HighlightBridge.applyHighlights(_controller!, chapterFavs,
          backgroundHex: _readerBackgroundHex,
          customHighlightCss: _customHighlightCss);
      if (!mounted || _controller == null) return;
      await _controller!.evaluateJavascript(
        source:
            'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
      );
      // HBK-AUDIT-117: theme persistence moved to _onThemeChanged — it is
      // unrelated to highlight application and must not be gated on favorites.
    }
  }

  Future<void> _applyLyricsFavorites() async {
    if (_controller == null) return;
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);
    final List<FavoriteSentence> all = await repo.getAll();
    if (_controller == null || !mounted) return;
    final List<String> texts = all
        .where((s) => s.bookKey == widget.bookKey)
        .map((s) => s.text)
        .where((t) => t.isNotEmpty)
        .toList();
    final String json = jsonEncode(texts);
    await _controller!.evaluateJavascript(
      source:
          'window.__lyricsMarkFavorites && window.__lyricsMarkFavorites($json);',
    );
  }

  // ── Restore Complete ──────────────────────────────────────────────

  Completer<bool>? _restoreCompleter;
  int _navigateGeneration = 0;
  int _restoreExpectedGeneration = 0;

  void _startContentReadyTimeout() {
    _contentReadyTimer?.cancel();
    _contentReadyTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _readerContentReady) return;
      debugPrint(
          '[ReaderHibiki] content ready timeout — forcing overlay removal');
      setState(() {
        _readerContentReady = true;
        _hasEverLoaded = true;
      });
      HibikiToast.show(msg: t.reader_content_timeout);
    });
  }

  void _onRestoreComplete() {
    _contentReadyTimer?.cancel();
    if (!mounted) {
      return;
    }
    if (_restoreExpectedGeneration != _navigateGeneration) {
      debugPrint(
        '[ReaderHibiki] stale onRestoreComplete: '
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
      // BUG-111: 基线必须是「JS 实际分页用的宽高」(_paginatedWidth/Height)，
      // 不能用 content-ready 这一刻的当前 MediaQuery——否则下面 postFrame 的
      // _syncPageSize 比对的是同一个值，width/height 差永远为 0、初始重排校验恒
      // no-op。改用 _paginatedWidth 后：若界面缩放(scale!=1.0)未 settle 致初始
      // 分页偏窄，settle 后的真实视口宽与基线不等 → _syncPageSize 重新分页铺满。
      _lastSyncedWidth = _paginatedWidth;
      _lastSyncedHeight = _paginatedHeight;
      setState(() {
        _readerContentReady = true;
        _hasEverLoaded = true;
      });
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncPageSize();
      });
    }

    // 收藏高亮：在恢复完成（章节分页布局已稳定、恢复滚动已结束）时重新应用。
    // _onChapterLoadComplete 里的早期 apply 跑在 onLoadStop 同步返回之后，
    // 而 hoshiReader.initialize 把 buildNodeOffsets / 恢复滚动塞进图片
    // Promise.all().then() 里异步执行——早期 apply 抢在列布局存在之前注册
    // CSS Custom Highlight range，重进章节时高亮不绘制（立即收藏时布局已稳定
    // 所以能显示）。在这里（与立即收藏相同的稳定状态）再应用一次即可对齐。
    // 重复应用是幂等的：__hibikiApplyHighlights 会先清空再重建 range map。
    if (!_lyricsMode) {
      _applyChapterHighlights();
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
      const Duration(seconds: 10),
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
    try {
      setState(() => _lyricsMode = entering);
      await ReaderHibikiSource.instance.setLyricsMode(entering);

      if (entering) {
        // 文档即将被 LyricsModeHtml 整页替换（其中无 window.hoshiCaret）。若此刻
        // reader caret 正激活，surface 会滞留 reader，之后方向键会对歌词文档调
        // window.hoshiCaret.move() 报错、caret 卡死——进入前先丢掉旧 caret。
        _exitCaret();
        await _resolveAndApplyProfile(
          appModelNoUpdate.database,
          mediaTypeOverride: 'lyrics',
        );
        final List<AudioCue> allCues =
            _audiobookController!.allBookCuesSnapshot;
        if (allCues.isNotEmpty) {
          _audiobookController!.setChapterCues(allCues);
        }
        _lyricsEntryChapter = _currentChapter;
        _lyricsEntryCueIndex =
            _audiobookController!.allBookCuesSnapshot.isNotEmpty
                ? _audiobookController!.allBookCueIdx
                : _audiobookController!.currentCueIdx;
        await _loadLyricsPage();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        _showLyricsModeHintIfNeeded();
      } else {
        await _resolveAndApplyProfile(appModelNoUpdate.database);
        await _exitLyricsMode();
        try {
          await _restoreCompleter?.future.timeout(
            const Duration(seconds: 8),
            onTimeout: () => false,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log('ReaderHibiki.lyricsRestore', e, stack);
        }
      }
    } finally {
      if (mounted) setState(() => _lyricsModeTransition = false);
    }
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
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;

    String colorToCss(Color c) =>
        'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(2)})';

    final String html = LyricsModeHtml.generate(
      cues: _lyricsCueList,
      currentIndex: safeCurrentIdx.clamp(0, _lyricsCueList.length - 1),
      backgroundColor: colorToCss(bg),
      textColor: colorToCss(fg),
      accentColor: colorToCss(accent),
      fontSize: ReaderHibikiSource.instance.lyricsFontSize,
      marginTop: ReaderHibikiSource.instance.lyricsMarginTop,
      marginBottom: ReaderHibikiSource.instance.lyricsMarginBottom,
      marginLeft: ReaderHibikiSource.instance.lyricsMarginLeft,
      marginRight: ReaderHibikiSource.instance.lyricsMarginRight,
    );

    await _controller!.loadData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf-8',
      baseUrl: WebUri('https://hoshi.local/lyrics'),
    );
  }

  Future<void> _updateLyricsStyleLive() async {
    if (!mounted || _controller == null || !_lyricsPageReady) return;
    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final Color accent = _isReaderThemeDark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
    final double fontSize = ReaderHibikiSource.instance.lyricsFontSize;

    String colorToCss(Color c) =>
        'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(2)})';

    final String bgCss = colorToCss(bg);
    final String fgCss = colorToCss(fg);
    final String accentCss = colorToCss(accent);

    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    final double mt = src.lyricsMarginTop;
    final double mb = src.lyricsMarginBottom;
    final double ml = src.lyricsMarginLeft;
    final double mr = src.lyricsMarginRight;
    try {
      await _controller!.evaluateJavascript(
        source: 'window.__lyricsUpdateStyle && window.__lyricsUpdateStyle('
            "'$bgCss','$fgCss','$accentCss',$fontSize,$mt,$mb,$ml,$mr);",
      );
    } catch (e, stack) {
      // 与 _applyStylesLive/_reloadWithCurrentSettings 对称：半销毁 WebView 上
      // eval 抛 PlatformException，安全 no-op（lyrics 路径也不再裸露孤儿 await）。
      ErrorLogService.instance
          .log('ReaderHibiki.updateLyricsStyleLive.eval', e, stack);
      return;
    }
    // cue 文本随字号/边距重排，激活中的焦点环坐标会过期——重测一次跟上新布局。
    if (_caretOnLyrics) await _caretRefresh();
    if (mounted) setState(() {});
  }

  void _showLyricsModeHintIfNeeded() {
    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    final bool shown = src.getPreference<bool>(
      key: 'lyrics_mode_hint_shown',
      defaultValue: false,
    );
    if (shown || !mounted) return;
    src.setPreference<bool>(key: 'lyrics_mode_hint_shown', value: true);
    showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => ReaderLyricsModeHintDialog(
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  Future<void> _exitLyricsMode() async {
    // 离开歌词模式会重载 reader 章节，lyrics caret JS 随之消失；复位 surface，
    // 否则方向键/A 会被误路由到已不存在的 hoshiLyricsCaret。
    if (_caretSurface == CaretSurface.lyrics) {
      setState(() => _caretSurface = CaretSurface.none);
    }
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
          // followAudio OFF → pass scroll=false so the lyrics page updates the
          // current-line highlight but does not auto-scroll (the toggle was a
          // no-op before: __lyricsSetCue always scrolled regardless).
          _controller!.evaluateJavascript(
            source: 'if(window.__lyricsSetCue)'
                'window.__lyricsSetCue($idx, ${controller.followAudio.value});',
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
        _syncFloatingLyric(controller);
        _syncMediaNotification(controller);
        return;
      }
      if (frag == null && _srtCueChapterMap != null) {
        final int? cueChapter = _srtCueChapterMap![cue.sentenceIndex];
        if (cueChapter != null && cueChapter != _currentChapter) {
          if (controller.shouldRevealCurrentCue && !_restoreInFlight) {
            _navigateToChapter(cueChapter);
          } else {
            AudiobookBridge.highlight(_controller!);
          }
          _syncFloatingLyric(controller);
          _syncMediaNotification(controller);
          return;
        }
      }
    }
    final bool forceReveal = controller.consumeForceReveal();
    final bool reveal = forceReveal || controller.shouldRevealCurrentCue;
    AudiobookBridge.highlight(_controller!, cue: cue, reveal: reveal);
    _syncPositionFromCurrentCue();
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
  int? _cachedSentenceOffset;
  bool _currentSentenceIsFavorited = false;

  int get _lookupSectionIndex {
    if (_lyricsMode && _lookupCue != null) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(_lookupCue!.textFragmentId);
      if (frag != null) return frag.sectionIndex;
    }
    return _currentChapter;
  }

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

  AudioCue? _findCueForSentence(String sentence) {
    if (_srtBookUid == null) return null;
    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null || allCues.isEmpty) return null;

    final int chapter = _currentChapter;
    int startIdx = 0;
    int endIdx = allCues.length;
    if (_srtChapterRanges != null &&
        chapter >= 0 &&
        chapter < _srtChapterRanges!.length) {
      final (int first, int last) = _srtChapterRanges![chapter];
      startIdx = first;
      endIdx = last + 1;
    }

    final String needle = sentence.trim();
    if (needle.isEmpty) return null;

    for (int i = startIdx; i < endIdx && i < allCues.length; i++) {
      if (allCues[i].text.trim() == needle) return allCues[i];
    }
    for (int i = startIdx; i < endIdx && i < allCues.length; i++) {
      if (allCues[i].text.length > 2 && needle.contains(allCues[i].text)) {
        return allCues[i];
      }
    }
    return null;
  }

  List<AudioCue> _sentenceAudioMiningCues(AudioCue cue) {
    if (_lyricsMode && _lyricsCueList.isNotEmpty) {
      return _lyricsCueList;
    }

    final List<AudioCue>? allCues = _cachedAllCues;
    if (_srtBookUid != null && allCues != null && allCues.isNotEmpty) {
      final int chapter = _currentChapter;
      if (_srtChapterRanges != null &&
          chapter >= 0 &&
          chapter < _srtChapterRanges!.length) {
        final (int first, int last) = _srtChapterRanges![chapter];
        final int safeFirst = first.clamp(0, allCues.length);
        final int safeLast = (last + 1).clamp(safeFirst, allCues.length);
        return allCues.sublist(safeFirst, safeLast);
      }
      return allCues;
    }

    final List<AudioCue> sectionCues =
        _audiobookController?.sasayakiCuesForSection(_lookupSectionIndex) ??
            const <AudioCue>[];
    if (sectionCues.isNotEmpty) {
      return sectionCues;
    }

    final List<AudioCue> chapterCues =
        _audiobookController?.chapterCuesSnapshot ?? const <AudioCue>[];
    if (chapterCues.isNotEmpty) {
      return chapterCues;
    }

    return <AudioCue>[cue];
  }

  void _syncCueSentence() {
    final String cueText = _lookupCue?.text ?? '';
    if (cueText.isNotEmpty) {
      appModel.currentMediaSource?.setCurrentCueSentence(
        selection: HibikiTextSelection(text: cueText),
      );
    } else {
      appModel.currentMediaSource?.clearCurrentCueSentence();
    }
  }

  @override
  void clearDictionaryResult() {
    _lookupCue = null;
    _cachedSelectionRange = null;
    _cachedSentenceRange = null;
    _cachedSentenceOffset = null;
    _currentSentenceIsFavorited = false;
    appModel.currentMediaSource?.clearCurrentCueSentence();
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
    Directory? sasayakiTempDir;
    final AudioCue? cue = _lookupCue;
    final AudiobookPlayerController? audioController = _audiobookController;
    final List<File>? audioFiles = audioController?.audioFiles;
    if (cue != null && audioFiles != null) {
      final AudioPlaybackRange clip = miningSentenceAudioRange(
        cues: _sentenceAudioMiningCues(cue),
        cue: cue,
        sentence: sentence,
        sectionIndex: _lookupSectionIndex,
        sentenceNormCharOffset: _cachedSentenceRange?.offset,
        sentenceNormCharLength: _cachedSentenceRange?.length,
        delayMs: audioController?.delayMs.value ?? 0,
      );
      if (clip.audioFileIndex >= 0 && clip.audioFileIndex < audioFiles.length) {
        final File inputFile = audioFiles[clip.audioFileIndex];
        sasayakiTempDir =
            Directory.systemTemp.createTempSync('hibiki_mine_sentence_audio_');
        final String outputPath = p.join(sasayakiTempDir.path, 'sentence.aac');
        sasayakiAudioPath = await TtsChannel.instance.extractAudioSegment(
          inputPath: inputFile.path,
          startMs: clip.startMs,
          endMs: clip.endMs,
          outputPath: outputPath,
        );
      }
    }

    final String cueSentence =
        appModel.currentMediaSource?.currentCueSentence.text ?? '';

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: cueSentence.isNotEmpty ? cueSentence : null,
      documentTitle: _book?.title,
      coverPath: coverPath,
      sasayakiAudioPath: sasayakiAudioPath,
      sentenceOffset: _cachedSentenceOffset,
    );

    final MineOutcome outcome;
    try {
      outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
    } finally {
      if (sasayakiTempDir != null && sasayakiTempDir.existsSync()) {
        try {
          sasayakiTempDir.deleteSync(recursive: true);
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderHibiki.mineEntry.cleanupAudio', e, stack);
        }
      }
    }

    switch (outcome.result) {
      case MineResult.success:
        // 制卡成功计入书籍统计（reader 走 BaseSourcePageState.onMineFromPopup，
        // 不 mixin DictionaryPageMixin，故直接调 addMiningCount，来源固定 book）。
        // 失败不影响制卡结果，吞掉并记日志。
        unawaited(_recordMined());
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
        HibikiToast.show(msg: logMineFailure(outcome));
        return false;
    }
  }

  /// 把一次成功制卡计入书籍统计。reader 走 [BaseSourcePageState.onMineFromPopup]，
  /// 不 mixin [DictionaryPageMixin]，故自带本记账（来源固定 [kStatSourceBook]，与
  /// mixin 的 `recordMined` 同契约：[HibikiDatabase.addMiningCount]）。失败吞掉并记日志。
  Future<void> _recordMined() async {
    try {
      await appModel.database.addMiningCount(
        sourceType: kStatSourceBook,
        dateKey: statTodayKey(),
      );
    } catch (e, st) {
      debugPrint('[hibiki-stats] reader addMiningCount failed: $e\n$st');
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
    if (_audiobookBookKey == null) return null;

    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    final List<AudioCue> allCues = await repo.cuesForBook(_audiobookBookKey!);
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

    await AudiobookBridge.inject(_controller!,
        primaryColor: _themeSasayakiColor());

    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) return;

    if (_srtBookUid != null) {
      _audiobookController!.setChapterCues(allCues);
      _audiobookController!.setAllBookCues(allCues);
      if (_srtCueChapterMap == null) {
        final (Map<int, int> m, List<(int, int)> r) =
            _buildSrtChapterMap(allCues);
        _srtCueChapterMap = m;
        _srtChapterRanges = r;
      }
    } else if (_audiobookBookKey != null) {
      if (_cachedSasayaki) {
        _audiobookController!.setChapterCues(allCues);
        _audiobookController!.setAllBookCues(allCues);
      } else {
        final String chapterHref = _book!.chapters[_currentChapter].href;
        final AudiobookRepository repo = AudiobookRepository(appModel.database);
        final List<AudioCue> cues = await repo.cuesForChapter(
          bookKey: _audiobookBookKey!,
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

  Future<void> _navigateToChapter(
    int index, {
    double progress = 0.0,
    bool manual = false,
  }) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) {
      return;
    }
    if (_controller == null) {
      return;
    }

    if (manual) {
      _audiobookController?.noteManualReaderNavigation();
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
    // BUG-162: 翻章是去新位置，无该章精确锚 → -1 走分数，别把上次恢复的锚带进来。
    _initialCharOffset = -1;
    _displayedProgress = progress;
    _lastProgressSection = index;
    _lastProgressValue = progress;
    // HBK-AUDIT-037: ordinary navigation does not want a fragment jump. Clear
    // it at the start of every fragment-less navigation so a stale fragment
    // from a prior internal-link nav can never leak into this chapter's setup
    // script (the old post-await reset in _onChapterLoadComplete was skipped on
    // lyrics/spread/early-return/throw paths).
    _initialFragment = null;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._navigateToChapter', e, stack);
      debugPrint('[ReaderHibiki] _navigateToChapter loadUrl failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  Future<bool> _navigateToChapterAndWait(
    int index, {
    bool manual = false,
  }) async {
    await _navigateToChapter(index, manual: manual);
    final bool success = await _restoreCompleter?.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('[ReaderHibiki] _navigateToChapterAndWait timed out');
            _isNavigatingToChapter = false;
            _restoreCompleter = null;
            _restoreInFlight = false;
            return false;
          },
        ) ??
        false;
    return success && _currentChapter == index;
  }

  // BUG-117: shared internal-link handler. Called both from the JS click
  // interceptor (onInternalLink — the primary path, fires on every platform)
  // and from shouldOverrideUrlLoading (fallback for non-click navigations).
  // [url] is the browser-resolved absolute URL of the clicked <a> (or the
  // navigation target). Internal book links jump within the reader; genuine
  // external schemes go to the OS handler; an unresolved hoshi.local link stays
  // put (never pops a blank OS browser — see _openExternalUrl / BUG-097).
  Future<void> _handleInternalLinkUrl(String url) async {
    if (url.isEmpty) return;
    final ({int chapterIndex, String? fragment})? link =
        _book?.resolveInternalLink(url);
    if (link != null) {
      // HBK-AUDIT-038: a same-document anchor (e.g. href="#note1") resolves to
      // the current chapter's path plus a fragment. Jump in place instead of
      // reloading the whole chapter (avoids a visible flash + lost scroll).
      if (link.chapterIndex == _currentChapter && link.fragment != null) {
        await _jumpToFragmentInPlace(link.fragment!);
      } else {
        await _navigateToChapterWithFragment(
          link.chapterIndex,
          link.fragment,
          manual: true,
        );
      }
      return;
    }
    // HBK-AUDIT-038: route genuine external schemes (http/https/mailto/tel on a
    // foreign host) to the OS; _openExternalUrl no-ops for our own virtual host.
    await _openExternalUrl(url);
  }

  Future<void> _navigateToChapterWithFragment(int index, String? fragment,
      {bool manual = false}) async {
    if (_book == null || index < 0 || index >= _book!.chapters.length) return;
    if (_controller == null) return;

    _progressPollTimer?.cancel();
    if (manual) {
      _audiobookController?.noteManualReaderNavigation();
    } else {
      _audiobookController?.cancelChapterTransition();
    }
    _flushReadingStats();

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();

    _currentChapter = index;
    _initialProgress = 0.0;
    _initialCharOffset = -1; // BUG-162: 新章/fragment 跳转走分数/fragment，非 char 锚。
    _displayedProgress = 0.0;
    _lastProgressSection = index;
    _lastProgressValue = 0.0;
    _initialFragment = fragment;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._navigateToChapterWithFragment', e, stack);
      debugPrint(
          '[ReaderHibiki] _navigateToChapterWithFragment loadUrl failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  // HBK-AUDIT-038: scroll to an in-page anchor without reloading the chapter.
  // Used when an internal link resolves to the chapter already on screen.
  Future<void> _jumpToFragmentInPlace(String fragment) async {
    if (_controller == null || !_readerContentReady) return;
    // jsonEncode produces a valid, escaped JS string literal for the fragment.
    final String literal = jsonEncode(fragment);
    try {
      await _controller!.evaluateJavascript(
        source: 'window.hoshiReader && '
            'window.hoshiReader.jumpToFragment($literal);',
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._jumpToFragmentInPlace', e, stack);
      debugPrint('[ReaderHibiki] _jumpToFragmentInPlace failed: $e');
    }
  }

  // HBK-AUDIT-038: open a genuinely external link (http/https/mailto/tel) in the
  // OS handler instead of silently cancelling it. Non-external schemes are
  // ignored so we never hand the OS an internal hoshi.local URL.
  Future<void> _openExternalUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    // BUG-097: an unresolved internal link (host == kHost) must stay in the
    // reader — never pop a blank OS browser for our virtual hoshi.local host.
    if (!ReaderHibikiSource.isExternalUrl(url)) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._openExternalUrl', e, stack);
      debugPrint('[ReaderHibiki] _openExternalUrl failed for $url: $e');
    }
  }

  // ── Spread (two-page) support ──────────────────────────────────────

  Map<int, bool>? _edgeMatchResults;

  void _rebuildSpreadMap() {
    if (_book == null || _settings == null) return;
    _spreadMap = EpubSpreadMap.build(
      book: _book!,
      spreadMode: _settings!.spreadMode,
      spreadDirection: _settings!.spreadDirection,
      edgeMatchResults: _edgeMatchResults,
    );
  }

  Future<void> _initSpreadMap(HibikiDatabase db) async {
    if (_book == null || _settings == null) return;
    final String bookKey = widget.bookKey;
    if (_settings!.spreadMode == 'auto') {
      _edgeMatchResults = await EpubSpreadAnalyzer.loadCached(db, bookKey);
    }
    _rebuildSpreadMap();

    if (_settings!.spreadMode == 'auto' && _edgeMatchResults == null) {
      _runEdgeAnalysis(db, bookKey);
    }
  }

  Future<void> _runEdgeAnalysis(HibikiDatabase db, String bookKey) async {
    if (_book == null) return;
    try {
      final Map<int, bool> results = await EpubSpreadAnalyzer.analyze(_book!);
      await EpubSpreadAnalyzer.saveCache(db, bookKey, results);
      _edgeMatchResults = results;
      _rebuildSpreadMap();
      if (mounted) setState(() {});
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._runEdgeAnalysis', e, stack);
    }
  }

  Future<void> _navigateToVirtualPage(
    int virtualIndex, {
    double progress = 0.0,
  }) async {
    if (_spreadMap == null) return;
    if (virtualIndex < 0 || virtualIndex >= _spreadMap!.length) return;
    final SpreadEntry entry = _spreadMap!.entryAt(virtualIndex);
    if (entry.isSpread) {
      await _navigateToSpread(entry);
    } else {
      await _navigateToChapter(entry.chapterIndex, progress: progress);
    }
  }

  Future<void> _navigateToSpread(SpreadEntry entry) async {
    if (_book == null || _controller == null || !entry.isSpread) return;

    _progressPollTimer?.cancel();
    _flushReadingStats();

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();

    _currentChapter = entry.chapterIndex;
    _initialProgress = 0.0;
    _initialCharOffset = -1; // BUG-162: spread 导航去章首，无 char 锚。
    _displayedProgress = 0.0;
    _lastProgressSection = entry.chapterIndex;
    _lastProgressValue = 0.0;
    // HBK-AUDIT-037: spread navigation does not want a fragment jump; clear any
    // leftover fragment so it cannot leak into the spread setup script.
    _initialFragment = null;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();

    try {
      await _loadSpreadPage(entry);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._navigateToSpread', e, stack);
      debugPrint('[ReaderHibiki] _navigateToSpread failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  Future<void> _loadSpreadPage(SpreadEntry entry) async {
    if (_book == null || !entry.isSpread) return;

    final String? srcA = _book!.chapterImageSrc(entry.chapterIndex);
    final String? srcB = _book!.chapterImageSrc(entry.secondChapterIndex!);
    if (srcA == null || srcB == null) {
      await _loadChapterDirectly(entry.chapterIndex);
      return;
    }

    final String urlA = _resolveSpreadImageUrl(
      _book!.chapters[entry.chapterIndex].href,
      srcA,
    );
    final String urlB = _resolveSpreadImageUrl(
      _book!.chapters[entry.secondChapterIndex!].href,
      srcB,
    );

    final bool rtl = _settings?.spreadDirection != 'ltr';
    final String leftUrl = rtl ? urlB : urlA;
    final String rightUrl = rtl ? urlA : urlB;

    final String html = '''
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:100vw;height:100vh;overflow:hidden;background:#000}
.spread{display:flex;width:100vw;height:100vh}
.spread-half{flex:1;display:flex;justify-content:center;align-items:center;overflow:hidden}
.spread-half img{max-width:100%;max-height:100vh;object-fit:contain;cursor:pointer}
</style>
</head><body>
<div class="spread">
<div class="spread-half"><img src="$leftUrl" class="block-img"/></div>
<div class="spread-half"><img src="$rightUrl" class="block-img"/></div>
</div>
<script>
document.querySelectorAll('img').forEach(function(img){
  img.addEventListener('click',function(){
    window.flutter_inappwebview.callHandler('onImageTap',img.src);
  });
});
window.flutter_inappwebview.callHandler('spreadReady');
</script>
</body></html>
''';

    _isNavigatingToChapter = true;
    try {
      await _controller!.loadData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(
          ReaderHibikiSource.epubUrl(_book!.chapters[entry.chapterIndex].href),
        ),
      );
    } catch (e) {
      _isNavigatingToChapter = false;
      rethrow;
    }
  }

  String _resolveSpreadImageUrl(String chapterHref, String imgSrc) {
    final String chapterDir = p.posix.dirname(chapterHref);
    final String resolved = p.posix.normalize(p.posix.join(chapterDir, imgSrc));
    return ReaderHibikiSource.epubUrl(resolved);
  }

  void _handlePageTurnLimit(String direction) {
    if (_book == null) {
      return;
    }
    _audiobookController?.noteManualReaderNavigation();

    if (_spreadMap != null && _settings?.spreadMode != 'off') {
      final int currentVirtual =
          _spreadMap!.virtualPageForChapter(_currentChapter);
      if (direction == 'forward') {
        if (currentVirtual + 1 < _spreadMap!.length) {
          _navigateToVirtualPage(currentVirtual + 1);
        }
      } else {
        if (currentVirtual > 0) {
          _navigateToVirtualPage(currentVirtual - 1, progress: 0.99);
        }
      }
      return;
    }

    if (direction == 'forward') {
      if (_currentChapter < _book!.chapters.length - 1) {
        _navigateToChapter(_currentChapter + 1, manual: true);
      }
    } else {
      if (_currentChapter > 0) {
        _navigateToChapter(
          _currentChapter - 1,
          progress: 0.99,
          manual: true,
        );
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

  /// Reclaim Flutter keyboard focus for the reading content after a reader
  /// WebView pointer gesture (swipe / wheel page-turn, boundary chapter turn,
  /// tap-to-toggle-chrome). The native WebView grabs the OS focus when the user
  /// touches it, dropping [_focusNode] so ESC / shortcuts no longer reach
  /// [_handleKeyEvent] (BUG-136). Mirrors the popup-dismiss reclaim in
  /// [onAllPopupsDismissed]; the predicate skips it when a popup or the chrome
  /// bar legitimately owns focus, and it is a harmless no-op for keyboard /
  /// gamepad turns (those never route through the JS gesture handlers).
  void _reclaimReaderFocusAfterGesture() {
    if (!mounted) return;
    if (!shouldReclaimReaderFocusAfterGesture(
      popupVisible: isDictionaryShown,
      chromeHasFocus: _chromeFocusScope.hasFocus,
    )) {
      return;
    }
    _focusNode.requestFocus();
  }

  @override
  void onAllPopupsDismissed() {
    if (!mounted) return;
    _clearLookupState();
    // Return Flutter focus to the reading content. The dismissed popup's WebView
    // held the keyboard/gamepad focus, so without this the reader receives no key
    // events after the popup closes and the user is stuck with no way back in.
    _focusNode.requestFocus();
    // If the cursor was living in a popup (controller/keyboard flow), the popup
    // it was in is gone — bring it back to the reader at its remembered word.
    // This covers every dismiss path (B/Esc, tap-outside, swipe).
    if (_caretSurface == CaretSurface.popup) {
      _caretPopupState = null;
      unawaited(_enterCaret());
    }
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

  Future<void> _highlightAndShowPopup(
    int highlightCount,
    Rect fallbackRect,
  ) async {
    Rect finalRect = fallbackRect;
    try {
      if (highlightCount > 0 && _controller != null) {
        final raw = await _controller!.evaluateJavascript(
          source: ReaderSelectionScripts.highlightInvocation(highlightCount),
        );
        if (mounted) {
          final rect = ReaderSelectionScripts.highlightRectFromResult(
            raw,
            topOffset: 0,
          );
          if (rect != null) finalRect = rect;
        }
      }
    } finally {
      showDeferredPopup(selectionRect: finalRect);
    }
  }

  Future<void> _handleTextSelected(ReaderSelectionData data) async {
    if (data.text.isEmpty) {
      return;
    }

    final bool shouldPause = ReaderHibikiSource.instance.pauseOnLookup;
    final AudiobookPlayerController? abc = _audiobookController;
    if (shouldPause && abc != null && abc.isPlaying) {
      abc.pause();
      _pausedForLookup = true;
    }

    final Map<String, double>? rect = data.rect;
    final Rect selectionRect = rect != null
        ? Rect.fromLTWH(
            rect['x'] ?? 0,
            rect['y'] ?? 0,
            rect['width'] ?? 0,
            rect['height'] ?? 0,
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
      selection: HibikiTextSelection(text: data.sentence),
    );
    _cachedSentenceOffset = data.sentenceOffset;

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
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderHibiki.lyricsCueContext', e, stack);
        }
      }
      _lookupCue ??= _audiobookController?.currentCue;
      _syncCueSentence();
      prunePopupStack(0);
      final int highlightCount = await searchDictionaryResult(
        searchTerm: data.text,
        selectionRect: selectionRect,
        deferDisplay: true,
      );
      await _highlightAndShowPopup(highlightCount, selectionRect);
      _checkFavoriteStatus();
      return;
    }

    _lookupCue = data.normalizedOffset != null
        ? _findCueForOffset(data.normalizedOffset!)
        : null;
    if (_lookupCue == null && _srtBookUid != null) {
      _lookupCue = _findCueForSentence(data.sentence);
    }
    _syncCueSentence();

    prunePopupStack(0);
    final int highlightCount = await searchDictionaryResult(
      searchTerm: data.text,
      selectionRect: selectionRect,
      deferDisplay: true,
    );

    await _highlightAndShowPopup(highlightCount, selectionRect);
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
      bookKey: widget.bookKey,
      sectionIndex: _lookupSectionIndex,
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
    if (parts.length < 2) {
      // HBK-AUDIT-119: surface bridge format drift instead of silently no-oping.
      debugPrint('[ReaderHibiki] _refreshProgress unexpected result: "$str"');
      return;
    }
    final int? current = int.tryParse(parts[0]);
    final int? total = int.tryParse(parts[1]);
    // BUG-162: 第三段 = section 内精确字符偏移（hoshiProgressDetails 追加）。旧格式
    // （两段）或解析失败按 -1（无精确锚）处理。
    final int charOffset =
        parts.length >= 3 ? (int.tryParse(parts[2]) ?? -1) : -1;
    if (current == null || total == null || total <= 0) {
      // HBK-AUDIT-119: unparseable / non-positive total — log so drift is visible.
      debugPrint('[ReaderHibiki] _refreshProgress unparseable result: "$str"');
      return;
    }

    final double progress = current / total;
    _displayedProgress = progress;
    _lastProgressSection = _currentChapter;
    _lastProgressValue = progress;
    _lastProgressCharOffset = charOffset;
    final int absoluteChars = _absoluteCharPosition(progress);
    final int charDiff = absoluteChars - _lastAbsoluteCount;
    if (charDiff > 0) {
      _sessionCharsRead += charDiff;
    }
    _lastAbsoluteCount = absoluteChars;
    _debouncedSavePosition(progress, charOffset);

    if (mounted) {
      final int newTotal = _chapterCumulativeChars.isNotEmpty
          ? _chapterCumulativeChars.last + _chapterCharCounts.last
          : total;
      if (_progressCurrentChars != absoluteChars ||
          _progressTotalChars != newTotal) {
        setState(() {
          _progressCurrentChars = absoluteChars;
          _progressTotalChars = newTotal;
        });
      }
    }
  }

  Future<void> _syncPositionFromWebViewProgress() async {
    if (_controller == null ||
        _lyricsMode ||
        !_readerContentReady ||
        _restoreInFlight) {
      return;
    }

    final dynamic result;
    try {
      result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderHibiki.syncPositionFromWebViewProgress.eval',
        e,
        stack,
      );
      debugPrint('[ReaderHibiki] syncPositionFromWebViewProgress failed: $e');
      return;
    }
    if (!mounted) return;

    final String str = result.toString().replaceAll('"', '').trim();
    if (str.isEmpty) return;

    final List<String> parts = str.split(',');
    if (parts.length < 2) {
      debugPrint(
        '[ReaderHibiki] syncPositionFromWebViewProgress unexpected result: '
        '"$str"',
      );
      return;
    }
    final int? current = int.tryParse(parts[0]);
    final int? total = int.tryParse(parts[1]);
    final int charOffset =
        parts.length >= 3 ? (int.tryParse(parts[2]) ?? -1) : -1;
    if (current == null || total == null || total <= 0) {
      debugPrint(
        '[ReaderHibiki] syncPositionFromWebViewProgress unparseable result: '
        '"$str"',
      );
      return;
    }

    final double clamped = (current / total).clamp(0.0, 1.0).toDouble();
    _displayedProgress = clamped;
    _lastProgressSection = _currentChapter;
    _lastProgressValue = clamped;
    _lastProgressCharOffset = charOffset;
  }

  void _debouncedSavePosition(double progress, int charOffset) {
    _debouncedSaveReaderPosition(_currentChapter, progress, charOffset);
  }

  void _debouncedSaveReaderPosition(
      int section, double progress, int charOffset) {
    if (_restoreInFlight) {
      return;
    }
    if (section == _lastSavedSection &&
        (progress - _lastSavedProgress).abs() < 0.001) {
      return;
    }

    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistPosition(section, progress, charOffset);
    });
  }

  Future<void> _persistPosition(
      int section, double progress, int charOffset) async {
    _lastSavedSection = section;
    _lastSavedProgress = progress;

    final int normOffset = (progress * 10000).round();
    debugPrint('[ReaderHibiki] save position: bookKey=${widget.bookKey} '
        'section=$section normOffset=$normOffset charOffset=$charOffset');
    final ReaderPositionRepository repo =
        ReaderPositionRepository(appModel.database);
    await repo.save(
      bookKey: widget.bookKey,
      sectionIndex: section,
      normCharOffset: normOffset,
      // BUG-162: >=0 写精确锚（char_offset 列），<0 传 null → 同 section 保留既有锚、
      // 跨 section 失效（repo.save 逻辑）。不动 sync 的 ttu_char_offset 列。
      charOffset: charOffset >= 0 ? charOffset : null,
    );
  }

  void _syncPositionFromCurrentCue() {
    final AudioCue? cue = _audiobookController?.currentCue;
    if (cue == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag != null) {
      _lastProgressSection = frag.sectionIndex;
      if (frag.sectionIndex >= 0 &&
          frag.sectionIndex < _chapterCharCounts.length &&
          _chapterCharCounts[frag.sectionIndex] > 0) {
        _lastProgressValue =
            frag.normCharStart / _chapterCharCounts[frag.sectionIndex];
        _lastProgressValue = _lastProgressValue.clamp(0.0, 1.0);
        // BUG-162: cue 派生位置无 WebView 精确偏移 → -1（恢复走 cue 的 normChar 分数），
        // 并清陈旧锚，避免后续 flush 把别 section 的偏移误写进来。
        _lastProgressCharOffset = -1;
        _debouncedSaveReaderPosition(
            _lastProgressSection, _lastProgressValue, -1);
      }
      return;
    }
    if (_srtCueChapterMap != null && _srtChapterRanges != null) {
      final int? chapter = _srtCueChapterMap![cue.sentenceIndex];
      if (chapter != null &&
          chapter >= 0 &&
          chapter < _srtChapterRanges!.length) {
        _lastProgressSection = chapter;
        final (int first, int last) = _srtChapterRanges![chapter];
        final int span = last - first;
        _lastProgressValue = span > 0
            ? ((cue.sentenceIndex - first) / span).clamp(0.0, 1.0)
            : 0.0;
        _lastProgressCharOffset = -1;
        _debouncedSaveReaderPosition(
            _lastProgressSection, _lastProgressValue, -1);
      }
    }
  }

  // HBK-AUDIT-122: in lyrics mode the persisted position must be derived from
  // the current audio cue before flushing, otherwise a stale reader-scroll
  // position is saved. dispose did this but didChangeAppLifecycleState did not,
  // so backgrounding while in lyrics mode lost playback progress. Both paths
  // now share this helper.
  //
  // BUG-032: backgrounding must ALSO durably flush the audiobook playback
  // position. dispose() force-saves it via the controller, but on a hard
  // process kill dispose never runs; the periodic save is fire-and-forget (may
  // not commit before the OS reclaims the process) and stops once background
  // Dart timers suspend. In lyrics mode the audio position is the only visible
  // progress (entry cue = allBookCueIdx), so losing it reads as "归零". Await
  // the controller flush inside the still-alive onPause window so the position
  // at background time is written through — mirroring the reader-pos flush.
  Future<void> _syncAndFlushPosition() async {
    if (_lyricsMode) {
      _syncPositionFromCurrentCue();
    } else {
      await _syncPositionFromWebViewProgress();
    }
    await _flushPosition();
    await _audiobookController?.flushPosition();
  }

  Future<void> _flushPosition() async {
    _saveDebounce?.cancel();
    if (!_hasEverLoaded || _lastProgressSection < 0) {
      return;
    }
    await _persistPosition(
        _lastProgressSection, _lastProgressValue, _lastProgressCharOffset);
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
      _navigateToChapter(
        targetChapter,
        progress: progress.clamp(0.0, 1.0),
        manual: true,
      );
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
      debugPrint('[ReaderHibiki] stats flush error: $e');
    });
    _sessionCharsRead = 0;
    _sessionStartTime = DateTime.now();
  }

  // ── Key Navigation ────────────────────────────────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // The popup header toolbar (sibling of the popup content). Down returns to
    // the content caret; B/Escape dismiss the popup (ascend out of it). Left/
    // Right/Enter fall through to the framework so the buttons traverse and
    // activate natively (the global HibikiFocusRing rings the focused one).
    if (_popupHeaderScope.hasFocus) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _returnToPopupContent();
        return KeyEventResult.handled;
      }
      // The header is the TOP of the popup — nothing is above it. Consume Up so
      // focus stays on the header instead of the directional fallback wrapping
      // to another button (or, in any scope edge case, escaping and stranding
      // the hidden caret). Mirrors the bottom bar handling its Up explicitly.
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.gameButtonB ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        unawaited(_caretDismissOrExit()); // popup surface → dismissTopPopup()
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // While a bottom-chrome control holds focus, let directional traversal and
    // Activate flow through to the framework (gamepad/keyboard operation of the
    // chrome buttons) instead of resolving reader page-turn shortcuts. B/Escape
    // closes the chrome and returns focus to the reading content rather than
    // bubbling up to the global pop (which would exit the reader).
    if (_chromeFocusScope.hasFocus) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      // The bar and the reading content are the same (top) layer. Up moves focus
      // back to the reading content; B/Escape exit the reader (top-level back).
      // The bar's visibility is controlled only by Y, so B must not hide it.
      // (Both chrome bars are single rows, so intercepting Up never strands
      // intra-bar vertical traversal.)
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _focusNode.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.gameButtonB ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        unawaited(Navigator.of(context).maybePop());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final KeyEventResult? gamepadAResult =
        _focusNavEnabled ? _handleGamepadAKeyEvent(event) : null;
    if (gamepadAResult != null) return gamepadAResult;

    // Holding an arrow (or Tab) while the char cursor is active steps the cursor
    // continuously: the OS auto-repeat (KeyRepeatEvent) drives the SAME caret
    // MOVE action as the press edge does below, so the cursor advances per
    // repeat instead of one char per discrete press. Consuming it here also
    // stops the repeat from bubbling to the app-wide wrapper, which would
    // otherwise move FOCUS off the reading content ([_focusNode]) instead of
    // moving the cursor. ONLY movement actions repeat — activate (Enter/A look-
    // up) and dismissOrExit (Esc/B) must fire once per press, never on auto-
    // repeat, or a held Enter/Esc would re-look-up / re-exit every frame.
    if (_focusNavEnabled && _caretActive && event is KeyRepeatEvent) {
      final CaretAction? repeatCaret = ReaderCaretRouter.decideKeyboard(
        event.logicalKey,
        shift: HardwareKeyboard.instance.isShiftPressed,
      );
      if (repeatCaret != null && _isRepeatableCaretMove(repeatCaret)) {
        unawaited(_runCaretAction(repeatCaret));
        return KeyEventResult.handled;
      }
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Char-level reading cursor (book has focus; chrome already returned above).
    // While active, the cursor owns Tab / arrows / A(Enter) / B(Esc) before the
    // registry is consulted. While inactive, A / Enter ENTER the cursor.
    if (_focusNavEnabled && _caretActive) {
      // LB/RB flip a whole page on the cursor surface, mirroring the polled
      // gamepad branch in _handleGamepadButton. Android gamepads deliver the
      // shoulders here as gameButton key events, mapped back via fromLogicalKey;
      // these logical keys are gamepad-only, so a desktop keyboard never hits it.
      final GamepadButton? shoulder =
          GamepadButton.fromLogicalKey(event.logicalKey);
      if (shoulder == GamepadButton.rb) {
        unawaited(_caretScrollPage(true));
        return KeyEventResult.handled;
      }
      if (shoulder == GamepadButton.lb) {
        unawaited(_caretScrollPage(false));
        return KeyEventResult.handled;
      }
      final CaretAction? caretAction = ReaderCaretRouter.decideKeyboard(
        event.logicalKey,
        shift: HardwareKeyboard.instance.isShiftPressed,
      );
      if (caretAction != null) {
        unawaited(_runCaretAction(caretAction));
        return KeyEventResult.handled;
      }
    } else if (ReaderCaretRouter.isEnterTriggerKeyboard(
      event.logicalKey,
      focusNavEnabled: _focusNavEnabled,
    )) {
      unawaited(_enterCaret());
      return KeyEventResult.handled;
    }

    // Caret inactive: arrow Down drops focus into the bottom bar (the sibling
    // layer below the reading content), mirroring the gamepad polled path
    // (_handleGamepadButton). Without this the keyboard path had no chrome
    // route, so Down resolved to a reader page-turn shortcut and could never
    // reach the bar (BUG-020). Gated on a visible bar that accepts focus.
    if (_focusNavEnabled &&
        !_caretActive &&
        event.logicalKey == LogicalKeyboardKey.arrowDown &&
        _showChrome) {
      _chromeFocusScope.requestFocus();
      if (_chromeFocusScope.context != null && _chromeFocusScope.nextFocus()) {
        return KeyEventResult.handled;
      }
      // Empty chrome (no focusable child): undo the scope grab so focus isn't
      // stranded on an empty FocusScope, then fall through to shortcut
      // resolution. Mirrors _promoteCaretToChrome's undo.
      _focusNode.requestFocus();
    }

    final modifiers = <ModifierKey>{};
    if (HardwareKeyboard.instance.isControlPressed) {
      modifiers.add(ModifierKey.ctrl);
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      modifiers.add(ModifierKey.shift);
    }
    if (HardwareKeyboard.instance.isAltPressed) {
      modifiers.add(ModifierKey.alt);
    }
    if (HardwareKeyboard.instance.isMetaPressed) {
      modifiers.add(ModifierKey.meta);
    }

    // 有声书激活时，无修饰 Space 改作播放/暂停（媒体播放器惯例），先于
    // reader scope 的「翻页」解析，否则 Space 永远被 reader scope 抢成翻页
    // （翻页仍可用方向键/PageDown；Shift+Space 后退翻页、Ctrl+Space 原义不变）。
    final ShortcutAction? spaceOverride = resolveReaderSpaceOverride(
      key: event.logicalKey,
      modifiers: modifiers,
      hasActiveAudiobook: _audiobookController != null &&
          _audiobookController!.chapterCueCount > 0,
    );
    // BUG-099: bare Left/Right page-turn follows the reading direction (RTL book
    // advances on Left). Resolved before the registry, which binds Right=forward
    // unconditionally; null for any other key leaves default resolution intact.
    final ShortcutAction? arrowOverride = resolveReaderArrowPageTurn(
      key: event.logicalKey,
      modifiers: modifiers,
      rtl: _isRtlReading,
    );
    ShortcutAction? action = spaceOverride ??
        arrowOverride ??
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.reader,
        ) ??
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.audiobook,
        );

    if (action == null) {
      final gamepad = GamepadButton.fromLogicalKey(event.logicalKey);
      if (gamepad != null) {
        action = appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.reader,
            ) ??
            appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.audiobook,
            );
      }
    }

    if (action == null) return KeyEventResult.ignored;
    return _executeShortcutAction(action);
  }

  KeyEventResult? _handleGamepadAKeyEvent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.gameButtonA) return null;
    if (event is KeyDownEvent) {
      if (_gamepadAHoldTimer != null) return KeyEventResult.handled;
      _gamepadALongFired = false;
      _gamepadAHoldTimer = Timer(const Duration(milliseconds: 500), () {
        _gamepadAHoldTimer = null;
        _gamepadALongFired = true;
        if (!mounted || !_focusNavEnabled || !_caretActive) return;
        unawaited(_runCaretAction(CaretAction.longPress));
      });
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      final bool longFired = _gamepadALongFired;
      _clearGamepadAHold();
      if (longFired) return KeyEventResult.handled;
      if (_caretActive) {
        unawaited(_runCaretAction(CaretAction.activate));
      } else {
        unawaited(_enterCaret());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  void _clearGamepadAHold() {
    _gamepadAHoldTimer?.cancel();
    _gamepadAHoldTimer = null;
    _gamepadALongFired = false;
  }

  /// Handles a gamepad button delivered via [GamepadButtonIntent] (desktop
  /// polled path). Mirrors the gamepad branch of [_handleKeyEvent] so polled
  /// input behaves identically to Android's native gameButton key events.
  /// Returns true when consumed; false lets the GamepadService apply its
  /// directional-focus / activate / global-back fallback.
  bool _handleGamepadButton(GamepadButton button) {
    // Popup header toolbar (sibling of the popup content). Down → content caret;
    // B → dismiss the popup. Left/Right/A fall through (return false) so the
    // GamepadService traverses the buttons and activates the focused one.
    if (_popupHeaderScope.hasFocus) {
      if (button == GamepadButton.dpadDown) {
        _returnToPopupContent();
        return true;
      }
      // Header is the top of the popup — consume Up so focus stays here (don't
      // let the directional fallback in gamepadMoveFocusInDirection wrap to
      // another button or escape the scope and strand the hidden caret).
      if (button == GamepadButton.dpadUp) {
        return true;
      }
      if (button == GamepadButton.b) {
        unawaited(_caretDismissOrExit());
        return true;
      }
      return false;
    }
    if (_chromeFocusScope.hasFocus) {
      // D-pad Up moves focus back to the reading content (sibling layer above).
      if (button == GamepadButton.dpadUp) {
        _focusNode.requestFocus();
        return true;
      }
      // B exits the reader (top-level back); the bar's visibility is Y-only, so
      // B must not hide it. Left/Right traverse the bar's buttons.
      if (button == GamepadButton.b) {
        unawaited(Navigator.of(context).maybePop());
        return true;
      }
      return false;
    }
    // Char-level reading cursor — same contextual routing as the keyboard path.
    if (_focusNavEnabled && _caretActive) {
      // LB/RB flip a whole page on the cursor surface (popup scrolls, paged
      // reader turns) before the directional caret map — the shoulders are not
      // caret-directional, so they would otherwise fall through to the reader
      // scope and never reach the popup WebView.
      if (button == GamepadButton.rb) {
        unawaited(_caretScrollPage(true));
        return true;
      }
      if (button == GamepadButton.lb) {
        unawaited(_caretScrollPage(false));
        return true;
      }
      final CaretAction? caretAction = ReaderCaretRouter.decideGamepad(button);
      if (caretAction != null) {
        unawaited(_runCaretAction(caretAction));
        return true;
      }
    } else if (ReaderCaretRouter.isEnterTriggerGamepad(
      button,
      focusNavEnabled: _focusNavEnabled,
    )) {
      unawaited(_enterCaret());
      return true;
    }
    // Top level (cursor inactive): D-pad Down moves focus into the bottom bar
    // (the sibling layer below the reading content). The bar must be visible
    // (its visibility is Y-controlled). D-pad Up/Down are free on the gamepad —
    // page-turn is on RB/LB + D-pad Left/Right — so this never shadows paging.
    if (_focusNavEnabled && button == GamepadButton.dpadDown && _showChrome) {
      _chromeFocusScope.requestFocus();
      // Only consume Down if focus actually advanced into a bar control. If the
      // bar has no focusable child (nextFocus() == false), fall through so the
      // GamepadService directional-focus fallback runs instead of stranding the
      // press on the (focus-less) reading content.
      // FocusNode.nextFocus() dereferences `context!`; guard against an
      // unattached scope (chrome not yet built, e.g. content not ready) so it
      // can never throw "Null check operator used on a null value".
      if (_chromeFocusScope.context != null && _chromeFocusScope.nextFocus()) {
        return true;
      }
    }
    final ShortcutAction? action = appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.reader,
        ) ??
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.audiobook,
        );
    if (action == null) return false;
    return _executeShortcutAction(action) == KeyEventResult.handled;
  }

  bool _handleGamepadLongPress(GamepadButton button) {
    if (!_focusNavEnabled || button != GamepadButton.a || !_caretActive) {
      return false;
    }
    unawaited(_runCaretAction(CaretAction.longPress));
    return true;
  }

  /// 正文（Sasayaki 原生 EPUB / 合成书）中键点击 → 经 JS `cueIdAtPoint` 反查所在
  /// cue → 跳到该句并播放。点空白/无命中静默忽略。
  Future<void> _seekToClickedSentence(double x, double y) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final Object? raw = await _controller?.evaluateJavascript(
      source: 'window.hoshiReader && window.hoshiReader.cueIdAtPoint'
          ' ? window.hoshiReader.cueIdAtPoint($x, $y) : null',
    );
    // await 期间用户可能退出有声书（_audiobookController 被置空并 dispose）。
    // 用快照同一性校验，避免对已 dispose 的旧 controller 调 playCueAndContinue。
    if (!mounted || !identical(_audiobookController, controller)) return;
    if (raw is! String) return;
    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) return;
    final AudioCue? cue = cueForPointerPayload(raw, allCues);
    if (cue != null) controller.playCueAndContinue(cue);
  }

  KeyEventResult _executeShortcutAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.readerPageForward:
        _paginate(ReaderNavigationDirection.forward);
        return KeyEventResult.handled;
      case ShortcutAction.readerPageBackward:
        _paginate(ReaderNavigationDirection.backward);
        return KeyEventResult.handled;
      case ShortcutAction.readerDismissDict:
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        // No dictionary popup: this is the reader's "back" key (keyboard Esc /
        // gamepad B). Leave the book — never toggle the bottom bar. Bar
        // visibility is owned by M / Y / tap. Mirrors the chrome-scope and
        // popup-scope B/Esc branches that already maybePop().
        unawaited(Navigator.of(context).maybePop());
        return KeyEventResult.handled;
      case ShortcutAction.readerToggleChrome:
        if (isDictionaryShown) {
          clearDictionaryResult();
          return KeyEventResult.handled;
        }
        _toggleChrome(moveFocusToChrome: true);
        return KeyEventResult.handled;
      case ShortcutAction.readerToggleBookmark:
        _addBookmarkAtCurrentPosition();
        return KeyEventResult.handled;
      case ShortcutAction.readerToggleFurigana:
        // Mirror the double-tap furigana toggle so a gamepad (R3) can show/hide
        // furigana without a pointer double-tap the WebView can't synthesise.
        _controller?.evaluateJavascript(
          source: "document.body.classList.toggle('show-all-rt');",
        );
        return KeyEventResult.handled;
      case ShortcutAction.audiobookPlayPause:
        _audiobookController?.togglePlayPause();
        return KeyEventResult.handled;
      case ShortcutAction.audiobookNextSentence:
        _audiobookController?.skipToNextCue();
        return KeyEventResult.handled;
      case ShortcutAction.audiobookPrevSentence:
        _audiobookController?.skipToPrevCue();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  // ── Char-level reading cursor ─────────────────────────────────────

  /// rgba() for the cursor focus ring — the reader accent (theme primary, or the
  /// highlight yellow on dark backgrounds where primary lacks contrast).
  String _caretRingColorCss() {
    final Color accent = _isReaderThemeDark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
    return 'rgba(${(accent.r * 255).round()},${(accent.g * 255).round()},'
        '${(accent.b * 255).round()},0.98)';
  }

  /// Enter the cursor on the READER content (A/Enter in the book with no cursor,
  /// or returning from a dismissed popup). The reader's own hoshiCaret restores
  /// its remembered position, so this re-shows the ring where the user left it.
  Future<void> _enterCaret() async {
    if (_controller == null || !_readerContentReady || _caretBusy) return;
    _caretBusy = true;
    try {
      final Object? raw = await _controller!.evaluateJavascript(
          source: _lyricsMode
              ? ReaderLyricsCaretScripts.enterInvocation()
              : ReaderCaretScripts.enterInvocation());
      if (!mounted) return;
      // enter() returns {ok:false} on an empty page (no visible character).
      if (ReaderCaretScripts.moveStatus(raw) != 'moved') return;
      if (_lyricsMode) {
        // 激活后暂停播放跟随滚动：setCue 只换高亮，不抢滚动。
        await _controller!
            .evaluateJavascript(source: 'window.__lyricsCaretActive = true;');
        setState(() => _caretSurface = CaretSurface.lyrics);
      } else {
        setState(() => _caretSurface = CaretSurface.reader);
      }
    } finally {
      _caretBusy = false;
    }
  }

  /// Fully leave cursor mode — hide the ring on whichever surface holds it.
  void _exitCaret() {
    switch (_caretSurface) {
      case CaretSurface.none:
        return;
      case CaretSurface.reader:
        _controller?.evaluateJavascript(
            source: ReaderCaretScripts.exitInvocation());
        break;
      case CaretSurface.lyrics:
        _controller?.evaluateJavascript(
            source: ReaderLyricsCaretScripts.exitInvocation());
        // 退出焦点：恢复播放跟随并立即把当前播放行重新居中。
        _controller?.evaluateJavascript(
            source: 'window.__lyricsCaretActive = false;'
                'if(window.__lyricsScrollToCue&&window.__lyricsGetCurrentIndex)'
                'window.__lyricsScrollToCue(window.__lyricsGetCurrentIndex());');
        break;
      case CaretSurface.popup:
        topPopupState?.caretExit();
        break;
    }
    setState(() {
      _caretSurface = CaretSurface.none;
      _caretPopupState = null;
    });
  }

  /// Whether [action] is a cursor MOVEMENT that may fire on keyboard auto-repeat
  /// (holding the key steps the cursor continuously). Activation / dismissal /
  /// lookup must stay one-per-press, so only the directional + step actions
  /// repeat.
  static bool _isRepeatableCaretMove(CaretAction action) {
    switch (action) {
      case CaretAction.stepForward:
      case CaretAction.stepBackward:
      case CaretAction.moveUp:
      case CaretAction.moveDown:
      case CaretAction.moveLeft:
      case CaretAction.moveRight:
        return true;
      case CaretAction.activate:
      case CaretAction.lookup:
      case CaretAction.longPress:
      case CaretAction.dismissOrExit:
        return false;
    }
  }

  Future<void> _runCaretAction(CaretAction action) async {
    // Leaving is always allowed, even mid-operation — it must never be dropped
    // by the in-flight guard, or the user could get stuck unable to back out.
    if (action == CaretAction.dismissOrExit) {
      await _caretDismissOrExit();
      return;
    }
    if (_caretBusy) return;
    _caretBusy = true;
    try {
      switch (action) {
        case CaretAction.stepForward:
          await _caretMove('forward');
          break;
        case CaretAction.stepBackward:
          await _caretMove('backward');
          break;
        case CaretAction.moveUp:
          await _caretMove('up');
          break;
        case CaretAction.moveDown:
          await _caretMove('down');
          break;
        case CaretAction.moveLeft:
          await _caretMove('left');
          break;
        case CaretAction.moveRight:
          await _caretMove('right');
          break;
        case CaretAction.activate:
          await _caretActivate();
          break;
        case CaretAction.lookup:
          await _caretLookup();
          break;
        case CaretAction.longPress:
          await _caretLongPress();
          break;
        case CaretAction.dismissOrExit:
          break; // handled above
      }
    } finally {
      _caretBusy = false;
    }
  }

  /// B/Esc while the cursor is active. On the popup it walks one layer back; the
  /// cursor then follows to the parent popup ([onDictionaryStackChanged]) or back
  /// to the reader ([onAllPopupsDismissed]) — the same hooks that fire on a swipe
  /// dismissal, so every back path is handled in one place. On the reader it
  /// dismisses a touch-opened popup or, with none, leaves cursor mode.
  Future<void> _caretDismissOrExit() async {
    if (_caretSurface == CaretSurface.popup) {
      dismissTopPopup();
      return;
    }
    if (isDictionaryShown) {
      clearDictionaryResult();
    } else {
      _exitCaret();
    }
  }

  /// Move focus from the popup content caret UP to the Flutter header toolbar
  /// (sibling layer). Called when the caret is at the top of the popup content
  /// and Up is pressed. Hides the popup caret ring so the header's standard
  /// HibikiFocusRing is the single indicator. No-op (focus stays on content) if
  /// the header has no focusable button.
  void _focusPopupHeader() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    // The header toolbar exists only on the bottom popup (index 0, see
    // base_source_page._buildPopupLayer). When the caret is on a deeper
    // sub-lookup popup there is no header for it — don't grab the (occluded)
    // bottom popup's toolbar; Up at the top simply blocks.
    if (topVisiblePopupIndex != 0) return;
    _popupHeaderScope.requestFocus();
    if (_popupHeaderScope.nextFocus()) {
      topPopupState
          ?.caretExit(); // header owns focus → hide the popup caret ring
    } else {
      _focusNode.requestFocus(); // nothing focusable in the header — undo
    }
  }

  /// Move focus from the header toolbar back DOWN to the popup content caret
  /// (sibling layer). Re-shows the popup caret ring at its remembered position.
  void _returnToPopupContent() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    _focusNode.requestFocus(); // take Flutter focus off the header buttons
    unawaited(
        topPopupState?.caretEnter()); // re-show + re-place the popup caret
  }

  /// A deeper popup layer was dismissed (B/Esc or swipe) but a parent popup
  /// remains: keep the cursor on the popup surface, follow it to the new top, and
  /// re-measure its ring.
  @override
  void onDictionaryStackChanged() {
    if (!mounted || _caretSurface != CaretSurface.popup) return;
    final DictionaryPopupWebViewState? newTop = topPopupState;
    if (newTop == null) return;
    if (!identical(newTop, _caretPopupState)) {
      setState(() => _caretPopupState = newTop);
      unawaited(newTop.caretRefresh());
    }
  }

  /// Drive one cursor move on the active surface. On the reader, a paged
  /// page-edge ('pageForward'/'pageBackward') asks Dart to turn the page (which
  /// re-anchors the cursor). The popup has no hoshiReader, so its cursor scrolls
  /// internally and only ever returns 'moved'/'blocked'.
  Future<void> _caretMove(String physicalDir) async {
    if (_caretSurface == CaretSurface.popup) {
      final String status =
          await topPopupState?.caretMove(physicalDir) ?? 'blocked';
      if (!mounted) return;
      // At the top edge of the popup content, an upward move is blocked. Treat
      // that as crossing into the sibling header layer (like reader content →
      // bottom bar, but upward). Only 'up' promotes; left/right/down that block
      // simply stay put.
      if (status == 'blocked' && physicalDir == 'up') {
        _focusPopupHeader();
      }
      return;
    }
    if (_controller == null) return;
    final Object? raw = await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.moveInvocation(physicalDir)
            : ReaderCaretScripts.moveInvocation(physicalDir));
    if (!mounted || _controller == null) return;
    // lyrics caret 只返回 moved/blocked，永不 pageForward/Backward，故下面分支天然跳过。
    final String status = ReaderCaretScripts.moveStatus(raw);
    switch (readerCaretMoveOutcome(physicalDir, status)) {
      case ReaderCaretMoveOutcome.promoteChrome:
        // Down at the bottom edge: hand focus to the bottom bar instead of
        // turning the page (BUG-020). Mirrors the popup top-edge Up→header.
        _promoteCaretToChrome();
        break;
      case ReaderCaretMoveOutcome.paginateForward:
        await _paginate(ReaderNavigationDirection.forward);
        break;
      case ReaderCaretMoveOutcome.paginateBackward:
        await _paginate(ReaderNavigationDirection.backward);
        break;
      case ReaderCaretMoveOutcome.none:
        break;
    }
  }

  /// Move focus from the active reader caret DOWN into the bottom chrome bar
  /// (the sibling layer below the reading content). Spatially the same idea as
  /// [_focusPopupHeader] (popup content Up → header), but ONE-WAY: this fully
  /// exits the caret ([_exitCaret]) rather than just hiding the ring, so the
  /// later Up from the bar returns to plain reading focus ([_focusNode]), not a
  /// re-entered caret — unlike the reversible popup content↔header round-trip.
  /// Only promotes if the bar is visible and actually accepts focus; otherwise
  /// the caret stays put (no stranded focus, no page turn).
  void _promoteCaretToChrome() {
    if (!_showChrome) return; // bar hidden — nowhere to go; Down stays a no-op
    _chromeFocusScope.requestFocus();
    if (_chromeFocusScope.context != null && _chromeFocusScope.nextFocus()) {
      _exitCaret(); // hide the reader caret ring; the bar's ring takes over
    } else {
      _focusNode.requestFocus(); // bar had no focusable child — undo
    }
  }

  /// LB/RB whole-page flip on the active cursor surface. On the popup it scrolls
  /// the content one page and the ring follows; on the paged reader a returned
  /// 'pageForward'/'pageBackward' turns the page (re-anchoring the cursor), the
  /// same edge handling as a line move in [_caretMove]. Shares the [_caretBusy]
  /// guard so a mashed shoulder cannot race an in-flight move.
  Future<void> _caretScrollPage(bool forward) async {
    if (_caretBusy) return;
    _caretBusy = true;
    try {
      if (_caretSurface == CaretSurface.popup) {
        await topPopupState?.caretScrollPage(forward);
        return;
      }
      if (_controller == null) return;
      final Object? raw = await _controller!.evaluateJavascript(
          source: _caretOnLyrics
              ? ReaderLyricsCaretScripts.scrollPageInvocation(forward)
              : ReaderCaretScripts.scrollPageInvocation(forward));
      if (!mounted || _controller == null) return;
      final String status = ReaderCaretScripts.moveStatus(raw);
      if (status == 'pageForward') {
        await _paginate(ReaderNavigationDirection.forward);
      } else if (status == 'pageBackward') {
        await _paginate(ReaderNavigationDirection.backward);
      }
    } finally {
      _caretBusy = false;
    }
  }

  /// Look up the word at the cursor. On the reader it fires onTextSelected → a
  /// popup; on the popup it fires the popup's textSelected → a deeper popup.
  /// Either way the new popup's onRendered hands the cursor to it.
  Future<void> _caretLookup() async {
    if (_caretSurface == CaretSurface.popup) {
      await topPopupState?.caretLookup();
      return;
    }
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.lookupInvocation()
            : ReaderCaretScripts.lookupInvocation());
  }

  /// A / Enter "context click" at the cursor: follow a hyperlink, click an
  /// interactive control, or look up plain text — [ReaderCaretScripts.activate]
  /// decides. A followed link navigates the WebView (→ shouldOverrideUrlLoading);
  /// a lookup fires the existing onTextSelected pipeline. Fire-and-forget either
  /// way, like [_caretLookup].
  Future<void> _caretActivate() async {
    if (_caretSurface == CaretSurface.popup) {
      await topPopupState?.caretActivate();
      return;
    }
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.activateInvocation()
            : ReaderCaretScripts.activateInvocation());
  }

  Future<void> _caretLongPress() async {
    if (_caretSurface == CaretSurface.popup) {
      await topPopupState?.caretLongPress();
      return;
    }
    if (_controller == null) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.longPressInvocation()
            : ReaderCaretScripts.longPressInvocation());
  }

  /// Place the reader cursor at the entering edge of the freshly paginated page.
  /// Reader-only — the popup never paginates.
  Future<void> _caretReanchor(ReaderNavigationDirection direction) async {
    if (!_caretOnReader || _controller == null) return;
    final String edge =
        direction == ReaderNavigationDirection.forward ? 'forward' : 'backward';
    await _controller!.evaluateJavascript(
        source: ReaderCaretScripts.reanchorInvocation(edge));
  }

  /// Re-measure the reader ring after a relayout (chrome toggle, font/size). If
  /// the cursor's node detached, JS re-anchors to the first visible character.
  /// Reader-only.
  Future<void> _caretRefresh() async {
    if (_controller == null || (!_caretOnReader && !_caretOnLyrics)) return;
    await _controller!.evaluateJavascript(
        source: _caretOnLyrics
            ? ReaderLyricsCaretScripts.refreshInvocation()
            : ReaderCaretScripts.refreshInvocation());
  }

  /// Hand the char-level cursor to the freshly rendered top popup when in cursor
  /// mode. Pure-touch users (surface == none) are unaffected.
  @override
  void onDictionaryPopupRendered(int index) {
    if (_caretSurface == CaretSurface.none) return;
    if (index != topVisiblePopupIndex) return;
    final state = topPopupState;
    if (state == null) return;
    if (_caretSurface == CaretSurface.popup &&
        identical(state, _caretPopupState)) {
      // Same popup re-rendered (e.g. load-more) — just re-measure its ring.
      unawaited(state.caretRefresh());
      return;
    }
    unawaited(_transferCaretToTopPopup(state));
  }

  Future<void> _transferCaretToTopPopup(
      DictionaryPopupWebViewState state) async {
    await state.caretInit();
    String status = await state.caretEnter();
    if (!mounted || topPopupState != state) return;
    if (status != 'moved') {
      // The popup may not have laid out its definition body yet (the cursor only
      // stops inside .glossary-content). Give it a frame and retry once.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || topPopupState != state) return;
      status = await state.caretEnter();
      if (!mounted) return;
    }
    if (status != 'moved') {
      debugPrint('[ReaderHibiki] caret transfer to popup failed: $status');
      return; // leave the cursor on its current surface (ring still shown)
    }
    // Success: hide the reader ring when leaving the reader (it's the large
    // background). A parent popup's ring is occluded by the new top, so leave it
    // for the return trip (it re-shows when the top is dismissed).
    if (_caretSurface == CaretSurface.reader) {
      _controller?.evaluateJavascript(
          source: ReaderCaretScripts.exitInvocation());
    }
    setState(() {
      _caretSurface = CaretSurface.popup;
      _caretPopupState = state;
    });
  }

  // ── Shift+Hover over dismiss barrier ──────────────────────────────

  double _barrierHoverLastDx = -1;
  double _barrierHoverLastDy = -1;

  @override
  void onDismissBarrierHover(PointerHoverEvent event) {
    if (!HardwareKeyboard.instance.isShiftPressed) {
      _barrierHoverLastDx = -1;
      _barrierHoverLastDy = -1;
      return;
    }
    final double dx = event.localPosition.dx - _barrierHoverLastDx;
    final double dy = event.localPosition.dy - _barrierHoverLastDy;
    if (dx * dx + dy * dy < 64) return;
    _barrierHoverLastDx = event.localPosition.dx;
    _barrierHoverLastDy = event.localPosition.dy;
    _selectTextAt(event.localPosition.dx, event.localPosition.dy);
  }

  // ── Page Turn ─────────────────────────────────────────────────────

  Future<void> _paginate(ReaderNavigationDirection direction) async {
    if (_controller == null) {
      return;
    }
    // Lyrics mode renders LyricsModeHtml — a vertical cue list with no
    // hoshiReader paginator. paginate() there no-ops in JS (the
    // `window.hoshiReader && ...` guard short-circuits) and returns undefined,
    // which _didScroll reads as a page edge → _handlePageTurnLimit →
    // _navigateToChapter, swapping the lyrics page for an EPUB chapter (the
    // text vanishes). Swipe paths already guard this (onSwipe/onBoundarySwipe);
    // the keyboard/gamepad/volume shortcut path funnels through here, so this is
    // the single choke point that must bail in lyrics mode.
    if (_lyricsMode) {
      return;
    }
    if (_settings?.isContinuousMode == true) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.paginateInvocation(direction),
      );
      if (!mounted || _controller == null) return;
      if (!_didScroll(result)) {
        _handlePageTurnLimit(direction.jsValue);
      } else {
        await _caretReanchor(direction);
      }
      return;
    }
    final dynamic result = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.paginateInvocation(direction),
    );
    if (!mounted || _controller == null) return;
    if (_didScroll(result)) {
      await _refreshProgress();
      if (!mounted || _controller == null) return;
      await _caretReanchor(direction);
    } else {
      _handlePageTurnLimit(direction.jsValue);
    }
  }

  // ── Image Viewer ──────────────────────────────────────────────────

  File? _readerImageFileForUrl(String imgUrl) {
    final Uri? uri = Uri.tryParse(imgUrl);
    if (uri == null || _extractDir == null) return null;
    if (uri.host != ReaderHibikiSource.kHost) return null;
    if (!uri.path.startsWith('/epub/')) return null;
    final String epubPath =
        Uri.decodeComponent(uri.path.substring('/epub/'.length));
    final String extractRoot = p.canonicalize(_extractDir!);
    final String filePath = p.canonicalize(p.join(extractRoot, epubPath));
    if (!p.isWithin(extractRoot, filePath)) {
      return null;
    }
    final File file = File(filePath);
    if (!file.existsSync()) return null;
    return file;
  }

  Future<void> _showReaderImageContextMenu(
    String imgUrl,
    Offset webViewOffset,
  ) async {
    if (!mounted) return;
    if (!isWindowsPlatform) {
      await _shareReaderImage(imgUrl);
      return;
    }
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset global = box?.localToGlobal(webViewOffset) ?? webViewOffset;
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(global.dx, global.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.copy_outlined, size: 18),
              const SizedBox(width: 12),
              Text(t.reader_copy_image),
            ],
          ),
        ),
      ],
    );
    if (action == 'copy') {
      await _copyReaderImageToClipboard(imgUrl);
    }
  }

  Future<void> _shareReaderImage(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await Share.shareXFiles(
        <XFile>[XFile(file.path, mimeType: fallbackMimeType(file.path))],
        subject: p.basename(file.path),
      );
    } catch (e) {
      HibikiToast.show(msg: t.reader_image_share_failed(error: e));
    }
  }

  Future<void> _copyReaderImageToClipboard(String imgUrl) async {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) {
      HibikiToast.show(msg: t.reader_image_file_unavailable);
      return;
    }
    try {
      await HibikiChannels.clipboardImage.invokeMethod<void>(
        'copyImageFile',
        <String, String>{'path': file.path},
      );
      HibikiToast.show(msg: t.copied_to_clipboard);
    } catch (e) {
      HibikiToast.show(msg: t.reader_image_copy_failed(error: e));
    }
  }

  void _openImageViewer(String imgUrl) {
    final File? file = _readerImageFileForUrl(imgUrl);
    if (file == null) return;
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor:
            Theme.of(context).colorScheme.scrim.withValues(alpha: 0.87),
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 10,
            child: Center(
              child: Image.file(file, fit: BoxFit.contain),
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
      final int s = ReaderHibikiSource.instance.skipActionSeconds;
      if (s == 0) {
        ctrl.skipToNextCue();
      } else {
        ctrl.seekRelative(s);
      }
    });
    _skipPrevSub = appModel.skipPreviousStream.listen((_) {
      final int s = ReaderHibikiSource.instance.skipActionSeconds;
      if (s == 0) {
        ctrl.skipToPrevCue();
      } else {
        ctrl.seekRelative(-s);
      }
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

  ({
    double fontSize,
    int textColor,
    int bgColor,
    int buttonTextColor,
    int buttonBgColor,
    int highlightColor,
    int activeColor,
  }) _floatingLyricStyle({double? fontSize}) {
    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final bool dark = _isReaderThemeDark;
    final Color accent = dark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
    return (
      fontSize: fontSize ?? appModel.floatingLyricFontSize,
      textColor: fg.value,
      bgColor: bg.withAlpha(dark ? 230 : 220).value,
      buttonTextColor: fg.value,
      buttonBgColor:
          (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
      highlightColor: accent.withAlpha(128).value,
      activeColor: accent.value,
    );
  }

  Future<bool> _showFloatingLyricWithStyle() {
    final style = _floatingLyricStyle();
    return FloatingLyricChannel.show(
      fontSize: style.fontSize,
      textColor: style.textColor,
      bgColor: style.bgColor,
      buttonTextColor: style.buttonTextColor,
      buttonBgColor: style.buttonBgColor,
      highlightColor: style.highlightColor,
      activeColor: style.activeColor,
      clickLookupEnabled: appModel.floatingLyricClickLookup,
    );
  }

  Future<void> _applyFloatingLyricStyle() async {
    final style = _floatingLyricStyle();
    await FloatingLyricChannel.updateStyle(
      fontSize: style.fontSize,
      textColor: style.textColor,
      bgColor: style.bgColor,
      buttonTextColor: style.buttonTextColor,
      buttonBgColor: style.buttonBgColor,
      highlightColor: style.highlightColor,
      activeColor: style.activeColor,
    );
    await FloatingLyricChannel.setClickLookupEnabled(
      appModel.floatingLyricClickLookup,
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
    await _showFloatingLyricWithStyle();
    await _applyFloatingLyricStyle();
    _setupFloatingLyricHandlers();
  }

  Future<bool> _toggleFloatingLyric() async {
    final bool current = appModel.showFloatingLyric;
    if (!current) {
      final bool shown = await _showFloatingLyricWithStyle();
      if (!shown) {
        if (mounted) {
          // Android needs the OS "draw over other apps" permission, so its
          // failure is a permission prompt. The desktop strip is a runner-owned
          // window with no such permission, so a failure there means window
          // creation failed — show the generic hint instead of a false
          // permission message.
          final String hint = Platform.isAndroid
              ? t.floating_lyric_permission_hint
              : t.floating_lyric_unavailable_hint;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(hint),
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
      onLookupText: _lookupFromFloatingLyric,
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

  /// Routes a tap on the desktop floating-lyric strip into the in-app
  /// dictionary popup. The strip is a separate native window with no DOM
  /// selection, so we segment the tapped word ([Language.wordFromIndex],
  /// the same extractor the Android popup uses) and show the popup with a
  /// centre-screen fallback rect — identical to the lyrics-mode path that
  /// also lacks a WebView selection rect.
  ///
  /// On Android the overlay launches its own `PopupDictActivity`, so this
  /// handler is only exercised by the Windows back-end; it is a no-op when no
  /// usable word can be segmented.
  Future<void> _lookupFromFloatingLyric(String text, int index) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || !mounted) return;
    final String word =
        appModel.targetLanguage.wordFromIndex(text: text, index: index).trim();
    final String searchTerm = word.isNotEmpty ? word : trimmed;

    final Rect selectionRect = Rect.fromCenter(
      center: Offset(
        MediaQuery.of(context).size.width / 2,
        MediaQuery.of(context).size.height / 2,
      ),
      width: 1,
      height: 1,
    );

    prunePopupStack(0);
    final int highlightCount = await searchDictionaryResult(
      searchTerm: searchTerm,
      selectionRect: selectionRect,
      deferDisplay: true,
    );
    if (!mounted) return;
    await _highlightAndShowPopup(highlightCount, selectionRect);
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

  void _toggleChrome({bool moveFocusToChrome = false}) {
    setState(() {
      _showChrome = !_showChrome;
    });
    _applyChromeInsets();
    if (!_showChrome) {
      // Chrome hidden: return focus to the reading content so directional keys
      // resume turning the page.
      _focusNode.requestFocus();
    } else if (moveFocusToChrome) {
      // Chrome shown via keyboard/gamepad: move focus into the chrome so its
      // controls are reachable by directional navigation. The bar mounts fresh
      // on this frame, so wait one frame before requesting focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_showChrome) return;
        _chromeFocusScope.requestFocus();
        // Guard against an unattached scope: FocusNode.nextFocus() dereferences
        // `context!` and throws if the chrome bar hasn't mounted this node yet
        // (e.g. toggled while reader content isn't ready). requestFocus() above
        // is safe without a context; only the traversal needs one.
        if (_chromeFocusScope.context != null) {
          _chromeFocusScope.nextFocus();
        }
      });
    }
  }

  Future<void> _applyChromeInsets() async {
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    final double top = _readerTopOffset;
    final double bottom = _showChrome
        ? _readerChromeHeight + _stableBottomInset
        : _stableBottomInset;
    await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.setChromeInsetsInvocation(top, bottom),
    );
    if (!mounted || _controller == null) return;
    // Keep the cursor's "is on the current page" viewport in sync with the chrome
    // (it changes the usable bottom inset) so the next enter()/move() lands inside
    // the visible page, and re-measure the ring for the reflow.
    await _controller!.evaluateJavascript(
      source: ReaderCaretScripts.initInvocation(
        color: _caretRingColorCss(),
        insetTop: top,
        insetBottom: bottom,
      ),
    );
    await _caretRefresh();
  }

  Widget _buildBottomChrome() {
    // 底栏可见性只取决于用户意图（_showChrome）和「首次冷加载是否完成」
    // （_hasEverLoaded，只置 true、从不复位），不再耦合每次切章都会翻转的
    // _readerContentReady。否则切章时 _readerContentReady=false 会把底栏硬卸载
    // 成 SizedBox.shrink()，新章就绪后又突然挂回，造成底栏闪烁。冷启动首章
    // 渲染前 _hasEverLoaded 仍为 false，底栏照旧不显示，行为不变。
    if (!_hasEverLoaded || !_showChrome) {
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
          child: FocusScope(
            node: _chromeFocusScope,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ReaderChromeScaler(
                  scale: _readerChromeScale,
                  baseHeight: _readerChromeBaseHeight,
                  child: AudiobookPlayBar(
                    controller: ctrl,
                    skipActionSeconds:
                        ReaderHibikiSource.instance.skipActionSeconds,
                    onOpenSettings: _showAppearanceSheet,
                    backgroundColor: _themeBackgroundColor(),
                    foregroundColor: _themeTextColor(),
                    reversed: appModel.reverseReaderBottomBar,
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
          ),
        );
      },
    );
  }

  Widget _buildSettingsBar() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool reversed = appModel.reverseReaderBottomBar;
    final List<Widget> barItems = <Widget>[
      IconButton(
        icon: Icon(Icons.headphones_outlined, color: _themeTextColor()),
        iconSize: 22,
        tooltip: t.audio_import,
        onPressed: _openAudioImportDialog,
      ),
      const Spacer(),
      IconButton(
        icon: Icon(Icons.tune_outlined, color: _themeTextColor()),
        iconSize: 20,
        tooltip: t.reader_settings_section,
        onPressed: _showAppearanceSheet,
      ),
    ];
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: FocusScope(
        node: _chromeFocusScope,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ReaderChromeScaler(
              scale: _readerChromeScale,
              baseHeight: _readerChromeBaseHeight,
              child: ColoredBox(
                color: _themeBackgroundColor(),
                child: SizedBox(
                  height: _readerChromeBaseHeight,
                  child: Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
                    child: Row(
                      children:
                          reversed ? barItems.reversed.toList() : barItems,
                    ),
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
      ),
    );
  }

  Future<void> _openAudioImportDialog() async {
    if (_srtBookUid != null) {
      await _openSrtBookAudioPicker();
      return;
    }
    final AudiobookRepository repo = AudiobookRepository(appModel.database);

    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AudiobookImportDialog(
        bookKey: widget.bookKey,
        repo: repo,
        extractDir: _extractDir,
      ),
    );

    try {
      await _resolveAudioSlot();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.openAudioImport', e, stack);
      debugPrint('[ReaderHibiki] resolveAudioSlot after import failed: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _openSrtBookAudioPicker() async {
    final SrtBookRepository repo = SrtBookRepository(appModel.database);
    final SrtBook? book = await repo.findByUid(_srtBookUid!);
    if (book == null || !mounted) return;

    final List<String>? newPaths = await showAppDialog<List<String>>(
      context: context,
      builder: (ctx) {
        final String currentLabel =
            book.audioPaths != null && book.audioPaths!.isNotEmpty
                ? t.srt_import_files_selected(n: book.audioPaths!.length)
                : (book.audioRoot ?? t.audio_panel_add_audio);
        return ReaderSrtAudioPickerDialog(
          currentLabel: currentLabel,
          onPickFiles: () => _pickSrtAudioFiles(ctx),
        );
      },
    );

    if (newPaths == null || newPaths.isEmpty || !mounted) return;

    HibikiToast.show(msg: t.dialog_importing);

    try {
      final Directory persistDir =
          await AudiobookStorage.ensurePersistDir(_srtBookUid!);
      await AudiobookStorage.cleanAudioFiles(persistDir);

      final List<String> persisted = <String>[];
      for (final String src in newPaths) {
        persisted.add(
          await AudiobookStorage.persistFileWithProgress(File(src), persistDir),
        );
      }

      book.audioPaths = persisted;
      book.audioRoot = null;
      await repo.save(book);

      await _resolveAudioSlot();
      if (mounted) {
        setState(() {});
        HibikiToast.show(msg: t.audiobook_import_success);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.srtBookAudioPicker', e, stack);
      debugPrint('[ReaderHibiki] srtBookAudioPicker failed: $e');
      if (mounted) HibikiToast.show(msg: t.audiobook_import_error);
    }
  }

  Future<void> _pickSrtAudioFiles(BuildContext dialogContext) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (result == null) return;
    final List<String> paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList()
      ..sort(compareAudioFilePath);
    if (paths.isNotEmpty && dialogContext.mounted) {
      Navigator.pop(dialogContext, paths);
    }
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
    // 重入守卫：快速连点时按钮按下到 show 之间的 DB 读 await 期间会二次进入、弹出
    // 两个面板。标志置位必须在第一个 await 之前，复位放 finally（异常也复位）。
    if (_appearanceSheetOpen) return;
    _appearanceSheetOpen = true;
    try {
      // _settings 就是 ReaderHibikiSource.readerSettings 本体（见 initState 绑定），
      // 面板控件经 ReaderHibikiSource.instance.ttu* 实时读写同一对象，开面板前后都
      // 无需设置同步——旧 TTU 双存储时代的 _syncSettings*Hive 已是写回自身的死桥，
      // 且 _syncSettingsToHive 会触发 17× onSettingsChangedLive 的 DB/WebView 风暴。
      final List<TtuTocEntry> toc = _buildTtuToc();
      final String bookKey = widget.bookKey;
      final BookmarkRepository bmRepo = BookmarkRepository(appModel.database);
      final FavoriteSentenceRepository favRepo =
          FavoriteSentenceRepository(appModel.database);

      List<Bookmark> bookmarks = await bmRepo.getBookmarks(bookKey);
      final List<FavoriteSentence> allFavorites = await favRepo.getAll();
      final List<FavoriteSentence> favorites =
          allFavorites.where((f) => f.bookKey == bookKey).toList();

      if (!mounted) return;

      final Widget sheetContent = ReaderQuickSettingsSheet(
        controller: _audiobookController,
        toc: toc,
        readerProgress: (_currentChapter, _book!.chapters.length),
        onJumpSection: (index) async {
          _navigateToChapter(index, manual: true);
        },
        onBookmark: () async {
          await _addBookmarkAtCurrentPosition();
        },
        onExitReader: () {
          Navigator.of(context).pop();
        },
        webViewController: _controller!,
        appModel: appModel,
        ref: ref,
        isHibikiReader: true,
        onStyleChanged: _applyStylesLive,
        onThemeChanged: _onThemeChanged,
        extractDir: _extractDir,
        onReloadChapter: _reloadWithCurrentSettings,
        onAudioImport: _srtBookUid != null ? _openAudioImportDialog : null,
        lyricsMode: _lyricsMode,
        onToggleLyricsMode: _toggleLyricsMode,
        showFloatingLyric: appModel.showFloatingLyric,
        onToggleFloatingLyric: _toggleFloatingLyric,
        floatingLyricFontSize: appModel.floatingLyricFontSize,
        onFloatingLyricFontSizeChanged: (v) async {
          await appModel.setFloatingLyricFontSize(v);
          final style = _floatingLyricStyle(fontSize: v);
          await FloatingLyricChannel.updateStyle(
            fontSize: style.fontSize,
            textColor: style.textColor,
            bgColor: style.bgColor,
            buttonTextColor: style.buttonTextColor,
            buttonBgColor: style.buttonBgColor,
            highlightColor: style.highlightColor,
            activeColor: style.activeColor,
          );
        },
        floatingLyricClickLookup: appModel.floatingLyricClickLookup,
        onFloatingLyricClickLookupChanged: (bool value) async {
          await appModel.setFloatingLyricClickLookup(value);
          await FloatingLyricChannel.setClickLookupEnabled(value);
        },
        showMediaNotification: appModel.showMediaNotification,
        onToggleMediaNotification: _toggleMediaNotification,
        charProgress:
            _progressCurrentChars != null && _progressTotalChars != null
                ? (_progressCurrentChars!, _progressTotalChars!)
                : null,
        onJumpToCharOffset: (globalOffset) async {
          _jumpToGlobalCharOffset(globalOffset);
        },
        epubBook: _book,
        chapterLabel: _currentChapterLabel(),
        onSearchJump: (BookSearchResult result, String query) async {
          if (_book == null || _controller == null) return;
          if (result.sectionIndex != _currentChapter) {
            final bool ok = await _navigateToChapterAndWait(
              result.sectionIndex,
              manual: true,
            );
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
            await _navigateToChapterAndWait(bm.sectionIndex, manual: true);
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
              bookKey,
              sectionIndex: bookmark.sectionIndex,
              normCharOffset: bookmark.normCharOffset,
              createdAt: bookmark.createdAt,
            );
          }
          bookmarks = await bmRepo.getBookmarks(bookKey);
        },
        favoriteSentences: favorites,
        onDeleteFavorite: (fav) async {
          await favRepo.removeById(fav.id);
        },
        onJumpToFavorite: (fav) async {
          if (fav.sectionIndex == null) return;
          if (fav.sectionIndex != _currentChapter) {
            await _navigateToChapterAndWait(fav.sectionIndex!, manual: true);
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
          builder: (_) => HibikiDialogFrame(
            // master-detail（左父菜单 + 右详情）需要更宽画布；窄于 640 的窗口
            // 由面板内部 LayoutBuilder 自动降级回单列 push。
            maxWidth: 900,
            maxHeightFactor: 0.80,
            scrollable: false,
            child: sheetContent,
          ),
        );
      } else {
        await adaptiveModalSheet<void>(
          context: context,
          builder: (_) => sheetContent,
        );
      }

      _syncDictionaryTheme();
    } finally {
      _appearanceSheetOpen = false;
    }
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
        bookKey: widget.bookKey,
        bookTitle: _book?.title,
      );
      await BookmarkRepository(appModel.database)
          .addBookmark(widget.bookKey, bm);
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

    final (int, int)? pageInfo = await _probePageInfo();

    final Bookmark bm = Bookmark(
      sectionIndex: _currentChapter,
      normCharOffset: normOffset,
      label: label,
      createdAt: DateTime.now(),
      bookKey: widget.bookKey,
      bookTitle: _book?.title,
      pageInChapter: pageInfo?.$1,
      totalPagesInChapter: pageInfo?.$2,
    );

    await BookmarkRepository(appModel.database).addBookmark(widget.bookKey, bm);
  }

  /// Probes the paginated reader engine for the current page / total pages
  /// within the loaded chapter. Returns `null` in continuous mode (no pages)
  /// or when the engine isn't ready.
  Future<(int, int)?> _probePageInfo() async {
    if (_controller == null) return null;
    final Object? raw = await _controller!.evaluateJavascript(
      source: ReaderPaginationScripts.pageInfoInvocation(),
    );
    if (raw is! String) return null;
    final String trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'null') return null;
    try {
      final Map<String, dynamic> info =
          jsonDecode(trimmed) as Map<String, dynamic>;
      final int? current = (info['currentPage'] as num?)?.toInt();
      final int? total = (info['totalPages'] as num?)?.toInt();
      if (current == null || total == null || total <= 0) return null;
      return (current, total);
    } catch (_) {
      return null;
    }
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
    _sanitizedCssCache.clear();
    _invalidateStyleCache();
    if (_lyricsMode) {
      await _loadLyricsPage();
      return;
    }
    final dynamic result;
    try {
      result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.progressInvocation(),
      );
    } catch (e, stack) {
      // 半销毁的 WebView 上 evaluateJavascript 抛 PlatformException；此处尚未改
      // 任何恢复状态，安全 no-op 返回（此前这是 try 块外的孤儿 await，会逃 zone）。
      ErrorLogService.instance
          .log('ReaderHibiki.reloadWithCurrentSettings.eval', e, stack);
      return;
    }
    if (!mounted || _controller == null) return;
    final double? progress = _toDouble(result);
    _initialProgress = progress ?? 0.0;
    // BUG-162: full reload 暂沿用粗粒度分数重锚（与改动前一致，不回归）。精确字符
    // 重锚是后续可做的增量；本次只根治退出再进的持久化恢复。
    _initialCharOffset = -1;
    _lastProgressSection = _currentChapter;
    _lastProgressValue = _initialProgress;

    final int gen = ++_navigateGeneration;
    _restoreExpectedGeneration = gen;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();
    _restoreInFlight = true;
    debugPrint('[ReaderHibiki] reloadWithCurrentSettings: '
        'chapter=$_currentChapter progress=$_initialProgress '
        'generation=$gen continuous=${_settings?.isContinuousMode}');

    setState(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();

    try {
      await _loadChapterDirectly(_currentChapter);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.reloadWithCurrentSettings', e, stack);
      debugPrint('[ReaderHibiki] reloadWithCurrentSettings failed: $e');
      _restoreInFlight = false;
      if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
        _restoreCompleter!.complete(false);
      }
      _restoreCompleter = null;
    }
  }

  // ── Top Progress Bar ──────────────────────────────────────────────

  Widget _buildTopProgressBar() {
    if (_lyricsMode || !_showTopProgress) {
      return const SizedBox.shrink();
    }

    final double ratio =
        (_progressCurrentChars! / _progressTotalChars!).clamp(0.0, 1.0);
    final Color infoColor = _themeTextColor();

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

  static const Map<String, ({Color bg, Color fg, Color sasayaki, bool dark})>
      _themeMap = {
    'ecru-theme': (
      bg: Color(0xFFF7F6EB),
      fg: Color(0xDE000000),
      sasayaki: Color(0x66A8C68C),
      dark: false,
    ),
    'water-theme': (
      bg: Color(0xFFDFECF4),
      fg: Color(0xDE000000),
      sasayaki: Color(0x6664B4DC),
      dark: false,
    ),
    'gray-theme': (
      bg: Color(0xFF23272A),
      fg: Color(0xDEFFFFFF),
      sasayaki: Color(0x595096C8),
      dark: true,
    ),
    'dark-theme': (
      bg: Color(0xFF121212),
      fg: Color(0x99FFFFFF),
      sasayaki: Color(0x594682B4),
      dark: true,
    ),
    'black-theme': (
      bg: Color(0xFF000000),
      fg: Color(0xDEFFFFFF),
      sasayaki: Color(0x663C78AA),
      dark: true,
    ),
  };

  Color _themeBackgroundColor() {
    final String key = appModel.appThemeKey;
    if (key == 'custom-theme') {
      return appModel.customThemeBackgroundColor ?? const Color(0xFFFFFFFF);
    }
    return _themeMap[key]?.bg ?? const Color(0xFFFFFFFF);
  }

  Color _themeTextColor() {
    final String key = appModel.appThemeKey;
    if (key == 'custom-theme') {
      return appModel.customThemeFontColor ??
          (appModel.customThemeDark
              ? const Color(0xDEFFFFFF)
              : const Color(0xDE000000));
    }
    return _themeMap[key]?.fg ?? const Color(0xDE000000);
  }

  Color _themeSasayakiColor() {
    final String key = appModel.appThemeKey;
    if (key == 'custom-theme') {
      return appModel.customThemeSasayakiColor ??
          HibikiColor.defaultSasayakiColor;
    }
    return _themeMap[key]?.sasayaki ?? HibikiColor.defaultSasayakiColor;
  }

  bool get _isReaderThemeDark {
    final String key = appModel.appThemeKey;
    if (key == 'custom-theme') return appModel.customThemeDark;
    return _themeMap[key]?.dark ?? false;
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

  Future<void> _onThemeChanged() async {
    // HBK-AUDIT-117: persist the reader theme here, in the theme-change flow,
    // instead of as a hidden side effect of _applyChapterHighlights (which only
    // ran when the chapter had favorites).
    await _settings?.setTheme(appModel.appThemeKey);
    _syncDictionaryTheme();
    if (appModel.showFloatingLyric) {
      await _applyFloatingLyricStyle();
    }
    if (_lyricsMode) {
      await _updateLyricsStyleLive();
    }
    if (mounted) setState(() {});
  }

  void _syncDictionaryTheme() {
    final Color bg = _themeBackgroundColor();
    final Color textColor = _themeTextColor();
    final Brightness brightness =
        _isReaderThemeDark ? Brightness.dark : Brightness.light;
    appModel.setOverrideDictionaryColor(bg);
    appModel.setOverrideDictionaryTheme(
      ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: bg,
          brightness: brightness,
        ).copyWith(
          onSurface: textColor,
        ),
      ),
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

  Future<void> _refreshSectionHighlights(int section) async {
    if (_controller == null) return;
    if (_lyricsMode) {
      await _applyLyricsFavorites();
      return;
    }
    final List<FavoriteSentence> all =
        await FavoriteSentenceRepository(appModel.database).getAll();
    final List<FavoriteSentence> chapterFavs = all
        .where((s) => s.bookKey == widget.bookKey && s.sectionIndex == section)
        .toList();
    await HighlightBridge.applyHighlights(_controller!, chapterFavs,
        backgroundHex: _readerBackgroundHex,
        customHighlightCss: _customHighlightCss);
    await _controller!.evaluateJavascript(
      source:
          'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
    );
  }

  Future<void> _toggleFavoriteSentence() async {
    if (_controller == null || _book == null) return;
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    if (sentence.isEmpty) {
      HibikiToast.show(msg: t.no_sentence_selected);
      return;
    }

    final int section = _lookupSectionIndex;
    final sentenceRange = _cachedSentenceRange ??
        (_cachedSelectionRange != null
            ? (
                offset: _cachedSelectionRange!.offset,
                length: _cachedSelectionRange!.length
              )
            : null);
    debugPrint('[hoshi-hl] toggleFavorite: '
        'sentenceRange=${sentenceRange != null ? "(${sentenceRange.offset},${sentenceRange.length})" : "null"} '
        'cachedSentence=${_cachedSentenceRange != null} '
        'cachedSelection=${_cachedSelectionRange != null}');
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);

    if (_currentSentenceIsFavorited) {
      await repo.removeByContent(
        text: sentence,
        bookKey: widget.bookKey,
        sectionIndex: section,
        normCharOffset: sentenceRange?.offset,
      );
      setState(() => _currentSentenceIsFavorited = false);
      if (sentenceRange != null || _lyricsMode) {
        await _refreshSectionHighlights(section);
      }
      HibikiToast.show(msg: t.favorite_removed);
      return;
    }

    final FavoriteSentence fav = FavoriteSentence(
      text: sentence,
      bookTitle: _book!.title,
      chapterLabel: _currentChapterLabelFor(section),
      createdAt: DateTime.now(),
      bookKey: widget.bookKey,
      sectionIndex: section,
      normCharOffset: sentenceRange?.offset,
      normCharLength: sentenceRange?.length,
    );
    await repo.add(fav);
    setState(() => _currentSentenceIsFavorited = true);
    if (sentenceRange != null || _lyricsMode) {
      await _refreshSectionHighlights(section);
    }
    HibikiToast.show(msg: t.favorite_added);
  }

  @override
  Widget? buildPopupAudioControls() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    final bool hasAudio = ctrl != null && ctrl.chapterCueCount > 0;

    Widget buildRow(ThemeData theme) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
      final AudioCue? cue = _lookupCue;
      final bool hasCue = cue != null;
      return ReaderChromeScaler(
        scale: _readerChromeScale,
        baseHeight: _readerPopupHeaderBaseHeight,
        child: SizedBox(
          height: _readerPopupHeaderBaseHeight,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.dividerColor,
                  width: 0.5,
                ),
              ),
            ),
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                HibikiIconButton(
                  icon: _currentSentenceIsFavorited
                      ? Icons.star
                      : Icons.star_border,
                  size: 20,
                  enabledColor: _currentSentenceIsFavorited
                      ? theme.colorScheme.primary
                      : null,
                  onTap: _toggleFavoriteSentence,
                  tooltip: t.action_favorite,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                ),
                if (hasAudio) ...[
                  SizedBox(width: tokens.spacing.gap),
                  HibikiIconButton(
                    icon: Icons.replay_outlined,
                    size: 20,
                    onTap: hasCue
                        ? () {
                            final AudioCue? cue = _lookupCue;
                            if (cue == null) return;
                            ctrl.playCueOnce(cue);
                          }
                        : null,
                    tooltip: t.repeat_cue,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  HibikiIconButton(
                    icon: ctrl.isPlaying
                        ? Icons.pause_outlined
                        : Icons.play_arrow_outlined,
                    size: 24,
                    onTap: ctrl.togglePlayPause,
                    tooltip: ctrl.isPlaying ? t.pause : t.play,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  HibikiIconButton(
                    icon: Icons.play_circle_outline,
                    size: 20,
                    onTap: hasCue
                        ? () {
                            final AudioCue? cue = _lookupCue;
                            if (cue == null) return;
                            ctrl.playCueAndContinue(cue);
                            clearDictionaryResult();
                          }
                        : null,
                    tooltip: t.play_from_cue,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // Own focus scope so the gamepad can move focus into the header (Up from the
    // popup content top) and the buttons traverse with Left/Right. The node is a
    // State field (stable across rebuilds); only the index==0 popup gets a
    // header, so exactly one widget ever uses this node at a time.
    if (!hasAudio) {
      return FocusScope(
        node: _popupHeaderScope,
        child: Builder(builder: (context) => buildRow(Theme.of(context))),
      );
    }
    return FocusScope(
      node: _popupHeaderScope,
      child: ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) => buildRow(Theme.of(context)),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Audiobook _audiobookFromRow(AudiobookRow row) {
    final Audiobook ab = Audiobook()
      ..id = row.id
      ..bookKey = row.bookKey
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
      ..bookKey = row.bookKey;
    if (row.audioPathsJson != null) {
      book.audioPaths =
          (jsonDecode(row.audioPathsJson!) as List<dynamic>).cast<String>();
    }
    return book;
  }
}

@visibleForTesting
class ReaderLyricsModeHintDialog extends StatelessWidget {
  const ReaderLyricsModeHintDialog({
    required this.onClose,
    super.key,
  });

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: t.lyrics_mode_hint_title,
        leadingIcon: Icons.lyrics_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.lyrics_mode_hint_body,
          style: tokens.type.listSubtitle,
        ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: adaptiveDialogAction(
            context: context,
            onPressed: onClose,
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class ReaderSrtAudioPickerDialog extends StatelessWidget {
  const ReaderSrtAudioPickerDialog({
    required this.currentLabel,
    required this.onPickFiles,
    super.key,
  });

  final String currentLabel;
  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 460,
      maxHeightFactor: 0.76,
      child: HibikiModalSheetFrame(
        title: t.srt_book_replace_audio,
        leadingIcon: Icons.audio_file_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          currentLabel,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            FilledButton.icon(
              onPressed: onPickFiles,
              icon: const Icon(Icons.audio_file_outlined, size: 18),
              label: Text(t.srt_import_pick_audio_files),
            ),
          ],
        ),
      ),
    );
  }
}

extension _LetExtension<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
