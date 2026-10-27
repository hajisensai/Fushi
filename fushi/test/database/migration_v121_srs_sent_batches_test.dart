import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v121（原定 v119，先后因并行合入的视频字幕 AI 校对（v119）与 SRS 批量修复的索引步（v120）占用而顺延）：
/// SRS 多目录同步的「本机已冻结批次留存」`srs_sent_batches`
/// （profile_uid / writer_id / batch_no / bytes，三列主键）。
///
/// 设备本地：不进备份、恢复后清空。迁移只建表，`_tableExists` 守卫幂等：v120 库升级后表存在
/// 且列形状、主键正确；表已存在（重复升级）时既有行原样保留、不抛异常。
///
/// 2026-10-23 起 SRS 表归 Rust 的 srs.db：新建的主库没有这张表；迁移阶梯上带老 SRS 表的库仍按
/// 当年的形状补上它（`kLegacySrsTableDdl`），好让一次性搬迁原样搬走。
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
        "PRAGMA table_info('srs_sent_batches')",
      ))
        row['name'] as String: row,
    };
  }

  /// 退回 v120 带老 SRS 表的形态：v117 的八张表在、srs_sent_batches 不在。
  void addLegacyV117Tables(sqlite.Database raw) {
    for (final String t in kLegacySrsV117Tables) {
      raw.execute(kLegacySrsTableDdl[t]!);
    }
  }

  test('fresh database has no srs_sent_batches (it lives in srs.db)', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'srssent121fresh',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);
    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(columnsOf(probe), isEmpty);
  });

  test(
    'v120 → v121 creates srs_sent_batches with the expected columns',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'srssent121',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = await createDbAt(directory);

      // 退回 v120 形态：有老 SRS 表，没有这张表。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      addLegacyV117Tables(raw);
      raw.execute('PRAGMA user_version = 120');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(migrated.schemaVersion, 138);
      await migrated.customSelect('SELECT 1').get();
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(probe.select('PRAGMA user_version').first.values.first, 138);
      final Map<String, sqlite.Row> columns = columnsOf(probe);
      expect(columns.keys.toSet(), <String>{
        'profile_uid',
        'writer_id',
        'batch_no',
        'bytes',
      });
      expect(columns['profile_uid']!['type'], 'TEXT');
      expect(columns['writer_id']!['type'], 'TEXT');
      expect(columns['batch_no']!['type'], 'INTEGER');
      expect(columns['bytes']!['type'], 'BLOB');
      for (final String name in columns.keys) {
        expect(columns[name]!['notnull'], 1, reason: '$name NOT NULL');
      }
      // 三列主键：pk 序号 1..3，bytes 不在主键里。
      expect(columns['profile_uid']!['pk'], 1);
      expect(columns['writer_id']!['pk'], 2);
      expect(columns['batch_no']!['pk'], 3);
      expect(columns['bytes']!['pk'], 0);
    },
  );

  test('v121 step is idempotent when srs_sent_batches already exists', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'srssent121idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 表已在（重复升级），只把版本号退回 120。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    addLegacyV117Tables(raw);
    raw.execute(kLegacySrsTableDdl['srs_sent_batches']!);
    raw.execute(
      'INSERT INTO srs_sent_batches (profile_uid, writer_id, batch_no, '
      "bytes) VALUES ('p', 'w', 1, x'0102')",
    );
    raw.execute('PRAGMA user_version = 120');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    final List<QueryRow> rows = await migrated
        .customSelect(
          'SELECT profile_uid, writer_id, batch_no, bytes FROM srs_sent_batches',
        )
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('profile_uid'), 'p');
    expect(rows.single.read<String>('writer_id'), 'w');
    expect(rows.single.read<int>('batch_no'), 1);
    expect(rows.single.read<Uint8List>('bytes'), <int>[1, 2]);
  });
}
