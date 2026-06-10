import 'package:flutter/widgets.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

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
  DictionaryPopupController({required this.lowMemory});

  /// 低内存模式不保留常驻热槽（关栈即清空，释放 WebView）。可变：宿主在 appModel
  /// 已初始化的安全时机（seed 前）设入真实值，避免在 State.initState 里过早读
  /// prefsRepo（未初始化会抛）。
  bool lowMemory;

  final List<DictionaryPopupEntry> _entries = <DictionaryPopupEntry>[];
  List<DictionaryPopupEntry> get entries => List.unmodifiable(_entries);

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
  /// [seedResult] 让宿主放一个占位结果（书内放 kPopupSearchingPlaceholderResult）。
  void seedWarmSlot({DictionarySearchResult? seedResult}) {
    if (lowMemory || _entries.isNotEmpty) return;
    _entries.add(DictionaryPopupEntry(
      searchTerm: '',
      selectionRect: Rect.zero,
      result: seedResult,
      visible: false,
      isWarmSlot: true,
    ));
    notifyListeners();
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
    final DictionaryPopupEntry e;
    if (reuseWarmSlot && _entries.isNotEmpty && _entries.first.isWarmSlot) {
      if (_entries.length > 1) {
        _entries.removeRange(1, _entries.length);
      }
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
    return e;
  }

  /// 嵌套查词目标：先把 [parentIndex] 之后的更深子层裁掉，再压入一条新目标。
  DictionaryPopupEntry pushChild({
    required String term,
    required Rect rect,
    required int parentIndex,
    required bool visible,
  }) {
    truncateTo(parentIndex + 1);
    final DictionaryPopupEntry e = DictionaryPopupEntry(
      searchTerm: term,
      selectionRect: rect,
      visible: visible,
    )..isSearching = true;
    _entries.add(e);
    notifyListeners();
    return e;
  }

  /// 裁到只剩前 [length] 层（用于丢弃更深的嵌套层）。
  void truncateTo(int length) {
    if (length < 0) length = 0;
    if (_entries.length > length) {
      _entries.removeRange(length, _entries.length);
      notifyListeners();
    }
  }

  /// 顶层新查词前的预清理：保留常驻隐藏热槽、丢弃其余（低内存则清空）。
  /// 对应 base_source_page 旧 `prunePopupStack(0)`。
  void pruneToWarmSlot() {
    if (_entries.isEmpty) return;
    final DictionaryPopupEntry first = _entries.first;
    if (first.isWarmSlot && !lowMemory) {
      first
        ..visible = false
        ..revealOnRender = false
        ..selectionRect = Rect.zero;
      _entries
        ..clear()
        ..add(first);
    } else {
      _entries.clear();
    }
    notifyListeners();
  }

  /// 清空整个栈（宿主重置/销毁用；不保留热槽）。
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
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
    e.visible = true;
    e.revealOnRender = false;
    notifyListeners();
  }

  /// TODO-058：结果已就绪但**先不显示**——挂起到该层 WebView 渲染完成。
  /// 用于冷启动（新建 WebView）的嵌套/非热槽层：让其 WebView 在屏外预渲染，
  /// 待 [revealRendered] 命中（`onRendered` 信号）再翻可见，杜绝白屏一瞬。
  /// 热槽/有词条但 WebView 已预热的层不走此路（[show] 立即显示即可）。
  void markPendingReveal(DictionaryPopupEntry e) {
    e.visible = false;
    e.revealOnRender = true;
    notifyListeners();
  }

  /// TODO-058：某层 WebView 渲染完成（`popupRendered` → `onRendered`）时调用。
  /// 仅当该层处于挂起状态（[markPendingReveal] 标记的 [revealOnRender]）才翻为可见，
  /// 并清掉标记；非挂起层（热槽再次渲染、load-more 等）不受影响。返回是否真的翻了可见，
  /// 让宿主据此决定是否继续后续（如把光标交给刚显示的层）。
  bool revealRendered(DictionaryPopupEntry e) {
    if (!e.revealOnRender) return false;
    e.visible = true;
    e.revealOnRender = false;
    notifyListeners();
    return true;
  }

  /// 关闭第 [index] 层及其之上。index==0：保留并隐藏常驻热槽（低内存则清空）；
  /// index>0：裁掉该层及之上，保留下层。
  void dismissAt(int index) {
    if (index < 0 || index >= _entries.length) return;
    if (index == 0) {
      final DictionaryPopupEntry first = _entries.first;
      if (first.isWarmSlot && !lowMemory) {
        first
          ..visible = false
          ..revealOnRender = false
          ..selectionRect = Rect.zero
          ..isSearching = false;
        _entries
          ..clear()
          ..add(first);
      } else {
        _entries.clear();
      }
    } else {
      _entries.removeRange(index, _entries.length);
    }
    notifyListeners();
  }
}
