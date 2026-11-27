import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-5597：「本机一个成员都没有」的合集判据只看本机条目表（成员种类各自的表），
/// 与库页的筛选 / 上锁 / 折叠归属无关。
void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> collection(String name, List<(MediaKind, String)> members) async {
    final int id = await db.createMediaCollection(name);
    for (final (MediaKind kind, String key) in members) {
      await db.addToCollection(id, kind, key);
    }
    return id;
  }

  test('各成员种类按本机条目表判；有一个在本机就不算', () async {
    await db
        .into(db.epubBooks)
        .insert(
          EpubBooksCompanion.insert(
            bookKey: 'Book A',
            title: 'Book A',
            epubPath: '/tmp/a.epub',
            extractDir: '/tmp/a',
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: 1,
          ),
        );
    final String uid = (await db.resolveEpubBookUid('Book A'))!;
    await db
        .into(db.srtBooks)
        .insert(
          SrtBooksCompanion.insert(
            uid: 'srt-1',
            title: 's',
            srtPath: '/tmp/s.srt',
            importedAt: 1,
          ),
        );
    await db
        .into(db.videoBooks)
        .insert(
          VideoBooksCompanion.insert(
            bookUid: 'video/v1',
            title: 'v',
            videoPath: '/tmp/v.mkv',
          ),
        );
    await db
        .into(db.galgames)
        .insert(
          GalgamesCompanion.insert(
            id: 'g1',
            name: 'g',
            exePath: '/tmp/g.exe',
            workdir: '/tmp',
            addedAt: 1,
          ),
        );

    final int byUid = await collection('uid', <(MediaKind, String)>[
      (MediaKind.epub, uid),
    ]);
    final int byBookKey = await collection('bookKey', <(MediaKind, String)>[
      (MediaKind.epub, 'Book A'),
    ]);
    final int mixed = await collection('mixed', <(MediaKind, String)>[
      (MediaKind.epub, 'elsewhere 1'),
      (MediaKind.srt, 'srt-1'),
    ]);
    final int video = await collection('video', <(MediaKind, String)>[
      (MediaKind.video, 'video/v1'),
    ]);
    final int game = await collection('game', <(MediaKind, String)>[
      (MediaKind.game, 'g1'),
    ]);
    final int remoteBooks = await collection('remote', <(MediaKind, String)>[
      (MediaKind.epub, 'elsewhere 1'),
      (MediaKind.epub, 'elsewhere 2'),
      (MediaKind.srt, 'srt-elsewhere'),
    ]);
    final int remoteVideo = await collection('rv', <(MediaKind, String)>[
      (MediaKind.video, 'e01KPS000BSQ3ER953WBZ1D1JZ3'),
    ]);
    final int remoteGame = await collection('rg', <(MediaKind, String)>[
      (MediaKind.game, 'g-elsewhere'),
    ]);
    await db.createMediaCollection('empty');

    final Map<int, int> all = await db.getCollectionsWithoutLocalMembers();
    expect(all, <int, int>{remoteBooks: 3, remoteVideo: 1, remoteGame: 1});
    for (final int id in <int>[byUid, byBookKey, mixed, video, game]) {
      expect(all.containsKey(id), isFalse);
    }
    expect(
      await db.getCollectionsWithoutLocalMembers(
        collectionIds: <int>[remoteBooks, mixed],
      ),
      <int, int>{remoteBooks: 3},
    );
    expect(
      await db.getCollectionsWithoutLocalMembers(collectionIds: const <int>[]),
      isEmpty,
    );
  });

  test('含本机不认识的成员种类（对端新版本）的合集不报', () async {
    final int id = await db.createMediaCollection('future');
    await db.addToCollectionRaw(id, 'podcast', 'p1');
    await db.addToCollectionRaw(id, 'epub', 'elsewhere');
    expect(await db.getCollectionsWithoutLocalMembers(), isEmpty);
  });
}
