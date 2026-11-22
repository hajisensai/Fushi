import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v169：`video_collection_section_overrides`——用户 / AI 钉死的「文件 → 合集分栏」
/// （拍板台 iR6ccUys9H）。纯建表、幂等；FK 随视频删除；批量读写与清除。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_v169_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  bool tableExists(sqlite.Database db, String name) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[name],
  ).isNotEmpty;

  Future<void> addVideo(FushiDatabase db, String uid) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(uid),
      videoPath: Value<String>('/v/$uid.mkv'),
    ),
  );

  test('v168 → v169 建表；重跑不报错不清数据；挂 video_books 外键', () async {
    final String path = p.join(tmp.path, 'fushi.db');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE video_collection_section_overrides');
    raw.execute('PRAGMA user_version = 168');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 171);
    await addVideo(migrated, 'video/a');
    await migrated.setVideoCollectionSectionOverrides(<String>[
      'video/a',
    ], 'extras');
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 171);
    expect(tableExists(probe, 'video_collection_section_overrides'), isTrue);
    expect(
      probe
          .select('PRAGMA foreign_key_list(video_collection_section_overrides)')
          .map((sqlite.Row r) => r['table'])
          .toList(),
      <Object?>['video_books'],
    );
    probe.execute('PRAGMA user_version = 168');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(reopened.close);
    expect(
      await reopened.getVideoCollectionSectionOverrides(<String>['video/a']),
      <String, String>{'video/a': 'extras'},
    );
  });

  test('批量覆盖 / 清除；删视频随外键清掉', () async {
    final FushiDatabase db = FushiDatabase.atFile(
      p.join(tmp.path, 'fushi.db'),
      isMainProcess: false,
    );
    addTearDown(db.close);
    await addVideo(db, 'video/a');
    await addVideo(db, 'video/b');
    await addVideo(db, 'video/c');
    await db.setVideoCollectionSectionOverrides(<String>[
      'video/a',
      'video/b',
    ], 'extras');
    await db.setVideoCollectionSectionOverrides(<String>['video/b'], 's2');
    expect(
      await db.getVideoCollectionSectionOverrides(<String>[
        'video/a',
        'video/b',
        'video/c',
      ]),
      <String, String>{'video/a': 'extras', 'video/b': 's2'},
    );

    await db.clearVideoCollectionSectionOverrides(<String>['video/a']);
    await db.deleteVideoBooks(<String>['video/b']);
    expect(
      await db.getVideoCollectionSectionOverrides(<String>[
        'video/a',
        'video/b',
      ]),
      isEmpty,
    );
  });
}
