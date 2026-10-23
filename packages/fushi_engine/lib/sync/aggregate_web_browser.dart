// v125 内置浏览器历史 / 书签在聚合快照里的合并、仲裁与本地读写。
//
// 与收藏词 / 收藏句同一条通道（[AggregateSyncService]：云 `__aggregate__` 快照 + 互联
// `GET/PUT aggregate`），同一套「并集 + 删除墓碑仲裁」：
//   - 历史按 url 并集：visitCount 取大、lastVisitedAt 取大、title 跟较新的访问走；
//     墓碑 itemKey = url（`deletedAt > lastVisitedAt` 压制），或区间墓碑
//     `~clear:<since>`（`since <= lastVisitedAt < deletedAt` 压制）。逐条墓碑在出现更晚
//     的访问后退场；区间墓碑永不退场（每次「清除浏览数据」只一条，数量有界）。
//   - 书签按 uid LWW（updatedAt 大者）；墓碑 itemKey = uid（`deletedAt > updatedAt`
//     压制），出现更晚的修改后退场。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';

/// 墓碑列表 → itemKey → deletedAt（同键取大）。
Map<String, int> webTombstoneMap(Iterable<AggregateTombstoneRecord> records) {
  final Map<String, int> out = <String, int>{};
  for (final AggregateTombstoneRecord t in records) {
    if (t.deletedAt > (out[t.itemKey] ?? 0)) out[t.itemKey] = t.deletedAt;
  }
  return out;
}

List<AggregateTombstoneRecord> _tombstoneList(Map<String, int> map) =>
    <AggregateTombstoneRecord>[
      for (final MapEntry<String, int> e in map.entries)
        AggregateTombstoneRecord(itemKey: e.key, deletedAt: e.value),
    ];

/// 历史并集（纯函数、可交换、幂等）。
List<WebHistoryRecord> mergeWebHistory(
  List<WebHistoryRecord> local,
  List<WebHistoryRecord> remote,
) {
  final Map<String, WebHistoryRecord> byUrl = <String, WebHistoryRecord>{};
  for (final WebHistoryRecord r in <WebHistoryRecord>[...local, ...remote]) {
    final WebHistoryRecord? prev = byUrl[r.url];
    if (prev == null) {
      byUrl[r.url] = r;
      continue;
    }
    // 较新的访问决定标题；同刻取字典序较大的标题，保证交换律。
    final bool rNewer =
        r.lastVisitedAt > prev.lastVisitedAt ||
        (r.lastVisitedAt == prev.lastVisitedAt &&
            r.title.compareTo(prev.title) > 0);
    final WebHistoryRecord newer = rNewer ? r : prev;
    byUrl[r.url] = WebHistoryRecord(
      url: r.url,
      title: newer.title.isNotEmpty
          ? newer.title
          : (rNewer ? prev.title : r.title),
      lastVisitedAt: newer.lastVisitedAt,
      visitCount: r.visitCount > prev.visitCount
          ? r.visitCount
          : prev.visitCount,
    );
  }
  return byUrl.values.toList();
}

/// 历史「删除 vs 再访问」仲裁：被墓碑压制的条目出局；逐条墓碑在已有更晚访问时退场。
({List<WebHistoryRecord> entries, List<AggregateTombstoneRecord> tombstones})
arbitrateWebHistory({
  required List<WebHistoryRecord> union,
  required Map<String, int> tombstones,
}) {
  final Map<String, int> latestVisit = <String, int>{
    for (final WebHistoryRecord r in union) r.url: r.lastVisitedAt,
  };
  final List<WebHistoryRecord> entries = <WebHistoryRecord>[
    for (final WebHistoryRecord r in union)
      if (!isWebHistorySuppressed(
        url: r.url,
        lastVisitedAt: r.lastVisitedAt,
        tombstones: tombstones,
      ))
        r,
  ];
  final Map<String, int> live = <String, int>{
    for (final MapEntry<String, int> e in tombstones.entries)
      if (webHistoryClearTombstoneSince(e.key) != null ||
          (latestVisit[e.key] ?? -1) < e.value)
        e.key: e.value,
  };
  return (entries: entries, tombstones: _tombstoneList(live));
}

/// 书签按 uid LWW 并集（updatedAt 大者；同刻按 JSON 字典序定胜负，保证交换律）。
List<WebBookmarkRecord> mergeWebBookmarks(
  List<WebBookmarkRecord> local,
  List<WebBookmarkRecord> remote,
) {
  final Map<String, WebBookmarkRecord> byUid = <String, WebBookmarkRecord>{};
  for (final WebBookmarkRecord r in <WebBookmarkRecord>[...local, ...remote]) {
    final WebBookmarkRecord? prev = byUid[r.uid];
    if (prev == null ||
        r.updatedAt > prev.updatedAt ||
        (r.updatedAt == prev.updatedAt &&
            r.toJson().toString().compareTo(prev.toJson().toString()) > 0)) {
      byUid[r.uid] = r;
    }
  }
  return byUid.values.toList();
}

/// 书签「删除 vs 再修改」仲裁：`deletedAt > updatedAt` 出局；已有更晚修改的墓碑退场。
({List<WebBookmarkRecord> bookmarks, List<AggregateTombstoneRecord> tombstones})
arbitrateWebBookmarks({
  required List<WebBookmarkRecord> union,
  required Map<String, int> tombstones,
}) {
  final Map<String, int> latest = <String, int>{
    for (final WebBookmarkRecord r in union) r.uid: r.updatedAt,
  };
  final List<WebBookmarkRecord> bookmarks = <WebBookmarkRecord>[
    for (final WebBookmarkRecord r in union)
      if ((tombstones[r.uid] ?? 0) <= r.updatedAt) r,
  ];
  final Map<String, int> live = <String, int>{
    for (final MapEntry<String, int> e in tombstones.entries)
      if ((latest[e.key] ?? -1) < e.value) e.key: e.value,
  };
  return (bookmarks: bookmarks, tombstones: _tombstoneList(live));
}

/// 本机浏览器历史 / 书签 / 两类墓碑 → 快照四个家族。
Future<
  ({
    List<WebHistoryRecord> history,
    List<WebBookmarkRecord> bookmarks,
    List<AggregateTombstoneRecord> historyTombstones,
    List<AggregateTombstoneRecord> bookmarkTombstones,
  })
>
materializeWebBrowserFamilies(FushiDatabase db) async {
  final List<WebBrowserBookmarkRow> bookmarkRows = await db
      .getAllWebBrowserBookmarks();
  final Map<int, String> uidById = <int, String>{
    for (final WebBrowserBookmarkRow r in bookmarkRows) r.id: r.uid,
  };
  return (
    history: <WebHistoryRecord>[
      for (final WebBrowserHistoryRow r in await db.getWebBrowserHistory())
        WebHistoryRecord(
          url: r.url,
          title: r.title,
          lastVisitedAt: r.lastVisitedAt,
          visitCount: r.visitCount,
        ),
    ],
    bookmarks: <WebBookmarkRecord>[
      for (final WebBrowserBookmarkRow r in bookmarkRows)
        WebBookmarkRecord(
          uid: r.uid,
          title: r.title,
          url: r.url,
          parentUid: r.parentId == null ? null : uidById[r.parentId],
          position: r.position,
          createdAt: r.createdAt,
          updatedAt: r.updatedAt,
        ),
    ],
    historyTombstones: await _localTombstones(db, SyncTombstoneKind.webhistory),
    bookmarkTombstones: await _localTombstones(
      db,
      SyncTombstoneKind.webbookmark,
    ),
  );
}

Future<List<AggregateTombstoneRecord>> _localTombstones(
  FushiDatabase db,
  SyncTombstoneKind kind,
) async => <AggregateTombstoneRecord>[
  for (final SyncDeletionTombstoneRow row
      in await db.getSyncDeletionTombstonesOfType(kind.dbValue))
    AggregateTombstoneRecord(itemKey: row.itemKey, deletedAt: row.deletedAt),
];

/// 按本机墓碑裁剪将要上行的历史 / 书签（与 [applyWebBrowserFamilies] 的跳过规则同源）。
Future<({List<WebHistoryRecord> history, List<WebBookmarkRecord> bookmarks})>
filterWebBrowserTombstoned(
  FushiDatabase db, {
  required List<WebHistoryRecord> history,
  required List<WebBookmarkRecord> bookmarks,
}) async {
  final Map<String, int> historyTombs = webTombstoneMap(
    await _localTombstones(db, SyncTombstoneKind.webhistory),
  );
  final Map<String, int> bookmarkTombs = webTombstoneMap(
    await _localTombstones(db, SyncTombstoneKind.webbookmark),
  );
  return (
    history: historyTombs.isEmpty
        ? history
        : <WebHistoryRecord>[
            for (final WebHistoryRecord r in history)
              if (!isWebHistorySuppressed(
                url: r.url,
                lastVisitedAt: r.lastVisitedAt,
                tombstones: historyTombs,
              ))
                r,
          ],
    bookmarks: bookmarkTombs.isEmpty
        ? bookmarks
        : <WebBookmarkRecord>[
            for (final WebBookmarkRecord r in bookmarks)
              if ((bookmarkTombs[r.uid] ?? 0) <= r.updatedAt) r,
          ],
  );
}

/// 把快照的浏览器四个家族落进本机：墓碑先落（只写严格较新者）并删掉被压制的行，再按
/// 本机（含刚落下的）墓碑过滤后并入历史与书签。幂等：重复应用同一快照不改变任何行。
Future<void> applyWebBrowserFamilies(
  FushiDatabase db,
  AggregateSnapshot snapshot,
) async {
  Future<Map<String, int>> persist(
    SyncTombstoneKind kind,
    List<AggregateTombstoneRecord> incoming,
  ) async {
    final Map<String, int> existing = webTombstoneMap(
      await _localTombstones(db, kind),
    );
    for (final AggregateTombstoneRecord t in incoming) {
      if (t.deletedAt > (existing[t.itemKey] ?? 0)) {
        await db.writeSyncDeletionTombstone(
          kind.dbValue,
          t.itemKey,
          t.deletedAt,
        );
        existing[t.itemKey] = t.deletedAt;
      }
    }
    return existing;
  }

  final Map<String, int> historyTombs = await persist(
    SyncTombstoneKind.webhistory,
    snapshot.webHistoryTombstones,
  );
  final Map<String, int> bookmarkTombs = await persist(
    SyncTombstoneKind.webbookmark,
    snapshot.webBookmarkTombstones,
  );
  if (snapshot.webHistoryTombstones.isNotEmpty) {
    await db.removeWebBrowserHistorySuppressedBy(historyTombs);
  }
  if (snapshot.webBookmarkTombstones.isNotEmpty) {
    await db.removeWebBrowserBookmarksSuppressedBy(bookmarkTombs);
  }

  for (final WebHistoryRecord r in snapshot.webHistory) {
    if (isWebHistorySuppressed(
      url: r.url,
      lastVisitedAt: r.lastVisitedAt,
      tombstones: historyTombs,
    )) {
      continue;
    }
    await db.mergeWebBrowserHistoryEntry(
      url: r.url,
      title: r.title,
      lastVisitedAt: r.lastVisitedAt,
      visitCount: r.visitCount < 1 ? 1 : r.visitCount,
    );
  }

  // 父级先于子级落地：按 parentUid 拓扑排序（父级不在快照里的视作根）。剩余的
  // （环 / 孤儿）最后落，父级找不到时落根目录。
  final List<WebBookmarkRecord> pending = <WebBookmarkRecord>[
    for (final WebBookmarkRecord r in snapshot.webBookmarks)
      if ((bookmarkTombs[r.uid] ?? 0) <= r.updatedAt) r,
  ];
  final Set<String> inSnapshot = <String>{
    for (final WebBookmarkRecord r in pending) r.uid,
  };
  final Set<String> placed = <String>{};
  bool progressed = true;
  while (pending.isNotEmpty && progressed) {
    progressed = false;
    for (final WebBookmarkRecord r in List<WebBookmarkRecord>.of(pending)) {
      final String? parent = r.parentUid;
      if (parent != null &&
          inSnapshot.contains(parent) &&
          !placed.contains(parent)) {
        continue;
      }
      await _upsertBookmark(db, r);
      placed.add(r.uid);
      pending.remove(r);
      progressed = true;
    }
  }
  for (final WebBookmarkRecord r in pending) {
    await _upsertBookmark(db, r);
  }
}

Future<void> _upsertBookmark(FushiDatabase db, WebBookmarkRecord r) =>
    db.upsertWebBrowserBookmarkFromSync(
      uid: r.uid,
      title: r.title,
      url: r.url,
      parentUid: r.parentUid,
      position: r.position,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
