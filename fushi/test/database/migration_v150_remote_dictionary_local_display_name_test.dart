import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v150：`remote_dictionary_metadata.local_display_name`——本机给服务器词典起的显示名
/// （设备本地，不归配置）。升级加列、存量行原样且新列为 NULL；已有该列时幂等跳过；
/// 目录刷新的 upsert 不碰它。
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

  bool hasColumn(sqlite.Database raw) => raw
      .select("PRAGMA table_info('remote_dictionary_metadata')")
      .any((sqlite.Row r) => r['name'] == 'local_display_name');

  RemoteDictionaryMetadataCompanion catalogRow(
    String host,
    String name, {
    String? displayName,
    int lastSeenAt = 1,
  }) => RemoteDictionaryMetadataCompanion(
    hostId: Value<String>(host),
    name: Value<String>(name),
    type: const Value<String>('term'),
    displayName: Value<String?>(displayName),
    lastSeenAt: Value<int>(lastSeenAt),
    missingSince: const Value<int?>(null),
    order: const Value<int>(0),
  );

  test('v149 → v150：加列，存量目录行原样、新列为 NULL', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'remotedictv150',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v149 形状：重建不带 local_display_name 的表并放一条存量行。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE remote_dictionary_metadata');
    raw.execute(
      'CREATE TABLE remote_dictionary_metadata ('
      'host_id TEXT NOT NULL, name TEXT NOT NULL, '
      "type TEXT NOT NULL DEFAULT 'term', format_key TEXT NULL, "
      'revision TEXT NULL, display_name TEXT NULL, source_language TEXT NULL, '
      'last_seen_at INTEGER NOT NULL, missing_since INTEGER NULL, '
      '"order" INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0 '
      'CHECK ("hidden" IN (0, 1)), PRIMARY KEY (host_id, name))',
    );
    raw.execute(
      'INSERT INTO remote_dictionary_metadata '
      '(host_id, name, revision, last_seen_at, "order", hidden) '
      "VALUES ('h1', 'Daijirin', 'r7', 5, 3, 1)",
    );
    raw.execute('PRAGMA user_version = 149');
    expect(hasColumn(raw), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 150);
    final RemoteDictionaryMetaRow row =
        (await migrated.getAllRemoteDictionaryMetadata()).single;
    expect(row.name, 'Daijirin');
    expect(row.revision, 'r7');
    expect(row.order, 3);
    expect(row.hidden, isTrue);
    expect(row.localDisplayName, isNull);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 150);
    expect(hasColumn(probe), isTrue);
  });

  test('v150 步幂等：列已在时跳过，已写的本机显示名不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'remotedictv150idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.upsertRemoteDictionaryCatalog(catalogRow('h1', 'Daijirin'));
    await seeded.setRemoteDictionaryLocalDisplayName(
      hostId: 'h1',
      name: 'Daijirin',
      localDisplayName: '大辞林（客厅）',
    );
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 149');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await migrated.getAllRemoteDictionaryMetadata()).single.localDisplayName,
      '大辞林（客厅）',
    );
    await migrated.close();
  });

  group('本机显示名写入', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('目录 upsert 不碰本机显示名；空白 = 清掉；无行命中 0', () async {
      await db.upsertRemoteDictionaryCatalog(
        catalogRow('h1', 'Daijirin', displayName: 'Host name'),
      );
      expect(
        await db.setRemoteDictionaryLocalDisplayName(
          hostId: 'h1',
          name: 'Daijirin',
          localDisplayName: '  Mine  ',
        ),
        1,
      );
      await db.upsertRemoteDictionaryCatalog(
        catalogRow(
          'h1',
          'Daijirin',
          displayName: 'Renamed on host',
          lastSeenAt: 9,
        ),
      );
      RemoteDictionaryMetaRow row =
          (await db.getAllRemoteDictionaryMetadata()).single;
      expect(row.displayName, 'Renamed on host');
      expect(row.localDisplayName, 'Mine', reason: '刷新目录不得冲掉本机起的名字');

      await db.setRemoteDictionaryLocalDisplayName(
        hostId: 'h1',
        name: 'Daijirin',
        localDisplayName: '   ',
      );
      row = (await db.getAllRemoteDictionaryMetadata()).single;
      expect(row.localDisplayName, isNull);

      expect(
        await db.setRemoteDictionaryLocalDisplayName(
          hostId: 'h1',
          name: 'Ghost',
          localDisplayName: 'x',
        ),
        0,
      );
    });
  });
}
