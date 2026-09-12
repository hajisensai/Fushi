import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v99（刮削 C 二期）：`video_source_scrape_settings.metadata_locale`（来源级资料
/// 语言覆盖）与 `video_metadata_works.locked_fields`（作品级字段锁）。
///
/// 守三件事：从真实 v98 库出发两列都建出来；存量行一行不丢；两列升级后都是
/// NULL——NULL 才等于「跟随全局 locale / 无锁」，也就是升级前的逐字节行为。
void main() {
  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row row) => row['name'] == column);
  }

  /// 建一个真实 v98 形状的库：当前 schema 建满 + 存量行，再 DROP 掉 v99 的两列、
  /// 版本写回 98。
  Future<void> seedV98(String path) async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(path, isMainProcess: false);
    final int sourceId = await fresh.into(fresh.mediaSources).insert(
          MediaSourcesCompanion.insert(
            label: '本地番剧',
            mediaKind: 'video',
            rootPath: r'D:\anime',
            createdAt: 1700000000,
          ),
        );
    await fresh.into(fresh.videoSourceScrapeSettings).insert(
          VideoSourceScrapeSettingsCompanion.insert(
            sourceId: Value<int>(sourceId),
            providerOverride: const Value<String?>('tmdb'),
            updatedAt: 1700000001,
          ),
        );
    final int collectionId = await fresh.into(fresh.mediaCollections).insert(
          MediaCollectionsCompanion.insert(name: '某番', createdAt: 1700000000),
        );
    await fresh.into(fresh.videoMetadataWorks).insert(
          VideoMetadataWorksCompanion.insert(
            collectionId: Value<int?>(collectionId),
            mediaType: 'tv',
            title: '某番',
            overview: const Value<String?>('旧简介'),
            updatedAt: 1700000002,
          ),
        );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(path);
    try {
      raw.execute('ALTER TABLE video_source_scrape_settings '
          'DROP COLUMN metadata_locale');
      raw.execute('ALTER TABLE video_metadata_works DROP COLUMN locked_fields');
      raw.execute('PRAGMA user_version = 98');
    } finally {
      raw.dispose();
    }
  }

  String newDbPath(String prefix) {
    final Directory dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      // 迁移测试会开/关多次库；Windows 上句柄回收有延迟，删不掉不算测试失败。
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });
    return '${dir.path}${Platform.pathSeparator}v98-source.db';
  }

  test('v98 库确实没有这两列（前提自检）', () async {
    final String path = newDbPath('fushi_v99_precheck');
    await seedV98(path);

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 98);
      expect(
        hasColumn(probe, 'video_source_scrape_settings', 'metadata_locale'),
        isFalse,
      );
      expect(
          hasColumn(probe, 'video_metadata_works', 'locked_fields'), isFalse);
    } finally {
      probe.dispose();
    }
  });

  test('v98 -> v99：两列建出来、存量行无损、新列默认 NULL', () async {
    final String path = newDbPath('fushi_v99_upgrade');
    await seedV98(path);

    final FushiDatabase migrated =
        FushiDatabase.atFile(path, isMainProcess: false);

    final VideoSourceScrapeSettingRow settings =
        await migrated.select(migrated.videoSourceScrapeSettings).getSingle();
    expect(settings.providerOverride, 'tmdb', reason: '存量来源覆盖不能被迁移抹掉');
    expect(settings.metadataLocale, isNull, reason: 'NULL = 跟随全局资料语言 = 升级前行为');

    final VideoMetadataWorkRow work =
        await migrated.select(migrated.videoMetadataWorks).getSingle();
    expect(work.title, '某番');
    expect(work.overview, '旧简介');
    expect(work.lockedFields, isNull, reason: 'NULL = 无锁 = 升级前行为');

    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 104);
      expect(
        hasColumn(probe, 'video_source_scrape_settings', 'metadata_locale'),
        isTrue,
      );
      expect(hasColumn(probe, 'video_metadata_works', 'locked_fields'), isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('新建库直接就有这两列，且可读写', () async {
    final String path = newDbPath('fushi_v99_fresh');
    final FushiDatabase fresh =
        FushiDatabase.atFile(path, isMainProcess: false);
    expect(fresh.schemaVersion, 104);
    final int sourceId = await fresh.into(fresh.mediaSources).insert(
          MediaSourcesCompanion.insert(
            label: '本地番剧',
            mediaKind: 'video',
            rootPath: r'D:\anime',
            createdAt: 1700000000,
          ),
        );
    await fresh.into(fresh.videoSourceScrapeSettings).insert(
          VideoSourceScrapeSettingsCompanion.insert(
            sourceId: Value<int>(sourceId),
            metadataLocale: const Value<String?>('ja'),
            updatedAt: 1700000001,
          ),
        );
    final int collectionId = await fresh.into(fresh.mediaCollections).insert(
          MediaCollectionsCompanion.insert(name: '某番', createdAt: 1),
        );
    final int workId = await fresh.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: '某番',
        lockedFields: const Value<String?>('title,overview'),
        updatedAt: 1,
      ),
    );

    expect(
      (await fresh.select(fresh.videoSourceScrapeSettings).getSingle())
          .metadataLocale,
      'ja',
    );
    expect((await fresh.getVideoMetadataWorkById(workId))!.lockedFields,
        'title,overview');
    await fresh.close();
  });

  test('setVideoMetadataWorkLockedFields 写穿并可清空', () async {
    final String path = newDbPath('fushi_v99_setter');
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    final int collectionId = await db.into(db.mediaCollections).insert(
          MediaCollectionsCompanion.insert(name: '某番', createdAt: 1),
        );
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: '某番',
        updatedAt: 1,
      ),
    );

    await db.setVideoMetadataWorkLockedFields(workId, 'title,cover');
    expect(
      (await db.getVideoMetadataWorkById(workId))!.lockedFields,
      'title,cover',
    );

    await db.setVideoMetadataWorkLockedFields(workId, null);
    expect((await db.getVideoMetadataWorkById(workId))!.lockedFields, isNull);
    await db.close();
  });
}
