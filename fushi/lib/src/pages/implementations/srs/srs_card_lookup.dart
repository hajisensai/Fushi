/// 复习卡面查词：卡面上点词 / 悬停取词 → 与阅读器、视频页同一个查词弹窗，弹窗里的释义
/// 继续点词一层层嵌套查下去。
///
/// - 弹窗、嵌套、制卡、收藏、自动发音全部复用 [DictionaryPageMixin] +
///   [DictionaryPopupController]（与 texthooker / 悬浮歌词 / 首页词典同一套弹窗引擎）；
///   弹窗里制卡走用户当前的制卡目标（可能就是 Fushi 复习本身）。
/// - 宿主 [SrsCardLookupHost] 把弹窗栈挂进根 Overlay（与 texthooker 同法：整棵浮层中和
///   到净缩放 1，点词得到的全局矩形与浮层同一坐标系）。
/// - 卡面上的取词表面（WebView 卡面、原生绘制的词条 / 例句）经 [SrsCardLookupScope]
///   拿到 [SrsCardLookupController] 并登记为 [SrsCardLookupSurface]：弹窗打开时整屏
///   dismiss barrier 盖住卡面，barrier 上的点按 / 悬停由控制器按坐标转回对应表面，
///   于是「弹窗开着时点卡面上的下一个词」直接换词，不必先关再点。
/// - 交互设置与阅读器同源：点按查词（`highlight_on_tap`）、悬停即查词
///   （`hover_auto_lookup`，另外按住 Shift 悬停恒可查）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show DictionarySearchResult;

import 'package:fushi/media.dart' show ReaderFushiSource;
import 'package:fushi/models.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/lookup/source_lookup_sentence.dart'
    show withFallbackMiningSentence;
import 'package:fushi/src/media/video/subtitle_transcript_text.dart'
    show subtitleTranscriptLookupSpan;
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi/src/reader/reader_host_hover_lookup.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/utils.dart';

/// 卡面取词的交互设置（与阅读器同源）。
typedef SrsCardLookupSettings = ({bool tap, bool hoverAuto});

/// 生产设置：阅读器的「点按查词」与「悬停即查词」。偏好层没就绪（极早期 / 测试）时
/// 按默认值（点按查词开、悬停即查词关）。
SrsCardLookupSettings srsCardLookupSettingsFromReader() {
  try {
    return (
      tap: ReaderFushiSource.instance.highlightOnTap,
      hoverAuto: ReaderFushiSource.instance.hoverAutoLookup,
    );
  } catch (_) {
    return (tap: true, hoverAuto: false);
  }
}

/// 一次查词请求（来自某个取词表面）。
@immutable
class SrsCardLookupRequest {
  const SrsCardLookupRequest({
    required this.term,
    required this.anchor,
    this.sentence = '',
    this.fromHover = false,
    this.origin,
    this.onMatched,
  });

  /// 查询串（命中字起到段尾，引擎按最长匹配回报命中长度）。
  final String term;

  /// 被点文字的全局矩形（弹窗据此避让、绝不盖住被查词）。
  final Rect anchor;

  /// 被查词所在的那句话：弹窗里制卡时 JS 没带例句就用它兜底。
  final String sentence;
  final bool fromHover;

  /// 发起查词的表面（弹窗关闭 / 换词时其它表面据此清掉自己的选区高亮）。
  final SrsCardLookupSurface? origin;

  /// 查到结果后回报命中字数（WebView 表面据此在卡面上高亮被查词）。
  final void Function(int matchedChars)? onMatched;
}

/// 卡面上的一块取词表面（WebView 卡面 / 原生文字区）。
abstract interface class SrsCardLookupSurface {
  /// 全局坐标 [globalPosition] 落在本表面上时在该处取词并返回 true；不在本表面上返回
  /// false。dismiss barrier 盖住卡面时，点按 / 悬停经这里转回卡面。
  bool lookupAt(Offset globalPosition, {required bool fromHover});

  /// 弹窗栈开 / 关（[origin] 是这次查词的发起表面）：表面据此清选区、更新页内门控。
  void onLookupStateChanged({
    required bool open,
    required SrsCardLookupSurface? origin,
  });
}

/// 查词结果的数据源（测试注入；生产走 [AppModel.searchDictionary]）。
typedef SrsCardLookupSearch =
    Future<DictionarySearchResult> Function(String term, int maximumTerms);

/// 卡面查词的数据源覆写点：null（生产）= 本机词典。widget 测试覆写成假词典。
final Provider<SrsCardLookupSearch?> srsCardLookupSearchProvider =
    Provider<SrsCardLookupSearch?>((Ref ref) => null);

/// 卡面查词的控制器：页面持有，宿主 [SrsCardLookupHost] 接上弹窗栈，各取词表面经
/// [SrsCardLookupScope] 找到它。
class SrsCardLookupController extends ChangeNotifier {
  SrsCardLookupController({SrsCardLookupSettings Function()? settings})
    : _settings = settings ?? srsCardLookupSettingsFromReader;

  final SrsCardLookupSettings Function() _settings;
  final List<SrsCardLookupSurface> _surfaces = <SrsCardLookupSurface>[];
  _SrsCardLookupHostState? _host;
  bool _open = false;
  SrsCardLookupSurface? _origin;
  final ReaderHostHoverLookupGate _barrierHover = ReaderHostHoverLookupGate();

  /// 当前交互设置（每次取词现读，设置页改了立即跟随）。
  SrsCardLookupSettings get settings => _settings();

  /// 查词弹窗（或搜索期占位）是否在屏上。打开期间复习页的空格 / Enter / 数字键
  /// 不翻面、不评分。
  bool get isOpen => _open;

  /// 栈里可见弹窗层数（测试观察嵌套用）。
  @visibleForTesting
  int get debugVisibleDepth => _host?._visibleDepth ?? 0;

  /// 最近一次查词的查询串（测试观察用）。
  @visibleForTesting
  List<String> get debugQueries =>
      List<String>.unmodifiable(_host?._queries ?? const <String>[]);

  void register(SrsCardLookupSurface surface) {
    if (!_surfaces.contains(surface)) _surfaces.add(surface);
  }

  void unregister(SrsCardLookupSurface surface) {
    _surfaces.remove(surface);
    if (identical(_origin, surface)) _origin = null;
  }

  /// 从某个表面发起一次顶层查词（换掉整栈）。宿主没挂上时 no-op。
  void lookup(SrsCardLookupRequest request) {
    final _SrsCardLookupHostState? host = _host;
    if (host == null || request.term.trim().isEmpty) return;
    _origin = request.origin;
    for (final SrsCardLookupSurface s in List<SrsCardLookupSurface>.of(
      _surfaces,
    )) {
      if (!identical(s, request.origin)) {
        s.onLookupStateChanged(open: true, origin: request.origin);
      }
    }
    host._present(request);
  }

  /// 在弹窗栈之上再压一层（弹窗释义里点词的嵌套查词入口，测试也走它）。
  Future<int> pushNested(String query, Rect selectionRect) =>
      _host?._pushNested(query, selectionRect) ?? Future<int>.value(0);

  /// 关掉最上面一层；没有可见弹窗返回 false。
  bool closeTop() => _host?._closeTop() ?? false;

  /// 关掉整栈。
  void closeAll() => _host?._closeAll();

  /// 把 [globalPosition] 交给落点所在的取词表面（barrier 转发用）。
  bool lookupAt(Offset globalPosition, {required bool fromHover}) {
    for (final SrsCardLookupSurface s in List<SrsCardLookupSurface>.of(
      _surfaces,
    )) {
      if (s.lookupAt(globalPosition, fromHover: fromHover)) return true;
    }
    return false;
  }

  void _setOpen(bool open) {
    if (open == _open) return;
    _open = open;
    if (!open) _barrierHover.reset();
    for (final SrsCardLookupSurface s in List<SrsCardLookupSurface>.of(
      _surfaces,
    )) {
      s.onLookupStateChanged(open: open, origin: _origin);
    }
    notifyListeners();
  }

  /// 弹窗打开时页面的按键闸：Esc 关一层；会翻面 / 评分 / 换卡的键一律吞掉（不落到
  /// 复习 / 浏览动作上）；其它键照常。弹窗没开时返回 null（页面照常处理）。
  KeyEventResult? guardKey(KeyEvent event) {
    if (!_open) return null;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) closeTop();
      return KeyEventResult.handled;
    }
    if (srsLookupSwallowedKeys.contains(key)) return KeyEventResult.handled;
    return null;
  }

  /// 卡面 WebView 键盘桥回传的 token 在弹窗打开时的处置：返回 true = 已消费（页面
  /// 不再按复习 / 浏览动作处理）。
  bool guardBridgeToken(String token) {
    if (!_open) return false;
    if (token == 'Escape') closeTop();
    return true;
  }
}

/// 弹窗打开期间吞掉的键（翻面 / 评分 / 换卡）。
final Set<LogicalKeyboardKey> srsLookupSwallowedKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
};

/// 把 [SrsCardLookupController] 交给卡面里的取词表面。[controller] 为 null = 这棵子树
/// 不取词（例如正面预热在 Offstage 里的释义 WebView）。
class SrsCardLookupScope extends InheritedWidget {
  const SrsCardLookupScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SrsCardLookupController? controller;

  static SrsCardLookupController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SrsCardLookupScope>()
      ?.controller;

  @override
  bool updateShouldNotify(SrsCardLookupScope oldWidget) =>
      !identical(oldWidget.controller, controller);
}

/// 查词宿主上制卡时的外部来源：页面标题 + 网址（app 内浏览器的当前网页）。
///
/// 用通用记录类型而不是浏览器的来源类，宿主层不依赖 web_browser 层。
typedef SrsCardLookupCardSource = ({String title, Uri url});

/// 卡面查词宿主：给 [child] 提供 [SrsCardLookupScope]，把弹窗栈挂进根 Overlay。
class SrsCardLookupHost extends ConsumerStatefulWidget {
  const SrsCardLookupHost({
    super.key,
    required this.controller,
    required this.child,
    this.onClosed,
    this.cardSource,
  });

  final SrsCardLookupController controller;
  final Widget child;

  /// 整栈关掉之后（页面据此经 PageFocusOwnership 回收焦点）。
  final VoidCallback? onClosed;

  /// 弹窗里制卡时的卡片来源，制卡那一刻现取（标签页可能已导航）。返回 null = 不带来源
  /// （如无痕标签页）。不传（复习卡面）时制卡与以前完全一样。
  final SrsCardLookupCardSource? Function()? cardSource;

  @override
  ConsumerState<SrsCardLookupHost> createState() => _SrsCardLookupHostState();
}

class _SrsCardLookupHostState extends ConsumerState<SrsCardLookupHost>
    with DictionaryPageMixin {
  late final AppModel _appModel = ref.read(appProvider);
  late final DictionaryPopupController _popup = DictionaryPopupController(
    lowMemory: false,
    onLookupStackDepthChanged: recordLookupStackDepth,
  );

  OverlayEntry? _overlayEntry;
  bool _overlayRebuildScheduled = false;
  bool _routeCurrent = true;

  /// 当前顶层查词所在的那句（弹窗里制卡的例句兜底）。
  String _sentence = '';

  /// 当前顶层查词的锚点：barrier 上再点同一个词 = 只关弹窗（与阅读器再点同词取消一致）。
  Rect? _topAnchor;
  final List<String> _queries = <String>[];

  @override
  AppModel get mixinAppModel => _appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  String get lookupDiagHost => 'srs';

  @override
  Future<DictionarySearchResult> searchPopupDictionary({
    required String term,
    required int maximumTerms,
  }) {
    final SrsCardLookupSearch? search = ref.read(srsCardLookupSearchProvider);
    if (search != null) return search(term, maximumTerms);
    return super.searchPopupDictionary(term: term, maximumTerms: maximumTerms);
  }

  @override
  String? get miningDocumentTitle {
    final String? title = widget.cardSource?.call()?.title.trim();
    return title == null || title.isEmpty ? null : title;
  }

  @override
  String? get miningSourceUrl => widget.cardSource?.call()?.url.toString();

  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) =>
      super.onMineEntry(withFallbackMiningSentence(fields, _sentence));

  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) => super.onUpdateEntry(
    noteId,
    withFallbackMiningSentence(fields, _sentence),
  );

  int get _visibleDepth =>
      _popup.entries.where((DictionaryPopupEntry e) => e.visible).length;

  bool get _stackOpen => _popup.hasVisiblePopup || _popup.isSearchingUi;

  @override
  void initState() {
    super.initState();
    widget.controller._host = this;
    attachLookupCounter(_popup);
  }

  @override
  void didUpdateWidget(SrsCardLookupHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller._host, this)) {
        oldWidget.controller._host = null;
      }
      widget.controller._host = this;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 本页之上压了别的路由（编辑页 / 浏览 / 来源跳转 / 对话框）：弹窗栈挂在根 Overlay，
    // 不收起会盖在新路由上面。
    final bool current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current != _routeCurrent) {
      _routeCurrent = current;
      if (!current && _stackOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _closeAll();
        });
      }
      _scheduleOverlayRebuild();
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller._host, this)) {
      widget.controller._host = null;
    }
    final OverlayEntry? entry = _overlayEntry;
    if (entry != null) {
      if (entry.mounted) entry.remove();
      entry.dispose();
      _overlayEntry = null;
    }
    widget.controller._setOpen(false);
    _popup.dispose();
    super.dispose();
  }

  /// 弹窗栈的每次变化都经 mixin 的 setState：顺带同步「是否打开」并重建浮层。
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _afterStackChange();
  }

  void _afterStackChange() {
    final bool open = _stackOpen;
    final bool wasOpen = widget.controller.isOpen;
    widget.controller._setOpen(open);
    if (wasOpen && !open) {
      _topAnchor = null;
      widget.onClosed?.call();
    }
    _scheduleOverlayRebuild();
  }

  void _present(SrsCardLookupRequest request) {
    _popup.lowMemory = _appModel.lowMemoryMode;
    _popup.seedWarmSlot();
    _sentence = request.sentence;
    _topAnchor = request.anchor;
    _queries.add(request.term.trim());
    unawaited(() async {
      final int matched = await pushNestedPopup(
        query: request.term,
        selectionRect: request.anchor,
        controller: _popup,
        replaceStack: true,
        reuseWarmSlot: true,
        autoRead: !request.fromHover,
      );
      if (mounted && matched > 0) request.onMatched?.call(matched);
    }());
  }

  Future<int> _pushNested(String query, Rect selectionRect) {
    _queries.add(query.trim());
    return pushNestedPopup(
      query: query,
      selectionRect: selectionRect,
      controller: _popup,
    );
  }

  int get _topVisibleIndex {
    final int i = _popup.lastVisibleIndex;
    return i < 0 ? 0 : i;
  }

  bool _closeTop() {
    if (!_stackOpen) return false;
    popNestedPopupAt(_topVisibleIndex, _popup);
    return true;
  }

  void _closeAll() {
    if (!_stackOpen) return;
    popNestedPopupAt(0, _popup);
  }

  /// barrier 上的点按：先关整栈；点在卡面的另一个词上则直接换查那个词（点回同一个词
  /// 只关弹窗）。
  void _onBarrierTap(Offset global) {
    final Rect? anchor = _topAnchor;
    _closeAll();
    if (anchor != null && anchor.inflate(2).contains(global)) return;
    if (!widget.controller.settings.tap) return;
    widget.controller.lookupAt(global, fromHover: false);
  }

  /// barrier 盖住卡面后，悬停查词只剩这里（与阅读器 BUG-861 同理）。
  void _onBarrierHover(PointerHoverEvent event) {
    final SrsCardLookupSettings s = widget.controller.settings;
    if (!widget.controller._barrierHover.shouldLookup(
      event.position,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      hoverAutoLookup: s.hoverAuto,
    )) {
      return;
    }
    final Rect? anchor = _topAnchor;
    if (anchor != null && anchor.inflate(2).contains(event.position)) return;
    widget.controller.lookupAt(event.position, fromHover: true);
  }

  void _scheduleOverlayRebuild() {
    if (_overlayRebuildScheduled) return;
    _overlayRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayRebuildScheduled = false;
      _syncOverlay();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _syncOverlay() {
    if (!mounted) return;
    if (_popup.entries.isEmpty && !_popup.isSearchingUi) {
      final OverlayEntry? entry = _overlayEntry;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
        _overlayEntry = null;
      }
      return;
    }
    final OverlayEntry? existing = _overlayEntry;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildOverlay);
    _overlayEntry = entry;
    overlay.insert(entry);
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    if (!mounted || !_routeCurrent) return const SizedBox.shrink();
    return LookupOverlayNavigator(
      child: FushiAppUiScaleNeutralizer(
        child: Theme(
          data: _appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
          child: Builder(
            builder: (BuildContext context) {
              if (!mounted) return const SizedBox.shrink();
              return Stack(
                clipBehavior: Clip.none,
                children: _buildPopups(context),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPopups(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    return <Widget>[
      if (shouldShowLookupDismissBarrier(
        hasVisiblePopup: _popup.hasVisiblePopup,
        isSearching: _popup.isSearchingUi,
        hiddenByDialog: lookupPopupHiddenByDialog,
      ))
        Positioned.fill(
          child: LookupDismissBarrier(
            key: const ValueKey<String>('srs-lookup-barrier'),
            onTapDismiss: _onBarrierTap,
            onSwipeDismiss: () => _closeTop(),
            swipeEnabled: ReaderFushiSource.instance.enableSwipeToClose,
            touchSwipeEnabled:
                ReaderFushiSource.instance.enableTouchSwipeToClose,
            sensitivity: ReaderFushiSource.instance.dismissSwipeSensitivity,
            onPointerHover: _onBarrierHover,
            onNonPrimaryButtonDown: onDismissBarrierNonPrimaryButton,
          ),
        ),
      if (_popup.isSearchingUi && _popup.pendingRect != null)
        buildPopupLoadingPlaceholder(rect: _popup.pendingRect!, screen: screen),
      for (int i = 0; i < _popup.entries.length; i++)
        buildNestedPopupLayer(
          index: i,
          screen: screen,
          controller: _popup,
          // 弹窗释义里点词 → 再压一层（嵌套查词，与阅读器 / 视频页同一入口）。
          onPush: _pushNested,
          onPop: (int index) => popNestedPopupAt(index, _popup),
        ),
      ...buildParkedRealmLayers(screen: screen, controller: _popup),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SrsCardLookupScope(
      controller: widget.controller,
      child: widget.child,
    );
  }
}

// ------------------------------------------------------------------ WebView 卡面

/// 卡面 WebView 的取词脚本（依赖 `window.fushiSelection`，即阅读器同一份选区脚本
/// [ReaderSelectionScripts.source]）。
///
/// - 点按：原始 pointerup / touchend + 12px 位移门（拖动滚动不误触；不依赖合成
///   click，与歌词模式 BUG-280 同理）。点在链接、按钮、表单、`onclick` / `role=button`、
///   `cursor:pointer` 的元素上不取词——卡片模板自己的点击操作（展开释义、切换注音、
///   播放按钮）照旧；拖选出非空原生选区时也不取词。
/// - 悬停：按住 Shift 或开了「悬停即查词」，鼠标越过 8px 即取词（与阅读器 JS 腿同阈值）；
///   宿主侧接管悬停的平台（macOS，BUG-2508）由 `hostHover` 关掉本腿。
/// - 门控 `window.__fushiSrsLookup = {tap, hover, hostHover, open}` 由 Dart 下发；弹窗
///   打开期间（`open`）点按交给 Flutter 的 dismiss barrier 统一处置，页内不再取词。
const String kSrsCardLookupScript = r'''
(function(){
  if (window.__fushiSrsLookupInstalled) return;
  window.__fushiSrsLookupInstalled = true;
  function gate(){ return window.__fushiSrsLookup || {}; }
  function blocked(el){
    for (var n = el; n && n.nodeType === 1 && n !== document.body &&
        n !== document.documentElement; n = n.parentElement) {
      var tag = n.tagName;
      if (tag === 'A' || tag === 'BUTTON' || tag === 'INPUT' ||
          tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'SUMMARY' ||
          tag === 'LABEL' || tag === 'AUDIO' || tag === 'VIDEO') return true;
      if (n.hasAttribute('onclick') || n.getAttribute('role') === 'button' ||
          n.isContentEditable) return true;
      try {
        if (window.getComputedStyle(n).cursor === 'pointer') return true;
      } catch (e) {}
    }
    return false;
  }
  function selectAt(x, y, hover){
    if (!window.fushiSelection) return;
    var el = document.elementFromPoint(x, y);
    if (!el || blocked(el)) return;
    window.fushiSelection.selectText(x, y, 400, hover);
  }
  var sx = 0, sy = 0, moved = false, has = false;
  function start(x, y){ sx = x; sy = y; moved = false; has = true; }
  function move(x, y){
    if (!has) return;
    if (Math.abs(x - sx) > 12 || Math.abs(y - sy) > 12) moved = true;
  }
  function end(x, y){
    if (!has) return;
    has = false;
    if (moved) return;
    var g = gate();
    if (!g.tap || g.open) return;
    var sel = window.getSelection ? window.getSelection() : null;
    if (sel && !sel.isCollapsed && String(sel).length > 0) return;
    selectAt(x, y, false);
  }
  window.__fushiSrsLookupTap = end;
  document.addEventListener('touchstart', function(e){
    if (e.touches.length !== 1) { has = false; return; }
    var t = e.touches[0]; start(t.clientX, t.clientY);
  }, {passive: true});
  document.addEventListener('touchmove', function(e){
    var t = e.touches[0]; if (t) move(t.clientX, t.clientY);
  }, {passive: true});
  document.addEventListener('touchend', function(e){
    var t = e.changedTouches[0]; if (t) end(t.clientX, t.clientY);
  }, {passive: true});
  document.addEventListener('touchcancel', function(){ has = false; });
  document.addEventListener('pointerdown', function(e){
    if (e.pointerType === 'touch' || e.button !== 0) return;
    start(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointermove', function(e){
    if (e.pointerType === 'touch') return;
    move(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointerup', function(e){
    if (e.pointerType === 'touch' || e.button !== 0) return;
    end(e.clientX, e.clientY);
  }, {passive: true});
  var hx = -1, hy = -1;
  document.addEventListener('mousemove', function(e){
    var g = gate();
    if (g.hostHover || g.open) return;
    if (!e.shiftKey && !g.hover) { hx = -1; hy = -1; return; }
    var dx = e.clientX - hx, dy = e.clientY - hy;
    if (dx * dx + dy * dy < 64) return;
    hx = e.clientX; hy = e.clientY;
    selectAt(e.clientX, e.clientY, true);
  }, {passive: true});
})();
''';

/// 卡面上被查词的高亮（阅读器选区脚本的 CSS Highlight / 包裹 span）。颜色取卡面主题的
/// 强调色；高亮只改底色，不动排版。
const String kSrsCardLookupCss = '''
::highlight(fushi-selection){background-color:color-mix(in srgb,var(--fushi-srs-accent,#3b82f6) 32%,transparent);color:inherit;}
.fushi-dict-highlight{background-color:color-mix(in srgb,var(--fushi-srs-accent,#3b82f6) 32%,transparent)!important;color:inherit;border-radius:2px;}
ruby.fushi-selection-ruby-active{background-color:color-mix(in srgb,var(--fushi-srs-accent,#3b82f6) 32%,transparent)!important;border-radius:2px;}
''';

/// 页内取词门控的下发脚本。
String srsCardLookupGateScript({
  required bool tap,
  required bool hover,
  required bool hostHover,
  required bool open,
}) =>
    'window.__fushiSrsLookup = {tap: $tap, hover: $hover, '
    'hostHover: $hostHover, open: $open};';

/// 安装取词能力的整段脚本（选区脚本 + 高亮样式 + 点按 / 悬停监听），幂等。
String srsCardLookupInstallScript(String selectionSource) =>
    '(function(){'
    'if (!window.fushiSelection) {$selectionSource\n}'
    'if (!document.getElementById("fushi-srs-lookup-css")) {'
    'var s = document.createElement("style");'
    's.id = "fushi-srs-lookup-css";'
    's.textContent = ${jsonEncode(kSrsCardLookupCss)};'
    'document.head.appendChild(s);}'
    '})();\n$kSrsCardLookupScript';

// ------------------------------------------------------------------ 原生文字区

/// 原生文字区里一段可取词的文字（挂在包住该文字的 [MetaData] 上）。
///
/// [text] 是整段的纯文本；文字由带注音的 [WidgetSpan] 拼成时（[SrsRubyText]），外层
/// 段落的纯文本里每个注音段只占一个占位符，[segments] 记下各段在两边的偏移以便换算。
@immutable
class SrsLookupTextData {
  const SrsLookupTextData(this.text, {this.segments});

  final String text;

  /// 注音拼接文字的分段：`(outerStart, outerLength, fullStart, placeholder)`。
  final List<SrsLookupTextSegment>? segments;

  /// 外层段落纯文本里的 UTF-16 偏移 → [text] 里的偏移；落在占位符上返回 null。
  int? mapOuterOffset(int outer) {
    final List<SrsLookupTextSegment>? segs = segments;
    if (segs == null) return outer;
    for (final SrsLookupTextSegment s in segs) {
      if (outer >= s.outerStart && outer < s.outerStart + s.outerLength) {
        return s.placeholder ? null : s.fullStart + (outer - s.outerStart);
      }
    }
    return null;
  }
}

/// [SrsLookupTextData.segments] 的一段。
@immutable
class SrsLookupTextSegment {
  const SrsLookupTextSegment({
    required this.outerStart,
    required this.outerLength,
    required this.fullStart,
    required this.placeholder,
  });

  final int outerStart;
  final int outerLength;
  final int fullStart;
  final bool placeholder;
}

/// 注音段（[WidgetSpan]）里的基字 / 注音文字：[fullStart] 是该段在整段纯文本里的起点。
@immutable
class SrsLookupRubySegment {
  const SrsLookupRubySegment({required this.fullStart, required this.isRuby});

  final int fullStart;

  /// 点在注音（假名）上：按该段起点取词。
  final bool isRuby;
}

/// 把一段原生文字标成可取词（[SrsNativeLookupRegion] 只认这样标过的文字，按钮 /
/// 词频标签 / 音调图之类不会被误查）。
Widget srsLookupText({required String text, required Widget child}) =>
    MetaData(metaData: SrsLookupTextData(text), child: child);

/// 一次原生取词命中。
typedef SrsNativeLookupHit = ({
  String term,
  String sentence,
  Rect anchor,
  RenderParagraph paragraph,
  int start,
});

/// 在 [root] 子树里按全局坐标找被点的字（纯几何，可单测）：命中路径上最深的
/// [RenderParagraph] + 最近的 [SrsLookupTextData] 标记 → 整段纯文本里的偏移 →
/// 查询串（命中字起到段尾；拉丁词回退到词首）。没有标记 / 点在字形盒外返回 null。
SrsNativeLookupHit? srsNativeLookupHitAt(RenderBox root, Offset global) {
  if (!root.attached || !root.hasSize) return null;
  final Offset local = root.globalToLocal(global);
  if (!(Offset.zero & root.size).contains(local)) return null;
  final BoxHitTestResult result = BoxHitTestResult();
  if (!root.hitTest(result, position: local)) return null;
  RenderParagraph? paragraph;
  SrsLookupRubySegment? segment;
  SrsLookupTextData? data;
  for (final HitTestEntry entry in result.path) {
    final HitTestTarget target = entry.target;
    if (paragraph == null) {
      if (target is RenderParagraph) paragraph = target;
      continue;
    }
    if (target is RenderMetaData) {
      final Object? meta = target.metaData;
      if (meta is SrsLookupRubySegment && segment == null) {
        segment = meta;
      } else if (meta is SrsLookupTextData) {
        data = meta;
        break;
      }
    }
  }
  if (paragraph == null || data == null || data.text.isEmpty) return null;
  final String paraText = paragraph.text.toPlainText(
    includeSemanticsLabels: false,
  );
  if (paraText.isEmpty) return null;
  final Offset paraLocal = paragraph.globalToLocal(global);
  // 逐字真实渲染盒命中（与视频字幕列表同一判据，BUG-916），点在字形盒外不算。
  int offset = -1;
  Rect? box;
  int utf16 = 0;
  for (final String g in paraText.characters) {
    final List<TextBox> boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: utf16, extentOffset: utf16 + g.length),
      boxHeightStyle: BoxHeightStyle.max,
    );
    for (final TextBox b in boxes) {
      final Rect r = b.toRect();
      if (r.contains(paraLocal)) {
        offset = utf16;
        box = r;
        break;
      }
    }
    if (offset >= 0) break;
    utf16 += g.length;
  }
  if (offset < 0 || box == null) return null;
  final int? full = segment != null
      ? (segment.isRuby ? segment.fullStart : segment.fullStart + offset)
      : data.mapOuterOffset(offset);
  if (full == null || full < 0 || full >= data.text.length) return null;
  final int graphemeIndex = data.text.substring(0, full).characters.length;
  final ({int start, String term}) span = subtitleTranscriptLookupSpan(
    data.text,
    graphemeIndex,
  );
  // 查询串止于行尾、最多 100 字（引擎按最长匹配回报命中长度，后面的字只是候选余量；
  // 跨行粘上下一段反而会造出假匹配）。
  String term = span.term;
  final int newline = term.indexOf('\n');
  if (newline >= 0) term = term.substring(0, newline);
  if (term.characters.length > 100) term = term.characters.take(100).string;
  if (term.trim().isEmpty) return null;
  final int startUtf16 = data.text.characters.take(span.start).string.length;
  final String sentence = extractSentenceAt(data.text, startUtf16, 1).sentence;
  return (
    term: term,
    sentence: sentence.isEmpty ? data.text : sentence,
    // 字形盒整个经段落到根的变换（含界面缩放）：只平移原点会把盒子的位置与高宽留在
    // 1/缩放，弹窗按偏高的下沿摆、盖住被查的那一行（复习页不在缩放中和层之下）。
    anchor: MatrixUtils.transformRect(paragraph.getTransformTo(null), box),
    paragraph: paragraph,
    start: startUtf16,
  );
}

/// 原生绘制的卡面区：点按 / 悬停取词（只认 [srsLookupText] 标过的文字）。
///
/// 用原始 [Listener] 而不进手势竞技场：卡面原有的点击（点卡切换词条 / 例句、点例句
/// 显示注音、播放音频、看大图）照常赢；需要让位的点击处理器经 [tookTap] 知道这一下
/// 已经被取词用掉了（Listener 的 pointerUp 先于竞技场的 tap 回调派发）。
class SrsNativeLookupRegion extends StatefulWidget {
  const SrsNativeLookupRegion({super.key, required this.child});

  final Widget child;

  @override
  State<SrsNativeLookupRegion> createState() => SrsNativeLookupRegionState();
}

class SrsNativeLookupRegionState extends State<SrsNativeLookupRegion>
    implements SrsCardLookupSurface {
  SrsCardLookupController? _controller;
  Offset? _down;
  bool _moved = false;
  bool _primary = false;
  SrsNativeLookupHit? _pendingHit;
  bool _tookTap = false;
  final ReaderHostHoverLookupGate _hover = ReaderHostHoverLookupGate();
  ({RenderParagraph paragraph, int start})? _hovered;

  /// 最近这次点按是否已被取词用掉（卡面自己的点击处理器据此让位）。
  bool get tookTap => _tookTap;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final SrsCardLookupController? next = SrsCardLookupScope.of(context);
    if (!identical(next, _controller)) {
      _controller?.unregister(this);
      _controller = next;
      next?.register(this);
    }
  }

  @override
  void dispose() {
    _controller?.unregister(this);
    super.dispose();
  }

  RenderBox? get _box {
    final RenderObject? r = context.findRenderObject();
    return r is RenderBox ? r : null;
  }

  @override
  bool lookupAt(Offset globalPosition, {required bool fromHover}) {
    final SrsCardLookupController? c = _controller;
    final RenderBox? box = _box;
    if (c == null || box == null || !mounted) return false;
    final SrsNativeLookupHit? hit = srsNativeLookupHitAt(box, globalPosition);
    if (hit == null) return false;
    return _lookupHit(c, hit, fromHover: fromHover);
  }

  bool _lookupHit(
    SrsCardLookupController c,
    SrsNativeLookupHit hit, {
    required bool fromHover,
  }) {
    if (fromHover) {
      final ({RenderParagraph paragraph, int start}) key = (
        paragraph: hit.paragraph,
        start: hit.start,
      );
      if (c.isOpen && _hovered == key) return true;
      _hovered = key;
    } else {
      _hovered = null;
    }
    c.lookup(
      SrsCardLookupRequest(
        term: hit.term,
        anchor: hit.anchor,
        sentence: hit.sentence,
        fromHover: fromHover,
        origin: this,
      ),
    );
    return true;
  }

  @override
  void onLookupStateChanged({
    required bool open,
    required SrsCardLookupSurface? origin,
  }) {
    if (!open) {
      _hovered = null;
      _hover.reset();
    }
  }

  void _onDown(PointerDownEvent e) {
    _down = e.position;
    _moved = false;
    _tookTap = false;
    _pendingHit = null;
    _primary = e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryButton;
    // 命中在按下时就算好：抬起那一刻可滚动的卡面正处在按住 / 拖动活动里，Scrollable
    // 会让子树暂时不参与命中测试（IgnorePointer），抬起时再测就落空。
    final SrsCardLookupController? c = _controller;
    final RenderBox? box = _box;
    if (!_primary || c == null || box == null || c.isOpen || !c.settings.tap) {
      return;
    }
    _pendingHit = srsNativeLookupHitAt(box, e.position);
  }

  void _onMove(PointerMoveEvent e) {
    final Offset? d = _down;
    if (d != null && (e.position - d).distance > kTouchSlop) _moved = true;
  }

  void _onUp(PointerUpEvent e) {
    final Offset? d = _down;
    final SrsNativeLookupHit? hit = _pendingHit;
    _down = null;
    _pendingHit = null;
    final SrsCardLookupController? c = _controller;
    if (d == null || hit == null || _moved || c == null || c.isOpen) return;
    _tookTap = _lookupHit(c, hit, fromHover: false);
  }

  void _onHover(PointerHoverEvent e) {
    final SrsCardLookupController? c = _controller;
    if (c == null || e.kind != PointerDeviceKind.mouse) return;
    final RenderBox? box = _box;
    if (box == null) return;
    if (!_hover.shouldLookup(
      box.globalToLocal(e.position),
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      hoverAutoLookup: c.settings.hoverAuto,
    )) {
      return;
    }
    lookupAt(e.position, fromHover: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) return widget.child;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: (_) {
        _down = null;
        _pendingHit = null;
      },
      onPointerHover: _onHover,
      child: widget.child,
    );
  }
}

/// [SrsBlankTapRegion.excluded] 在命中路径上留下的标记。
const Object _kSrsBlankTapExcluded = Object();

/// 原生卡面上的「点空白」：一次没有拖动的主键点按，落点上没有取词命中、没有带点击 /
/// 长按处理的子控件（按钮、图片、来源链接、例句注音切换），也不在 [excluded] 圈出的
/// 子树上（释义 WebView：那里的空白由页内取词脚本回报 `onTapEmpty`）——满足才调
/// [onTapEmpty]。复习页据此切换悬浮顶栏（与小说、漫画阅读器「点空白切换顶栏」同口径）。
///
/// 只旁观指针（Listener），不进手势竞技场：卡面的拖选、点按、滚动一概不受影响。命中
/// 在按下时判（抬起时可滚动的卡面正处在拖动活动里，子树暂不参与命中测试）。必须包在
/// [SrsNativeLookupRegion] **外面**：同一次抬起时取词区先处理，[tapTookLookup] 才已定。
class SrsBlankTapRegion extends StatefulWidget {
  const SrsBlankTapRegion({
    super.key,
    required this.onTapEmpty,
    required this.tapTookLookup,
    required this.child,
    this.onTapBelowContent,
    this.contentRect,
  });

  /// 圈出一块「点按不归原生区判空白」的子树。
  static Widget excluded({required Widget child}) =>
      MetaData(metaData: _kSrsBlankTapExcluded, child: child);

  final VoidCallback? onTapEmpty;

  /// 落点在 [contentRect] 下沿**以下**时改调它（而不是 [onTapEmpty]）。
  final VoidCallback? onTapBelowContent;

  /// 当前内容块的全局矩形（null = 没有可比的内容边界，一律走 [onTapEmpty]）。抬起时读，
  /// 所以滚动后的位置也是新的。
  final Rect? Function()? contentRect;

  /// 这一下点按是否已被原生取词用掉。
  final bool Function() tapTookLookup;
  final Widget child;

  @override
  State<SrsBlankTapRegion> createState() => _SrsBlankTapRegionState();
}

class _SrsBlankTapRegionState extends State<SrsBlankTapRegion> {
  int? _pointer;
  Offset? _down;
  bool _moved = false;

  /// 按下点 [global] 是否落在某个自己处理点按的子控件上（只看本区域以内的命中）。
  bool _hitsTapTarget(Offset global) {
    final RenderObject? self = context.findRenderObject();
    if (self == null) return true;
    final HitTestResult result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    for (final HitTestEntry entry in result.path) {
      final HitTestTarget target = entry.target;
      if (identical(target, self)) return false;
      if (target is RenderSemanticsGestureHandler &&
          (target.onTap != null || target.onLongPress != null)) {
        return true;
      }
      // 自报可点的控件：图标按钮（[FushiIconButton] 内层 InkWell 不进语义，命中路径上只有
      // 外层的 `Semantics(button: true)`）、视频片段画面等。不认它们，点按钮 / 点视频会
      // 被当成点空白，顺带切换悬浮顶栏。
      if (target is RenderSemanticsAnnotations) {
        final SemanticsProperties p = target.properties;
        if (p.button == true || p.link == true || p.onTap != null) return true;
      }
      if (target is RenderMetaData &&
          identical(target.metaData, _kSrsBlankTapExcluded)) {
        return true;
      }
    }
    return true;
  }

  void _onDown(PointerDownEvent e) {
    _pointer = null;
    if (widget.onTapEmpty == null) return;
    final bool primary =
        e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryButton;
    // 查词弹窗开着时这一下是关弹窗，不切换顶栏。
    final bool lookupOpen = SrsCardLookupScope.of(context)?.isOpen ?? false;
    if (!primary || lookupOpen || _hitsTapTarget(e.position)) return;
    _pointer = e.pointer;
    _down = e.position;
    _moved = false;
  }

  void _onMove(PointerMoveEvent e) {
    final Offset? d = _down;
    if (e.pointer == _pointer && d != null) {
      if ((e.position - d).distance > kTouchSlop) _moved = true;
    }
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_moved || widget.tapTookLookup()) return;
    final Rect? content = widget.contentRect?.call();
    final VoidCallback? below = widget.onTapBelowContent;
    if (below != null && content != null && e.position.dy > content.bottom) {
      below();
      return;
    }
    widget.onTapEmpty?.call();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: _onUp,
    onPointerCancel: (_) => _pointer = null,
    child: widget.child,
  );
}
