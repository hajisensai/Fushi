import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';

/// 移除一个扫描根（source library），连带处理视频下载对它的引用（BUG-2755）。
///
/// - 订阅与还没整理完的下载任务：[migrateVideoDownloadsTo] 非 null 时在删除的
///   同一事务里改写到该来源；否则按 [disableVideoDownloadSubscriptions] 停用订阅
///   （见 [FushiDatabase.deleteMediaSource]）。
/// - 默认下载来源偏好 `video_download_target_source_id` 指向被删来源时改指迁移
///   目标；没有迁移目标就清空（回到「未选 = 取第一个可用来源」）。
/// - 网络来源凭据随行清除（本地来源无凭据，deleteSecret 幂等无副作用）。
/// - iOS 本地来源在 app 生命周期内持有的安全作用域访问随行释放（BUG-3697；
///   其它平台 / 未激活时 no-op）。
/// - 已完成的下载任务还在被删来源根下做种：经 [videoDownloadPipeline] 把这些种子
///   从下载后端摘掉（不删文件），否则用户删掉旧目录后引擎会在原处重下（BUG-2776）。
/// - 音乐曲目行不挂来源外键：先把这个根下的曲目软删（与扫描器「文件已不在」同一
///   方法），否则删掉音乐扫描根会在曲库里留下孤儿曲目，之后重扫也清不掉
///   （BUG-3785）。非音乐来源下没有曲目，这一步是空操作。
Future<void> removeSourceLibrary({
  required FushiDatabase database,
  required PreferencesRepository prefs,
  required int sourceId,
  int? migrateVideoDownloadsTo,
  bool disableVideoDownloadSubscriptions = false,
  VideoDownloadPipelineService? videoDownloadPipeline,
}) async {
  await database.softDeleteMissingMusicTracks(
    sourceId: sourceId,
    seenTrackUids: const <String>{},
    deletedAt: DateTime.now().millisecondsSinceEpoch,
  );
  await database.deleteMediaSource(
    sourceId,
    migrateVideoDownloadsTo: migrateVideoDownloadsTo,
    disableVideoDownloadSubscriptions: disableVideoDownloadSubscriptions,
  );
  await SourceLibraryCredentialStore(database).deleteSecret(sourceId);
  await SourceFolderAccess.instance.release(sourceId);
  if (prefs.videoDownloadTargetSourceId == sourceId) {
    await prefs.setVideoDownloadTargetSourceId(migrateVideoDownloadsTo);
  }
  await videoDownloadPipeline?.releaseOrphanedCompletedSeeds();
}
