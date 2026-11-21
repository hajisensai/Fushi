import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v161：`item_scrape_meta` / `item_images`——单本书 / 漫画 / 字幕书 / 游戏的刮削资料
/// 与横版背景图（2026-11-16 所有者：刮削过的条目都走系列色块）。纯新增建表、幂等；
/// 宿主是逻辑外键，删书 / 删字幕书 / 删游戏在各自事务里清行。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  bool hasTable(sqlite.Database raw, String name) => raw.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    <Object?>[name],
  ).isNotEmpty;

  ItemScrapeMetaCompanion meta(MediaKind kind, String key, {String? summary}) =>
      ItemScrapeMetaCompanion.insert(
        mediaType: kind.dbValue,
        entryKey: key,
        source: 'bangumi',
        subjectId: const Value<String?>('42'),
        summary: Value<String?>(summary),
        rating: const Value<double?>(8.2),
        tagsJson: const Value<String?>('[{"name":"恋爱"}]'),
        scrapedAt: 1,
      );

  test('v160 → v161：建出两张表，存量书行原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'itemscrapev161',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE item_scrape_meta');
    raw.execute('DROP TABLE item_images');
    raw.execute(
      'INSERT INTO srt_books (uid, title, srt_path, imported_at) '
      "VALUES ('s1', 'S', '/abs/s.srt', 1)",
    );
    raw.execute('PRAGMA user_version = 160');
    expect(hasTable(raw, 'item_scrape_meta'), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 166);
    await migrated.upsertItemScrapeMeta(meta(MediaKind.srt, 's1'));
    expect((await migrated.getAllItemScrapeMeta()).single.entryKey, 's1');
    expect(await migrated.getSrtBookByUid('s1'), isNotNull);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 166);
    expect(hasTable(probe, 'item_scrape_meta'), isTrue);
    expect(hasTable(probe, 'item_images'), isTrue);
  });

  test('v161 步幂等：表已在时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'itemscrapev161idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.upsertItemScrapeMeta(
      meta(MediaKind.game, 'g1', summary: 'kept'),
    );
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 160');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await migrated.getItemScrapeMeta(MediaKind.game, 'g1'))?.summary,
      'kept',
    );
    await migrated.close();
  });

  group('DAO', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('upsert 整行覆盖；video 拒收', () async {
      await db.upsertItemScrapeMeta(meta(MediaKind.epub, 'u1', summary: 'a'));
      await db.upsertItemScrapeMeta(meta(MediaKind.epub, 'u1', summary: 'b'));
      final ItemScrapeMetaRow row = (await db.getAllItemScrapeMeta()).single;
      expect(row.summary, 'b');
      expect(row.rating, 8.2);
      expect(
        () => db.upsertItemScrapeMeta(meta(MediaKind.video, 'v1')),
        throwsArgumentError,
      );
    });

    test('replaceItemImagesOfKind：按序落 position、返回被换掉的旧路径', () async {
      List<String> dropped = await db.replaceItemImagesOfKind(
        mediaType: MediaKind.game,
        entryKey: 'g1',
        kind: MediaImageKind.backdrop,
        images: const <({String path, String? sourceUrl})>[
          (path: '/a.jpg', sourceUrl: 'https://x/a'),
          (path: '/b.jpg', sourceUrl: null),
        ],
      );
      expect(dropped, isEmpty);
      final List<ItemImageRow> rows = await db.getItemImages(
        MediaKind.game,
        'g1',
      );
      expect(
        rows.map((ItemImageRow r) => (r.position, r.path)),
        <(int, String)>[(0, '/a.jpg'), (1, '/b.jpg')],
      );
      dropped = await db.replaceItemImagesOfKind(
        mediaType: MediaKind.game,
        entryKey: 'g1',
        kind: MediaImageKind.backdrop,
        images: const <({String path, String? sourceUrl})>[
          (path: '/b.jpg', sourceUrl: null),
        ],
      );
      expect(dropped, <String>['/a.jpg']);
      expect(
        () => db.replaceItemImagesOfKind(
          mediaType: MediaKind.game,
          entryKey: 'g1',
          kind: MediaImageKind.logo,
          images: const <({String path, String? sourceUrl})>[
            (path: '/l1.png', sourceUrl: null),
            (path: '/l2.png', sourceUrl: null),
          ],
        ),
        throwsArgumentError,
        reason: '只有 backdrop 允许多张',
      );
      expect(
        (await db.getItemImagesOfKind(MediaImageKind.backdrop)).single.path,
        '/b.jpg',
      );
    });

    Future<void> seedImage(MediaKind kind, String key) =>
        db.replaceItemImagesOfKind(
          mediaType: kind,
          entryKey: key,
          kind: MediaImageKind.backdrop,
          images: <({String path, String? sourceUrl})>[
            (path: '/img/$key.jpg', sourceUrl: null),
          ],
        );

    test('删书 / 删字幕书 / 删游戏同事务清行，别的条目不动', () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'bk',
          title: 'B',
          epubPath: '/x/b.epub',
          extractDir: '/x/b',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      final String uid = (await db.resolveEpubBookUid('bk'))!;
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 's1',
          title: 'S',
          srtPath: '/abs/s.srt',
          importedAt: 1,
        ),
      );
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'G',
          exePath: '/g/1.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      for (final (MediaKind kind, String key) in <(MediaKind, String)>[
        (MediaKind.epub, uid),
        (MediaKind.srt, 's1'),
        (MediaKind.game, 'g1'),
        (MediaKind.game, 'other'),
      ]) {
        await db.upsertItemScrapeMeta(meta(kind, key));
        await seedImage(kind, key);
      }

      await db.deleteEpubBook('bk');
      await db.deleteSrtBookByUid('s1');
      await db.deleteGalgame('g1');

      expect(
        (await db.getAllItemScrapeMeta()).map(
          (ItemScrapeMetaRow r) => r.entryKey,
        ),
        <String>['other'],
      );
      expect(
        (await db.getAllItemImages()).map((ItemImageRow r) => r.entryKey),
        <String>['other'],
      );
    });

    test('deleteItemScrapeDataFor 返回被删图的路径', () async {
      await db.upsertItemScrapeMeta(meta(MediaKind.srt, 's2'));
      await seedImage(MediaKind.srt, 's2');
      expect(
        await db.deleteItemScrapeDataFor(MediaKind.srt, <String>['s2']),
        <String>['/img/s2.jpg'],
      );
      expect(await db.getItemScrapeMeta(MediaKind.srt, 's2'), isNull);
    });
  });
}
