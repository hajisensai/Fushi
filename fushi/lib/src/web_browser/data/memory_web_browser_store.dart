import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';

/// [WebBrowserStore] 的纯内存实现：测试与 widget 预览用，语义与 Drift 版一致——
/// 同 url 合并访问、删文件夹级联、最近关闭最多 25 条且最新在前、每次写入后
/// `notifyListeners`。
///
/// [clock] 可注入（测试固定时间）；缺省 `DateTime.now`。
class MemoryWebBrowserStore extends ChangeNotifier implements WebBrowserStore {
  MemoryWebBrowserStore({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// 最近关闭保留上限（与 Drift 版同值）。
  static const int closedTabsLimit = 25;

  final DateTime Function() _clock;

  final List<WebBrowserHistoryEntry> _history = <WebBrowserHistoryEntry>[];
  final Map<int, WebBrowserBookmark> _bookmarks = <int, WebBrowserBookmark>{};
  final List<WebBrowserClosedTab> _closedTabs = <WebBrowserClosedTab>[];
  final Map<int, WebBrowserDownload> _downloads = <int, WebBrowserDownload>{};
  WebBrowserSession? _session;

  int _nextHistoryId = 1;
  int _nextBookmarkId = 1;
  int _nextDownloadId = 1;

  // ── 历史 ──────────────────────────────────────────────────────────

  @override
  Future<void> recordVisit({required Uri url, required String title}) async {
    final DateTime now = _clock();
    final int index = _history.indexWhere(
      (WebBrowserHistoryEntry e) => e.url.toString() == url.toString(),
    );
    if (index >= 0) {
      final WebBrowserHistoryEntry old = _history[index];
      _history[index] = WebBrowserHistoryEntry(
        id: old.id,
        url: url,
        title: title.trim().isEmpty ? old.title : title,
        lastVisitedAt: now,
        visitCount: old.visitCount + 1,
      );
    } else {
      _history.add(
        WebBrowserHistoryEntry(
          id: _nextHistoryId++,
          url: url,
          title: title,
          lastVisitedAt: now,
          visitCount: 1,
        ),
      );
    }
    notifyListeners();
  }

  /// 测试播种：按给定时刻 / 次数直接写一条历史（同 url 覆盖）。
  @visibleForTesting
  void seedHistory({
    required Uri url,
    required String title,
    required DateTime lastVisitedAt,
    int visitCount = 1,
  }) {
    _history.removeWhere(
      (WebBrowserHistoryEntry e) => e.url.toString() == url.toString(),
    );
    _history.add(
      WebBrowserHistoryEntry(
        id: _nextHistoryId++,
        url: url,
        title: title,
        lastVisitedAt: lastVisitedAt,
        visitCount: visitCount,
      ),
    );
    notifyListeners();
  }

  @override
  Future<List<WebBrowserHistoryEntry>> history({
    String query = '',
    int limit = 200,
    int offset = 0,
  }) async {
    final List<WebBrowserHistoryEntry> sorted =
        <WebBrowserHistoryEntry>[..._history]
          ..sort((WebBrowserHistoryEntry a, WebBrowserHistoryEntry b) {
            final int byTime = b.lastVisitedAt.compareTo(a.lastVisitedAt);
            return byTime != 0 ? byTime : b.id.compareTo(a.id);
          });
    final List<WebBrowserHistoryEntry> filtered = filterByMediaSearch(
      sorted,
      query,
      (WebBrowserHistoryEntry e) => <String>[e.title, e.url.toString()],
    );
    return filtered.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<void> deleteHistory(Iterable<int> ids) async {
    final Set<int> drop = ids.toSet();
    _history.removeWhere((WebBrowserHistoryEntry e) => drop.contains(e.id));
    notifyListeners();
  }

  @override
  Future<void> clearHistory({DateTime? since}) async {
    if (since == null) {
      _history.clear();
    } else {
      _history.removeWhere(
        (WebBrowserHistoryEntry e) => !e.lastVisitedAt.isBefore(since),
      );
    }
    notifyListeners();
  }

  // ── 书签 ──────────────────────────────────────────────────────────

  List<WebBrowserBookmark> _children(int? parentId) =>
      _bookmarks.values
          .where((WebBrowserBookmark b) => b.parentId == parentId)
          .toList()
        ..sort((WebBrowserBookmark a, WebBrowserBookmark b) {
          final int byPos = a.position.compareTo(b.position);
          return byPos != 0 ? byPos : a.id.compareTo(b.id);
        });

  int _nextPosition(int? parentId) {
    final List<WebBrowserBookmark> siblings = _children(parentId);
    return siblings.isEmpty ? 0 : siblings.last.position + 1;
  }

  @override
  Future<List<WebBrowserBookmark>> bookmarks({int? parentId}) async =>
      List<WebBrowserBookmark>.unmodifiable(_children(parentId));

  @override
  Future<List<WebBrowserBookmark>> allBookmarks() async =>
      List<WebBrowserBookmark>.unmodifiable(
        _bookmarks.values.where((WebBrowserBookmark b) => !b.isFolder).toList()
          ..sort(
            (WebBrowserBookmark a, WebBrowserBookmark b) =>
                a.id.compareTo(b.id),
          ),
      );

  @override
  Future<WebBrowserBookmark?> bookmarkForUrl(Uri url) async {
    final String key = url.toString();
    for (final WebBrowserBookmark b in _bookmarks.values) {
      if (b.url?.toString() == key) return b;
    }
    return null;
  }

  @override
  Future<int> addBookmark({
    required String title,
    required Uri url,
    int? parentId,
  }) async {
    final int id = _nextBookmarkId++;
    _bookmarks[id] = WebBrowserBookmark(
      id: id,
      title: title,
      url: url,
      parentId: parentId,
      position: _nextPosition(parentId),
      createdAt: _clock(),
    );
    notifyListeners();
    return id;
  }

  @override
  Future<int> addFolder({required String title, int? parentId}) async {
    final int id = _nextBookmarkId++;
    _bookmarks[id] = WebBrowserBookmark(
      id: id,
      title: title,
      url: null,
      parentId: parentId,
      position: _nextPosition(parentId),
      createdAt: _clock(),
    );
    notifyListeners();
    return id;
  }

  /// [parentId] 只有显式传入才改；要移到根目录用 [moveToRoot]。Drift 版同口径：
  /// 契约里 `int? parentId` 为 null 表示「不改」。
  @override
  Future<void> updateBookmark(
    int id, {
    String? title,
    Uri? url,
    int? parentId,
    int? position,
    bool moveToRoot = false,
  }) async {
    final WebBrowserBookmark? old = _bookmarks[id];
    if (old == null) return;
    final int? newParent = moveToRoot ? null : (parentId ?? old.parentId);
    if (newParent != null && _isSelfOrDescendant(newParent, id)) return;
    final bool parentChanged = newParent != old.parentId;
    _bookmarks[id] = WebBrowserBookmark(
      id: id,
      title: title ?? old.title,
      url: old.isFolder ? null : (url ?? old.url),
      parentId: newParent,
      position:
          position ?? (parentChanged ? _nextPosition(newParent) : old.position),
      createdAt: old.createdAt,
    );
    if (position != null) _renumber(newParent, pinned: id, at: position);
    notifyListeners();
  }

  /// [candidate] 是否就是 [id] 自己或其子孙（防止把文件夹移进自己）。
  bool _isSelfOrDescendant(int candidate, int id) {
    int? cursor = candidate;
    while (cursor != null) {
      if (cursor == id) return true;
      cursor = _bookmarks[cursor]?.parentId;
    }
    return false;
  }

  /// 把 [parentId] 下的兄弟重新编号成 0..n-1，[pinned] 落在 [at]。
  void _renumber(int? parentId, {required int pinned, required int at}) {
    final List<WebBrowserBookmark> others = _children(
      parentId,
    ).where((WebBrowserBookmark b) => b.id != pinned).toList();
    final WebBrowserBookmark? self = _bookmarks[pinned];
    if (self == null) return;
    others.insert(at.clamp(0, others.length), self);
    for (int i = 0; i < others.length; i++) {
      final WebBrowserBookmark b = others[i];
      _bookmarks[b.id] = WebBrowserBookmark(
        id: b.id,
        title: b.title,
        url: b.url,
        parentId: b.parentId,
        position: i,
        createdAt: b.createdAt,
      );
    }
  }

  @override
  Future<void> deleteBookmark(int id) async {
    final List<int> stack = <int>[id];
    while (stack.isNotEmpty) {
      final int current = stack.removeLast();
      if (_bookmarks.remove(current) == null) continue;
      stack.addAll(
        _bookmarks.values
            .where((WebBrowserBookmark b) => b.parentId == current)
            .map((WebBrowserBookmark b) => b.id),
      );
    }
    notifyListeners();
  }

  // ── 标签页会话 ─────────────────────────────────────────────────────

  @override
  Future<void> saveSession(WebBrowserSession session) async {
    _session = WebBrowserSession(
      tabs: List<WebBrowserSessionTab>.unmodifiable(session.tabs),
      activeTabId: session.activeTabId,
    );
    notifyListeners();
  }

  @override
  Future<WebBrowserSession?> loadSession() async => _session;

  @override
  Future<void> pushClosedTab(WebBrowserClosedTab tab) async {
    _closedTabs.insert(0, tab);
    if (_closedTabs.length > closedTabsLimit) {
      _closedTabs.removeRange(closedTabsLimit, _closedTabs.length);
    }
    notifyListeners();
  }

  @override
  Future<WebBrowserClosedTab?> popClosedTab() async {
    if (_closedTabs.isEmpty) return null;
    final WebBrowserClosedTab tab = _closedTabs.removeAt(0);
    notifyListeners();
    return tab;
  }

  @override
  Future<List<WebBrowserClosedTab>> closedTabs() async =>
      List<WebBrowserClosedTab>.unmodifiable(_closedTabs);

  // ── 下载记录 ─────────────────────────────────────────────────────

  @override
  Future<int> addDownload(WebBrowserDownload download) async {
    final int id = _nextDownloadId++;
    _downloads[id] = WebBrowserDownload(
      id: id,
      url: download.url,
      fileName: download.fileName,
      startedAt: download.startedAt,
      mimeType: download.mimeType,
      totalBytes: download.totalBytes,
      receivedBytes: download.receivedBytes,
      state: download.state,
      savedPath: download.savedPath,
    );
    notifyListeners();
    return id;
  }

  @override
  Future<void> updateDownload(
    int id, {
    int? receivedBytes,
    int? totalBytes,
    WebBrowserDownloadState? state,
    String? savedPath,
  }) async {
    final WebBrowserDownload? old = _downloads[id];
    if (old == null) return;
    _downloads[id] = WebBrowserDownload(
      id: id,
      url: old.url,
      fileName: old.fileName,
      startedAt: old.startedAt,
      mimeType: old.mimeType,
      totalBytes: totalBytes ?? old.totalBytes,
      receivedBytes: receivedBytes ?? old.receivedBytes,
      state: state ?? old.state,
      savedPath: savedPath ?? old.savedPath,
    );
    notifyListeners();
  }

  /// 最新开始的在前。
  @override
  Future<List<WebBrowserDownload>> downloads() async =>
      List<WebBrowserDownload>.unmodifiable(
        _downloads.values.toList()
          ..sort((WebBrowserDownload a, WebBrowserDownload b) {
            final int byTime = b.startedAt.compareTo(a.startedAt);
            return byTime != 0 ? byTime : b.id.compareTo(a.id);
          }),
      );

  @override
  Future<void> deleteDownload(int id) async {
    _downloads.remove(id);
    notifyListeners();
  }
}
