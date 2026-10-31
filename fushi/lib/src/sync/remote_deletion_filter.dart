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
  // 云盘书库的书：墓碑记着这本书云盘文件夹的处置结论（v142 `cloudFolderState`）。
  // 文件夹已经删掉、或处置时核实云盘上本就没有，之后同名书文件夹只可能是删除之后
  // 重新导入、重新上传的新书——不能再藏，否则别的设备重新导入的书在本机永远看不见。
  // 其余（未处置）一律藏：文件夹可能还在。**不能拿「已发布」代替「文件夹已删」**：
  // v142 之前的版本发布「从所有设备删除」墓碑时从不删云盘文件夹，那些墓碑全是已发布
  // + 未处置，残留还在云盘上，放出来就是把用户删过的书全部送回远端书架。
  //
  // 藏的键：墓碑键（bookKey / 对端键）+ 删除时记下的云盘文件夹名——书架按
  // `sanitizeTtuFilename(远端书名)` = 文件夹名比对，墓碑键是对端键 / 别名时只有后者
  // 命得中。
  if (kind == SyncTombstoneKind.book &&
      remoteLibrarySourceId.startsWith(kCloudRemoteLibrarySourceIdPrefix)) {
    return <String>{
      for (final SyncDeletionTombstoneRow row
          in await db.getSyncDeletionTombstonesOfType(kind.dbValue))
        if (!TombstoneCloudFolderState.fromDb(
          row.cloudFolderState,
        ).resolved) ...<String>[row.itemKey, ?row.cloudFolderName],
    };
  }
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
