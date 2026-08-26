/// 视频库删除的 UI 侧统一入口：把删除确认框的 [DeleteDecision] 落到仓库层，并在用户
/// 勾了「同时删除本地文件」时联动对账下载任务。
///
/// 为什么不塞进 [VideoBookRepository]：仓库层不认识下载管线（管线依赖仓库，反过来
/// 会成环）；对账靠仓库回调出的「真删掉的路径」在这一层接线。视频页单删 / 批删共用，
/// 保证两条路径的语义一字不差。
library;

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart'
    show
        VideoDownloadPipelineService,
        reconcileVideoDownloadJobsAfterLocalDelete;
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';

/// 删掉 [bookUids] 对应的视频行 + app 副本；[decision].deleteLocalFiles 为真时再删
/// 原始视频文件并对账下载任务。返回真删掉的行数。
Future<int> deleteVideoBooksWithDecision({
  required VideoBookRepository repo,
  required FushiDatabase database,
  required VideoDownloadPipelineService? pipeline,
  required Iterable<String> bookUids,
  required DeleteDecision decision,
  bool compactDatabase = true,
  Future<void> Function()? afterDeleteBeforeReclaim,
}) {
  return repo.deleteVideoBooksAndReclaimAssets(
    bookUids,
    scope: decision.scope,
    compactDatabase: compactDatabase,
    deleteLocalFiles: decision.deleteLocalFiles,
    onLocalFilesDeleted: decision.deleteLocalFiles
        ? (Set<String> deletedPaths) async {
            await reconcileVideoDownloadJobsAfterLocalDelete(
              database: database,
              deletedPaths: deletedPaths,
              pipeline: pipeline,
            );
            database.notifyVideoLibraryChanged();
          }
        : null,
    afterDeleteBeforeReclaim: afterDeleteBeforeReclaim,
  );
}
