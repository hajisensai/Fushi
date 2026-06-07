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

  /// 该层是否正在（增量/分页）搜索中，供 load-more 态。
  bool isSearching = false;

  /// 是否已无更多结果可加载（分页到底）。
  bool allLoaded;

  /// 仅常驻热槽为 true：其 WebView 全程挂载复用，关栈时隐藏而非销毁。
  final bool isWarmSlot;

  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}

/// 与 UI 无关的查词弹窗栈控制器：书内（base_source_page）、视频、首页查词 tab、
/// 安卓独立查词窗共用同一份栈逻辑（消除「同一个 bug 两处各修一遍」的根因）。
///
/// 时序统一为「**搜索 → 结果就绪才把浮层设为可见**」：搜索期只暴露 [isSearching] +
/// [pendingRect] 供宿主画轻量加载占位，**从不显示空 WebView**（视频原先「先显示空槽
/// 再搜索」是白屏根因）。
class DictionaryPopupController extends ChangeNotifier {
  DictionaryPopupController({required this.lowMemory});

  /// 低内存模式不保留常驻热槽（关栈即清空，释放 WebView）。
  final bool lowMemory;

  final List<DictionaryPopupEntry> _entries = <DictionaryPopupEntry>[];
  List<DictionaryPopupEntry> get entries => List.unmodifiable(_entries);

  bool _isSearching = false;
  bool get isSearching => _isSearching;

  Rect? _pendingRect;
  Rect? get pendingRect => _pendingRect;

  /// 当前这次搜索要落入的目标条目（顶层=复用热槽/首条，嵌套=新压入的末条）。
  DictionaryPopupEntry? _searchTarget;

  bool get hasVisiblePopup =>
      _entries.any((DictionaryPopupEntry e) => e.visible);

  /// 开页 seed 一个常驻隐藏热槽，使其 WebView 冷加载一次后全程复用。
  void seedWarmSlot() {
    if (lowMemory || _entries.isNotEmpty) return;
    _entries.add(DictionaryPopupEntry(
      searchTerm: '',
      selectionRect: Rect.zero,
      visible: false,
      isWarmSlot: true,
    ));
    notifyListeners();
  }

  /// 顶层查词开始：丢弃所有子层、复用首条（热槽）作为目标并标记搜索中。
  /// 目标条目此刻**仍隐藏**，待 [revealResult] 才显示——搜索期靠 [isSearching] +
  /// [pendingRect] 画占位。
  void beginSearch(Rect selectionRect, String term) {
    _isSearching = true;
    _pendingRect = selectionRect;
    if (_entries.isNotEmpty) {
      if (_entries.length > 1) {
        _entries.removeRange(1, _entries.length);
      }
      final DictionaryPopupEntry e = _entries.first
        ..searchTerm = term
        ..selectionRect = selectionRect
        ..isSearching = true;
      _searchTarget = e;
    } else {
      final DictionaryPopupEntry e = DictionaryPopupEntry(
        searchTerm: term,
        selectionRect: selectionRect,
        visible: false,
      )..isSearching = true;
      _entries.add(e);
      _searchTarget = e;
    }
    notifyListeners();
  }

  /// 嵌套查词（在已显示的浮层里点词/链接）：压入一个新的隐藏目标条目。
  void pushChild(Rect selectionRect, String term) {
    _isSearching = true;
    _pendingRect = selectionRect;
    final DictionaryPopupEntry e = DictionaryPopupEntry(
      searchTerm: term,
      selectionRect: selectionRect,
      visible: false,
    )..isSearching = true;
    _entries.add(e);
    _searchTarget = e;
    notifyListeners();
  }

  /// 结果就绪：把结果填入当前搜索目标条目并设为可见（顶层/嵌套通用）。
  void revealResult({
    required DictionarySearchResult? result,
    required bool allLoaded,
  }) {
    _isSearching = false;
    _pendingRect = null;
    DictionaryPopupEntry? e = _searchTarget;
    e ??= _entries.isNotEmpty ? _entries.last : null;
    if (e == null) {
      e = DictionaryPopupEntry(searchTerm: '', selectionRect: Rect.zero);
      _entries.add(e);
    }
    e
      ..result = result
      ..allLoaded = allLoaded
      ..visible = true
      ..isSearching = false;
    _searchTarget = null;
    notifyListeners();
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
    _isSearching = false;
    _pendingRect = null;
    _searchTarget = null;
    notifyListeners();
  }
}
