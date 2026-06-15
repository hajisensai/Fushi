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
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/highlight_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki/src/media/audiobook/mining_sentence_draft.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState, MinePopupResult;
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
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/media/audiobook/pointer_seek.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/debug_log_service.dart';
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
import 'package:hibiki/src/shortcuts/dictionary_caret_controller.dart';
// Re-export so existing references to `CaretSurface` via the reader page,
// and the source-scan guards that read this file, still resolve the enum
// after its definition moved into the shared caret controller (TODO-387).
export 'package:hibiki/src/shortcuts/dictionary_caret_controller.dart'
    show CaretSurface;
import 'package:hibiki/src/shortcuts/reader_space_override.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

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

/// 桌面悬浮字幕条点词时，从整句文本与点击字符索引解析出真正要查的词
/// （TODO-376）。优先用语言分词器 [Language.wordFromIndex] 切出的 [word]；切不出
/// （空白 / 标点 / 引擎未就绪）则回退整句 [text]。两者皆空返回空串，调用方据此
/// no-op。提取成顶层纯函数便于单测，不必驱动整个阅读器页面。
String floatingLyricSearchTerm({
  required String text,
  required int index,
  required String word,
}) {
  final String trimmedWord = word.trim();
  if (trimmedWord.isNotEmpty) return trimmedWord;
  return text.trim();
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

/// 视口尺寸变化是否大到需要重排分页（BUG-210 / TODO-146）。
///
/// 桌面端用户报「翻页有时跳回章节开头」。根因不在 JS `paginate`（真实 Chromium
/// 引擎下逐页步进稳健，BUG-169 修复有效），而在 [_ReaderHibikiPageState._syncPageSize]
/// 的旧判定：宽度用**精确浮点不等** `w != _lastSyncedWidth`（零容差），高度才用
/// `(h - last).abs() >= 1`（1px 容差）。Windows 桌面（`flutter_inappwebview_windows`
/// fork 渲染 EPUB）在翻页/重绘时常报 sub-pixel 视口宽抖动，零容差让任意 0.x px 宽差
/// 都判 `widthChanged` → 走整章重载（`_navigateToChapter` 重新 load + 粗粒度 progress
/// 恢复）：progress 分辨率低 → 落到错误的、通常更靠前的页（progress<=0 时直接
/// `scrollToProgressPaged` 回 `contentFirstPageScroll` = 章节开头），即用户感知的
/// 「翻页跳回章节开头」。
///
/// 修复 = 让宽、高用**同一个 1px 容差**判定（消除「宽零容差」这个特例）。真正的
/// 旋转 / 窗口 resize 宽度大变（远 > 1px）仍照常重排，零破坏。返回 `(width, height)`
/// 两个布尔，调用方据此分别决定整章重载（宽变）或原地重排（高变）。
({bool width, bool height}) readerViewportNeedsRepaginate({
  required double width,
  required double height,
  required double lastWidth,
  required double lastHeight,
  double tolerancePx = 1.0,
}) {
  final bool widthChanged =
      lastWidth > 0 && (width - lastWidth).abs() >= tolerancePx;
  final bool heightChanged = (height - lastHeight).abs() >= tolerancePx;
  return (width: widthChanged, height: heightChanged);
}

/// 阅读器主题用的四个颜色角色：正文背景、正文字色、私语(振假名/sasayaki)叠色、
/// 是否暗色。preset 主题在 [_ReaderHibikiPageState._themeMap] 里手调，其余主题
/// （light-theme / system-theme / 任意未覆盖的 key）由 [resolveReaderThemeColors]
/// 回落到真实 ColorScheme 派生，避免再写死成白底（BUG-208 / TODO-143）。
typedef ReaderThemeColors = ({Color bg, Color fg, Color sasayaki, bool dark});

/// 把当前主题 key 解析成阅读器的四个颜色角色。
///
/// 关键修复（BUG-208 / TODO-143）：旧逻辑只查私有 [presetMap]，命中失败就硬编码
/// 白底/黑字/默认私语色。但 `themePresets` 里还有 `light-theme`，且**默认主题**是
/// `system-theme`，两者都不在 presetMap 中，于是阅读器背景永远是白色——无论系统
/// 强调色或明暗如何，「书籍背景没吃主题」。
///
/// 现在：
/// - `custom-theme`：用用户自定义的背景/字色/私语色（与旧行为一致）。
/// - presetMap 命中（ecru/water/gray/dark/black）：用手调底色（向后兼容，零变化）。
/// - 其余（light-theme / system-theme / 未来新增 key）：从真实 [scheme] 派生
///   surface/onSurface/brightness，让阅读器背景真正跟随当前主题。
ReaderThemeColors resolveReaderThemeColors({
  required String themeKey,
  required Map<String, ReaderThemeColors> presetMap,
  required ColorScheme scheme,
  ReaderThemeColors? customColors,
}) {
  if (themeKey == 'custom-theme' && customColors != null) {
    return customColors;
  }
  final ReaderThemeColors? preset = presetMap[themeKey];
  if (preset != null) {
    return preset;
  }
  // light-theme / system-theme / 未覆盖的 key：跟随真实 ColorScheme。
  final bool dark = scheme.brightness == Brightness.dark;
  return (
    bg: scheme.surface,
    fg: scheme.onSurface,
    sasayaki: scheme.primary.withValues(alpha: dark ? 0.34 : 0.40),
    dark: dark,
  );
}

/// 本 session 阅读字数推进结果：[charsAdded] 本次新计入的字数（>=0），
/// [highWaterMark] 更新后的「本 session 历史最高已读绝对字符位置」（只升不降）。
typedef ReadProgressResult = ({int charsAdded, int highWaterMark});

/// TODO-147 / BUG-211：把「本 session 阅读字数推进」算成相对历史最高已读位置
/// （high-water mark）的增量，而不是相邻两次采样的正向差。
///
/// 旧逻辑（错）：每次进度回调 `charDiff = absolute - last; if(charDiff>0) chars+=charDiff;
/// last = absolute;`——`last` 无条件下移。日语精读常见的「读一句→往回看→再往前」
/// 往返翻页会把重叠区间反复计入，统计字数随往返次数倍增，呈现「字数明显非常高」。
///
/// 新逻辑（对）：只有当前绝对位置 [absoluteChars] **超过本 session 历史最高位置**
/// [highWaterMark] 时，才把超出部分计入，并抬高水位；回退、以及再前进经过旧区间都
/// 不重复计数。水位「只升不降」消除了往返重复这个特殊情况（导航/flush 时由调用方把
/// 水位重置到新 session 起点）。
///
/// 纯函数，无副作用，供单测锁定 high-water mark 语义（撤销修复 → 测试转红）。
ReadProgressResult accumulateSessionChars({
  required int absoluteChars,
  required int highWaterMark,
}) {
  if (absoluteChars > highWaterMark) {
    return (
      charsAdded: absoluteChars - highWaterMark,
      highWaterMark: absoluteChars,
    );
  }
  return (charsAdded: 0, highWaterMark: highWaterMark);
}

/// BUG-213：章内原生滚动回传（`onReaderScroll`）到来时，是否应刷新章内进度。
///
/// 章内进度 UI 字段只在 `_refreshProgress()` 里写；原生滚动（连续模式 window 滚动、
/// 分页模式触摸/trackpad/键盘箭头）此前没有任何刷新通道，进度条要等 10s 轮询或翻章才
/// 更新。setup 脚本新增的 scroll reporter 把滚动回传给这里，但必须在以下时机一律抑制，
/// 避免恢复期程序化滚动、歌词模式或控制器未就绪时误触发：
/// - [restoreInFlight]：章节恢复/重载期间 WebView 正被程序化滚动到锚点；
/// - [lyricsMode]：歌词模式不是正文阅读，无章内进度语义；
/// - !`readerContentReady`：内容尚未就绪，`hoshiProgressDetails` 可能算不出总数；
/// - !`controllerAvailable`：WebView 控制器已释放（dispose 竞态）。
///
/// 纯函数，无副作用，供单测锁定门控真值表（撤销任一守卫 → 对应用例转红）。
bool readerScrollProgressRefreshAllowed({
  required bool readerContentReady,
  required bool restoreInFlight,
  required bool lyricsMode,
  required bool controllerAvailable,
}) {
  return readerContentReady &&
      !restoreInFlight &&
      !lyricsMode &&
      controllerAvailable;
}

typedef ReaderStableProgressDetails = ({
  int current,
  int total,
  double progress,
  int charOffset,
});

/// Parses `window.hoshiProgressDetails()` after the JS-side settled gate.
///
/// A stable `0,total,0` is a valid chapter-start position (manual chapter
/// jumps must still persist it). `null`/empty/invalid/zero-total results mean
/// the reader has not settled enough to make a durable position decision.
ReaderStableProgressDetails? parseReaderStableProgressDetails(dynamic result) {
  if (result == null) return null;
  final String str = result.toString().replaceAll('"', '').trim();
  if (str.isEmpty) return null;

  final List<String> parts = str.split(',');
  if (parts.length < 2) return null;
  final int? current = int.tryParse(parts[0]);
  final int? total = int.tryParse(parts[1]);
  if (current == null || total == null || total <= 0) return null;

  final int charOffset =
      parts.length >= 3 ? (int.tryParse(parts[2]) ?? -1) : -1;
  return (
    current: current,
    total: total,
    progress: (current / total).clamp(0.0, 1.0).toDouble(),
    charOffset: charOffset,
  );
}

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
///
/// TODO-131: 冷开书的首屏不需要逐章字符数（只进度/统计要）。开书路径优先用
/// [parseBookOnly] 拿渲染必需结构、再用 [charCountsFromChaptersJson] 复用导入时
/// 已落库的计数，整本 html_parser 计数仅在 DB 计数缺失时经 [countChapterChars]
/// 后台补算。此函数保留给等价性测试与不复用 DB 的旧路径。
ParsedBookData parseAndCountChapters(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  return ParsedBookData(book, countChapterChars(book));
}

/// TODO-131: 只解析渲染必需结构（章节 href / spine / 资源 / TOC / spread），不在
/// isolate 里逐章跑 html_parser 计数。供 compute() 调用——开书首屏走这条，把每章
/// 纯文本计数从「整本 isolate 计数」降到「只解析必要项」。
EpubBook parseBookOnly(String extractDir) {
  return EpubParser.parseFromExtracted(extractDir);
}

/// TODO-131: 从 [EpubBooks.chaptersJson]（导入时由 EpubImporter 写入的
/// `characters` 字段，值即 `chapterPlainText().length`）复用每章字符数，避免开书时
/// 对整本 EPUB 重跑 html_parser。
///
/// 仅当**每一章**都带合法非负 `characters` int、且条目数与 [expectedChapters]
/// 严格一致时返回计数列表；任一缺失/类型错误/数量不符返回 null，调用方回退到
/// 后台 [countChapterChars] 重算。这样旧书（导入早于该字段）与异常数据都安全降级，
/// 不会用错的总字数破坏进度/统计正确性。
List<int>? charCountsFromChaptersJson(
  String chaptersJson,
  int expectedChapters,
) {
  if (expectedChapters <= 0) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(chaptersJson);
  } on FormatException {
    return null;
  }
  if (decoded is! List || decoded.length != expectedChapters) return null;
  final List<int> counts = <int>[];
  for (final Object? entry in decoded) {
    if (entry is! Map) return null;
    final Object? raw = entry['characters'];
    if (raw is! int || raw < 0) return null;
    counts.add(raw);
  }
  return counts;
}

/// TODO-131: 书本磁盘定位结果。`_locateBookOnDisk` 与 profile/settings 链并行返回，
/// `bookRow` 携带 chaptersJson（供 DB 计数复用）；`exists` 为 false 时调用方提示
/// 文件丢失并退出。
class _BookLocateResult {
  const _BookLocateResult({
    required this.bookRow,
    required this.extractDir,
    required this.exists,
  });
  final EpubBookRow? bookRow;
  final String extractDir;
  final bool exists;
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
    with WidgetsBindingObserver
    implements ReaderAudiobookView, DictionaryCaretHost {
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

  /// 图片右键菜单由 Flutter PopupMenuRoute 承载，不在阅读器中和后的 chrome 子树内。
  /// 所以这里复用 reader chrome 的用户界面缩放口径，且只缩放菜单自身，不改鼠标锚点。
  double get _readerImageMenuScale =>
      HibikiAppUiScale.normalize(_readerChromeScale);

  /// 缩放后底栏在屏高度。所有把底栏高度喂给 WebView/光标/焦点环/正文预留的地方都
  /// 走这个 getter，保证视觉高度与预留高度恒等。
  double get _readerChromeHeight => ReaderChromeScaler.scaledHeight(
      _readerChromeBaseHeight, _readerChromeScale);
  static const double _infoFontSize = 12;

  int? _progressCurrentChars;
  int? _progressTotalChars;

  int _sessionCharsRead = 0;
  // TODO-147 / BUG-211：本 session 历史最高已读绝对字符位置（high-water mark，
  // 只升不降）。统计字数只在越过它时增量计入，往返翻页不重复累计。导航/后台
  // flush 起新 session 时由调用方重置到当前位置。
  int _sessionMaxAbsoluteChars = 0;
  DateTime _sessionStartTime = DateTime.now();

  List<int> _chapterCharCounts = [];
  List<int> _chapterCumulativeChars = [];

  final Map<String, Uint8List> _sanitizedCssCache = {};

  // BUG-270 (TODO-296 B): cross-chapter LRU cache of fully sanitized + style-
  // injected chapter HTML, keyed by absolute file path. The styleTag is baked
  // into each cached entry, so the cache MUST be dropped on every style
  // invalidation (see _invalidateStyleCache). Forward/back paging and prefetch
  // both hit this cache, turning a repeat chapter visit into an in-memory map
  // lookup instead of disk read + utf8 decode + sanitize + regex inject.
  static const int _kChapterHtmlCacheLimit = 6;
  final LinkedHashMap<String, Uint8List> _sanitizedHtmlCache =
      LinkedHashMap<String, Uint8List>();

  // BUG-270: in-flight prefetch dedup — the file path currently being warmed in
  // the background, so a navigation that lands on it does not race a second read.
  String? _prefetchingHtmlPath;

  String? _cachedStyleTag;

  Timer? _saveDebounce;

  /// 进程退出 flush 回调引用（TODO-086/BUG-191）：initState 登记到
  /// [ExitFlushRegistry]，dispose 注销。退出路径统一 await，保证未到 debounce
  /// 的阅读位置/统计在 exit(0) 前落库。
  ExitFlushCallback? _exitFlushCallback;
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
  List<FavoriteSentence>? _favoriteSentencesForBookCache;
  Future<List<FavoriteSentence>>? _favoriteSentencesForBookFuture;

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

  // TODO-291 阶段2：audioHandler 控制流（play/seek/skip/悬浮字幕翻转）订阅已上移到
  // [AudiobookSession]（进程级），reader 不再持有这些订阅。

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

  // The char-level dictionary reading-cursor state machine, owned by the shared
  // [DictionaryCaretController] (TODO-387) so video / home / standalone-window
  // surfaces can reuse it. This page is its [DictionaryCaretHost]: the controller
  // owns the surface / popup-state / busy fields and the popup-surface
  // transitions, while the reader keeps its reader/lyrics JS branches, keyboard
  // routing and the focus sandwich. The thin `_caret*` accessors below delegate
  // straight to the controller so every existing call site (and the source-scan
  // guards) keeps the same behaviour — only the ownership moved.
  late final DictionaryCaretController _caret = DictionaryCaretController(this);

  // Which surface holds the char-level reading cursor (a focused character inside
  // a WebView's DOM, driven from JS via [ReaderCaretScripts]). The cursor lives
  // on the reader content, or — after a lookup — on the top dictionary popup, and
  // follows the popup stack as the user goes deeper / backs out. While active,
  // A/Enter looks up the word at the cursor, B/Esc backs out a layer, and
  // directional keys / Tab step the cursor. Backed by [_caret].
  CaretSurface get _caretSurface => _caret.surface;
  set _caretSurface(CaretSurface value) => _caret.surface = value;

  bool get _caretActive => _caret.active;
  bool get _caretOnReader => _caret.onReader;
  bool get _caretOnLyrics => _caret.onLyrics;

  // The WebView char caret and focus-layer hops are part of the experimental
  // keyboard/gamepad focus navigation system. Page-turn and media shortcuts stay
  // active when the switch is off.
  bool get _focusNavEnabled => appModel.experimentalFocusNavigationEnabled;

  // Serializes the cursor's async JS operations. A gamepad D-pad auto-repeats
  // ~9×/s and a move that turns the page (move → _paginate → reanchor) round-
  // trips slower than that, so overlapping calls would evaluate against a mid-
  // pagination DOM and make the cursor jump. New directional input is dropped
  // while an op is in flight; the next auto-repeat tick moves instead.
  // Backed by [_caret].
  bool get _caretBusy => _caret.busy;
  set _caretBusy(bool value) => _caret.busy = value;

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
    _exitFlushCallback =
        ExitFlushRegistry.instance.register(_flushAllForProcessExit);
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

    // TODO-131: profile→settings 链与 book 定位→解析链互不依赖（前者动
    // ReaderHibikiSource.readerSettings / active profile，后者动 _book / _extractDir），
    // 并行起跑把 profile/settings 的 DB 往返与 EPUB 解析 isolate 重叠，缩短白屏。
    final Future<void> profileSettingsFuture = _resolveProfileAndSettings(db);
    final Future<_BookLocateResult> bookLocateFuture = _locateBookOnDisk(db);

    await profileSettingsFuture;
    if (!mounted) return;
    _settings = ReaderHibikiSource.readerSettings;

    final _BookLocateResult located = await bookLocateFuture;
    if (!mounted) return;
    if (!located.exists) {
      debugPrint('[ReaderHibiki] book ${widget.bookKey} not found on disk');
      HibikiToast.show(msg: t.book_file_not_found);
      Navigator.of(context).pop();
      return;
    }

    final EpubBookRow? bookRow = located.bookRow;
    final String extractDir = located.extractDir;
    _extractDir = extractDir;

    // TODO-131: charsFromDb 命中 = 跳过整本 html_parser 计数（导入时已落库）。
    // 缺失（旧书 / 异常）时为 null → 后台 compute 补算，首屏不阻塞。
    List<int>? charsFromDb;
    try {
      _book = await compute(parseBookOnly, extractDir);
      debugPrint(
          '[ReaderHibiki] parsed EPUB: ${_book!.chapters.length} chapters');
      if (bookRow != null) {
        charsFromDb = charCountsFromChaptersJson(
            bookRow.chaptersJson, _book!.chapters.length);
      }
    } on FormatException catch (e) {
      debugPrint('[ReaderHibiki] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookKey, extractDir);
      if (!mounted) return;
      _book ??= _buildLegacyBook(extractDir);
      if (bookRow != null) {
        charsFromDb = charCountsFromChaptersJson(
            bookRow.chaptersJson, _book!.chapters.length);
      }
      if (!mounted) return;
      HibikiToast.show(msg: t.epub_parse_fallback);
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderHibiki] chapter hrefs: $hrefs');

    if (charsFromDb != null) {
      _applyCharCounts(charsFromDb);
    } else {
      // DB 计数不可用：以零计数占位（所有消费点已 >0 / empty 守卫，进度回退 JS
      // total、统计暂累 0），同时后台 isolate 重算整本，落定后 _applyCharCounts
      // 补齐 totalChars 并重置统计基准，保证最终进度/统计字数等价、不丢字数。
      _applyCharCounts(
          List<int>.filled(_book!.chapters.length, 0, growable: false));
      _recomputeCharCountsInBackground();
    }

    // TODO-131: spread map 与 audio slot 互不依赖（前者写 _spreadMap/_edgeMatchResults，
    // 后者写 _audiobookController，都只读已就绪的 _book），并行等待两组 DB 往返。
    await Future.wait(<Future<void>>[
      _initSpreadMap(appModelNoUpdate.database),
      _resolveAudioSlot(),
    ]);
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

  /// TODO-131: profile 解析+应用 → 阅读器设置刷新。两步有依赖（profile 切换可能
  /// 改哪份 profile-scoped 设置生效），故内部串行；整条与书本定位/解析链并行。
  Future<void> _resolveProfileAndSettings(HibikiDatabase db) async {
    await _resolveAndApplyProfile(db);
    if (!mounted) return;
    if (ReaderHibikiSource.readerSettings == null) {
      final ReaderSettings rs = ReaderSettings(db);
      await rs.refreshFromDb();
      ReaderHibikiSource.readerSettings = rs;
    }
  }

  /// TODO-131: 按 bookKey 查 EpubBooks 行 + 校验磁盘目录存在。与 profile/settings
  /// 链并行起跑；`chaptersJson` 随行带回，供 [charCountsFromChaptersJson] 复用计数。
  Future<_BookLocateResult> _locateBookOnDisk(HibikiDatabase db) async {
    // Locate the book on disk by its stored extract_dir column (the on-disk
    // folder name may still be a legacy int id; the column is the truth).
    final EpubBookRow? bookRow = await db.getEpubBook(widget.bookKey);
    final String extractDir = bookRow?.extractDir ?? '';
    final bool exists = await EpubStorage.bookDirExists(extractDir);
    return _BookLocateResult(
      bookRow: bookRow,
      extractDir: extractDir,
      exists: exists,
    );
  }

  /// TODO-131: 落定每章字符数并重建累计前缀 + 刷新进度条总字数。开书时与延后重算
  /// 完成时共用。空/零计数也安全（消费点 >0 守卫），延后重算落定后再调一次补齐。
  void _applyCharCounts(List<int> counts) {
    _chapterCharCounts = counts;
    int cumulative = 0;
    _chapterCumulativeChars = <int>[];
    for (final int count in counts) {
      _chapterCumulativeChars.add(cumulative);
      cumulative += count;
    }
    if (mounted) {
      final int newTotal = _chapterCumulativeChars.isNotEmpty
          ? _chapterCumulativeChars.last + _chapterCharCounts.last
          : 0;
      if (newTotal > 0 && _progressTotalChars != newTotal) {
        setState(() {
          _progressTotalChars = newTotal;
        });
      }
    }
  }

  /// TODO-131: DB 计数缺失（旧书 / chaptersJson 无 characters 字段）时，把整本
  /// html_parser 逐章计数放后台 isolate 补算，**不阻塞首屏**。落定后用
  /// [_applyCharCounts] 补齐总字数，并把统计水位 `_sessionMaxAbsoluteChars` 重置到
  /// 当前位置——否则零计数期间它停在 0，计数落定后首个进度回调会把整段前缀误当本次
  /// 读到的新字数（幻象 spike）。重置后增量相对正确基准，统计字数等价。
  void _recomputeCharCountsInBackground() {
    final EpubBook? book = _book;
    if (book == null || book.chapters.isEmpty) return;
    unawaited(compute(countChapterChars, book).then((List<int> counts) {
      // 书可能在重算期间被换（重载 / 退出）；仅当仍是同一本、长度一致才采用。
      if (!mounted ||
          !identical(_book, book) ||
          counts.length != book.chapters.length) {
        return;
      }
      _applyCharCounts(counts);
      _sessionMaxAbsoluteChars = _absoluteCharPosition(_lastProgressValue);
    }).catchError((Object e, StackTrace s) {
      ErrorLogService.instance
          .log('ReaderHibiki._recomputeCharCountsInBackground', e, s);
    }));
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

  /// 解析并接管本书的有声书会话（TODO-291 阶段2）。
  ///
  /// 控制器现由进程级 [AudiobookSession] 持有。reader 不再自己 new / dispose 控制器，
  /// 而是：① 若已有同书的后台会话 → 直接复用（退书后台听书再进，无缝接回）；
  /// ② 否则让 session 起新会话；③ attach reader 的 WebView 侧回调。
  ///
  /// [forceReload] = true 时（导入新音频后重解析）先 stop 旧会话，逼 session 重新 load
  /// 新音频；首次开书 = false，优先复用既有后台会话。
  Future<void> _resolveAudioSlot({bool forceReload = false}) async {
    final AudiobookSession session = appModel.audiobookSession;
    final AudiobookPlayerController? old = _audiobookController;
    if (old != null) {
      // 旧引用是 session 控制器：先 detach（不 dispose）。reader 字段清掉等下面重接。
      session.detachReader(this);
      _audiobookController = null;
      _audiobookBookKey = null;
      _srtBookUid = null;
      _srtCueChapterMap = null;
      _srtChapterRanges = null;
    }
    if (forceReload && session.isActive) {
      // 导入了新音频：必须重 load，stop 旧会话让 session.start 走全新加载分支。
      await session.stop();
    }

    final HibikiDatabase db = appModel.database;
    final String bookKey = widget.bookKey;

    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(db);
    final AudiobookSessionStartRequest? req = await launcher.resolve(bookKey);
    if (req != null) {
      // 若进程级会话已持有本书控制器（退书后台听书后重进 / 同书重开），直接复用
      // （session.book.bookKey 对 EPUB 是 bookKey、对 SRT 是 uid，与 req.info.bookKey 同源）。
      if (session.isActive && session.book?.bookKey == req.info.bookKey) {
        await _attachExistingSession(session);
      } else {
        await _startAndAttachSession(session, req);
      }
    }

    await _primeAudioCuesForCurrentBook();

    if (_audiobookController == null && _lyricsMode) {
      _lyricsMode = false;
      await ReaderHibikiSource.instance.setLyricsMode(false);
    }
  }

  /// 复用 session 已持有的控制器：装 reader WebView 侧回调 + 监听 cue（经 session 转发）。
  Future<void> _attachExistingSession(AudiobookSession session) async {
    final AudiobookPlayerController? controller = session.controller;
    if (controller == null) return;
    final SessionBookInfo? info = session.book;
    // 恢复 SRT 路径标识（_srtBookUid / _audiobookBookKey），cue 同步分支据此走 SRT/EPUB。
    if (info != null) {
      if (info.audiobook.alignmentFormat == 'srt') {
        _srtBookUid = info.bookKey;
      } else {
        _audiobookBookKey = info.bookKey;
      }
    }
    _installReaderSessionSurfaces(session);
    session.attachReader(this);
    setState(() {
      _audiobookController = controller;
    });
    // 同步一次当前 cue 到 WebView（暂停态也即时高亮）。
    _onCueChanged();
  }

  /// 起新会话并 attach。失败弹提示。
  Future<void> _startAndAttachSession(
    AudiobookSession session,
    AudiobookSessionStartRequest req,
  ) async {
    AudiobookPlayerController? controller;
    try {
      controller = await session.start(
        info: req.info,
        audioFiles: req.audioFiles,
        prefs: req.prefs,
        persist: req.persist,
        // 灌扁平全书 cue 作初值（_primeAudioCuesForCurrentBook 随后按章节精确覆盖）；
        // 与后台听书路径共用 req.cues，使 attach 前的瞬态也有 cue（TODO-354）。
        cues: req.cues,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki.startSession', e, stack);
      debugPrint('[ReaderHibiki] audiobook session start failed: $e');
      if (mounted) HibikiToast.show(msg: t.audiobook_load_error);
      return;
    }
    if (controller == null) return;
    if (!mounted) {
      // 页面在 await 期间被弃：会话仍可在后台续播（用户决策①后台继续），不 stop。
      return;
    }
    if (req.info.audiobook.alignmentFormat == 'srt') {
      _srtBookUid = req.info.bookKey;
    } else {
      _audiobookBookKey = req.info.bookKey;
    }
    _installReaderSessionSurfaces(session);
    session.attachReader(this);
    setState(() {
      _audiobookController = controller;
    });
  }

  /// 把 reader 主题样式 + reader 弹窗查词装进 session（attach 期悬浮窗用 reader 主题）。
  void _installReaderSessionSurfaces(AudiobookSession session) {
    session.installReaderSurfaces(
      floatingLyricStyle: _readerFloatingLyricStyle,
      onFloatingLyricLookup: _lookupFromFloatingLyric,
    );
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
    final ExitFlushCallback? exitFlush = _exitFlushCallback;
    if (exitFlush != null) {
      ExitFlushRegistry.instance.unregister(exitFlush);
      _exitFlushCallback = null;
    }
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
    // 必须在 detachReader 之前：flush 读的是 _audiobookController（= session 控制器），
    // detach 不 dispose 控制器，但这里先把退出那一刻的位置写穿（BUG-203/032）。
    _syncAndFlushPosition();
    _flushReadingStats();
    // TODO-291 阶段2：退出书籍页不再 dispose 控制器、不再隐藏悬浮窗 / 清通知。
    // 控制器归 [AudiobookSession] 进程级持有，detach 仅卸下 reader 的 WebView 侧回调，
    // 让会话在后台继续播 + 悬浮窗继续刷字 + 通知继续更新（用户决策①后台继续）。
    // 控制流订阅、悬浮窗显隐、媒体通知现都由 session 管理，reader 不再触碰。
    appModel.audiobookSession.detachReader(this);
    _readingTimeTracker?.dispose();
    _focusNode.dispose();
    _chromeFocusScope.dispose();
    _popupHeaderScope.dispose();
    try {
      WakelockPlus.disable();
    } catch (e) {
      debugPrint('[Hibiki] wakelock disable failed: $e');
    }
    super.dispose();
  }

  /// BUG-203：返回书架前，先把 WebView 当前显示页落库，再交回基类走
  /// closeMedia / triggerAutoSyncAfterClose。
  ///
  /// 根因：dispose() 里的 [_syncAndFlushPosition] 是 fire-and-forget（dispose
  /// 同步签名无法 await），它内部 `await _syncPositionFromWebViewProgress()`
  /// （读实时 WebView 进度）与 `await _flushPosition()`（DB 写）抢不过紧随的
  /// super.dispose() 拆 WebView，恢复点退回 10s 轮询/debounce 的陈旧
  /// `_lastProgress*`，表现为退出重进落在前面好几页（分页/连续/竖排同此
  /// dispose flush，与模式无关）。
  ///
  /// 修：基类 [BaseSourcePageState.onWillPop] 在 closeMedia / triggerAutoSync
  /// 之前 `await onSourcePagePop()`，且此刻页面仍 mounted、WebView 仍存活，
  /// 对它 evaluateJavascript 安全（不同于进程退出期的 [_flushAllForProcessExit]
  /// 故意不碰 WebView）。这里 await 把实时当前页写穿，dispose 的 fire-and-forget
  /// 保留作兜底（硬 kill / 系统回收时 onWillPop 不一定跑到）。
  @override
  Future<void> onSourcePagePop() async {
    await _syncAndFlushPosition();
    await _flushReadingStats();
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

  void _resumePopupCaretForHardwareNav() =>
      _caret.resumePopupCaretForHardwareNav();

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
    // BUG-210 / TODO-146: 宽、高共用 1px 容差判定（见 readerViewportNeedsRepaginate）。
    // 旧代码宽度用零容差精确不等，Windows sub-pixel 宽抖动会误触发整章重载 + 粗粒度
    // progress 恢复，把用户从当前页弹到更靠前的页/章节开头（「翻页跳回章节开头」）。
    final ({bool width, bool height}) repaginate =
        readerViewportNeedsRepaginate(
      width: w,
      height: h,
      lastWidth: _lastSyncedWidth,
      lastHeight: _lastSyncedHeight,
    );
    final bool widthChanged = repaginate.width;
    final bool heightChanged = repaginate.height;
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
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
      if (!mounted || _controller == null) return;
      final ReaderStableProgressDetails? snapshot =
          parseReaderStableProgressDetails(result);
      final bool hasSameChapterCache = _lastProgressSection == _currentChapter;
      final double progress = snapshot?.progress ??
          (hasSameChapterCache ? _lastProgressValue : 0.0);
      final int? charOffset = snapshot?.charOffset ??
          (hasSameChapterCache ? _lastProgressCharOffset : null);
      await _navigateToChapter(
        _currentChapter,
        progress: progress,
        charOffset: charOffset,
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
    while (_sanitizedHtmlCache.length > _kChapterHtmlCacheLimit) {
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

  bool get _isCustomTheme => appModel.appThemeKey == 'custom-theme';

  String _buildStyleTag() {
    return _cachedStyleTag ??= _computeStyleTag();
  }

  String _computeStyleTag() {
    return '<style id="hoshi-reader-style">\n${ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      // TODO-165 / BUG-224：正文 <body> 背景/字色统一吃 `_readerThemeColors` 派生色。
      // preset 命中时 _themeColors 走 switch case 用手调底色（忽略 customBg → 零破坏）；
      // system-theme（默认主题）/light-theme/未命中 key 落 default 分支，原来恒白底
      // #fff，现在吃这套真实 ColorScheme.surface/onSurface；custom-theme→用户色。
      customBg: _readerBackgroundHex,
      customFg: _customThemeTextCss,
      // selection/sasayaki/link 是 preset 主题在 _themeColors switch 里手调的专色，
      // 仅 custom-theme 由 page 端覆盖（无条件传会用 _themeMap 的等价副本覆盖掉
      // preset switch 专色，引入双份硬编码耦合）；system-theme 用 _themeColors 默认兜底。
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
    // BUG-270: cached chapter HTML bakes in the styleTag, so any style change
    // must drop it — the next served chapter then rebuilds with the fresh tag.
    _sanitizedHtmlCache.clear();
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
      // TODO-165 / BUG-224：与 _computeStyleTag 对称——正文背景/字色统一吃当前主题
      // 派生色，system-theme（默认主题）不再恒白底。
      customBg: _readerBackgroundHex,
      customFg: _customThemeTextCss,
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
  // BUG-239: 连续模式不让 _gestureEnd 回传 onSwipe（交给原生滚动 + 边界 IIFE），
  // 消除横向滑动 90% 跳页与原生滚动的轴向冲突；分页模式照旧水平滑动翻页。
  var hoshiContinuousMode = $continuousMode;
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
    // BUG-239 / TODO-345 同源门控：连续模式靠浏览器原生滚动（滚动轴 = 书写轴）。
    // 此处一旦在连续模式回传 onSwipe（90% 整屏跳页），就与原生滚动产生轴向冲突。
    var r = window.hoshiReader;
    if (hoshiContinuousMode) {
      // TODO-345: 横排连续滚动轴 = 纵向（与桌面鼠标滚轮的 deltaY 默认轴一致），
      // 放行原生滚动即可顺滑滚动。竖排连续滚动轴 = 横向（CSS overflow-x 可滚、
      // overflow-y:hidden），但桌面鼠标滚轮只产生 deltaY、不产生 deltaX，浏览器
      // 不会把垂直滚轮可靠地映射到横向可滚轴 → 竖排连续模式滚轮滚不动。故竖排
      // 显式把滚轮的主 delta 投影到横向 scrollBy（沿真实书写轴），方向与
      // hoshiReader.paginate 一致（vertical-rl forward 往左 = scrollLeft 减小），
      // 并 preventDefault 防止浏览器把它误吞到不可滚的纵轴；横排放行原生滚动不变。
      if (!r || !r.isVertical || !r.isVertical()) return;
      var delta = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
      if (delta === 0) return;
      var wm = window.getComputedStyle(document.body).writingMode;
      var sign = (wm === 'vertical-rl') ? -1 : 1;
      window.scrollBy({left: delta * sign, top: 0, behavior: 'auto'});
      e.preventDefault();
      return;
    }
    if (_wheelTimer) return;
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
  // BUG-213: 章内原生滚动（连续模式 window 滚动 / 分页模式触摸/trackpad/键盘箭头
  // 落 body 的原生滚动）没有进度回传通道，进度条要等 10s 轮询或翻章才更新。这里给
  // 两模式共享的 setup 脚本挂一条统一 scroll → Dart 通道：capture 阶段监听让 window
  // 与 body 内部滚动都进来，rAF 合一帧 + 200ms debounce 抑制高频抖动后回传一次；
  // 程序化重锚期（_reanchorPending）跳过，避免恢复/重排瞬态误触发（恢复期的
  // _restoreInFlight / 歌词模式由 Dart 侧 onReaderScroll 再门控一道）。
  (function() {
    var _progressScrollRaf = 0;
    var _progressScrollTimer = null;
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
      if (_progressScrollRaf) cancelAnimationFrame(_progressScrollRaf);
      _progressScrollRaf = requestAnimationFrame(function() {
        _progressScrollRaf = 0;
        if (_progressScrollTimer) clearTimeout(_progressScrollTimer);
        _progressScrollTimer = setTimeout(function() {
          _progressScrollTimer = null;
          _reportReaderScroll();
        }, 200);
      });
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

  void _invalidateFavoriteSentenceCache() {
    _favoriteSentencesForBookCache = null;
    _favoriteSentencesForBookFuture = null;
  }

  Future<List<FavoriteSentence>> _loadFavoriteSentencesForBook() async {
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);
    try {
      final List<FavoriteSentence> favorites = (await repo.getAll())
          .where((FavoriteSentence s) => s.bookKey == widget.bookKey)
          .toList(growable: false);
      _favoriteSentencesForBookCache = favorites;
      return favorites;
    } finally {
      _favoriteSentencesForBookFuture = null;
    }
  }

  Future<List<FavoriteSentence>> _favoriteSentencesForBook() {
    final List<FavoriteSentence>? cached = _favoriteSentencesForBookCache;
    if (cached != null) {
      return Future<List<FavoriteSentence>>.value(cached);
    }
    return _favoriteSentencesForBookFuture ??= _loadFavoriteSentencesForBook();
  }

  Future<List<FavoriteSentence>> _favoriteSentencesForSection(
      int section) async {
    final List<FavoriteSentence> favorites = await _favoriteSentencesForBook();
    return favorites
        .where((FavoriteSentence s) =>
            s.bookKey == widget.bookKey && s.sectionIndex == section)
        .toList(growable: false);
  }

  Future<void> _applyChapterHighlights() async {
    if (_controller == null) return;
    final List<FavoriteSentence> chapterFavs =
        await _favoriteSentencesForSection(_currentChapter);
    if (!mounted || _controller == null) return;
    final int withOffsets =
        chapterFavs.where((s) => s.normCharOffset != null).length;
    final int total =
        _favoriteSentencesForBookCache?.length ?? chapterFavs.length;
    debugPrint('[hoshi-hl] chapter=$_currentChapter '
        'total=$total chapterFavs=${chapterFavs.length} '
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
    final List<FavoriteSentence> all = await _favoriteSentencesForBook();
    if (_controller == null || !mounted) return;
    final List<String> texts =
        all.map((s) => s.text).where((t) => t.isNotEmpty).toList();
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
    _sessionMaxAbsoluteChars = _absoluteCharPosition(_initialProgress);

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

  /// BUG-213：setup 脚本的 scroll reporter 在章内原生滚动稳定后（rAF + 200ms
  /// debounce）回传到此。门控通过则复用既有 `_refreshProgress()` 重算章内进度
  /// （high-water-mark 计字不重复累计、`_debouncedSavePosition` 自带 500ms 去抖，
  /// 不改字数累加路径）。恢复期/歌词/未就绪由纯函数统一抑制。
  void _handleReaderScroll() {
    final bool allowed = readerScrollProgressRefreshAllowed(
      readerContentReady: _readerContentReady,
      restoreInFlight: _restoreInFlight,
      lyricsMode: _lyricsMode,
      controllerAvailable: _controller != null,
    );
    // TODO-151/164 / BUG-225 诊断（默认 off，DebugLogService.instance.enabled 门控）：
    // 记四个门控条件各自真值 + 是否实际调 _refreshProgress，便于真机定位「滚动回传到了
    // 但进度不刷新」是被哪个门控挡掉的（恢复期/歌词/未就绪/控制器释放）。不改 151 逻辑。
    if (DebugLogService.instance.enabled) {
      debugPrint('[ReaderDiag] _handleReaderScroll'
          ' readerContentReady=$_readerContentReady'
          ' restoreInFlight=$_restoreInFlight'
          ' lyricsMode=$_lyricsMode'
          ' controllerAvailable=${_controller != null}'
          ' allowed=$allowed → refresh=${allowed ? 'yes' : 'no'}');
    }
    if (!allowed) {
      return;
    }
    _refreshProgress();
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
    final Color fg = _lyricsTextColor();
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

  /// TODO-368: 歌词字幕文字色——用户设过自定义色（[ReaderHibikiSource.lyricsTextColor]
  /// 非哨兵 0）则用它，否则回退主题文字色 [_themeTextColor]（向后兼容默认跟随主题）。
  Color _lyricsTextColor() {
    final int custom = ReaderHibikiSource.instance.lyricsTextColor;
    if (custom != 0) return Color(custom);
    return _themeTextColor();
  }

  Future<void> _updateLyricsStyleLive() async {
    if (!mounted || _controller == null || !_lyricsPageReady) return;
    final Color bg = _themeBackgroundColor();
    final Color fg = _lyricsTextColor();
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

  /// TODO-291 阶段2：实现 [ReaderAudiobookView.onReaderCueChanged]。由 session 的
  /// 控制器监听器转发（reader attach 期才被调用）。只管 WebView 侧（正文高亮 / lyrics /
  /// 进度同步）——悬浮窗 / 媒体通知同步已上移到 session 常驻执行，这里不再做，避免双写。
  @override
  void onReaderCueChanged() => _onCueChanged();

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
      if (frag == null && _srtCueChapterMap != null) {
        final int? cueChapter = _srtCueChapterMap![cue.sentenceIndex];
        if (cueChapter != null && cueChapter != _currentChapter) {
          if (controller.shouldRevealCurrentCue && !_restoreInFlight) {
            _navigateToChapter(cueChapter);
          } else {
            AudiobookBridge.highlight(_controller!);
          }
          return;
        }
      }
    }
    final bool forceReveal = controller.consumeForceReveal();
    final bool reveal = forceReveal || controller.shouldRevealCurrentCue;
    AudiobookBridge.highlight(_controller!, cue: cue, reveal: reveal);
    _syncPositionFromCurrentCue();
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

  // ── ReaderAudiobookView（TODO-291 阶段2：reader 向 session 暴露 WebView 侧回调） ──

  @override
  int getCurrentReaderSection() => _currentChapter;

  @override
  Future<void> onCueCrossChapter(int sectionIndex) =>
      _handleCueCrossChapter(sectionIndex);

  @override
  Future<void> onBoundarySkip(int delta) => _handleBoundarySkip(delta);

  AudioCue? _lookupCue;
  ({int offset, int length, String text})? _cachedSelectionRange;
  ({int offset, int length})? _cachedSentenceRange;
  int? _cachedSentenceOffset;
  bool _currentSentenceIsFavorited = false;

  /// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：会话级制卡草稿缓冲。弹窗点「+句」
  /// 把当前句（+句子音频区间）推进这里，连续查多句累积；制卡时合成一段写入卡片
  /// sentence 字段（[joinMinedSentences]），音频区间合并（[mergeMiningAudioRanges]，
  /// 跨章/跨音频文件退化为只合文本）。制卡成功或关闭弹窗栈后清空。书籍 + 有声书共用
  /// 同一 reader 页 / currentSentence 链路，区别只在裁句子音频。
  final MiningSentenceDraft _miningDraft = MiningSentenceDraft();

  /// reader（书籍/有声书）支持「+句」累积草稿。
  @override
  bool get supportsSentenceDraft => true;

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

  List<AudioCue> _sentenceAudioMiningCues(AudioCue? cue) {
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

    // Gap word with no cue and no section/chapter cues: nothing to clip.
    return cue != null ? <AudioCue>[cue] : const <AudioCue>[];
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

  /// TODO-104a / BUG-172：当前正查这一句对应的句子音频区间（已含 A/V 同步偏移）。
  /// 抽出来给「制卡」与「上 N 句 / 下 N 句」上下文共用，确保两条路径裁的是同一句同一
  /// 区间。返回 null 表示无音频文件，或无法从当前 cue / 句子 span 解析出区间。
  AudioPlaybackRange? _currentSentenceAudioRange() {
    final String sentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    return _sentenceAudioRangeFor(
      sentence: sentence,
      cue: _lookupCue,
      normOffset: _cachedSentenceRange?.offset,
      normLength: _cachedSentenceRange?.length,
    );
  }

  /// TODO-393：把任意一句（当前句或上下文句）按其整书归一化偏移解析成句子音频区间
  /// （已含 A/V 同步偏移）。上下文句没有 cue，[cue] 传 null，纯靠 [normOffset]/
  /// [normLength] 在本 section 的 cue 列表里定位（[miningSentenceAudioRange] 支持）。
  /// 无音频文件或解析不出区间时返回 null（调用方退化为只合文本）。
  AudioPlaybackRange? _sentenceAudioRangeFor({
    required String sentence,
    AudioCue? cue,
    int? normOffset,
    int? normLength,
  }) {
    final AudiobookPlayerController? audioController = _audiobookController;
    final List<File>? audioFiles = audioController?.audioFiles;
    if (audioFiles == null) return null;
    final AudioPlaybackRange? clip = miningSentenceAudioRange(
      cues: _sentenceAudioMiningCues(cue),
      cue: cue,
      sentence: sentence,
      sectionIndex: _lookupSectionIndex,
      sentenceNormCharOffset: normOffset,
      sentenceNormCharLength: normLength,
      delayMs: audioController?.delayMs.value ?? 0,
    );
    if (clip == null ||
        clip.audioFileIndex < 0 ||
        clip.audioFileIndex >= audioFiles.length) {
      return null;
    }
    return clip;
  }

  /// TODO-393「上 N 句 / 下 N 句」上下文选择：把当前句之前 [prevCount] 句、之后
  /// [nextCount] 句作上下文**整体设置**进会话级制卡草稿（覆盖上一次选择，不累积），
  /// 返回上下文句总数（上 N + 下 N）。上下文句从阅读器 DOM 取（
  /// [ReaderSelectionScripts.getSurroundingSentences]，沿用查词同一句子边界规则，止于
  /// 段落边界），有声书顺带按各句归一化偏移裁出音频区间一并入队（制卡时合并成首句起→
  /// 末句止；跨章/跨音频文件退化为只合文本）。无 WebView 或无选区时清空上下文返回 0。
  @override
  Future<int> onSetSentenceContextToDraft(int prevCount, int nextCount) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null || (prevCount <= 0 && nextCount <= 0)) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    Object? raw;
    try {
      raw = await controller.evaluateJavascript(
        source: ReaderSelectionScripts.surroundingSentencesInvocation(
          prevCount,
          nextCount,
        ),
      );
    } catch (_) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final parsed = ReaderSelectionScripts.surroundingSentencesFromResult(raw);
    MiningDraftSentence toEntry(SurroundingSentence s) => MiningDraftSentence(
          sentence: s.sentence,
          audioRange: _sentenceAudioRangeFor(
            sentence: s.sentence,
            normOffset: s.normOffset,
            normLength: s.normLength,
          ),
        );
    _miningDraft.setContext(
      prev: <MiningDraftSentence>[for (final s in parsed.prev) toEntry(s)],
      next: <MiningDraftSentence>[for (final s in parsed.next) toEntry(s)],
    );
    return _miningDraft.length;
  }

  /// TODO-382 / TODO-393：弹窗点「清空已加句子」清掉本次查词的上下文选择（回到只制
  /// 当前句），回传清空后的句数（恒 0）。给用户一个明确、可见的撤销入口。
  @override
  Future<int> onClearSentenceDraftToDraft() async {
    _miningDraft.clear();
    return _miningDraft.length;
  }

  /// TODO-270 D：reader 制卡/覆盖共用的「构造制卡上下文」。返回构造好的
  /// [AnkiMiningContext] 与一个 `cleanup` 闭包（清理句子音频临时目录，调用方在 mine/
  /// update 完成后必须调用）。当句子音频导出失败（已弹 toast）时返回 `context: null`，
  /// 调用方据此直接放弃本次制卡/覆盖。把这段重逻辑抽出来，使制卡与覆盖走完全一致的
  /// 封面/句子音频/句子偏移/分类标签链路（避免两份漂移）。
  Future<({AnkiMiningContext? context, void Function() cleanup})>
      _prepareMiningContext() async {
    final String currentSentence =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    // TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：把已累积的草稿句 + 当前句合成一段
    // 写入卡片 sentence 字段；草稿为空时等价于原来的单句（joinMinedSentences 单句
    // 直接 trim 返回）。音频区间同理合并（跨章/跨音频文件退化为只合文本）。
    final String sentence = _miningDraft.composeText(currentSentence);

    String? coverPath;
    if (_book?.coverHref != null && _extractDir != null) {
      final File coverFile = File(p.join(_extractDir!, _book!.coverHref));
      if (coverFile.existsSync()) coverPath = coverFile.path;
    }

    String? sasayakiAudioPath;
    Directory? sasayakiTempDir;
    bool requestedSentenceAudioClip = false;
    void cleanupSasayakiTempDir() {
      if (sasayakiTempDir != null && sasayakiTempDir.existsSync()) {
        try {
          sasayakiTempDir.deleteSync(recursive: true);
        } catch (e, stack) {
          ErrorLogService.instance
              .log('ReaderHibiki.mineEntry.cleanupAudio', e, stack);
        }
      }
    }

    final AudioCue? cue = _lookupCue;
    final List<File>? audioFiles = _audiobookController?.audioFiles;
    // BUG-172 / TODO-104a: do not gate on `cue != null`. Audiobook cue alignment
    // leaves gaps (titles, captions, alignment misses, chapter edges); a word can
    // land in covered-but-uncued text so `_lookupCue` is null, yet the sentence
    // is still spanned by surrounding cues. As long as audio files exist, resolve
    // the range by the sentence span (cue-by-range) instead of silently dropping
    // sentence audio. `miningSentenceAudioRange` returns null when nothing can be
    // derived (no cue and no usable sentence span), so the gate stays honest.
    //
    // TODO-270 F/G：把当前句区间与草稿累积的句子区间合并成「首句起→末句止」。
    // 跨章/跨音频文件时 MiningSentenceDraft.composeAudioRange 返回 null →退化为只
    // 合文本（不静默拼坏音频），并诚实记日志。
    if (audioFiles != null) {
      final AudioPlaybackRange? currentRange = _currentSentenceAudioRange();
      final AudioPlaybackRange? clip =
          _miningDraft.composeAudioRange(currentRange);
      if (clip != null &&
          clip.audioFileIndex >= 0 &&
          clip.audioFileIndex < audioFiles.length) {
        final File inputFile = audioFiles[clip.audioFileIndex];
        sasayakiTempDir =
            Directory.systemTemp.createTempSync('hibiki_mine_sentence_audio_');
        final String outputPath = p.join(sasayakiTempDir.path, 'sentence.aac');
        requestedSentenceAudioClip = true;
        sasayakiAudioPath = await TtsChannel.instance.extractAudioSegment(
          inputPath: inputFile.path,
          startMs: clip.startMs,
          endMs: clip.endMs,
          outputPath: outputPath,
        );
      } else if (cue == null) {
        // Visibility: audio exists but neither a lookup cue / sentence span nor a
        // mergeable draft range resolved to a cue range (or the draft spans
        // multiple audio files → text-only). Log so a future "no sentence audio"
        // report is traceable instead of being a silent drop.
        debugPrint(
          '[ReaderHibiki] mine: audio present but no sentence-audio range '
          '(lookupCue=null, sentenceRange=${_cachedSentenceRange != null}, '
          'draftSentences=${_miningDraft.length}).',
        );
      }
    }

    if (requestedSentenceAudioClip && sasayakiAudioPath == null) {
      cleanupSasayakiTempDir();
      ErrorLogService.instance.log(
        'ReaderHibiki.mineEntry.sentenceAudio',
        'sentence audio export failed',
        StackTrace.current,
      );
      HibikiToast.show(
        msg: t.card_export_failed_detail(
          reason: 'sentence audio export failed',
        ),
      );
      return (context: null, cleanup: cleanupSasayakiTempDir);
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
      // TODO-115: 书籍来源 → 卡片追加 `book` 分类标签（reader 不走 DictionaryPageMixin）。
      source: AnkiMiningSource.book,
    );

    return (context: miningContext, cleanup: cleanupSasayakiTempDir);
  }

  @override
  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final prepared = await _prepareMiningContext();
    final AnkiMiningContext? miningContext = prepared.context;
    if (miningContext == null) {
      prepared.cleanup();
      return const MinePopupResult();
    }

    final MineOutcome outcome;
    try {
      outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
    } finally {
      prepared.cleanup();
    }

    // 牌组名仅 success 需要（避免给失败分支白白 loadSettings）。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(outcome, deckName: deckName);
    // 制卡成功计入书籍统计（reader 走 BaseSourcePageState.onMineFromPopup，不
    // mixin DictionaryPageMixin，故直接 addMiningCount，来源固定 book）。失败吞掉记日志。
    if (described.record) unawaited(_recordMined());
    HibikiToast.show(msg: described.message);
    if (described.success) {
      // TODO-270 F/G：合并卡已落地 → 清空多句草稿（popup.js 同事件把角标清零，
      // 两端在同一事件归零、不漂移）。下一次查词从空草稿重新累积。
      _miningDraft.clear();
      // TODO-270 D：AnkiConnect 成功制卡带回 note id（noteId 非空），让弹窗把这张
      // 标记为「最新可改」第三态；AnkiDroid 的 noteId 恒为 null（优雅降级，进不了
      // 第三态）。ankiConnect 沿用旧的「成功即可同步刷新 ✓」语义。
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
  }

  @override
  Future<MinePopupResult> onUpdateFromPopup(
    int noteId,
    Map<String, String> fields,
  ) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final prepared = await _prepareMiningContext();
    final AnkiMiningContext? miningContext = prepared.context;
    if (miningContext == null) {
      prepared.cleanup();
      return const MinePopupResult();
    }

    final MineOutcome outcome;
    try {
      outcome = await repo.updateMinedNote(
        noteId: noteId,
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
    } finally {
      prepared.cleanup();
    }

    // 覆盖路径走收口的单一真相（overwrite=true → card_overwritten + 不记账）。覆盖已有
    // 卡片不计入统计（不是新制一张），成功仍保留「最新可改」第三态、带回同一 noteId。
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described =
        describeMineOutcome(outcome, deckName: deckName, overwrite: true);
    HibikiToast.show(msg: described.message);
    if (described.success) {
      return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
    }
    return const MinePopupResult();
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

    // BUG-405：直接复用 AudiobookBridge.buildSasayakiPayload，与有声书桥接路径
    // 共用同一份 payload 契约（必含 cue 原文 text）。此前 reader 这里手写的内联
    // 循环漏了 text 字段：JS collectSasayakiCueRanges 拿到空 needle → 跳过实时
    // DOM 就近重定位 → 只按「匹配坐标系」的 start 提示回落，而该提示在「渲染
    // 坐标系」实时 DOM 里错位 → 高亮落空，正文看不到任何有声书跟随高亮。复用
    // 纯函数后两条路径不会再各自漂移（BUG-060 的实时 DOM 重定位对 reader 生效）。
    final List<Map<String, dynamic>> payload =
        AudiobookBridge.buildSasayakiPayload(allCues, _currentChapter);
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

  /// 一次导航的共用主体：递增代际 token + 完成/新建 restore completer + 置初始锚点
  /// 字段 + 设 fragment + 标 restoreInFlight + setState 清 ready + 启动超时。
  /// _navigateToChapter / _navigateToSpread / _navigateToChapterWithFragment 此前各复制
  /// 这 14 行（任一改动要三处同步，否则导航/恢复代际状态机漂移）。各方法自己的前导
  /// （进度轮询取消 / manual 标记 / cancelChapterTransition / flush 统计）保留在各自方法。
  ///
  /// 注意：[_navigateToChapter] 额外把 charOffset 镜像进 `_lastProgressCharOffset`，
  /// 另两者不设 → 该字段不在此 helper 内（保各自原行为）。
  void _beginNavigation({
    required int chapter,
    required double progress,
    required int charOffset,
    String? fragment,
  }) {
    _restoreExpectedGeneration = ++_navigateGeneration;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = Completer<bool>();
    _currentChapter = chapter;
    _initialProgress = progress;
    _initialCharOffset = charOffset;
    _lastProgressSection = chapter;
    _lastProgressValue = progress;
    // HBK-AUDIT-037: 清/设 fragment——上次内链导航的残留 fragment 不得漏进本次 setup
    // 脚本（旧的 post-await 复位在 lyrics/spread/early-return/throw 路径会被跳过）。
    _initialFragment = fragment;
    _restoreInFlight = true;
    setState(() {
      _readerContentReady = false;
    });
    _startContentReadyTimeout();
  }

  /// 导航装载失败的共用收尾：清 restoreInFlight、完成并清空 restore completer。
  void _failNavigation() {
    _restoreInFlight = false;
    if (_restoreCompleter != null && !_restoreCompleter!.isCompleted) {
      _restoreCompleter!.complete(false);
    }
    _restoreCompleter = null;
  }

  Future<void> _navigateToChapter(
    int index, {
    double progress = 0.0,
    int? charOffset,
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

    // BUG-162: 普通翻章去新位置，无该章精确锚 → -1 走分数；同章程序化重分页可显式
    // 传 charOffset 保不动点。
    _beginNavigation(
      chapter: index,
      progress: progress,
      charOffset: charOffset ?? -1,
    );
    _lastProgressCharOffset = _initialCharOffset;

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._navigateToChapter', e, stack);
      debugPrint('[ReaderHibiki] _navigateToChapter loadUrl failed: $e');
      _failNavigation();
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

    // BUG-162: 新章/fragment 跳转走分数/fragment，非 char 锚 → -1。
    _beginNavigation(
      chapter: index,
      progress: 0.0,
      charOffset: -1,
      fragment: fragment,
    );

    try {
      await _loadChapterDirectly(index);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki._navigateToChapterWithFragment', e, stack);
      debugPrint(
          '[ReaderHibiki] _navigateToChapterWithFragment loadUrl failed: $e');
      _failNavigation();
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

    // BUG-162: spread 导航去章首，无 char 锚 → -1；不要 fragment 跳转（fragment=null）。
    _beginNavigation(
      chapter: entry.chapterIndex,
      progress: 0.0,
      charOffset: -1,
    );

    try {
      await _loadSpreadPage(entry);
    } catch (e, stack) {
      ErrorLogService.instance.log('ReaderHibiki._navigateToSpread', e, stack);
      debugPrint('[ReaderHibiki] _navigateToSpread failed: $e');
      _failNavigation();
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
    // TODO-270 F/G：整条查词浮层栈关闭 = 一次「查词会话」结束，丢弃未制卡的多句
    // 草稿（避免下次查词带着上次没用掉的累积句）。制卡成功已在 onMineFromPopup
    // 清过，这里兜住「攒了几句但没制卡就关掉」的情况。
    _miningDraft.clear();
    _clearLookupState();
    // Return Flutter focus to the reading content. The dismissed popup's WebView
    // held the keyboard/gamepad focus, so without this the reader receives no key
    // events after the popup closes and the user is stuck with no way back in.
    _focusNode.requestFocus();
    // If the cursor was living in a popup (controller/keyboard flow), the popup
    // it was in is gone — bring it back to the reader at its remembered word.
    // This covers every dismiss path (B/Esc, tap-outside, swipe).
    if (_caretSurface == CaretSurface.popup) {
      _caret.popupState = null;
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

  /// 查词收尾序列：清栈热槽 → deferDisplay 查词 → 高亮并展示弹窗。reader 选词的
  /// 歌词模式与普通模式两分支共用（前后各自的 cue 解析 / cached-range 设置保留在
  /// 各分支，因时机不同：歌词从 fragment 提前设，普通从 data 在其后设）。
  Future<void> _runLookupAndHighlight(
    String searchTerm,
    Rect selectionRect,
  ) async {
    prunePopupStack(0);
    final int highlightCount = await searchDictionaryResult(
      searchTerm: searchTerm,
      selectionRect: selectionRect,
      deferDisplay: true,
    );
    await _highlightAndShowPopup(highlightCount, selectionRect);
  }

  Future<void> _handleTextSelected(ReaderSelectionData data) async {
    if (data.text.isEmpty) {
      return;
    }
    // TODO-393 / BUG-缓存串味：每次新查词（换词 / 换句）都从「只制当前句」起步，丢弃
    // 上一个词的「上 N 句 / 下 N 句」上下文选择。热槽 WebView 复用使弹窗 DOM 不重载，
    // 草稿若不在此清空，上一个词攒的上下文会带到下一个词的卡（用户报「弹窗会缓存」）。
    _miningDraft.clear();

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
      await _runLookupAndHighlight(data.text, selectionRect);
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

    await _runLookupAndHighlight(data.text, selectionRect);
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
      source: ReaderPaginationScripts.stableProgressInvocation(),
    );
    if (result == null || !mounted) return;
    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    if (snapshot == null) {
      return;
    }

    final int total = snapshot.total;
    final int charOffset = snapshot.charOffset;
    final double progress = snapshot.progress;
    _lastProgressSection = _currentChapter;
    _lastProgressValue = progress;
    _lastProgressCharOffset = charOffset;
    final int absoluteChars = _absoluteCharPosition(progress);
    // TODO-147 / BUG-211：按 high-water mark 增量计数，避免往返翻页重复累计。
    final ReadProgressResult delta = accumulateSessionChars(
      absoluteChars: absoluteChars,
      highWaterMark: _sessionMaxAbsoluteChars,
    );
    _sessionCharsRead += delta.charsAdded;
    _sessionMaxAbsoluteChars = delta.highWaterMark;
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
      // TODO-151/164 / BUG-225 诊断（默认 off，DebugLogService.instance.enabled 门控）：
      // 记重算后章内进度 UI 字段最终值，便于真机确认滚动后进度数确实推进/未推进。
      if (DebugLogService.instance.enabled) {
        debugPrint('[ReaderDiag] _refreshProgress'
            ' progressCurrentChars=$_progressCurrentChars'
            ' progressTotalChars=$_progressTotalChars'
            ' (progress=${progress.toStringAsFixed(4)} section=$_currentChapter)');
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

    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    if (snapshot == null) {
      return;
    }

    _lastProgressSection = _currentChapter;
    _lastProgressValue = snapshot.progress;
    _lastProgressCharOffset = snapshot.charOffset;
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
      // BUG-162: >=0 写精确锚（char_offset 列）。<0（WebView 当帧算不出精确偏移）
      // 传 null → ReaderPositionRepository.save 在同 section 保留既有精确锚、仅跨
      // section 失效。BUG-285 回归：TODO-265 误改成直接传 -1，使 _refreshProgress /
      // _syncPositionFromWebViewProgress 在重排或竖排边缘拿到 -1 时把同 section 的
      // 精确锚覆盖成 -1 → 恢复/有声书跨章重锚退化成「章首分数」（章节粒度），不再
      // 逐句跟随。还原 null 守卫，把同/跨 section 的取舍交回 repo.save。
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

  /// 进程退出统一 flush（TODO-086/BUG-191）。**不**调用
  /// [_syncPositionFromWebViewProgress]——退出期 WebView2 正在拆除，对它
  /// `evaluateJavascript` 会挂死整个退出。改用 debounce 已算好缓存的
  /// `_lastProgress*` 字段直接落库（[_flushPosition]），并把阅读统计 + 有声书
  /// 播放位置写穿。await 完成后退出路径才会 exit(0)。
  Future<void> _flushAllForProcessExit() async {
    if (_lyricsMode) {
      // 歌词模式可见进度只有音频 cue 位置，先从当前 cue 派生位置再落库
      // （纯内存计算，不碰 WebView）。
      _syncPositionFromCurrentCue();
    }
    await _flushPosition();
    await _flushReadingStats();
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

  /// 把本 session 累积的字数 + 阅读时长落库。返回的 Future 在 DB 写完成后才完成，
  /// 供进程退出路径 await（TODO-086/BUG-191）；其余生命周期调用点 fire-and-forget
  /// （不 await 返回的 Future，行为同旧版）。计数器在发起写之前清零，保证同一段
  /// 时长/字数不会被重复累加。
  Future<void> _flushReadingStats() async {
    if (_sessionCharsRead <= 0 || _book == null) return;
    final DateTime now = DateTime.now();
    final int elapsedMs = now.difference(_sessionStartTime).inMilliseconds;
    final String dateKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final int charsRead = _sessionCharsRead;
    final String title = _book!.title;
    _sessionCharsRead = 0;
    _sessionStartTime = DateTime.now();
    try {
      await appModel.database.addReadingStatistic(
        title: title,
        dateKey: dateKey,
        charsRead: charsRead,
        timeMs: elapsedMs,
      );
    } catch (e) {
      debugPrint('[ReaderHibiki] stats flush error: $e');
    }
  }

  // ── Key Navigation ────────────────────────────────────────────────

  /// 当前按下的修饰键集合（Ctrl/Shift/Alt/Meta）。键盘快捷解析与底栏焦点的
  /// Space 覆写共用，避免两处各自重建一份。
  Set<ModifierKey> _activeModifiers() {
    final Set<ModifierKey> modifiers = <ModifierKey>{};
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
    return modifiers;
  }

  /// 有声书是否已激活（有控制器且本章有 cue）。Space 播放/暂停覆写的统一闸门，
  /// 正文焦点路径与底栏焦点路径（BUG-204）共用同一判据。
  bool get _hasActiveAudiobook =>
      _audiobookController != null && _audiobookController!.chapterCueCount > 0;

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
      // BUG-204: 焦点落底栏控件时，裸 Space 仍应播放/暂停有声书。否则它在这里
      // 被吞成 ignored，到不了下方 [resolveReaderSpaceOverride]，冒泡到全局
      // 导航把裸 Space 中和为 DoNothingIntent（c152fcd91 用户裁定的正确全局
      // 行为，**不回退**），有声书永不暂停。仅在有声书激活 + 无修饰 Space 时
      // 拦截（与正文焦点路径同一 [resolveReaderSpaceOverride] 闸门），其余键
      // 一律落 ignored，底栏控件本身的 Space 语义不受影响。
      final ShortcutAction? chromeSpaceOverride = resolveReaderSpaceOverride(
        key: event.logicalKey,
        modifiers: _activeModifiers(),
        hasActiveAudiobook: _hasActiveAudiobook,
      );
      if (chromeSpaceOverride != null) {
        return _executeShortcutAction(
          chromeSpaceOverride,
          keyboardTriggerKey: event.logicalKey,
        );
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

    final Set<ModifierKey> modifiers = _activeModifiers();

    final ShortcutAction? directReaderAction =
        appModel.shortcutRegistry.resolveKeyboard(
      event.logicalKey,
      modifiers: modifiers,
      scope: ShortcutScope.reader,
    );

    // Char-level reading cursor (book has focus; chrome already returned above).
    // While active, the cursor owns Tab / arrows / A(Enter) / B(Esc) before the
    // registry is consulted. While inactive, A / Enter ENTER the cursor.
    if (_focusNavEnabled && _caretActive) {
      if (_isReaderDirectCaretShortcut(directReaderAction)) {
        return _executeShortcutAction(
          directReaderAction!,
          keyboardTriggerKey: event.logicalKey,
        );
      }
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
      // LT/RT (Android delivers gamepad triggers as gameButton key events) jump
      // to the previous/next dictionary section on the popup. Routed through the
      // gamepad map (the keyboard `[`/`]` path is handled below by
      // decideKeyboard); these trigger logical keys are gamepad-only, so a
      // desktop keyboard never reaches here.
      if (shoulder == GamepadButton.lt || shoulder == GamepadButton.rt) {
        final CaretAction? triggerAction =
            ReaderCaretRouter.decideGamepad(shoulder!);
        if (triggerAction != null) {
          unawaited(_runCaretAction(triggerAction));
          return KeyEventResult.handled;
        }
      }
      final CaretAction? caretAction = ReaderCaretRouter.decideKeyboard(
        event.logicalKey,
        shift: HardwareKeyboard.instance.isShiftPressed,
      );
      if (caretAction != null) {
        unawaited(_runCaretAction(caretAction));
        return KeyEventResult.handled;
      }
    } else if (_isReaderDirectCaretShortcut(directReaderAction)) {
      return _executeShortcutAction(
        directReaderAction!,
        keyboardTriggerKey: event.logicalKey,
      );
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

    // 有声书激活时，无修饰 Space 改作播放/暂停（媒体播放器惯例），先于
    // reader scope 的「翻页」解析，否则 Space 永远被 reader scope 抢成翻页
    // （翻页仍可用方向键/PageDown；Shift+Space 后退翻页、Ctrl+Space 原义不变）。
    final ShortcutAction? spaceOverride = resolveReaderSpaceOverride(
      key: event.logicalKey,
      modifiers: modifiers,
      hasActiveAudiobook: _hasActiveAudiobook,
    );
    // BUG-099: bare Left/Right page-turn follows the reading direction (RTL book
    // advances on Left). Resolved before the registry, which binds Right=forward
    // unconditionally; null for any other key leaves default resolution intact.
    final ShortcutAction? arrowOverride = resolveReaderArrowPageTurn(
      key: event.logicalKey,
      modifiers: modifiers,
      rtl: _isRtlReading,
      reverse: ReaderHibikiSource.instance.reverseArrowPageTurn,
    );
    ShortcutAction? action = spaceOverride ??
        arrowOverride ??
        directReaderAction ??
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
    return _executeShortcutAction(
      action,
      keyboardTriggerKey: event.logicalKey,
    );
  }

  static bool _isReaderDirectCaretShortcut(ShortcutAction? action) {
    switch (action) {
      case ShortcutAction.readerLookupAtCursor:
      case ShortcutAction.readerShiftLookup:
      case ShortcutAction.readerCreateCardFromPopup:
        return true;
      default:
        return false;
    }
  }

  KeyEventResult? _handleGamepadAKeyEvent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.gameButtonA) return null;
    final ShortcutAction? resolvedAction =
        appModel.shortcutRegistry.resolveGamepad(
      GamepadButton.a,
      scope: ShortcutScope.reader,
    );
    if (resolvedAction != ShortcutAction.readerLookupAtCursor) return null;
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
      return _executeShortcutAction(
        ShortcutAction.readerLookupAtCursor,
        gamepadTriggerButton: GamepadButton.a,
      );
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
    return _executeShortcutAction(
          action,
          gamepadTriggerButton: button,
        ) ==
        KeyEventResult.handled;
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

  bool _isCaretEntryTrigger({
    LogicalKeyboardKey? keyboardTriggerKey,
    GamepadButton? gamepadTriggerButton,
  }) {
    if (keyboardTriggerKey != null) {
      return ReaderCaretRouter.isEnterTriggerKeyboard(
        keyboardTriggerKey,
        focusNavEnabled: _focusNavEnabled,
      );
    }
    if (gamepadTriggerButton != null) {
      return ReaderCaretRouter.isEnterTriggerGamepad(
        gamepadTriggerButton,
        focusNavEnabled: _focusNavEnabled,
      );
    }
    return _focusNavEnabled;
  }

  KeyEventResult _executeShortcutAction(
    ShortcutAction action, {
    LogicalKeyboardKey? keyboardTriggerKey,
    GamepadButton? gamepadTriggerButton,
  }) {
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
      case ShortcutAction.readerLookupAtCursor:
        if (_focusNavEnabled && _caretActive) {
          unawaited(_runCaretAction(CaretAction.activate));
        } else if (_isCaretEntryTrigger(
          keyboardTriggerKey: keyboardTriggerKey,
          gamepadTriggerButton: gamepadTriggerButton,
        )) {
          unawaited(_enterCaret());
        }
        return KeyEventResult.handled;
      case ShortcutAction.readerShiftLookup:
        if (_focusNavEnabled && _caretActive) {
          unawaited(_runCaretAction(CaretAction.lookup));
        } else if (_focusNavEnabled) {
          unawaited(_enterCaret());
        }
        return KeyEventResult.handled;
      case ShortcutAction.readerCreateCardFromPopup:
        final Future<void>? mining = topPopupState?.mineFirstVisibleEntry();
        if (mining != null) {
          unawaited(mining);
        }
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
      _caret.popupState = null;
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
      // 跳转词典是离散跳整段，每次按一下跳一本，绝不随长按连发（否则一口气
      // 冲过所有词典段）。
      case CaretAction.jumpDictNext:
      case CaretAction.jumpDictPrev:
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
        case CaretAction.jumpDictNext:
          await _caretJumpDict(true);
          break;
        case CaretAction.jumpDictPrev:
          await _caretJumpDict(false);
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
  void onDictionaryStackChanged() => _caret.onDictionaryStackChanged();

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

  /// Jump the cursor to the next/previous dictionary section header in a
  /// multi-dictionary popup (Yomitan-style "go to dictionary"). Popup-only — the
  /// reader and lyrics surfaces have no dictionary sections, so the keys/triggers
  /// no-op there (the JS returns 'blocked'). [forward] true → next dictionary
  /// below the cursor, false → previous above.
  Future<void> _caretJumpDict(bool forward) async {
    if (_caretSurface != CaretSurface.popup) return;
    await topPopupState?.caretJumpDict(forward);
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
  void onDictionaryPopupRendered(int index) =>
      _caret.onDictionaryPopupRendered(index);

  // ── DictionaryCaretHost ───────────────────────────────────────────
  // The reader is the host for its [_caret] state machine: it supplies the
  // popup-stack view and the `setState` / reader-ring side effects, while the
  // controller owns the surface/popup-state/busy fields and the popup transitions.

  @override
  bool get caretHostMounted => mounted;

  @override
  DictionaryPopupWebViewState? get caretTopPopupState => topPopupState;

  @override
  int get caretTopVisiblePopupIndex => topVisiblePopupIndex;

  @override
  void caretSetState(VoidCallback fn) {
    if (!mounted) {
      fn();
      return;
    }
    setState(fn);
  }

  /// Hide the reader-content caret ring (called by the controller only when the
  /// cursor leaves the reader surface for a popup). Mirrors the pre-extraction
  /// `_controller?.evaluateJavascript(ReaderCaretScripts.exit)`.
  @override
  void caretExitPrimaryRing() {
    _controller?.evaluateJavascript(
        source: ReaderCaretScripts.exitInvocation());
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
        await _refreshProgress();
        if (!mounted || _controller == null) return;
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
    final Offset global = box?.localToGlobal(webViewOffset) ?? webViewOffset;
    await _showReaderImageContextMenuAtGlobalPosition(imgUrl, global);
  }

  Future<void> _showReaderImageContextMenuAtGlobalPosition(
    String imgUrl,
    Offset globalPosition, {
    BuildContext? menuContext,
  }) async {
    if (!mounted || !isWindowsPlatform) return;
    final BuildContext effectiveContext = menuContext ?? context;
    final RenderBox overlay =
        Overlay.of(effectiveContext).context.findRenderObject()! as RenderBox;
    final double menuScale = _readerImageMenuScale;
    final String? action = await showMenu<String>(
      context: effectiveContext,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints(
        minWidth: 112.0 * menuScale,
        maxWidth: 280.0 * menuScale,
      ),
      menuPadding: EdgeInsets.symmetric(vertical: 8.0 * menuScale),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy',
          height: kMinInteractiveDimension * menuScale,
          padding: EdgeInsets.symmetric(horizontal: 16.0 * menuScale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.copy_outlined, size: 18.0 * menuScale),
              SizedBox(width: 12.0 * menuScale),
              Text(
                t.reader_copy_image,
                style: TextStyle(fontSize: 14.0 * menuScale),
              ),
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
        pageBuilder: (BuildContext routeContext, __, ___) => GestureDetector(
          onTap: () => Navigator.pop(context),
          onSecondaryTapDown: isWindowsPlatform
              ? (TapDownDetails details) {
                  unawaited(
                    _showReaderImageContextMenuAtGlobalPosition(
                      imgUrl,
                      details.globalPosition,
                      menuContext: routeContext,
                    ),
                  );
                }
              : null,
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

  // ── Floating Lyric ─────────────────────────────────────────────────
  //
  // TODO-291 阶段2：悬浮窗 / 媒体通知的「拉起 + cue 同步 + 控制流订阅」已上移到进程级
  // [AudiobookSession]，让退出书籍后仍能后台听书 + 悬浮刷字。reader 这里只保留：
  // ① reader 主题样式 [_readerFloatingLyricStyle]（attach 期通过 session.installReaderSurfaces
  //    注入，使悬浮窗用 reader 当前书的深色/竖排主题）；
  // ② 桌面悬浮窗点词路由 [_lookupFromFloatingLyric]（attach 期注入，路由进 reader 弹窗）；
  // ③ 设置开关 [_toggleFloatingLyric] / [_toggleMediaNotification]（薄壳，委托 session）。

  /// reader 主题悬浮窗样式（attach 期注入 session）。
  FloatingLyricStyle _readerFloatingLyricStyle({double? fontSize}) {
    final Color bg = _themeBackgroundColor();
    final Color fg = _themeTextColor();
    final bool dark = _isReaderThemeDark;
    final Color accent = dark
        ? HibikiColor.defaultHighlightYellow
        : Theme.of(context).colorScheme.primary;
    final int textOpacity = appModel.floatingLyricTextOpacity;
    final int buttonBgOpacity = appModel.floatingLyricButtonBgOpacity;
    return FloatingLyricStyle(
      fontSize: fontSize ?? appModel.floatingLyricFontSize,
      // TODO-370: 文字 / 按钮底色透明度按设置缩放 alpha（默认 100=保持原观感）。
      textColor: FloatingLyricStyle.scaleAlpha(fg.value, textOpacity),
      bgColor: bg.withAlpha(dark ? 230 : 220).value,
      buttonTextColor: fg.value,
      buttonBgColor: FloatingLyricStyle.scaleAlpha(
        (dark ? const Color(0x33FFFFFF) : const Color(0x1A000000)).value,
        buttonBgOpacity,
      ),
      highlightColor: accent.withAlpha(128).value,
      activeColor: accent.value,
    );
  }

  /// 设置 / 通知 custom action 翻转悬浮窗。委托 [AppModel.toggleFloatingLyricFromControls]
  /// （session 拉起/隐藏 + 偏好读写），失败时按平台显示提示。
  Future<bool> _toggleFloatingLyric() async {
    final bool wasOn = appModel.showFloatingLyric;
    final bool ok = await appModel.toggleFloatingLyricFromControls();
    if (!ok) {
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
    if (mounted) setState(() {});
    // 刚开启：让悬浮窗用 reader 主题样式（session 默认已是 app 级；attach 期 install 过
    // reader 样式，但若 toggle 在 attach 之前发生则补一次）。
    if (!wasOn) {
      await appModel.audiobookSession.applyFloatingLyricStyle();
    }
    return true;
  }

  /// Routes a tap on the desktop floating-lyric strip through the **clipboard
  /// lookup pipeline** (TODO-376). The strip is a separate native always-on-top
  /// window with no DOM selection, so we segment the tapped word
  /// ([floatingLyricSearchTerm] via [Language.wordFromIndex], the same extractor
  /// the Android popup uses) and hand it to [DesktopLookupService.triggerLookup]
  /// — the exact same outlet the desktop clipboard-watch / global-hotkey lookup
  /// uses. Per the user's decision ("复用剪贴板查词那套逻辑"), the result is shown
  /// in the main window's dictionary tab instead of an in-app popup rendered at
  /// the reader's screen centre, and [bringPendingLookupToFront] surfaces the
  /// main window (it is a no-op when already focused — TODO-341).
  ///
  /// On Android the overlay launches its own `PopupDictActivity`, so this
  /// handler is only exercised by the desktop back-end; on non-desktop hosts it
  /// is a no-op. It also no-ops when no usable word can be segmented.
  ///
  /// 排队 → 唤前台 → 请求首页切到查词 tab。切 tab 让 [HomeDictionaryPage] 挂载，
  /// 它在 initState 无条件消费已存在的 [DesktopLookupService.pendingText] 并展示——
  /// pending 必须在请求切 tab **之前**就位（这里顺序即如此），否则页面挂载时读不到。
  Future<void> _lookupFromFloatingLyric(String text, int index) async {
    if (!mounted) return;
    final String searchTerm = floatingLyricSearchTerm(
      text: text,
      index: index,
      word: appModel.targetLanguage.wordFromIndex(text: text, index: index),
    );
    if (searchTerm.isEmpty) return;
    if (!DesktopLookupService.isDesktop) return;
    DesktopLookupService.instance.triggerLookup(searchTerm);
    await DesktopLookupService.instance.bringPendingLookupToFront();
    if (!mounted) return;
    // 显式请求主窗切到查词 tab（与被动剪贴板正交）：HomeDictionaryPage 挂载后消费
    // pendingText 展示结果。不在阅读器内弹 in-app 中心浮层（用户决策）。
    appModel.requestHomeDictionaryTab();
  }

  // ── Media Notification ────────────────────────────────────────────
  // TODO-291 阶段2：媒体通知的 cue/播放态同步已上移到 [AudiobookSession] 常驻执行。
  // reader 只保留设置开关，翻转后委托 session 装/清通知卡片。

  Future<void> _toggleMediaNotification() async {
    final bool newValue = !appModel.showMediaNotification;
    await appModel.setShowMediaNotification(newValue);
    appModel.audiobookSession.onMediaNotificationToggled(enabled: newValue);
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
      // 导入了新音频：强制重 load（停旧会话再起新），否则同书会复用旧控制器不换源。
      await _resolveAudioSlot(forceReload: true);
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

      // 换了 SRT 书的音频：强制重 load（停旧会话再起新）。
      await _resolveAudioSlot(forceReload: true);
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
      final List<FavoriteSentence> favorites =
          await _favoriteSentencesForBook();

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
          final FloatingLyricStyle style =
              _readerFloatingLyricStyle(fontSize: v);
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
          _invalidateFavoriteSentenceCache();
          if (fav.sectionIndex == _currentChapter || _lyricsMode) {
            await _refreshSectionHighlights(
                fav.sectionIndex ?? _currentChapter);
          }
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
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
    } catch (e, stack) {
      // 半销毁的 WebView 上 evaluateJavascript 抛 PlatformException；此处尚未改
      // 任何恢复状态，安全 no-op 返回（此前这是 try 块外的孤儿 await，会逃 zone）。
      ErrorLogService.instance
          .log('ReaderHibiki.reloadWithCurrentSettings.eval', e, stack);
      return;
    }
    if (!mounted || _controller == null) return;
    final ReaderStableProgressDetails? snapshot =
        parseReaderStableProgressDetails(result);
    final bool hasSameChapterCache = _lastProgressSection == _currentChapter;
    _initialProgress =
        snapshot?.progress ?? (hasSameChapterCache ? _lastProgressValue : 0.0);
    // BUG-162 / TODO-219: reload 是同章程序化重建，优先沿用稳定精确锚；
    // stable gate 暂时不给快照时保留同章缓存，避免把瞬态章首 0 当新位置。
    _initialCharOffset = snapshot?.charOffset ??
        (hasSameChapterCache ? _lastProgressCharOffset : -1);
    _lastProgressSection = _currentChapter;
    _lastProgressValue = _initialProgress;
    _lastProgressCharOffset = _initialCharOffset;

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

  static const Map<String, ReaderThemeColors> _themeMap = {
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

  /// custom-theme 的四个角色色（用户自定义；任一项缺省回落到合理默认）。
  ReaderThemeColors get _customReaderThemeColors {
    final bool dark = appModel.customThemeDark;
    return (
      bg: appModel.customThemeBackgroundColor ?? const Color(0xFFFFFFFF),
      fg: appModel.customThemeFontColor ??
          (dark ? const Color(0xDEFFFFFF) : const Color(0xDE000000)),
      sasayaki:
          appModel.customThemeSasayakiColor ?? HibikiColor.defaultSasayakiColor,
      dark: dark,
    );
  }

  /// 当前主题 key 解析出的四个阅读器角色色，统一经 [resolveReaderThemeColors]：
  /// preset 命中用手调底色，未命中（light/system/未来 key）跟随真实 ColorScheme。
  ReaderThemeColors get _readerThemeColors {
    final String key = appModel.appThemeKey;
    return resolveReaderThemeColors(
      themeKey: key,
      presetMap: _themeMap,
      scheme: appModel.buildColorScheme(
        appModel.isDarkMode ? Brightness.dark : Brightness.light,
      ),
      customColors: key == 'custom-theme' ? _customReaderThemeColors : null,
    );
  }

  Color _themeBackgroundColor() => _readerThemeColors.bg;

  Color _themeTextColor() => _readerThemeColors.fg;

  Color _themeSasayakiColor() => _readerThemeColors.sasayaki;

  bool get _isReaderThemeDark => _readerThemeColors.dark;

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
      // reader 主题变了：让 session 用新的 reader 样式重刷悬浮窗
      // （reader 样式已在 attach 时 install 进 session）。
      await appModel.audiobookSession.applyFloatingLyricStyle();
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
    final List<FavoriteSentence> chapterFavs =
        await _favoriteSentencesForSection(section);
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
      _invalidateFavoriteSentenceCache();
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
    _invalidateFavoriteSentenceCache();
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
  // TODO-291 阶段2：_audiobookFromRow / _srtBookFromRow / _resolveAudioFiles 已移到
  // [AudiobookSessionLauncher]（reader 与书架共用会话解析）。
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
