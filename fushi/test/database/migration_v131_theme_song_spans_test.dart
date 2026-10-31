import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v131：作品图谱 L2 的 OP / ED 声纹比对按集缓存 `video_theme_song_spans`
/// （docs/specs/2026-10-24-cross-media-links.md §2）。
///
/// 迁移只建表、不动既有数据，重跑幂等；CHECK 钉死「起止同时为空 / 同时非空且 end >
/// start」；表**没有外键**（设备本地表覆盖恢复时按 `INSERT … SELECT *` 回灌，外键会让
/// 一行孤儿把整批回灌打断）。
void main() {
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  VideoThemeSongSpansCompanion row({int? start, int? end}) =>
      VideoThemeSongSpansCompanion.insert(
        bookUid: 'b',
        episodeIndex: 0,
        trackUid: 't',
        fileSizeBytes: 1,
        fileModifiedAt: 1,
        detectorVersion: 1,
        startMs: Value<int?>(start),
        endMs: Value<int?>(end),
        detectedAt: 1,
      );

  test('v130 → v131 建 video_theme_song_spans；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'theme_song_v131',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE video_theme_song_spans');
    raw.execute('PRAGMA user_version = 130');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 142);
    await migrated.upsertThemeSongSpan(row(start: 1000, end: 91000));
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 142);
    expect(tableExists(probe, 'video_theme_song_spans'), isTrue);
    expect(
      probe.select('PRAGMA foreign_key_list(video_theme_song_spans)'),
      isEmpty,
      reason: '设备本地缓存不挂外键',
    );
    // 重跑 v131 步：表已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 130');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final List<VideoThemeSongSpanRow> rows = await reopened
        .themeSongSpansForEpisode((bookUid: 'b', episodeIndex: 0));
    expect(rows.single.startMs, 1000);
    expect((await reopened.themeSongSpansForTrack('t')).single.endMs, 91000);
    await reopened.close();
  });

  test('CHECK：起止同为空（没出现）可写；只有一端 / end ≤ start 拒绝', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'theme_song_check',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final FushiDatabase db = FushiDatabase.atFile(
      '${directory.path}/t.db',
      isMainProcess: false,
    );
    addTearDown(db.close);
    await db.upsertThemeSongSpan(row());
    expect(await db.themeSongSpansForTrack('t'), isEmpty, reason: '没出现不算命中');
    await expectLater(db.upsertThemeSongSpan(row(start: 5)), throwsA(anything));
    await expectLater(
      db.upsertThemeSongSpan(row(start: 5, end: 5)),
      throwsA(anything),
    );
  });
}
