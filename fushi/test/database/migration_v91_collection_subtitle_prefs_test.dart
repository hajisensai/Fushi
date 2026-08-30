import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v91（合集级字幕偏好）：`media_collections` 加 `subtitle_language`（系列级默认
/// 字幕语言代码）与 `subtitle_release_group`（系列级偏好的字幕版本组键），镜像
/// v52 `subtitle_delay_ms` 的「系列共享、nullable」结构。
///
/// 本文件守三件事：
///  1. **加列不许并进已发布的版本号**：从「真实的 v88 库」出发（当前 schema 建满
///     → DROP 掉这两列 → user_version 写回 88），只有 88 这个起点能区分「列在
///     v88 段」和「列在 v91 段」——塞进 `from < 88` 的列对已写成 88 的库永远不会
///     执行，读路径静默读成 NULL、写路径撞 no such column（v88 那次事故同款）。
///  2. **加列无损**：存量合集行一条不丢、既有系列级调轴值逐列不变。
///  3. **NULL = 没人配过**：升级后两列全 NULL，消费方回退视频内容语言链 /
///     默认选轨——绝不回填 ja，语言未知不许替用户猜。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir =
        Directory.systemTemp.createTempSync('fushi_v91_collection_subtitle');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v88-source.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 建一个真实的 v88 形状库：当前 schema 建满，再摘掉 v91 的两列并把版本写回 88。
  Future<void> seedV88() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // 存量行：系列级调过主轨（-450），迁移必须无损带过去。
    await fresh.customStatement(
      'INSERT INTO media_collections (name, created_at, subtitle_delay_ms) '
      "VALUES ('某番剧', 1700000000, -450)",
    );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('ALTER TABLE media_collections DROP COLUMN subtitle_language');
      raw.execute(
          'ALTER TABLE media_collections DROP COLUMN subtitle_release_group');
      raw.execute('PRAGMA user_version = 88');
    } finally {
      raw.dispose();
    }
  }

  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row r) => r['name'] == column);
  }

  test('v88 库确实缺这两列（前提自检——不然下面那条测了个寂寞）', () async {
    await seedV88();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 88);
      expect(hasColumn(probe, 'media_collections', 'subtitle_language'),
          isFalse);
      expect(hasColumn(probe, 'media_collections', 'subtitle_release_group'),
          isFalse);
    } finally {
      probe.dispose();
    }
  });

  test('v88 -> v91：两列补齐、默认 NULL、存量合集行与既有调轴值无损', () async {
    await seedV88();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    // 走真实查询路径：列缺失时这一句就会 SqliteException，正是线上会炸的地方。
    final List<MediaCollectionRow> rows =
        await migrated.select(migrated.mediaCollections).get();
    expect(rows, hasLength(1), reason: '迁移丢一行就是丢一个合集');
    expect(rows.single.name, '某番剧');
    expect(rows.single.subtitleDelayMs, -450, reason: '系列级主轨调轴值不许被迁移动到');
    expect(rows.single.subtitleLanguage, isNull,
        reason: 'NULL = 没人配过 → 回退视频内容语言链；不许因为「多半是日文」就填 ja');
    expect(rows.single.subtitleReleaseGroup, isNull,
        reason: 'NULL = 没人配过 → 默认选轨');
    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 91);
      expect(
          hasColumn(probe, 'media_collections', 'subtitle_language'), isTrue);
      expect(hasColumn(probe, 'media_collections', 'subtitle_release_group'),
          isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('升级后写入口照常：设语言 / 版本组能真写穿，设 null 能清空', () async {
    await seedV88();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    addTearDown(migrated.close);
    final int id =
        (await migrated.select(migrated.mediaCollections).getSingle()).id;

    // 读路径在缺列时**不抛**（一律读成 NULL），所以判别力靠这两条写入：
    // `SET subtitle_language = ?` 打在没有该列的表上必然报错。
    await migrated.updateMediaCollectionSubtitleLanguage(id, 'en');
    await migrated.updateMediaCollectionSubtitleReleaseGroup(id, 'group-a');
    MediaCollectionRow row =
        await migrated.select(migrated.mediaCollections).getSingle();
    expect(row.subtitleLanguage, 'en');
    expect(row.subtitleReleaseGroup, 'group-a');
    expect(row.subtitleDelayMs, -450, reason: '写别的列不许碰调轴');

    // 清空 = 写回 NULL（回到「没人配过」），不是空串。
    await migrated.updateMediaCollectionSubtitleLanguage(id, null);
    await migrated.updateMediaCollectionSubtitleReleaseGroup(id, null);
    row = await migrated.select(migrated.mediaCollections).getSingle();
    expect(row.subtitleLanguage, isNull);
    expect(row.subtitleReleaseGroup, isNull);
  });

  test('重复打开幂等：第二次开库不因列已存在而报错', () async {
    await seedV88();

    final FushiDatabase first =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await first.close();
    final FushiDatabase second =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    final List<MediaCollectionRow> rows =
        await second.select(second.mediaCollections).get();
    expect(rows, hasLength(1));
    await second.close();
  });
}
