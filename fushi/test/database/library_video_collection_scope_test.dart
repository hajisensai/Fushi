import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_privacy.dart';
import 'package:test/test.dart';

/// 启动后切模块掉帧：追踪补发（私密快照、未关联清单）与来源刮削计划每次都把
/// `media_collection_items` 整表读进 UI isolate。媒体服务器镜像的播放列表成员
/// 动辄数万行，启动期间被反复触发，整段时间 UI 线程每秒被堵几百毫秒。
///
/// 这些调用方只按库内视频 / 私密合集回答问题：这里钉住缩小后的查询口径——只读
/// 与问题相关的合集，且答案与整表时一致。
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> video(String uid) => db
      .into(db.videoBooks)
      .insert(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          videoPath: '/v/$uid.mkv',
          importedAt: const Value<int?>(0),
        ),
      );

  Future<int> playlist(String name, List<String> members) async {
    final int id = await db.createMediaCollection(name);
    for (final String m in members) {
      await db.addToCollection(id, MediaKind.video, m);
    }
    return id;
  }

  group('含库内视频的合集', () {
    test('只取含库内视频的合集，但取它们的全部成员', () async {
      await video('local1');
      await video('local2');
      final int mixed = await playlist('本机 + 别的', <String>[
        'local1',
        'remote-a',
      ]);
      await db.addToCollection(mixed, MediaKind.epub, 'book-uid');
      final int local = await playlist('只有本机', <String>['local2']);
      // 媒体服务器镜像过来的播放列表：成员键不是库内视频。
      await playlist('镜像', <String>['remote-b', 'remote-c', 'remote-d']);
      await db.createMediaCollection('空合集');

      final List<MediaCollectionItemRow> items = await db
          .getCollectionItemsOfLibraryVideos();
      expect(
        items.map((MediaCollectionItemRow r) => (r.collectionId, r.entryKey)),
        unorderedEquals(<(int, String)>[
          (mixed, 'local1'),
          (mixed, 'remote-a'),
          (mixed, 'book-uid'),
          (local, 'local2'),
        ]),
      );
      // 排序口径同 getAllCollectionItems：同一合集的行连续。
      expect(
        items.map((MediaCollectionItemRow r) => r.collectionId).toList(),
        (await db.getAllCollectionItems())
            .map((MediaCollectionItemRow r) => r.collectionId)
            .where(<int>{mixed, local}.contains)
            .toList(),
      );

      expect(
        (await db.getCollectionsOfLibraryVideos()).map(
          (MediaCollectionRow r) => r.id,
        ),
        unorderedEquals(<int>[mixed, local]),
      );
    });

    test('书条目同键不算库内视频', () async {
      await video('k');
      final int c = await db.createMediaCollection('书');
      await db.addToCollection(c, MediaKind.epub, 'k');
      expect(await db.getCollectionItemsOfLibraryVideos(), isEmpty);
      expect(await db.getCollectionsOfLibraryVideos(), isEmpty);
    });
  });

  test('指定视频所在合集：全部成员，别的合集不读', () async {
    final int a = await playlist('甲', <String>['x', 'remote-1']);
    final int b = await playlist('乙', <String>['y']);
    await playlist('丙', <String>['z', 'remote-2']);
    final List<MediaCollectionItemRow> items = await db
        .getCollectionItemsOfVideos(<String>['x', 'y', 'nobody']);
    expect(
      items.map((MediaCollectionItemRow r) => (r.collectionId, r.entryKey)),
      unorderedEquals(<(int, String)>[(a, 'x'), (a, 'remote-1'), (b, 'y')]),
    );
    expect(await db.getCollectionItemsOfVideos(const <String>[]), isEmpty);
  });

  test('按种类取主归属 / 成员：与全量结果里同种类的部分一致', () async {
    final int first = await playlist('先', <String>['v']);
    await db.addToCollection(first, MediaKind.epub, 'b');
    final int second = await db.createMediaCollection('后');
    await db.addToCollection(second, MediaKind.epub, 'b');
    await db.addToCollection(second, MediaKind.game, 'g');
    await db.addToCollection(second, MediaKind.srt, 's');

    const Set<MediaKind> kinds = <MediaKind>{MediaKind.epub, MediaKind.srt};
    final Map<String, int> all = await db.getPrimaryCollectionIdByEntry();
    expect(await db.getPrimaryCollectionIdByEntry(kinds: kinds), <String, int>{
      for (final MapEntry<String, int> e in all.entries)
        if (e.key.startsWith('epub|') || e.key.startsWith('srt|'))
          e.key: e.value,
    });
    expect(all['epub|b'], first);

    final List<MediaCollectionItemRow> scoped = await db
        .getCollectionItemsOfKinds(kinds);
    expect(
      scoped.map((MediaCollectionItemRow r) => (r.collectionId, r.entryKey)),
      <(int, String)>[
        for (final MediaCollectionItemRow r in await db.getAllCollectionItems())
          if (r.mediaType == 'epub' || r.mediaType == 'srt')
            (r.collectionId, r.entryKey),
      ],
    );
  });

  group('私密快照只读私密合集的成员', () {
    Future<void> markPrivateCollection(int id) => db.setMediaPrivate(
      TagHostKind.collection,
      collectionTagEntryKey(id),
      true,
    );

    test('合集级视频追踪：合集被标 / 成员自身私密 / 成员在别的私密合集里', () async {
      for (final String v in <String>['a', 'b', 'c', 'd', 'e']) {
        await video(v);
      }
      final int marked = await playlist('被标', <String>['a']);
      await markPrivateCollection(marked);
      final int withPrivateMember = await playlist('含私密集', <String>['b', 'c']);
      await db.setMediaPrivate(TagHostKind.video, 'b', true);
      final int carrier = await playlist('私密载体', <String>['d']);
      await markPrivateCollection(carrier);
      final int sharesCarried = await playlist('共享成员', <String>['d', 'e']);
      final int public = await playlist('公开', <String>['c', 'e']);

      final MediaPrivacySnapshot snap = await MediaPrivacySnapshot.load(db);
      expect(snap.isVideoCollectionPrivate(marked), isTrue);
      expect(snap.isVideoCollectionPrivate(withPrivateMember), isTrue);
      expect(snap.isVideoCollectionPrivate(carrier), isTrue);
      expect(snap.isVideoCollectionPrivate(sharesCarried), isTrue);
      expect(snap.isVideoCollectionPrivate(public), isFalse);

      expect(snap.isVideoPrivate('a'), isTrue);
      expect(snap.isVideoPrivate('b'), isTrue);
      expect(snap.isVideoPrivate('d'), isTrue);
      expect(snap.isVideoPrivate('c'), isFalse);
      expect(snap.isVideoPrivate('e'), isFalse);
    });

    test('没有任何私密标记：合集不私密', () async {
      await video('a');
      final int c = await playlist('公开', <String>['a', 'remote']);
      final MediaPrivacySnapshot snap = await MediaPrivacySnapshot.load(db);
      expect(snap.isEmpty, isTrue);
      expect(snap.isVideoCollectionPrivate(c), isFalse);
      expect(snap.isVideoPrivate('a'), isFalse);
    });
  });
}
