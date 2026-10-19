import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_privacy.dart';

/// v122 私密标记：成员的私密可以只是「在私密合集里」继承来的。合集被删 / 合并解散 /
/// 拆分（含刮削后台自动做的 AniDB 拆分）/ 成员被移出时，继承随成员关系消失——
/// 这些路径必须先把私密落到成员自己身上，否则作品会在下一轮排行榜上传、Bangumi
/// 推送里静默变回公开（fail-open）。
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String> book(String key) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/x/$key.epub',
        extractDir: '/x/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
      ),
    );
    return (await db.getEpubBook(key))!.uid;
  }

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

  Future<int> privateCollection(String name) async {
    final int id = await db.createMediaCollection(name);
    await db.setMediaPrivate(
      TagHostKind.collection,
      collectionTagEntryKey(id),
      true,
    );
    return id;
  }

  test('删除私密合集：成员（书按 uid 入合集、视频）各自落私密', () async {
    final String uid = await book('B');
    await video('v1');
    final int c = await privateCollection('秘');
    await db.addToCollection(c, MediaKind.epub, uid);
    await db.addToCollection(c, MediaKind.video, 'v1');

    MediaPrivacySnapshot snap = await MediaPrivacySnapshot.load(db);
    expect(snap.isBookPrivate('B'), isTrue);
    expect(snap.isVideoPrivate('v1'), isTrue);
    expect(await db.isMediaPrivate(TagHostKind.epub, 'B'), isFalse);

    await db.deleteMediaCollection(c);

    // 落在 bookKey 域（私密标记与排行榜 / 追踪的键），不是成员行的 uid 域。
    expect(await db.isMediaPrivate(TagHostKind.epub, 'B'), isTrue);
    expect(await db.isMediaPrivate(TagHostKind.epub, uid), isFalse);
    expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isTrue);
    snap = await MediaPrivacySnapshot.load(db);
    expect(snap.isBookPrivate('B'), isTrue);
    expect(snap.isVideoPrivate('v1'), isTrue);
  });

  test('从私密合集移出成员：被移出的那个落私密', () async {
    await video('v1');
    await video('v2');
    final int c = await privateCollection('剧');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');

    await db.removeFromCollection(c, MediaKind.video, 'v1');

    expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isTrue);
    // 还在合集里的照旧靠继承，不额外写行。
    expect(await db.isMediaPrivate(TagHostKind.video, 'v2'), isFalse);
    expect((await MediaPrivacySnapshot.load(db)).isVideoPrivate('v2'), isTrue);
  });

  test('同步应用端原样删合集（deleteMediaCollectionRaw）同样落私密', () async {
    await video('v1');
    final int c = await privateCollection('镜');
    await db.addToCollection(c, MediaKind.video, 'v1');

    await db.deleteMediaCollectionRaw(c);

    expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isTrue);
  });

  test('非私密合集被删：成员不受影响；成员已私密时不推进时钟', () async {
    await video('v1');
    await video('v2');
    final int open = await db.createMediaCollection('公开');
    await db.addToCollection(open, MediaKind.video, 'v1');
    await db.deleteMediaCollection(open);
    expect(await db.isMediaPrivate(TagHostKind.video, 'v1'), isFalse);

    await db.setMediaPrivate(TagHostKind.video, 'v2', true, at: 5);
    final int c = await privateCollection('秘');
    await db.addToCollection(c, MediaKind.video, 'v2');
    await db.deleteMediaCollection(c);
    expect(await db.mediaPrivacyClock(TagHostKind.video, 'v2'), (
      privateAt: 5,
      clearedAt: null,
    ));
  });
}
