import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/remote_deletion_filter.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v142：`sync_deletion_tombstones` 加 `cloud_folder_name`（删书时记下的云盘书文件夹
/// 名）与 `cloud_folder_state`（文件夹处置结论）。
///
/// 承重的是升级语义：v142 之前的版本发布「从所有设备删除」墓碑时**从不**删云盘书
/// 文件夹，所以存量墓碑哪怕已发布，残留也还在云盘上。升级后这些墓碑必须读成「未处置」，
/// 云盘书库的远端占位卡继续藏——不能把「已发布」当成「文件夹已删」，否则用户以前删过的
/// 书全部回到远端书架。
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
      "PRAGMA table_info('sync_deletion_tombstones')",
    ))
      row['name'] as String,
  };

  final String cloudSource = cloudRemoteLibrarySourceId(
    SyncBackendType.webDav.name,
  );

  test('v141 → v142：存量已发布的书墓碑读成未处置，云盘书库占位卡继续藏', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'tombcloud142',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v141 形态：没有两列；旧版本「从所有设备删除」留下一条已发布的书墓碑
    // （旧版本发布时没删云盘文件夹）和一条还没发布的。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute(
      'ALTER TABLE sync_deletion_tombstones DROP COLUMN cloud_folder_name',
    );
    raw.execute(
      'ALTER TABLE sync_deletion_tombstones DROP COLUMN cloud_folder_state',
    );
    raw.execute(
      'INSERT INTO sync_deletion_tombstones '
      '(media_type, item_key, deleted_at, remote_published_at) VALUES '
      "('book', 'Old Published', 100, 200), "
      "('book', 'Old Pending', 300, 0), "
      "('video', 'vid-uid', 400, 500)",
    );
    raw.execute('PRAGMA user_version = 141');
    expect(columnsOf(raw), isNot(contains('cloud_folder_state')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 143);
    final List<SyncDeletionTombstoneRow> rows = await migrated
        .getSyncDeletionTombstonesOfType(SyncTombstoneKind.book.dbValue);
    expect(rows, hasLength(2));
    for (final SyncDeletionTombstoneRow row in rows) {
      expect(row.cloudFolderName, isNull, reason: row.itemKey);
      expect(
        TombstoneCloudFolderState.fromDb(row.cloudFolderState),
        TombstoneCloudFolderState.pending,
        reason: row.itemKey,
      );
    }
    expect(
      rows
          .singleWhere(
            (SyncDeletionTombstoneRow r) => r.itemKey == 'Old Published',
          )
          .remotePublishedAt,
      200,
      reason: '发布状态原样保留',
    );

    expect(
      await loadPendingRemoteDeletionKeys(
        migrated,
        SyncTombstoneKind.book,
        remoteLibrarySourceId: cloudSource,
      ),
      <String>{'Old Published', 'Old Pending'},
      reason: '旧版本发布时没删云盘文件夹：升级后已发布的也得继续藏',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
    expect(
      columnsOf(probe),
      containsAll(<String>['cloud_folder_name', 'cloud_folder_state']),
    );
  });

  test('v142 步幂等：两列已在（按当前定义建的表）时跳过', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'tombcloud142idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 141');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await migrated.writeSyncDeletionTombstone(
      SyncTombstoneKind.book.dbValue,
      'peer-key',
      1,
      cloudFolderName: 'Re%3AZero',
    );
    final SyncDeletionTombstoneRow row =
        (await migrated.getSyncDeletionTombstones()).single;
    expect(row.cloudFolderName, 'Re%3AZero');
    expect(row.cloudFolderState, TombstoneCloudFolderState.pending.dbValue);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 143);
  });
}
