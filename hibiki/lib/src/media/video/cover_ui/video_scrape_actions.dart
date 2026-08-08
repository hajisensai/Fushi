import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/src/media/metadata/scrape_batch.dart';
import 'package:hibiki/src/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/anilist_client.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/cover_scraper_service.dart';
import 'package:hibiki/src/media/video/scraper/jikan_client.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_default_key.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 视频刮削依赖组装结果，单项匹配、自动刮削与来源页的整库刮削共用。
typedef VideoScraperBundle = ({
  CoverScraperService service,
  CoverScraperService Function(OfflineIndex offline) rebuild,
  Directory scraperDir,
});

/// 组装视频封面/资料刮削运行时，保持所有入口的来源、缓存和 TMDB key 规则一致。
Future<VideoScraperBundle> createVideoScraperBundle({
  required VideoBookRepository repository,
  required String configuredTmdbKey,
  HibikiDatabase? artifactDatabase,
}) async {
  final Directory covers = await VideoStorage.coversDir();
  final Directory scraperDir =
      Directory(p.join(covers.parent.path, 'video_scraper'));
  await scraperDir.create(recursive: true);
  final String tmdbKey = resolveTmdbApiKey(configuredTmdbKey);
  final DatabaseSidecarGeneratedArtifactChecker? generatedArtifactChecker =
      artifactDatabase == null
          ? null
          : DatabaseSidecarGeneratedArtifactChecker(artifactDatabase);
  CoverScraperService make(OfflineIndex? offline) => CoverScraperService(
        repository: repository,
        coverMetaStore: CoverMetaStore(covers),
        aliasCache: AliasCache(scraperDir),
        bangumiClient: BangumiClient(),
        coverDownloader: CoverDownloader(),
        tmdbClient: tmdbKey.isEmpty ? null : TmdbClient(apiKey: tmdbKey),
        aniListClient: AniListClient(),
        jikanClient: JikanClient(),
        offlineIndex: offline,
        generatedSidecarArtifactChecker: generatedArtifactChecker,
        coversDirectory: covers,
      );
  final OfflineIndex? offline =
      await CoverScraperService.loadOfflineIndex(scraperDir);
  return (
    service: make(offline),
    rebuild: (OfflineIndex value) => make(value),
    scraperDir: scraperDir,
  );
}

/// 显示视频整库刮削弹窗。取消返回 null，完成返回批处理摘要。
///
/// `rescrapeScraped: true` 只允许服务重试旧的自动刮削结果；用户手选封面、用户确认
/// 过的匹配和 sidecar 保护仍由 [CoverScraperService.scrapeLibrary] 的统一策略决定。
Future<ScrapeBatchSummary?> showVideoScrapeAllDialog({
  required BuildContext context,
  required VideoBookRepository repository,
  required String configuredTmdbKey,
  HibikiDatabase? artifactDatabase,
}) async {
  final List<VideoBookRow> books = await repository.listAll();
  if (!context.mounted) return null;
  final VideoScraperBundle bundle = await createVideoScraperBundle(
    repository: repository,
    configuredTmdbKey: configuredTmdbKey,
    artifactDatabase: artifactDatabase,
  );
  if (!context.mounted) return null;
  return showScrapeBatchDialog(
    context: context,
    mediaLabel: t.nav_video,
    itemCount: books.length,
    runner: (ScrapeBatchProgressCallback onProgress) async {
      ScrapeBatchSummary summary = const ScrapeBatchSummary();
      await for (final BatchScrapeProgress progress
          in bundle.service.scrapeLibrary(
        books,
        rescrapeScraped: true,
      )) {
        final ScrapeBatchItemResult result = switch (progress.outcome) {
          ScrapeApplied() => ScrapeBatchItemResult.applied,
          ScrapeNeedsConfirm() => ScrapeBatchItemResult.needsReview,
          ScrapeFailed() => ScrapeBatchItemResult.failed,
          _ => ScrapeBatchItemResult.skipped,
        };
        summary = summary.add(result);
        onProgress(ScrapeBatchProgress(
          current: progress.index + 1,
          total: progress.total,
          title: progress.book.title,
          summary: summary,
        ));
      }
      return summary;
    },
  );
}
