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
///
/// [DeleteDecision.deleteStatistics] 也在这一层落地，且必须排在删行**之前**：
/// `deleteVideoStatisticsForIdentity` 要按 `title` 立墓碑，还要回查 `video_books`
/// 做同名歧义复核——行一删，这两个判据就都没了。
library;

import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, LocalFileDeleteReport, VideoBookRow;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart'
    show
        VideoDownloadPipelineService,
        prepareVideoDownloadJobsForLocalDelete,
        reconcileVideoDownloadJobsAfterLocalDelete;
import 'package:fushi_engine/media/video/bluray/bluray_library_title.dart'
    show
        BlurayExtraDeletionTombstone,
        planBlurayExtraDeletionTombstones,
        writeBlurayExtraDeletionTombstones;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show LocalVideoFileDeleteHooks;
import 'package:fushi_engine/media/video/video_work_companions.dart'
    show videoWorkCompanionBookUids;
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/sync/local_file_delete_feedback.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

/// [deleteVideoBooksWithDecision] 的结果：删了几行 + 没删掉的行（BUG-2754：某条
/// 失败不拖累其余条，失败条目留在库里，由 UI 如实提示）+ 本机原件的逐条删除结果。
typedef VideoLibraryDeleteResult = ({
  int deleted,
  List<VideoBookDeleteFailure> failed,
  LocalFileDeleteReport localFiles,
});

/// 删掉 [bookUids] 对应的视频行 + app 副本；[decision].deleteLocalFiles 为真时再删
/// 原始视频文件（含跟着它走的 sidecar 字幕）并联动下载任务；
/// [decision].deleteStatistics 为真时先把这些视频攒下的统计一并删掉。
///
/// [removeFromCollections] 见 [VideoBookRepository.deleteVideoBooks]：只有「删掉从
/// 配对设备下载来的本机副本」传 false（那一集仍在对端，合集成员留着退回远端集）。
Future<VideoLibraryDeleteResult> deleteVideoBooksWithDecision({
  required VideoBookRepository repo,
  required FushiDatabase database,
  required VideoDownloadPipelineService? pipeline,
  required Iterable<String> bookUids,
  required DeleteDecision decision,
  bool compactDatabase = true,
  bool removeFromCollections = true,
  Future<void> Function()? afterDeleteBeforeReclaim,
}) async {
  // 删的是一整部作品时，它名下不在合集里的附属行（本地特典 / 下载整理出的附件）
  // 跟着一起删，否则正片没了、特典行和特典文件原样留下（fuQcFmZZxb / BUG-3802）。
  // 「只删本机副本、成员行保留」（removeFromCollections: false）的作品仍在，不扩。
  final List<String> requested = bookUids.toList(growable: false);
  final List<String> targetUids = removeFromCollections
      ? <String>[
          ...requested,
          ...await videoWorkCompanionBookUids(database, requested),
        ]
      : requested;
  LocalFileDeleteReport report = const LocalFileDeleteReport();
  if (decision.deleteStatistics) {
    await _deleteStatisticsForVideos(
      repo: repo,
      database: database,
      bookUids: targetUids,
    );
  }
  // 蓝光盘特典不在盘合集里，删掉它不留任何成员墓碑，下一次重扫会原样建回来
  // （PR #2058 审查）。删前认出特典（删后合集成员关系就没了），删成后在盘合集
  // 自然键下记墓碑，扫描器据此跳过。best-effort：墓碑记不上不拦删除。
  List<BlurayExtraDeletionTombstone> extraTombstones =
      const <BlurayExtraDeletionTombstone>[];
  try {
    extraTombstones =
        await planBlurayExtraDeletionTombstones(database, targetUids);
  } catch (e, stack) {
    ErrorLogService.instance
        .log('VideoLibraryDelete.planBlurayExtraTombstones', e, stack);
  }
  int deleted;
  List<VideoBookDeleteFailure> failed = const <VideoBookDeleteFailure>[];
  try {
    deleted = await repo.deleteVideoBooksAndReclaimAssets(
      targetUids,
      scope: decision.scope,
      compactDatabase: compactDatabase,
      deleteLocalFiles: decision.deleteLocalFiles,
      removeFromCollections: removeFromCollections,
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
  } on VideoBooksDeleteException catch (e) {
    // 部分失败：成功的那些已删完、回收完（仓库层把尾活跑完才抛）；失败的逐条留痕。
    deleted = e.deletedCount;
    failed = e.failures;
    for (final VideoBookDeleteFailure failure in e.failures) {
      ErrorLogService.instance.log(
        'VideoLibraryDelete.deleteRow',
        failure.error,
        failure.stackTrace,
      );
    }
  }
  if (extraTombstones.isNotEmpty) {
    final Set<String> failedUids = <String>{
      for (final VideoBookDeleteFailure f in failed) f.bookUid,
    };
    try {
      await writeBlurayExtraDeletionTombstones(
        database,
        extraTombstones,
        deletedUids: <String>{
          for (final String uid in targetUids)
            if (!failedUids.contains(uid)) uid,
        },
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('VideoLibraryDelete.writeBlurayExtraTombstones', e, stack);
    }
  }
  return (deleted: deleted, failed: failed, localFiles: report);
}

/// 把一次视频库删除的失败告诉用户（BUG-2754）：有行没删掉就弹 warning toast
/// 说清几条留在库里（逐条原因已在 [deleteVideoBooksWithDecision] 记进错误日志），
/// 再交给 [reportLocalFileDeleteFailures] 报本机原件的删除失败。全部成功时什么都
/// 不做——成功提示由调用方按自己的语境给。
void reportVideoLibraryDeleteFailures(
  VideoLibraryDeleteResult result, {
  required String source,
}) {
  if (result.failed.isNotEmpty) {
    FushiToast.show(
      msg: t.video_library_delete_rows_failed(n: result.failed.length),
      severity: ToastSeverity.warning,
    );
  }
  reportLocalFileDeleteFailures(result.localFiles, source: source);
}

/// 删这些视频攒下的统计（「同时删除统计数据」勾选的落地）。
///
/// 逐条走 [FushiDatabase.deleteVideoStatisticsForIdentity]：它在一个事务里删
/// `study_segments`（唯一事实表）+「已看过区间」偏好 + legacy 的观看时长/字数行 +
/// 该视频的查词/制卡计数，并按媒体身份与 title 两级立碑——不立碑的话下一轮聚合同步
/// 会把对端还留着的段整批灌回来（BUG-2215）。
///
/// `includeUnattributed: false`：只删挂在这条 `bookUid` 名下的行。同名视频的**无
/// 身份**遗留行留给统计页自己处置，删一条视频不该按标题连坐别人的历史。
///
/// 逐条 best-effort：某一条统计删失败不该拦住整批视频的删除（行还没删，用户重试
/// 即可），失败只记日志。
Future<void> _deleteStatisticsForVideos({
  required VideoBookRepository repo,
  required FushiDatabase database,
  required Iterable<String> bookUids,
}) async {
  for (final String bookUid in bookUids.toSet()) {
    try {
      // title 必须在行还活着时取：墓碑与同名歧义复核都以它为判据。
      final VideoBookRow? row = await repo.getByBookUid(bookUid);
      if (row == null) continue;
      await database.deleteVideoStatisticsForIdentity(
        title: row.title,
        bookUid: bookUid,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoLibraryDelete.deleteStatistics', e, stack);
    }
  }
}
