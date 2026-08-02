import 'dart:io';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/media/video/video_cover_extractor.dart'
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
/// [VideoBookRepository.importSplitPlaylist]）→ 记 added 活动事件 → 绑定
/// AniList id → 封面。
///
/// 封面分两层、各自 best-effort（用户 2026-08-02：作品海报只归合集封面，成员条目
/// 保持抽帧/集级剧照）：
/// * **作品海报（AniList 封面 URL）→ 合集自有封面**（`MediaCollections.coverPath`，
///   落 `video_covers/collections/<collectionId>.jpg`），**不再借道首集条目封面**
///   ——旧路径把海报写进首集 `VideoBooks.coverPath` 再让合集 coverSource 指过去，
///   结果是成员条目顶着一张作品级竖版海报；
/// * **首集抽帧缩略图 → 首集条目封面**，并保留 coverSource 借用链指向首集：海报
///   下载失败/无 URL 时，合集卡回落链（coverPath 优先 → 借成员）仍能显示首集抽帧，
///   与旧行为对齐。
///
/// 封面/绑定失败不影响入库结果（best-effort），入库本体失败返回 null（由
/// [AnimeDownloadService] 把计划标 failed）。
///
/// [httpClient] / [collectionCoversDirectory] 仅供测试注入（默认自建 client /
/// 生产 [VideoStorage.collectionCoversDir]）。
Future<AnimeDownloadImportOutcome?> Function(
  AnimeDownloadPlan plan,
  List<String> videoAbsolutePaths,
) buildAnimeDownloadImporter(
  HibikiDatabase db, {
  http.Client? httpClient,
  Directory? collectionCoversDirectory,
}) {
  final VideoBookRepository repo = VideoBookRepository(db);
  return (AnimeDownloadPlan plan, List<String> videoAbsolutePaths) async {
    if (videoAbsolutePaths.isEmpty) return null;
    final List<String> sorted = sortVideoPathsByEpisode(videoAbsolutePaths);
    final SplitPlaylistImportResult result = await repo.importSplitPlaylist(
      collectionName: plan.seriesTitle,
      // plan JSON 与 Drift 无法做同一事务；若进程在 DB 提交后、计划 flag
      // 回写前崩溃，重启会重放 importer。以归一化视频路径作稳定业务键并在
      // importSplitPlaylist 的单事务内复用条目/合集，重放只补状态、不重复副作用。
      reuseExistingPaths: true,
      entries: <PlaylistEntry>[
        for (final String path in sorted) PlaylistEntry(title: '', path: path),
      ],
    );

    // BUG-1417：番剧下载完成自动入库也是一次真实入库，必须进首页活动时间轴——
    // 与对话框 / 拖拽 / 扫描首导同粒度：整本 1 条 added（title=系列名、mediaKey=
    // 首集 uid），绝不每集一条。
    //
    // 幂等**只能**看 createdEpisodeUids：`reuseExistingPaths: true` 让崩溃重放
    // （DB 已提交、计划 flag 未回写）复用既有条目与既有合集，此时一集都没新建 →
    // 一条都不记。**不是**靠时间窗/去重表掩盖，而是让判据本身分清「真新增」与
    // 「复用既有」；活动流表按设计是纯追加（addActivityEvent 不去重），不能也
    // 不该在那一层兜。同系列后续批次（新集号）确有新建 → 记 1 条，这是真新增内容。
    // best-effort：recordVideoImportActivity 内部自捕获，失败只 log 不影响入库。
    if (result.createdEpisodeUids.isNotEmpty && result.episodeUids.isNotEmpty) {
      await repo.recordVideoImportActivity(
        bookUid: result.episodeUids.first,
        title: plan.seriesTitle,
      );
    }

    // AniList 绑定（后续 Jimaku 批量对话框可直接复用该 id，跳过搜番消歧）。
    if (plan.anilistId != null) {
      try {
        await db.setMediaCollectionAnilistId(
          result.collectionId,
          plan.anilistId,
        );
      } catch (_) {}
    }

    if (result.episodeUids.isNotEmpty) {
      // ① 作品海报 → 合集自有封面（见函数注释）。文件名/目录与
      //    applyCandidateToCollection 同约定；gcOrphanCovers 非递归，天然免疫。
      final String? coverUrl = plan.coverUrl;
      if (coverUrl != null && coverUrl.isNotEmpty) {
        try {
          final Directory covers = collectionCoversDirectory ??
              await VideoStorage.collectionCoversDir();
          final String? collectionCoverPath = await downloadVideoCoverToPath(
            coverUrl: coverUrl,
            outputPath: p.join(
              covers.path,
              videoCoverFileName('${result.collectionId}'),
            ),
            httpClient: httpClient,
          );
          if (collectionCoverPath != null) {
            await db.updateMediaCollectionCoverPath(
              result.collectionId,
              collectionCoverPath,
            );
          }
        } catch (_) {}
      }

      // ② 首集抽帧缩略图 → 首集条目封面 + coverSource 借用链兜底。
      try {
        final String firstUid = result.episodeUids.first;
        final String? framePath = await extractVideoCover(
          videoPath: sorted.first,
          bookUid: firstUid,
        );
        if (framePath != null) {
          await repo.updateCover(firstUid, framePath);
          // ⚠️ 唯一落库点：MediaCollections.coverSource 持久化 'video|<uid>'，
          // compositeKey 生成串与历史手写插值逐字节一致。
          await db.updateMediaCollectionCover(
            result.collectionId,
            MediaKind.video.compositeKey(firstUid),
          );
        }
      } catch (_) {}
    }

    return AnimeDownloadImportOutcome(collectionId: result.collectionId);
  };
}
