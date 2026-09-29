import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 移除一个扫描根（source library），连带处理视频下载对它的引用（BUG-2755）。
///
/// - 订阅与还没整理完的下载任务：[migrateVideoDownloadsTo] 非 null 时在删除的
///   同一事务里改写到该来源；否则按 [disableVideoDownloadSubscriptions] 停用订阅
///   （见 [FushiDatabase.deleteMediaSource]）。
/// - 默认下载来源偏好 `video_download_target_source_id` 指向被删来源时改指迁移
///   目标；没有迁移目标就清空（回到「未选 = 取第一个可用来源」）。
/// - 网络来源凭据随行清除（本地来源无凭据，deleteSecret 幂等无副作用）。
Future<void> removeSourceLibrary({
  required FushiDatabase database,
  required PreferencesRepository prefs,
  required int sourceId,
  int? migrateVideoDownloadsTo,
  bool disableVideoDownloadSubscriptions = false,
}) async {
  await database.deleteMediaSource(
    sourceId,
    migrateVideoDownloadsTo: migrateVideoDownloadsTo,
    disableVideoDownloadSubscriptions: disableVideoDownloadSubscriptions,
  );
  await SourceLibraryCredentialStore(database).deleteSecret(sourceId);
  if (prefs.videoDownloadTargetSourceId == sourceId) {
    await prefs.setVideoDownloadTargetSourceId(migrateVideoDownloadsTo);
  }
}
