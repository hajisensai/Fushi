// 内置浏览器（v128）：历史 / 书签（含文件夹）/ 标签页会话 / 最近关闭 / 下载记录。
// 表语义见 tables.dart 的 web_browser_* 段。历史与书签的删除写 sync_deletion_tombstones
// （`webhistory` / `webbookmark`），跨端同步走聚合快照（fushi_engine
// AggregateSyncService）；会话 / 最近关闭 / 下载是设备本地。
part of 'database.dart';

/// 最近关闭标签页的保留上限。
const int kWebBrowserClosedTabsLimit = 25;

/// 历史「按时间段清除」墓碑的 itemKey 前缀：`~clear:<since 毫秒>`，deletedAt = 清除时刻。
///
/// 一次「清除全部 / 清除最近 N 小时」只写**一条**区间墓碑，而不是给每个 url 各写一条
/// （历史动辄上千条，逐条墓碑会让快照与墓碑表无界膨胀）。区间墓碑压制
/// `since <= lastVisitedAt < deletedAt` 的历史条目；`~` 不可能是绝对 URL 的首字符
/// （scheme 必须以字母开头），与逐条墓碑（itemKey = url）不会撞键。
const String kWebHistoryClearTombstonePrefix = '~clear:';

/// 「清除 [since] 之后的历史」区间墓碑的 itemKey（[since] 为 0 = 全部）。
String webHistoryClearTombstoneKey(int since) =>
    '$kWebHistoryClearTombstonePrefix$since';

/// 区间墓碑 itemKey 的起点毫秒；不是区间墓碑（= 逐条 url 墓碑）返回 null。
int? webHistoryClearTombstoneSince(String itemKey) {
  if (!itemKey.startsWith(kWebHistoryClearTombstonePrefix)) return null;
  return int.tryParse(
    itemKey.substring(kWebHistoryClearTombstonePrefix.length),
  );
}

/// 一条历史（[url] 最近访问于 [lastVisitedAt]）是否被墓碑集合 [tombstones]
/// （itemKey → deletedAt）压制。逐条墓碑：`deletedAt > lastVisitedAt`；区间墓碑：
/// `since <= lastVisitedAt < deletedAt`。删除之后再访问（lastVisitedAt 更新）即复活。
bool isWebHistorySuppressed({
  required String url,
  required int lastVisitedAt,
  required Map<String, int> tombstones,
}) {
  if ((tombstones[url] ?? 0) > lastVisitedAt) return true;
  for (final MapEntry<String, int> e in tombstones.entries) {
    final int? since = webHistoryClearTombstoneSince(e.key);
    if (since == null) continue;
    if (lastVisitedAt >= since && lastVisitedAt < e.value) return true;
  }
  return false;
}

mixin _FushiDbWebBrowser on _$FushiDatabase {
  /// 写一条浏览器删除墓碑（与 `writeSyncDeletionTombstone` 同语义：同键 upsert 刷新
  /// deletedAt、重置发布状态）。本 mixin 只能看到生成的表访问器，故内联一份。
  Future<void> _writeWebBrowserTombstone(
    String mediaType,
    String itemKey,
    int deletedAt,
  ) => into(syncDeletionTombstones).insertOnConflictUpdate(
    SyncDeletionTombstoneRow(
      mediaType: mediaType,
      itemKey: itemKey,
      deletedAt: deletedAt,
      remotePublishedAt: 0,
      cloudFolderState: TombstoneCloudFolderState.pending.dbValue,
    ),
  );

  // ── 历史 ──────────────────────────────────────────────────────────

  /// 记一次访问：同 url 合并（次数 +1、最近访问取大、[title] 非空时覆盖标题）。
  /// 本机再次访问一条曾被删除的 url，同键逐条墓碑一并退场（与收藏词重收藏清墓碑同律）。
  Future<void> recordWebBrowserVisit({
    required String url,
    required String title,
    required int visitedAt,
  }) async {
    await transaction(() async {
      final WebBrowserHistoryRow? existing =
          await (select(webBrowserHistory)
                ..where(($WebBrowserHistoryTable t) => t.url.equals(url)))
              .getSingleOrNull();
      if (existing == null) {
        await into(webBrowserHistory).insert(
          WebBrowserHistoryCompanion.insert(
            url: url,
            title: Value(title),
            lastVisitedAt: visitedAt,
            visitCount: const Value(1),
          ),
        );
      } else {
        await (update(webBrowserHistory)
              ..where(($WebBrowserHistoryTable t) => t.id.equals(existing.id)))
            .write(
              WebBrowserHistoryCompanion(
                title: Value(title.isEmpty ? existing.title : title),
                lastVisitedAt: Value(
                  visitedAt > existing.lastVisitedAt
                      ? visitedAt
                      : existing.lastVisitedAt,
                ),
                visitCount: Value(existing.visitCount + 1),
              ),
            );
      }
      await (delete(syncDeletionTombstones)..where(
            ($SyncDeletionTombstonesTable t) =>
                t.mediaType.equals(SyncTombstoneKind.webhistory.dbValue) &
                t.itemKey.equals(url),
          ))
          .go();
    });
  }

  /// 全部历史，按最近访问倒序（同刻按 id 倒序，结果确定）。
  Future<List<WebBrowserHistoryRow>> getWebBrowserHistory({
    int? limit,
    int offset = 0,
  }) {
    final SimpleSelectStatement<$WebBrowserHistoryTable, WebBrowserHistoryRow>
    q = select(webBrowserHistory)
      ..orderBy(<OrderClauseGenerator<$WebBrowserHistoryTable>>[
        ($WebBrowserHistoryTable t) => OrderingTerm.desc(t.lastVisitedAt),
        ($WebBrowserHistoryTable t) => OrderingTerm.desc(t.id),
      ]);
    if (limit != null) q.limit(limit, offset: offset);
    return q.get();
  }

  /// 按 id 删历史，每条写一个 `webhistory` 逐条墓碑（itemKey = url）。
  Future<void> deleteWebBrowserHistoryByIds(
    Iterable<int> ids, {
    required int deletedAt,
  }) async {
    final List<int> idList = ids.toList(growable: false);
    if (idList.isEmpty) return;
    await transaction(() async {
      final List<WebBrowserHistoryRow> rows = await (select(
        webBrowserHistory,
      )..where(($WebBrowserHistoryTable t) => t.id.isIn(idList))).get();
      for (final WebBrowserHistoryRow row in rows) {
        await _writeWebBrowserTombstone(
          SyncTombstoneKind.webhistory.dbValue,
          row.url,
          deletedAt,
        );
      }
      await (delete(
        webBrowserHistory,
      )..where(($WebBrowserHistoryTable t) => t.id.isIn(idList))).go();
    });
  }

  /// 清除最近访问 `>= since` 的历史（[since] 为 null = 全部），写**一条**区间墓碑
  /// （见 [kWebHistoryClearTombstonePrefix]）。
  Future<void> clearWebBrowserHistory({
    int? since,
    required int deletedAt,
  }) async {
    await transaction(() async {
      await _writeWebBrowserTombstone(
        SyncTombstoneKind.webhistory.dbValue,
        webHistoryClearTombstoneKey(since ?? 0),
        deletedAt,
      );
      final DeleteStatement<$WebBrowserHistoryTable, WebBrowserHistoryRow> d =
          delete(webBrowserHistory);
      if (since != null) {
        d.where(
          ($WebBrowserHistoryTable t) =>
              t.lastVisitedAt.isBiggerOrEqualValue(since),
        );
      }
      await d.go();
    });
  }

  /// 同步落地：把一条对端历史并进本机（url 并集；次数取大、最近访问取大、标题跟较新的
  /// 访问走）。幂等：重复应用同一条不改变任何行。
  Future<void> mergeWebBrowserHistoryEntry({
    required String url,
    required String title,
    required int lastVisitedAt,
    required int visitCount,
  }) async {
    final WebBrowserHistoryRow? existing =
        await (select(webBrowserHistory)
              ..where(($WebBrowserHistoryTable t) => t.url.equals(url)))
            .getSingleOrNull();
    if (existing == null) {
      await into(webBrowserHistory).insert(
        WebBrowserHistoryCompanion.insert(
          url: url,
          title: Value(title),
          lastVisitedAt: lastVisitedAt,
          visitCount: Value(visitCount),
        ),
      );
      return;
    }
    final bool incomingNewer = lastVisitedAt > existing.lastVisitedAt;
    final String mergedTitle = incomingNewer && title.isNotEmpty
        ? title
        : existing.title;
    final int mergedAt = incomingNewer ? lastVisitedAt : existing.lastVisitedAt;
    final int mergedCount = visitCount > existing.visitCount
        ? visitCount
        : existing.visitCount;
    if (mergedTitle == existing.title &&
        mergedAt == existing.lastVisitedAt &&
        mergedCount == existing.visitCount) {
      return;
    }
    await (update(
      webBrowserHistory,
    )..where(($WebBrowserHistoryTable t) => t.id.equals(existing.id))).write(
      WebBrowserHistoryCompanion(
        title: Value(mergedTitle),
        lastVisitedAt: Value(mergedAt),
        visitCount: Value(mergedCount),
      ),
    );
  }

  /// 同步落地：删掉本机被墓碑集合 [tombstones]（itemKey → deletedAt）压制的历史行
  /// （判据 [isWebHistorySuppressed]）。不写墓碑（墓碑由调用方按对端原戳落表）。
  Future<void> removeWebBrowserHistorySuppressedBy(
    Map<String, int> tombstones,
  ) async {
    if (tombstones.isEmpty) return;
    final List<int> doomed = <int>[
      for (final WebBrowserHistoryRow row in await select(
        webBrowserHistory,
      ).get())
        if (isWebHistorySuppressed(
          url: row.url,
          lastVisitedAt: row.lastVisitedAt,
          tombstones: tombstones,
        ))
          row.id,
    ];
    if (doomed.isEmpty) return;
    await (delete(
      webBrowserHistory,
    )..where(($WebBrowserHistoryTable t) => t.id.isIn(doomed))).go();
  }

  // ── 书签 ──────────────────────────────────────────────────────────

  /// 全部书签与文件夹（按 parentId、position、id 排序）。
  Future<List<WebBrowserBookmarkRow>> getAllWebBrowserBookmarks() =>
      (select(webBrowserBookmarks)
            ..orderBy(<OrderClauseGenerator<$WebBrowserBookmarksTable>>[
              ($WebBrowserBookmarksTable t) => OrderingTerm.asc(t.parentId),
              ($WebBrowserBookmarksTable t) => OrderingTerm.asc(t.position),
              ($WebBrowserBookmarksTable t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// [parentId] 下的直接子项（null = 根目录），按 position 排序。
  Future<List<WebBrowserBookmarkRow>> getWebBrowserBookmarkChildren(
    int? parentId,
  ) =>
      (select(webBrowserBookmarks)
            ..where(
              ($WebBrowserBookmarksTable t) => parentId == null
                  ? t.parentId.isNull()
                  : t.parentId.equals(parentId),
            )
            ..orderBy(<OrderClauseGenerator<$WebBrowserBookmarksTable>>[
              ($WebBrowserBookmarksTable t) => OrderingTerm.asc(t.position),
              ($WebBrowserBookmarksTable t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  Future<WebBrowserBookmarkRow?> getWebBrowserBookmarkById(int id) => (select(
    webBrowserBookmarks,
  )..where(($WebBrowserBookmarksTable t) => t.id.equals(id))).getSingleOrNull();

  /// [url] 对应的第一条书签（不含文件夹；多条时取最早建的）。
  Future<WebBrowserBookmarkRow?> getWebBrowserBookmarkByUrl(String url) async {
    final List<WebBrowserBookmarkRow> rows =
        await (select(webBrowserBookmarks)
              ..where(($WebBrowserBookmarksTable t) => t.url.equals(url))
              ..orderBy(<OrderClauseGenerator<$WebBrowserBookmarksTable>>[
                ($WebBrowserBookmarksTable t) => OrderingTerm.asc(t.id),
              ])
              ..limit(1))
            .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// 在 [parentId] 末尾新建一条书签（[url] 为 null = 文件夹），返回本机 id。
  Future<int> insertWebBrowserBookmark({
    required String uid,
    required String title,
    required String? url,
    required int? parentId,
    required int now,
  }) async {
    return transaction(() async {
      final int position = await _nextWebBrowserBookmarkPosition(parentId);
      return into(webBrowserBookmarks).insert(
        WebBrowserBookmarksCompanion.insert(
          uid: uid,
          title: title,
          url: Value(url),
          parentId: Value(parentId),
          position: Value(position),
          createdAt: now,
          updatedAt: now,
        ),
      );
    });
  }

  Future<int> _nextWebBrowserBookmarkPosition(int? parentId) async {
    final List<WebBrowserBookmarkRow> siblings =
        await getWebBrowserBookmarkChildren(parentId);
    int next = 0;
    for (final WebBrowserBookmarkRow r in siblings) {
      if (r.position >= next) next = r.position + 1;
    }
    return next;
  }

  /// 改标题 / 地址 / 位置。[moveTo] 非 null 时移动：`moveTo.parentId` 为目标父级
  /// （null = 根），`moveTo.position` 为目标序位（null = 末尾）；两个兄弟列表都按
  /// 0..n-1 重排，序位真变了的行 updatedAt 一并推进（让排序跨端 LWW 传播）。
  /// 把文件夹移进它自己或其后代时移动静默忽略（与 `WebBrowserStore.updateBookmark`
  /// 契约一致）。
  Future<void> updateWebBrowserBookmark(
    int id, {
    String? title,
    String? url,
    ({int? parentId, int? position})? moveTo,
    required int now,
  }) async {
    await transaction(() async {
      final WebBrowserBookmarkRow? row = await getWebBrowserBookmarkById(id);
      if (row == null) return;
      if (title != null || url != null) {
        await (update(
          webBrowserBookmarks,
        )..where(($WebBrowserBookmarksTable t) => t.id.equals(id))).write(
          WebBrowserBookmarksCompanion(
            title: title == null ? const Value.absent() : Value(title),
            // 文件夹没有地址：只对书签行改 url。
            url: url == null || row.url == null
                ? const Value.absent()
                : Value(url),
            updatedAt: Value(now),
          ),
        );
      }
      if (moveTo == null) return;
      final int? targetParent = moveTo.parentId;
      if (targetParent != null) {
        if (targetParent == id ||
            (await _webBrowserBookmarkDescendantIds(
              id,
            )).contains(targetParent)) {
          // 移进自己或后代会成环：整次移动静默忽略（标题 / 地址的修改照常生效）。
          return;
        }
      }
      final List<WebBrowserBookmarkRow> oldSiblings = <WebBrowserBookmarkRow>[
        for (final WebBrowserBookmarkRow r
            in await getWebBrowserBookmarkChildren(row.parentId))
          if (r.id != id) r,
      ];
      final List<WebBrowserBookmarkRow> newSiblings =
          row.parentId == targetParent
          ? oldSiblings
          : <WebBrowserBookmarkRow>[
              for (final WebBrowserBookmarkRow r
                  in await getWebBrowserBookmarkChildren(targetParent))
                if (r.id != id) r,
            ];
      final int insertAt = (moveTo.position ?? newSiblings.length).clamp(
        0,
        newSiblings.length,
      );
      final List<WebBrowserBookmarkRow> placed = <WebBrowserBookmarkRow>[
        ...newSiblings,
      ]..insert(insertAt, row);
      Future<void> renumber(List<WebBrowserBookmarkRow> list) async {
        for (int i = 0; i < list.length; i++) {
          final WebBrowserBookmarkRow r = list[i];
          final bool moved = r.id == id;
          if (!moved && r.position == i) continue;
          await (update(
            webBrowserBookmarks,
          )..where(($WebBrowserBookmarksTable t) => t.id.equals(r.id))).write(
            WebBrowserBookmarksCompanion(
              position: Value(i),
              parentId: moved ? Value(targetParent) : const Value.absent(),
              updatedAt: Value(now),
            ),
          );
        }
      }

      if (row.parentId != targetParent) await renumber(oldSiblings);
      await renumber(placed);
    });
  }

  /// [id] 的全部后代 id（不含自身）。
  Future<Set<int>> _webBrowserBookmarkDescendantIds(int id) async {
    final Map<int?, List<int>> childrenOf = <int?, List<int>>{};
    for (final WebBrowserBookmarkRow r in await select(
      webBrowserBookmarks,
    ).get()) {
      childrenOf.putIfAbsent(r.parentId, () => <int>[]).add(r.id);
    }
    final Set<int> out = <int>{};
    final List<int> stack = <int>[...?childrenOf[id]];
    while (stack.isNotEmpty) {
      final int next = stack.removeLast();
      if (!out.add(next)) continue;
      stack.addAll(childrenOf[next] ?? const <int>[]);
    }
    return out;
  }

  /// 删一条书签；文件夹连同其下全部内容。每条被删的行写一个 `webbookmark` 墓碑
  /// （itemKey = uid），删文件夹的意图因此能逐条传到对端。
  Future<void> deleteWebBrowserBookmarkTree(
    int id, {
    required int deletedAt,
  }) async {
    await transaction(() async {
      final WebBrowserBookmarkRow? row = await getWebBrowserBookmarkById(id);
      if (row == null) return;
      final Set<int> doomed = <int>{
        id,
        ...await _webBrowserBookmarkDescendantIds(id),
      };
      final List<WebBrowserBookmarkRow> rows = await (select(
        webBrowserBookmarks,
      )..where(($WebBrowserBookmarksTable t) => t.id.isIn(doomed))).get();
      for (final WebBrowserBookmarkRow r in rows) {
        await _writeWebBrowserTombstone(
          SyncTombstoneKind.webbookmark.dbValue,
          r.uid,
          deletedAt,
        );
      }
      await (delete(
        webBrowserBookmarks,
      )..where(($WebBrowserBookmarksTable t) => t.id.isIn(doomed))).go();
    });
  }

  /// 同步落地：按 uid LWW 并入一条对端书签。[parentUid] 为 null = 根；父级在本机
  /// 不存在（尚未到达 / 已被本机删）时落到根目录，不丢条目。本机已有同 uid 且
  /// `updatedAt` 不小于对端时不动（幂等）。返回落地后的本机 id。
  Future<int> upsertWebBrowserBookmarkFromSync({
    required String uid,
    required String title,
    required String? url,
    required String? parentUid,
    required int position,
    required int createdAt,
    required int updatedAt,
  }) async {
    int? parentId;
    if (parentUid != null) {
      final WebBrowserBookmarkRow? parent =
          await (select(webBrowserBookmarks)..where(
                ($WebBrowserBookmarksTable t) => t.uid.equals(parentUid),
              ))
              .getSingleOrNull();
      parentId = parent?.id;
    }
    final WebBrowserBookmarkRow? existing =
        await (select(webBrowserBookmarks)
              ..where(($WebBrowserBookmarksTable t) => t.uid.equals(uid)))
            .getSingleOrNull();
    if (existing == null) {
      return into(webBrowserBookmarks).insert(
        WebBrowserBookmarksCompanion.insert(
          uid: uid,
          title: title,
          url: Value(url),
          parentId: Value(parentId),
          position: Value(position),
          createdAt: createdAt,
          updatedAt: updatedAt,
        ),
      );
    }
    if (existing.updatedAt >= updatedAt) return existing.id;
    // 环保护：对端把文件夹挪进了本机认为是它后代的地方（两端并发移动）——落根。
    if (parentId != null &&
        (parentId == existing.id ||
            (await _webBrowserBookmarkDescendantIds(
              existing.id,
            )).contains(parentId))) {
      parentId = null;
    }
    await (update(
      webBrowserBookmarks,
    )..where(($WebBrowserBookmarksTable t) => t.id.equals(existing.id))).write(
      WebBrowserBookmarksCompanion(
        title: Value(title),
        url: Value(url),
        parentId: Value(parentId),
        position: Value(position),
        updatedAt: Value(updatedAt),
      ),
    );
    return existing.id;
  }

  /// 同步落地：删掉 uid 被墓碑严格压制（`deletedAt > updatedAt`）的书签行。被删文件夹
  /// 下仍存活的子项（对端在删除之后新加 / 改过）挂回根目录，不随父级消失。
  Future<void> removeWebBrowserBookmarksSuppressedBy(
    Map<String, int> tombstones,
  ) async {
    if (tombstones.isEmpty) return;
    final List<WebBrowserBookmarkRow> all = await select(
      webBrowserBookmarks,
    ).get();
    final Set<int> doomed = <int>{
      for (final WebBrowserBookmarkRow r in all)
        if ((tombstones[r.uid] ?? 0) > r.updatedAt) r.id,
    };
    if (doomed.isEmpty) return;
    await transaction(() async {
      await (delete(
        webBrowserBookmarks,
      )..where(($WebBrowserBookmarksTable t) => t.id.isIn(doomed))).go();
      await (update(webBrowserBookmarks)
            ..where(($WebBrowserBookmarksTable t) => t.parentId.isIn(doomed)))
          .write(const WebBrowserBookmarksCompanion(parentId: Value(null)));
    });
  }

  // ── 标签页会话（设备本地）─────────────────────────────────────────

  /// 整份覆盖会话：按顺序写 [tabs]，[activeTabId] 那一行标记激活。
  Future<void> replaceWebBrowserSession(
    List<({String tabId, String url, String title})> tabs, {
    required String? activeTabId,
  }) async {
    await transaction(() async {
      await delete(webBrowserSessionTabs).go();
      for (int i = 0; i < tabs.length; i++) {
        await into(webBrowserSessionTabs).insert(
          WebBrowserSessionTabsCompanion.insert(
            position: Value(i),
            tabId: tabs[i].tabId,
            url: tabs[i].url,
            title: Value(tabs[i].title),
            active: Value(tabs[i].tabId == activeTabId),
          ),
        );
      }
    });
  }

  Future<List<WebBrowserSessionTabRow>> getWebBrowserSession() =>
      (select(webBrowserSessionTabs)
            ..orderBy(<OrderClauseGenerator<$WebBrowserSessionTabsTable>>[
              ($WebBrowserSessionTabsTable t) => OrderingTerm.asc(t.position),
            ]))
          .get();

  // ── 最近关闭（设备本地）───────────────────────────────────────────

  /// 记一条最近关闭，并把超出 [kWebBrowserClosedTabsLimit] 的最旧条目删掉。
  Future<void> pushWebBrowserClosedTab({
    required String url,
    required String title,
    required int closedAt,
    required int tabIndex,
  }) async {
    await transaction(() async {
      await into(webBrowserClosedTabs).insert(
        WebBrowserClosedTabsCompanion.insert(
          url: url,
          title: Value(title),
          closedAt: closedAt,
          tabIndex: Value(tabIndex),
        ),
      );
      final List<WebBrowserClosedTabRow> rows = await getWebBrowserClosedTabs();
      if (rows.length <= kWebBrowserClosedTabsLimit) return;
      final List<int> overflow = <int>[
        for (final WebBrowserClosedTabRow r in rows.skip(
          kWebBrowserClosedTabsLimit,
        ))
          r.id,
      ];
      await (delete(
        webBrowserClosedTabs,
      )..where(($WebBrowserClosedTabsTable t) => t.id.isIn(overflow))).go();
    });
  }

  /// 最近关闭，最新在前。
  Future<List<WebBrowserClosedTabRow>> getWebBrowserClosedTabs() =>
      (select(webBrowserClosedTabs)
            ..orderBy(<OrderClauseGenerator<$WebBrowserClosedTabsTable>>[
              ($WebBrowserClosedTabsTable t) => OrderingTerm.desc(t.closedAt),
              ($WebBrowserClosedTabsTable t) => OrderingTerm.desc(t.id),
            ]))
          .get();

  /// 取出并删除最新一条最近关闭；没有时返回 null。
  Future<WebBrowserClosedTabRow?> popWebBrowserClosedTab() {
    return transaction(() async {
      final List<WebBrowserClosedTabRow> rows = await getWebBrowserClosedTabs();
      if (rows.isEmpty) return null;
      final WebBrowserClosedTabRow top = rows.first;
      await (delete(
        webBrowserClosedTabs,
      )..where(($WebBrowserClosedTabsTable t) => t.id.equals(top.id))).go();
      return top;
    });
  }

  // ── 下载记录（设备本地）───────────────────────────────────────────

  Future<int> insertWebBrowserDownload(WebBrowserDownloadsCompanion row) =>
      into(webBrowserDownloads).insert(row);

  Future<void> updateWebBrowserDownload(
    int id,
    WebBrowserDownloadsCompanion patch,
  ) => (update(
    webBrowserDownloads,
  )..where(($WebBrowserDownloadsTable t) => t.id.equals(id))).write(patch);

  /// 下载记录，最新开始的在前。
  Future<List<WebBrowserDownloadRow>> getWebBrowserDownloads() =>
      (select(webBrowserDownloads)
            ..orderBy(<OrderClauseGenerator<$WebBrowserDownloadsTable>>[
              ($WebBrowserDownloadsTable t) => OrderingTerm.desc(t.startedAt),
              ($WebBrowserDownloadsTable t) => OrderingTerm.desc(t.id),
            ]))
          .get();

  Future<void> deleteWebBrowserDownload(int id) => (delete(
    webBrowserDownloads,
  )..where(($WebBrowserDownloadsTable t) => t.id.equals(id))).go();
}
