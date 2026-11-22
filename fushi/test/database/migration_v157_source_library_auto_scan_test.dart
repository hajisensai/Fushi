import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v157：`media_sources` 加「自动扫描」开关 `auto_scan`（拍板台 C_8oheua0H /
/// ICOLa6LZLU / enSm2GOuFA）。纯加列、默认关，存量来源 false；列已存在（早期步骤
/// 按当前定义建的表）时跳过。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  Set<String> columnsOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "PRAGMA table_info('media_sources')",
    ))
      row['name'] as String,
  };

  test('v156 → v157 adds auto_scan; existing sources stay off', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'sourceautoscan157',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v156 形态：没有 auto_scan 列，已有两条来源。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE media_sources DROP COLUMN auto_scan');
    raw.execute(
      'INSERT INTO media_sources (label, media_kind, transport, root_path, '
      "sort_order, created_at) VALUES ('Books', 'book', 'local', '/books', 1, 1)",
    );
    raw.execute(
      'INSERT INTO media_sources (label, media_kind, transport, root_path, '
      "sort_order, created_at) VALUES ('Anime', 'video', 'local', '/anime', 0, 2)",
    );
    raw.execute('PRAGMA user_version = 156');
    expect(columnsOf(raw), isNot(contains('auto_scan')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 172);
    final List<MediaSourceRow> rows = await migrated
        .select(migrated.mediaSources)
        .get();
    expect(rows, hasLength(2));
    expect(
      rows.every((MediaSourceRow r) => !r.autoScan),
      isTrue,
      reason: '存量来源默认不自动扫描，行为与升级前一致',
    );
    expect(await migrated.getAutoScanMediaSources(), isEmpty);

    // 开关只写这一列；读取按来源页顺序（sortOrder, id）。
    for (final MediaSourceRow r in rows) {
      await migrated.updateMediaSourceAutoScan(r.id, true);
    }
    final List<MediaSourceRow> enabled = await migrated
        .getAutoScanMediaSources();
    expect(enabled.map((MediaSourceRow r) => r.label).toList(), <String>[
      'Anime',
      'Books',
    ]);
    expect(enabled.first.rootPath, '/anime');
    final MediaSourceRow books = rows.firstWhere(
      (MediaSourceRow r) => r.label == 'Books',
    );
    await migrated.updateMediaSourceAutoScan(books.id, false);
    expect(
      (await migrated.getAutoScanMediaSources())
          .map((MediaSourceRow r) => r.label)
          .toList(),
      <String>['Anime'],
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 172);
    expect(columnsOf(probe), contains('auto_scan'));
  });

  test('v157 step is idempotent when the column already exists', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'sourceautoscan157idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 156');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await migrated.customSelect('SELECT 1').get();
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 172);
    expect(columnsOf(probe), contains('auto_scan'));
  });
}
