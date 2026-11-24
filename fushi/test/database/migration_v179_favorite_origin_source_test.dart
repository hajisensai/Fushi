import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v179：`favorite_sentences.origin_source_id`——远端条目收藏时的来源身份
/// （BUG-5379：Plex / Emby 条目 id 跨服务器撞号，跳回原处按它找回那一台）。纯加列：
/// 存量行原样、新列 NULL；重跑幂等。起点是真实的 v178 形状（建当前库再删掉新列）。
void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_v179_');
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

  void downgradeTo178() {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE favorite_sentences DROP COLUMN origin_source_id');
    expect(columns(raw), isNot(contains('origin_source_id')));
    raw.execute(
      'INSERT INTO favorite_sentences (id, sentence, book_title, '
      "created_at_us, book_key, source) VALUES ('hl_1', 'そうか', 'Ep 3', "
      "1700000000000000, '1234', 'video')",
    );
    raw.execute('PRAGMA user_version = 178');
    raw.dispose();
  }

  test('v178 → v179 加列：存量行原样、来源 NULL，之后新收藏能记来源', () async {
    downgradeTo178();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(db.schemaVersion, kFushiDbSchemaVersion);
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    final FavoriteSentence legacy = (await repo.getAll()).single;
    expect(legacy.bookKey, '1234');
    expect(legacy.originSourceId, isNull);

    await repo.add(
      FavoriteSentence(
        text: 'もう一つ',
        bookTitle: 'Ep 4',
        createdAt: DateTime.fromMicrosecondsSinceEpoch(1800000000000000),
        bookKey: '1234',
        source: kFavoriteSentenceSourceVideo,
        originSourceId: 'plex:m1|a1',
      ),
    );
    final List<FavoriteSentence> all = await repo.getAll();
    expect(all.first.originSourceId, 'plex:m1|a1');
  });

  test('列已在时重跑 v179 不报错、不动数据', () async {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 178');
    raw.dispose();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.getAllFavoriteSentenceRows(), isEmpty);
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(columns(probe), contains('origin_source_id'));
    expect(
      probe.select('PRAGMA user_version').first.values.first,
      kFushiDbSchemaVersion,
    );
  });
}
