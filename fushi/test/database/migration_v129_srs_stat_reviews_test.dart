import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v129：`srs_stat_reviews`——SRS 有效复习投影（本机可重建缓存，BUG-3770）。
///
/// 迁移只建空表 + 两条索引：存量库的投影由 SrsDbStore 打开时按缓存修订号补算（引擎测试
/// `packages/fushi_engine/test/srs/srs_stat_projection_test.dart` 钉那一步）；重跑幂等。
void main() {
  Set<String> namesOf(sqlite.Database raw, String type) => <String>{
    for (final sqlite.Row row in raw.select(
      'SELECT name FROM sqlite_master WHERE type = ?',
      <Object>[type],
    ))
      row['name'] as String,
  };

  test('v128 → v129 建 srs_stat_reviews 与索引；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'srs_stat_reviews_v129',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    expect(namesOf(raw, 'table'), contains('srs_stat_reviews'));
    raw.execute('DROP TABLE srs_stat_reviews');
    raw.execute('PRAGMA user_version = 128');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 129);
    await migrated.getAllTags();
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 129);
    expect(namesOf(probe, 'table'), contains('srs_stat_reviews'));
    expect(
      namesOf(probe, 'index'),
      containsAll(<String>[
        'idx_srs_stat_reviews_profile_time',
        'idx_srs_stat_reviews_card',
      ]),
    );
    probe.execute(
      'INSERT INTO srs_stat_reviews (log_id, profile_uid, card_id, occurred_at) '
      "VALUES ('l1', 'p1', 'c1', 1)",
    );
    probe.execute('PRAGMA user_version = 128');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await reopened.getAllTags();
    await reopened.close();
    final sqlite.Database probe2 = sqlite.sqlite3.open(path);
    expect(probe2.select('PRAGMA user_version').first.values.first, 129);
    expect(
      probe2.select('SELECT COUNT(*) FROM srs_stat_reviews').first.values.first,
      1,
    );
    probe2.dispose();
  });
}
