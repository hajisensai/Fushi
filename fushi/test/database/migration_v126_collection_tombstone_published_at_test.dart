import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v126：`collection_member_tombstones.published_at`——墓碑知识进入本库的时刻，本机作
/// 互联 host 时作合集清单的 publishedAt / deletedPublishedAt 输出。存量行留 NULL（对端
/// 回退 deleted_at 判，与升级前一致）；迁移重跑幂等。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  test('v125 → v126 加 published_at 列、存量墓碑留 NULL、重跑幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tomb_pub_v126');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    final int c = await db.createMediaCollection('S');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addToCollection(c, MediaKind.video, 'v2');
    await db.removeFromCollection(c, MediaKind.video, 'v2');
    final int d = await db.createMediaCollection('D');
    await db.addToCollection(d, MediaKind.video, 'd1');
    await db.deleteMediaCollection(d);
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'ALTER TABLE collection_member_tombstones DROP COLUMN published_at',
    );
    expect(
      columnsOf(raw, 'collection_member_tombstones'),
      isNot(contains('published_at')),
    );
    raw.execute('PRAGMA user_version = 124');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 143);
    final List<CollectionMemberTombstoneRow> rows = await migrated
        .getAllCollectionMemberTombstones();
    expect(rows, hasLength(2), reason: '成员墓碑 + 合集级删除哨兵都保留');
    expect(
      rows.map((CollectionMemberTombstoneRow r) => r.publishedAt),
      everyElement(isNull),
      reason: '存量行没有进库时刻，留 NULL 回退 deleted_at',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(
      columnsOf(probe, 'collection_member_tombstones'),
      contains('published_at'),
    );
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
    // 重跑：版本号写回 124 再开，列已存在的守卫让这一步 no-op。
    probe.execute('PRAGMA user_version = 124');
    probe.dispose();
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await reopened.getAllCollectionMemberTombstones(), hasLength(2));
    await reopened.close();
  });
}
