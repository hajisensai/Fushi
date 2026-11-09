import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v149：新表 `remote_dictionary_metadata`（已配对服务器上托管的词典在本机的目录行）。
/// 纯新增：升级建表、不碰存量词典；建过的库幂等跳过。另钉死 DAO 的写入分工：目录刷新
/// 的 upsert 只动目录列，配置拥有的 order / hidden 只经 setRemoteDictionaryProfileColumns。
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

  bool hasTable(sqlite.Database raw) => raw
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='remote_dictionary_metadata'",
      )
      .isNotEmpty;

  RemoteDictionaryMetadataCompanion catalogRow(
    String host,
    String name, {
    int order = 0,
    String? revision,
    int lastSeenAt = 1,
  }) => RemoteDictionaryMetadataCompanion(
    hostId: Value<String>(host),
    name: Value<String>(name),
    type: const Value<String>('term'),
    formatKey: const Value<String?>('yomichan'),
    revision: Value<String?>(revision),
    lastSeenAt: Value<int>(lastSeenAt),
    missingSince: const Value<int?>(null),
    order: Value<int>(order),
  );

  test('v148 → v149：建出服务器词典目录表，存量本机词典原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'remotedictv149',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE remote_dictionary_metadata');
    raw.execute(
      'INSERT INTO dictionary_metadata (name, format_key, "order") '
      "VALUES ('JMdict', 'yomichan', 0)",
    );
    raw.execute('PRAGMA user_version = 148');
    expect(hasTable(raw), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 149);
    await migrated.upsertRemoteDictionaryCatalog(catalogRow('h1', 'Daijirin'));
    expect(
      (await migrated.getAllRemoteDictionaryMetadata()).single.name,
      'Daijirin',
    );
    expect(
      (await migrated.getAllDictionaryMetadata()).map((r) => r.name),
      <String>['JMdict'],
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 149);
    expect(hasTable(probe), isTrue);
  });

  test('v149 步幂等：表已在时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'remotedictv149idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.upsertRemoteDictionaryCatalog(
      catalogRow('h1', 'Daijirin', order: 7),
    );
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 148');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await migrated.getAllRemoteDictionaryMetadata()).single.order, 7);
    await migrated.close();
  });

  group('DAO 写入分工', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('目录 upsert 冲突时只改目录列，配置列（order / hidden）不动', () async {
      await db.upsertRemoteDictionaryCatalog(
        catalogRow('h1', 'Daijirin', order: 3, revision: 'r1'),
      );
      expect(
        await db.setRemoteDictionaryProfileColumns(
          hostId: 'h1',
          name: 'Daijirin',
          order: 9,
          hidden: true,
        ),
        1,
      );
      await db.upsertRemoteDictionaryCatalog(
        catalogRow('h1', 'Daijirin', order: 0, revision: 'r2', lastSeenAt: 50),
      );
      final RemoteDictionaryMetaRow row =
          (await db.getAllRemoteDictionaryMetadata()).single;
      expect(row.revision, 'r2');
      expect(row.lastSeenAt, 50);
      expect(row.order, 9, reason: '刷新目录不得冲掉配置排好的顺序');
      expect(row.hidden, isTrue, reason: '刷新目录不得把关掉的词典打开');
    });

    test('配置列只写已有行：没有目录行时命中 0 行、不插行', () async {
      expect(
        await db.setRemoteDictionaryProfileColumns(
          hostId: 'h1',
          name: 'Ghost',
          order: 1,
          hidden: false,
        ),
        0,
      );
      expect(await db.getAllRemoteDictionaryMetadata(), isEmpty);
    });

    test('标消失保留最早时刻；标在场清 missingSince；按 host / 单条删除', () async {
      await db.upsertRemoteDictionaryCatalog(catalogRow('h1', 'A'));
      await db.upsertRemoteDictionaryCatalog(catalogRow('h1', 'B'));
      await db.upsertRemoteDictionaryCatalog(catalogRow('h2', 'A'));

      expect(
        await db.markRemoteDictionariesMissing('h1', <String>['A'], 10),
        1,
      );
      expect(
        await db.markRemoteDictionariesMissing('h1', <String>['A'], 20),
        0,
        reason: '已标过的不刷新时刻',
      );
      Map<String, RemoteDictionaryMetaRow> rows =
          <String, RemoteDictionaryMetaRow>{
            for (final RemoteDictionaryMetaRow r
                in await db.getAllRemoteDictionaryMetadata())
              '${r.hostId}/${r.name}': r,
          };
      expect(rows['h1/A']!.missingSince, 10);
      expect(rows['h2/A']!.missingSince, isNull, reason: '别的 host 的同名行不受影响');

      await db.markRemoteDictionariesPresent('h1', <String>['A'], 30);
      rows = <String, RemoteDictionaryMetaRow>{
        for (final RemoteDictionaryMetaRow r
            in await db.getAllRemoteDictionaryMetadata())
          '${r.hostId}/${r.name}': r,
      };
      expect(rows['h1/A']!.missingSince, isNull);
      expect(rows['h1/A']!.lastSeenAt, 30);

      expect(await db.deleteRemoteDictionary('h1', 'B'), 1);
      expect(await db.deleteRemoteDictionariesForHost('h1'), 1);
      expect(
        (await db.getAllRemoteDictionaryMetadata()).map(
          (RemoteDictionaryMetaRow r) => '${r.hostId}/${r.name}',
        ),
        <String>['h2/A'],
      );
    });
  });
}
