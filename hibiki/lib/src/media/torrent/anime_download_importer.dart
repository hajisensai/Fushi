import 'dart:io';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show downloadVideoCoverToPath, extractVideoCover, videoCoverFileName;

/// 把下载完成的视频路径按解析集号升序排（集号缺失排末尾，同集按文件名）。纯函数，
/// 保证入库后合集成员顺序 = 集号顺序（importSplitPlaylist 按 entries 顺序挂成员）。
List<String> sortVideoPathsByEpisode(List<String> paths) {
  final List<String> sorted = List<String>.of(paths);
  sorted.sort((String a, String b) {
    final int? ea = parseVideoFilename(p.basename(a)).episode;
    final int? eb = parseVideoFilename(p.basename(b)).episode;
    if (ea != null && eb != null && ea != eb) return ea.compareTo(eb);
    if (ea != null && eb == null) return -1;
    if (ea == null && eb != null) return 1;
    return p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase());
  });
  return sorted;
}

/// 组装番剧下载完成后的入库回调：N 集拆行 + playlist 合集（一个事务，复用
/// [VideoBookRepository.importSplitPlaylist]）→ 绑定 AniList id → 封面（优先
/// AniList 封面 URL，失败退 ffmpeg 抽帧）落到首集并让合集封面指向它。
///
/// 封面/绑定失败不影响入库结果（best-effort），入库本体失败返回 null（由
/// [AnimeDownloadService] 把计划标 failed）。
Future<AnimeDownloadImportOutcome?> Function(
        AnimeDownloadPlan plan, List<String> videoAbsolutePaths)
    buildAnimeDownloadImporter(HibikiDatabase db) {
  final VideoBookRepository repo = VideoBookRepository(db);
  return (AnimeDownloadPlan plan, List<String> videoAbsolutePaths) async {
    if (videoAbsolutePaths.isEmpty) return null;
    final List<String> sorted = sortVideoPathsByEpisode(videoAbsolutePaths);
    final ({int collectionId, List<String> episodeUids}) result =
        await repo.importSplitPlaylist(
      collectionName: plan.seriesTitle,
      entries: <PlaylistEntry>[
        for (final String path in sorted) PlaylistEntry(title: '', path: path),
      ],
    );

    // AniList 绑定（后续 Jimaku 批量对话框可直接复用该 id，跳过搜番消歧）。
    if (plan.anilistId != null) {
      try {
        await db.setMediaCollectionAnilistId(
            result.collectionId, plan.anilistId);
      } catch (_) {}
    }

    // 封面：下载 AniList 封面 → 退 ffmpeg 抽帧；设到首集并让合集封面指向首集。
    if (result.episodeUids.isNotEmpty) {
      try {
        final String firstUid = result.episodeUids.first;
        String? coverPath;
        final String? coverUrl = plan.coverUrl;
        if (coverUrl != null && coverUrl.isNotEmpty) {
          final Directory covers = await AppPaths.videoCoversDirectory();
          coverPath = await downloadVideoCoverToPath(
            coverUrl: coverUrl,
            outputPath: p.join(covers.path, videoCoverFileName(firstUid)),
          );
        }
        coverPath ??= await extractVideoCover(
          videoPath: sorted.first,
          bookUid: firstUid,
        );
        if (coverPath != null) {
          await repo.updateCover(firstUid, coverPath);
          await db.updateMediaCollectionCover(
              result.collectionId, 'video|$firstUid');
        }
      } catch (_) {}
    }

    return AnimeDownloadImportOutcome(collectionId: result.collectionId);
  };
}
