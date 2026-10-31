/// 「立即给库里这**一个**视频补字幕」：互联 host 的
/// `POST /api/library/videos/<id>/subtitle/backfill` 用它。
///
/// 与刮削后自动补字幕是同一个 [VideoSubtitleBackfillService]，差别只在身份从哪来：
/// 自动那条拿的是刚刮完的 [VideoMetadataWork]，这里从库里读回已落库的作品行 +
/// provider 身份（与合集字幕面板同一个原语 [identityMediaReference]）。没刮过的
/// 视频不猜身份——拿文件名去搜正是这套服务存在要消灭的东西——如实回
/// `noIdentity`，让用户先刮削 / 手动识别。
///
/// 服务的保护原样保留：视频已有字幕源（DB）或目录里已有 sidecar 时不补
/// （`alreadyHasSubtitle`）。要换字幕先 `DELETE .../subtitle` 清掉旧的。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    show VideoMediaReference;
import 'package:fushi_engine/media/video/download/download_confirmed_identity.dart'
    show downloadConfirmedReferenceForVideoPath, mergeDownloadConfirmedIdentity;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleSource;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show VideoSubtitleBackfillReport;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/subtitle/scraped_subtitle_targets.dart'
    show identityMediaReference;
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';

/// 给 [videoId] 补一条字幕。视频不存在返回 null。
///
/// [service] 为 null（下载 / 字幕运行时还没起来）或没配任何字幕来源时回
/// `unavailable`。[language] 是这次显式要的字幕语言（硬过滤），null 时用
/// [seriesLanguage] 查到的每系列记忆，再没有就按服务的全局链。
///
/// [embeddedSelectionBlocks] 见 [libraryVideoSubtitleTarget]。
Future<VideoSubtitleBackfillReport?> backfillLibraryVideoSubtitle({
  required FushiDatabase database,
  required VideoSubtitleBackfillService? service,
  required String videoId,
  String? language,
  String? Function(String seriesKey)? seriesLanguage,
  bool embeddedSelectionBlocks = true,
}) async {
  final VideoBookRow? book = await database.getVideoBookByBookUid(videoId);
  if (book == null) return null;
  if (service == null || service.registry.providers.isEmpty) {
    return const VideoSubtitleBackfillReport(
      outcome: 'unavailable',
      detail: 'no online subtitle source is configured on this host',
    );
  }
  final ({SubtitleBackfillTarget? target, String? reason}) built =
      await libraryVideoSubtitleTarget(
        database,
        book,
        explicitLanguage: language,
        seriesLanguage: seriesLanguage,
        embeddedSelectionBlocks: embeddedSelectionBlocks,
      );
  final SubtitleBackfillTarget? target = built.target;
  if (target == null) {
    return VideoSubtitleBackfillReport(
      outcome: 'noIdentity',
      detail: built.reason,
    );
  }
  final SubtitleBackfillResult result = await service.backfill(target);
  return VideoSubtitleBackfillReport(
    outcome: result.outcome.name,
    installedPath: result.installedPath,
    language: result.language,
    detail: result.detail,
  );
}

/// 库里一个视频 → 补字幕目标（身份取自已落库的刮削结论）。拿不出可信身份时
/// target 为 null，reason 说明为什么。
///
/// [embeddedSelectionBlocks] 为 false 时，库里存的内嵌轨选择（`embedded:<n>`）不算
/// 「已有字幕」：下载后缺字幕重试用它——那一集本该由下载流水线装上 sidecar，内嵌轨
/// 只是没有 sidecar 时的退路（实测 Crunchyroll 片源的第 0 条内嵌轨是英文）。
/// `off:` 与外挂文件路径无论如何都挡住。
Future<({SubtitleBackfillTarget? target, String? reason})>
libraryVideoSubtitleTarget(
  FushiDatabase database,
  VideoBookRow book, {
  String? explicitLanguage,
  String? Function(String seriesKey)? seriesLanguage,
  bool embeddedSelectionBlocks = true,
}) async {
  if (book.videoPath.trim().isEmpty) {
    return (target: null, reason: 'video has no local file');
  }
  // 作品行要么挂在这一集上（单文件作品 / 按集刮的成员），要么挂在它的合集上。
  final VideoMetadataWorkRow? own = await database.getVideoMetadataWorkByBook(
    book.bookUid,
  );
  VideoMetadataWorkRow? work = own;
  MediaCollectionRow? collection;
  int memberCount = 1;
  for (final MediaCollectionItemRow item
      in await database.getAllCollectionItems()) {
    if (item.mediaType != 'video' || item.entryKey != book.bookUid) continue;
    final MediaCollectionRow? row = await database.getMediaCollectionById(
      item.collectionId,
    );
    if (row == null) continue;
    // 合集名只用来查每系列字幕语言记忆；作品行已挂在这一集上时就够了。
    collection ??= row;
    if (work != null) break;
    final VideoMetadataWorkRow? shared = await database
        .resolveVideoMetadataWorkForCollection(row.id);
    if (shared == null) continue;
    work = shared;
    collection = row;
    memberCount = (await database.getCollectionItems(
      row.id,
    )).where((MediaCollectionItemRow i) => i.mediaType == 'video').length;
    break;
  }
  if (work == null) {
    return (
      target: null,
      reason: 'video has not been scraped; scrape or identify it first',
    );
  }
  final List<VideoMetadataProviderIdentityRow> identities = await database
      .getVideoMetadataProviderIdentities(workId: work.id);
  if (identities.isEmpty) {
    return (target: null, reason: 'scraped work has no provider identity');
  }
  final VideoMetadataProviderIdentityRow primary = identities.firstWhere(
    (VideoMetadataProviderIdentityRow row) => row.isPrimary,
    orElse: () => identities.first,
  );
  // 季集号取文件名解析（与刮削后自动补同一判据，见 scrapedSubtitleTargets）：
  // 多集作品里认不出集号就不配，配上去只能是碰运气。
  final bool single = own != null || memberCount <= 1;
  final VideoNameInfo parsed = parseVideoFilename(p.basename(book.videoPath));
  // 单文件电影没有集号（「Doraemon Movie 25」的 25 是系列序号），同
  // scrapedSubtitleTargets。
  final int? episode = single && work.mediaType == 'movie'
      ? null
      : parsed.episode;
  if (episode == null && !single) {
    return (
      target: null,
      reason: 'cannot tell which episode this file is from its name',
    );
  }
  final int? season = episode == null ? null : (parsed.season ?? 1);
  final String? series = collection?.name.trim().toLowerCase();
  final VideoMediaReference scraped = identityMediaReference(
    providerId: primary.provider,
    kind: work.mediaType == 'movie'
        ? VideoMetadataMediaKind.movie
        : VideoMetadataMediaKind.tv,
    externalIds: libraryWorkExternalIds(identities),
    title: work.title,
    originalTitle: work.originalTitle,
    year: work.year,
    season: season,
    episode: episode,
  );
  return (
    target: SubtitleBackfillTarget(
      bookUid: book.bookUid,
      videoPath: book.videoPath,
      hasExistingSubtitle: subtitleSourceBlocksBackfill(
        book.subtitleSource,
        embeddedSelectionBlocks: embeddedSelectionBlocks,
      ),
      media: await withDownloadConfirmedIdentity(
        database,
        videoPath: book.videoPath,
        media: scraped,
      ),
      scrapedRuntimeMinutes: work.runtimeMinutes,
      contentLanguage: book.language,
      originalLanguage: work.originalLanguage,
      explicitLanguage:
          explicitLanguage ??
          (series == null ? null : seriesLanguage?.call(series)),
    ),
    reason: null,
  );
}

/// 补字幕身份 = 库内刮削身份 + 产出这个文件的下载任务确认过的身份（只补缺）。
///
/// 刮削后自动补、下载后缺字幕重试、控制通道补字幕都经这里，三条路对同一个文件
/// 搜的是同一份身份：刮削主源是 TMDB 时库内身份不带 AniList，Jimaku 就找不到
/// 条目（BUG-3892）。规则见 [mergeDownloadConfirmedIdentity]。
Future<VideoMediaReference> withDownloadConfirmedIdentity(
  FushiDatabase database, {
  required String videoPath,
  required VideoMediaReference media,
}) async {
  final VideoMediaReference? confirmed =
      await downloadConfirmedReferenceForVideoPath(database, videoPath);
  return confirmed == null
      ? media
      : mergeDownloadConfirmedIdentity(media, confirmed);
}

/// 库里存的主字幕源是否算「已有字幕」、挡住补字幕。null / 空不挡；`off:`（用户
/// 显式关闭）与外挂文件路径挡；内嵌轨选择按 [embeddedSelectionBlocks]。
bool subtitleSourceBlocksBackfill(
  String? subtitleSource, {
  bool embeddedSelectionBlocks = true,
}) {
  final String source = subtitleSource?.trim() ?? '';
  if (source.isEmpty) return false;
  if (SubtitleSource.isEmbeddedPersisted(source)) {
    return embeddedSelectionBlocks;
  }
  return true;
}

/// 作品的 provider 身份行 → `externalIds`（provider 归一成小写）。同一 provider
/// 有多行（大小写不同的旧行）时**保留首选**：主身份（`isPrimary`）在前，其余按
/// 原顺序，先到先得——与刮削确认的身份优先序一致，不让一条旧的非主身份行把
/// 主身份 id 顶掉（否则字幕会按另一部作品去搜）。
Map<String, String> libraryWorkExternalIds(
  List<VideoMetadataProviderIdentityRow> identities,
) {
  final Map<String, String> ids = <String, String>{};
  for (final VideoMetadataProviderIdentityRow row
      in <VideoMetadataProviderIdentityRow>[
        ...identities.where(
          (VideoMetadataProviderIdentityRow r) => r.isPrimary,
        ),
        ...identities.where(
          (VideoMetadataProviderIdentityRow r) => !r.isPrimary,
        ),
      ]) {
    final String provider = row.provider.trim().toLowerCase();
    final String id = row.externalId.trim();
    if (provider.isEmpty || id.isEmpty) continue;
    ids.putIfAbsent(provider, () => id);
  }
  return ids;
}
