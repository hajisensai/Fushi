import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_deletion_filter.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3508 审查跟进：远端占位卡的删除墓碑过滤不再拿 host importedAt 比本端
/// deletedAt（跨设备时钟偏差），改为「墓碑是否已送达 host」（本端推送基线，同一台
/// 设备的时钟）+ host 删除成功时作废远端清单缓存。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('互联来源：按推送基线只藏未送达的墓碑；云盘来源：墓碑在就藏', () async {
    await db.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'delivered',
      1000,
    );
    await db.writeSyncDeletionTombstone(
      SyncTombstoneKind.video.dbValue,
      'pending',
      5000,
    );
    // 别的种类的墓碑不串进来。
    await db.writeSyncDeletionTombstone(
      SyncTombstoneKind.book.dbValue,
      'a-book',
      5000,
    );
    await SyncRepository(db).setDeletionTombstonesPushBaselineMs(2000);

    expect(
      await loadPendingRemoteDeletionKeys(
        db,
        SyncTombstoneKind.video,
        remoteLibrarySourceId: kInterconnectRemoteLibrarySourceId,
      ),
      <String>{'pending'},
    );
    expect(
      await loadPendingRemoteDeletionKeys(
        db,
        SyncTombstoneKind.video,
        remoteLibrarySourceId: cloudRemoteLibrarySourceId('webdav'),
      ),
      <String>{'delivered', 'pending'},
      reason: '云盘从不执行墓碑，清单里那份只能是被删的残留',
    );
    expect(
      await loadPendingRemoteDeletionKeys(
        db,
        SyncTombstoneKind.book,
        remoteLibrarySourceId: kInterconnectRemoteLibrarySourceId,
      ),
      <String>{'a-book'},
    );
  });

  test('host 删除成功（remoteLibraryMutationRevision）同步作废互联来源的清单缓存', () async {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final RemoteLibraryCache cache = container.read(remoteLibraryCacheProvider);

    Future<List<String>> read(String sourceId, List<String> value) =>
        cache.read<List<String>>(
          sourceId: sourceId,
          key: RemoteLibraryCacheKeys.books,
          fetch: () async => value,
        );

    await read(kInterconnectRemoteLibrarySourceId, <String>['deleted-book']);
    final String cloud = cloudRemoteLibrarySourceId('webdav');
    await read(cloud, <String>['cloud-book']);
    expect(
      cache.isFresh(
        kInterconnectRemoteLibrarySourceId,
        RemoteLibraryCacheKeys.books,
      ),
      isTrue,
    );

    InterconnectSyncBackend.instance.remoteLibraryMutationRevision.value++;

    expect(
      cache.isFresh(
        kInterconnectRemoteLibrarySourceId,
        RemoteLibraryCacheKeys.books,
      ),
      isFalse,
      reason: '删除之前取的清单还带着被删条目，送达后必须重取',
    );
    expect(
      cache.isFresh(cloud, RemoteLibraryCacheKeys.books),
      isTrue,
      reason: '只作废互联来源，云盘清单不受牵连',
    );
    expect(
      await read(kInterconnectRemoteLibrarySourceId, <String>[]),
      isEmpty,
      reason: '下一次读真的重新取数',
    );
  });
}
