// 合集同步的「自动清理」删除（BUG-5601 PR2，schema v183 / wire 可选字段 autoPruned）：
// 往返与旧清单兼容、双死合并、带 pinned 的活合集否决、多份对端折叠、落库镜像。
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:test/test.dart';

const String _type = 'playlist';

CollectionManifestEntry _dead(
  String name,
  int at, {
  int? publishedAt,
  bool autoPruned = false,
}) => CollectionManifestEntry(
  name: name,
  collectionType: _type,
  deletedAt: at,
  deletedPublishedAt: publishedAt,
  autoPruned: autoPruned,
);

CollectionManifestEntry _alive(String name, {bool pinned = false}) =>
    CollectionManifestEntry(
      name: name,
      collectionType: _type,
      origin: 'user',
      members: <CollectionManifestMember>[
        const CollectionManifestMember(
          mediaType: 'video',
          entryKey: 'e1',
          sortIndex: 0,
        ),
        CollectionManifestMember(
          mediaType: 'video',
          entryKey: 'e2',
          sortIndex: 1,
          pinned: pinned,
        ),
      ],
    );

CollectionManifest _m(List<CollectionManifestEntry> e, {int writtenAt = 0}) =>
    CollectionManifest(collections: e, lastWrittenAt: writtenAt);

CollectionManifestEntry? _one(CollectionManifest m, String name) {
  for (final CollectionManifestEntry e in m.collections) {
    if (e.name == name) return e;
  }
  return null;
}

CollectionManifestEntry _merge(
  CollectionManifestEntry? local,
  CollectionManifestEntry? remote, {
  int baseline = 100,
}) {
  final CollectionSyncOutcome out = CollectionSyncEngine.merge(
    local: _m(<CollectionManifestEntry>[?local]),
    remote: _m(<CollectionManifestEntry>[?remote]),
    lastSyncedAtMs: baseline,
    nowMs: 1000,
  );
  return _one(out.merged, (local ?? remote)!.name)!;
}

void main() {
  group('wire', () {
    test('autoPruned 往返；false 不写 key；旧清单缺字段按 false；不升版本', () {
      final Map<String, dynamic> j = _dead('X', 5, autoPruned: true).toJson();
      expect(j['autoPruned'], isTrue);
      expect(CollectionManifestEntry.fromJson(j).autoPruned, isTrue);
      expect(_dead('X', 5).toJson().containsKey('autoPruned'), isFalse);
      final CollectionManifestEntry legacy =
          CollectionManifestEntry.fromJson(<String, dynamic>{
            'name': 'X',
            'collectionType': _type,
            'orderUpdatedAt': 0,
            'deletedAt': 5,
            'members': <Object?>[],
            'memberTombstones': <Object?>[],
          });
      expect(legacy.autoPruned, isFalse);
      expect(CollectionManifest.currentVersion, 1);
    });
  });

  group('双死合并', () {
    test('deletedAt 取新，标记跟着较新的那条走', () {
      final CollectionManifestEntry a = _merge(
        _dead('X', 200, autoPruned: true),
        _dead('X', 300, publishedAt: 300),
      );
      expect(a.deletedAt, 300);
      expect(a.autoPruned, isFalse);
      final CollectionManifestEntry b = _merge(
        _dead('X', 200),
        _dead('X', 300, publishedAt: 300, autoPruned: true),
      );
      expect(b.autoPruned, isTrue);
    });

    test('deletedAt 相同取或（旧客户端转发丢了字段）', () {
      expect(
        _merge(
          _dead('X', 200, autoPruned: true),
          _dead('X', 200, publishedAt: 210),
        ).autoPruned,
        isTrue,
      );
      expect(
        _merge(
          _dead('X', 200),
          _dead('X', 200, publishedAt: 210, autoPruned: true),
        ).autoPruned,
        isTrue,
      );
    });
  });

  group('否决：带 pinned 成员的活合集压过自动清理', () {
    test('本端活且钉住 / 对端自动清理（新闻）⇒ 活', () {
      final CollectionManifestEntry r = _merge(
        _alive('X', pinned: true),
        _dead('X', 500, publishedAt: 500, autoPruned: true),
      );
      expect(r.deletedAt, isNull);
      expect(
        r.members.map((CollectionManifestMember m) => m.entryKey),
        <String>['e1', 'e2'],
      );
      expect(r.members.last.pinned, isTrue);
    });

    test('本端自动清理（未发布）/ 对端活且钉住 ⇒ 活', () {
      final CollectionManifestEntry r = _merge(
        _dead('X', 500, autoPruned: true),
        _alive('X', pinned: true),
      );
      expect(r.deletedAt, isNull);
    });

    test('没有钉住的成员 ⇒ 自动清理照常生效（标记保留）', () {
      final CollectionManifestEntry a = _merge(
        _alive('X'),
        _dead('X', 500, publishedAt: 500, autoPruned: true),
      );
      expect(a.deletedAt, 500);
      expect(a.autoPruned, isTrue);
      final CollectionManifestEntry b = _merge(
        _dead('X', 500, autoPruned: true),
        _alive('X'),
      );
      expect(b.deletedAt, 500);
      expect(b.autoPruned, isTrue);
    });

    test('用户删除不受 pinned 影响', () {
      expect(
        _merge(
          _alive('X', pinned: true),
          _dead('X', 500, publishedAt: 500),
        ).deletedAt,
        500,
      );
      expect(_merge(_dead('X', 500), _alive('X', pinned: true)).deletedAt, 500);
    });

    test('旧闻语义不变：已发布过的自动清理遇到活合集 ⇒ 活', () {
      expect(
        _merge(
          _alive('X'),
          _dead('X', 50, publishedAt: 50, autoPruned: true),
        ).deletedAt,
        isNull,
      );
    });
  });

  group('多份对端折叠（combinePeers）', () {
    test('任一份活文件钉住了成员 ⇒ 自动清理被否决', () {
      final CollectionManifest folded = CollectionSyncEngine.combinePeers(
        <CollectionManifest>[
          _m(<CollectionManifestEntry>[
            _alive('X', pinned: true),
          ], writtenAt: 5),
          _m(<CollectionManifestEntry>[
            _dead('X', 10, publishedAt: 10, autoPruned: true),
          ], writtenAt: 20),
        ],
      );
      expect(_one(folded, 'X')!.deletedAt, isNull);
    });

    test('没钉住 ⇒ 删除胜，标记保留；用户删除不被 pinned 否决', () {
      final CollectionManifest a = CollectionSyncEngine.combinePeers(
        <CollectionManifest>[
          _m(<CollectionManifestEntry>[_alive('X')], writtenAt: 5),
          _m(<CollectionManifestEntry>[
            _dead('X', 10, publishedAt: 10, autoPruned: true),
          ], writtenAt: 20),
        ],
      );
      expect(_one(a, 'X')!.deletedAt, 10);
      expect(_one(a, 'X')!.autoPruned, isTrue);
      final CollectionManifest b = CollectionSyncEngine.combinePeers(
        <CollectionManifest>[
          _m(<CollectionManifestEntry>[
            _alive('X', pinned: true),
          ], writtenAt: 5),
          _m(<CollectionManifestEntry>[
            _dead('X', 10, publishedAt: 10),
          ], writtenAt: 20),
        ],
      );
      expect(_one(b, 'X')!.deletedAt, 10);
      expect(_one(b, 'X')!.autoPruned, isFalse);
    });

    test('双死：较新的说了算，平手取或', () {
      CollectionManifestEntry fold(List<CollectionManifestEntry> deads) => _one(
        CollectionSyncEngine.combinePeers(<CollectionManifest>[
          for (final CollectionManifestEntry d in deads)
            _m(<CollectionManifestEntry>[d], writtenAt: 30),
        ]),
        'X',
      )!;
      expect(
        fold(<CollectionManifestEntry>[
          _dead('X', 10, publishedAt: 10, autoPruned: true),
          _dead('X', 20, publishedAt: 20),
        ]).autoPruned,
        isFalse,
      );
      expect(
        fold(<CollectionManifestEntry>[
          _dead('X', 20, publishedAt: 20),
          _dead('X', 20, publishedAt: 21, autoPruned: true),
        ]).autoPruned,
        isTrue,
      );
    });
  });

  group('落库', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('对端的自动清理删除镜像成带 auto_pruned 的哨兵；本地缺标记时补上', () async {
      final int id = await db.createMediaCollection('X', collectionType: _type);
      await db.addToCollection(id, MediaKind.video, 'e1', userIntent: false);
      CollectionSyncOutcome out = CollectionSyncEngine.merge(
        local: await loadLocalCollectionManifest(db),
        remote: _m(<CollectionManifestEntry>[
          _dead('X', 500, publishedAt: 500, autoPruned: true),
        ]),
        lastSyncedAtMs: 100,
        nowMs: 1000,
      );
      await applyCollectionLocalChanges(db, out.changes);
      expect(await db.getMediaCollectionByNaturalKey('X', _type), isNull);
      List<CollectionMemberTombstoneRow> rows = await db
          .getAllCollectionMemberTombstones();
      expect(rows.single.autoPruned, isTrue);

      // 旧客户端写来的同一次删除（同 deletedAt、没有标记）：本地降级成 false 后，
      // 再遇到带标记的那份，合并取或，本地补回 true。
      await db.customStatement(
        'UPDATE collection_member_tombstones SET auto_pruned = 0',
      );
      out = CollectionSyncEngine.merge(
        local: await loadLocalCollectionManifest(db),
        remote: _m(<CollectionManifestEntry>[
          _dead('X', 500, publishedAt: 500, autoPruned: true),
        ]),
        lastSyncedAtMs: 1000,
        nowMs: 2000,
      );
      expect(out.changes.isEmpty, isFalse);
      await applyCollectionLocalChanges(db, out.changes);
      rows = await db.getAllCollectionMemberTombstones();
      expect(rows.single.autoPruned, isTrue);
    });

    test('本机清理的删除发布时盖戳、标记不丢', () async {
      await db.upsertCollectionMemberTombstone(
        collectionName: 'X',
        collectionType: _type,
        mediaType: FushiDatabase.collectionTombstoneSentinel,
        entryKey: FushiDatabase.collectionTombstoneSentinel,
        deletedAt: 500,
        autoPruned: true,
      );
      final CollectionSyncOutcome out = CollectionSyncEngine.merge(
        local: await loadLocalCollectionManifest(db),
        remote: CollectionManifest.empty,
        lastSyncedAtMs: 100,
        nowMs: 1000,
      );
      final CollectionManifestEntry e = _one(out.merged, 'X')!;
      expect(e.deletedPublishedAt, 1000);
      expect(e.autoPruned, isTrue);
    });
  });
}
