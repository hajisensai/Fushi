import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v180：`favorite_sentences.origin_locator`——在线视频源收藏的重开规格（哪部作品的
/// 哪一集），收藏夹 / 手机遥控据此跳回源条目。纯加列：存量行原样、新列 NULL；重跑
/// 幂等。起点是真实的 v179 形状（建当前库再删掉新列）。
void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_v180_');
    path = p.join(tmp.path, 'fushi.db');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  List<String> columns(sqlite.Database raw) => <String>[
    for (final sqlite.Row r in raw.select(
      'PRAGMA table_info(favorite_sentences)',
    ))
      r['name'] as String,
  ];

  void downgradeTo179() {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE favorite_sentences DROP COLUMN origin_locator');
    expect(columns(raw), isNot(contains('origin_locator')));
    raw.execute(
      'INSERT INTO favorite_sentences (id, sentence, book_title, '
      'created_at_us, book_key, source, origin_source_id) VALUES '
      "('hl_1', 'そうか', 'Ep 3', 1700000000000000, "
      "'anime-source:ext:42:/ep/3', 'video', 'anime-source:ext:42')",
    );
    raw.execute('PRAGMA user_version = 179');
    raw.dispose();
  }

  test('v179 → v180 加列：存量行原样、规格 NULL，之后新收藏能记规格', () async {
    downgradeTo179();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(db.schemaVersion, kFushiDbSchemaVersion);
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    final FavoriteSentence legacy = (await repo.getAll()).single;
    expect(legacy.originSourceId, 'anime-source:ext:42');
    expect(legacy.originLocator, isNull);

    await repo.add(
      FavoriteSentence(
        text: 'もう一つ',
        bookTitle: 'Ep 4',
        createdAt: DateTime.fromMicrosecondsSinceEpoch(1800000000000000),
        bookKey: 'anime-source:ext:42:/ep/4',
        source: kFavoriteSentenceSourceVideo,
        originSourceId: 'anime-source:ext:42',
        originLocator: '{"kind":"anime-source"}',
      ),
    );
    final List<FavoriteSentence> all = await repo.getAll();
    expect(all.first.originLocator, '{"kind":"anime-source"}');
  });

  test('列已在时重跑 v180 不报错、不动数据', () async {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 179');
    raw.dispose();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.getAllFavoriteSentenceRows(), isEmpty);
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(columns(probe), contains('origin_locator'));
    expect(
      probe.select('PRAGMA user_version').first.values.first,
      kFushiDbSchemaVersion,
    );
  });
}
