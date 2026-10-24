import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/web_browser/data/drift_web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';

/// v128 内置浏览器历史 / 书签经聚合快照跨端同步 + 删除墓碑传播。
WebHistoryRecord _h(
  String url, {
  required int at,
  int count = 1,
  String title = '',
}) => WebHistoryRecord(
  url: url,
  title: title,
  lastVisitedAt: at,
  visitCount: count,
);

WebBookmarkRecord _b(
  String uid, {
  required int updatedAt,
  String? url = 'https://x/',
  String? parentUid,
  String title = 't',
}) => WebBookmarkRecord(
  uid: uid,
  title: title,
  url: url,
  parentUid: parentUid,
  position: 0,
  createdAt: 1,
  updatedAt: updatedAt,
);

void main() {
  group('mergeSnapshots（纯函数）', () {
    test('历史按 url 并集：次数取大、最近访问取大、标题跟较新访问', () {
      final AggregateSnapshot merged = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webHistory: <WebHistoryRecord>[
            _h('https://a/', at: 100, count: 5, title: 'old'),
            _h('https://only-local/', at: 1),
          ],
        ),
        AggregateSnapshot(
          webHistory: <WebHistoryRecord>[
            _h('https://a/', at: 200, count: 2, title: 'new'),
          ],
        ),
      );
      final Map<String, WebHistoryRecord> byUrl = <String, WebHistoryRecord>{
        for (final WebHistoryRecord r in merged.webHistory) r.url: r,
      };
      expect(
        byUrl.keys,
        unorderedEquals(<String>['https://a/', 'https://only-local/']),
      );
      expect(byUrl['https://a/']!.visitCount, 5);
      expect(byUrl['https://a/']!.lastVisitedAt, 200);
      expect(byUrl['https://a/']!.title, 'new');
    });

    test('合并可交换', () {
      final AggregateSnapshot l = AggregateSnapshot(
        webHistory: <WebHistoryRecord>[_h('https://a/', at: 100, title: 'x')],
        webBookmarks: <WebBookmarkRecord>[_b('u', updatedAt: 5, title: 'L')],
      );
      final AggregateSnapshot r = AggregateSnapshot(
        webHistory: <WebHistoryRecord>[_h('https://a/', at: 100, title: 'y')],
        webBookmarks: <WebBookmarkRecord>[_b('u', updatedAt: 5, title: 'R')],
      );
      expect(
        AggregateSyncService.unorderedSnapshotFingerprint(
          AggregateSyncService.mergeSnapshots(l, r).toJson(),
        ),
        AggregateSyncService.unorderedSnapshotFingerprint(
          AggregateSyncService.mergeSnapshots(r, l).toJson(),
        ),
      );
    });

    test('历史逐条墓碑：删除晚于访问 → 出局；之后再访问 → 复活、墓碑退场', () {
      final AggregateSnapshot deleted = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webHistory: <WebHistoryRecord>[_h('https://a/', at: 100)],
        ),
        const AggregateSnapshot(
          webHistoryTombstones: <AggregateTombstoneRecord>[
            AggregateTombstoneRecord(itemKey: 'https://a/', deletedAt: 200),
          ],
        ),
      );
      expect(deleted.webHistory, isEmpty);
      expect(deleted.webHistoryTombstones.single.deletedAt, 200);

      final AggregateSnapshot revisited = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webHistory: <WebHistoryRecord>[_h('https://a/', at: 300)],
        ),
        const AggregateSnapshot(
          webHistoryTombstones: <AggregateTombstoneRecord>[
            AggregateTombstoneRecord(itemKey: 'https://a/', deletedAt: 200),
          ],
        ),
      );
      expect(revisited.webHistory, hasLength(1));
      expect(revisited.webHistoryTombstones, isEmpty);
    });

    test('区间墓碑压制 [since, deletedAt) 内的访问且永不退场', () {
      final AggregateSnapshot merged = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webHistory: <WebHistoryRecord>[
            _h('https://before/', at: 50),
            _h('https://inside/', at: 150),
            _h('https://after/', at: 300),
          ],
        ),
        AggregateSnapshot(
          webHistoryTombstones: <AggregateTombstoneRecord>[
            AggregateTombstoneRecord(
              itemKey: webHistoryClearTombstoneKey(100),
              deletedAt: 200,
            ),
          ],
        ),
      );
      expect(
        merged.webHistory.map((WebHistoryRecord r) => r.url),
        unorderedEquals(<String>['https://before/', 'https://after/']),
      );
      expect(
        merged.webHistoryTombstones.single.itemKey,
        webHistoryClearTombstoneKey(100),
      );
    });

    test('书签 uid LWW；墓碑晚于修改 → 出局，修改晚于墓碑 → 保留且墓碑退场', () {
      final AggregateSnapshot lww = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webBookmarks: <WebBookmarkRecord>[
            _b('u1', updatedAt: 10, title: 'old'),
          ],
        ),
        AggregateSnapshot(
          webBookmarks: <WebBookmarkRecord>[
            _b('u1', updatedAt: 20, title: 'new'),
          ],
        ),
      );
      expect(lww.webBookmarks.single.title, 'new');

      final AggregateSnapshot deleted = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webBookmarks: <WebBookmarkRecord>[_b('u1', updatedAt: 10)],
        ),
        const AggregateSnapshot(
          webBookmarkTombstones: <AggregateTombstoneRecord>[
            AggregateTombstoneRecord(itemKey: 'u1', deletedAt: 15),
          ],
        ),
      );
      expect(deleted.webBookmarks, isEmpty);
      expect(deleted.webBookmarkTombstones.single.itemKey, 'u1');

      final AggregateSnapshot edited = AggregateSyncService.mergeSnapshots(
        AggregateSnapshot(
          webBookmarks: <WebBookmarkRecord>[_b('u1', updatedAt: 30)],
        ),
        const AggregateSnapshot(
          webBookmarkTombstones: <AggregateTombstoneRecord>[
            AggregateTombstoneRecord(itemKey: 'u1', deletedAt: 15),
          ],
        ),
      );
      expect(edited.webBookmarks, hasLength(1));
      expect(edited.webBookmarkTombstones, isEmpty);
    });

    test('json 往返 + 旧端缺键回退空 + select(favorites:false) 整族置空', () {
      final AggregateSnapshot s = AggregateSnapshot(
        webHistory: <WebHistoryRecord>[
          _h('https://a/', at: 1, count: 3, title: 'A'),
        ],
        webBookmarks: <WebBookmarkRecord>[
          _b('f', updatedAt: 1, url: null),
          _b('c', updatedAt: 2, parentUid: 'f'),
        ],
        webHistoryTombstones: const <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: 'https://gone/', deletedAt: 9),
        ],
        webBookmarkTombstones: const <AggregateTombstoneRecord>[
          AggregateTombstoneRecord(itemKey: 'x', deletedAt: 9),
        ],
      );
      expect(s.isEmpty, isFalse);
      final AggregateSnapshot back = AggregateSnapshot.fromJson(s.toJson());
      expect(back.webHistory.single.visitCount, 3);
      expect(back.webBookmarks.first.url, isNull);
      expect(back.webBookmarks.last.parentUid, 'f');
      expect(back.webHistoryTombstones.single.itemKey, 'https://gone/');
      expect(back.webBookmarkTombstones.single.itemKey, 'x');

      final AggregateSnapshot old = AggregateSnapshot.fromJson(
        <String, Object?>{'version': 1},
      );
      expect(old.webHistory, isEmpty);
      expect(old.webBookmarks, isEmpty);

      // 书签归收藏族：收藏关掉时书签（连墓碑）置空，历史不受收藏开关影响。
      final AggregateSnapshot noFav = s.select(
        stats: true,
        favorites: false,
        webHistory: true,
      );
      expect(noFav.webHistory, hasLength(1));
      expect(noFav.webHistoryTombstones, hasLength(1));
      expect(noFav.webBookmarks, isEmpty);
      expect(noFav.webBookmarkTombstones, isEmpty);

      // 历史自成一族（设备级「同步浏览历史」，默认关）：已开共享收藏也不外流。
      final AggregateSnapshot noHistory = s.select(
        stats: true,
        favorites: true,
        webHistory: false,
      );
      expect(noHistory.webHistory, isEmpty);
      expect(noHistory.webHistoryTombstones, isEmpty);
      expect(noHistory.webBookmarks, hasLength(2));
      expect(noHistory.webBookmarkTombstones, hasLength(1));
    });
  });

  group('两台设备端到端（materialize → merge → apply）', () {
    late FushiDatabase dbA;
    late FushiDatabase dbB;
    late DriftWebBrowserStore storeA;
    late DriftWebBrowserStore storeB;
    late int now;
    int seq = 0;

    setUp(() {
      dbA = FushiDatabase.forTesting(NativeDatabase.memory());
      dbB = FushiDatabase.forTesting(NativeDatabase.memory());
      now = 1000;
      DateTime clock() => DateTime.fromMillisecondsSinceEpoch(now);
      storeA = DriftWebBrowserStore(
        dbA,
        clock: clock,
        newUid: () => 'a${seq++}',
      );
      storeB = DriftWebBrowserStore(
        dbB,
        clock: clock,
        newUid: () => 'b${seq++}',
      );
    });
    tearDown(() async {
      storeA.dispose();
      storeB.dispose();
      await dbA.close();
      await dbB.close();
    });

    /// 一轮双向同步：两侧 materialize、合并，各自落地合并结果。
    Future<void> syncRound() async {
      final AggregateSyncService a = AggregateSyncService(dbA);
      final AggregateSyncService b = AggregateSyncService(dbB);
      final AggregateSnapshot merged = AggregateSyncService.mergeSnapshots(
        await a.materializeLocalSnapshot(),
        await b.materializeLocalSnapshot(),
      );
      await a.foldIntoLocal(merged);
      await b.foldIntoLocal(merged);
    }

    test('书签文件夹树与历史传到对端，父子关系按 uid 还原', () async {
      final int folder = await storeA.addFolder(title: 'Folder');
      await storeA.addBookmark(
        title: 'Child',
        url: Uri.parse('https://child/'),
        parentId: folder,
      );
      await storeA.recordVisit(url: Uri.parse('https://h/'), title: 'H');
      await storeB.recordVisit(url: Uri.parse('https://h/'), title: 'H');
      await storeB.recordVisit(url: Uri.parse('https://h/'), title: 'H');

      await syncRound();

      final List<WebBrowserBookmark> rootB = await storeB.bookmarks();
      expect(rootB.single.title, 'Folder');
      expect(rootB.single.isFolder, isTrue);
      expect(
        (await storeB.bookmarks(parentId: rootB.single.id)).single.title,
        'Child',
      );
      expect((await storeA.history()).single.visitCount, 2);
      expect((await storeB.history()).single.visitCount, 2);

      // 幂等：再来一轮不改变任何东西。
      await syncRound();
      expect(await dbB.getAllWebBrowserBookmarks(), hasLength(2));
      expect((await storeB.history()).single.visitCount, 2);
    });

    test('A 删文件夹 → B 上整棵树消失；A 清除历史 → B 上被清掉', () async {
      final int folder = await storeA.addFolder(title: 'Folder');
      await storeA.addBookmark(
        title: 'Child',
        url: Uri.parse('https://child/'),
        parentId: folder,
      );
      await storeA.addBookmark(title: 'Keep', url: Uri.parse('https://keep/'));
      now = 1500;
      await storeA.recordVisit(url: Uri.parse('https://h/'), title: 'H');
      await syncRound();
      expect(await dbB.getAllWebBrowserBookmarks(), hasLength(3));
      expect(await storeB.history(), hasLength(1));

      now = 2000;
      await storeA.deleteBookmark(folder);
      await storeA.clearHistory();
      await syncRound();

      expect((await storeB.bookmarks()).single.title, 'Keep');
      expect(await dbB.getAllWebBrowserBookmarks(), hasLength(1));
      expect(await storeB.history(), isEmpty);
      // 墓碑落到 B 并继续随 B 的快照上行（第三台设备也能收到）。
      final AggregateSnapshot fromB = await AggregateSyncService(
        dbB,
      ).materializeLocalSnapshot();
      expect(fromB.webBookmarkTombstones, hasLength(2));
      expect(
        fromB.webHistoryTombstones.single.itemKey,
        webHistoryClearTombstoneKey(0),
      );

      // B 在删除之后重新访问 → 复活并传回 A。
      now = 3000;
      await storeB.recordVisit(url: Uri.parse('https://h/'), title: 'H');
      await syncRound();
      expect(
        (await storeA.history()).single.lastVisitedAt.millisecondsSinceEpoch,
        3000,
      );
    });

    test('上行裁剪：本机墓碑压制的条目不随 filterTombstoned 上行', () async {
      await storeA.recordVisit(url: Uri.parse('https://a/'), title: 'A');
      now = 2000;
      await storeA.clearHistory();
      final AggregateSyncService svc = AggregateSyncService(dbA);
      final AggregateSnapshot filtered = await svc.filterTombstoned(
        AggregateSnapshot(
          webHistory: <WebHistoryRecord>[
            _h('https://a/', at: 1000),
            _h('https://late/', at: 2500),
          ],
        ),
      );
      expect(filtered.webHistory.single.url, 'https://late/');
    });
  });
}
