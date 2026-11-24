// 库管家 ③ 步书 / 游戏刮削的默认库事实（真 schema 的内存库）：「缺元数据」判据、
// 系列按合集归一个单元、水位、已有资料源快照的游戏不进。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  late DatabaseLibraryCurateFacts facts;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    facts = DatabaseLibraryCurateFacts(db);
  });

  tearDown(() => db.close());

  Future<String> book(
    String key, {
    String? title,
    String? author = 'A',
    String? cover = '/c.jpg',
    int added = 100,
    String? isbn,
  }) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: key,
      title: title ?? key,
      author: Value<String?>(author),
      coverPath: Value<String?>(cover),
      epubPath: '/b/$key.epub',
      extractDir: '/x/$key',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 1,
      localAddedAt: Value<int?>(added),
      isbn: Value<String?>(isbn),
    ),
  );

  Future<String> uidOf(String key) async => (await db.getEpubBook(key))!.uid;

  Future<void> collection(
    int id,
    String name,
    List<String> uids, {
    String type = 'collection',
    CollectionOrigin origin = CollectionOrigin.user,
  }) async {
    await db.customStatement(
      'INSERT INTO media_collections '
      '(id, name, collection_type, origin, created_at) '
      "VALUES ($id, '$name', '$type', '${origin.dbValue}', 1)",
    );
    for (final String u in uids) {
      await db.customStatement(
        'INSERT INTO media_collection_items '
        '(collection_id, media_type, entry_key) '
        "VALUES ($id, '${MediaKind.epub.dbValue}', '$u')",
      );
    }
  }

  test('书：缺封面 / 缺作者 / 书名是文件名才算；同合集两本以上归系列', () async {
    await book('full'); // 什么都不缺
    await book('nocover', cover: null);
    await book('noauthor', author: null);
    await book('file', title: '[X] file.epub');
    await book('s1', cover: null);
    await book('s2', author: '');
    await book('s3'); // 系列里但不缺：不进单元
    await collection(1, 'Series', <String>[
      await uidOf('s1'),
      await uidOf('s2'),
      await uidOf('s3'),
    ]);
    final List<LibraryCurateBookUnit> units = await facts.bookScrapeUnits(null);
    expect(units.map((LibraryCurateBookUnit u) => u.id), <String>[
      'collection:1',
      'book:file',
      'book:noauthor',
      'book:nocover',
    ]);
    final LibraryCurateBookUnit series = units.first;
    expect(series.isSeries, isTrue);
    expect(series.title, 'Series');
    expect(
      series.volumes.map((LibraryCurateBookVolume v) => v.bookKey),
      <String>['s1', 's2'],
    );
    expect(series.volumes.first.missingCover, isTrue);
    expect(series.volumes.last.missingAuthor, isTrue);
    final LibraryCurateBookUnit file = units[1];
    expect(file.volumes.single.fileNameTitle, isTrue);
  });

  // BUG-5370：书架自动归组（BookSeriesGrouper）与 AI 整理建的系列是 `playlist` 型；
  // 以前只认 `collection` 型，同一系列的两卷被拆成两个单书单元、提醒条数成两部。
  test('整理器建的 playlist 系列（rule / ai）归一个单元；用户手建的 playlist 不归', () async {
    await book('r1', author: null);
    await book('r2', author: null);
    await book('a1', cover: null);
    await book('a2', cover: null);
    await book('u1', author: null);
    await book('u2', author: null);
    await collection(
      1,
      'Rule Series',
      <String>[await uidOf('r1'), await uidOf('r2')],
      type: 'playlist',
      origin: CollectionOrigin.rule,
    );
    await collection(
      2,
      'AI Series',
      <String>[await uidOf('a1'), await uidOf('a2')],
      type: 'playlist',
      origin: CollectionOrigin.ai,
    );
    await collection(3, 'My playlist', <String>[
      await uidOf('u1'),
      await uidOf('u2'),
    ], type: 'playlist');
    final List<LibraryCurateBookUnit> units = await facts.bookScrapeUnits(null);
    expect(units.map((LibraryCurateBookUnit u) => u.id), <String>[
      'collection:1',
      'collection:2',
      'book:u1',
      'book:u2',
    ]);
    final LibraryCurateBookUnit rule = units.first;
    expect(rule.isSeries, isTrue);
    expect(rule.title, 'Rule Series');
    expect(rule.volumes.map((LibraryCurateBookVolume v) => v.bookKey), <String>[
      'r1',
      'r2',
    ]);
    expect(
      units[1].volumes.map((LibraryCurateBookVolume v) => v.bookKey),
      <String>['a1', 'a2'],
    );
  });

  test('书的水位：只要含新入库书的单元', () async {
    await book('old', cover: null, added: 10);
    await book('new', cover: null, added: 500);
    expect(
      (await facts.bookScrapeUnits(100)).map((LibraryCurateBookUnit u) => u.id),
      <String>['book:new'],
    );
  });

  test('游戏：已有资料源快照的不进；改过名用改的名；水位按 added_at', () async {
    Future<void> game(String id, int added, {String? custom}) =>
        db.upsertGalgame(
          GalgamesCompanion.insert(
            id: id,
            name: 'exe_$id',
            exePath: '/g/$id.exe',
            workdir: '/g',
            addedAt: added,
            customDataJson: Value<String?>(custom),
          ),
        );
    await game('a', 10);
    await game('b', 20, custom: '{"name":"Renamed"}');
    await game('c', 30);
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'c',
        source: 'vndb',
        dataJson: '{}',
        fetchedAt: 1,
      ),
    );
    final List<LibraryCurateGameUnit> all = await facts.gameScrapeUnits(null);
    expect(all.map((LibraryCurateGameUnit g) => '${g.id}=${g.title}'), <String>[
      'a=exe_a',
      'b=Renamed',
    ]);
    expect(
      (await facts.gameScrapeUnits(15)).map((LibraryCurateGameUnit g) => g.id),
      <String>['b'],
    );
  });
}
