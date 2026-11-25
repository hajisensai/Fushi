// 库管家 ③ 步书 / 游戏刮削的默认库事实（真 schema 的内存库）：「缺元数据」判据、
// 系列按系列身份归一个单元、水位、已有资料源快照的游戏不进。
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
  }) async {
    await db.customStatement(
      'INSERT INTO media_collections (id, name, collection_type, created_at) '
      "VALUES ($id, '$name', '$type', 1)",
    );
    for (final String u in uids) {
      await db.customStatement(
        'INSERT INTO media_collection_items '
        '(collection_id, media_type, entry_key) '
        "VALUES ($id, '${MediaKind.epub.dbValue}', '$u')",
      );
    }
  }

  test('书：缺封面 / 缺作者 / 书名是文件名才算；同系列两本以上归一个系列单元', () async {
    await book('full'); // 什么都不缺
    await book('nocover', cover: null);
    await book('noauthor', author: null);
    await book('file', title: '[X] file.epub');
    await book('s1', title: 'Saga 01', cover: null);
    await book('s2', title: 'Saga 02', author: '');
    await book('s3', title: 'Saga 03'); // 系列里但不缺：不进单元
    final List<LibraryCurateBookUnit> units = await facts.bookScrapeUnits(null);
    expect(units.map((LibraryCurateBookUnit u) => u.id), <String>[
      'series:book|saga',
      'book:file',
      'book:noauthor',
      'book:nocover',
    ]);
    final LibraryCurateBookUnit series = units.first;
    expect(series.isSeries, isTrue);
    expect(series.title, 'Saga');
    expect(series.query, 'Saga');
    expect(
      series.volumes.map((LibraryCurateBookVolume v) => v.bookKey),
      <String>['s1', 's2'],
    );
    expect(series.volumes.first.missingCover, isTrue);
    expect(series.volumes.last.missingAuthor, isTrue);
    final LibraryCurateBookUnit file = units[1];
    expect(file.volumes.single.fileNameTitle, isTrue);
  });

  // BUG-5366：系列归组 / 库整理 / AI 助手建的系列合集都是 `playlist` 型；补刮原先只认
  // `collection` 型，系列各卷被拆成单本、按「第10話 前編」这种卷名去查。
  test('系列身份按书名判（与归组同一判据），不看合集类型；混合合集不当系列', () async {
    await book('m10', title: '十歳の最強魔導師 第10話 前編 [e2b80cbb]', author: null);
    await book('m11', title: '十歳の最強魔導師 第11話 前編 [e27261d5]', author: null);
    await collection(1, '十歳の最強魔導師', <String>[
      await uidOf('m10'),
      await uidOf('m11'),
    ], type: 'playlist');
    await book('x1', title: 'Alpha', author: null);
    await book('x2', title: 'Beta', author: null);
    await collection(2, 'Favorites', <String>[
      await uidOf('x1'),
      await uidOf('x2'),
    ]);
    final List<LibraryCurateBookUnit> units = await facts.bookScrapeUnits(null);
    final LibraryCurateBookUnit series = units.firstWhere(
      (LibraryCurateBookUnit u) => u.isSeries,
    );
    expect(series.query, '十歳の最強魔導師');
    expect(
      series.volumes.map((LibraryCurateBookVolume v) => v.bookKey),
      <String>['m10', 'm11'],
    );
    expect(
      units
          .where((LibraryCurateBookUnit u) => !u.isSeries)
          .map((LibraryCurateBookUnit u) => u.id),
      <String>['book:x1', 'book:x2'],
    );
  });

  test('单本按去掉卷号 / 店铺标签后的系列名查，显示名不变', () async {
    await book('b1', title: 'バカに告白 1【電子限定特典付き】', author: null);
    final LibraryCurateBookUnit unit = (await facts.bookScrapeUnits(
      null,
    )).single;
    expect(unit.id, 'book:b1');
    expect(unit.title, 'バカに告白 1【電子限定特典付き】');
    expect(unit.query, 'バカに告白');
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
