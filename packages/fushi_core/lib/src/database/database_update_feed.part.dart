// 统一更新提醒（v101）：番剧新集 / 漫画新章 / 漫画扩展新版 / app 新版四个域投递到
// 同一条事件流，UI 只消费这一处。表语义见 tables.dart 的 UpdateFeedEntries。
part of 'database.dart';

mixin _FushiDbUpdateFeed on _$FushiDatabase {
  /// 投递一条更新事件。返回 `true` = 这是**第一次**发现它（调用方据此决定要不要
  /// 发系统通知）；`false` = 早就投递过，一个字节都没改。
  ///
  /// 冲突时 DO NOTHING 而不是 upsert 是刻意的：一条事件的身份（作品 + 集号/章/
  /// 版本）一旦成立，它承载的事实就不再变。重复发现若刷新 [UpdateFeedEntries
  /// .discoveredAt]，列表排序会无故跳动；若覆盖 [UpdateFeedEntries.seenAt]，
  /// 已读的条目每轮检查都会重新变红、重新弹通知。「已存在就不动」把这两个特殊
  /// 情况一起消掉，也让投递方不必先查一次再决定写不写。
  Future<bool> insertUpdateFeedEntry(UpdateFeedEntriesCompanion entry) async {
    final UpdateFeedEntryRow? inserted = await into(updateFeedEntries)
        .insertReturningOrNull(entry, mode: InsertMode.insertOrIgnore);
    return inserted != null;
  }

  /// 未读条目数，按域分组。红点只数这个；域没有未读时**键不出现**（不是 0）。
  Future<Map<String, int>> unseenUpdateFeedCountsByKind() async {
    final Expression<int> count = updateFeedEntries.entryId.count();
    final List<TypedResult> rows = await (selectOnly(updateFeedEntries)
          ..addColumns(<Expression<Object>>[updateFeedEntries.kind, count])
          ..where(updateFeedEntries.seenAt.isNull())
          ..groupBy(<Expression<Object>>[updateFeedEntries.kind]))
        .get();
    return <String, int>{
      for (final TypedResult row in rows)
        row.read(updateFeedEntries.kind)!: row.read(count) ?? 0,
    };
  }

  /// 更新列表页的一页。[kinds] 为空 = 不过滤域（不是「一个域都不要」——空集合在
  /// 这里只可能来自「调用方没有指定」，而按域过滤永远至少给一个域）。
  Future<List<UpdateFeedEntryRow>> updateFeedEntriesPage({
    Set<String> kinds = const <String>{},
    bool unseenOnly = false,
    int limit = 200,
  }) {
    final SimpleSelectStatement<$UpdateFeedEntriesTable, UpdateFeedEntryRow>
        query = select(updateFeedEntries);
    if (kinds.isNotEmpty) {
      query.where((t) => t.kind.isIn(kinds));
    }
    if (unseenOnly) {
      query.where((t) => t.seenAt.isNull());
    }
    query
      ..orderBy(<OrderingTerm Function($UpdateFeedEntriesTable)>[
        (t) => OrderingTerm(
            expression: t.discoveredAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.entryId),
      ])
      ..limit(limit);
    return query.get();
  }

  /// 按身份取一条（系统通知点击回流用：通知载荷只带 entryId，落点从这里还原）。
  Future<UpdateFeedEntryRow?> getUpdateFeedEntry(String entryId) =>
      (select(updateFeedEntries)..where((t) => t.entryId.equals(entryId)))
          .getSingleOrNull();

  /// 把指定条目标记为已读（幂等：已读的行不再改写 seenAt，保留第一次看见的时刻）。
  Future<int> markUpdateFeedEntriesSeen(
    Iterable<String> entryIds, {
    required int seenAt,
  }) {
    final List<String> ids = entryIds.toList(growable: false);
    if (ids.isEmpty) return Future<int>.value(0);
    return (update(updateFeedEntries)
          ..where((t) => t.entryId.isIn(ids) & t.seenAt.isNull()))
        .write(UpdateFeedEntriesCompanion(seenAt: Value<int?>(seenAt)));
  }

  /// 全部标记已读；[kind] 非空时只标该域。
  Future<int> markAllUpdateFeedSeen({String? kind, required int seenAt}) {
    final UpdateStatement<$UpdateFeedEntriesTable, UpdateFeedEntryRow> stmt =
        update(updateFeedEntries)..where((t) => t.seenAt.isNull());
    if (kind != null) {
      stmt.where((t) => t.kind.equals(kind));
    }
    return stmt.write(UpdateFeedEntriesCompanion(seenAt: Value<int?>(seenAt)));
  }

  Future<int> deleteUpdateFeedEntries(Iterable<String> entryIds) {
    final List<String> ids = entryIds.toList(growable: false);
    if (ids.isEmpty) return Future<int>.value(0);
    return (delete(updateFeedEntries)..where((t) => t.entryId.isIn(ids))).go();
  }

  /// 清掉**已读且早于** [seenBefore] 的条目。未读的一条不动——用户还没看见的提醒
  /// 不能因为「太老」被悄悄抹掉（订阅的番半年没看，那条新集提醒依然有效）。
  Future<int> pruneSeenUpdateFeedEntries({required int seenBefore}) =>
      (delete(updateFeedEntries)
            ..where((t) => t.seenAt.isNotNull() & t.seenAt.isSmallerThanValue(seenBefore)))
          .go();

  /// 「更新流变了」的信号流（不带行）。长驻页面的 initState 订阅必须用它而不是裸
  /// `select(...).watch()`：drift 的 QueryStream 取消时会排一个 `Timer.run`，widget
  /// 测试里页面 dispose 后它仍 pending，任何「构建再卸载」的用例都会红（BUG-834）。
  Stream<void> watchUpdateFeedChanged() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub = tableUpdates(
          TableUpdateQuery
              .onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            updateFeedEntries,
          ]),
        ).listen((_) {
          if (!controller.isClosed) controller.add(null);
        });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }
}
