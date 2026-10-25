import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v128（内置浏览器完整化）：历史 / 书签（含文件夹）/ 标签页会话 / 最近关闭 / 下载记录
/// 五张新表。纯新表：升级只建表、不动存量数据，重跑幂等。
void main() {
  const List<String> webTables = <String>[
    'web_browser_history',
    'web_browser_bookmarks',
    'web_browser_session_tabs',
    'web_browser_closed_tabs',
    'web_browser_downloads',
  ];

  Set<String> tablesOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "SELECT name FROM sqlite_master WHERE type='table'",
    ))
      row['name'] as String,
  };

  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  test('v127 → v128 建出五张浏览器表、存量数据不动、重跑幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync('web_v128');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.createMediaCollection('Keep');
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String t in webTables) {
      raw.execute('DROP TABLE $t');
    }
    raw.execute('PRAGMA user_version = 127');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 135);
    expect((await migrated.getAllMediaCollections()).single.name, 'Keep');
    await migrated.recordWebBrowserVisit(
      url: 'https://example.com/',
      title: 'Example',
      visitedAt: 1,
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(tablesOf(probe), containsAll(webTables));
    expect(
      columnsOf(probe, 'web_browser_history'),
      containsAll(<String>['url', 'title', 'last_visited_at', 'visit_count']),
    );
    expect(
      columnsOf(probe, 'web_browser_bookmarks'),
      containsAll(<String>[
        'uid',
        'title',
        'url',
        'parent_id',
        'position',
        'created_at',
        'updated_at',
      ]),
    );
    expect(
      columnsOf(probe, 'web_browser_downloads'),
      containsAll(<String>[
        'url',
        'file_name',
        'mime_type',
        'total_bytes',
        'received_bytes',
        'state',
        'saved_path',
        'started_at',
      ]),
    );
    expect(probe.select('PRAGMA user_version').first.values.first, 135);
    // 重跑：表已存在时 _tableExists 守卫让整步 no-op，数据保留。
    probe.execute('PRAGMA user_version = 127');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getWebBrowserHistory()).single.title, 'Example');
    await reopened.close();
  });

  // 并行迁移史：音乐 / 作品图谱分支（PR #2534）合入前把 v125–v131 用给了自己的表，
  // 合入时整体后移到 v129–v135。那条分支构建打开过的库 user_version 落在 129–131，
  // 却没有 develop 的 v125–v128 产物；升级必须补齐，不能因为版本号已过 128 就跳过。
  for (final int parallelVersion in <int>[129, 130, 131]) {
    test('并行史 user_version=$parallelVersion 缺 v125–v128 产物：升级补齐', () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'web_parallel_$parallelVersion',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final String path = '${dir.path}/test.db';
      final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
      await db.createMediaCollection('Keep');
      await db.close();

      final sqlite.Database raw = sqlite.sqlite3.open(path);
      for (final String t in webTables) {
        raw.execute('DROP TABLE $t');
      }
      raw.execute('ALTER TABLE bookmarks DROP COLUMN char_offset');
      raw.execute('ALTER TABLE bookmarks DROP COLUMN chapter_key');
      raw.execute(
        'ALTER TABLE collection_member_tombstones DROP COLUMN published_at',
      );
      raw.execute('PRAGMA user_version = $parallelVersion');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect((await migrated.getAllMediaCollections()).single.name, 'Keep');
      await migrated.close();

      final sqlite.Database probe = sqlite.sqlite3.open(path);
      addTearDown(probe.dispose);
      expect(tablesOf(probe), containsAll(webTables));
      expect(
        columnsOf(probe, 'bookmarks'),
        containsAll(<String>['char_offset', 'chapter_key']),
      );
      expect(
        columnsOf(probe, 'collection_member_tombstones'),
        contains('published_at'),
      );
      expect(probe.select('PRAGMA user_version').first.values.first, 135);
    });
  }
}
