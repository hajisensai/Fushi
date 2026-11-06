import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi/src/media/source_library/source_folder_access.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
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
/// - 音乐曲目行不挂来源外键：移除音乐来源时先处理它名下的曲目，否则删掉音乐扫描根会
///   在曲库里留下孤儿曲目，之后重扫也清不掉（BUG-3785）。仍被另一个本地音乐来源覆盖
///   的曲目改挂过去，其余软删（[FushiDatabase.releaseMusicTracksOfSource]）。
/// - 视频来源自动登记的音乐来源（v145，反馈 QAondMh4M5）随它一起移除（[retireMusicSources]，
///   用户手动添加的音乐来源不动）。用户直接移除一个自动来源时（[recordAutoSourceDismissal]）
///   记进「不再登记」清单，之后再扫 owner 视频来源不会把它加回来。
Future<void> removeSourceLibrary({
  required FushiDatabase database,
  required PreferencesRepository prefs,
  required int sourceId,
  int? migrateVideoDownloadsTo,
  bool disableVideoDownloadSubscriptions = false,
  VideoDownloadPipelineService? videoDownloadPipeline,
  bool recordAutoSourceDismissal = true,
}) async {
  final SourceLibraryRow? row = await database.getMediaSourceById(sourceId);
  final List<SourceLibraryRow> owned = await database.listAutoMusicSourcesOf(
    sourceId,
  );
  if (owned.isNotEmpty) {
    await retireMusicSources(
      database: database,
      sourceIds: <int>{for (final SourceLibraryRow s in owned) s.id},
      alsoRemoving: <int>{sourceId},
    );
  }
  final int? owner = row?.autoOwnerSourceId;
  if (row != null && owner != null && recordAutoSourceDismissal) {
    await database.addMusicAutoSourceDismissal(owner, row.rootPath);
  }
  await database.releaseMusicTracksOfSource(sourceId);
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

/// 撤掉一组音乐来源（视频来源被删时它自动登记的那些、或扫描对账判定该撤的）：曲目
/// 仍被别的本地音乐来源覆盖的改挂过去，其余软删；再删来源行。不写「不再登记」清单
/// （这是自动撤销，不是用户的选择）。[alsoRemoving] 是同一次操作里也要删掉的来源（曲目
/// 不能改挂到它们）。
Future<void> retireMusicSources({
  required FushiDatabase database,
  required Set<int> sourceIds,
  Set<int> alsoRemoving = const <int>{},
}) async {
  final Set<int> gone = <int>{...sourceIds, ...alsoRemoving};
  for (final int id in sourceIds) {
    await database.releaseMusicTracksOfSource(id, excludeSourceIds: gone);
  }
  for (final int id in sourceIds) {
    await database.deleteMediaSource(id);
    await SourceLibraryCredentialStore(database).deleteSecret(id);
    await SourceFolderAccess.instance.release(id);
  }
}

/// 移除视频来源 [ownerId] 时会一并移除的自动音乐来源（确认框里提示数量）：来源数与
/// 它们名下的在库曲目数。
Future<({int sources, int tracks})> autoMusicSourcesRemovalPreview(
  FushiDatabase database,
  int ownerId,
) async {
  final List<SourceLibraryRow> owned = await database.listAutoMusicSourcesOf(
    ownerId,
  );
  if (owned.isEmpty) return (sources: 0, tracks: 0);
  final List<int> ids = <int>[for (final SourceLibraryRow s in owned) s.id];
  final int tracks = await database
      .customSelect(
        'SELECT COUNT(*) AS c FROM music_tracks WHERE deleted_at IS NULL '
        'AND source_id IN (${List<String>.filled(ids.length, '?').join(', ')})',
        variables: <Variable<Object>>[
          for (final int id in ids) Variable<int>(id),
        ],
      )
      .getSingle()
      .then((QueryRow r) => r.read<int>('c'));
  return (sources: owned.length, tracks: tracks);
}
