import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 同时活着（建着 WebView 平台视图）的标签页上限。超出时回收最久没看过的，
/// 只留地址 / 标题，切回来时按地址重载。
const int kWebBrowserMaxLiveTabs = 4;

/// 会话写盘的防抖：标签页地址 / 标题连续变化（重定向、SPA 改标题）只写最后一次。
const Duration kWebBrowserSessionSaveDebounce = Duration(milliseconds: 800);

/// 浏览页的标签列表：开 / 关 / 切换 / 重排、关闭回到 opener、最近关闭与重开、
/// 会话恢复（防抖写盘、只给前台页建 WebView）、活 WebView 数量上限。
///
/// 纯逻辑，不碰 widget：浏览页（壳）监听它重建，标签页 WebView 只读
/// [isLive] 决定建不建平台视图。功能插件的标签生命周期回调（前台切换 / 关闭）
/// 也只在这里发，壳与标签页不各自再发一份。
class WebBrowserTabsController extends ChangeNotifier {
  WebBrowserTabsController({
    required WebBrowserStore store,
    List<WebBrowserFeature> features = const <WebBrowserFeature>[],
    int maxLiveTabs = kWebBrowserMaxLiveTabs,
    Duration saveDebounce = kWebBrowserSessionSaveDebounce,
    DateTime Function()? clock,
  }) : _store = store,
       _features = features,
       _maxLiveTabs = maxLiveTabs < 1 ? 1 : maxLiveTabs,
       _saveDebounce = saveDebounce,
       _clock = clock ?? DateTime.now;

  final WebBrowserStore _store;
  final List<WebBrowserFeature> _features;
  final int _maxLiveTabs;
  final Duration _saveDebounce;
  final DateTime Function() _clock;

  final List<WebBrowserTab> _tabs = <WebBrowserTab>[];
  WebBrowserTab? _active;

  /// 最近使用在前；只含活着的标签页 id。
  final List<String> _live = <String>[];
  int _nextId = 0;
  Timer? _saveTimer;
  bool _disposed = false;

  /// 会话持久化开关（设置「恢复上次的标签页」关掉时为 false：不写也不读）。
  bool persistSession = true;

  List<WebBrowserTab> get tabs => List<WebBrowserTab>.unmodifiable(_tabs);
  int get length => _tabs.length;
  bool get isEmpty => _tabs.isEmpty;
  WebBrowserTab? get activeTab => _active;
  int get activeIndex => _active == null ? -1 : _tabs.indexOf(_active!);
  int get incognitoCount =>
      _tabs.where((WebBrowserTab t) => t.incognito).length;

  bool isActive(WebBrowserTab tab) => identical(tab, _active);

  /// 该标签页此刻是否应当建着 WebView。没有地址的新标签页不建（显示起始页）。
  bool isLive(WebBrowserTab tab) => tab.url != null && _live.contains(tab.id);

  WebBrowserTab? tabById(String id) {
    for (final WebBrowserTab t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  String _newId() =>
      't${_clock().microsecondsSinceEpoch.toRadixString(36)}_${_nextId++}';

  // ── 开 / 关 / 切换 ───────────────────────────────────────────────────

  /// 开新标签页。[index] 为 null 时：有 opener 就插在 opener 之后那串子页末尾，
  /// 否则追加到末尾。
  WebBrowserTab openTab(
    Uri? url, {
    String? openerId,
    int? windowId,
    bool incognito = false,
    bool activate = true,
    int? index,
    String title = '',
    String? id,
  }) {
    final WebBrowserTab tab = WebBrowserTab(
      id: id ?? _newId(),
      url: url,
      incognito: incognito,
      openerId: openerId,
      windowId: windowId,
      title: title,
    );
    _insert(tab, index ?? _defaultInsertIndex(openerId));
    if (activate || _active == null) {
      _setActive(tab);
    } else {
      // 后台打开的也要下一帧就建 WebView：`window.open` 的新窗口靠这个完成交接
      // （windowId 只能在 onCreateWindow 回调期间被新视图接走）。只有会话恢复出来
      // 的旧标签页懒加载。
      _touchLive(tab);
      final WebBrowserTab? active = _active;
      if (active != null) _touchLive(active);
    }
    _changed();
    return tab;
  }

  int _defaultInsertIndex(String? openerId) {
    if (openerId == null) return _tabs.length;
    final int opener = _tabs.indexWhere((WebBrowserTab t) => t.id == openerId);
    if (opener < 0) return _tabs.length;
    int i = opener + 1;
    while (i < _tabs.length && _tabs[i].openerId == openerId) {
      i++;
    }
    return i;
  }

  void _insert(WebBrowserTab tab, int index) {
    _tabs.insert(index.clamp(0, _tabs.length), tab);
    tab.addListener(_onTabChanged);
  }

  /// 关闭标签页：非无痕且有地址的进最近关闭栈；关的是前台页时回到它的 opener
  /// （还开着的话），否则右边的邻居，再否则左边的。
  void closeTab(WebBrowserTab tab) {
    final int index = _tabs.indexOf(tab);
    if (index < 0) return;
    final Uri? url = tab.url;
    if (!tab.incognito && url != null) {
      unawaited(
        _store.pushClosedTab(
          WebBrowserClosedTab(
            url: url,
            title: tab.title,
            closedAt: _clock(),
            index: index,
          ),
        ),
      );
    }
    _remove(tab);
    if (identical(tab, _active)) {
      WebBrowserTab? next;
      final String? opener = tab.openerId;
      if (opener != null) next = tabById(opener);
      if (next == null && _tabs.isNotEmpty) {
        next = _tabs[index < _tabs.length ? index : _tabs.length - 1];
      }
      _active = null;
      if (next != null) _setActive(next);
    }
    _changed();
  }

  void _remove(WebBrowserTab tab) {
    _tabs.remove(tab);
    _live.remove(tab.id);
    tab.removeListener(_onTabChanged);
    // 前台页被关：先报「不再是前台」，再报关闭（统计计时等按 active 收尾）。
    final bool wasActive = identical(tab, _active);
    for (final WebBrowserFeature f in _features) {
      if (wasActive) {
        _notifyFeature(f, () => f.onTabActiveChanged(tab, active: false));
      }
      _notifyFeature(f, () => f.onTabClosed(tab));
    }
  }

  /// 单个插件抛异常不影响其它插件与标签页状态。
  void _notifyFeature(WebBrowserFeature feature, void Function() body) {
    try {
      body();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserTabsController.${feature.id}',
        error,
        stack,
      );
    }
  }

  /// 关掉 [keep] 以外的全部标签页。
  void closeOtherTabs(WebBrowserTab keep) {
    for (final WebBrowserTab t in List<WebBrowserTab>.of(_tabs)) {
      if (!identical(t, keep)) closeTab(t);
    }
    activate(keep);
  }

  /// 重新打开最近关闭的标签页，尽量放回原位。栈空返回 null。
  Future<WebBrowserTab?> reopenClosedTab() async {
    final WebBrowserClosedTab? closed = await _store.popClosedTab();
    if (closed == null || _disposed) return null;
    return openTab(closed.url, title: closed.title, index: closed.index);
  }

  void activate(WebBrowserTab tab) {
    if (!_tabs.contains(tab) || identical(tab, _active)) return;
    _setActive(tab);
    _changed();
  }

  /// [delta] = +1 下一个 / -1 上一个，首尾循环。
  void activateRelative(int delta) {
    if (_tabs.length < 2) return;
    final int i = activeIndex < 0 ? 0 : activeIndex;
    activate(_tabs[(i + delta) % _tabs.length]);
  }

  void _setActive(WebBrowserTab tab) {
    final WebBrowserTab? previous = _active;
    _active = tab;
    _touchLive(tab);
    if (previous != null && _tabs.contains(previous)) {
      for (final WebBrowserFeature f in _features) {
        _notifyFeature(f, () => f.onTabActiveChanged(previous, active: false));
      }
    }
    for (final WebBrowserFeature f in _features) {
      _notifyFeature(f, () => f.onTabActiveChanged(tab, active: true));
    }
  }

  /// 把 [tab] 记成最近使用；超过上限时回收最久没用的（前台页永不回收）。
  void _touchLive(WebBrowserTab tab) {
    _live
      ..remove(tab.id)
      ..insert(0, tab.id);
    while (_live.length > _maxLiveTabs) {
      final String evicted = _live.removeLast();
      final WebBrowserTab? t = tabById(evicted);
      // 回收：只留地址 / 标题，WebView 拆掉时标签页自己摘控制器。
      if (t != null && identical(t, _active)) {
        _live.insert(0, evicted);
        break;
      }
    }
  }

  /// 拖动排序（[newIndex] 是移除旧位置之前的目标下标，与 ReorderableList 同口径）。
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _tabs.length) return;
    int target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, _tabs.length - 1);
    if (target == oldIndex) return;
    final WebBrowserTab tab = _tabs.removeAt(oldIndex);
    _tabs.insert(target, tab);
    _changed();
  }

  // ── 会话 ───────────────────────────────────────────────────────────

  /// 读上次的会话并建标签页（不触发 WebView：只有前台页会被 [isLive] 放行）。
  /// 恢复的标签页排在已有标签页之前（已有的是这次打开浏览页带进来的地址），
  /// 与已有标签页同地址的不重复恢复。已有前台页时前台不变。返回恢复了几个。
  Future<int> restoreSession() async {
    if (!persistSession) return 0;
    final WebBrowserSession? session = await _store.loadSession();
    if (session == null || session.tabs.isEmpty || _disposed) return 0;
    final Set<String> open = <String>{
      for (final WebBrowserTab t in _tabs)
        if (t.url != null) t.url.toString(),
    };
    WebBrowserTab? active;
    int restored = 0;
    for (final WebBrowserSessionTab s in session.tabs) {
      if (tabById(s.id) != null || open.contains(s.url.toString())) continue;
      final WebBrowserTab tab = WebBrowserTab(
        id: s.id,
        url: s.url,
        title: s.title,
      );
      _insert(tab, restored++);
      if (s.id == session.activeTabId) active = tab;
    }
    if (restored == 0) return 0;
    active ??= _tabs.first;
    if (_active == null) _setActive(active);
    _changed();
    return restored;
  }

  /// 当前应当写盘的会话（非无痕、有地址的标签页，按顺序）。
  WebBrowserSession snapshotSession() {
    final List<WebBrowserSessionTab> tabs = <WebBrowserSessionTab>[
      for (final WebBrowserTab t in _tabs)
        if (!t.incognito && t.url != null)
          WebBrowserSessionTab(id: t.id, url: t.url!, title: t.title),
    ];
    final WebBrowserTab? active = _active;
    return WebBrowserSession(
      tabs: tabs,
      activeTabId: active == null || active.incognito ? null : active.id,
    );
  }

  void _scheduleSave() {
    if (!persistSession || _disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(flushSession()));
  }

  /// 立即写盘（页面退出 / 进后台时调）。
  Future<void> flushSession() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!persistSession) return;
    await _store.saveSession(snapshotSession());
  }

  void _onTabChanged() => _scheduleSave();

  void _changed() {
    if (_disposed) return;
    _scheduleSave();
    notifyListeners();
  }

  @override
  void dispose() {
    final bool pending = _saveTimer?.isActive ?? false;
    _saveTimer?.cancel();
    if (pending && persistSession) {
      unawaited(_store.saveSession(snapshotSession()));
    }
    _disposed = true;
    for (final WebBrowserTab t in _tabs) {
      t.removeListener(_onTabChanged);
    }
    super.dispose();
  }
}
