/// 系列关系的批量补齐入口：先给缺合集成员表的 TMDB 电影快照联网补上成员表
/// （[refreshMissingTmdbCollectionParts]，按合集去重、每个合集一次请求），再跑
/// 不联网的存量补填（[backfillScrapedCollectionRelations]）。
///
/// 只补系列关系，不重刮、不改作品资料。库管家 ⑤ 作品层、控制通道
/// `POST /api/admin/video/relations/refresh`（CLI `video relations`、助手的
/// `video.relation.refresh`）共用这一处。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_collection_relation_sync.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';

/// [refreshVideoSeriesRelations] 的结果：[tmdb] 为 null = 没配 TMDB 凭据、没联网
/// （或 TMDB 那一步整体失败，见日志）。
typedef VideoSeriesRelationRefreshResult = ({
  TmdbCollectionPartsRefreshResult? tmdb,
  CollectionRelationBackfillResult backfill,
});

/// 补齐系列关系。[fetchTmdbParts] 给了就用它（测试注入）；否则按
/// [config]`.tmdbApiKey` / [config]`.locale`（空则用 provider 默认语言）现建一个
/// [TmdbVideoMetadataProvider]，用完关闭。没配 TMDB key 且没注入 fetcher 时不联网。
/// TMDB 那一步整体失败只记日志，不影响后面的不联网补填。
Future<VideoSeriesRelationRefreshResult> refreshVideoSeriesRelations(
  FushiDatabase db, {
  required VideoSourceScrapeGlobalConfig config,
  required AniDbXmlDirectoryResolver aniDbXmlDirectory,
  TmdbCollectionPartsFetcher? fetchTmdbParts,
}) async {
  TmdbCollectionPartsRefreshResult? tmdb;
  final String apiKey = config.tmdbApiKey.trim();
  if (fetchTmdbParts != null || apiKey.isNotEmpty) {
    final String locale = config.locale.trim();
    final TmdbVideoMetadataProvider? provider = fetchTmdbParts == null
        ? (locale.isEmpty
              ? TmdbVideoMetadataProvider(apiKey: apiKey)
              : TmdbVideoMetadataProvider(apiKey: apiKey, language: locale))
        : null;
    try {
      tmdb = await refreshMissingTmdbCollectionParts(
        db,
        fetchParts: fetchTmdbParts ?? provider!.fetchCollectionParts,
      );
      engineLog.logDiagnostic(
        'videoRelations.refresh',
        'tmdb collection parts: missing=${tmdb.missing} '
            'refreshed=${tmdb.refreshed} requests=${tmdb.requests} '
            'failed=${tmdb.failed}',
      );
    } on Object catch (error, stack) {
      tmdb = null;
      engineLog.log('videoRelations.refresh.tmdb', error, stack);
    } finally {
      provider?.close();
    }
  }
  final CollectionRelationBackfillResult backfill =
      await backfillScrapedCollectionRelations(
        db,
        aniDbXmlDirectory: aniDbXmlDirectory,
      );
  return (tmdb: tmdb, backfill: backfill);
}
