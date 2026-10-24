import 'package:flutter/foundation.dart';

/// 浏览器持久化数据的唯一入口（历史、书签及文件夹、标签页会话、最近关闭、下载记录）。
///
/// 浏览页与历史 / 书签 / 下载页只认这个接口；Drift 实现是 `DriftWebBrowserStore`
/// （新表在 `fushi_core`），测试用 `MemoryWebBrowserStore`。
/// 无痕标签页的任何数据都不进这里。
abstract interface class WebBrowserStore implements Listenable {
  // ── 历史 ──────────────────────────────────────────────────────────
  /// 记一次访问（同 url 合并：更新标题、访问次数 +1、lastVisitedAt）。
  Future<void> recordVisit({required Uri url, required String title});

  /// 按最近访问倒序；[query] 非空时按标题 / 地址过滤（统一归一化匹配）。
  Future<List<WebBrowserHistoryEntry>> history({
    String query = '',
    int limit = 200,
    int offset = 0,
  });

  Future<void> deleteHistory(Iterable<int> ids);

  /// [since] 为 null = 全部清空。
  Future<void> clearHistory({DateTime? since});

  // ── 书签 ──────────────────────────────────────────────────────────
  /// [parentId] 为 null = 根目录。按 position 排序，文件夹与书签混排。
  Future<List<WebBrowserBookmark>> bookmarks({int? parentId});

  /// 全部书签（不含文件夹），地址栏联想用。
  Future<List<WebBrowserBookmark>> allBookmarks();

  Future<WebBrowserBookmark?> bookmarkForUrl(Uri url);
  Future<int> addBookmark({
    required String title,
    required Uri url,
    int? parentId,
  });
  Future<int> addFolder({required String title, int? parentId});

  /// 只改显式传入的字段：[parentId] 为 null = 不改父目录；要移到根目录传
  /// [moveToRoot] = true。换父目录且没给 [position] 时排到新目录末尾；给了
  /// [position] 时把同级重新编号成 0..n-1、本条落在该下标（拖动排序）。
  /// 不允许把文件夹移进它自己或其子孙（静默忽略）。
  Future<void> updateBookmark(
    int id, {
    String? title,
    Uri? url,
    int? parentId,
    int? position,
    bool moveToRoot = false,
  });

  /// 删文件夹连同其下全部内容。
  Future<void> deleteBookmark(int id);

  // ── 标签页会话 ─────────────────────────────────────────────────────
  /// 整份覆盖（非无痕标签页，按顺序）。
  Future<void> saveSession(WebBrowserSession session);
  Future<WebBrowserSession?> loadSession();

  /// 最近关闭（最多保留 25 条，最新在前）。
  Future<void> pushClosedTab(WebBrowserClosedTab tab);
  Future<WebBrowserClosedTab?> popClosedTab();
  Future<List<WebBrowserClosedTab>> closedTabs();

  // ── 下载记录 ─────────────────────────────────────────────────────
  Future<int> addDownload(WebBrowserDownload download);
  Future<void> updateDownload(
    int id, {
    int? receivedBytes,
    int? totalBytes,
    WebBrowserDownloadState? state,
    String? savedPath,
  });

  /// 最新开始的在前。
  Future<List<WebBrowserDownload>> downloads();
  Future<void> deleteDownload(int id);
}

@immutable
class WebBrowserHistoryEntry {
  const WebBrowserHistoryEntry({
    required this.id,
    required this.url,
    required this.title,
    required this.lastVisitedAt,
    required this.visitCount,
  });

  final int id;
  final Uri url;
  final String title;
  final DateTime lastVisitedAt;
  final int visitCount;
}

@immutable
class WebBrowserBookmark {
  const WebBrowserBookmark({
    required this.id,
    required this.title,
    required this.url,
    required this.parentId,
    required this.position,
    required this.createdAt,
  });

  final int id;
  final String title;

  /// null = 文件夹。
  final Uri? url;
  final int? parentId;
  final int position;
  final DateTime createdAt;

  bool get isFolder => url == null;
}

@immutable
class WebBrowserSessionTab {
  const WebBrowserSessionTab({
    required this.id,
    required this.url,
    required this.title,
  });

  final String id;
  final Uri url;
  final String title;
}

@immutable
class WebBrowserSession {
  const WebBrowserSession({required this.tabs, required this.activeTabId});

  final List<WebBrowserSessionTab> tabs;
  final String? activeTabId;
}

@immutable
class WebBrowserClosedTab {
  const WebBrowserClosedTab({
    required this.url,
    required this.title,
    required this.closedAt,
    required this.index,
  });

  final Uri url;
  final String title;
  final DateTime closedAt;

  /// 关闭时在标签列表里的位置（恢复时尽量放回原位）。
  final int index;
}

enum WebBrowserDownloadState { running, completed, failed, cancelled }

@immutable
class WebBrowserDownload {
  const WebBrowserDownload({
    required this.id,
    required this.url,
    required this.fileName,
    required this.startedAt,
    this.mimeType,
    this.totalBytes,
    this.receivedBytes = 0,
    this.state = WebBrowserDownloadState.running,
    this.savedPath,
  });

  /// 新建时传 0，由 store 分配。
  final int id;
  final Uri url;
  final String fileName;
  final DateTime startedAt;
  final String? mimeType;
  final int? totalBytes;
  final int receivedBytes;
  final WebBrowserDownloadState state;
  final String? savedPath;
}
