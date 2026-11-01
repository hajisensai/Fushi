import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v140：`media_sources` 加隐私来源开关 `is_private`（反馈 kEAgATi1LF）。纯加列、
/// 存量来源 false（照旧上传排行榜）；列已存在（早期步骤按当前定义建的表）时跳过。
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

  test('v139 → v140 adds is_private; existing sources stay public', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'sourceprivate140',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v139 形态：没有 is_private 列，已有一条来源。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE media_sources DROP COLUMN is_private');
    raw.execute(
      'INSERT INTO media_sources (label, media_kind, transport, root_path, '
      "created_at) VALUES ('Books', 'book', 'local', '/books', 1)",
    );
    raw.execute('PRAGMA user_version = 139');
    expect(columnsOf(raw), isNot(contains('is_private')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 143);
    final MediaSourceRow row = await migrated
        .select(migrated.mediaSources)
        .getSingle();
    expect(row.label, 'Books');
    expect(row.isPrivate, isFalse, reason: '存量来源默认公开，行为与升级前一致');
    expect(await migrated.privateMediaSourceIds(), isEmpty);

    // 开关只写这一列。
    await migrated.updateMediaSourcePrivate(row.id, true);
    final MediaSourceRow flipped = await migrated
        .select(migrated.mediaSources)
        .getSingle();
    expect(flipped.isPrivate, isTrue);
    expect(flipped.label, 'Books');
    expect(flipped.rootPath, '/books');
    expect(await migrated.privateMediaSourceIds(), <int>{row.id});
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
    expect(columnsOf(probe), contains('is_private'));
  });

  test('v140 step is idempotent when the column already exists', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'sourceprivate140idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 139');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await migrated.customSelect('SELECT 1').get();
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
    expect(columnsOf(probe), contains('is_private'));
  });
}
