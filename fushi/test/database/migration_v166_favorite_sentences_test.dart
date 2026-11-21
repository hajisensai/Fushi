import 'dart:convert';
import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v166：收藏句从偏好 `favorite_sentences` 的整段 JSON 搬进 `favorite_sentences` 表
/// （拍板台 design-nmv-stats-main-isolate）。字段原样、同 id 不同内容的旧数据
/// （BUG-494）改名保留、缺必填字段的坏条目跳过、整段坏 JSON 不动偏好、重跑不重复。
void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_v166_');
    path = p.join(tmp.path, 'fushi.db');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// 把库退回 v165 的形状：没有收藏句表，偏好里放 [prefValue]。
  void downgradeTo165({required String prefValue, bool dropTable = true}) {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    if (dropTable) raw.execute('DROP TABLE favorite_sentences');
    raw.execute(
      'INSERT OR REPLACE INTO preferences (key, value, updated_at) '
      "VALUES ('favorite_sentences', ?, 1)",
      <Object?>[prefValue],
    );
    raw.execute('PRAGMA user_version = 165');
    raw.dispose();
  }

  const String createdA = '2026-11-20T21:15:03.123456';
  final List<Map<String, Object?>> legacy = <Map<String, Object?>>[
    <String, Object?>{
      'id': 'hl_1',
      'text': 'そうか',
      'bookTitle': '本',
      'chapterLabel': '第一章',
      'createdAt': createdA,
      'bookKey': 'book/a',
      'sectionIndex': 2,
      'normCharOffset': 120,
      'normCharLength': 3,
      'color': 'yellow',
      'source': 'audiobook',
      'dateKey': '2026-11-20',
      'expression': '然う',
      'reading': 'そう',
    },
    // BUG-494 之前的旧数据：同 id、不同内容。
    <String, Object?>{
      'id': 'hl_1',
      'text': 'いいね',
      'bookTitle': '本',
      'createdAt': '2026-11-19T08:00:00.000',
    },
    // 缺 source / dateKey 的更旧条目：source 回退 book、dateKey 留空。
    <String, Object?>{
      'id': 'hl_old',
      'text': '古い',
      'bookTitle': '昔の本',
      'createdAt': '2026-01-01T00:00:00.000',
    },
    // 缺 createdAt：旧仓库读这条就整表抛错，迁移跳过它。
    <String, Object?>{'id': 'hl_bad', 'text': '壊れた', 'bookTitle': ''},
  ];

  test('v165 → v166 搬表：字段原样、撞 id 改名保留、坏条目跳过、偏好删掉', () async {
    downgradeTo165(prefValue: jsonEncode(legacy));

    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(db.schemaVersion, 169);
    final List<FavoriteSentence> all = await FavoriteSentenceRepository(
      db,
    ).getAll();
    expect(all.map((FavoriteSentence s) => s.text).toList(), <String>[
      'そうか',
      'いいね',
      '古い',
    ], reason: '新收藏在前；缺 createdAt 的坏条目跳过');
    final FavoriteSentence a = all[0];
    expect(a.id, 'hl_1');
    expect(a.toJson(), legacy[0], reason: '每个字段原样，createdAt 精确到微秒（wire 字节不变）');
    expect(all[1].id, 'hl_1_1', reason: '同 id 不同内容的旧数据改名保留');
    expect(all[2].source, kFavoriteSentenceSourceBook);
    expect(all[2].dateKey, isNull);
    expect(await db.getPref(kFavoriteSentencesPrefKey), isNull);

    final List<FavoriteSentenceStatRow> stat = await db
        .getFavoriteSentenceStatRows();
    expect(stat, hasLength(3));
  });

  test('重跑 v166（表已在、偏好又出现同一批）不重复搬', () async {
    downgradeTo165(prefValue: jsonEncode(legacy));
    FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    expect(await db.getAllFavoriteSentenceRows(), hasLength(3));
    await db.close();

    downgradeTo165(
      prefValue: jsonEncode(legacy.take(1).toList()),
      dropTable: false,
    );
    db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.getAllFavoriteSentenceRows(), hasLength(3));
    expect(await db.getPref(kFavoriteSentencesPrefKey), isNull);
  });

  test('整段 JSON 坏了：不动偏好（可人工救回）、不建半截数据', () async {
    downgradeTo165(prefValue: '[{"id": "x", "text": ');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.getAllFavoriteSentenceRows(), isEmpty);
    expect(
      await db.getPref(kFavoriteSentencesPrefKey),
      '[{"id": "x", "text": ',
    );
  });

  test('没有旧偏好：只建空表', () async {
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE favorite_sentences');
    raw.execute('PRAGMA user_version = 165');
    raw.dispose();
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    addTearDown(db.close);
    expect(await db.getAllFavoriteSentenceRows(), isEmpty);
  });
}
