import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v134：`music_lyric_coverage`（曲库按歌词生词覆盖率排序的缓存，设计 §12）。迁移只建表、
/// 不动既有数据，重跑幂等；v132 / v133 归并行分支，本步只认自己的表。
void main() {
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  test('v131 → v134 建 music_lyric_coverage；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'music_lyric_coverage_v134',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags();
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_lyric_coverage');
    raw.execute('PRAGMA user_version = 131');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 134);
    await migrated
        .into(migrated.musicLyricCoverage)
        .insert(
          MusicLyricCoverageCompanion.insert(
            trackUid: 't1',
            status: 'ok',
            inputStamp: 's',
            termsJson: const Value<String>('[["夜","よる",2]]'),
            totalTokens: const Value<int>(2),
            uniqueTerms: const Value<int>(1),
            computedAt: 1,
          ),
        );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 134);
    expect(tableExists(probe, 'music_lyric_coverage'), isTrue);
    final Set<String> columns = <String>{
      for (final sqlite.Row r in probe.select(
        'PRAGMA table_info(music_lyric_coverage)',
      ))
        r['name'] as String,
    };
    expect(
      columns,
      containsAll(<String>[
        'track_uid',
        'status',
        'input_stamp',
        'terms_json',
        'total_tokens',
        'unique_terms',
        'known_tokens',
        'known_stamp',
        'computed_at',
      ]),
    );
    probe.execute('PRAGMA user_version = 131');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(reopened.close);
    final MusicLyricCoverageRow row = await reopened
        .select(reopened.musicLyricCoverage)
        .getSingle();
    expect(row.trackUid, 't1', reason: '重跑不清数据');
    expect(row.knownTokens, isNull);
  });
}
