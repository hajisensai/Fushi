import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v80 迁移（media_items → media_open_history）：19 列旧最近打开表收敛为
/// 身份 (media_source, media_id) + opened_at + 进度两列 + snapshot JSON；
/// 遗留 base64 图片原样进 snapshot；旧表 DROP。
void main() {
  Future<FushiDatabase> openV79Db() async {
    final FushiDatabase db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE media_items (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  media_identifier TEXT NOT NULL,
  title TEXT NOT NULL,
  media_type_identifier TEXT NOT NULL,
  media_source_identifier TEXT NOT NULL,
  unique_key TEXT NOT NULL UNIQUE,
  base64_image TEXT,
  image_url TEXT,
  audio_url TEXT,
  author TEXT,
  author_identifier TEXT,
  extra_url TEXT,
  extra TEXT,
  source_metadata TEXT,
  position INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  can_delete INTEGER NOT NULL,
  can_edit INTEGER NOT NULL,
  imported_at INTEGER NOT NULL DEFAULT 0
)
''');
          rawDb.execute('INSERT INTO media_items (media_identifier, title, '
              'media_type_identifier, media_source_identifier, unique_key, '
              'base64_image, image_url, author, position, duration, '
              'can_delete, can_edit, imported_at) '
              "VALUES ('https://ex.com/m', '在线漫画', 'viewer', 'mangasrc', "
              "'mangasrc/https://ex.com/m', 'AAAA', 'https://ex.com/c.jpg', "
              "'作者', 42, 100, 1, 0, 1700000000000)");
          rawDb.execute('INSERT INTO media_items (media_identifier, title, '
              'media_type_identifier, media_source_identifier, unique_key, '
              'position, duration, can_delete, can_edit, imported_at) '
              "VALUES ('fushi://book/Bk', 'Bk', 'reader', 'hibiki', "
              "'hibiki/fushi://book/Bk', 760, 1000, 1, 0, 1700000000001)");
          rawDb.execute('PRAGMA user_version = 79');
        },
      ),
    );
    addTearDown(db.close);
    return db;
  }

  test('v80：零丢行搬移、载荷进 snapshot、进度/时刻列化、旧表 DROP', () async {
    final FushiDatabase db = await openV79Db();

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), db.schemaVersion);
    expect(db.schemaVersion, 85);

    final rows = await db.getAllMediaOpenHistory();
    expect(rows, hasLength(2), reason: '迁移零丢行');
    expect(rows.first.mediaId, 'fushi://book/Bk', reason: 'openedAt 倒序，较新者在前');

    final MediaOpenHistoryRow online =
        rows.singleWhere((r) => r.mediaSource == 'mangasrc');
    expect(online.mediaType, 'viewer');
    expect(online.openedAt, 1700000000000, reason: 'imported_at 平移');
    expect(online.position, 42);
    expect(online.duration, 100);
    final Map<String, dynamic> snap =
        jsonDecode(online.snapshotJson) as Map<String, dynamic>;
    expect(snap['title'], '在线漫画');
    expect(snap['imageUrl'], 'https://ex.com/c.jpg');
    expect(snap['author'], '作者');
    expect(snap['base64Image'], 'AAAA', reason: '遗留 base64 原样平移不丢');

    final MediaOpenHistoryRow book =
        rows.singleWhere((r) => r.mediaSource == 'hibiki');
    final Map<String, dynamic> bookSnap =
        jsonDecode(book.snapshotJson) as Map<String, dynamic>;
    expect(bookSnap.containsKey('imageUrl'), isFalse,
        reason: 'NULL 字段不进 snapshot（不存哨兵）');

    final legacy = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='media_items'")
        .get();
    expect(legacy, isEmpty, reason: '旧表已 DROP');
  });
}
