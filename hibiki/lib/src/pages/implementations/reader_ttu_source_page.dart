import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:document_file_save_plus/document_file_save_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:local_assets_server/local_assets_server.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/src/anki/anki_models.dart';
import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/reading_time_tracker.dart';
import 'package:hibiki/src/media/audiobook/highlight_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/bookmark_repository.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/collection_audio_matcher.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/media/audiobook/audiobook_repository.dart';
import 'package:hibiki/src/media/audiobook/reader_position_model.dart';
import 'package:hibiki/src/media/audiobook/reader_position_repository.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';
import 'package:hibiki/src/media/audiobook/srt_book_model.dart';
import 'package:hibiki/src/media/audiobook/srt_book_repository.dart';
import 'package:hibiki/src/media/audiobook/srt_parser.dart';
import 'package:hibiki/utils.dart';

String _cssAlpha(int alpha) {
  if (alpha == 255) {
    return '1';
  }
  return (alpha / 255.0).toStringAsFixed(2);
}

/// Builds the TTU custom theme object stored in localStorage.
Map<String, String> buildTtuCustomThemeDefinition({
  required bool dark,
  Color? fontColor,
  Color? backgroundColor,
  Color? selectionColor,
}) {
  final Color resolvedFontColor =
      fontColor ?? (dark ? const Color(0xDEFFFFFF) : const Color(0xDE000000));
  final int r = resolvedFontColor.red;
  final int g = resolvedFontColor.green;
  final int b = resolvedFontColor.blue;
  final String a = (resolvedFontColor.alpha / 255.0).toStringAsFixed(2);

  final Color resolvedBg = backgroundColor ??
      (dark ? const Color(0xFF23272A) : const Color(0xFFFFFFFF));
  final String bgRgba =
      'rgba(${resolvedBg.red},${resolvedBg.green},${resolvedBg.blue},${_cssAlpha(resolvedBg.alpha)})';

  final Color resolvedSel = selectionColor ??
      (dark ? const Color(0xCCD4D9DC) : const Color(0xFF979797));
  final String selRgba =
      'rgba(${resolvedSel.red},${resolvedSel.green},${resolvedSel.blue},${_cssAlpha(resolvedSel.alpha)})';

  return {
    'fontColor': 'rgba($r,$g,$b,$a)',
    'backgroundColor': bgRgba,
    'selectionFontColor': dark ? 'rgba(85,90,92,0.6)' : 'rgba(245,245,245,1)',
    'selectionBackgroundColor': selRgba,
    'hintFuriganaFontColor': 'rgba($r,$g,$b,0.38)',
    'hintFuriganaShadowColor':
        dark ? 'rgba(240,240,241,0.3)' : 'rgba(34,34,49,0.3)',
    'tooltipTextFontColor': 'rgba($r,$g,$b,0.6)',
  };
}

/// Builds JavaScript that writes Hibiki's custom theme into TTU.
String buildTtuCustomThemeJs({
  required bool dark,
  Color? fontColor,
  Color? backgroundColor,
  Color? selectionColor,
}) {
  final String themesJson = jsonEncode({
    'custom-theme': buildTtuCustomThemeDefinition(
      dark: dark,
      fontColor: fontColor,
      backgroundColor: backgroundColor,
      selectionColor: selectionColor,
    ),
  });
  return 'window.localStorage.setItem("customThemes",'
      '${jsonEncode(themesJson)})';
}

class ReaderTtuBridgeInjectionGate {
  Future<void>? _active;

  bool get isRunning => _active != null;

  Future<void> run(Future<void> Function() operation) {
    final Future<void>? active = _active;
    if (active != null) {
      return active;
    }

    final Future<void> next = Future<void>.sync(operation);
    _active = next;
    return next.whenComplete(() {
      if (identical(_active, next)) {
        _active = null;
      }
    });
  }
}

/// Whether the TTU WebView needs bottom space reserved for reader chrome.
bool shouldReserveReaderBottomChrome({
  required bool showPlayBar,
}) {
  return showPlayBar;
}

int resolveTtuPageMarginBottom({
  required String writingMode,
  required double firstDimensionMargin,
  required double secondDimensionMargin,
}) {
  final double base = writingMode == 'vertical-rl'
      ? secondDimensionMargin
      : firstDimensionMargin;
  return base.round();
}

double resolveReaderProgressRatio({
  required double scrollPosition,
  required double scrollExtent,
  required double viewportExtent,
}) {
  final double maxScroll = scrollExtent - viewportExtent;
  if (maxScroll <= 0) return 0;
  return (scrollPosition.abs() / maxScroll).clamp(0, 1).toDouble();
}

(int current, int total)? resolveDisplayedPageProgress({
  required int currentPage,
  required int totalPages,
}) {
  if (totalPages <= 0) return null;
  final int current = (currentPage + 1).clamp(1, totalPages);
  return (current, totalPages);
}

(int current, int total)? resolveFullBookReaderProgress({
  required List<int> sectionChars,
  required int sectionIndex,
  required int sectionCurrentChars,
  required int sectionTotalChars,
}) {
  if (sectionChars.isEmpty || sectionTotalChars <= 0) return null;
  if (sectionIndex < 0 || sectionIndex >= sectionChars.length) return null;

  final int total = sectionChars.fold<int>(0, (int a, int b) => a + b);
  if (total <= 0) return null;

  final int previous =
      sectionChars.take(sectionIndex).fold<int>(0, (int a, int b) => a + b);
  final double ratio =
      (sectionCurrentChars / sectionTotalChars).clamp(0, 1).toDouble();
  final int current =
      (previous + (sectionChars[sectionIndex] * ratio).round()).clamp(0, total);
  return (current, total);
}

(int current, int total)? resolveTopReaderProgress({
  required List<int> sectionChars,
  required int sectionIndex,
  required int sectionCurrentChars,
  required int sectionTotalChars,
}) {
  if (sectionTotalChars <= 0) return null;
  if (sectionChars.isEmpty) {
    return (sectionCurrentChars, sectionTotalChars);
  }
  return resolveFullBookReaderProgress(
    sectionChars: sectionChars,
    sectionIndex: sectionIndex,
    sectionCurrentChars: sectionCurrentChars,
    sectionTotalChars: sectionTotalChars,
  );
}

List<int> parseReaderProgressSectionChars(String? raw) {
  if (raw == null || raw.isEmpty) return const <int>[];
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! List) return const <int>[];
    return decoded
        .whereType<num>()
        .map((num v) => v.toInt() < 0 ? 0 : v.toInt())
        .toList(growable: false);
  } catch (_) {
    return const <int>[];
  }
}

(int sectionIndex, int localOffset)? resolveGlobalCharOffset({
  required List<int> sectionChars,
  required int globalOffset,
}) {
  if (sectionChars.isEmpty) return null;
  final int total = sectionChars.fold<int>(0, (int a, int b) => a + b);
  if (globalOffset < 0 || globalOffset > total) return null;
  final int clamped = globalOffset.clamp(0, total);
  int accumulated = 0;
  for (int i = 0; i < sectionChars.length; i++) {
    if (accumulated + sectionChars[i] > clamped) {
      return (i, clamped - accumulated);
    }
    accumulated += sectionChars[i];
  }
  final int last = sectionChars.length - 1;
  return (last, sectionChars[last]);
}

/// Builds the native reader chrome theme around the TTU page surface.
ThemeData buildTtuReaderChromeTheme({
  required ThemeData base,
  required Color surface,
}) {
  return base.copyWith(
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    cardColor: surface,
    colorScheme: base.colorScheme.copyWith(
      surface: surface,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
    ),
    bottomAppBarTheme: base.bottomAppBarTheme.copyWith(color: surface),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(backgroundColor: surface),
  );
}

/// The media page used for the [ReaderTtuSource].
class ReaderTtuSourcePage extends BaseSourcePage {
  /// Create an instance of this page.
  const ReaderTtuSourcePage({
    super.item,
    this.initialBookmarkJump,
    super.key,
  });

  final Bookmark? initialBookmarkJump;

  @override
  BaseSourcePageState createState() => _ReaderTtuSourcePageState();
}

class _ReaderTtuSourcePageState extends BaseSourcePageState<ReaderTtuSourcePage>
    with WidgetsBindingObserver {
  /// The media source pertaining to this page.
  ReaderTtuSource get mediaSource => ReaderTtuSource.instance;
  bool _controllerInitialised = false;
  late InAppWebViewController _controller;

  DateTime? lastMessageTime;
  DateTime? lastTapLookupTime;
  Orientation? lastOrientation;

  Duration get consoleMessageDebounce => const Duration(milliseconds: 50);
  Duration get tapLookupDebounce => const Duration(milliseconds: 500);

  final FocusNode _focusNode = FocusNode();
  bool _isRecursiveSearching = false;
  bool _wasPlayingBeforeLookup = false;

  /// 查词时对应的 cue（"句子 A"），用于 popup 三按钮控制。
  AudioCue? _lookupCue;

  // ── 有声书播放器 ────────────────────────────────────────────────────────────
  AudiobookPlayerController? _audiobookController;
  final ValueNotifier<ThemeData?> _barThemeNotifier =
      ValueNotifier<ThemeData?>(null);

  /// 异步判定：这本书是否有 Audiobook/SrtBook 记录且配置了音频。
  /// WebView 在 `_audioSlotResolved` 前不创建，避免视口先大后小触发 ttu
  /// paginated 模式 resize 重排（vertical-rl 列高变短 → 首页文字整体上移）。
  bool _hasAudioSlot = false;
  bool _audioSlotResolved = false;

  static const double _readerChromeHeight = 56;
  static const double _topProgressBarHeight = 18;
  static const int _resumeRestoreOffsetTolerance = 500;
  double _stableTopInset = 0;
  double _stableBottomInset = 0;
  bool _stableInsetsCaptured = false;

  bool get _hasReaderBottomChrome => shouldReserveReaderBottomChrome(
        showPlayBar: appModel.showPlayBar,
      );

  double get _readerBottomReserve =>
      (_hasReaderBottomChrome ? _readerChromeHeight : 0) + _stableBottomInset;

  /// ttu 的 pageMarginBottom 只表示用户原有底部页边距。
  ///
  /// 播放栏预留由 Flutter WebView 容器的 bottom inset 负责。如果这里也加
  /// 播放栏高度，就会让 TTU 分页列高和实际 WebView bounds 脱节。
  ///
  /// pageMarginBottom == -1 时 ttu 会 fallback 到 legacyVerticalPageMargin：
  ///   horizontal-tb → firstDimensionMargin
  ///   vertical-rl   → secondDimensionMargin
  /// 我们直接算出同样的值，避免破坏页边距语义。
  int _ttuPageMarginBottom() {
    final ReaderTtuSource src = ReaderTtuSource.instance;
    return resolveTtuPageMarginBottom(
      writingMode: src.ttuWritingMode,
      firstDimensionMargin: src.ttuFirstDimensionMargin,
      secondDimensionMargin: src.ttuSecondDimensionMargin,
    );
  }

  /// 播放栏显隐变化后，通过 ttu bridge 实时同步 pageMarginBottom。
  void _syncTtuPageMarginBottom() {
    if (!_controllerInitialised) return;
    AudiobookBridge.setReaderSetting(
      _controller,
      key: 'pageMarginBottom',
      value: _ttuPageMarginBottom(),
    );
  }

  int? _progressCurrentChars;
  int? _progressTotalChars;
  String? _progressSectionCharsMetadata;
  List<int> _progressSectionChars = const <int>[];

  bool get _showTopProgress =>
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0;

  double get _readerTopOffset =>
      _stableTopInset + (_showTopProgress ? _topProgressBarHeight : 0);

  List<int> _readerProgressSectionChars() {
    final String? raw = widget.item?.sourceMetadata;
    if (raw != _progressSectionCharsMetadata) {
      _progressSectionCharsMetadata = raw;
      _progressSectionChars = parseReaderProgressSectionChars(raw);
    }
    return _progressSectionChars;
  }

  /// 当前章节的 href（用于 cue 查询和 JS 注解）。
  String _currentChapterHref = '';

  /// 非 null 表示当前书来自 [SrtBook]（字幕 EPUB）；值为 [SrtBook.uid]。
  String? _srtBookUid;

  // ── PR8b: Follow audio pill + auto-off 状态 ─────────────────────────────

  /// Follow=OFF 时 cue 跨章触发：悬浮 pill，点击跳转后清空。
  /// null 表示无 pending；setState 驱动重绘。
  int? _pendingNavSection;

  /// ttu TOC 缓存（section index → label），用于 pill 显示章节名。
  Map<int, String> _tocLabels = const {};

  /// ttu 当前书籍的 section 总数。用于在 Dart 侧过滤旧书签、旧恢复位置、
  /// 旧 Sasayaki 匹配结果里的越界 section，避免把无效导航发给 WebView。
  int? _ttuSectionCount;

  /// 已被请求跳章（`requestSectionNav` 调用后），用来过滤掉那条由自己
  /// 触发的 sectionChanged 回报事件——否则 ON 模式下系统自己跳的章会
  /// 被当成用户意图，立刻又把 Follow auto-off 掉。
  int? _inFlightNavSection;

  /// 跨章跳章超时兜底。`requestSectionNav` 用 `evaluateJavascript`，不 await
  /// JS Promise——Dart 侧 await 几乎瞬间返回。之前立刻调
  /// `notifySectionRestoreCompleted` 会提前清 `_chapterTransition`，期间
  /// 另一条 cue tick 看到段不匹配再发一次跳章，ttu 被轮番 `__ttuGoToSection`，
  /// scrollTop 反复被清零到章首（翻页被拽回首页的视觉来源）。改为等 ttu
  /// 自己把 `sectionChanged(auto=true, idx==target)` 推回来再 notify；本
  /// Timer 兜底 ttu fork 缺失 / 跳章失败 3s 内没回报时强制降级为 pill。
  Timer? _navRestoreTimeout;

  /// Reader position restore has a different failure mode from audio follow:
  /// it must not reveal the WebView at section top just because the first
  /// section navigation callback is slow. Retry before failing open.
  Timer? _readerRestoreNavTimeout;
  int _readerRestoreNavAttempts = 0;

  /// reader 当前挂载的 ttu section index。-1 = 还没收到任何 sectionChanged
  /// 事件（开书前 / ttu 还没初始化）。供 controller 通过
  /// [AudiobookPlayerController.getCurrentReaderSection] 读取，作为"cue 是否
  /// 跨章"的判定参照系（对齐 Sasayaki SasayakiPlayer 的 getCurrentIndex 闭包）。
  ///
  /// 不能默认 0：cue 在第 5 章但 reader 还没汇报时，0 会被误判为"跨章"。
  /// controller 端遇到 -1 直接 return 不触发跨章逻辑。
  int _currentTtuSection = -1;

  /// 上次调 applySasayakiCues 的 section。JS 侧也有 guard（same section +
  /// rootLen），Dart 侧再挡一层减少 bridge 开销。
  int _lastSasayakiAppliedSection = -1;

  final ReaderTtuBridgeInjectionGate _audiobookBridgeInjectionGate =
      ReaderTtuBridgeInjectionGate();

  // ── 位置持久化（ReaderPosition Isar 表） ────────────────────────────────
  //
  // 保存触发：JS 侧 scroll debounce 500ms 调 saveReaderPos handler，Dart 侧
  // 拿到 {section, offset} 即刻写 Isar（去重：同 section+offset 跳过）。
  // dispose 里做一次 flush：evaluate 当前视口位置 → 写库，兜 500ms debounce
  // 窗内关书丢失。

  /// 上一次写进 Isar 的位置，用于去重，避免高频 scroll 里重复 writeTxn。
  ReaderViewportPos? _lastSavedPos;

  /// 一本书的 WebView 生命周期里只做一次恢复。**不是只在成功时置 true**：
  /// 读 Isar 返回 null（新书）/ requestSectionNav 抛异常 / 无 ttuId 都算
  /// "做过了"，防止每次 Sasayaki mount 事件都反复触发恢复。
  bool _didRestorePos = false;

  /// 恢复需要两次 mount（第一次 current section，第二次跳完 savedSection）。
  /// 第一次读 Isar 时把 saved pos 暂存这里，第二次 mount 匹配 section 时
  /// consume。同段直接恢复时也临时设一下，`_finishRestore` 会立即清掉。
  ReaderViewportPos? _pendingRestorePos;

  /// 恢复流程进行中（requestSectionNav → 等 mount → scrollToNormOffset）。
  /// 此期间 `_handleCueCrossChapter` 必须拒绝 Follow audio 的跨章跳转，
  /// 否则音频 cue 推着 reader 往播放位置跑，恢复目标章就被覆盖。
  bool _restoreInFlight = false;

  Completer<bool>? _scrollToNormOffsetCompleter;
  Completer<bool>? _viewportStableCompleter;
  int _restoreToken = 0;
  int _restoreTargetSection = -1;
  int _restoreTargetOffset = -1;

  // ── 窗口尺寸变化时保持阅读位置 ──────────────────────────────────────
  Timer? _metricsDebounce;

  /// 生命周期 pause→resume 过渡期间为 true，屏蔽 didChangeMetrics 的位置
  /// 捕获和恢复（此时 viewport 尺寸不稳定，拿到的 offset 不可信）。
  bool _lifecycleTransition = false;
  Timer? _lifecycleResumeTimer;
  int _lifecycleResumeToken = 0;

  /// 最近一次 _completeNavRestore 的时间戳。用于在 sectionChanged(auto=false)
  /// 中过滤紧接程序化跳章后 ttu 推出的 settle 事件，避免误触 follow auto-off。
  DateTime? _lastNavRestoreTime;

  /// WebView 内容就绪（位置恢复完成或确认无需恢复）之前为 false，
  /// 用主题色遮罩盖住 WebView 避免先显示封面/第一章再跳转。
  bool _readerContentReady = false;

  bool _onLoadStopRunning = false;

  /// initState 预读的阅读位置（Isar），onLoadStop 直接消费，省掉异步查询。
  ReaderPosition? _preloadedPos;

  String? _lastAppThemeSignature;
  String? _lastFloatingLyricStyleKey;
  bool _floatingLyricStyleSyncScheduled = false;

  // ── 媒体通知栏（状态栏播放控制） ───────────────────────────────────────────
  StreamSubscription<void>? _notifPlaySub;
  StreamSubscription<void>? _notifSkipNextSub;
  StreamSubscription<void>? _notifSkipPrevSub;

  ReadingTimeTracker? _readingTimeTracker;

  @override
  void initState() {
    super.initState();
    _readingTimeTracker = ReadingTimeTracker(appModelNoUpdate.database);
    _readingTimeTracker!.start();
    debugPrint('[hibiki-reader-lifecycle] initState ${identityHashCode(this)}');
    WidgetsBinding.instance.addObserver(this);
    appModelNoUpdate.addListener(_onAppModelChanged);
    _applyVolumeKeyIntercept();
    _registerFloatingLyricHandlers();
    // 同步预判：Isar 查 Audiobook / SrtBook 记录。命中就让 WebView 首帧
    // 起就带底部 56+padding 槽位，避免异步 load 完再翻转 bottom 触发 ttu
    // reflow 把首页文字往上抬。
    _detectAudioSlotAsync().then((hasSlot) {
      if (mounted) {
        setState(() {
          _hasAudioSlot = hasSlot;
          _audioSlotResolved = true;
        });
      }
    }, onError: (_) {
      if (mounted) setState(() => _audioSlotResolved = true);
    });
    _preloadReaderPos();
    // 异步检查是否有挂载有声书
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAudiobookIfAvailable();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleFloatingLyricStyleSync(force: true);
    _captureStableInsets();
  }

  void _captureStableInsets() {
    if (!_stableInsetsCaptured) {
      final vp = MediaQuery.of(context).viewPadding;
      _stableTopInset = vp.top;
      _stableBottomInset = vp.bottom;
      _stableInsetsCaptured = true;
    }
  }

  /// 异步判定当前书是否有已配置音频的 Audiobook 或 SrtBook 记录。
  /// 只看记录 + 音频路径字段是否非空；不解析文件是否真实存在（那步会触发
  /// 文件 I/O）。极端情况下路径失效会让预留槽位比实际播放栏多出现几毫秒
  /// 就消失 —— 比每次开书文字跳一下更可接受。
  Future<bool> _detectAudioSlotAsync() async {
    // initState 阶段不能 ref.watch，走 appModelNoUpdate（ref.read）取 DB。
    final database = appModelNoUpdate.database;
    final String? bookUid = widget.item?.uniqueKey;
    final abRepo = AudiobookRepository(database);
    if (bookUid != null) {
      Audiobook? ab = await abRepo.findByBookUid(bookUid);
      if (ab == null) {
        final int? ttuId = _extractTtuBookId();
        if (ttuId != null && ttuId > 0) {
          ab = await abRepo.findByTtuBookId(ttuId);
        }
      }
      if (ab != null) {
        return (ab.audioPaths?.isNotEmpty ?? false) ||
            (ab.audioRoot != null && ab.audioRoot!.isNotEmpty);
      }
    }
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) {
      return false;
    }
    final SrtBook? b = await SrtBookRepository(database).findByTtuBookId(ttuId);
    if (b != null) {
      return (b.audioPaths?.isNotEmpty ?? false) ||
          (b.audioRoot != null && b.audioRoot!.isNotEmpty);
    }
    return false;
  }

  /// initState 预读阅读位置，和 _detectAudioSlotAsync 并行。
  Future<void> _preloadReaderPos() async {
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) return;
    try {
      _preloadedPos = await ReaderPositionRepository(appModelNoUpdate.database)
          .findByTtuBookId(ttuId);
      debugPrint(
        '[hibiki-reader-pos] preloaded ttuId=$ttuId '
        's=${_preloadedPos?.sectionIndex}/o=${_preloadedPos?.normCharOffset}',
      );
    } catch (e) {
      debugPrint('[hibiki-reader-pos] preload err: $e');
    }
  }

  @override
  void dispose() {
    debugPrint('[hibiki-reader-lifecycle] dispose ${identityHashCode(this)}');
    _readingTimeTracker?.dispose();
    VolumeKeyChannel.instance.setHandlers();
    VolumeKeyChannel.instance.setInterceptEnabled(false);
    FloatingLyricChannel.clearEventHandlers();
    _navRestoreTimeout?.cancel();
    _readerRestoreNavTimeout?.cancel();
    _metricsDebounce?.cancel();
    _lifecycleResumeTimer?.cancel();
    if (_scrollToNormOffsetCompleter != null &&
        !_scrollToNormOffsetCompleter!.isCompleted) {
      _scrollToNormOffsetCompleter!.complete(false);
    }
    if (_viewportStableCompleter != null &&
        !_viewportStableCompleter!.isCompleted) {
      _viewportStableCompleter!.complete(false);
    }
    // 在 WebView 销毁前同步读一次当前视口位置（fire-and-forget 写 Isar），
    // 兜住 JS 侧 500ms scroll-debounce 窗内关书导致的保存丢失。
    // unawaited 是有意的：dispose 不能 async，Isar 写不依赖 UI 线程，
    // Future 在 widget 销毁后仍能跑完。
    _flushReaderPosOnDispose();
    _notifPlaySub?.cancel();
    _notifSkipNextSub?.cancel();
    _notifSkipPrevSub?.cancel();
    appModelNoUpdate.audioHandler?.clearNotification();
    appModelNoUpdate.removeListener(_onAppModelChanged);
    if (appModelNoUpdate.showFloatingLyric) {
      FloatingLyricChannel.hide();
    }
    _audiobookController?.removeListener(_onCueChanged);
    _audiobookController?.removeListener(_onMediaNotificationUpdate);
    _audiobookController?.dispose();
    _barThemeNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _registerFloatingLyricHandlers() {
    FloatingLyricChannel.setEventHandlers(
      onLookupText: _onFloatingLyricLookup,
      onPreviousCue: () {
        final AudiobookPlayerController? controller = _audiobookController;
        if (controller != null) {
          unawaited(controller.skipToPrevCue());
        }
      },
      onPlayPause: () {
        final AudiobookPlayerController? controller = _audiobookController;
        if (controller != null) {
          unawaited(controller.togglePlayPause());
        }
      },
      onNextCue: () {
        final AudiobookPlayerController? controller = _audiobookController;
        if (controller != null) {
          unawaited(controller.skipToNextCue());
        }
      },
      onClose: () {
        unawaited(appModelNoUpdate.setShowFloatingLyric(false));
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  void _onAppModelChanged() {
    _scheduleFloatingLyricStyleSync(force: true);
  }

  void _onFloatingLyricLookup(String text, int index) {
    if (!mounted || text.trim().isEmpty) return;
    final int safeIndex = index.clamp(0, text.length - 1).toInt();
    final String searchTerm = appModel.targetLanguage
        .getSearchTermFromIndex(text: text, index: safeIndex)
        .trim();
    if (searchTerm.isEmpty) return;
    unawaited(FloatingLyricChannel.highlight(
      start: safeIndex,
      length: appModel.targetLanguage.getGuessHighlightLength(
        searchTerm: searchTerm,
      ),
    ));
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    final Size size = mediaQuery.size;
    final double anchorY = math.max(
      mediaQuery.padding.top + 12,
      size.height * 0.10,
    );
    final Rect selectionRect = Rect.fromCenter(
      center: Offset(size.width / 2, anchorY),
      width: 1,
      height: 1,
    );
    unawaited(searchDictionaryResult(
      searchTerm: searchTerm,
      selectionRect: selectionRect,
    ));
  }

  Future<void> _syncFloatingLyricOverlay() async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (!mounted || controller == null || !appModel.showFloatingLyric) return;
    await _syncFloatingLyricLabels();
    await _syncFloatingLyricStyle();
    final bool shown = await FloatingLyricChannel.show();
    if (!shown) return;
    await FloatingLyricChannel.setPlaybackState(
      playing: controller.isPlaying,
    );
    final AudioCue? cue = controller.currentCue;
    if (cue != null) {
      await FloatingLyricChannel.updateText(cue.text);
    }
  }

  Future<void> _syncFloatingLyricLabels() {
    return FloatingLyricChannel.updateLabels(
      previous: t.floating_lyric_previous,
      playPause: t.floating_lyric_play_pause,
      next: t.floating_lyric_next,
      lock: t.floating_lyric_lock,
      unlock: t.floating_lyric_unlock,
      close: t.floating_lyric_close,
    );
  }

  Future<void> _syncFloatingLyricStyle() {
    if (!mounted || !appModel.showFloatingLyric) {
      return Future<void>.value();
    }
    final ThemeData theme = _effectiveFloatingLyricTheme();
    final double fontSize = _floatingLyricFontSize();
    _lastFloatingLyricStyleKey = _floatingLyricStyleKey(theme, fontSize);
    final ColorScheme colors = theme.colorScheme;
    final Brightness brightness = colors.brightness;
    final Color surface = colors.surface;
    final Color onSurface = colors.onSurface;
    final Color primary = colors.primary;
    final Color buttonBg = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    return FloatingLyricChannel.updateStyle(
      fontSize: fontSize,
      textColor: onSurface.toARGB32(),
      bgColor: surface.withValues(alpha: 0.92).toARGB32(),
      buttonTextColor: onSurface.toARGB32(),
      buttonBgColor: buttonBg.toARGB32(),
      highlightColor: primary.withValues(alpha: 0.34).toARGB32(),
      activeColor: primary.toARGB32(),
    );
  }

  /// Fire-and-forget：读一次视口位置并写库。WebView 可能已开始销毁，
  /// evaluateJavascript 抛异常就吞掉。
  ThemeData _effectiveFloatingLyricTheme() {
    return appModel.overrideDictionaryTheme ??
        (appModel.isDarkMode ? appModel.darkTheme : appModel.theme);
  }

  double _floatingLyricFontSize() {
    return appModel.floatingLyricFontSize.clamp(8, 64).toDouble();
  }

  String _floatingLyricStyleKey(ThemeData theme, double fontSize) {
    final ColorScheme colors = theme.colorScheme;
    return <Object>[
      fontSize.toStringAsFixed(2),
      colors.brightness.name,
      colors.surface.toARGB32(),
      colors.onSurface.toARGB32(),
      colors.primary.toARGB32(),
    ].join(':');
  }

  void _scheduleFloatingLyricStyleSync({bool force = false}) {
    if (!mounted || !appModel.showFloatingLyric) return;
    final ThemeData theme = _effectiveFloatingLyricTheme();
    final String styleKey = _floatingLyricStyleKey(
      theme,
      _floatingLyricFontSize(),
    );
    if (!force && styleKey == _lastFloatingLyricStyleKey) return;
    if (_floatingLyricStyleSyncScheduled) return;
    _floatingLyricStyleSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _floatingLyricStyleSyncScheduled = false;
      if (!mounted) return;
      unawaited(_syncFloatingLyricStyle());
    });
  }

  void _flushReaderPosOnDispose() {
    if (!_controllerInitialised) return;
    if (_restoreInFlight) return;
    final InAppWebViewController controller = _controller;
    Future<void>.microtask(() async {
      try {
        final ReaderViewportPos? pos =
            await AudiobookBridge.getViewportNormOffset(controller);
        if (pos == null) return;
        await _persistReaderPos(
          section: pos.section,
          offset: pos.offset,
          from: 'dispose',
        );
      } catch (e) {
        debugPrint('[hibiki-reader-pos] dispose flush err: $e');
      }
    });
  }

  /// 把位置写进 Isar。同 section+offset 则跳过，避免重复 writeTxn。
  Future<void> _persistReaderPos({
    required int section,
    required int offset,
    required String from,
  }) async {
    if (section < 0 || offset < 0) {
      debugPrint(
          '[hibiki-reader-pos] persist skip: negative s=$section o=$offset');
      return;
    }
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) {
      debugPrint('[hibiki-reader-pos] persist skip: no ttuId');
      return;
    }
    if (_lastSavedPos?.section == section && _lastSavedPos?.offset == offset) {
      return;
    }
    _lastSavedPos = ReaderViewportPos(section: section, offset: offset);
    try {
      final ReaderPositionRepository repo =
          ReaderPositionRepository(appModelNoUpdate.database);
      await repo.save(
        ttuBookId: ttuId,
        sectionIndex: section,
        normCharOffset: offset,
      );
      debugPrint(
        '[hibiki-reader-pos] save($from) ttuId=$ttuId s=$section o=$offset',
      );
    } catch (e) {
      debugPrint('[hibiki-reader-pos] save err: $e');
    }
  }

  Future<void> _persistReaderPosForCue(AudioCue? cue, String from) async {
    if (cue == null) return;
    final SasayakiFragment? frag =
        SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag == null) return;
    await _persistReaderPos(
      section: frag.sectionIndex,
      offset: frag.normCharStart,
      from: from,
    );
  }

  /// Wire native volume-key interception according to the current setting.
  /// Called on page mount and whenever the toggle flips via the settings
  /// dialog so the key handler stops swallowing volume presses once the
  /// user turns the feature off.
  void _applyVolumeKeyIntercept() {
    final enabled = mediaSource.volumePageTurningEnabled;
    if (enabled) {
      VolumeKeyChannel.instance.setHandlers(
        onVolumeUp: _onVolumeKeyUp,
        onVolumeDown: _onVolumeKeyDown,
      );
    } else {
      VolumeKeyChannel.instance.setHandlers();
    }
    VolumeKeyChannel.instance.setInterceptEnabled(enabled);
  }

  void _onVolumeKeyUp() {
    if (!_controllerInitialised) return;
    if (isDictionaryShown) {
      clearDictionaryResult();
      unselectWebViewTextSelection(_controller);
      mediaSource.clearCurrentSentence();
      return;
    }
    _autoOffFollowOnManualTurn();
    unselectWebViewTextSelection(_controller);
    _controller.evaluateJavascript(source: leftArrowSimulateJs);
  }

  void _onVolumeKeyDown() {
    if (!_controllerInitialised) return;
    if (isDictionaryShown) {
      clearDictionaryResult();
      unselectWebViewTextSelection(_controller);
      mediaSource.clearCurrentSentence();
      return;
    }
    _autoOffFollowOnManualTurn();
    unselectWebViewTextSelection(_controller);
    _controller.evaluateJavascript(source: rightArrowSimulateJs);
  }

  /// 所有显式手翻的 Follow auto-off 公共入口：音量键 / swipe 跨段 /
  /// ToC 点击都调这里。音量键在 ttu 连续滚动模式下 wheel 只滚不翻章，
  /// 不触发 sectionChanged，所以必须在 arrow simulate 之前主动调；
  /// swipe / ToC 则由 [_handleTtuSectionChanged] 的 auto=false 分支转发。
  /// 没这一层，按着音量键往下读，下一条 cue 会把 reader 拖回原位。
  /// 无有声书或 Follow=OFF 时直接跳过。
  void _autoOffFollowOnManualTurn() {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    if (!controller.followAudio.value) return;
    controller.setFollowAudio(false);
    if (mounted) {
      Fluttertoast.showToast(msg: t.follow_audio_paused);
    }
  }

  int? _knownTtuSectionCount() {
    final int? probedCount = _ttuSectionCount;
    if (probedCount != null && probedCount > 0) {
      return probedCount;
    }
    if (_tocLabels.isEmpty) {
      return null;
    }
    int highest = -1;
    for (final int index in _tocLabels.keys) {
      if (index > highest) highest = index;
    }
    return highest >= 0 ? highest + 1 : null;
  }

  bool _canNavigateToTtuSection(int sectionIndex) {
    if (sectionIndex < 0) {
      return false;
    }
    final int? count = _knownTtuSectionCount();
    return count == null || sectionIndex < count;
  }

  bool _dropStaleSectionNavigation(int sectionIndex, String from) {
    if (_canNavigateToTtuSection(sectionIndex)) {
      return false;
    }
    debugPrint(
      '[hibiki-audiobook] stale section navigation dropped: '
      'from=$from section=$sectionIndex count=${_knownTtuSectionCount()}',
    );
    if (_pendingNavSection == sectionIndex && mounted) {
      setState(() => _pendingNavSection = null);
    } else if (_pendingNavSection == sectionIndex) {
      _pendingNavSection = null;
    }
    if (_inFlightNavSection == sectionIndex) {
      _navRestoreTimeout?.cancel();
      _navRestoreTimeout = null;
      _inFlightNavSection = null;
    }
    if (_pendingRestorePos?.section == sectionIndex) {
      _pendingRestorePos = null;
      _restoreInFlight = false;
      _readerRestoreNavTimeout?.cancel();
      _readerRestoreNavTimeout = null;
      _readerRestoreNavAttempts = 0;
    }
    _audiobookController?.cancelChapterTransition();
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _readingTimeTracker?.stop();
      _lifecycleResumeTimer?.cancel();
      _lifecycleResumeTimer = null;
      _lifecycleResumeToken++;
      _lifecycleTransition = true;
      _metricsDebounce?.cancel();
      _preMetricsPos = null;
      if (_controllerInitialised && !_restoreInFlight) {
        AudiobookBridge.getViewportNormOffset(_controller).then((pos) {
          if (pos != null) {
            _persistReaderPos(
              section: pos.section,
              offset: pos.offset,
              from: 'lifecycle-pause',
            );
          }
        }).catchError((_) {});
      }
    } else if (state == AppLifecycleState.resumed) {
      _readingTimeTracker?.start();
      FocusScope.of(context).unfocus();
      _focusNode.requestFocus();
      _lifecycleResumeTimer?.cancel();
      final int myToken = ++_lifecycleResumeToken;
      unawaited(_restoreAfterLifecycleResume(myToken));
    }
  }

  Future<void> _restoreAfterLifecycleResume(int token) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
    if (!mounted || token != _lifecycleResumeToken) return;
    _lifecycleResumeTimer = Timer(const Duration(milliseconds: 400), () async {
      _lifecycleResumeTimer = null;
      if (!mounted || token != _lifecycleResumeToken) return;
      _lifecycleTransition = false;
      final ReaderViewportPos? target = _lastSavedPos;
      if (target != null &&
          _controllerInitialised &&
          !_restoreInFlight &&
          target.section >= 0 &&
          target.offset >= 0) {
        ReaderViewportPos? current;
        try {
          current = await AudiobookBridge.getViewportNormOffset(_controller);
        } catch (_) {}
        if (current != null &&
            current.section == target.section &&
            (current.offset - target.offset).abs() <
                _resumeRestoreOffsetTolerance) {
          return;
        }
        AudiobookBridge.scrollToNormOffset(
          _controller,
          section: target.section,
          offset: target.offset,
        ).catchError((_) {});
      }
    });
  }

  @override
  ReaderViewportPos? _preMetricsPos;

  Size? _metricsScreenSize;

  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!_controllerInitialised) return;
    if (!_readerContentReady) return;
    if (_restoreInFlight) return;
    if (_lifecycleTransition) return;
    if (dictionaryPopupShown) return;
    final currentSize = MediaQuery.of(context).size;
    if (_metricsDebounce == null || !_metricsDebounce!.isActive) {
      _metricsScreenSize = currentSize;
      AudiobookBridge.getViewportNormOffset(_controller).then((pos) {
        if (pos != null) _preMetricsPos = pos;
      });
    }
    _metricsDebounce?.cancel();
    _metricsDebounce = Timer(const Duration(milliseconds: 600), () async {
      if (dictionaryPopupShown) {
        _preMetricsPos = null;
        _metricsScreenSize = null;
        return;
      }
      final sizeNow = MediaQuery.of(context).size;
      final sizeChanged = _metricsScreenSize != null &&
          (_metricsScreenSize!.width != sizeNow.width ||
              _metricsScreenSize!.height != sizeNow.height);
      _metricsScreenSize = null;
      if (!sizeChanged) {
        _preMetricsPos = null;
        return;
      }
      final pos = _preMetricsPos ?? _lastSavedPos;
      _preMetricsPos = null;
      if (pos == null || pos.section < 0 || pos.offset < 0) return;
      try {
        await AudiobookBridge.scrollToNormOffset(
          _controller,
          section: pos.section,
          offset: pos.offset,
        );
      } catch (e) {
        debugPrint('[hibiki-reader-pos] metrics restore err: $e');
      }
    });
  }

  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    _isRecursiveSearching = true;
    if (appModel.isMediaOpen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await Future.delayed(const Duration(milliseconds: 5), () {});
    }
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    if (appModel.isMediaOpen) {
      await Future.delayed(const Duration(milliseconds: 5), () {});
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _isRecursiveSearching = false;

    _focusNode.requestFocus();
  }

  @override
  Future<int> searchDictionaryResult({
    required String searchTerm,
    required Rect selectionRect,
    int? overrideMaximumTerms,
  }) async {
    if (!dictionaryPopupShown) {
      final ctrl = _audiobookController;
      if (ctrl != null && ctrl.isPlaying) {
        _wasPlayingBeforeLookup = true;
        await ctrl.pause();
      }
    }
    return super.searchDictionaryResult(
      searchTerm: searchTerm,
      selectionRect: selectionRect,
      overrideMaximumTerms: overrideMaximumTerms,
    );
  }

  /// 根据段落文本和点击位置，在当前章节 cues 中找到覆盖该位置的 cue。
  AudioCue? _findCueForParagraphIndex(String paragraph, int index) {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null) return null;
    final List<AudioCue> cues = ctrl.chapterCuesSnapshot;
    if (cues.isEmpty) return null;

    // 逐 cue 尝试在 paragraph 中按顺序定位，找到包含 index 的那个
    int searchFrom = 0;
    for (final AudioCue cue in cues) {
      if (cue.text.isEmpty) continue;
      final int pos = paragraph.indexOf(cue.text, searchFrom);
      if (pos < 0) continue;
      final int end = pos + cue.text.length;
      if (index >= pos && index < end) {
        return cue;
      }
      searchFrom = pos + 1;
    }

    // 回退：找包含查词文字最近的 cue（如 paragraph 与 cue.text 不完全匹配时）
    final String needle = index < paragraph.length
        ? paragraph.substring(index, (index + 4).clamp(0, paragraph.length))
        : '';
    if (needle.isNotEmpty) {
      for (final AudioCue cue in cues) {
        if (cue.text.contains(needle)) return cue;
      }
    }
    return null;
  }

  @override
  Widget? buildPopupAudioControls() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null || ctrl.chapterCueCount == 0) return null;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (BuildContext context, _) {
        final AudioCue? cueA = _lookupCue;
        final bool hasLookupCue = cueA != null;
        final ThemeData theme = Theme.of(context);
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
              // 左：复读查词句（A），读完暂停
              IconButton(
                icon: const Icon(Icons.replay, size: 20),
                onPressed: hasLookupCue ? () => ctrl.playCueOnce(cueA) : null,
                tooltip: t.repeat_cue,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 12),
              // 中：继续/暂停当前播放位置（B）
              IconButton(
                icon: Icon(
                  ctrl.isPlaying ? Icons.pause : Icons.play_arrow,
                  size: 24,
                ),
                onPressed: () => ctrl.togglePlayPause(),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 12),
              // 右：从查词句（A）开始连续播放
              IconButton(
                icon: const Icon(Icons.play_circle_outline, size: 20),
                onPressed:
                    hasLookupCue ? () => ctrl.playCueAndContinue(cueA) : null,
                tooltip: t.play_from_cue,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Future<bool> onMineFromPopup(Map<String, String> fields) async {
    final currentSentence = appModel.getCurrentSentence();
    final repo = ref.read(ankiRepositoryProvider);

    String? sasayakiAudioPath;
    final controller = _audiobookController;
    final AudioCue? cue = _lookupCue ?? controller?.currentCue;
    if (cue != null && controller != null && controller.audioFiles.isNotEmpty) {
      try {
        if (cue.audioFileIndex < controller.audioFiles.length) {
          final inputFile = controller.audioFiles[cue.audioFileIndex];
          final outputPath =
              '${Directory.systemTemp.path}/mine_sentence_audio.m4a';
          sasayakiAudioPath = await TtsChannel.instance.extractAudioSegment(
            inputPath: inputFile.path,
            startMs: cue.startMs,
            endMs: cue.endMs,
            outputPath: outputPath,
          );
        }
      } catch (e) {
        debugPrint('[hibiki-mine] sentence audio extract failed: $e');
      }
    }

    final miningContext = AnkiMiningContext(
      sentence: currentSentence.text.trim(),
      documentTitle: widget.item?.title,
      sasayakiAudioPath: sasayakiAudioPath,
    );

    final result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );

    switch (result) {
      case MineResult.success:
        final settings = await repo.loadSettings();
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

  /// Hide the dictionary and dispose of the current result.
  @override
  void clearDictionaryResult() async {
    super.clearDictionaryResult();
    _lookupCue = null;
    ReaderTtuSource.instance.clearPendingSentenceAudio();
    unselectWebViewTextSelection(_controller);
    if (_wasPlayingBeforeLookup) {
      _wasPlayingBeforeLookup = false;
      _audiobookController?.play();
    }
  }

  @override
  void onCreatorClose() {
    _focusNode.unfocus();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Orientation orientation = MediaQuery.of(context).orientation;
    if (orientation != lastOrientation) {
      if (_controllerInitialised) {
        clearDictionaryResult();
      }
      lastOrientation = orientation;
      final vp = MediaQuery.of(context).viewPadding;
      _stableTopInset = vp.top;
      _stableBottomInset = vp.bottom;
    }

    final currentThemeSignature = _appThemeSignature();
    if (_lastAppThemeSignature != null &&
        _lastAppThemeSignature != currentThemeSignature &&
        _controllerInitialised) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_applyAppThemeToTtuReader());
        }
      });
    }
    _lastAppThemeSignature = currentThemeSignature;
    _scheduleFloatingLyricStyleSync();

    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onFocusChange: (value) {
        if (mediaSource.volumePageTurningEnabled &&
            (ModalRoute.of(context)?.isCurrent ?? false) &&
            !_isRecursiveSearching) {
          _focusNode.requestFocus();
        }
      },
      canRequestFocus: true,
      // Android volume keys don't reach Flutter's key pipeline reliably
      // (AudioManager consumes them first), so page-turn goes through
      // VolumeKeyChannel / MainActivity.dispatchKeyEvent instead. This
      // Focus is kept for other future keyboard bindings (e.g. desktop).
      onKey: (data, event) => KeyEventResult.ignored,
      child: WillPopScope(
        onWillPop: onWillPop,
        child: Scaffold(
          backgroundColor: _ttuThemeFlutterColor(),
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: <Widget>[
              Positioned.fill(
                top: _readerTopOffset,
                bottom: _readerBottomReserve,
                child: buildBody(),
              ),
              _buildTopProgressBar(),
              buildDictionary(),
              buildAudiobookBar(),
              buildAudiobookImportButton(),
              buildReaderSettingsFab(),
              if (!_readerContentReady)
                Positioned.fill(
                  top: _stableTopInset,
                  child: ColoredBox(color: _ttuThemeFlutterColor()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildBody() {
    if (!_audioSlotResolved) return buildLoading();

    AsyncValue<LocalAssetsServer> server =
        ref.watch(ttuServerProvider(appModel.targetLanguage));

    return server.when(
      data: buildReaderArea,
      loading: buildLoading,
      error: (error, stack) => buildError(
        error: error,
        stack: stack,
        refresh: () {
          ref.invalidate(ttuServerProvider(appModel.targetLanguage));
        },
      ),
    );
  }

  ThemeData _themedWithSurface(ThemeData base, Color surface) {
    return buildTtuReaderChromeTheme(base: base, surface: surface);
  }

  String _appThemeSignature() {
    if (appModel.appThemeKey != 'custom-theme') {
      return appModel.appThemeKey;
    }
    return [
      appModel.appThemeKey,
      appModel.customThemeDark ? 'dark' : 'light',
      appModel.customThemeFontColor?.toARGB32().toRadixString(16) ?? 'default',
      appModel.customThemeBackgroundColor?.toARGB32().toRadixString(16) ??
          'default',
      appModel.customThemeSelectionColor?.toARGB32().toRadixString(16) ??
          'default',
      appModel.customThemePrimaryColor?.toARGB32().toRadixString(16) ??
          'default',
      appModel.customThemeSecondaryColor?.toARGB32().toRadixString(16) ??
          'default',
      appModel.customThemeTertiaryColor?.toARGB32().toRadixString(16) ??
          'default',
      appModel.customThemeContainerColor?.toARGB32().toRadixString(16) ??
          'default',
    ].join(':');
  }

  Future<void> _applyAppThemeToTtuReader() async {
    final String themeKey = appModel.appThemeKey;
    final Color bgColor = _ttuThemeFlutterColor();
    final String bgHex =
        '#${bgColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    final String customThemesJson = jsonEncode({
      'custom-theme': buildTtuCustomThemeDefinition(
        dark: appModel.customThemeDark,
        fontColor: appModel.customThemeFontColor,
        backgroundColor: appModel.customThemeBackgroundColor,
        selectionColor: appModel.customThemeSelectionColor,
      ),
    });
    final String customThemesJsLiteral = jsonEncode(customThemesJson);
    final String themeKeyJsLiteral = jsonEncode(themeKey);
    final String initialBgCssJsLiteral = jsonEncode(
      ':root,html,body{background-color:$bgHex!important}',
    );
    final List<String> cmds = [
      'var s=document.getElementById("hibiki-initial-bg");if(s)s.textContent=$initialBgCssJsLiteral',
      'window.localStorage.setItem("customThemes",$customThemesJsLiteral)',
      '(function(){try{if(window.__ttuReaderSettings){window.__ttuReaderSettings.set("customThemes",JSON.parse($customThemesJsLiteral));window.__ttuReaderSettings.set("theme",$themeKeyJsLiteral);}}catch(e){}})()',
    ];
    await _controller.evaluateJavascript(source: cmds.join(';'));
    if (mediaSource.adaptTtuTheme) {
      await setDictionaryColors();
    }
  }

  Future<void> setDictionaryColors() async {
    if (!mounted) return;
    final app = appModelNoUpdate;
    String currentTheme = (await _controller.evaluateJavascript(
            source: 'window.localStorage.getItem("theme")'))
        .toString();
    if (!mounted) return;
    switch (currentTheme) {
      case 'light-theme':
        final c = Color.fromRGBO(249, 249, 249, 1);
        app.setOverrideDictionaryTheme(_themedWithSurface(app.theme, c));
        app.setOverrideDictionaryColor(
            c.withValues(alpha: dictionaryEntryOpacity));
        break;
      case 'ecru-theme':
        final c = Color.fromRGBO(247, 246, 235, 1);
        app.setOverrideDictionaryTheme(_themedWithSurface(app.theme, c));
        app.setOverrideDictionaryColor(
            c.withValues(alpha: dictionaryEntryOpacity));
        break;
      case 'water-theme':
        final c = Color.fromRGBO(223, 236, 244, 1);
        app.setOverrideDictionaryTheme(_themedWithSurface(app.theme, c));
        app.setOverrideDictionaryColor(
            c.withValues(alpha: dictionaryEntryOpacity));
        break;
      case 'gray-theme':
        final c = Color.fromRGBO(35, 39, 42, 1);
        app.setOverrideDictionaryTheme(_themedWithSurface(app.darkTheme, c));
        app.setOverrideDictionaryColor(
            c.withValues(alpha: dictionaryEntryOpacity));
        break;
      case 'dark-theme':
        final c = Color.fromRGBO(18, 18, 18, 1);
        app.setOverrideDictionaryTheme(_themedWithSurface(app.darkTheme, c));
        app.setOverrideDictionaryColor(
            c.withValues(alpha: dictionaryEntryOpacity));
        break;
      case 'black-theme':
        final c = Color.fromRGBO(16, 16, 16, 1);
        app.setOverrideDictionaryTheme(_themedWithSurface(app.darkTheme, c));
        app.setOverrideDictionaryColor(
            c.withValues(alpha: dictionaryEntryOpacity));
        break;
      case 'custom-theme':
        if (app.customThemeDark) {
          final c = app.customThemeBackgroundColor ??
              const Color.fromRGBO(35, 39, 42, 1);
          app.setOverrideDictionaryTheme(_themedWithSurface(app.darkTheme, c));
          app.setOverrideDictionaryColor(
              c.withValues(alpha: dictionaryEntryOpacity));
        } else {
          final c = app.customThemeBackgroundColor ??
              const Color.fromRGBO(249, 249, 249, 1);
          app.setOverrideDictionaryTheme(_themedWithSurface(app.theme, c));
          app.setOverrideDictionaryColor(
              c.withValues(alpha: dictionaryEntryOpacity));
        }
        break;
    }

    _barThemeNotifier.value = app.overrideDictionaryTheme;
    _scheduleFloatingLyricStyleSync(force: true);

    if (mounted) {
      clearDictionaryResult();
      setState(() {});
    }
  }

  String sanitizeWebViewTextSelection(String? text) {
    if (text == null) {
      return '';
    }

    text = text.replaceAll('\\n', '\n');
    text = text.trim();
    return text;
  }

  Future<String> getWebViewTextSelection(
      InAppWebViewController webViewController) async {
    String? selectedText = await webViewController.getSelectedText();
    selectedText = sanitizeWebViewTextSelection(selectedText);
    return selectedText;
  }

  late final bool _ttuVersionChanged = mediaSource.currentTtuInternalVersion !=
      ReaderTtuSource.ttuInternalVersion;

  CacheMode get cacheMode {
    return _ttuVersionChanged
        ? CacheMode.LOAD_NO_CACHE
        : CacheMode.LOAD_CACHE_ELSE_NETWORK;
  }

  String _buildTtuCacheRefreshJs() {
    return '''
(function() {
  var key = 'hibiki_ttu_cache_refresh_${ReaderTtuSource.ttuInternalVersion}';
  var alreadyDone = false;
  try { alreadyDone = window.sessionStorage.getItem(key) === '1'; } catch (_) {}

  if (alreadyDone) {
    console.log(JSON.stringify({"hibiki-message-type":"ttuCacheRefreshDone"}));
    return;
  }

  (window.caches
    ? caches.keys().then(function(keys) {
        return Promise.all(keys.map(function(k) { return caches.delete(k); }));
      })
    : Promise.resolve()
  ).then(function() {
    try { window.sessionStorage.setItem(key, '1'); } catch (_) {}
    console.log(JSON.stringify({"hibiki-message-type":"ttuCacheRefreshDone"}));
  });
})();
''';
  }

  createFileFromBase64(String base64Content) async {
    var bytes = base64Decode(base64Content.replaceAll('\n', ''));
    DocumentFileSavePlus().saveFile(
      bytes.buffer.asUint8List(),
      _suggestedFilename,
      _mimeType,
    );
    Fluttertoast.showToast(msg: t.file_downloaded(name: _suggestedFilename));
  }

  String _buildApplySettingsJs() {
    final ReaderTtuSource src = ReaderTtuSource.instance;
    final fontCss = src.buildCustomFontCss();
    final hasCustomFonts = fontCss.fontFamily.isNotEmpty;
    final fontFamilyOne =
        hasCustomFonts ? '${fontCss.fontFamily}, serif' : 'serif';
    final fontFamilyTwo =
        hasCustomFonts ? '${fontCss.fontFamily}, sans-serif' : 'sans-serif';
    final hideFuriganaValue = src.ttuFuriganaMode == 'show' ? 0 : 1;
    final furiganaStyle =
        ReaderTtuSource.furiganaModeToStyle(src.ttuFuriganaMode);
    final cmds = [
      'window.localStorage.setItem("fontSize",${src.ttuFontSize})',
      'window.localStorage.setItem("lineHeight",${src.ttuLineHeight})',
      'window.localStorage.setItem("writingMode","${src.ttuWritingMode}")',
      'window.localStorage.setItem("viewMode","${src.ttuViewMode}")',
      'window.localStorage.setItem("theme","${appModel.appThemeKey}")',
      if (appModel.appThemeKey == 'custom-theme') _buildCustomThemeJs(),
      'window.localStorage.setItem("hideFurigana","$hideFuriganaValue")',
      'window.localStorage.setItem("furiganaStyle","$furiganaStyle")',
      'window.localStorage.setItem("textIndentation",${src.ttuTextIndentation})',
      'window.localStorage.setItem("firstDimensionMargin",${src.ttuFirstDimensionMargin})',
      'window.localStorage.setItem("pageMarginBottom",${_ttuPageMarginBottom()})',
      'window.localStorage.setItem("secondDimensionMaxValue",${src.ttuSecondDimensionMaxValue})',
      'window.localStorage.setItem("pageColumns",${src.ttuPageColumns})',
      'window.localStorage.setItem("enableVerticalFontKerning","${src.ttuEnableVerticalFontKerning ? 1 : 0}")',
      'window.localStorage.setItem("enableFontVPAL","${src.ttuEnableFontVPAL ? 1 : 0}")',
      'window.localStorage.setItem("verticalTextOrientation","${src.ttuVerticalTextOrientation}")',
      'window.localStorage.setItem("enableTextJustification","${src.ttuEnableTextJustification ? 1 : 0}")',
      'window.localStorage.setItem("prioritizeReaderStyles","${src.ttuPrioritizeReaderStyles ? 1 : 0}")',
      ReaderTtuSource.ttuStatisticsSettingsJs,
      'window.localStorage.setItem("fontFamilyGroupOne",${jsonEncode(fontFamilyOne)})',
      'window.localStorage.setItem("fontFamilyGroupTwo",${jsonEncode(fontFamilyTwo)})',
    ];
    return cmds.join(';');
  }

  /// 根据当前 ttu 主题返回 Flutter Color，用于 Scaffold 背景和遮罩。
  Color _ttuThemeFlutterColor() {
    switch (appModel.appThemeKey) {
      case 'light-theme':
        return const Color(0xFFF9F9F9);
      case 'ecru-theme':
        return const Color(0xFFF7F6EB);
      case 'water-theme':
        return const Color(0xFFDFECF4);
      case 'gray-theme':
        return const Color(0xFF23272A);
      case 'dark-theme':
        return const Color(0xFF121212);
      case 'black-theme':
        return const Color(0xFF101010);
      case 'custom-theme':
        return appModel.customThemeBackgroundColor ??
            (appModel.customThemeDark
                ? const Color(0xFF23272A)
                : const Color(0xFFFFFFFF));
      default:
        return const Color(0xFFF9F9F9);
    }
  }

  bool get _isDarkReaderTheme {
    switch (appModel.appThemeKey) {
      case 'gray-theme':
      case 'dark-theme':
      case 'black-theme':
        return true;
      case 'custom-theme':
        return appModel.customThemeDark;
      default:
        return false;
    }
  }

  Future<void> _refreshPageProgress() async {
    try {
      final Object? raw = await _controller.evaluateJavascript(source: '''
(function() {
  var el = document.querySelector('.book-content');
  if (!el) return null;
  var totalChars = (el.textContent || '').length;
  if (totalChars <= 0) return null;

  var settings = null;
  try {
    settings = window.__ttuReaderSettings && window.__ttuReaderSettings.get
      ? window.__ttuReaderSettings.get()
      : null;
  } catch (e) {}
  var writingMode = (settings && settings.writingMode) || getComputedStyle(el).writingMode || '';
  var viewMode = (settings && settings.viewMode) || '';
  var vertical = writingMode === 'vertical-rl';

  function ratio(pos, extent, viewport) {
    var maxScroll = extent - viewport;
    if (!isFinite(maxScroll) || maxScroll <= 0) return 0;
    var value = Math.abs(pos || 0) / maxScroll;
    if (!isFinite(value)) return 0;
    return Math.max(0, Math.min(1, value));
  }

  var progressRatio = 0;
  if (viewMode === 'continuous') {
    var doc = document.documentElement || {};
    var body = document.body || {};
    if (vertical) {
      progressRatio = ratio(
        window.scrollX || doc.scrollLeft || body.scrollLeft || 0,
        Math.max(doc.scrollWidth || 0, body.scrollWidth || 0, el.scrollWidth || 0),
        window.innerWidth || doc.clientWidth || el.clientWidth || 1
      );
    } else {
      progressRatio = ratio(
        window.scrollY || doc.scrollTop || body.scrollTop || 0,
        Math.max(doc.scrollHeight || 0, body.scrollHeight || 0, el.scrollHeight || 0),
        window.innerHeight || doc.clientHeight || el.clientHeight || 1
      );
    }
  } else {
    if (vertical) {
      progressRatio = ratio(el.scrollTop || 0, el.scrollHeight || 0, el.clientHeight || 1);
    } else {
      progressRatio = ratio(el.scrollLeft || 0, el.scrollWidth || 0, el.clientWidth || 1);
    }
  }
  var section = -1;
  try {
    section = typeof window.__ttuCurrentSection === 'function'
      ? window.__ttuCurrentSection()
      : -1;
  } catch (e) {}
  var currentChars = Math.round(progressRatio * totalChars);
  return JSON.stringify({c: currentChars, t: totalChars, s: section});
})()
''');
      if (raw == null || raw == 'null') return;
      final String str = raw is String ? raw : raw.toString();
      final Map<String, dynamic> json =
          Map<String, dynamic>.from(jsonDecode(str) as Map);
      final int? c = (json['c'] as num?)?.toInt();
      final int? t = (json['t'] as num?)?.toInt();
      final int? s = (json['s'] as num?)?.toInt();
      if (c != null && t != null && t > 0) {
        final (int, int)? progress = resolveTopReaderProgress(
          sectionChars: _readerProgressSectionChars(),
          sectionIndex: s ?? -1,
          sectionCurrentChars: c,
          sectionTotalChars: t,
        );
        if (progress == null) return;
        final int nextCurrent = progress.$1;
        final int nextTotal = progress.$2;
        if (nextCurrent != _progressCurrentChars ||
            nextTotal != _progressTotalChars) {
          setState(() {
            _progressCurrentChars = nextCurrent;
            _progressTotalChars = nextTotal;
          });
        }
      }
    } catch (_) {}
  }

  Widget _buildTopProgressBar() {
    if (!_showTopProgress) return const SizedBox.shrink();
    final int current = _progressCurrentChars!;
    final int total = _progressTotalChars!;
    final double pct = total > 0 ? current / total * 100 : 0;
    final String title = widget.item?.title ?? '';
    final bool dark = _isDarkReaderTheme;
    final Color fg = dark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);

    return Positioned(
      left: 0,
      right: 0,
      top: _stableTopInset,
      height: _topProgressBarHeight,
      child: ColoredBox(
        color: _ttuThemeFlutterColor(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 10, color: fg, height: 1.0),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$current / $total  ${pct.toStringAsFixed(2)}%',
                style: TextStyle(fontSize: 10, color: fg, height: 1.0),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 返回注入到 WebView document start 的 CSS，让背景色在任何 JS/CSS 加载前生效，
  /// 消除白屏闪烁。
  String _buildInitialBgCssJs() {
    final Color c = _ttuThemeFlutterColor();
    final String hex =
        '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    return '(function(){'
        'function appendStyle(e){'
        'var p=document.head||document.documentElement||document.body;'
        'if(p){p.appendChild(e);return;}'
        'document.addEventListener("DOMContentLoaded",function(){'
        '(document.head||document.documentElement||document.body).appendChild(e);'
        '},{once:true});'
        '}'
        'var s=document.createElement("style");'
        's.id="hibiki-initial-bg";'
        's.textContent=":root,html,body{background-color:$hex!important}";'
        'appendStyle(s);'
        'var h=document.createElement("style");'
        'h.id="hibiki-content-hide";'
        'h.textContent=":root,html,body{visibility:hidden!important}";'
        'appendStyle(h);'
        '})()';
  }

  void _markReaderContentReady() {
    if (!mounted) return;
    _metricsDebounce?.cancel();
    _preMetricsPos = null;
    unawaited(_clearJsRestoreFlag());
    unawaited(_revealAndUnmask());
  }

  Future<void> _revealAndUnmask() async {
    if (!mounted) return;
    final bool revealOk = await _removeInitialHideCss();
    if (!revealOk) {
      debugPrint(
          '[hibiki-reader-pos] CSS hide removal failed, unmasking anyway');
    }
    if (!_readerContentReady && mounted) {
      setState(() => _readerContentReady = true);
    }
  }

  Future<bool> _removeInitialHideCss() async {
    if (!_controllerInitialised || !mounted) return false;
    for (int i = 0; i < 3; i++) {
      try {
        final Object? result = await _controller.evaluateJavascript(
          source:
              '(function(){var e=document.getElementById("hibiki-content-hide");if(e){e.remove();return true}return false})()',
        );
        return result != null;
      } catch (e) {
        debugPrint(
            '[hibiki-reader-pos] removeInitialHideCss attempt $i err: $e');
        if (i < 2) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return false;
  }

  Future<void> _setJsRestoreFlag() async {
    if (!_controllerInitialised) return;
    _restoreToken++;
    try {
      await _controller.evaluateJavascript(
        source: 'window.__hoshiRestoreInFlight = true;',
      );
    } catch (_) {}
  }

  Future<void> _clearJsRestoreFlag() async {
    if (!_controllerInitialised) return;
    try {
      await _controller.evaluateJavascript(
        source: 'window.__hoshiRestoreInFlight = false;',
      );
    } catch (_) {}
  }

  String _buildCustomThemeJs() {
    return buildTtuCustomThemeJs(
      dark: appModel.customThemeDark,
      fontColor: appModel.customThemeFontColor,
      backgroundColor: appModel.customThemeBackgroundColor,
      selectionColor: appModel.customThemeSelectionColor,
    );
  }

  String _buildFontFaceCss() {
    return ReaderTtuSource.instance.buildCustomFontCss().fontFaces;
  }

  Widget buildReaderArea(LocalAssetsServer server) {
    final String fontFaceCss = _buildFontFaceCss();
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          widget.item?.mediaIdentifier ??
              'http://localhost:${server.boundPort}/manage.html',
        ),
      ),
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        UserScript(
          source: 'window.onerror=function(m,s,l,c,e){'
              'console.error("__HIBIKI_JS_ERROR__ "+m+" at "+s+":"+l+":"+c+(e&&e.stack?" stack="+e.stack:""));'
              'return false;};'
              'window.addEventListener("unhandledrejection",function(ev){'
              'var r=ev.reason;'
              'console.error("__HIBIKI_UNHANDLED_REJECTION__ "+(r&&r.stack?r.stack:String(r)));'
              '});',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        if (_ttuVersionChanged)
          UserScript(
            source: _buildTtuCacheRefreshJs(),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        UserScript(
          source:
              'if(!String.prototype.replaceAll){String.prototype.replaceAll=function(a,b){if(a instanceof RegExp){if(!a.global)throw new TypeError("replaceAll must be called with a global RegExp");return this.replace(a,b)}return this.split(a).join(b)}}',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: 'window.__hoshiManagesPosition = true;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: 'window.__hoshiRestoreInFlight = true;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _buildInitialBgCssJs(),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _buildApplySettingsJs(),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        if (fontFaceCss.isNotEmpty)
          UserScript(
            source: '(function(){'
                'function appendStyle(e){'
                'var p=document.head||document.documentElement||document.body;'
                'if(p){p.appendChild(e);return;}'
                'document.addEventListener("DOMContentLoaded",function(){'
                '(document.head||document.documentElement||document.body).appendChild(e);'
                '},{once:true});'
                '}'
                'var s=document.createElement("style");'
                's.id="hibiki-custom-fonts";'
                "s.textContent='${fontFaceCss.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', ' ')}';"
                'appendStyle(s);})()',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]),
      onPermissionRequest: (controller, origin) async {
        return PermissionResponse(
          action: PermissionResponseAction.GRANT,
        );
      },
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        mediaPlaybackRequiresUserGesture: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        javaScriptCanOpenWindowsAutomatically: true,
        useOnDownloadStart: true,
        verticalScrollbarThumbColor: Colors.transparent,
        verticalScrollbarTrackColor: Colors.transparent,
        horizontalScrollbarThumbColor: Colors.transparent,
        horizontalScrollbarTrackColor: Colors.transparent,
        scrollbarFadingEnabled: false,
        appCachePath: appModel.browserDirectory.path,
        cacheMode: cacheMode,
        supportMultipleWindows: true,
      ),
      contextMenu: contextMenu,
      onConsoleMessage: onConsoleMessage,
      onWebViewCreated: (controller) {
        _controller = controller;
        _controllerInitialised = true;

        controller.addJavaScriptHandler(
          handlerName: 'blobToBase64Handler',
          callback: (data) async {
            if (data.isNotEmpty) {
              final String base64Content = data[0];
              createFileFromBase64(base64Content);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'onTapLookup',
          callback: (data) async {
            if (data.isEmpty) return;
            final DateTime now = DateTime.now();
            if (lastTapLookupTime != null &&
                now.difference(lastTapLookupTime!) < tapLookupDebounce) {
              return;
            }
            lastTapLookupTime = now;
            try {
              final Map<String, dynamic> payload =
                  Map<String, dynamic>.from(data[0] as Map);
              await _processLookup(payload);
            } catch (e) {
              debugPrint('onTapLookup error: $e');
            }
          },
        );

        // JS 侧 `.book-content` scroll debounce 500ms 后调这里，把当前视口
        // 的 (sectionIndex, 章内 normCharOffset) 写进 Isar ReaderPosition。
        // JS 已经 debounce 过了，Dart 侧直接写，不再加层 debounce。
        controller.addJavaScriptHandler(
          handlerName: 'saveReaderPos',
          callback: (data) async {
            if (_restoreInFlight) {
              debugPrint(
                  '[hibiki-reader-pos] saveReaderPos BLOCKED by restoreInFlight');
              return;
            }
            if (data.isEmpty) return;
            try {
              final Map<String, dynamic> payload =
                  Map<String, dynamic>.from(data[0] as Map);
              final int? section = (payload['section'] as num?)?.toInt();
              final int? offset = (payload['offset'] as num?)?.toInt();
              debugPrint(
                  '[hibiki-reader-pos] saveReaderPos received s=$section o=$offset');
              if (section == null || offset == null) return;
              await _persistReaderPos(
                section: section,
                offset: offset,
                from: 'scroll',
              );
              unawaited(_refreshPageProgress());
            } catch (e) {
              debugPrint('[hibiki-reader-pos] saveReaderPos error: $e');
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'scrollToNormOffsetDone',
          callback: (data) {
            final bool ok =
                data.isNotEmpty && (data[0] as Map?)?['success'] == true;
            final Completer<bool>? c = _scrollToNormOffsetCompleter;
            if (c != null && !c.isCompleted) {
              c.complete(ok);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'viewportStable',
          callback: (data) {
            final Map<String, dynamic>? payload = data.isNotEmpty
                ? (data[0] as Map?)?.cast<String, dynamic>()
                : null;
            final int token = (payload?['token'] as num?)?.toInt() ?? -1;
            final bool success = payload?['success'] == true;
            final int sec = (payload?['section'] as num?)?.toInt() ?? -1;
            final int off = (payload?['offset'] as num?)?.toInt() ?? -1;
            debugPrint(
              '[hibiki-reader-pos] viewportStable token=$token '
              'expected=$_restoreToken success=$success '
              's=$sec o=$off target=s$_restoreTargetSection/o$_restoreTargetOffset',
            );
            if (token != _restoreToken) return;
            if (success &&
                (sec != _restoreTargetSection ||
                    (off - _restoreTargetOffset).abs() > 5)) {
              debugPrint(
                  '[hibiki-reader-pos] viewportStable section/offset mismatch, rejecting');
              return;
            }
            final Completer<bool>? c = _viewportStableCompleter;
            if (c != null && !c.isCompleted) {
              c.complete(success);
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'hibikiTtuBookmarkAdded',
          callback: (data) async {
            await _addCurrentViewportBookmark(from: 'ttu');
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'imageClicked',
          callback: (data) async {
            if (data.isEmpty) return;
            final String src = data[0] as String;
            if (src.isEmpty || !mounted) return;
            _showZoomableImage(src);
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'userSwipe',
          callback: (data) async {
            _autoOffFollowOnManualTurn();
          },
        );
      },
      onCreateWindow: (controller, createWindowRequest) async {
        showAppDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              insetPadding: Spacing.of(context).insets.all.big,
              contentPadding: EdgeInsets.zero,
              content: SizedBox(
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.height * (3 / 4),
                child: InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    supportZoom: false,
                    disableContextMenu: true,
                    allowFileAccessFromFileURLs: true,
                    allowUniversalAccessFromFileURLs: true,
                    mediaPlaybackRequiresUserGesture: false,
                    verticalScrollBarEnabled: false,
                    horizontalScrollBarEnabled: false,
                    javaScriptCanOpenWindowsAutomatically: true,
                    userAgent: 'random',
                    useOnDownloadStart: true,
                    verticalScrollbarThumbColor: Colors.transparent,
                    verticalScrollbarTrackColor: Colors.transparent,
                    horizontalScrollbarThumbColor: Colors.transparent,
                    horizontalScrollbarTrackColor: Colors.transparent,
                    scrollbarFadingEnabled: false,
                    appCachePath: appModel.browserDirectory.path,
                    cacheMode: cacheMode,
                    supportMultipleWindows: true,
                  ),
                  windowId: createWindowRequest.windowId,
                  onDownloadStartRequest: onDownloadStartRequest,
                  onCloseWindow: (controller) {
                    if (mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
              ),
            );
          },
        );
        return true;
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
      onLoadStop: (controller, uri) async {
        if (_onLoadStopRunning) return;
        _onLoadStopRunning = true;
        try {
          if (mediaSource.adaptTtuTheme) {
            setDictionaryColors();
          }

          debugPrint(
            '[hibiki-audiobook] onLoadStop uri=$uri '
            'ctrl=${_audiobookController != null} srtUid=$_srtBookUid',
          );
          _currentChapterHref = uri?.toString() ?? _currentChapterHref;

          final jsFuture = controller.evaluateJavascript(
            source: javascriptToExecute,
          );
          unawaited(_injectPrimarySelectionColor(controller));
          if (_audiobookController != null) {
            try {
              await Future.wait([
                jsFuture,
                _maybeInjectAudiobookBridge(controller, trigger: 'onLoadStop')
                    .timeout(const Duration(seconds: 10)),
              ]);
            } catch (e) {
              debugPrint('[hibiki-audiobook] onLoadStop parallel timeout: $e');
            }
          } else {
            await jsFuture;
            await _injectReaderViewportBridge(controller);
            if (!_didRestorePos) {
              try {
                await _bootstrapCurrentTtuSection(controller)
                    .timeout(const Duration(seconds: 5));
              } catch (e) {
                debugPrint(
                    '[hibiki-audiobook] onLoadStop ttuSection timeout: $e');
              }
              try {
                await _bootstrapRestoreReaderPos()
                    .timeout(const Duration(seconds: 5));
              } catch (e) {
                debugPrint(
                    '[hibiki-audiobook] onLoadStop restorePos timeout: $e');
              }
            }
          }
          Future.delayed(
              const Duration(milliseconds: 300), _focusNode.requestFocus);
          unawaited(_installTtuBookmarkBridge(controller));
          await HighlightBridge.inject(controller);
          unawaited(_applyHighlightsForCurrentSection());
        } finally {
          _onLoadStopRunning = false;
          if (!_restoreInFlight) _markReaderContentReady();
        }
      },
      onTitleChanged: (controller, title) async {
        await controller.evaluateJavascript(source: javascriptToExecute);
        unawaited(_injectPrimarySelectionColor(controller));
        await _injectReaderViewportBridge(controller);
        unawaited(_installTtuBookmarkBridge(controller));

        if (mediaSource.adaptTtuTheme) {
          setDictionaryColors();
        }

        debugPrint(
          '[hibiki-audiobook] onTitleChanged title=$title '
          'ctrl=${_audiobookController != null} srtUid=$_srtBookUid',
        );
        try {
          await _maybeInjectAudiobookBridge(controller,
                  trigger: 'onTitleChanged')
              .timeout(const Duration(seconds: 10));
        } catch (e) {
          debugPrint('[hibiki-audiobook] onTitleChanged bridge timeout: $e');
        }
      },
      onDownloadStartRequest: onDownloadStartRequest,
    );
  }

  String _suggestedFilename = '';
  String _mimeType = '';

  void onDownloadStartRequest(
      InAppWebViewController controller, DownloadStartRequest request) async {
    _mimeType = request.mimeType ?? _mimeType;

    _suggestedFilename = request.suggestedFilename ?? _suggestedFilename;

    await controller.evaluateJavascript(
        source: downloadFileJs.replaceAll(
            'blobUrlPlaceholder', request.url.toString()));
  }

  Future<void> selectTextOnwards({
    required int cursorX,
    required int cursorY,
    required int offsetIndex,
    required int length,
    required int whitespaceOffset,
    required bool isSpaceDelimited,
  }) async {
    _controller.setContextMenu(emptyContextMenu);
    await _controller.evaluateJavascript(
      source:
          'selectTextForTextLength($cursorX, $cursorY, $offsetIndex, $length, $whitespaceOffset, $isSpaceDelimited);',
    );
    _controller.setContextMenu(contextMenu);
  }

  void onConsoleMessage(
    InAppWebViewController controller,
    ConsoleMessage message,
  ) async {
    late Map<String, dynamic> messageJson;
    bool isJson = true;
    try {
      messageJson = jsonDecode(message.message);
    } catch (e) {
      isJson = false;
    }

    final String? msgType =
        isJson ? messageJson['hibiki-message-type'] as String? : null;

    // ERROR 级别不防抖，确保所有错误都被记录。
    // 防抖只过滤非错误的 ttu 原生 console 噪声。
    if (msgType == null && message.messageLevel != ConsoleMessageLevel.ERROR) {
      DateTime now = DateTime.now();
      if (lastMessageTime != null &&
          now.difference(lastMessageTime!) < consoleMessageDebounce) {
        return;
      }
      lastMessageTime = now;
    }

    if (!isJson) {
      if (message.messageLevel == ConsoleMessageLevel.ERROR) {
        ErrorLogService.instance.log(
          'WebView.console.error',
          message.message,
        );
        debugPrint('[hibiki-webview-error] ${message.message}');
      }
      debugPrint('[hibiki-webview] level=${message.messageLevel} '
          'msg=${message.message}');
      return;
    }

    switch (msgType) {
      case 'lookup':
        await _processLookup(messageJson);
        break;
      case 'seekToSentence':
        break;
      case 'sectionChanged':
        _handleTtuSectionChanged(messageJson);
        break;
      case 'sasayakiNavOk':
        // DOM 渲染完成，重试 cueMap 构建（sectionChanged 时可能太早）。
        final int? navSection = (messageJson['section'] as num?)?.toInt();
        if (navSection != null) {
          _lastSasayakiAppliedSection = -1;
          unawaited(_applySasayakiCuesForSection(navSection));
        }
        break;
      case 'sasayakiApplySkip':
        _lastSasayakiAppliedSection = -1;
        break;
      case 'sasayakiNavErr':
        final int? navSection = (messageJson['section'] as num?)?.toInt();
        final Object? error = messageJson['error'];
        if (navSection != null && error == 'section out of range') {
          _dropStaleSectionNavigation(navSection, 'webview-nav-err');
          break;
        }
        ErrorLogService.instance.log(
          'WebView.$msgType',
          error ?? message.message,
        );
        break;
      case 'ttuCacheRefreshDone':
        if (_ttuVersionChanged) {
          unawaited(mediaSource.setTtuInternalVersion().catchError((e) {
            debugPrint('[hibiki] setTtuInternalVersion failed: $e');
          }));
        }
        break;
      case 'alignToRectDiag':
        // ignore: avoid_print
        print('[hibiki-align] ${message.message}');
        break;
      default:
        if (msgType != null && msgType.toLowerCase().contains('err')) {
          ErrorLogService.instance.log(
            'WebView.$msgType',
            messageJson['error'] ?? message.message,
          );
        }
        // ignore: avoid_print
        print('[hibiki-audiobook-diag] ${message.message}');
        break;
    }
  }

  Future<void> _processLookup(Map<String, dynamic> payload) async {
    FocusScope.of(context).unfocus();
    _focusNode.requestFocus();

    int index = (payload['index'] as num).toInt();
    String text = (payload['text'] as String?) ?? '';
    int x = (payload['x'] as num).toInt();
    int y = (payload['y'] as num).toInt();

    final Rect selectionRect = Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1);

    text = text.replaceAll('\\n', '\n');

    if (text.isEmpty || index < 0 || index >= text.length) {
      clearDictionaryResult();
      mediaSource.clearCurrentSentence();
      return;
    }

    try {
      /// If we cut off at a lone surrogate, offset the index back by 1. The
      /// selection meant to select the index before
      RegExp loneSurrogate = RegExp(
        '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]',
      );
      if (index != 0 && text.substring(index).startsWith(loneSurrogate)) {
        index = index - 1;
      }

      bool isSpaceDelimited = appModel.targetLanguage.isSpaceDelimited;

      String searchTerm = appModel.targetLanguage.getSearchTermFromIndex(
        text: text,
        index: index,
      );
      int whitespaceOffset = searchTerm.length - searchTerm.trimLeft().length;

      int offsetIndex =
          appModel.targetLanguage.getStartingIndex(text: text, index: index) +
              whitespaceOffset;

      int length = appModel.targetLanguage.getGuessHighlightLength(
        searchTerm: searchTerm,
      );
      final int initialHighlightLength = length;

      if (mediaSource.highlightOnTap) {
        await selectTextOnwards(
          cursorX: x,
          cursorY: y,
          offsetIndex: offsetIndex,
          length: length,
          whitespaceOffset: whitespaceOffset,
          isSpaceDelimited: isSpaceDelimited,
        );
      }

      _lookupCue = _findCueForParagraphIndex(text, index);
      if (_lookupCue != null && _audiobookController != null) {
        ReaderTtuSource.instance.setPendingSentenceAudio(
          cue: _lookupCue!,
          audioFiles: _audiobookController!.audioFiles,
        );
      }

      searchDictionaryResult(
        searchTerm: searchTerm,
        selectionRect: selectionRect,
      ).then((_) async {
        final int finalLength = appModel.targetLanguage.getFinalHighlightLength(
          result: currentResult,
          searchTerm: searchTerm,
        );
        length = finalLength;

        if (mediaSource.highlightOnTap &&
            finalLength != initialHighlightLength &&
            !dictionaryPopupShown) {
          await selectTextOnwards(
            cursorX: x,
            cursorY: y,
            offsetIndex: offsetIndex,
            length: finalLength,
            whitespaceOffset: whitespaceOffset,
            isSpaceDelimited: isSpaceDelimited,
          );
        }

        JidoujishoTextSelection selection =
            appModel.targetLanguage.getSentenceFromParagraph(
          paragraph: text,
          index: index,
          startOffset: offsetIndex,
          endOffset: offsetIndex + length,
        );

        mediaSource.setCurrentSentence(
          selection: selection,
        );
      }).catchError((Object e) {
        debugPrint('_processLookup async error: $e');
        clearDictionaryResult();
        mediaSource.clearCurrentSentence();
      });
    } catch (e) {
      debugPrint('_processLookup error: $e');
      clearDictionaryResult();
    }
  }

  void _showZoomableImage(String src) {
    Widget imageWidget;
    if (src.startsWith('data:')) {
      final commaIdx = src.indexOf(',');
      if (commaIdx != -1) {
        final bytes = base64Decode(src.substring(commaIdx + 1));
        imageWidget = Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.broken_image_outlined,
            color: Colors.white54,
            size: 64,
          ),
        );
      } else {
        imageWidget = const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 64,
        );
      }
    } else {
      imageWidget = Image.network(
        src,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 64,
        ),
      );
    }

    showAppDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: Center(child: imageWidget),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> unselectWebViewTextSelection(
      InAppWebViewController webViewController) async {
    String source = '''
if (!window.getSelection().isCollapsed) {
  if (window.__hibikiRunWithScrollLock) {
    window.__hibikiRunWithScrollLock(function() {
      window.getSelection().removeAllRanges();
    });
  } else {
    window.getSelection().removeAllRanges();
  }
}
''';
    await webViewController.evaluateJavascript(source: source);
  }

  /// Get the default context menu for sources that make use of embedded web
  /// views.
  ContextMenu get contextMenu => ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: true,
        ),
        menuItems: [
          searchMenuItem(),
          stashMenuItem(),
          favoriteMenuItem(),
          copyMenuItem(),
          shareMenuItem(),
        ],
      );

  /// Get the default context menu for sources that make use of embedded web
  /// views.
  ContextMenu get emptyContextMenu => ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: true,
        ),
        menuItems: [],
      );

  ContextMenuItem searchMenuItem() {
    return ContextMenuItem(
      id: 1,
      title: t.search,
      action: searchMenuAction,
    );
  }

  ContextMenuItem stashMenuItem() {
    return ContextMenuItem(
      id: 2,
      title: t.stash,
      action: stashMenuAction,
    );
  }

  ContextMenuItem copyMenuItem() {
    return ContextMenuItem(
      id: 3,
      title: t.copy,
      action: copyMenuAction,
    );
  }

  ContextMenuItem shareMenuItem() {
    return ContextMenuItem(
      id: 4,
      title: t.share,
      action: shareMenuAction,
    );
  }

  ContextMenuItem favoriteMenuItem() {
    return ContextMenuItem(
      id: 6,
      title: t.action_favorite,
      action: favoriteMenuAction,
    );
  }

  void favoriteMenuAction() async {
    final selRange = await HighlightBridge.getSelectionRange(_controller);
    String text;
    int? normOffset;
    int? normLength;
    if (selRange != null && selRange.text.isNotEmpty) {
      text = selRange.text;
      normOffset = selRange.offset;
      normLength = selRange.length;
    } else {
      text = (await getSelectedText()).replaceAll('\\n', '\n').trim();
    }
    if (text.isEmpty) return;
    await unselectWebViewTextSelection(_controller);
    final String bookTitle = widget.item?.title ?? '';
    final String? chapterLabel = _tocLabels[_currentTtuSection];
    final int? ttuId = _extractTtuBookId();
    final sentence = FavoriteSentence(
      text: text,
      bookTitle: bookTitle,
      chapterLabel: chapterLabel,
      createdAt: DateTime.now(),
      ttuBookId: ttuId,
      sectionIndex: _currentTtuSection >= 0 ? _currentTtuSection : null,
      normCharOffset: normOffset,
      normCharLength: normLength,
      color: 'yellow',
    );
    await FavoriteSentenceRepository(appModel.database).add(sentence);
    await _applyHighlightsForCurrentSection();
    if (mounted) {
      Fluttertoast.showToast(msg: t.favorite_added);
    }
  }

  Future<void> _applyHighlightsForCurrentSection() async {
    if (_currentTtuSection < 0) return;
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null) return;
    final List<FavoriteSentence> all =
        await FavoriteSentenceRepository(appModel.database).getAll();
    if (!mounted) return;
    final List<FavoriteSentence> sectionHighlights = all
        .where((FavoriteSentence f) =>
            f.ttuBookId == ttuId && f.sectionIndex == _currentTtuSection)
        .toList();
    await HighlightBridge.applyHighlights(_controller, sectionHighlights);
  }

  void searchMenuAction() async {
    String searchTerm = await getSelectedText();
    _isRecursiveSearching = true;

    await unselectWebViewTextSelection(_controller);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await Future.delayed(const Duration(milliseconds: 5), () {});
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    await Future.delayed(const Duration(milliseconds: 5), () {});
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _isRecursiveSearching = false;
    _focusNode.requestFocus();
  }

  void stashMenuAction() async {
    String searchTerm = await getSelectedText();
    appModel.addToStash(terms: [searchTerm]);
    await unselectWebViewTextSelection(_controller);
  }

  void copyMenuAction() async {
    String searchTerm = await getSelectedText();
    Clipboard.setData(ClipboardData(text: searchTerm));
    await unselectWebViewTextSelection(_controller);
  }

  void shareMenuAction() async {
    String searchTerm = await getSelectedText();
    Share.share(searchTerm);
    await unselectWebViewTextSelection(_controller);
  }

  Future<String> getSelectedText() async {
    return (await _controller.getSelectedText() ?? '')
        .replaceAll('\\n', '\n')
        .trim();
  }

  String downloadFileJs = '''
var xhr = new XMLHttpRequest();
var blobUrl = "blobUrlPlaceholder";
console.log(blobUrl);
xhr.open('GET', blobUrl, true);
xhr.responseType = 'blob';
xhr.onload = function(e) {
  if (this.status == 200) {
    var blob = this.response;
    var reader = new FileReader();
    reader.readAsDataURL(blob);
    reader.onloadend = function() {
      var base64data = reader.result;
      var base64ContentArray = base64data.split(",")     ;
      var mimeType = base64ContentArray[0].match(/[^:\\s*]\\w+\\/[\\w-+\\d.]+(?=[;| ])/)[0];
      var decodedFile = base64ContentArray[1];
      console.log(mimeType);
      window.flutter_inappwebview.callHandler('blobToBase64Handler', decodedFile, mimeType);
    };
  };
};
xhr.send();
''';

  /// This is executed upon page load and change.
  /// More accurate readability courtesy of
  /// https://github.com/birchill/10ten-ja-reader/blob/fbbbde5c429f1467a7b5a938e9d67597d7bd5ffa/src/content/get-text.ts#L314
  String get javascriptToExecute => """
/*jshint esversion: 6 */

window.__hibikiGetScrollRoots = function() {
  var roots = [];
  var bcc = document.querySelector('.book-content-container');
  var bc = document.querySelector('.book-content');
  var se = document.scrollingElement;
  var de = document.documentElement;
  if (bcc) roots.push(bcc);
  if (bc && bc !== bcc) roots.push(bc);
  if (se && se !== bcc && se !== bc) roots.push(se);
  if (de && de !== se && de !== bcc && de !== bc) roots.push(de);
  return roots;
};

window.__hibikiSelectionScrollLockCount = window.__hibikiSelectionScrollLockCount || 0;
window.__hibikiIsSelectionScrollLocked = function() {
  return (window.__hibikiSelectionScrollLockCount || 0) > 0;
};

window.__hibikiRunWithScrollLock = function(fn) {
  var roots = window.__hibikiGetScrollRoots ? window.__hibikiGetScrollRoots() : [];
  if (!roots.length) {
    var fb = document.querySelector('.book-content') || document.scrollingElement || document.documentElement;
    if (fb) roots = [fb];
  }
  var saved = roots.map(function(el) { return { el: el, top: el.scrollTop, left: el.scrollLeft }; });
  function restore() {
    for (var i = 0; i < saved.length; i++) {
      saved[i].el.scrollTop = saved[i].top;
      saved[i].el.scrollLeft = saved[i].left;
    }
  }
  window.__hibikiSelectionScrollLockCount++;
  var cleaned = false;
  function cleanup() {
    if (cleaned) return;
    cleaned = true;
    restore();
    window.__hibikiSelectionScrollLockCount = Math.max(0, (window.__hibikiSelectionScrollLockCount || 1) - 1);
  }
  try {
    fn();
    restore();
  } finally {
    setTimeout(cleanup, 150);
  }
};

function tapToSelect(e) {
  console.log('[hibiki] tapToSelect x=' + e.clientX + ' y=' + e.clientY + ' target=' + (e.target ? e.target.nodeName : 'null'));

  if (e.target && e.target.nodeName === 'IMG') {
    var imgEl = e.target;
    var src = imgEl.currentSrc || imgEl.src || '';
    if (src && window.flutter_inappwebview) {
      try {
        var canvas = document.createElement('canvas');
        canvas.width = imgEl.naturalWidth;
        canvas.height = imgEl.naturalHeight;
        var ctx2d = canvas.getContext('2d');
        ctx2d.drawImage(imgEl, 0, 0);
        var dataUrl = canvas.toDataURL('image/png');
        window.flutter_inappwebview.callHandler('imageClicked', dataUrl);
      } catch(err) {
        window.flutter_inappwebview.callHandler('imageClicked', src);
      }
    }
    return;
  }

  var result = document.caretRangeFromPoint(e.clientX, e.clientY);
  console.log('[hibiki] caretRangeFromPoint result=' + (result ? result.startContainer.nodeName + ' offset=' + result.startOffset : 'null'));

  if (!result || e.target.classList.contains('book-content')) {
    console.log('[hibiki] early return: result=' + (!!result) + ' isBookContent=' + (e.target && e.target.classList.contains('book-content')));
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTapLookup', {
        "index": -1,
        "text": "",
        "x": e.clientX,
        "y": e.clientY,
      });
    }
    return;
  }

  // Resolve furigana hit → base text in parent <ruby>
  if (result.startContainer && result.startContainer.nodeType === Node.TEXT_NODE) {
    var _el = result.startContainer.parentElement;
    if (_el && _el.closest('rt, rp')) {
      var _ruby = _el.closest('ruby');
      if (_ruby) {
        var _w = document.createTreeWalker(_ruby, NodeFilter.SHOW_TEXT, {
          acceptNode: function(n) {
            var p = n.parentElement;
            return (p && p.closest('rt, rp')) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          }
        });
        var _base = _w.nextNode();
        if (_base) {
          result = { startContainer: _base, startOffset: 0 };
        }
      }
    }
  }

  var selectedElement = result.startContainer;
  var paragraph = result.startContainer;
  var offsetNode = result.startContainer;
  var offset = result.startOffset;

  var adjustIndex = false;

  if (!!offsetNode && offsetNode.nodeType === Node.TEXT_NODE && offset) {
      const range = new Range();
      range.setStart(offsetNode, offset - 1);
      range.setEnd(offsetNode, offset);

      const bbox = range.getBoundingClientRect();
      if (bbox.left <= e.x && bbox.right >= e.x &&
          bbox.top <= e.y && bbox.bottom >= e.y) {
          
          result.startOffset = result.startOffset - 1;
          adjustIndex = true;
      }
    }
  
  
  while (paragraph && paragraph.nodeName !== 'P') {
    paragraph = paragraph.parentNode;
  }
  if (paragraph === null) {
    paragraph = result.startContainer.parentNode;
  }
  var noFuriganaText = [];
  var noFuriganaNodes = [];
  var selectedFound = false;
  var index = 0;
  for (var value of paragraph.childNodes.values()) {
    if (value.nodeName === "#text") {
      noFuriganaText.push(value.textContent);
      noFuriganaNodes.push(value);
      if (selectedFound === false) {
        if (selectedElement !== value) {
          index = index + value.textContent.length;
        } else {
          index = index + result.startOffset;
          selectedFound = true;
        }
      }
    } else {
      for (var node of value.childNodes.values()) {
        if (node.nodeName === "#text") {
          noFuriganaText.push(node.textContent);
          noFuriganaNodes.push(node);
          if (selectedFound === false) {
            if (selectedElement !== node) {
              index = index + node.textContent.length;
            } else {
              index = index + result.startOffset;
              selectedFound = true;
            }
          }
        } else if (node.firstChild && node.firstChild.nodeName === "#text" && node.nodeName !== "RT" && node.nodeName !== "RP") {
          noFuriganaText.push(node.firstChild.textContent);
          noFuriganaNodes.push(node.firstChild);
          if (selectedFound === false) {
            if (selectedElement !== node.firstChild) {
              index = index + node.firstChild.textContent.length;
            } else {
              index = index + result.startOffset;
              selectedFound = true;
            }
          }
        }
      }
    }
  }
  var text = noFuriganaText.join("");
  var offset = index;
  if (adjustIndex) {
    index = index - 1;
  }
  

  var character = text[index];
  console.log('[hibiki] character=' + character + ' index=' + index + ' textLen=' + text.length);
  if (character) {
    console.log('[hibiki] calling onTapLookup with index=' + index);
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTapLookup', {
        "index": index,
        "text": text,
        "x": e.clientX,
        "y": e.clientY,
      });
    } else {
      console.log('[hibiki] flutter_inappwebview not available!');
    }
  } else {
    console.log('[hibiki] no character found, sending index=-1');
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTapLookup', {
        "index": -1,
        "text": "",
        "x": e.clientX,
        "y": e.clientY,
      });
    }
  }
}
function getSelectionText() {
    function getRangeSelectedNodes(range) {
      var node = range.startContainer;
      var endNode = range.endContainer;
      if (node == endNode) return [node];
      var rangeNodes = [];
      while (node && node != endNode) rangeNodes.push(node = nextNode(node));
      node = range.startContainer;
      while (node && node != range.commonAncestorContainer) {
        rangeNodes.unshift(node);
        node = node.parentNode;
      }
      return rangeNodes;
      function nextNode(node) {
        if (node.hasChildNodes()) return node.firstChild;
        else {
          while (node && !node.nextSibling) node = node.parentNode;
          if (!node) return null;
          return node.nextSibling;
        }
      }
    }
    var txt = "";
    var nodesInRange;
    var selection;
    if (window.getSelection) {
      selection = window.getSelection();
      nodesInRange = getRangeSelectedNodes(selection.getRangeAt(0));
      nodes = nodesInRange.filter((node) => node.nodeName == "#text" && node.parentElement.nodeName !== "RT" && node.parentElement.nodeName !== "RP" && node.parentElement.parentElement.nodeName !== "RT" && node.parentElement.parentElement.nodeName !== "RP");
      if (selection.anchorNode === selection.focusNode) {
          txt = txt.concat(selection.anchorNode.textContent.substring(selection.baseOffset, selection.extentOffset));
      } else {
          for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (i === 0) {
                  txt = txt.concat(node.textContent.substring(selection.getRangeAt(0).startOffset));
              } else if (i === nodes.length - 1) {
                  txt = txt.concat(node.textContent.substring(0, selection.getRangeAt(0).endOffset));
              } else {
                  txt = txt.concat(node.textContent);
              }
          }
      }
    } else if (window.document.getSelection) {
      selection = window.document.getSelection();
      nodesInRange = getRangeSelectedNodes(selection.getRangeAt(0));
      nodes = nodesInRange.filter((node) => node.nodeName == "#text" && node.parentElement.nodeName !== "RT" && node.parentElement.nodeName !== "RP" && node.parentElement.parentElement.nodeName !== "RT" && node.parentElement.parentElement.nodeName !== "RP");
      if (selection.anchorNode === selection.focusNode) {
          txt = txt.concat(selection.anchorNode.textContent.substring(selection.baseOffset, selection.extentOffset));
      } else {
          for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (i === 0) {
                  txt = txt.concat(node.textContent.substring(selection.getRangeAt(0).startOffset));
              } else if (i === nodes.length - 1) {
                  txt = txt.concat(node.textContent.substring(0, selection.getRangeAt(0).endOffset));
              } else {
                  txt = txt.concat(node.textContent);
              }
          }
      }
    } else if (window.document.selection) {
      txt = window.document.selection.createRange().text;
    }
    return txt;
};
if (!window.__hibikiClickListenerRegistered) {
  window.__hibikiClickListenerRegistered = true;
  console.log('[hibiki] registering listeners');
  var __jidoTapStartX = 0, __jidoTapStartY = 0, __jidoLastTouchEnd = 0;
  var __hibikiLastTurn = 0;

  // Hoshi-style page turn via wheel event (matches volume-key path).
  // direction: 'next' or 'prev'.
  // deltaY magnitude matches volume-key path (0.001 * speed). 纯 sign 对
  // ttu 分页足够，但连续滚动模式下 0.001 会被当噪音吞掉——音量键用 0.1。
  window.__hibikiTurnPage = function(direction) {
    var now = Date.now();
    if (now - __hibikiLastTurn < 200) return;
    __hibikiLastTurn = now;
    var sign = (direction === 'next') ? -1 : +1;
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true);
    evt.deltaY = sign * 0.1;
    document.body.dispatchEvent(evt);
  };

  document.addEventListener('touchstart', function(e) {
    if (e.touches.length === 1) {
      __jidoTapStartX = e.touches[0].clientX;
      __jidoTapStartY = e.touches[0].clientY;
    }
  }, {capture: true, passive: true});

  document.addEventListener('touchend', function(e) {
    if (e.changedTouches.length !== 1) return;
    var touch = e.changedTouches[0];
    var dx = Math.abs(touch.clientX - __jidoTapStartX);
    var dy = Math.abs(touch.clientY - __jidoTapStartY);

    // Swipe (large movement) → notify Flutter for follow-audio auto-off.
    if (dx > 15 || dy > 15) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('userSwipe');
      }
      return;
    }

    // Tap → existing select-word behavior.
    if (!e.target.closest('.book-content')) return;
    // Skip dictionary lookup for hyperlinks — let the browser navigate.
    var _a = (e.target.nodeName === 'A') ? e.target : e.target.closest('a');
    if (_a && _a.getAttribute('href')) return;
    __jidoLastTouchEnd = Date.now();
    tapToSelect({
      clientX: touch.clientX, clientY: touch.clientY,
      x: touch.clientX, y: touch.clientY,
      target: e.target,
    });
  }, true);

  document.addEventListener('click', function(e) {
    if (Date.now() - __jidoLastTouchEnd < 600) return;
    if (!e.target.closest('.book-content')) return;
    var _a2 = (e.target.nodeName === 'A') ? e.target : e.target.closest('a');
    if (_a2 && _a2.getAttribute('href')) return;
    tapToSelect(e);
  }, true);
}
document.head.insertAdjacentHTML('beforebegin', `
<style>
rt {
  -webkit-touch-callout:none; /* iOS Safari */
  -webkit-user-select:none;   /* Chrome/Safari/Opera */
  -khtml-user-select:none;    /* Konqueror */
  -moz-user-select:none;      /* Firefox */
  -ms-user-select:none;       /* Internet Explorer/Edge */
  user-select:none;           /* Non-prefixed version */
}
rp {
  -webkit-touch-callout:none; /* iOS Safari */
  -webkit-user-select:none;   /* Chrome/Safari/Opera */
  -khtml-user-select:none;    /* Konqueror */
  -moz-user-select:none;      /* Firefox */
  -ms-user-select:none;       /* Internet Explorer/Edge */
  user-select:none;           /* Non-prefixed version */
}

::selection {
  color: white;
  background: var(--hoshi-primary-selection, rgba(255, 0, 0, 0.6));
}

/* ttu 顶部 32px 隐形热区 <button>（tap 唤出 reader 工具栏）在 Android
   WebView 下会被 -webkit-appearance:button 绘成 buttonface 灰白底，
   盖住正文最上面那一点。SSG 快照里 class 带 top-0，Svelte hydrate 后
   class 变成 "fixed inset-x-0 z-10 h-8 w-full"（没有 top-0），所以
   要按 fixed+h-8+w-full 匹配。 */
button.fixed.h-8.w-full,
button.fixed.inset-x-0,
button.fixed.top-0 {
  display: none !important;
}

/* ttu 书签指示图标（faBookmark，opacity 0.25）——滚动位置命中 bookmark
   时显示。对应 node4 Ou/Gu 渲染的 div.pointer-events-none.absolute.
   opacity-25，用 inline top/left/right 浮在正文上。hibiki 走 ttu 原生
   auto-bookmark，这颗半透明图钉对用户没用，且容易盖住正文，直接隐藏。 */
div.pointer-events-none.absolute.opacity-25 {
  display: none !important;
}

</style>
`);


function _applySelection(range) {
  window.__hibikiRunWithScrollLock(function() {
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  });
}

function selectTextForTextLength(x, y, index, length, whitespaceOffset, isSpaceDelimited) {
  var result = document.caretRangeFromPoint(x, y);
  if (!result || !result.startContainer || !(result.startContainer instanceof Node)) return;

  // Resolve furigana hit → base text in parent <ruby>
  if (result.startContainer.nodeType === Node.TEXT_NODE) {
    var _el = result.startContainer.parentElement;
    if (_el && _el.closest('rt, rp')) {
      var _ruby = _el.closest('ruby');
      if (_ruby) {
        var _w = document.createTreeWalker(_ruby, NodeFilter.SHOW_TEXT, {
          acceptNode: function(n) {
            var p = n.parentElement;
            return (p && p.closest('rt, rp')) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
          }
        });
        var _base = _w.nextNode();
        if (_base) {
          result = { startContainer: _base, startOffset: 0 };
        }
      }
    }
  }

  var offsetNode = result.startContainer;
  if (!(offsetNode instanceof Node) || offsetNode.nodeType !== Node.TEXT_NODE) return;
  var nodeLen = offsetNode.textContent ? offsetNode.textContent.length : 0;
  var offset = Math.min(result.startOffset, nodeLen);

  var adjustIndex = false;

  if (offset > 0) {
      var testRange = document.createRange();
      testRange.setStart(offsetNode, offset - 1);
      testRange.setEnd(offsetNode, offset);
      var bbox = testRange.getBoundingClientRect();
      if (bbox.left <= x && bbox.right >= x &&
          bbox.top <= y && bbox.bottom >= y) {
          if (length == 1) {
            var r1 = document.createRange();
            r1.setStart(offsetNode, offset - 1);
            r1.setEnd(offsetNode, offset);
            _applySelection(r1);
            return;
          }
          offset = offset - 1;
          adjustIndex = true;
      }
  }

  if (length == 1) {
    var end1 = Math.min(offset + 1, nodeLen);
    if (end1 <= offset) return;
    var r2 = document.createRange();
    r2.setStart(offsetNode, offset);
    r2.setEnd(offsetNode, end1);
    _applySelection(r2);
    return;
  }

  var paragraph = offsetNode;
  while (paragraph && paragraph.nodeName !== 'P') {
    paragraph = paragraph.parentNode;
  }
  if (!paragraph) {
    paragraph = offsetNode.parentNode;
  }
  if (!paragraph) return;

  var lastNode = null;
  var endOffset = 0;
  var done = false;
  var charCount = 0;
  var target = length + index;

  function walkTextNode(tnode) {
    if (done) return;
    lastNode = tnode;
    endOffset = 0;
    var tlen = tnode.textContent ? tnode.textContent.length : 0;
    for (var i = 0; i < tlen; i++) {
      endOffset = i + 1;
      charCount++;
      if (charCount >= target) { done = true; return; }
    }
  }

  for (var value of paragraph.childNodes.values()) {
    if (done) break;
    if (value.nodeName === '#text') {
      walkTextNode(value);
    } else {
      for (var node of value.childNodes.values()) {
        if (done) break;
        if (node.nodeName === '#text') {
          walkTextNode(node);
        } else if (node.nodeName !== 'RT' && node.nodeName !== 'RP' &&
                   node.firstChild && node.firstChild.nodeName === '#text') {
          walkTextNode(node.firstChild);
        }
      }
    }
  }

  var startOff = Math.max(0, Math.min(offset + whitespaceOffset, nodeLen));
  var range = document.createRange();
  range.setStart(offsetNode, startOff);
  if (isSpaceDelimited) {
    range.expand('word');
  } else if (lastNode instanceof Node && endOffset > 0) {
    var lastLen = lastNode.textContent ? lastNode.textContent.length : 0;
    range.setEnd(lastNode, Math.min(endOffset, lastLen));
  } else {
    var fallbackEnd = Math.min(startOff + 1, nodeLen);
    if (fallbackEnd > startOff) {
      range.setEnd(offsetNode, fallbackEnd);
    }
  }

  _applySelection(range);
}

// ReaderPosition 保存触发：监听 `.book-content` / `.book-content-container`
// 的 scroll 事件，debounce 500ms 后调 `__hibikiGetViewportNormOffset()`
// 反查当前视口的 (section, 章内 normCharOffset)，再通过 flutter_inappwebview
// 的 saveReaderPos handler 回传 Dart 写 Isar。
//
// 为什么 500ms：paginated 翻一页本质是单次 scroll 事件（scrollTop 跳一大步
// 后稳定），之后无后续 scroll。500ms 足够过滤同一次翻页动画里的多发
// scroll，又让翻页到落盘基本无感延迟。Dart 侧 _persistReaderPos 自带
// 同值去重，即便 JS debounce 偶尔多 fire 一次也不会额外 writeTxn。
//
// - scroll 事件不冒泡，必须 capture 阶段监听，并挂到 document 上做事件委托
//   （ttu 切换章节会重建 `.book-content` DOM，直接绑到那个元素会丢）
// - __hibikiGetViewportNormOffset 由 AudiobookBridge.inject 注入，但 inject
//   只在有 audiobook 时才跑 —— 纯 EPUB（无有声书）场景该函数不存在，这里
//   直接 return，不会抛。纯 EPUB 的位置保存后续单独做。
// - __hibikiPosSaveInstalled guard 防 onLoadStop 多次 evaluate 重复注册。
(function() {
  if (window.__hibikiPosSaveInstalled) return;
  window.__hibikiPosSaveInstalled = true;
  var timer = null;
  function schedule() {
    if (timer) clearTimeout(timer);
    timer = setTimeout(function() {
      try {
        if (window.__hoshiAutoScrollInFlight || window.__hoshiRestoreInFlight || (window.__hibikiIsSelectionScrollLocked && window.__hibikiIsSelectionScrollLocked())) {
          console.log(JSON.stringify({'hibiki-message-type':'pos-save-skip','reason':'autoScrollInFlight'}));
          return;
        }
        if (!window.__hibikiGetViewportNormOffset) {
          console.log(JSON.stringify({'hibiki-message-type':'pos-save-skip','reason':'noGetOffset'}));
          return;
        }
        var p = window.__hibikiGetViewportNormOffset();
        if (!p) {
          console.log(JSON.stringify({'hibiki-message-type':'pos-save-skip','reason':'nullOffset'}));
          return;
        }
        console.log(JSON.stringify({'hibiki-message-type':'pos-save-fire','s':p.section,'o':p.offset}));
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('saveReaderPos', p);
        }
      } catch (e) {
        console.log(JSON.stringify({'hibiki-message-type':'pos-save-err','e':String(e)}));
      }
    }, 500);
  }
  document.addEventListener('scroll', function(e) {
    var t = e.target;
    if (!t) return;
    // Element vs Document 区分：document 的 scroll 事件 target === document
    // 本身（ttu paginated 下 window 不滚，这里主要过 book-content*）
    if (t === document) { schedule(); return; }
    if (t.classList && (t.classList.contains('book-content') ||
                        t.classList.contains('book-content-container'))) {
      schedule();
    }
  }, true);
})();
""";

  String get leftArrowSimulateJs => '''
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true);
    evt.deltaY = +0.001 * ${mediaSource.volumePageTurningSpeed * (mediaSource.volumePageTurningInverted ? -1 : 1)};
    document.body.dispatchEvent(evt);
    ''';

  String get rightArrowSimulateJs => '''
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true);
    evt.deltaY = -0.001 * ${mediaSource.volumePageTurningSpeed * (mediaSource.volumePageTurningInverted ? -1 : 1)};
    document.body.dispatchEvent(evt);
    ''';

  // ── 有声书辅助方法 ──────────────────────────────────────────────────────────

  /// 从 Isar 查找当前书的 [Audiobook]，若存在则初始化播放器并监听 cue 变化。
  /// 若未找到，再尝试以 [SrtBook] 方式初始化（字幕 EPUB 路径）。
  Future<void> _initAudiobookIfAvailable() async {
    final String? bookUid = widget.item?.uniqueKey;
    if (bookUid == null) {
      return;
    }
    debugPrint('[hibiki-audiobook] initAudiobook bookUid.len=${bookUid.length} '
        'hash=${bookUid.hashCode} uid=$bookUid');
    final AudiobookRepository repo = AudiobookRepository(appModel.database);
    Audiobook? audiobook = await repo.findByBookUid(bookUid);

    // bookUid 不匹配时（如从收藏夹打开，URL 格式可能不同），按 ttuBookId 回退
    if (audiobook == null) {
      final int? ttuId = _extractTtuBookId();
      if (ttuId != null && ttuId > 0) {
        audiobook = await repo.findByTtuBookId(ttuId);
        if (audiobook != null) {
          debugPrint(
              '[hibiki-audiobook] bookUid miss, ttuId=$ttuId fallback hit');
        }
      }
    }

    if (audiobook != null) {
      final String effectiveUid = audiobook.bookUid;
      // ── 常规 EPUB 有声书路径 ─────────────────────────────────────────────
      final List<File> audioFiles = await _resolveAudioFiles(
        audioPaths: audiobook.audioPaths,
        audioRoot: audiobook.audioRoot,
      );

      if (audioFiles.isEmpty) {
        debugPrint('[hibiki-audiobook] audiobook found but files empty, '
            'trying SrtBook fallback');
        await _initSrtBookIfAvailable();
        return;
      }

      final AudiobookPlayerController controller = AudiobookPlayerController();
      final prefs = await Future.wait([
        repo.readFollowAudio(effectiveUid),
        repo.readDelayMs(effectiveUid),
        repo.readSpeed(effectiveUid),
        repo.readPositionMs(effectiveUid),
        repo.readImagePauseSec(effectiveUid),
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
      controller.onPositionWrite = (String uid, int posMs) {
        repo.updatePositionMs(bookUid: uid, positionMs: posMs);
      };
      if (!mounted) {
        controller.dispose();
        return;
      }
      controller.addListener(_onCueChanged);
      _wireFollowAudio(controller, bookUid: effectiveUid, repo: repo);
      unawaited(_wireMediaNotification(controller));

      if (mounted) {
        setState(() {
          _audiobookController = controller;
        });
        if (_controllerInitialised) {
          await _maybeInjectAudiobookBridge(
            _controller,
            trigger: 'audiobookReady',
          );
        }
        unawaited(_syncFloatingLyricOverlay());
      }
    } else {
      // ── 字幕 EPUB 路径（SrtBook）──────────────────────────────────────────
      await _initSrtBookIfAvailable();
    }
  }

  /// 从 URL 中解析 ttuBookId，查找对应 [SrtBook] 并初始化播放器。
  Future<void> _initSrtBookIfAvailable() async {
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) {
      debugPrint('[hibiki-audiobook] srt init skip: no ttuId in URL');
      if (mounted && _hasAudioSlot) setState(() => _hasAudioSlot = false);
      return;
    }

    final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
    final SrtBook? srtBook = await srtRepo.findByTtuBookId(ttuId);
    if (srtBook == null) {
      debugPrint(
          '[hibiki-audiobook] srt init skip: no SrtBook for ttuId=$ttuId');
      if (mounted && _hasAudioSlot) setState(() => _hasAudioSlot = false);
      return;
    }

    final bool hasAudioConfig =
        (srtBook.audioPaths != null && srtBook.audioPaths!.isNotEmpty) ||
            (srtBook.audioRoot != null && srtBook.audioRoot!.isNotEmpty);
    final List<File> audioFiles = await _audioFilesForSrtBook(srtBook);
    if (audioFiles.isEmpty) {
      if (hasAudioConfig) {
        // 配置了音频但解析为空 — 文件丢失/路径失效，告知用户
        debugPrint('[hibiki-audiobook] srt init: audio configured but '
            'unresolved. paths=${srtBook.audioPaths} root=${srtBook.audioRoot}');
        Fluttertoast.showToast(msg: t.srt_audio_unresolved);
      } else {
        debugPrint('[hibiki-audiobook] srt init: pure subtitle book, no audio');
      }
      // 撤销 initState 预留的 slot（文件失效 / 纯字幕无音频），别留空黑条。
      if (mounted && _hasAudioSlot) {
        setState(() => _hasAudioSlot = false);
      }
      return;
    }

    // 用合成 Audiobook 对象满足控制器接口；bookUid = SrtBook.uid。
    final Audiobook syntheticAudiobook = Audiobook()
      ..bookUid = srtBook.uid
      ..audioRoot = srtBook.audioRoot
      ..audioPaths = srtBook.audioPaths
      ..alignmentFormat = 'srt'
      ..alignmentPath = srtBook.srtPath;

    // 闭包捕获：避免 null-promotion 在 async 闭包里丢掉。局部 `srtRepo`
    // 已是 SrtBookRepository（外层变量），这里换名区分。
    final String srtBookUid = srtBook.uid;
    final AudiobookRepository abRepo = AudiobookRepository(appModel.database);
    final AudiobookPlayerController controller = AudiobookPlayerController();
    try {
      final srtPrefs = await Future.wait([
        abRepo.readDelayMs(srtBookUid),
        abRepo.readSpeed(srtBookUid),
        abRepo.readImagePauseSec(srtBookUid),
      ]);
      await controller.load(
        audiobook: syntheticAudiobook,
        audioFiles: audioFiles,
        initialDelayMs: srtPrefs[0] as int,
        initialSpeed: srtPrefs[1] as double,
        initialImagePauseSec: srtPrefs[2] as int,
      );
    } catch (e) {
      debugPrint('[hibiki-audiobook] srt init: controller.load failed: $e');
      Fluttertoast.showToast(msg: t.srt_audio_load_error);
      controller.dispose();
      return;
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    controller.addListener(_onCueChanged);
    // SRT-book 的 audiobook 是合成对象，没写进 Isar audiobooks 集合，
    // updateFollowAudio 会找不到记录。暂先只接 onCrossChapter（会话内
    // 磁铁按钮仍可切换），不落库。真正落库需要把 followAudio 搬到
    // SrtBook 模型，属于独立的数据层工作。
    // 延迟/速度走 Hive KV，可以落。
    controller.onDelayPersist = (int ms) async {
      await abRepo.updateDelayMs(bookUid: srtBookUid, ms: ms);
    };
    controller.onSpeedPersist = (double speed) async {
      await abRepo.updateSpeed(bookUid: srtBookUid, speed: speed);
    };
    controller.onImagePausePersist = (int sec) async {
      await abRepo.updateImagePauseSec(bookUid: srtBookUid, sec: sec);
    };
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.getCurrentReaderSection = () => _currentTtuSection;
    unawaited(_wireMediaNotification(controller));

    if (mounted) {
      setState(() {
        _audiobookController = controller;
        _srtBookUid = srtBook!.uid;
      });
      if (_controllerInitialised) {
        await _maybeInjectAudiobookBridge(
          _controller,
          trigger: 'srtBookReady',
        );
      }
      unawaited(_syncFloatingLyricOverlay());
    }
  }

  /// 从 [widget.item?.mediaIdentifier] 的 URL 中提取 `id=N` 参数。
  int? _extractTtuBookId() {
    final String? identifier = widget.item?.mediaIdentifier;
    if (identifier == null) {
      return null;
    }
    final Uri? uri = Uri.tryParse(identifier);
    return int.tryParse(uri?.queryParameters['id'] ?? '');
  }

  Future<void> _installTtuBookmarkBridge(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(source: '''
(function() {
  if (window.__hibikiBookmarkBridgeInstalled) return;
  window.__hibikiBookmarkBridgeInstalled = true;

  function notifyHibikiBookmark() {
    try {
      if (window.flutter_inappwebview &&
          window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('hibikiTtuBookmarkAdded');
      }
    } catch (e) {
      console.error('[hibiki] bookmark bridge notify failed', e);
    }
  }

  function wrapBookmarkPage() {
    if (typeof window.__ttuBookmarkPage !== 'function') return false;
    if (window.__ttuBookmarkPage.__hibikiWrapped) return true;
    var wrapped = async function() {
      notifyHibikiBookmark();
    };
    wrapped.__hibikiWrapped = true;
    window.__ttuBookmarkPage = wrapped;
    return true;
  }

  if (!wrapBookmarkPage()) {
    var tries = 0;
    var timer = setInterval(function() {
      tries += 1;
      if (wrapBookmarkPage() || tries >= 100) {
        clearInterval(timer);
      }
    }, 100);
  }
})();
''');
    } catch (e) {
      debugPrint('[hibiki-reader] bookmark bridge install error: $e');
    }
  }

  Future<void> _addCurrentViewportBookmark({required String from}) async {
    try {
      final int? ttuId = _extractTtuBookId();
      if (ttuId == null) {
        debugPrint(
            '[hibiki-reader] bookmark skipped: missing ttuId from=$from');
        return;
      }
      final results = await Future.wait([
        _resolveBookmarkViewport(from: from),
        AudiobookBridge.probeTtuApi(_controller),
      ]);
      final ReaderViewportPos bookmarkPos = results[0] as ReaderViewportPos;
      final TtuApiProbe probe = results[1] as TtuApiProbe;
      final String chapterLabel = _tocLabels[bookmarkPos.section] ??
          t.go_to_chapter(n: bookmarkPos.section + 1);
      final bookmark = Bookmark(
        sectionIndex: bookmarkPos.section,
        normCharOffset: bookmarkPos.offset,
        label: chapterLabel,
        createdAt: DateTime.now(),
        ttuBookId: ttuId,
        bookTitle: widget.item?.title,
        pageInChapter: probe.currentPage,
        totalPagesInChapter: probe.totalPages,
      );
      await BookmarkRepository(appModel.database).addBookmark(ttuId, bookmark);
      if (mounted) {
        Fluttertoast.showToast(msg: t.bookmark_added);
      }
    } catch (e) {
      debugPrint('[hibiki-reader] bookmark error from=$from: $e');
    }
  }

  Future<ReaderViewportPos> _resolveBookmarkViewport({
    required String from,
  }) async {
    final ReaderViewportPos? viewport =
        await AudiobookBridge.getViewportNormOffset(_controller);
    if (viewport != null) {
      return viewport;
    }

    final TtuApiProbe probe = await AudiobookBridge.probeTtuApi(_controller);
    final int section = probe.currentSection ?? _currentTtuSection;
    final int safeSection = section >= 0 ? section : 0;
    debugPrint(
      '[hibiki-reader] bookmark viewport fallback: '
      'from=$from section=$safeSection',
    );
    return ReaderViewportPos(section: safeSection, offset: 0);
  }

  Future<void> _injectPrimarySelectionColor(
    InAppWebViewController controller,
  ) async {
    if (!mounted) return;
    final Color primary = Theme.of(context).colorScheme.primary;
    final int pr = (primary.r * 255.0).round().clamp(0, 255);
    final int pg = (primary.g * 255.0).round().clamp(0, 255);
    final int pb = (primary.b * 255.0).round().clamp(0, 255);
    final String rgba = 'rgba($pr, $pg, $pb, 0.5)';
    await controller.evaluateJavascript(source: '''
(function() {
  var id = '__hoshi_selection_css';
  var existing = document.getElementById(id);
  if (existing) existing.remove();
  var s = document.createElement('style');
  s.id = id;
  s.textContent = ':root { --hoshi-primary-selection: $rgba; }';
  var parent = document.head || document.documentElement || document.body;
  if (parent) {
    parent.appendChild(s);
  }
})();
''');
  }

  Future<void> _injectReaderViewportBridge(
    InAppWebViewController controller,
  ) async {
    try {
      final Color primary = Theme.of(context).colorScheme.primary;
      await AudiobookBridge.inject(controller, primaryColor: primary);
      unawaited(_installTtuBookmarkBridge(controller));
    } catch (e) {
      debugPrint('[hibiki-reader] viewport bridge inject error: $e');
    }
  }

  /// 根据 [SrtBook] 的音频来源构建有序文件列表。
  Future<List<File>> _audioFilesForSrtBook(SrtBook book) => _resolveAudioFiles(
      audioPaths: book.audioPaths, audioRoot: book.audioRoot);

  Future<List<File>> _resolveAudioFiles({
    required List<String>? audioPaths,
    required String? audioRoot,
  }) async {
    if (audioPaths != null && audioPaths.isNotEmpty) {
      final files = <File>[];
      for (final p in audioPaths) {
        final f = File(p);
        if (await f.exists()) files.add(f);
      }
      return files;
    }
    if (audioRoot != null) {
      final Directory dir = Directory(audioRoot);
      if (!await dir.exists()) return [];
      final entries = await dir.list().toList();
      final files = entries.whereType<File>().where((f) {
        final String ext = f.path.toLowerCase();
        return ext.endsWith('.mp3') ||
            ext.endsWith('.m4a') ||
            ext.endsWith('.ogg') ||
            ext.endsWith('.aac') ||
            ext.endsWith('.wav') ||
            ext.endsWith('.mp4');
      }).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      return files;
    }
    return [];
  }

  /// 注入 / 重新注入 AudiobookBridge，并立即把当前 cue 重新高亮一次。
  ///
  /// 每次 `onLoadStop` / `onTitleChanged`（章节切换）都要重跑：
  /// - ttu 章节切换可能换 document，旧 JS 上下文消失，必须重注入函数。
  /// - 即便 JS 还在，新章节 DOM 落点是首页 — 必须主动跳到当前 cue
  ///   所在页，否则用户看到的是「回到标题页 / 第一行」。
  ///
  /// 注入流程本身是幂等的（CSS 用 id 去重，JS 用 var 覆盖，cue click
  /// handler 用 document flag 去重），所以重复调用安全。
  Future<void> _maybeInjectAudiobookBridge(
    InAppWebViewController controller, {
    required String trigger,
  }) async {
    if (_audiobookController == null) {
      return;
    }
    if (_audiobookBridgeInjectionGate.isRunning) {
      debugPrint('[hibiki-audiobook] injection in progress, '
          'joining redundant $trigger');
    }
    await _audiobookBridgeInjectionGate.run(() async {
      debugPrint(
          '[hibiki-audiobook] injecting via $trigger restoreInFlight=$_restoreInFlight');
      if (!_restoreInFlight) {
        _didRestorePos = false;
        _readerContentReady = false;
      }
      _lastSasayakiAppliedSection = -1;
      await _injectAudiobookBridge(controller);
      if (!mounted) return;
      await _bootstrapCurrentTtuSection(controller);
      if (!mounted) return;
      if (!_restoreInFlight) {
        await _bootstrapRestoreReaderPos();
        if (!mounted) return;
      }
      if (_currentTtuSection >= 0) {
        await _applySasayakiCuesForSection(_currentTtuSection);
        if (!mounted) return;
      }
      _onCueChanged();
    });
  }

  /// 打开 reader 设置面板。两个入口：
  /// - 有声书模式：播放栏 ⚙，传入 [ctrl] 显示全套（倍速 / 音画同步 等）
  /// - 普通 EPUB：左下角 FAB，传 null 省略音频相关节
  ///
  /// probe 结果 await 完再展开 —— 用户短暂 tap 延迟可接受，比先展开空
  /// 面板再填要好；TOC 列表在一次阅读会话里是静态的，一次 probe 够用。
  Future<void> _showReaderSettingsSheet(
    AudiobookPlayerController? ctrl,
  ) async {
    (int, int)? progress;
    (int, int)? pageProgress;
    List<TtuTocEntry> toc = const <TtuTocEntry>[];
    try {
      final TtuApiProbe probe = await AudiobookBridge.probeTtuApi(_controller);
      if (probe.currentPage != null &&
          probe.totalPages != null &&
          probe.totalPages! > 0) {
        pageProgress = (probe.currentPage!, probe.totalPages!);
      }
      toc = await AudiobookBridge.fetchToc(_controller);
      if (probe.currentSection != null && toc.isNotEmpty) {
        final int curRaw = probe.currentSection!;
        int tocPos = toc.indexWhere((TtuTocEntry e) => e.index == curRaw);
        if (tocPos < 0) {
          tocPos = toc.lastIndexWhere((TtuTocEntry e) => e.index <= curRaw);
        }
        if (tocPos >= 0) {
          progress = (tocPos, toc.length);
        }
      }
    } catch (e) {
      debugPrint('[hibiki-reader] settings probe error: $e');
    }
    if (!mounted) return;

    final int? ttuId = _extractTtuBookId();
    List<Bookmark> bookmarks = const [];
    if (ttuId != null) {
      bookmarks =
          await BookmarkRepository(appModel.database).getBookmarks(ttuId);
    }
    final List<FavoriteSentence> allFavorites =
        await FavoriteSentenceRepository(appModel.database).getAll();
    final List<FavoriteSentence> favorites = ttuId != null
        ? allFavorites
            .where((FavoriteSentence f) => f.ttuBookId == ttuId)
            .toList()
        : allFavorites;
    if (!mounted) return;

    final sheetThemeNotifier = ValueNotifier<ThemeData?>(
      appModel.overrideDictionaryTheme,
    );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        final ui.FlutterView view = View.of(ctx);
        final EdgeInsets realInsets = EdgeInsets.fromViewPadding(
          view.viewInsets,
          view.devicePixelRatio,
        );
        final (int, int)? charProg =
            _progressCurrentChars != null && _progressTotalChars != null
                ? (_progressCurrentChars!, _progressTotalChars!)
                : null;
        Widget sheet = AudiobookSettingsSheet(
          controller: ctrl,
          toc: toc,
          readerProgress: progress,
          pageProgress: pageProgress,
          charProgress: charProg,
          bookmarks: bookmarks,
          onJumpToBookmark: (Bookmark bm) async {
            if (_dropStaleSectionNavigation(
              bm.sectionIndex,
              'bookmark-jump',
            )) {
              return;
            }
            await AudiobookBridge.requestSectionNav(
              _controller,
              sectionIndex: bm.sectionIndex,
            );
            await Future.delayed(const Duration(milliseconds: 500));
            await AudiobookBridge.scrollToNormOffset(
              _controller,
              section: bm.sectionIndex,
              offset: bm.normCharOffset,
            );
          },
          onDeleteBookmark: (int index) async {
            if (ttuId == null) return;
            await BookmarkRepository(appModel.database)
                .removeBookmark(ttuId, index);
          },
          favoriteSentences: favorites,
          onDeleteFavorite: (int index) async {
            if (index >= 0 && index < favorites.length) {
              await FavoriteSentenceRepository(appModel.database)
                  .removeById(favorites[index].id);
              unawaited(_applyHighlightsForCurrentSection());
            }
          },
          onJumpToFavorite: (fav) async {
            if (fav.sectionIndex == null) return;
            if (_dropStaleSectionNavigation(
              fav.sectionIndex!,
              'favorite-jump',
            )) {
              return;
            }
            await AudiobookBridge.requestSectionNav(
              _controller,
              sectionIndex: fav.sectionIndex!,
            );
            if (fav.normCharOffset != null) {
              await Future.delayed(const Duration(milliseconds: 500));
              await AudiobookBridge.scrollToNormOffset(
                _controller,
                section: fav.sectionIndex!,
                offset: fav.normCharOffset!,
              );
            }
          },
          onPlayFavorite: _audiobookController != null
              ? (FavoriteSentence fav) async {
                  final ctrl = _audiobookController;
                  if (ctrl == null) {
                    return;
                  }
                  final AudioPlaybackRange? range =
                      CollectionAudioMatcher.findPlaybackRange(
                    cues: ctrl.allBookCuesSnapshot,
                    sectionIndex: fav.sectionIndex,
                    normCharOffset: fav.normCharOffset,
                    normCharLength: fav.normCharLength,
                    text: fav.text,
                  );
                  if (range != null) {
                    await ctrl.playRange(range);
                  }
                }
              : null,
          onJumpSection: (int idx) async {
            if (_dropStaleSectionNavigation(idx, 'toc-jump')) {
              return;
            }
            await AudiobookBridge.requestSectionNav(
              _controller,
              sectionIndex: idx,
            );
          },
          onBookmark: () async {
            await _addCurrentViewportBookmark(from: 'sheet');
          },
          onExitReader: () {
            if (mounted) Navigator.of(context).pop();
          },
          onSearchJump: (int sectionIndex, int charOffset) async {
            if (_dropStaleSectionNavigation(sectionIndex, 'search-jump')) {
              return;
            }
            await AudiobookBridge.requestSectionNav(
              _controller,
              sectionIndex: sectionIndex,
            );
            await Future.delayed(const Duration(milliseconds: 500));
            try {
              await _controller.evaluateJavascript(
                source:
                    'window.__ttuScrollToCharOffset($sectionIndex, $charOffset)',
              );
            } catch (e) {
              debugPrint('[hibiki-search] jump error: $e');
            }
          },
          onJumpToCharOffset: _readerProgressSectionChars().isEmpty
              ? null
              : (int globalOffset) async {
                  final List<int> sc = _readerProgressSectionChars();
                  final (int, int)? resolved = resolveGlobalCharOffset(
                    sectionChars: sc,
                    globalOffset: globalOffset,
                  );
                  if (resolved == null) {
                    final int total =
                        sc.fold<int>(0, (int a, int b) => a + b);
                    Fluttertoast.showToast(
                      msg: t.jump_to_char_out_of_range(max: total),
                    );
                    return;
                  }
                  final (int targetSection, int localOffset) = resolved;
                  if (_dropStaleSectionNavigation(
                      targetSection, 'char-jump')) {
                    return;
                  }
                  await AudiobookBridge.requestSectionNav(
                    _controller,
                    sectionIndex: targetSection,
                  );
                  await Future.delayed(const Duration(milliseconds: 500));
                  try {
                    await _controller.evaluateJavascript(
                      source:
                          'window.__ttuScrollToCharOffset($targetSection, $localOffset)',
                    );
                  } catch (e) {
                    debugPrint('[hibiki-char-jump] jump error: $e');
                  }
                },
          webViewController: _controller,
          appModel: appModel,
          onThemeChanged: () async {
            await setDictionaryColors();
            sheetThemeNotifier.value = appModel.overrideDictionaryTheme;
            _barThemeNotifier.value = appModel.overrideDictionaryTheme;
          },
          showPlayBar: appModel.showPlayBar,
          onTogglePlayBar: () {
            appModel.toggleShowPlayBar();
            setState(() {});
            _syncTtuPageMarginBottom();
          },
          showMediaNotification: appModel.showMediaNotification,
          onToggleMediaNotification: () {
            appModel.toggleShowMediaNotification();
            final ctrl = _audiobookController;
            if (ctrl != null) {
              if (appModel.showMediaNotification) {
                unawaited(_wireMediaNotification(ctrl));
              } else {
                _notifPlaySub?.cancel();
                _notifSkipNextSub?.cancel();
                _notifSkipPrevSub?.cancel();
                appModelNoUpdate.audioHandler?.clearNotification();
              }
            }
          },
          showFloatingLyric: appModel.showFloatingLyric,
          floatingLyricFontSize: appModel.floatingLyricFontSize,
          onFloatingLyricFontSizeChanged: (double value) async {
            await appModel.setFloatingLyricFontSize(value);
            _scheduleFloatingLyricStyleSync(force: true);
            if (mounted) {
              setState(() {});
            }
          },
          onToggleFloatingLyric: () async {
            final bool newValue = !appModel.showFloatingLyric;
            await appModel.setShowFloatingLyric(newValue);
            if (newValue) {
              await _syncFloatingLyricLabels();
              await _syncFloatingLyricStyle();
              await FloatingLyricChannel.show();
              await FloatingLyricChannel.setPlaybackState(
                playing: _audiobookController?.isPlaying ?? false,
              );
              final AudioCue? cue = _audiobookController?.currentCue;
              if (cue != null) {
                FloatingLyricChannel.updateText(cue.text);
              }
            } else {
              await FloatingLyricChannel.hide();
            }
            setState(() {});
          },
          onPageMarginChanged: _syncTtuPageMarginBottom,
        );
        return ValueListenableBuilder<ThemeData?>(
          valueListenable: sheetThemeNotifier,
          builder: (_, ThemeData? themeOverride, Widget? child) {
            final ThemeData effectiveTheme = themeOverride ?? Theme.of(ctx);
            final Color bg = effectiveTheme.colorScheme.surface;
            Widget wrapped = Theme(
              data: effectiveTheme,
              child: child!,
            );
            wrapped = Container(
              decoration: BoxDecoration(
                color: bg,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: effectiveTheme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Flexible(child: wrapped),
                ],
              ),
            );
            return MediaQuery(
              data: MediaQuery.of(ctx).copyWith(viewInsets: realInsets),
              child: wrapped,
            );
          },
          child: sheet,
        );
      },
    );
    sheetThemeNotifier.dispose();
  }

  /// 从 ttu fork 的 `__ttuCurrentSection()` 读一次当前段，用来兜住
  /// sectionChanged 初次发射被 skip(1) 吃掉的情况。fork 未就绪或 probe
  /// 失败时保留原值（多半仍是 -1，跨章守卫就继续等真正的 sectionChanged）。
  Future<void> _bootstrapCurrentTtuSection(
    InAppWebViewController controller,
  ) async {
    try {
      final results = await Future.wait([
        AudiobookBridge.probeTtuApi(controller),
        AudiobookBridge.fetchToc(controller),
      ]).timeout(const Duration(seconds: 5));
      final TtuApiProbe probe = results[0] as TtuApiProbe;
      final List<TtuTocEntry> toc = results[1] as List<TtuTocEntry>;
      if (probe.sectionCount != null && probe.sectionCount! > 0) {
        _ttuSectionCount = probe.sectionCount;
      } else if (toc.isNotEmpty) {
        int highest = -1;
        for (final TtuTocEntry entry in toc) {
          if (entry.index > highest) highest = entry.index;
        }
        _ttuSectionCount = highest >= 0 ? highest + 1 : toc.length;
      }
      if (!probe.hasCurrentSection || probe.currentSection == null) {
        return;
      }
      final int prev = _currentTtuSection;
      _currentTtuSection = probe.currentSection!;
      if (prev != _currentTtuSection) {
        debugPrint(
          '[hibiki-audiobook] bootstrap _currentTtuSection='
          '$_currentTtuSection (prev=$prev) via ttu probe',
        );
      }
      if (toc.isNotEmpty) {
        _tocLabels = {for (final e in toc) e.index: e.label};
      }
      if (prev != _currentTtuSection || toc.isNotEmpty) {
        setState(() {});
      }
      unawaited(_refreshPageProgress());
    } catch (e) {
      debugPrint('[hibiki-audiobook] probeTtuApi failed: $e');
    }
  }

  /// 注入 JS/CSS 桥并对当前页面注册交互逻辑。
  ///
  /// - **SrtBook 路径**：EPUB 已预置 `data-cue-id` span，直接注册点击处理器，
  ///   加载全部 cue 供音频轨道追踪，不调用 [AudiobookBridge.annotate]。
  /// - **常规有声书路径**：按章节 href 查询 cue；若为空则自动标注句子。
  Future<void> _injectAudiobookBridge(InAppWebViewController controller) async {
    final Color primary = Theme.of(context).colorScheme.primary;
    await AudiobookBridge.inject(controller, primaryColor: primary);

    if (_srtBookUid != null) {
      // ── 字幕 EPUB 路径 ────────────────────────────────────────────────────
      final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
      final List<AudioCue> cues = await srtRepo.cuesFor(_srtBookUid!);
      _audiobookController?.setChapterCues(cues);
      _audiobookController?.setAllBookCues(cues);

      debugPrint(
        '[hibiki-audiobook] inject(srt) cues=${cues.length} '
        'firstSel=${cues.isNotEmpty ? cues.first.textFragmentId : "-"}',
      );

      await AudiobookBridge.injectCueClickHandler(
        controller,
        chapterHref: SrtParser.defaultChapter,
      );

      // 诊断：页面里到底存不存在 data-cue-id span
      final Object? probe = await controller.evaluateJavascript(source: '''
(function(){
  var all = document.querySelectorAll('[data-cue-id]');
  var sample = all.length > 0 ? all[0].outerHTML.slice(0, 120) : '';
  return JSON.stringify({count: all.length, sample: sample});
})();
''');
      debugPrint('[hibiki-audiobook] dom probe: $probe');
    } else {
      // ── 常规有声书路径 ────────────────────────────────────────────────────
      final String? bookUid = widget.item?.uniqueKey;
      if (bookUid == null) {
        return;
      }
      final AudiobookRepository repo = AudiobookRepository(appModel.database);

      // Sasayaki 路径的 cue 把位置编码在 textFragmentId 上（`sasayaki://...`），
      // 与原始 chapterHref 解耦：cues 存在某个默认 chapter（srt:// 等）下，但
      // 跨章节定位靠 sectionIndex + 归一化偏移。按章节过滤会返回空集，所以
      // 先抓全部 cue，检测到 Sasayaki 编码就沿用；否则退回按章节过滤。
      final List<AudioCue> allCues = await repo.cuesForBook(bookUid);
      final bool sasayaki = allCues.any(
        (AudioCue c) => SasayakiMatchCodec.tryDecode(c.textFragmentId) != null,
      );

      final List<AudioCue> cues;
      if (sasayaki) {
        cues = allCues;
      } else {
        cues = await repo.cuesForChapter(
          bookUid: bookUid,
          chapterHref: _currentChapterHref,
        );
      }
      _audiobookController?.setChapterCues(cues);
      _audiobookController?.setAllBookCues(allCues);

      debugPrint(
        '[hibiki-audiobook] inject(regular) chapter=$_currentChapterHref '
        'cues=${cues.length} sasayaki=$sasayaki',
      );

      if (sasayaki) {
        // Sasayaki 模式不做句级 annotate（cue 位置由 normChar 偏移编码）；
        // 只需把 sectionIndex → DOM id 映射拉起来，高亮时现场定位。
        final int? ttuId = _extractTtuBookId();
        if (ttuId != null && ttuId > 0) {
          await AudiobookBridge.initSasayakiRefs(
            controller,
            ttuBookId: ttuId,
          );
        } else {
          debugPrint(
            '[hibiki-audiobook] sasayaki init skipped: ttuBookId missing',
          );
        }
      } else if (cues.isEmpty) {
        // 无预对齐 cue，用自动标注
        await AudiobookBridge.annotate(
          controller,
          chapterHref: _currentChapterHref,
        );
      }
    }
  }

  /// currentCue 变化时高亮对应 DOM 元素。
  void _onCueChanged() async {
    if (!mounted || !_controllerInitialised) {
      return;
    }
    final AudiobookPlayerController? controller = _audiobookController;
    final AudioCue? cue = controller?.currentCue;
    debugPrint(
      '[hibiki-audiobook-diag] _onCueChanged: '
      'cue=${cue?.textFragmentId ?? "NULL"} '
      'pos=${controller?.position?.inMilliseconds}ms '
      'followAudio=${controller?.followAudio.value} '
      'hasPlayed=${controller?.hasPlayedOnce} '
      'restoreInFlight=$_restoreInFlight',
    );
    final bool showFloatingLyric = appModelNoUpdate.showFloatingLyric;
    if (showFloatingLyric && controller != null) {
      unawaited(FloatingLyricChannel.setPlaybackState(
        playing: controller.isPlaying,
      ));
    }
    // cue 属于不同章节时不高亮——防止异步跨章 nav 完成后、用户已手动翻走的
    // 场景下，旧章 cue 被错误地高亮到新章 DOM 上。
    if (cue != null && _currentTtuSection >= 0) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag != null) {
        if (frag.sectionIndex != _currentTtuSection) {
          if (mounted) {
            AudiobookBridge.highlight(_controller, cue: null);
          }
          return;
        }
        if (_pendingNavSection != null &&
            frag.sectionIndex == _currentTtuSection &&
            mounted) {
          setState(() => _pendingNavSection = null);
        }
      }
    }
    if (controller?.isImagePaused ?? false) return;
    final bool forceReveal = controller?.consumeForceReveal() ?? false;
    final bool reveal =
        forceReveal || (controller?.shouldRevealCurrentCue ?? true);
    if (reveal && (controller?.imagePauseSec.value ?? 0) > 0) {
      AudiobookBridge.saveScrollPos(_controller);
    }
    if (!mounted) return;
    await AudiobookBridge.highlight(_controller, cue: cue, reveal: reveal);
    if (!mounted) return;
    if (showFloatingLyric && cue != null) {
      FloatingLyricChannel.updateText(cue.text);
    }
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    _maybeImagePause(controller);
  }

  /// 高亮后检查视口中是否出现新图片，触发图片暂停。
  Future<void> _maybeImagePause(AudiobookPlayerController? controller) async {
    if (controller == null) return;
    if (controller.imagePauseSec.value <= 0) return;
    if (!controller.isPlaying) return;
    if (controller.isImagePaused) return;
    final bool hasNew = await AudiobookBridge.checkNewImage(_controller);
    if (hasNew && controller.isPlaying) {
      controller.triggerImagePause();
    }
  }

  // ── PR8b Follow audio wiring ────────────────────────────────────────────

  /// 把 Follow audio / 延迟 / 速度 的持久化回调和跨章事件挂到控制器上。
  /// 常规 EPUB audiobook 路径走这里；SRT-book 路径暂不落库（见 caller 注释）。
  void _wireFollowAudio(
    AudiobookPlayerController controller, {
    required String bookUid,
    required AudiobookRepository repo,
  }) {
    controller.onFollowAudioPersist = (bool value) async {
      await repo.updateFollowAudio(bookUid: bookUid, value: value);
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
    controller.onCrossChapter = _handleCueCrossChapter;
    controller.getCurrentReaderSection = () => _currentTtuSection;
    controller.onBoundarySkip = _handleBoundarySkip;
    controller.getReaderViewportPos = () async {
      final ReaderViewportPos? vp =
          await AudiobookBridge.getViewportNormOffset(_controller);
      if (vp == null) return null;
      return (section: vp.section, offset: vp.offset);
    };
  }

  Future<void> _wireMediaNotification(
      AudiobookPlayerController controller) async {
    final handler = appModelNoUpdate.audioHandler;
    if (handler == null) return;
    if (!appModelNoUpdate.showMediaNotification) {
      handler.clearNotification();
      return;
    }

    final String bookTitle = widget.item?.title ?? 'Audiobook';

    Uri? artUri;
    final String? base64Img = widget.item?.base64Image;
    if (base64Img != null) {
      try {
        final UriData? data = Uri.parse(base64Img).data;
        if (data != null) {
          final dir = await getTemporaryDirectory();
          final coverFile = File(p.join(dir.path, 'hibiki_cover.png'));
          await coverFile.writeAsBytes(data.contentAsBytes());
          artUri = coverFile.uri;
        }
      } catch (e) {
        debugPrint('[hibiki-notif] cover write failed: $e');
      }
    }

    if (!mounted || _audiobookController != controller) return;

    handler.setMediaItemInfo(
      title: bookTitle,
      duration: controller.duration,
      artUri: artUri,
    );
    handler.updatePlaybackState(
      playing: controller.isPlaying,
      position: controller.position,
      speed: controller.speed,
      duration: controller.duration,
    );

    controller.removeListener(_onMediaNotificationUpdate);
    controller.addListener(_onMediaNotificationUpdate);

    _notifPlaySub?.cancel();
    _notifPlaySub = appModelNoUpdate.playStream.listen((_) {
      controller.togglePlayPause();
    });
    _notifSkipNextSub?.cancel();
    _notifSkipNextSub = appModelNoUpdate.skipNextStream.listen((_) {
      controller.skipToNextCue();
    });
    _notifSkipPrevSub?.cancel();
    _notifSkipPrevSub = appModelNoUpdate.skipPreviousStream.listen((_) {
      controller.skipToPrevCue();
    });
  }

  void _onMediaNotificationUpdate() {
    final controller = _audiobookController;
    if (controller == null) return;
    final handler = appModelNoUpdate.audioHandler;
    if (handler == null) return;
    handler.updatePlaybackState(
      playing: controller.isPlaying,
      position: controller.position,
      speed: controller.speed,
      duration: controller.duration,
    );
    handler.updateNotificationSubtitle(
      title: widget.item?.title ?? 'Audiobook',
      subtitle: appModelNoUpdate.showSubtitlesInNotification
          ? controller.currentCue?.text
          : null,
    );
  }

  /// cue 跨章时由控制器触发。
  ///
  /// Follow=ON：立刻请求 ttu 跳章；记 `_inFlightNavSection` 避免 ttu 回来
  /// 的 sectionChanged 又被当成用户意图。失败降级为 pill。
  /// Follow=OFF：显示 pill "→ 第 N 章"，点了手动跳。
  Future<void> _handleCueCrossChapter(int newSection) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null || !_controllerInitialised) return;
    // 位置恢复期间拒绝 Follow audio 的跨章跳转：否则音频 cue 一推，reader
    // 就从恢复目标章被带走（用户期望的 "回到上次位置" 变成 "跑到音频章"）。
    // 等 _finishRestore 清了 _restoreInFlight 再放开。
    if (_restoreInFlight) {
      debugPrint(
        '[hibiki-reader-pos] cross-chapter suppressed during restore '
        '(newSection=$newSection)',
      );
      return;
    }
    if (_dropStaleSectionNavigation(newSection, 'cue-cross-chapter')) {
      return;
    }

    if (controller.followAudio.value) {
      _inFlightNavSection = newSection;
      _armNavRestoreTimeout(newSection, controller);
      // ttu 重新挂载了章节 DOM，旧 cueMap 里的 span 已经游离。清 Dart 守卫，
      // sectionChanged(auto=true) 到达后 _applySasayakiCuesForSection 重建。
      _lastSasayakiAppliedSection = -1;
      try {
        await AudiobookBridge.requestSectionNav(
          _controller,
          sectionIndex: newSection,
        );
      } catch (e) {
        debugPrint('[hibiki-audiobook] requestSectionNav failed: $e');
        _completeNavRestore(
          controller: controller,
          currentReaderSection: _currentTtuSection,
          success: false,
        );
        if (mounted) {
          setState(() => _pendingNavSection = newSection);
        }
      }
      // 成功路径不在这里 notify —— evaluateJavascript 不 await JS Promise，
      // 在这里 notify 会提前清 _chapterTransition，期间下一条 cue tick 再
      // 触发跨章、scrollTop 被第二次清零到章首。改为等 ttu 真正跳完从 Wn
      // 推 sectionChanged(auto=true, idx==newSection) 回来，由
      // _handleTtuSectionChanged 调 _completeNavRestore。Timer 兜底 3s。
    } else {
      // Follow=OFF：不自动跳章，只显示 pill。controller 不会触发 onCrossChapter
      // 这条路径（_maybeEmitCrossChapter 已用 followAudio 守卫），但保险起见
      // 走 fallback 也清一下守卫。
      controller.notifySectionRestoreCompleted(
        currentReaderSection: _currentTtuSection,
        success: false,
      );
      if (mounted) {
        setState(() => _pendingNavSection = newSection);
      }
    }
  }

  /// 挂 3s 跳章兜底 Timer：ttu 没在期限内推 `sectionChanged(target,
  /// auto=true)` 回来（fork 缺失 / ttu 内部 5s 超时）时，强制 notify 一次
  /// 让 `_chapterTransition` 释放，不然 cue 推进永久卡死。3s 落在 ttu
  /// 自身 5s 超时之前，先走 pill 降级，体感比干等 5s 好。
  void _armNavRestoreTimeout(
    int newSection,
    AudiobookPlayerController controller,
  ) {
    _navRestoreTimeout?.cancel();
    _navRestoreTimeout = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_inFlightNavSection != newSection) return;
      debugPrint(
        '[hibiki-audiobook] nav restore timeout, section=$newSection',
      );
      _completeNavRestore(
        controller: controller,
        currentReaderSection: _currentTtuSection,
        success: false,
      );
      if (mounted) {
        setState(() => _pendingNavSection = newSection);
      }
    });
  }

  /// 统一跳章完成出口：取消兜底 Timer、清 in-flight 标记、调 notifyRestore。
  /// 成功路径由 [_handleTtuSectionChanged] 在 auto=true 命中 target 时调用；
  /// 失败路径由 Timer / requestSectionNav catch 调用。
  void _completeNavRestore({
    required AudiobookPlayerController controller,
    required int currentReaderSection,
    required bool success,
  }) {
    _navRestoreTimeout?.cancel();
    _navRestoreTimeout = null;
    _inFlightNavSection = null;
    _lastNavRestoreTime = DateTime.now();
    controller.notifySectionRestoreCompleted(
      currentReaderSection: currentReaderSection,
      success: success,
    );
  }

  /// 跳章成功后：先建 cueMap，再通知 controller 跳章完成。
  /// 拆出来是因为 _handleTtuSectionChanged 是 void，这里需要 await。
  Future<void> _applyThenCompleteNav(int idx) async {
    await _applySasayakiCuesForSection(idx);
    if (!mounted) return;
    unawaited(_applyHighlightsForCurrentSection());
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller != null) {
      if (!_restoreInFlight) {
        await _persistReaderPosForCue(
          controller.currentCue,
          'follow-audio',
        );
      }
      _completeNavRestore(
        controller: controller,
        currentReaderSection: idx,
        success: true,
      );
    } else {
      _navRestoreTimeout = null;
      _inFlightNavSection = null;
    }
    if (_restoreInFlight && _pendingRestorePos != null) {
      await _finishRestore();
    }
  }

  /// pill 被点击时的跳章入口；成功后清空 pill。
  Future<void> _followPillTap() async {
    final int? target = _pendingNavSection;
    if (target == null) return;
    if (_dropStaleSectionNavigation(target, 'follow-pill')) {
      return;
    }
    _inFlightNavSection = target;
    try {
      await AudiobookBridge.requestSectionNav(
        _controller,
        sectionIndex: target,
      );
      _currentTtuSection = target;
      // ttu 换过 DOM，cueMap 旧 span 作废，清 apply 守卫。
      _lastSasayakiAppliedSection = -1;
      if (mounted) setState(() => _pendingNavSection = null);
    } catch (e) {
      debugPrint('[hibiki-audiobook] pill tap requestSectionNav failed: $e');
      Fluttertoast.showToast(msg: t.follow_audio_jump_failed);
    }
  }

  /// 句子跳转到章节边界时（整本书首句/末句），跳到相邻章节第一句。
  Future<void> _handleBoundarySkip(int delta) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final int targetSec = _currentTtuSection + delta;
    if (targetSec < 0) return;
    if (_dropStaleSectionNavigation(targetSec, 'boundary-skip')) {
      return;
    }
    final List<AudioCue> allCues = controller.chapterCuesSnapshot;
    final List<AudioCue> targetCues = allCues.where((c) {
      final frag = SasayakiMatchCodec.tryDecode(c.textFragmentId);
      return frag != null && frag.sectionIndex == targetSec;
    }).toList();
    if (targetCues.isEmpty) return;
    await controller.skipToCue(targetCues.first);
  }

  /// 为指定章节预建 Sasayaki cueMap。由 sectionChanged 和 bootstrap 触发。
  Future<void> _applySasayakiCuesForSection(int sectionIndex) async {
    if (sectionIndex < 0) return;
    if (_dropStaleSectionNavigation(sectionIndex, 'apply-cues')) {
      return;
    }
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null || !_controllerInitialised) return;
    if (_lastSasayakiAppliedSection == sectionIndex) return;
    _lastSasayakiAppliedSection = sectionIndex;
    final List<AudioCue> cues = controller.sasayakiCuesForSection(sectionIndex);
    if (cues.isEmpty) {
      _lastSasayakiAppliedSection = -1;
      return;
    }
    debugPrint(
      '[hibiki-audiobook] applySasayakiCues section=$sectionIndex cues=${cues.length}',
    );
    try {
      await AudiobookBridge.applySasayakiCues(
        _controller,
        sectionIndex: sectionIndex,
        cues: cues,
      );
      if (!mounted) return;
      if (_currentTtuSection != sectionIndex) {
        debugPrint(
          '[hibiki-audiobook] applySasayakiCues stale: applied=$sectionIndex '
          'but reader now at $_currentTtuSection, discarding',
        );
        _lastSasayakiAppliedSection = -1;
        return;
      }
      // cue map 就绪后重新高亮当前 cue 并对齐页面
      _onCueChanged();
    } catch (e) {
      debugPrint('[hibiki-audiobook] applySasayakiCues failed: $e');
      _lastSasayakiAppliedSection = -1;
    }
  }

  /// 一本书 WebView 生命周期里第一次 bootstrap —— 读 Isar 的保存位置，
  /// 决定是跳章还是什么都不做。
  ///
  /// 调用时机：[_maybeInjectAudiobookBridge] 末尾（Sasayaki refs 已在路上
  /// 加载、_bootstrapCurrentTtuSection 已 probe 过 `_currentTtuSection`）。
  ///
  /// 两种路径：
  /// - saved.section == _currentTtuSection → [_finishRestore] 当场
  ///   scrollToNormOffset。
  /// - saved.section != _currentTtuSection → `requestSectionNav`，跳完
  ///   sectionChanged(auto=true) 触发 [_finishRestore]。
  ///
  /// 无记录（新书）：置 `_didRestorePos=true` 立即返回。
  Future<void> _bootstrapRestoreReaderPos() async {
    if (_didRestorePos) {
      _markReaderContentReady();
      return;
    }
    if (!_controllerInitialised) {
      _markReaderContentReady();
      return;
    }
    // 先置 true —— 后面任何失败分支都不再重试（防止同一本书反复调 Isar）。
    // 真正需要重试时用户关书再开就行。
    _didRestorePos = true;
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null || ttuId <= 0) {
      debugPrint('[hibiki-reader-pos] restore skipped: no ttuId');
      _markReaderContentReady();
      return;
    }
    // 优先用 initState 预读的位置（省掉 onLoadStop 里的 Isar IO）。
    ReaderPosition? saved = _preloadedPos;
    if (saved == null) {
      try {
        saved = await ReaderPositionRepository(appModel.database)
            .findByTtuBookId(ttuId);
      } catch (e) {
        debugPrint('[hibiki-reader-pos] restore query err: $e');
        _markReaderContentReady();
        return;
      }
    }
    final Bookmark? jumpBm = widget.initialBookmarkJump;
    if (jumpBm != null) {
      debugPrint(
        '[hibiki-reader-pos] bookmark jump override: '
        's${jumpBm.sectionIndex}/o${jumpBm.normCharOffset}',
      );
      _pendingRestorePos = ReaderViewportPos(
        section: jumpBm.sectionIndex,
        offset: jumpBm.normCharOffset,
      );
    } else if (saved == null) {
      debugPrint('[hibiki-reader-pos] no saved pos for ttuId=$ttuId');
      _markReaderContentReady();
      return;
    } else {
      debugPrint(
        '[hibiki-reader-pos] bootstrap restore ttuId=$ttuId '
        'saved=s${saved.sectionIndex}/o${saved.normCharOffset} '
        'currentTtuSection=$_currentTtuSection',
      );
      _pendingRestorePos = ReaderViewportPos(
        section: saved.sectionIndex,
        offset: saved.normCharOffset,
      );
    }
    if (_pendingRestorePos == null) {
      _markReaderContentReady();
      return;
    }
    if (_dropStaleSectionNavigation(
      _pendingRestorePos!.section,
      jumpBm != null ? 'bookmark-restore' : 'saved-restore',
    )) {
      _markReaderContentReady();
      return;
    }
    final int targetSection = _pendingRestorePos!.section;
    final int targetOffset = _pendingRestorePos!.offset;
    _restoreInFlight = true;
    await _setJsRestoreFlag();
    if (_currentTtuSection == targetSection) {
      debugPrint(
        '[hibiki-reader-pos] same section, scrolling to o=$targetOffset',
      );
      await _finishRestore();
      return;
    }
    // 跨段：发 requestSectionNav，`_handleTtuSectionChanged` 的
    // `_inFlightNavSection` 分支会处理回报。
    _inFlightNavSection = targetSection;
    _lastSasayakiAppliedSection = -1;
    _readerRestoreNavAttempts = 0;
    try {
      await AudiobookBridge.requestSectionNav(
        _controller,
        sectionIndex: targetSection,
      );
      _armReaderRestoreNavTimeout(targetSection);
    } catch (e) {
      debugPrint('[hibiki-reader-pos] restore requestSectionNav err: $e');
      _restoreInFlight = false;
      _pendingRestorePos = null;
      _inFlightNavSection = null;
      _readerRestoreNavTimeout?.cancel();
      _readerRestoreNavTimeout = null;
      _readerRestoreNavAttempts = 0;
      unawaited(_clearJsRestoreFlag());
      _markReaderContentReady();
    }
  }

  void _armReaderRestoreNavTimeout(int targetSection) {
    _readerRestoreNavTimeout?.cancel();
    _readerRestoreNavTimeout = Timer(const Duration(seconds: 5), () {
      unawaited(_handleReaderRestoreNavTimeout(targetSection));
    });
  }

  Future<void> _handleReaderRestoreNavTimeout(int targetSection) async {
    if (!mounted || !_restoreInFlight) {
      return;
    }
    if (_pendingRestorePos?.section != targetSection ||
        _inFlightNavSection != targetSection) {
      return;
    }
    _readerRestoreNavAttempts++;
    if (_readerRestoreNavAttempts < 3) {
      debugPrint(
        '[hibiki-reader-pos] restore section nav slow, retry '
        '$_readerRestoreNavAttempts target=$targetSection',
      );
      try {
        await AudiobookBridge.requestSectionNav(
          _controller,
          sectionIndex: targetSection,
        );
        _armReaderRestoreNavTimeout(targetSection);
        return;
      } catch (e) {
        debugPrint('[hibiki-reader-pos] restore section nav retry err: $e');
      }
    }

    debugPrint(
      '[hibiki-reader-pos] restore section nav timeout, clearing flags',
    );
    _restoreInFlight = false;
    _pendingRestorePos = null;
    _inFlightNavSection = null;
    _readerRestoreNavTimeout = null;
    _readerRestoreNavAttempts = 0;
    final Completer<bool>? c = _scrollToNormOffsetCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(false);
    }
    final Completer<bool>? vc = _viewportStableCompleter;
    if (vc != null && !vc.isCompleted) {
      vc.complete(false);
    }
    await _clearJsRestoreFlag();
    _markReaderContentReady();
  }

  Future<void> _finishRestore() async {
    _readerRestoreNavTimeout?.cancel();
    _readerRestoreNavTimeout = null;
    _readerRestoreNavAttempts = 0;
    final ReaderViewportPos? pending = _pendingRestorePos;
    if (pending == null) {
      _restoreInFlight = false;
      await _clearJsRestoreFlag();
      _markReaderContentReady();
      return;
    }
    _pendingRestorePos = null;
    try {
      _scrollToNormOffsetCompleter = Completer<bool>();
      _viewportStableCompleter = Completer<bool>();
      _restoreTargetSection = pending.section;
      _restoreTargetOffset = pending.offset;
      await AudiobookBridge.scrollToNormOffset(
        _controller,
        section: pending.section,
        offset: pending.offset,
      );
      final bool scrollOk = await _scrollToNormOffsetCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      _scrollToNormOffsetCompleter = null;
      debugPrint(
        '[hibiki-reader-pos] scrolled s=${pending.section} '
        'o=${pending.offset} ok=$scrollOk',
      );
      if (scrollOk) {
        final bool stable = await _viewportStableCompleter!.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => false,
        );
        debugPrint(
          '[hibiki-reader-pos] viewportStable '
          '${stable ? "reached" : "timeout/failed"}',
        );
      }
      _viewportStableCompleter = null;
    } catch (e) {
      debugPrint('[hibiki-reader-pos] scrollToNormOffset err: $e');
      _scrollToNormOffsetCompleter = null;
      _viewportStableCompleter = null;
    } finally {
      _restoreInFlight = false;
      await _clearJsRestoreFlag();
      _markReaderContentReady();
    }
  }

  /// 处理 ttu fork 外发的 sectionChanged console 事件。
  ///
  /// auto=true 只来自 `__sasayakiRequestNav`（我们自己的跳章请求），
  /// 只在 idx 匹配 [_inFlightNavSection] 时接受并更新 `_currentTtuSection`，
  /// 其余（中间段 / stale 延迟事件）全部丢弃。
  /// auto=false 来自用户 swipe / ToC，始终接受并走 [_autoOffFollowOnManualTurn]。
  void _handleTtuSectionChanged(Map<String, dynamic> json) {
    final int? idx = (json['sectionIndex'] as num?)?.toInt();
    final bool auto = json['auto'] == true;
    debugPrint(
      '[hibiki-audiobook-diag] {"hibiki-message-type":"ttuSectionChanged","idx":$idx,"auto":$auto,"inFlight":$_inFlightNavSection,"restoreInFlight":$_restoreInFlight,"pendingRestoreSec":${_pendingRestorePos?.section}}',
    );
    if (idx == null) return;
    unawaited(AudiobookBridge.clearSeenImages(_controller));
    // auto=true 只来自我们自己的 __sasayakiRequestNav，只认匹配
    // _inFlightNavSection 的那条（导航到达目标段），其余（中间段 /
    // 导航完成后的 stale 延迟事件）全部丢弃，不更新 _currentTtuSection。
    if (auto) {
      if (_inFlightNavSection == idx) {
        setState(() {
          _currentTtuSection = idx;
        });
        _navRestoreTimeout?.cancel();
        _readerRestoreNavTimeout?.cancel();
        _readerRestoreNavTimeout = null;
        _readerRestoreNavAttempts = 0;
        unawaited(_applyThenCompleteNav(idx));
      } else if (_inFlightNavSection == null) {
        setState(() {
          _currentTtuSection = idx;
        });
        _lastSasayakiAppliedSection = -1;
        unawaited(_applySasayakiCuesForSection(idx));
        unawaited(_applyHighlightsForCurrentSection());
      }
      return;
    }
    // auto=false：用户 swipe / ToC 翻页，始终更新 _currentTtuSection。
    if (!_didRestorePos) {
      debugPrint(
        '[hibiki-reader-pos] ignoring pre-bootstrap sectionChanged idx=$idx',
      );
      return;
    }
    setState(() {
      _currentTtuSection = idx;
    });
    // 用户手动翻章时，废弃正在进行的程序化跳章——否则旧的
    // _applyThenCompleteNav 异步完成后会用错误章节的 cueMap 覆盖当前章。
    if (_inFlightNavSection != null) {
      debugPrint(
        '[hibiki-audiobook] manual turn cancels in-flight nav '
        'to section $_inFlightNavSection',
      );
      _navRestoreTimeout?.cancel();
      _navRestoreTimeout = null;
      _readerRestoreNavTimeout?.cancel();
      _readerRestoreNavTimeout = null;
      _readerRestoreNavAttempts = 0;
      _inFlightNavSection = null;
      _audiobookController?.cancelChapterTransition();
    }
    // 程序化跳章完成后 ttu 有时紧接推一个 auto=false 的 settle 事件。
    // 如果在 500ms 窗口内，跳过 auto-off 防止误关 follow audio。
    final DateTime? lastNav = _lastNavRestoreTime;
    final bool recentNav = lastNav != null &&
        DateTime.now().difference(lastNav).inMilliseconds < 500;
    if (!recentNav) {
      _autoOffFollowOnManualTurn();
    }
    // 不在这里写 offset:0 —— scroll listener 的 500ms debounce 会带上
    // 真实偏移。急着写 0 会覆盖用户上次在本章的有效存档。
    // 用户翻到新章节，预建该章 Sasayaki cueMap。
    unawaited(_applySasayakiCuesForSection(idx));
    unawaited(_applyHighlightsForCurrentSection());
    unawaited(_refreshPageProgress());
  }

  // ── 有声书导入按钮 ──────────────────────────────────────────────────────────

  /// 右下角耳机图标，仅在无有声书时显示，点击打开导入对话框。
  Widget buildAudiobookImportButton() {
    return const SizedBox.shrink();
  }

  Widget buildReaderSettingsFab() {
    if (_audiobookController != null) {
      return const SizedBox.shrink();
    }
    final String? bookUid = widget.item?.uniqueKey;
    final Widget bar = Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BottomAppBar(
            height: _readerChromeHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                if (bookUid != null)
                  IconButton(
                    icon: const Icon(Icons.headphones),
                    iconSize: 22,
                    onPressed: () => _openImportDialog(bookUid),
                    tooltip: t.audiobook_import,
                  ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.tune),
                  iconSize: 20,
                  onPressed: () => _showReaderSettingsSheet(null),
                  tooltip: t.reader_settings_label,
                ),
              ],
            ),
          ),
          SizedBox(height: _stableBottomInset),
        ],
      ),
    );
    final ThemeData? overrideTheme = appModel.overrideDictionaryTheme;
    if (overrideTheme != null) {
      return Theme(data: overrideTheme, child: bar);
    }
    return bar;
  }

  Future<void> _openImportDialog(String bookUid) async {
    // SrtBook 路径：直接给这本字幕书补音频，不创建独立 Audiobook 记录。
    final int? ttuId = _extractTtuBookId();
    if (ttuId != null && ttuId > 0) {
      final SrtBookRepository srtRepo = SrtBookRepository(appModel.database);
      SrtBook? srtBook;
      for (final SrtBook b in await srtRepo.listAll()) {
        if (b.ttuBookId == ttuId) {
          srtBook = b;
          break;
        }
      }
      if (srtBook != null) {
        await _attachAudioToSrtBook(srtBook, srtRepo);
        return;
      }
    }

    // 若是 ttu 里的真 EPUB（带 ?id=N）且本地服务已启动，把 ttuBookId +
    // serverPort 一并传给 dialog，SRT 对齐时才会跑 Sasayaki 文本匹配，把
    // cue 位置编码到 textFragmentId（否则 cue 只带默认 `[data-cue-id]`，
    // 在没有 data-cue-id 的真 EPUB 上点不到也高亮不了）。
    final int? ttuBookIdForDialog = _extractTtuBookId();
    final int? serverPort = ref
        .read(ttuServerProvider(appModel.targetLanguage))
        .valueOrNull
        ?.boundPort;

    final bool? result = await showDialog<bool>(
      context: context,
      builder: (_) => AudiobookImportDialog(
        bookUid: bookUid,
        repo: AudiobookRepository(appModel.database),
        ttuBookId: ttuBookIdForDialog,
        serverPort: serverPort,
      ),
    );
    // result == true 表示用户完成导入，重新初始化播放器；
    // result == false 表示用户移除，拆掉内存中的控制器/播放条。
    if (!mounted) return;
    if (result == true) {
      await _initAudiobookIfAvailable();
    } else if (result == false) {
      _tearDownAudiobook();
    }
  }

  /// 用户从对话框里移除有声书后调用。拆 listener、dispose 控制器、清掉
  /// SrtBook 关联状态，并 setState 让播放条消失、耳机 FAB 重新出现。
  /// Isar 那边 deleteAudiobook 已经由对话框负责；这里只管内存状态。
  void _tearDownAudiobook() {
    _notifPlaySub?.cancel();
    _notifSkipNextSub?.cancel();
    _notifSkipPrevSub?.cancel();
    appModelNoUpdate.audioHandler?.clearNotification();
    final AudiobookPlayerController? ctrl = _audiobookController;
    ctrl?.removeListener(_onCueChanged);
    ctrl?.removeListener(_onMediaNotificationUpdate);
    ctrl?.dispose();
    setState(() {
      _audiobookController = null;
      _srtBookUid = null;
      _hasAudioSlot = false;
    });
  }

  /// 给已存在的 [SrtBook] 补音频：action sheet 选"目录"或"多文件"，
  /// 更新 [SrtBook.audioRoot] / [SrtBook.audioPaths] 后重新初始化播放器。
  Future<void> _attachAudioToSrtBook(
    SrtBook book,
    SrtBookRepository repo,
  ) async {
    final _SrtAudioSource? source = await showModalBottomSheet<_SrtAudioSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(t.srt_import_pick_audio_dir),
              onTap: () => Navigator.pop(ctx, _SrtAudioSource.folder),
            ),
            ListTile(
              leading: const Icon(Icons.audio_file),
              title: Text(t.srt_import_pick_audio_files),
              onTap: () => Navigator.pop(ctx, _SrtAudioSource.files),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    String? newDir;
    List<String>? newPaths;
    if (source == _SrtAudioSource.folder) {
      newDir = await FilePicker.platform.getDirectoryPath();
      if (newDir == null) return;
    } else {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result == null) return;
      newPaths = result.files.map((f) => f.path).whereType<String>().toList()
        ..sort();
      if (newPaths.isEmpty) return;
    }

    // file_picker 返回的路径在 cache/ 下，Android 随时会清理。
    // 把音���文件复制到持久目录再存路径。
    if (newPaths != null && newPaths.isNotEmpty) {
      final Directory docs = await getApplicationDocumentsDirectory();
      final String hash = book.uid.hashCode.toRadixString(16);
      final Directory persistDir =
          Directory(p.join(docs.path, 'audiobooks', hash));
      if (!persistDir.existsSync()) {
        persistDir.createSync(recursive: true);
      }
      final List<String> persisted = [];
      for (final String src in newPaths) {
        final File srcFile = File(src);
        if (srcFile.path.startsWith(persistDir.path)) {
          persisted.add(src);
        } else {
          final String dest = p.join(persistDir.path, p.basename(src));
          await srcFile.copy(dest);
          persisted.add(dest);
        }
      }
      newPaths = persisted;
    }

    book.audioRoot = newDir;
    book.audioPaths = newPaths;
    debugPrint('[hibiki-audiobook] before save: uid=${book.uid} id=${book.id} '
        'audioPaths=${book.audioPaths} audioRoot=${book.audioRoot}');
    try {
      await repo.save(book);
    } catch (e, st) {
      debugPrint('[hibiki-audiobook] save failed: $e\n$st');
      Fluttertoast.showToast(msg: t.srt_audio_load_error);
      return;
    }

    // 读回校验：保存后立刻重新查同一 uid，看 DB 实际保存了什么。
    final SrtBook? reread = await repo.findByUid(book.uid);
    debugPrint('[hibiki-audiobook] attached audio to SrtBook ${book.uid}: '
        'saved paths=$newPaths root=$newDir '
        '-> reread audioPaths=${reread?.audioPaths} '
        'audioRoot=${reread?.audioRoot} '
        'ttuBookId=${reread?.ttuBookId}');

    // 同时 dump 所有 SrtBook，看是否有同 ttuBookId 冲突
    final List<SrtBook> all = await repo.listAll();
    for (final SrtBook b in all) {
      debugPrint('[hibiki-audiobook]   DB entry: uid=${b.uid} '
          'ttuBookId=${b.ttuBookId} '
          'audioPaths=${b.audioPaths} audioRoot=${b.audioRoot}');
    }

    if (mounted) {
      await _initAudiobookIfAvailable();
    }
  }

  // ── 有声书底部播放条 ────────────────────────────────────────────────────────

  /// 底部播放控制条。仅在 [_audiobookController] 非 null 且用户未关闭时显示。
  Widget buildAudiobookBar() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    if (ctrl == null || !appModel.showPlayBar) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: Listenable.merge([ctrl, _barThemeNotifier]),
      builder: (context, _) {
        final barWidget = Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildFollowPill(),
              AudiobookPlayBar(
                controller: ctrl,
                onOpenSettings: () => _showReaderSettingsSheet(ctrl),
              ),
              SizedBox(height: _stableBottomInset),
            ],
          ),
        );
        final ThemeData? overrideTheme = appModel.overrideDictionaryTheme;
        if (overrideTheme != null) {
          return Theme(data: overrideTheme, child: barWidget);
        }
        return barWidget;
      },
    );
  }

  /// Follow=OFF 跨章时的悬浮 pill。点击跳章，成功后自动消失。
  /// 没有 pending 时返回空 widget（SizedBox）——不占高度不留白。
  Widget _buildFollowPill() {
    final int? target = _pendingNavSection;
    if (target == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, left: 12, right: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _followPillTap,
          icon: const Icon(Icons.arrow_forward, size: 16),
          label: Text(_tocLabels[target] ?? t.go_to_chapter(n: target + 1)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
  }
}

enum _SrtAudioSource { folder, files }
