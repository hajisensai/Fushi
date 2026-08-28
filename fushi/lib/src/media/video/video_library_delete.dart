/// 视频库删除的 UI 侧统一入口：把删除确认框的 [DeleteDecision] 落到仓库层，并在用户
/// 勾了「同时删除本地文件」时按正确顺序联动下载任务。
///
/// 为什么不塞进 [VideoBookRepository]：仓库层不认识下载管线（管线依赖仓库，反过来
/// 会成环）。挂钩靠仓库暴露的删除前/后两个钩子在这一层接线。视频页单删 / 批删共用，
/// 保证两条路径的语义一字不差。
///
/// 顺序是这条链路的正确性本身——**先让引用方放手，再销毁实体**：
/// 1. 删磁盘前 `MediaHandleRegistry.releaseHolding`——正握着这些文件的播放器先真放
///    句柄（Windows 上不放，`File.delete()` 直接 errno 32，用户看到「删除成功」而盘
///    上一个文件没少）；
/// 2. 删磁盘前 [prepareVideoDownloadJobsForLocalDelete]——把要消失的文件在下载后端
///    标 skip，种子才不会因为「文件缺失」被整个停掉；
/// 3. 删磁盘；
/// 4. 删磁盘后 [reconcileVideoDownloadJobsAfterLocalDelete]——按归属判据决定
///    「整个任务作废」还是「只把这几行标 skipped」。
library;

import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, LocalFileDeleteReport;
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart'
    show
        VideoDownloadPipelineService,
        prepareVideoDownloadJobsForLocalDelete,
        reconcileVideoDownloadJobsAfterLocalDelete;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_local_files.dart'
    show LocalVideoFileDeleteHooks;
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';

/// [deleteVideoBooksWithDecision] 的结果：删了几行 + 本机原件的逐条删除结果。
typedef VideoLibraryDeleteResult = ({
  int deleted,
  LocalFileDeleteReport localFiles,
});

/// 删掉 [bookUids] 对应的视频行 + app 副本；[decision].deleteLocalFiles 为真时再删
/// 原始视频文件并联动下载任务。
Future<VideoLibraryDeleteResult> deleteVideoBooksWithDecision({
  required VideoBookRepository repo,
  required FushiDatabase database,
  required VideoDownloadPipelineService? pipeline,
  required Iterable<String> bookUids,
  required DeleteDecision decision,
  bool compactDatabase = true,
  Future<void> Function()? afterDeleteBeforeReclaim,
}) async {
  LocalFileDeleteReport report = const LocalFileDeleteReport();
  final int deleted = await repo.deleteVideoBooksAndReclaimAssets(
    bookUids,
    scope: decision.scope,
    compactDatabase: compactDatabase,
    deleteLocalFiles: decision.deleteLocalFiles,
    localFileHooks: decision.deleteLocalFiles
        ? LocalVideoFileDeleteHooks(
            beforeDelete: (List<String> candidates) async {
              // ① 正握着这些文件的播放器先放句柄（Windows 上不放就是 errno 32）。
              await MediaHandleRegistry.instance.releaseHolding(candidates);
              // ② 还在做种的文件先在后端标 skip，种子才不会因缺文件被停掉。
              await prepareVideoDownloadJobsForLocalDelete(
                database: database,
                candidatePaths: candidates,
                pipeline: pipeline,
              );
            },
            afterDelete: (LocalFileDeleteReport result) async {
              report = result;
              if (result.removed.isEmpty) return;
              await reconcileVideoDownloadJobsAfterLocalDelete(
                database: database,
                deletedPaths: result.removedSet,
                pipeline: pipeline,
              );
              database.notifyVideoLibraryChanged();
            },
          )
        : null,
    afterDeleteBeforeReclaim: afterDeleteBeforeReclaim,
  );
  return (deleted: deleted, localFiles: report);
}
