import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

/// [FushiDatabase.adoptRemoteCollectionMembers]：整份远端清单的差分批量收养。
///
/// 库页每拿到一份新清单都要收养一遍。此前逐条 [FushiDatabase.adoptRemoteCollectionMember]
/// ——每条一个事务，清单没变时也照跑。现在：清单没变 = 一次只读查询、零写入、零事务；
/// 有变化的条目在**一个**事务里走与单条入口同一份规则，结果与逐条收养逐行一致。
void main() {
  late _StatementCounter counter;
  late FushiDatabase db;

  setUp(() async {
    counter = _StatementCounter();
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(counter),
    );
    // 开库迁移的语句不算进各用例。
    await db.customSelect('SELECT 1').get();
    counter.reset();
  });
  tearDown(() => db.close());

  RemoteCollectionMemberAdoption member(
    String id,
    String series,
    int index, {
    String? local,
    String type = 'playlist',
    bool userIntent = false,
  }) => RemoteCollectionMemberAdoption(
    name: series,
    collectionType: type,
    mediaType: MediaKind.video,
    remoteEntryKey: id,
    sortIndex: index,
    localEntryKey: local ?? id,
    userIntent: userIntent,
  );

  final List<RemoteCollectionMemberAdoption> library =
      <RemoteCollectionMemberAdoption>[
        member('a1', 'Show A', 1),
        member('a2', 'Show A', 2),
        member('a3', 'Show A', 3),
        member('b1', 'Show B', 1),
      ];

  test('首轮整批收养：建合集、按 DTO 排序，一个事务', () async {
    expect(await db.adoptRemoteCollectionMembers(library), 4);
    expect(counter.transactions, 1);
    final Map<String, List<String>> members = await _membersByCollection(db);
    expect(members, <String, List<String>>{
      'Show A': <String>['a1', 'a2', 'a3'],
      'Show B': <String>['b1'],
    });
  });

  test('清单没变的第二轮：一次只读查询，零写入、零事务', () async {
    await db.adoptRemoteCollectionMembers(library);
    final String before = await _dump(db);
    counter.reset();

    expect(await db.adoptRemoteCollectionMembers(library), 0);

    expect(counter.selects, 1, reason: '差分只该有一条读');
    expect(counter.writes, 0);
    expect(counter.transactions, 0);
    expect(await _dump(db), before);
  });

  test('只写变了的条目：新集、改了所属系列的集；其余不碰', () async {
    await db.adoptRemoteCollectionMembers(library);
    counter.reset();

    final int written = await db.adoptRemoteCollectionMembers(
      <RemoteCollectionMemberAdoption>[
        member('a1', 'Show A', 1),
        member('a2', 'Show A', 2),
        member('a3', 'Show A', 3),
        // 服务器把 b1 归到了改名后的系列。
        member('b1', 'Show B (2024)', 1),
        member('a4', 'Show A', 4),
      ],
    );

    expect(written, 2);
    expect(counter.transactions, 1);
    final Map<String, List<String>> members = await _membersByCollection(db);
    expect(members['Show A'], <String>['a1', 'a2', 'a3', 'a4']);
    expect(members['Show B (2024)'], <String>['b1']);
    // 收养只加不减：旧系列里的 b1 留着（与单条入口同一语义，移出归完整同步）。
    expect(members['Show B'], <String>['b1']);
  });

  test('与逐条收养逐行一致（墓碑 / 重名合集 / 占位提升 / 手动排序 / userIntent）', () async {
    final FushiDatabase sequential = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(sequential.close);
    for (final FushiDatabase d in <FushiDatabase>[db, sequential]) {
      // 用户删过的合集（合集级墓碑）：被动收养不复活它。
      await d.upsertCollectionMemberTombstone(
        collectionName: 'Deleted',
        deletedAt: 1,
        collectionType: 'playlist',
        mediaType: FushiDatabase.collectionTombstoneSentinel,
        entryKey: FushiDatabase.collectionTombstoneSentinel,
      );
      // 用户从 Show A 里单独移出的一集。
      await d.upsertCollectionMemberTombstone(
        collectionName: 'Show A',
        deletedAt: 1,
        collectionType: 'playlist',
        mediaType: 'video',
        entryKey: 'a9',
      );
      // 重名合集：成员在 id 较大的那一个里，规则认 id 最小的。
      final int primary = await d.createMediaCollection(
        'Dup',
        collectionType: 'playlist',
      );
      final int duplicate = await d
          .into(d.mediaCollections)
          .insert(
            MediaCollectionsCompanion.insert(
              name: 'Dup',
              collectionType: const Value<String>('playlist'),
              createdAt: 1,
            ),
          );
      expect(duplicate, greaterThan(primary));
      await d.addToCollection(
        duplicate,
        MediaKind.video,
        'd1',
        userIntent: false,
      );
      // 手动排过序的合集：新成员尾插，不取 DTO 序。
      final int manual = await d.createMediaCollection(
        'Manual',
        collectionType: 'playlist',
      );
      await d.addToCollection(manual, MediaKind.video, 'm1', userIntent: false);
      await d.setCollectionOrderUpdatedAt(manual, 123);
      // 远端占位行（本机后来下载了这一集，落地键不同）。
      final int promote = await d.createMediaCollection(
        'Promote',
        collectionType: 'playlist',
      );
      await d.upsertCollectionItemAt(promote, 'video', 'wire', 7);
    }
    final List<RemoteCollectionMemberAdoption> requests =
        <RemoteCollectionMemberAdoption>[
          member('x1', 'Deleted', 1),
          member('a9', 'Show A', 9),
          member('a1', 'Show A', 1),
          member('d1', 'Dup', 1),
          member('m2', 'Manual', 0),
          member('m1', 'Manual', 0),
          member('wire', 'Promote', 99, local: 'local-copy'),
          member('u1', 'Deleted', 1, userIntent: true),
        ];

    await db.adoptRemoteCollectionMembers(requests);
    for (final RemoteCollectionMemberAdoption r in requests) {
      await sequential.adoptRemoteCollectionMember(
        name: r.name,
        collectionType: r.collectionType,
        mediaType: r.mediaType,
        remoteEntryKey: r.remoteEntryKey,
        sortIndex: r.sortIndex,
        localEntryKey: r.localEntryKey,
        userIntent: r.userIntent,
      );
    }

    expect(await _dump(db), await _dump(sequential));
    // 抽查几条规则确实生效（不是两边都没写）。
    final Map<String, List<String>> members = await _membersByCollection(db);
    expect(members['Show A'], <String>['a1']);
    expect(members['Promote'], <String>['local-copy']);
    expect(members['Manual'], <String>['m1', 'm2']);
  });

  test('被墓碑挡下的条目每轮重新裁决但不计为写入，也不复活合集', () async {
    await db.upsertCollectionMemberTombstone(
      collectionName: 'Deleted',
      deletedAt: 1,
      collectionType: 'playlist',
      mediaType: FushiDatabase.collectionTombstoneSentinel,
      entryKey: FushiDatabase.collectionTombstoneSentinel,
    );
    counter.reset();
    expect(
      await db.adoptRemoteCollectionMembers(<RemoteCollectionMemberAdoption>[
        member('x1', 'Deleted', 1),
      ]),
      0,
    );
    expect(counter.writes, 0);
    expect(await db.getAllMediaCollections(), isEmpty);
  });

  test('占位提升做完之后，下一轮同一份清单就是零写入', () async {
    final int cid = await db.createMediaCollection(
      'Promote',
      collectionType: 'playlist',
    );
    await db.upsertCollectionItemAt(cid, 'video', 'wire', 7);
    final List<RemoteCollectionMemberAdoption> requests =
        <RemoteCollectionMemberAdoption>[
          member('wire', 'Promote', 7, local: 'local-copy'),
        ];
    expect(await db.adoptRemoteCollectionMembers(requests), 1);
    counter.reset();
    expect(await db.adoptRemoteCollectionMembers(requests), 0);
    expect(counter.writes, 0);
    expect(counter.transactions, 0);
  });

  test('空清单不发任何语句', () async {
    expect(
      await db.adoptRemoteCollectionMembers(
        const <RemoteCollectionMemberAdoption>[],
      ),
      0,
    );
    expect(counter.selects + counter.writes + counter.transactions, 0);
  });
}

/// 合集名 → 有序成员键（只看视频成员）。
Future<Map<String, List<String>>> _membersByCollection(FushiDatabase db) async {
  final Map<String, List<String>> out = <String, List<String>>{};
  for (final MediaCollectionRow c in await db.getAllMediaCollections()) {
    final List<String> keys = <String>[
      for (final MediaCollectionItemRow r in await db.getCollectionItems(c.id))
        r.entryKey,
    ];
    if (keys.isNotEmpty) out[c.name] = keys;
  }
  return out;
}

/// 合集 / 成员 / 墓碑三张表的规范化快照（不含自增 id 与时间戳以外的随机量）。
Future<String> _dump(FushiDatabase db) async {
  final List<String> lines = <String>[];
  for (final QueryRow row
      in await db
          .customSelect(
            'SELECT c.name, c.collection_type, c.sort_order, c.order_updated_at, '
            'i.media_type, i.entry_key, i.sort_index, i.pinned_by_user, '
            '(SELECT COUNT(*) FROM media_collections c2 WHERE c2.name = c.name '
            'AND c2.collection_type = c.collection_type AND c2.id < c.id) AS dup_rank '
            'FROM media_collections c LEFT JOIN media_collection_items i '
            'ON i.collection_id = c.id '
            'ORDER BY c.name, dup_rank, i.media_type, i.entry_key',
          )
          .get()) {
    lines.add(row.data.values.join('|'));
  }
  for (final CollectionMemberTombstoneRow t
      in await db.getAllCollectionMemberTombstones()) {
    lines.add(
      'tomb|${t.collectionName}|${t.collectionType}|${t.mediaType}|${t.entryKey}',
    );
  }
  lines.sort();
  return lines.join('\n');
}

/// 数语句：读 / 写 / 开事务各多少条（含事务内的语句）。
class _StatementCounter extends QueryInterceptor {
  int selects = 0;
  int writes = 0;
  int transactions = 0;

  void reset() {
    selects = 0;
    writes = 0;
    transactions = 0;
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    transactions++;
    return super.beginTransaction(parent);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    writes++;
    return super.runBatched(executor, statements);
  }
}
