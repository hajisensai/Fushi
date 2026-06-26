import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/video/video_storage.dart';

/// VideoBooks 仓库：视频元数据 + 进度；字幕 cue 复用 audioCues 表。
class VideoBookRepository {
  const VideoBookRepository(this._db);

  final HibikiDatabase _db;

  /// 写入/更新一本视频书。
  ///
  /// TODO-817 M1b：可选 [sourceId] 指向归属的网络/本地来源库（[MediaSources].id）；
  /// 默认 null = 手动导入无来源（向后兼容，现有手动导入调用点一字不改）。只在
  /// [book] 自身没显式设过 sourceId 时才合并进 companion，避免覆盖调用方意图。
  Future<void> saveVideoBook(VideoBooksCompanion book, {int? sourceId}) {
    final VideoBooksCompanion withSource =
        sourceId == null ? book : book.copyWith(sourceId: Value(sourceId));
    return _db.upsertVideoBook(withSource);
  }

  Future<VideoBookRow?> getByBookUid(String bookUid) =>
      _db.getVideoBookByBookUid(bookUid);

  Future<List<VideoBookRow>> listAll() => _db.allVideoBooks();

  Future<void> updatePosition(String bookUid, int positionMs) =>
      _db.updateVideoBookPosition(bookUid, positionMs);

  /// 更新播放列表当前集索引（多集导航切集后持久化）。
  Future<void> updateCurrentEpisode(String bookUid, int episodeIndex) =>
      _db.updateVideoBookEpisode(bookUid, episodeIndex);

  /// 回写整段播放列表 JSON（各集 positionMs 改变时持久化每集进度）。
  Future<void> updatePlaylistJson(String bookUid, String playlistJson) =>
      _db.updateVideoBookPlaylistJson(bookUid, playlistJson);

  /// 更新音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留。
  Future<void> updateDelayMs(String bookUid, int delayMs) =>
      _db.updateVideoBookDelayMs(bookUid, delayMs);

  /// 更新用户选中的字幕源（外挂存绝对路径；内嵌存 `embedded:<n>`；用户显式关闭存
  /// `off:` 哨兵 `SubtitleSource.offSentinel`，TODO-818；null=无偏好/从未选过，按
  /// 「自动选默认」恢复，与「显式关闭」区分，勿混用）。
  Future<void> updateSubtitleSource(String bookUid, String? subtitleSource) =>
      _db.updateVideoBookSubtitleSource(bookUid, subtitleSource);

  /// 更新用户选中的副字幕源（TODO-857 视频双字幕 Path A）：与 [updateSubtitleSource]
  /// 同款四态编码（外挂绝对路径 / `embedded:<n>` / `off:` / null）。副字幕由 libmpv
  /// `secondary-sid` 自渲染（不进 cue 流，不可查词），故无 cue，独立于 cue 事务写入。
  Future<void> updateSecondarySubtitleSource(
          String bookUid, String? secondarySubtitleSource) =>
      _db.updateVideoBookSecondarySubtitleSource(
          bookUid, secondarySubtitleSource);

  /// 更新用户选中的音轨 id（libmpv `AudioTrack.id`；清除存 null）。
  Future<void> updateAudioTrackId(String bookUid, String? audioTrackId) =>
      _db.updateVideoBookAudioTrackId(bookUid, audioTrackId);

  /// 更新视频封面图绝对路径（书架/视频库长按菜单手动设置封面）。
  Future<void> updateCover(String bookUid, String coverPath) =>
      _db.updateVideoBookCover(bookUid, coverPath);

  /// 更新视频/播放列表标题（视频库长按菜单「重命名」）。
  Future<void> updateTitle(String bookUid, String title) =>
      _db.updateVideoBookTitle(bookUid, title);

  /// 删除视频书：DB 行 + 本视频的字幕 cue 行一并删（[HibikiDatabase.deleteVideoBook]
  /// 在一个事务里删 videoBooks + audio_cues；标签映射经 FK cascade）。on-disk 的
  /// 封面/字幕副本回收交给调用方的 [VideoStorage.deleteBookAssets]（按被删 book 精确
  /// 删，不全库 sweep，BUG-276）。
  Future<void> deleteVideoBook(String bookUid) => _db.deleteVideoBook(bookUid);

  /// Deletes one video row and then reclaims the app-owned files that can be
  /// proven safe to delete.
  ///
  /// The DB row is read first so cleanup can use the deleted row's `coverPath`,
  /// `subtitleSource`, and `videoPath` after the row is gone. File cleanup and
  /// DB compaction are best-effort and run outside the delete transaction.
  Future<bool> deleteVideoBookAndReclaimAssets(
    String bookUid, {
    bool compactDatabase = true,
  }) async {
    final VideoBookRow? book = await getByBookUid(bookUid);
    if (book == null) return false;

    final String? deletedCoverPath = book.coverPath;
    final String? deletedSubtitlePath = book.subtitleSource;
    final String deletedVideoPath = book.videoPath;
    await deleteVideoBook(bookUid);
    await reclaimDeletedVideoBookAssets(
      deletedBookUid: bookUid,
      deletedCoverPath: deletedCoverPath,
      deletedSubtitlePath: deletedSubtitlePath,
      deletedVideoPath: deletedVideoPath,
    );
    if (compactDatabase) {
      await compactAfterVideoDeleteBestEffort();
    }
    return true;
  }

  /// Reclaims app-owned video assets for a row that has already been deleted.
  ///
  /// Only the deleted row's own cover/subtitle paths are considered, and each
  /// candidate must still live under Hibiki's app-owned video asset directory
  /// and be unreferenced by all remaining videos. The embedded subtitle cache is
  /// derived from [deletedVideoPath] and is skipped while another video still
  /// points at the same original path.
  Future<void> reclaimDeletedVideoBookAssets({
    required String deletedBookUid,
    required String? deletedCoverPath,
    required String? deletedSubtitlePath,
    required String deletedVideoPath,
  }) async {
    try {
      final ({Set<String> covers, Set<String> subtitles}) refs =
          await collectReferencedAssetPaths(excludeBookUid: deletedBookUid);
      await VideoStorage.deleteBookAssets(
        deletedCoverPath: deletedCoverPath,
        deletedSubtitlePath: deletedSubtitlePath,
        stillReferencedCoverPaths: refs.covers,
        stillReferencedSubtitlePaths: refs.subtitles,
      );
      await VideoStorage.gcOrphanCovers(referencedCoverPaths: refs.covers);
      if (!await isVideoPathReferenced(
        deletedVideoPath,
        excludeBookUid: deletedBookUid,
      )) {
        await VideoStorage.deleteEmbeddedSubtitleCacheForVideoPath(
          deletedVideoPath,
        );
      }
    } catch (e, stack) {
      debugPrint('VideoBookRepository: video asset cleanup failed: $e\n$stack');
    }
  }

  /// Best-effort SQLite space reclamation after video deletion. Keep this
  /// outside delete transactions; callers doing batch deletes should call it
  /// once after the batch, not once per row.
  Future<void> compactAfterVideoDeleteBestEffort() async {
    try {
      await _db.customStatement('VACUUM');
      await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e, stack) {
      debugPrint(
        'VideoBookRepository: compact after video delete failed: $e\n$stack',
      );
    }
  }

  /// 收集「当前 DB 仍引用的、app 拥有的视频副本路径」，供删除回收做护栏 / 封面历史
  /// GC 用作保留集。
  ///
  /// - `covers`：每本视频的 `coverPath`（落在 `<appDocs>/video_covers/`，文件名由
  ///   bookUid 1:1 派生，引用集对封面完整）。
  /// - `subtitles`：每本视频的 `subtitleSource`（手动导入/Jimaku 下载的外挂字幕落在
  ///   `<appDocs>/video_subtitles/`；sidecar/内嵌源也会被收进来，但它们不在该目录里，
  ///   无害）。**注意**：播放列表只在该列存最后选中那集的字幕路径，其余各集副本不在
  ///   DB，故字幕引用集**不完整**——只可用作删除护栏（命中则保留），不可拿去全库 sweep
  ///   删字幕，否则会误删别集活副本（见 [VideoStorage] 类注释 / BUG-276）。
  ///
  /// [excludeBookUid] 非 null 时跳过该 book 自己的引用（删除时取「全库其余 book」的
  /// 引用集，避免被删 book 自己的路径反而把自己的资产护住不删）。
  Future<({Set<String> covers, Set<String> subtitles})>
      collectReferencedAssetPaths({String? excludeBookUid}) async {
    final List<VideoBookRow> all = await listAll();
    final Set<String> covers = <String>{};
    final Set<String> subtitles = <String>{};
    for (final VideoBookRow row in all) {
      if (excludeBookUid != null && row.bookUid == excludeBookUid) continue;
      final String? cover = row.coverPath;
      if (cover != null && cover.isNotEmpty) covers.add(cover);
      final String? sub = row.subtitleSource;
      if (sub != null && sub.isNotEmpty) subtitles.add(sub);
    }
    return (covers: covers, subtitles: subtitles);
  }

  Future<bool> isVideoPathReferenced(
    String videoPath, {
    String? excludeBookUid,
  }) async {
    if (videoPath.isEmpty) return false;
    final List<VideoBookRow> all = await listAll();
    for (final VideoBookRow row in all) {
      if (excludeBookUid != null && row.bookUid == excludeBookUid) continue;
      if (row.videoPath == videoPath) return true;
    }
    return false;
  }

  Future<void> saveCues({
    required String bookUid,
    required List<AudioCue> cues,
  }) =>
      _db.replaceCuesForBook(bookUid, cues.map(AudioCue.toCompanion).toList());

  Future<List<AudioCue>> loadCues(String bookUid) async {
    final List<AudioCueRow> rows = await _db.getCuesForBook(bookUid);
    return rows.map(AudioCue.fromRow).toList();
  }

  /// 原子地写入「选中字幕源 + 解析出的 cue」（BUG-081，单视频用）。两步合进一个
  /// 事务，避免 cue 落库但 source 未更新（或反之）导致下次恢复时显示内容与字幕源
  /// 标签不一致。播放列表不走此路（每集按磁盘动态解析，见 VideoHibikiPage）。
  Future<void> saveSubtitleSelection({
    required String bookUid,
    required String? subtitleSource,
    required List<AudioCue> cues,
  }) =>
      _db.transaction(() async {
        await _db.replaceCuesForBook(
            bookUid, cues.map(AudioCue.toCompanion).toList());
        await _db.updateVideoBookSubtitleSource(bookUid, subtitleSource);
      });
}
