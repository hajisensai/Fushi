import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 远端占位卡要藏掉的本端删除墓碑键（[kind] 类，对 [remoteLibrarySourceId] 这个来源
/// 仍然有效的那些），判据见 [pendingRemoteDeletionKeys]。
///
/// **必须在取远端清单之前调用**：互联来源按推送基线判「墓碑是否已送达 host」，先读基线
/// 再取清单，才能保证「基线说已送达」时手里的清单是删除之后取的（删除成功会同步作废
/// 清单缓存，见 `InterconnectSyncBackend.remoteLibraryMutationRevision`）。反过来先取
/// 清单、后读基线，中间恰好推送完成，就会拿删除前的清单配上已推进的基线，把刚删的
/// 条目放出来。
Future<Set<String>> loadPendingRemoteDeletionKeys(
  FushiDatabase db,
  SyncTombstoneKind kind, {
  required String remoteLibrarySourceId,
}) async {
  final Map<String, int> deletedAtByKey = await db
      .getSyncDeletionDeletedAtByKey(kind.dbValue);
  if (deletedAtByKey.isEmpty) return const <String>{};
  final bool hostApplies =
      remoteLibrarySourceId == kInterconnectRemoteLibrarySourceId;
  return pendingRemoteDeletionKeys(
    deletedAtByKey: deletedAtByKey,
    sourceAppliesDeletions: hostApplies,
    deliveredThroughMs: hostApplies
        ? await SyncRepository(db).getDeletionTombstonesPushBaselineMs()
        : 0,
  );
}
