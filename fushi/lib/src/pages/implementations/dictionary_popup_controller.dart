import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

/// Shared empty result used to mount the popup WebView during the search phase
/// (BUG-080), so popup.html + JS + CSS cold-load in parallel with the FFI
/// lookup instead of serially after it, **and** to seed / re-park the resident
/// warm slot ([DictionaryPopupController.seedWarmSlot] / dismiss restore).
///
/// 必须是**同一个单例**：`DictionaryPopupWebView.didUpdateWidget` 按 result 对象
/// 身份判断是否重推（`oldWidget.result != widget.result`）。热槽 seed、关栈复位、
/// 搜索期占位（[DictionaryPopupController.beginTop] 的 `initialResult` 与
/// dictionary_popup_layer 的 `result ?? kPopupSearchingPlaceholderResult` 兜底）
/// 若各持一个空结果实例，空→空的身份变化也会触发一整次 `renderPopup()` no-results
/// 重画——每次查词凭空多一遍 WebView 渲染。canonical 实例放本文件（controller 是
/// 唯一内部消费者且保持纯逻辑可测），dictionary_popup_layer.dart re-export 供各宿主用。
final DictionarySearchResult kPopupSearchingPlaceholderResult =
    DictionarySearchResult(searchTerm: '');

/// 统一的查词弹窗条目（合并旧 `_PopupStackItem`（base_source_page）与
/// `NestedPopupEntry`（dictionary_page_mixin）两份近乎重复的类型）。
class DictionaryPopupEntry {
  DictionaryPopupEntry({
    required this.searchTerm,
    required this.selectionRect,
    this.result,
    this.visible = true,
    this.isWarmSlot = false,
    this.allLoaded = false,
  });

  String searchTerm;
  Rect selectionRect;
  DictionarySearchResult? result;

  /// 该层是否被绘制/可交互。常驻热槽在两次查词之间 `visible=false` 隐身，
  /// 但 WebView 仍挂载预热；一次查词把它翻为可见。
  bool visible;

  /// TODO-058：结果已就绪、但故意保持 `visible=false`，等其 WebView 真正把内容
  /// 渲染进 DOM（`popupRendered` → `onRendered`）后才翻可见——消除「冷加载 WebView
  /// 一翻可见就露白屏一瞬」。仅冷启动（新建 WebView）的嵌套/非热槽层需要：热槽
  /// WebView 已预热渲染就绪，立即可见无白屏。[revealRendered] 命中后清回 false。
  bool revealOnRender = false;

  /// 该层是否正在（增量/分页）搜索中。
  bool isSearching = false;

  /// 是否已无更多结果可加载（分页到底）。
  bool allLoaded;

  /// 仅常驻热槽为 true：其 WebView 全程挂载复用，关栈时隐藏而非销毁。
  final bool isWarmSlot;

  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}

/// 与 UI 无关的查词弹窗**栈原语**：书内（base_source_page）、视频、首页查词 tab、
/// 安卓独立查词窗共用同一份栈操作（消除「同一个 bug 两处各修一遍」的根因）。
///
/// **设计原则（保各表面现有行为）**：controller 只管「栈/热槽/复用/裁剪/填结果/
/// 显示/关栈」这些**机制**；「搜索期目标层是否立即可见」由宿主用 [visible] 参数自选——
/// 视频/首页/独立窗用 `visible:true`（搜索期即显示，空白由 DictionaryPopupLayer 的
/// 加载盖板兜住），书内用 `visible:false`（就绪才 [show]，搜索期另画轻量占位）。两条
/// 路径共用同一套原语，零行为变更。
class DictionaryPopupController extends ChangeNotifier {
  DictionaryPopupController({
    required this.lowMemory,
    this.onLookupStackDepthChanged,
  });

  /// TODO-607 P0-2：查词栈「可见深度」变化时的注入回调（书内 / 视频 / 首页 / 安卓独立
  /// 查词窗各宿主在创建时注入 `ErrorLogService.instance.markLookupStackDepth`）。
  /// 在此注入而非让 controller 直接调单例，是为了让 controller 保持纯逻辑可测
  /// （现有 `dictionary_popup_controller_test.dart` 在非 Flutter 环境跑，不能触发
  /// 文件 IO / path_provider）。回调同步执行，宿主据其同步写查词崩溃面包屑。
  ///
  /// 参数：当前**可见**查词栈深度（0=无可见弹窗→清面包屑，1=顶层，>=2=嵌套）+
  /// 栈顶可见层在查的词（可空）。
  final void Function(int depth, String? topTerm)? onLookupStackDepthChanged;

  /// 通知注入回调：当前可见栈深度 + 栈顶可见层的词。在所有改变 [_entries] 内容
  /// 或某层 [DictionaryPopupEntry.visible] 的栈操作尾部统一调用，使查词崩溃面包屑
  /// 始终反映「崩时第几层 / 在查什么词」。回调缺省（纯逻辑测试）时直接返回。
  void _notifyLookupStackDepth() {
    final callback = onLookupStackDepthChanged;
    if (callback == null) return;
    int depth = 0;
    String? topTerm;
    for (final DictionaryPopupEntry e in _entries) {
      if (!e.visible) continue;
      depth++;
      topTerm = e.searchTerm;
    }
    callback(depth, topTerm);
  }

  /// 低内存模式不保留常驻热槽（关栈即清空，释放 WebView）。可变：宿主在 appModel
  /// 已初始化的安全时机（seed 前）设入真实值，避免在 State.initState 里过早读
  /// prefsRepo（未初始化会抛）。
  bool lowMemory;

  /// TODO-1204：每次「查词开始」的注入回调（每个宿主在安全时机设入，解析本表面的书
  /// 身份后写 [FushiDatabase.addLookupCount]）。在 [beginTop] / [pushChild] 头部触发，
  /// **每次查词 +1**（顶层 / 嵌套 / 重复查各算一次，不去重；seed 热槽不算）。与
  /// [onLookupStackDepthChanged] 同理由用注入回调而非让 controller 直接碰 DB——保持
  /// controller 纯逻辑可测（纯逻辑测试缺省不设，为空则不触发）。
  void Function()? onLookupStarted;

  /// TODO-058 fail-safe：挂起层（[markPendingReveal]）等 `popupRendered` 才翻可见。
  /// 若 WebView 冷加载失败 / `renderPopup()` JS 抛异常 / `callHandler` 因 WebView
  /// 进程异常失败 → `popupRendered` 永不发，挂起层会**永久** `visible=false`（点查词
  /// 什么都不出，比白屏一瞬更糟）。该超时是兜底：到时仍未 [revealRendered] 就强制
  /// 翻可见（退回「最坏白屏一瞬」也好过永不显示）。取足够长，正常渲染远早于它，
  /// 不影响「就绪才显示」的正常路径。
  static const Duration kRevealFailsafeTimeout = Duration(milliseconds: 1800);

  /// 每个挂起层一个一次性兜底 Timer。[revealRendered]/[show]/隐藏/裁剪/清栈/[dispose]
  /// 任何使该层离开挂起态的路径都必须取消并移除其 Timer，避免在已销毁/已显示的
  /// 条目上回调或泄漏。
  final Map<DictionaryPopupEntry, Timer> _revealFailsafeTimers =
      <DictionaryPopupEntry, Timer>{};

  final List<DictionaryPopupEntry> _entries = <DictionaryPopupEntry>[];

  /// [_entries] 的常驻不可变 live 视图。此前每次访问 `List.unmodifiable(_entries)`
  /// 都整表拷贝一份——entries 在宿主 build 循环、`contains` 身份核对里高频调用，
  /// 每次查词/重建都白分配。[UnmodifiableListView] 包装内部列表：外部依旧不可变
  /// （写操作抛 UnsupportedError），读实时反映内部变更，零拷贝。
  late final List<DictionaryPopupEntry> _entriesView =
      UnmodifiableListView<DictionaryPopupEntry>(_entries);

  List<DictionaryPopupEntry> get entries => _entriesView;

  bool get hasVisiblePopup =>
      _entries.any((DictionaryPopupEntry e) => e.visible);

  /// 最顶层**可见**条目的下标，无可见层返回 -1（常驻隐藏热槽不算）。
  int get lastVisibleIndex {
    for (int i = _entries.length - 1; i >= 0; i--) {
      if (_entries[i].visible) return i;
    }
    return -1;
  }

  // ── 搜索期 UI（「搜索→就绪才显示」模式）───────────────────────────────
  // 弹窗目标搜索期隐藏，宿主据这两个字段在选中词位置画轻量加载占位卡，
  // 全程不显示空 WebView（与书内 base_source_page 同观感）。
  bool _searchingUi = false;
  bool get isSearchingUi => _searchingUi;
  Rect? _pendingRect;
  Rect? get pendingRect => _pendingRect;

  void beginSearchUi(Rect rect) {
    _searchingUi = true;
    _pendingRect = rect;
    notifyListeners();
  }

  void endSearchUi() {
    if (!_searchingUi && _pendingRect == null) return;
    _searchingUi = false;
    _pendingRect = null;
    notifyListeners();
  }

  /// 开页 seed 一个常驻隐藏热槽，使其 WebView 冷加载一次后全程复用。
  /// [seedResult] 让宿主放一个占位结果；缺省即 [kPopupSearchingPlaceholderResult]
  /// canonical 单例（与搜索期占位同一对象，seed→查词的 result 身份不变、不触发重推）。
  void seedWarmSlot({DictionarySearchResult? seedResult}) {
    if (lowMemory || _entries.isNotEmpty) return;
    _entries.add(DictionaryPopupEntry(
      searchTerm: '',
      selectionRect: Rect.zero,
      result: seedResult ?? kPopupSearchingPlaceholderResult,
      visible: false,
      isWarmSlot: true,
    ));
    notifyListeners();
    _notifyLookupStackDepth();
  }

  void _restoreWarmSeed(DictionaryPopupEntry e) {
    e
      ..searchTerm = ''
      ..selectionRect = Rect.zero
      ..result = kPopupSearchingPlaceholderResult
      ..visible = false
      ..revealOnRender = false
      ..isSearching = false
      ..allLoaded = false;
  }

  /// 顶层查词目标：能复用常驻热槽（首条且 isWarmSlot）就原地复用并丢弃子层；
  /// 否则按 [replaceStack] 决定是否清栈再压一条新目标。返回目标条目。
  /// [visible] 决定搜索期目标是否立即可见（见类注释）。
  DictionaryPopupEntry beginTop({
    required String term,
    required Rect rect,
    required bool reuseWarmSlot,
    required bool replaceStack,
    required bool visible,
    DictionarySearchResult? initialResult,
  }) {
    onLookupStarted?.call();
    final DictionaryPopupEntry e;
    if (reuseWarmSlot && _entries.isNotEmpty && _entries.first.isWarmSlot) {
      if (_entries.length > 1) {
        _entries.removeRange(1, _entries.length);
      }
      _cancelRevealTimer(_entries.first);
      e = _entries.first
        ..searchTerm = term
        ..selectionRect = rect
        ..result = initialResult
        ..allLoaded = false
        ..isSearching = true
        ..revealOnRender = false
        ..visible = visible;
    } else {
      if (replaceStack) _entries.clear();
      e = DictionaryPopupEntry(
        searchTerm: term,
        selectionRect: rect,
        result: initialResult,
        visible: visible,
      )..isSearching = true;
      _entries.add(e);
    }
    notifyListeners();
    _notifyLookupStackDepth();
    return e;
  }

  /// 嵌套查词目标：先把 [parentIndex] 之后的更深子层裁掉，再压入一条新目标。
  DictionaryPopupEntry pushChild({
    required String term,
    required Rect rect,
    required int parentIndex,
    required bool visible,
  }) {
    onLookupStarted?.call();
    truncateTo(parentIndex + 1);
    final DictionaryPopupEntry e = DictionaryPopupEntry(
      searchTerm: term,
      selectionRect: rect,
      visible: visible,
    )..isSearching = true;
    _entries.add(e);
    notifyListeners();
    _notifyLookupStackDepth();
    return e;
  }

  /// 裁到只剩前 [length] 层（用于丢弃更深的嵌套层）。
  void truncateTo(int length) {
    if (length < 0) length = 0;
    if (_entries.length > length) {
      _cancelRevealTimers(_entries.sublist(length));
      _entries.removeRange(length, _entries.length);
      notifyListeners();
      _notifyLookupStackDepth();
    }
  }

  /// 顶层新查词前的预清理：保留常驻隐藏热槽、丢弃其余（低内存则清空）。
  /// 对应 base_source_page 旧 `prunePopupStack(0)`。
  void pruneToWarmSlot() {
    if (_entries.isEmpty) return;
    final DictionaryPopupEntry first = _entries.first;
    if (first.isWarmSlot && !lowMemory) {
      _cancelRevealTimers(_entries);
      _restoreWarmSeed(first);
      _entries
        ..clear()
        ..add(first);
    } else {
      _cancelRevealTimers(_entries);
      _entries.clear();
    }
    notifyListeners();
    _notifyLookupStackDepth();
  }

  /// 清空整个栈（宿主重置/销毁用；不保留热槽）。
  void clear() {
    if (_entries.isEmpty) return;
    _cancelRevealTimers(_entries);
    _entries.clear();
    notifyListeners();
    _notifyLookupStackDepth();
  }

  /// 把结果填进 [e]（不改 visible），供「就绪才显示」与「延迟显示」两条路径。
  void fillResult(
    DictionaryPopupEntry e, {
    required DictionarySearchResult? result,
    required bool allLoaded,
  }) {
    e
      ..result = result
      ..allLoaded = allLoaded
      ..isSearching = false;
    notifyListeners();
  }

  /// 显示 [e]（搜索→就绪才显示路径在 [fillResult] 后调用）。
  void show(DictionaryPopupEntry e) {
    _cancelRevealTimer(e);
    e.visible = true;
    e.revealOnRender = false;
    notifyListeners();
    _notifyLookupStackDepth();
  }

  /// BUG-717 ②：把已显示的 [e] 重锚到 [rect] 并触发重定位（弹窗位置在 build 时由
  /// [DictionaryPopupEntry.selectionRect] 算出，改它 + [notifyListeners] 即重放）。
  ///
  /// 用于阅读器查词把「显示弹窗」与「正文高亮 eval」解耦后：弹窗先用原始选区 rect
  /// 立即显示（不再 await 打在繁忙大 reader WebView 上的高亮 eval），高亮 eval 回来
  /// 拿到精修后的词 bbox（多字去屈折时比选区宽）再用它重锚，保证弹窗不覆盖被查词
  /// （BUG-767）。[e] 已被新查词替换/关闭、或 rect 未变 → no-op（不重建、不抖动）。
  void reanchorEntry(DictionaryPopupEntry e, Rect rect) {
    if (!e.visible || !_entries.contains(e)) return;
    if (e.selectionRect == rect) return;
    e.selectionRect = rect;
    notifyListeners();
  }

  /// TODO-058：结果已就绪但**先不显示**——挂起到该层 WebView 渲染完成。
  /// 用于冷启动（新建 WebView）的嵌套/非热槽层：让其 WebView 在屏外预渲染，
  /// 待 [revealRendered] 命中（`onRendered` 信号）再翻可见，杜绝白屏一瞬。
  /// 热槽/有词条但 WebView 已预热的层不走此路（[show] 立即显示即可）。
  ///
  /// [onForcedReveal] 在**超时兜底**强制翻可见后回调（不在正常 [revealRendered]
  /// 路径调用——那条路有自己的后续）。宿主用它做翻可见后的重建：mixin 路径
  /// （视频/首页不监听本 controller）传 `setState(() {})`，阅读器路径（监听
  /// controller，[notifyListeners] 已触发重建）可传 null。[timeout] 默认
  /// [kRevealFailsafeTimeout]。
  void markPendingReveal(
    DictionaryPopupEntry e, {
    VoidCallback? onForcedReveal,
    Duration timeout = kRevealFailsafeTimeout,
  }) {
    e.visible = false;
    e.revealOnRender = true;
    _cancelRevealTimer(e);
    _revealFailsafeTimers[e] = Timer(timeout, () {
      // 到时仍挂起（没收到 popupRendered，也没被显示/裁掉）→ 强制翻可见。
      _revealFailsafeTimers.remove(e);
      if (!e.revealOnRender || !_entries.contains(e)) return;
      e.visible = true;
      e.revealOnRender = false;
      notifyListeners();
      _notifyLookupStackDepth();
      onForcedReveal?.call();
    });
    notifyListeners();
    _notifyLookupStackDepth();
  }

  /// 取消并移除 [e] 的兜底 Timer（离开挂起态的所有路径都要调，防回调/泄漏）。
  void _cancelRevealTimer(DictionaryPopupEntry e) {
    _revealFailsafeTimers.remove(e)?.cancel();
  }

  /// 取消并移除一批被裁/被清条目的兜底 Timer。
  void _cancelRevealTimers(Iterable<DictionaryPopupEntry> removed) {
    for (final DictionaryPopupEntry e in removed) {
      _revealFailsafeTimers.remove(e)?.cancel();
    }
  }

  /// TODO-058：某层 WebView 渲染完成（`popupRendered` → `onRendered`）时调用。
  /// 仅当该层处于挂起状态（[markPendingReveal] 标记的 [revealOnRender]）才翻为可见，
  /// 并清掉标记；非挂起层（热槽再次渲染、load-more 等）不受影响。返回是否真的翻了可见，
  /// 让宿主据此决定是否继续后续（如把光标交给刚显示的层）。
  bool revealRendered(DictionaryPopupEntry e) {
    if (!e.revealOnRender) return false;
    _cancelRevealTimer(e);
    e.visible = true;
    e.revealOnRender = false;
    notifyListeners();
    _notifyLookupStackDepth();
    return true;
  }

  /// 关闭第 [index] 层及其之上。index==0：保留并隐藏常驻热槽（低内存则清空）；
  /// index>0：裁掉该层及之上，保留下层。
  void dismissAt(int index) {
    if (index < 0 || index >= _entries.length) return;
    if (index == 0) {
      final DictionaryPopupEntry first = _entries.first;
      if (first.isWarmSlot && !lowMemory) {
        _cancelRevealTimers(_entries);
        _restoreWarmSeed(first);
        _entries
          ..clear()
          ..add(first);
      } else {
        _cancelRevealTimers(_entries);
        _entries.clear();
      }
    } else {
      _cancelRevealTimers(_entries.sublist(index));
      _entries.removeRange(index, _entries.length);
    }
    notifyListeners();
    _notifyLookupStackDepth();
  }

  @override
  void dispose() {
    // 防泄漏：销毁时取消所有挂起的兜底 Timer。
    for (final Timer t in _revealFailsafeTimers.values) {
      t.cancel();
    }
    _revealFailsafeTimers.clear();
    super.dispose();
  }
}
