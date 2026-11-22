import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v167：`favorite_sentences.color_updated_at_us`——收藏句颜色的 LWW 时钟
/// （BUG-5081）。纯加列：存量行原样、新列 NULL（= 没改过色）；重跑幂等。
void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_v167_');
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

  /// 把库退回 v166 的形状（表上没有颜色时钟列），放一条存量收藏句。
  void downgradeTo166() {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'ALTER TABLE favorite_sentences DROP COLUMN color_updated_at_us',
    );
    expect(columns(raw), isNot(contains('color_updated_at_us')));
    raw.execute(
      'INSERT INTO favorite_sentences (id, sentence, book_title, '
      "created_at_us, color, source) VALUES ('hl_1', 'そうか', '本', "
      "1700000000000000, 'green', 'book')",
    );
    raw.execute('PRAGMA user_version = 166');
    raw.dispose();
  }

  test('v166 → v167 加列：存量行原样、颜色时钟 NULL，之后能改色', () async {
    downgradeTo166();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(db.schemaVersion, 170);
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    final FavoriteSentence before = (await repo.getAll()).single;
    expect(before.color, 'green');
    expect(before.colorUpdatedAt, isNull);
    expect(before.colorClock, before.createdAt);

    final DateTime at = DateTime.fromMicrosecondsSinceEpoch(1800000000000000);
    expect(await repo.setColor('hl_1', 'pink', at: at), isTrue);
    final FavoriteSentence after = (await repo.getAll()).single;
    expect(after.color, 'pink');
    expect(after.colorUpdatedAt, at);
  });

  test('列已在时重跑 v167 不报错、不动数据', () async {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 166');
    raw.dispose();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.getAllFavoriteSentenceRows(), isEmpty);
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(columns(probe), contains('color_updated_at_us'));
    expect(probe.select('PRAGMA user_version').first.values.first, 170);
  });
}
