import 'dart:io';

import 'package:fushi/src/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/cover_scraper_service.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi_core/fushi_core.dart';

/// 组装只处理 sidecar / 本地封面的维护服务。
///
/// 动画在线元数据只能经 `VideoSourceScrapeCoordinator` 走 AniDB → TMDB；这里
/// 没有在线 client、下载器、候选匹配或别名缓存。
Future<CoverScraperService> createVideoScraperService({
  required VideoBookRepository repository,
  FushiDatabase? artifactDatabase,
}) async {
  final Directory covers = await VideoStorage.coversDir();
  final DatabaseSidecarGeneratedArtifactChecker? generatedArtifactChecker =
      artifactDatabase == null
          ? null
          : DatabaseSidecarGeneratedArtifactChecker(artifactDatabase);
  return CoverScraperService(
    repository: repository,
    coverMetaStore: CoverMetaStore(covers),
    generatedSidecarArtifactChecker: generatedArtifactChecker,
    coversDirectory: covers,
  );
}
