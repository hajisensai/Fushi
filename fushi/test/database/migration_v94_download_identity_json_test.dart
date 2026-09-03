import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// v94（刮削重设计 P1，BUG-2003）：`video_download_jobs` /
/// `video_download_subscriptions` 各加 `identity_json`——发现页完整身份
/// （原名/别名/全部外部 id）的 JSON 快照。
///
/// 守三件事：从真实 v93 库出发列会补上；存量任务/订阅行无损；新列默认 NULL
/// （= 旧行走修前行为，绝不臆造身份）。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_v94_identity_json');
    dbPath = '${tempDir.path}${Platform.pathSeparator}v93-source.db';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 建一个真实的 v93 形状库：当前 schema 建满，摘掉两张表的 identity_json，
  /// 版本写回 93。
  Future<void> seedV93() async {
    final FushiDatabase fresh =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await fresh.customStatement(
      'INSERT INTO video_download_jobs (job_id, resource_provider, '
      'selected_resource_id, media_kind, title, backend_kind, fingerprint, '
      'created_at, updated_at) '
      "VALUES ('job-1', 'nyaa:test', 'release-1', 'tv', '某番剧', 'embedded', "
      "'fp-1', 1700000000, 1700000000)",
    );
    await fresh.customStatement(
      'INSERT INTO video_download_subscriptions (subscription_id, '
      'resource_provider, media_kind, title, search_query, backend_kind, '
      'fingerprint, created_at, updated_at) '
      "VALUES ('sub-1', 'nyaa:test', 'tv', '某番剧', 'Some Query', 'embedded', "
      "'fp-1', 1700000000, 1700000000)",
    );
    await fresh.close();

    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath);
    try {
      raw.execute('ALTER TABLE video_download_jobs DROP COLUMN identity_json');
      raw.execute(
          'ALTER TABLE video_download_subscriptions DROP COLUMN identity_json');
      raw.execute('PRAGMA user_version = 93');
    } finally {
      raw.dispose();
    }
  }

  bool hasColumn(sqlite3.Database db, String table, String column) {
    final sqlite3.ResultSet rows = db.select('PRAGMA table_info($table)');
    return rows.any((sqlite3.Row r) => r['name'] == column);
  }

  test('v93 库确实缺 identity_json（前提自检）', () async {
    await seedV93();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 93);
      expect(hasColumn(probe, 'video_download_jobs', 'identity_json'), isFalse);
      expect(hasColumn(probe, 'video_download_subscriptions', 'identity_json'),
          isFalse);
    } finally {
      probe.dispose();
    }
  });

  test('v93 -> v94：两表补列、默认 NULL、存量行无损', () async {
    await seedV93();

    final FushiDatabase migrated =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    final List<VideoDownloadJobRow> jobs =
        await migrated.select(migrated.videoDownloadJobs).get();
    expect(jobs, hasLength(1), reason: '迁移丢一行就是丢一个任务');
    expect(jobs.single.title, '某番剧');
    expect(jobs.single.identityJson, isNull,
        reason: 'NULL = 旧任务无身份快照，走修前重建路径，绝不臆造身份');
    final List<VideoDownloadSubscriptionRow> subscriptions =
        await migrated.select(migrated.videoDownloadSubscriptions).get();
    expect(subscriptions, hasLength(1));
    expect(subscriptions.single.searchQuery, 'Some Query',
        reason: '订阅搜索词不许被迁移动到');
    expect(subscriptions.single.identityJson, isNull);
    await migrated.close();

    final sqlite3.Database probe =
        sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      expect(probe.select('PRAGMA user_version').first.values.first, 94);
      expect(hasColumn(probe, 'video_download_jobs', 'identity_json'), isTrue);
      expect(hasColumn(probe, 'video_download_subscriptions', 'identity_json'),
          isTrue);
    } finally {
      probe.dispose();
    }
  });

  test('重复打开幂等：第二次开库不因列已存在而报错', () async {
    await seedV93();

    final FushiDatabase first =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    await first.close();
    final FushiDatabase second =
        FushiDatabase.atFile(dbPath, isMainProcess: false);
    expect(await second.select(second.videoDownloadJobs).get(), hasLength(1));
    await second.close();
  });
}
