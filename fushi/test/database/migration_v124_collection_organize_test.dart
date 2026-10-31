import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_merge.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v124（AI 整理库 spec `docs/specs/2026-10-20-ai-library-organize-design.md` §5）：
/// 合集来源 / 分组身份列、删除哨兵上的分组键与「并掉」标记、整理记录表；以及 DAO 的
/// 所有权单调（用户写入口接手整理器合集，自动路径不接手）。
void main() {
  Set<String> columnsOf(sqlite.Database raw, String table) => <String>{
    for (final sqlite.Row row in raw.select("PRAGMA table_info('$table')"))
      row['name'] as String,
  };

  test('v123 → v124 加列建表、目录合集回填 folder、重跑幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync('organize_v124');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    final int folder = await db.createMediaCollection('Folder');
    await db.customStatement(
      "UPDATE media_collections SET source_folder_path = '/x' WHERE id = $folder",
    );
    await db.createMediaCollection('Mine');
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE library_organize_changes');
    raw.execute('DROP TABLE library_organize_runs');
    for (final String col in <String>[
      'origin',
      'organize_key',
      'organize_aliases',
    ]) {
      raw.execute('ALTER TABLE media_collections DROP COLUMN $col');
    }
    raw.execute(
      'ALTER TABLE collection_member_tombstones DROP COLUMN organize_key',
    );
    raw.execute(
      'ALTER TABLE collection_member_tombstones DROP COLUMN organize_merged',
    );
    raw.execute('PRAGMA user_version = 123');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 142);
    final Map<String, String> originByName = <String, String>{
      for (final MediaCollectionRow r
          in await migrated.getAllMediaCollections())
        r.name: r.origin,
    };
    expect(originByName, <String, String>{'Folder': 'folder', 'Mine': 'user'});
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(
      columnsOf(probe, 'media_collections'),
      containsAll(<String>['origin', 'organize_key', 'organize_aliases']),
    );
    expect(
      columnsOf(probe, 'collection_member_tombstones'),
      containsAll(<String>['organize_key', 'organize_merged']),
    );
    expect(columnsOf(probe, 'library_organize_runs'), contains('domain'));
    expect(
      columnsOf(probe, 'library_organize_changes'),
      contains('payload_json'),
    );
    probe.execute('PRAGMA user_version = 123');
    probe.dispose();
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getAllMediaCollections()).length, 2);
    await reopened.close();
  });

  group('所有权单调', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<int> ai() => db.createMediaCollection(
      'S',
      origin: CollectionOrigin.ai,
      organizeKey: 't:books:s',
    );
    Future<String> originOf(int id) async =>
        (await db.getMediaCollectionById(id))!.origin;

    test('自动路径加成员不接手', () async {
      final int id = await ai();
      await db.addToCollection(id, MediaKind.epub, 'b1', userIntent: false);
      await db.addToCollection(id, MediaKind.epub, 'b2', userIntent: false);
      // 留一个成员：移空会自动删合集。
      await db.removeFromCollection(
        id,
        MediaKind.epub,
        'b1',
        userIntent: false,
      );
      expect(await originOf(id), 'ai');
    });

    for (final (String label, Future<void> Function(int id) act)
        in <(String, Future<void> Function(int))>[
          ('加成员', (int id) => db.addToCollection(id, MediaKind.epub, 'b9')),
          (
            '移出成员',
            (int id) async {
              await db.addToCollection(
                id,
                MediaKind.epub,
                'b2',
                userIntent: false,
              );
              await db.removeFromCollection(id, MediaKind.epub, 'b2');
            },
          ),
          ('改名', (int id) => db.renameMediaCollection(id, 'S2')),
          (
            '手动排序',
            (int id) => db.reorderCollectionItems(
              id,
              const <CollectionMemberKey>[(mediaType: 'epub', entryKey: 'b1')],
            ),
          ),
        ]) {
      test('用户$label → 接手为 user，且不再回退', () async {
        final int id = await ai();
        await db.addToCollection(id, MediaKind.epub, 'b1', userIntent: false);
        await act(id);
        final MediaCollectionRow? row =
            await db.getMediaCollectionById(id) ??
            await db.getMediaCollectionByNaturalKey('S2', 'collection');
        expect(row!.origin, 'user');
        await db.setMediaCollectionOrganizeState(
          row.id,
          origin: CollectionOrigin.parse(
            CollectionOrigin.merge(
              CollectionOrigin.ai,
              CollectionOrigin.user,
            ).dbValue,
          ),
          organizeKey: row.organizeKey,
          organizeAliases: const <String>{},
        );
        expect(await originOf(row.id), 'user');
      });
    }

    test('删除 = 拒绝；合并掉 = 不是拒绝，键记进胜方别名', () async {
      final int rejected = await db.createMediaCollection(
        'R',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-r',
      );
      await db.addToCollection(
        rejected,
        MediaKind.epub,
        'x',
        userIntent: false,
      );
      final int winner = await db.createMediaCollection(
        'W',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-w',
      );
      final int loser = await db.createMediaCollection(
        'L',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-l',
      );
      await db.addToCollection(winner, MediaKind.epub, 'a', userIntent: false);
      await db.addToCollection(loser, MediaKind.epub, 'b', userIntent: false);
      await db.deleteMediaCollection(rejected);
      await mergeMediaCollectionsInto(
        db,
        targetId: winner,
        sourceIds: <int>[loser],
        userIntent: false,
      );
      expect(await db.getRejectedOrganizeKeys(), <String>{'k-r'});
      final MediaCollectionRow w = (await db.getMediaCollectionById(winner))!;
      expect(w.origin, 'ai');
      expect(decodeOrganizeAliases(w.organizeAliases), <String>{'k-l'});
      expect(
        (await db.getCollectionItems(
          winner,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        <String>['a', 'b'],
      );
      // 拒绝覆盖被删合集吸收过的别名（另一台设备的 AI 用另一种原名算出别名里的键时
      // 同样不再建）。
      final int absorbed = await db.createMediaCollection(
        'Z',
        origin: CollectionOrigin.ai,
        organizeKey: 'k-z',
      );
      await db.addToCollection(
        absorbed,
        MediaKind.epub,
        'z',
        userIntent: false,
      );
      await db.setMediaCollectionOrganizeState(
        absorbed,
        origin: CollectionOrigin.ai,
        organizeKey: 'k-z',
        organizeAliases: <String>{'k-z2'},
      );
      await db.deleteMediaCollection(absorbed);
      expect(await db.getRejectedOrganizeKeys(), <String>{
        'k-r',
        'k-z',
        'k-z2',
      });
      // 自动路径删合集不是用户表态：不记拒绝。
      final int auto = await db.createMediaCollection(
        'Auto',
        origin: CollectionOrigin.rule,
        organizeKey: 'k-auto',
      );
      await db.addToCollection(auto, MediaKind.epub, 'q', userIntent: false);
      await db.deleteMediaCollection(auto, userIntent: false);
      expect(await db.getRejectedOrganizeKeys(), isNot(contains('k-auto')));
    });

    test('合并不把胜方里用户移出过的成员并回来', () async {
      final int winner = await db.createMediaCollection(
        'W',
        origin: CollectionOrigin.ai,
        organizeKey: 'k',
      );
      await db.addToCollection(
        winner,
        MediaKind.epub,
        'gone',
        userIntent: false,
      );
      await db.removeFromCollection(winner, MediaKind.epub, 'gone');
      await db.addToCollection(
        winner,
        MediaKind.epub,
        'keep',
        userIntent: false,
      );
      final int loser = await db.createMediaCollection(
        'L',
        origin: CollectionOrigin.ai,
        organizeKey: 'k',
      );
      await db.addToCollection(
        loser,
        MediaKind.epub,
        'gone',
        userIntent: false,
      );
      await mergeMediaCollectionsInto(
        db,
        targetId: winner,
        sourceIds: <int>[loser],
        userIntent: false,
        skipTombstonedInTarget: true,
      );
      expect(
        (await db.getCollectionItems(
          winner,
        )).map((MediaCollectionItemRow m) => m.entryKey),
        <String>['keep'],
      );
    });
  });
}
