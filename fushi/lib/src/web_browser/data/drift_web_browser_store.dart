import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery, Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';

/// [WebBrowserStore] 的 Drift 实现（表在 `fushi_core` 的 `web_browser_*`，schema v128）。
///
/// 历史与书签的删除会写 `sync_deletion_tombstones`（`webhistory` / `webbookmark`），
/// 经聚合快照跨端传播；会话 / 最近关闭 / 下载是设备本地。
///
/// 通知：本 store 的每次写入完成后恰好 [notifyListeners] 一次（与
/// `MemoryWebBrowserStore` 同一契约）；另外订阅历史 / 书签两张表的 drift 更新流，
/// 让同步（互联 / 云 / 备份合并）落地的改动也能通知到——本 store 自己写入期间产生的
/// 更新事件经 [_ownWrites] 计数识别并跳过，不重复通知。
class DriftWebBrowserStore extends ChangeNotifier implements WebBrowserStore {
  DriftWebBrowserStore(
    this._db, {
    DateTime Function()? clock,
    String Function()? newUid,
  }) : _clock = clock ?? DateTime.now,
       _newUid = newUid ?? _randomUid {
    _externalUpdates = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              _db.webBrowserHistory,
              _db.webBrowserBookmarks,
            ],
          ),
        )
        .listen((_) {
          if (_ownWrites == 0) _notify();
        });
  }

  final FushiDatabase _db;
  final DateTime Function() _clock;
  final String Function() _newUid;
  late final StreamSubscription<Set<TableUpdate>> _externalUpdates;
  bool _disposed = false;

  /// 进行中的本 store 写入数（含其更新事件尚未送达的收尾窗口）。
  int _ownWrites = 0;

  /// 包住一次会改历史 / 书签表的写入：计数期间 drift 更新流的事件视作自己产生的。
  /// drift 在提交后以微任务送达更新事件，计数推迟到下一个事件循环任务再撤，保证
  /// 这些事件落在窗口内。
  Future<T> _write<T>(Future<T> Function() body) async {
    _ownWrites++;
    try {
      return await body();
    } finally {
      unawaited(Future<void>(() => _ownWrites--));
    }
  }

  static final Random _random = Random.secure();

  /// 128 位随机 hex：书签跨端身份，生成一次永不改变。
  static String _randomUid() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  int get _nowMs => _clock().millisecondsSinceEpoch;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_externalUpdates.cancel());
    super.dispose();
  }

  // ── 历史 ──────────────────────────────────────────────────────────

  @override
  Future<void> recordVisit({required Uri url, required String title}) async {
    await _write(
      () => _db.recordWebBrowserVisit(
        url: url.toString(),
        title: title,
        visitedAt: _nowMs,
      ),
    );
    _notify();
  }

  @override
  Future<List<WebBrowserHistoryEntry>> history({
    String query = '',
    int limit = 200,
    int offset = 0,
  }) async {
    if (normalizeMediaSearchText(query).isEmpty) {
      return <WebBrowserHistoryEntry>[
        for (final WebBrowserHistoryRow r in await _db.getWebBrowserHistory(
          limit: limit,
          offset: offset,
        ))
          _historyEntry(r),
      ];
    }
    final List<WebBrowserHistoryRow> matched =
        filterByMediaSearch<WebBrowserHistoryRow>(
          await _db.getWebBrowserHistory(),
          query,
          (WebBrowserHistoryRow r) => <String>[r.title, r.url],
        );
    return <WebBrowserHistoryEntry>[
      for (final WebBrowserHistoryRow r in matched.skip(offset).take(limit))
        _historyEntry(r),
    ];
  }

  static WebBrowserHistoryEntry _historyEntry(WebBrowserHistoryRow r) =>
      WebBrowserHistoryEntry(
        id: r.id,
        url: Uri.parse(r.url),
        title: r.title,
        lastVisitedAt: DateTime.fromMillisecondsSinceEpoch(r.lastVisitedAt),
        visitCount: r.visitCount,
      );

  @override
  Future<void> deleteHistory(Iterable<int> ids) async {
    await _write(
      () => _db.deleteWebBrowserHistoryByIds(ids, deletedAt: _nowMs),
    );
    _notify();
  }

  @override
  Future<void> clearHistory({DateTime? since}) async {
    await _write(
      () => _db.clearWebBrowserHistory(
        since: since?.millisecondsSinceEpoch,
        deletedAt: _nowMs,
      ),
    );
    _notify();
  }

  // ── 书签 ──────────────────────────────────────────────────────────

  @override
  Future<List<WebBrowserBookmark>> bookmarks({int? parentId}) async =>
      <WebBrowserBookmark>[
        for (final WebBrowserBookmarkRow r
            in await _db.getWebBrowserBookmarkChildren(parentId))
          _bookmark(r),
      ];

  @override
  Future<List<WebBrowserBookmark>> allBookmarks() async => <WebBrowserBookmark>[
    for (final WebBrowserBookmarkRow r in await _db.getAllWebBrowserBookmarks())
      if (r.url != null) _bookmark(r),
  ];

  @override
  Future<WebBrowserBookmark?> bookmarkForUrl(Uri url) async {
    final WebBrowserBookmarkRow? row = await _db.getWebBrowserBookmarkByUrl(
      url.toString(),
    );
    return row == null ? null : _bookmark(row);
  }

  static WebBrowserBookmark _bookmark(WebBrowserBookmarkRow r) =>
      WebBrowserBookmark(
        id: r.id,
        title: r.title,
        url: r.url == null ? null : Uri.parse(r.url!),
        parentId: r.parentId,
        position: r.position,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
      );

  @override
  Future<int> addBookmark({
    required String title,
    required Uri url,
    int? parentId,
  }) async {
    final int id = await _write(
      () => _db.insertWebBrowserBookmark(
        uid: _newUid(),
        title: title,
        url: url.toString(),
        parentId: parentId,
        now: _nowMs,
      ),
    );
    _notify();
    return id;
  }

  @override
  Future<int> addFolder({required String title, int? parentId}) async {
    final int id = await _write(
      () => _db.insertWebBrowserBookmark(
        uid: _newUid(),
        title: title,
        url: null,
        parentId: parentId,
        now: _nowMs,
      ),
    );
    _notify();
    return id;
  }

  @override
  Future<void> updateBookmark(
    int id, {
    String? title,
    Uri? url,
    int? parentId,
    int? position,
    bool moveToRoot = false,
  }) async {
    ({int? parentId, int? position})? moveTo;
    if (moveToRoot || parentId != null || position != null) {
      final WebBrowserBookmarkRow? row = await _db.getWebBrowserBookmarkById(
        id,
      );
      if (row == null) return;
      final int? target = moveToRoot ? null : (parentId ?? row.parentId);
      // 父级没变又没给序位 = 不是移动（不把它挪到末尾）。
      if (target != row.parentId || position != null) {
        moveTo = (parentId: target, position: position);
      }
    }
    await _write(
      () => _db.updateWebBrowserBookmark(
        id,
        title: title,
        url: url?.toString(),
        moveTo: moveTo,
        now: _nowMs,
      ),
    );
    _notify();
  }

  @override
  Future<void> deleteBookmark(int id) async {
    await _write(() => _db.deleteWebBrowserBookmarkTree(id, deletedAt: _nowMs));
    _notify();
  }

  // ── 标签页会话 ─────────────────────────────────────────────────────

  @override
  Future<void> saveSession(WebBrowserSession session) async {
    await _db
        .replaceWebBrowserSession(<({String tabId, String url, String title})>[
          for (final WebBrowserSessionTab t in session.tabs)
            (tabId: t.id, url: t.url.toString(), title: t.title),
        ], activeTabId: session.activeTabId);
    _notify();
  }

  @override
  Future<WebBrowserSession?> loadSession() async {
    final List<WebBrowserSessionTabRow> rows = await _db.getWebBrowserSession();
    if (rows.isEmpty) return null;
    String? active;
    for (final WebBrowserSessionTabRow r in rows) {
      if (r.active) active = r.tabId;
    }
    return WebBrowserSession(
      tabs: <WebBrowserSessionTab>[
        for (final WebBrowserSessionTabRow r in rows)
          WebBrowserSessionTab(
            id: r.tabId,
            url: Uri.parse(r.url),
            title: r.title,
          ),
      ],
      activeTabId: active,
    );
  }

  @override
  Future<void> pushClosedTab(WebBrowserClosedTab tab) async {
    await _db.pushWebBrowserClosedTab(
      url: tab.url.toString(),
      title: tab.title,
      closedAt: tab.closedAt.millisecondsSinceEpoch,
      tabIndex: tab.index,
    );
    _notify();
  }

  @override
  Future<WebBrowserClosedTab?> popClosedTab() async {
    final WebBrowserClosedTabRow? row = await _db.popWebBrowserClosedTab();
    if (row == null) return null;
    _notify();
    return _closedTab(row);
  }

  @override
  Future<List<WebBrowserClosedTab>> closedTabs() async => <WebBrowserClosedTab>[
    for (final WebBrowserClosedTabRow r in await _db.getWebBrowserClosedTabs())
      _closedTab(r),
  ];

  static WebBrowserClosedTab _closedTab(WebBrowserClosedTabRow r) =>
      WebBrowserClosedTab(
        url: Uri.parse(r.url),
        title: r.title,
        closedAt: DateTime.fromMillisecondsSinceEpoch(r.closedAt),
        index: r.tabIndex,
      );

  // ── 下载记录 ─────────────────────────────────────────────────────

  @override
  Future<int> addDownload(WebBrowserDownload download) async {
    final int id = await _db.insertWebBrowserDownload(
      WebBrowserDownloadsCompanion.insert(
        url: download.url.toString(),
        fileName: download.fileName,
        mimeType: Value(download.mimeType),
        totalBytes: Value(download.totalBytes),
        receivedBytes: Value(download.receivedBytes),
        state: download.state.name,
        savedPath: Value(download.savedPath),
        startedAt: download.startedAt.millisecondsSinceEpoch,
      ),
    );
    _notify();
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
    await _db.updateWebBrowserDownload(
      id,
      WebBrowserDownloadsCompanion(
        receivedBytes: receivedBytes == null
            ? const Value<int>.absent()
            : Value<int>(receivedBytes),
        totalBytes: totalBytes == null
            ? const Value<int?>.absent()
            : Value<int?>(totalBytes),
        state: state == null
            ? const Value<String>.absent()
            : Value<String>(state.name),
        savedPath: savedPath == null
            ? const Value<String?>.absent()
            : Value<String?>(savedPath),
      ),
    );
    _notify();
  }

  @override
  Future<List<WebBrowserDownload>> downloads() async => <WebBrowserDownload>[
    for (final WebBrowserDownloadRow r in await _db.getWebBrowserDownloads())
      WebBrowserDownload(
        id: r.id,
        url: Uri.parse(r.url),
        fileName: r.fileName,
        startedAt: DateTime.fromMillisecondsSinceEpoch(r.startedAt),
        mimeType: r.mimeType,
        totalBytes: r.totalBytes,
        receivedBytes: r.receivedBytes,
        state: _downloadState(r.state),
        savedPath: r.savedPath,
      ),
  ];

  /// 落库字符串 → 状态；未知值（未来版本写的）按失败处理，不抛。
  static WebBrowserDownloadState _downloadState(String raw) {
    for (final WebBrowserDownloadState s in WebBrowserDownloadState.values) {
      if (s.name == raw) return s;
    }
    return WebBrowserDownloadState.failed;
  }

  @override
  Future<void> deleteDownload(int id) async {
    await _db.deleteWebBrowserDownload(id);
    _notify();
  }
}
