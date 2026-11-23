import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v178：`study_segments.lookups`——段内查词次数（拍板台 4KOWK3c2mn，查词随会话
/// 编辑平移）。迁移只加列（存量段 0）+ 部分索引，按列存在性守卫，重跑幂等、不清数据。
void main() {
  Set<String> columns(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "PRAGMA table_info('study_segments')",
    ))
      row['name'] as String,
  };

  test('v176 → v178 给 study_segments 加 lookups（存量 0）；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'study_segment_lookups_v178',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: 'old',
        deviceId: 'dev',
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        title: 'T',
        startAt: 1,
        endAt: 2,
        dateKey: '2026-09-08',
        hour: 10,
        durationMs: const Value(60000),
        updatedAt: 1,
      ),
    );
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP INDEX IF EXISTS idx_study_segments_profile_lookups');
    raw.execute('ALTER TABLE study_segments DROP COLUMN lookups');
    raw.execute('PRAGMA user_version = 176');
    expect(columns(raw), isNot(contains('lookups')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, kFushiDbSchemaVersion);
    final List<StudySegmentRow> rows = await migrated.getStudySegments();
    expect(rows.single.uid, 'old');
    expect(rows.single.lookups, 0, reason: '存量段没有查词');
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(
      probe.select('PRAGMA user_version').first.values.first,
      kFushiDbSchemaVersion,
    );
    expect(columns(probe), contains('lookups'));
    expect(
      probe.select(
        "SELECT 1 FROM sqlite_master WHERE type = 'index' "
        "AND name = 'idx_study_segments_profile_lookups'",
      ),
      isNotEmpty,
    );
    probe.execute('PRAGMA user_version = 176');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getStudySegments()).single.uid, 'old');
    await reopened.close();
  });
}
