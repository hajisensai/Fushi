import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v114：设备端「待发制卡」队列 `pending_mine_queue`（后端不可达/批量模式先入队、
/// 稍后补发；载荷落 `<support>/pending_mine_queue/<id>.json`，表里无路径列）。
///
/// 迁移只做 `createTable`，`_tableExists` 守卫幂等：v113 库升级后表存在且列形状
/// 正确；表已存在（mid-ladder / 重复升级）时既有行原样保留、不抛异常。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    // 触发 onCreate，建出当前 schema。
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  Map<String, sqlite.Row> columnsOf(sqlite.Database raw) {
    return <String, sqlite.Row>{
      for (final sqlite.Row row in raw.select(
        "PRAGMA table_info('pending_mine_queue')",
      ))
        row['name'] as String: row,
    };
  }

  test(
    'v113 → v114 creates pending_mine_queue with the expected columns',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'pendingmine114',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // 退回 v113 形态：没有这张表。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('DROP TABLE pending_mine_queue');
      raw.execute('PRAGMA user_version = 113');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 114);
      await migrated
          .into(migrated.pendingMineQueue)
          .insert(
            PendingMineQueueCompanion.insert(
              id: 'a1b2',
              createdAt: 1000,
              expression: '食べる',
            ),
          );
      final PendingMineRow row = await migrated
          .select(migrated.pendingMineQueue)
          .getSingle();
      expect(row.reading, '');
      expect(row.status, PendingMineStatus.pending);
      expect(row.attempts, 0);
      expect(row.lastError, isNull);
      expect(row.lastAttemptAt, isNull);
      expect(row.originDeviceId, isNull, reason: '默认是本机制的卡');
      expect(row.uploaded, isFalse);
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 114);
      final Map<String, sqlite.Row> columns = columnsOf(probe);
      expect(columns.keys.toSet(), <String>{
        'id',
        'created_at',
        'expression',
        'reading',
        'status',
        'attempts',
        'last_error',
        'last_attempt_at',
        'origin_device_id',
        'uploaded',
      });
      expect(columns['id']!['pk'], 1);
      expect(columns['id']!['type'], 'TEXT');
      expect(columns['created_at']!['notnull'], 1);
      expect(columns['last_error']!['notnull'], 0);
      expect(columns['last_attempt_at']!['notnull'], 0);
      expect(columns['origin_device_id']!['notnull'], 0);
      expect(columns['uploaded']!['notnull'], 1);
    },
  );

  test(
    'v114 step is idempotent when pending_mine_queue already exists',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'pendingmine114idem',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // 表已在（fresh createAll / 重复升级），只把版本号退回 113。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute(
        'INSERT INTO pending_mine_queue (id, created_at, expression, status, '
        "attempts, last_error) VALUES ('keep', 5, '猫', 'failed', 3, 'boom')",
      );
      raw.execute('PRAGMA user_version = 113');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      final List<PendingMineRow> rows = await migrated
          .select(migrated.pendingMineQueue)
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.id, 'keep');
      expect(rows.single.status, PendingMineStatus.failed);
      expect(rows.single.attempts, 3);
      expect(rows.single.lastError, 'boom');
    },
  );
}
