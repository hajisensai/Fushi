/// v77 规范视频资料的 Drift 映射与旧详情页兼容投影。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart'
    show
        BooleanExpressionOperators,
        Table,
        TableInfo,
        UpdateKind,
        Value,
        Variable;
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart'
    show hasIncompleteMalCredits;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_collection_relation_sync.dart';
import 'package:fushi_engine/media/video/metadata/video_related_works.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_manual_edit.dart';

/// 成员视频的本地 (季, 集) 键：优先协调器给出的覆盖（多季合集 / 绝对集号重定向），
/// 否则按文件名解析（季缺省 1）；解不出集号返回 null。入库、sidecar、旧投影
/// 三处必须用同一把键，否则同一集会在三个地方绑到不同文件。
(int, int)? localEpisodeKeyFor(
  VideoBookRow book,
  Map<String, (int, int)> episodeOverrides,
) {
  final (int, int)? override = episodeOverrides[book.bookUid];
  if (override != null) return override;
  final VideoNameInfo parsed = parseVideoFilename(p.basename(book.videoPath));
  final int? episode = parsed.episode;
  if (episode == null) return null;
  return (parsed.season ?? 1, episode);
}

/// 分集行 `anidb_match_rating` 的「用户手动钉死」值（Shoko `MatchRating.UserVerified`）；
/// 其余值是 `TmdbEpisodeMatchRating.name`。
const String kUserVerifiedMatchRating = 'userVerified';

/// 一个文件的 AniDB 集身份 + 它与 TMDB 集链接的评级（Shoko
/// `CrossRef_AniDB_TMDB_Episode`），随绑定写到分集行。[matchRating] 为 null =
/// 没经 TMDB 逐集链接（无 TMDB 剧 / 没对上），只记 AniDB 原生身份。
class AnidbEpisodeXref {
  const AnidbEpisodeXref({
    required this.episodeId,
    required this.episodeNumber,
    this.matchRating,
  });
  final int episodeId;
  final String episodeNumber;
  final String? matchRating;
}

/// 一个文件覆盖的**额外**分集（AniDB FILE other episodes，Shoko
/// `CrossRef_File_Episode` 一文件多集）：成员 `bookUid` → 额外卡片 (季, 集) →
/// 那一集的 AniDB 身份。主集仍由 [localEpisodeKeyFor] 决定；这里的键只多绑、
/// 不改主键，sidecar / 旧投影只跟主集。
typedef AnidbAdditionalEpisodeBindings =
    Map<String, Map<(int, int), AnidbEpisodeXref>>;

class PersistedVideoMetadata {
  const PersistedVideoMetadata({
    required this.workId,
    required this.seasonIds,
    required this.episodeIds,
    required this.episodesByBookUid,
  });

  final int workId;
  final Map<int, int> seasonIds;
  final Map<(int, int), int> episodeIds;
  final Map<String, VideoMetadataEpisode> episodesByBookUid;
}

class VideoMetadataDatabaseStore {
  const VideoMetadataDatabaseStore(this.database);

  final FushiDatabase database;

  /// Returns every persisted work identity, with the primary identity first.
  ///
  /// The canonical MAL/TMDB binding and its secondary cross-references must
  /// survive independently of generated NFO files. Callers can therefore
  /// reuse an already-confirmed TMDB id/episode group without title-searching
  /// and potentially rebinding the same work on every rescrape. A secondary
  /// identity must never be promoted merely because the old primary retired.
  Future<List<VideoMetadataLookup>> lookupsForWork(
    VideoSourceScrapeWork localWork,
  ) => _lookupsForWork(localWork, primaryOnly: false);

  /// 仅返回被标为 `isPrimary` 的作品身份；没有主身份（例如只由本地 NFO 索引
  /// 出交叉引用、尚未被任何主源识别过的作品）返回 null。调用方据此区分「旧主源
  /// 已退役，需要重识别」与「从来没有主身份，交叉引用只是提示」——后者不该被
  /// 当成退役主源而把提示一起丢掉。
  Future<VideoMetadataLookup?> primaryLookupForWork(
    VideoSourceScrapeWork localWork,
  ) async => (await _lookupsForWork(localWork, primaryOnly: true)).firstOrNull;

  Future<List<VideoMetadataLookup>> _lookupsForWork(
    VideoSourceScrapeWork localWork, {
    required bool primaryOnly,
  }) async {
    final VideoMetadataWorkRow? row = localWork.collection == null
        ? await database.getVideoMetadataWorkByBook(
            localWork.members.single.bookUid,
          )
        : await database.getVideoMetadataWorkByCollection(
            localWork.collection!.id,
          );
    if (row == null) return const <VideoMetadataLookup>[];
    return lookupsForWorkRow(row, primaryOnly: primaryOnly);
  }

  /// [row] 这部已落库作品的全部可联网身份（主身份在前；[primaryOnly] 只要主身份）。
  /// 本地 / 媒体服务器 / fanart 身份不算（没有可再拉的源）。「横幅…」面板按它找
  /// TMDB 身份去列全部背景图。
  Future<List<VideoMetadataLookup>> lookupsForWorkRow(
    VideoMetadataWorkRow row, {
    bool primaryOnly = false,
  }) async {
    final VideoMetadataMediaKind? kind = VideoMetadataMediaKind.values
        .asNameMap()[row.mediaType];
    if (kind == null) return const <VideoMetadataLookup>[];
    final List<VideoMetadataProviderIdentityRow> identities = await database
        .getVideoMetadataProviderIdentities(workId: row.id);
    final List<VideoMetadataProviderIdentityRow> ordered =
        <VideoMetadataProviderIdentityRow>[
          ...identities.where(
            (VideoMetadataProviderIdentityRow value) => value.isPrimary,
          ),
          if (!primaryOnly)
            ...identities.where(
              (VideoMetadataProviderIdentityRow value) => !value.isPrimary,
            ),
        ];
    final List<VideoMetadataLookup> result = <VideoMetadataLookup>[];
    for (final VideoMetadataProviderIdentityRow identity in ordered) {
      final VideoMetadataProviderKind? provider = VideoMetadataProviderKind
          .values
          .asNameMap()[identity.provider];
      if (provider == null ||
          provider == VideoMetadataProviderKind.local ||
          provider == VideoMetadataProviderKind.mediaserver ||
          provider == VideoMetadataProviderKind.fanart) {
        continue;
      }
      result.add(
        VideoMetadataLookup(
          provider: provider,
          externalId: identity.externalId,
          mediaKind: kind,
          episodeGroupId: provider == VideoMetadataProviderKind.tmdb
              ? row.episodeGroupId
              : null,
        ),
      );
    }
    return result;
  }

  Future<VideoMetadataLookup?> confirmedLookup(
    VideoSourceScrapeWork localWork,
  ) async {
    final VideoMetadataWorkRow? row = localWork.collection == null
        ? await database.getVideoMetadataWorkByBook(
            localWork.members.single.bookUid,
          )
        : await database.getVideoMetadataWorkByCollection(
            localWork.collection!.id,
          );
    if (row == null) return null;
    final List<VideoMetadataProviderIdentityRow> identities = await database
        .getVideoMetadataProviderIdentities(workId: row.id);
    if (identities.isEmpty) return null;
    final VideoMetadataProviderIdentityRow? identity = identities
        .where((VideoMetadataProviderIdentityRow value) => value.isPrimary)
        .firstOrNull;
    if (identity == null) return null;
    final VideoMetadataProviderKind? provider = VideoMetadataProviderKind.values
        .asNameMap()[identity.provider];
    final VideoMetadataMediaKind? kind = VideoMetadataMediaKind.values
        .asNameMap()[row.mediaType];
    // 媒体服务器资料不是刮削身份：没有能「按已确认身份续刮」的 provider。
    if (provider == null ||
        provider == VideoMetadataProviderKind.fanart ||
        provider == VideoMetadataProviderKind.mediaserver ||
        kind == null) {
      return null;
    }
    return VideoMetadataLookup(
      provider: provider,
      externalId: identity.externalId,
      mediaKind: kind,
      episodeGroupId: row.episodeGroupId,
    );
  }

  /// [episodeOverrides]：成员 `bookUid` → 本地 (季, 集)。多季合集 / 绝对集号
  /// 重定向后由协调器给出，覆盖单纯按文件名解析的键；没有条目的成员照旧解析。
  ///
  /// [additionalEpisodeBindings]：一文件多集的额外绑定（见
  /// [AnidbAdditionalEpisodeBindings]）；同一文件因此出现在多条分集行上，
  /// v110 起 `book_uid` 不再唯一。
  ///
  /// [preserveExistingLegacyProjection]：只补写还不存在的旧投影行
  /// （`collection_scrape_meta` / `video_scrape_meta`），已有的一行不动。本地索引给
  /// 没有 NFO 的作品建占位作品时传 true：占位只有文件名推出的标题、没有任何外部
  /// 身份，而库里已有的旧刮削行带着在线来源的身份（`source` / `subjectId`，Bangumi
  /// 追番映射靠它）、简介与分集资料——占位覆盖上去就是把用户的刮削资料换成空壳
  /// （BUG-5418 审查）。
  Future<PersistedVideoMetadata> apply(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata, {
    bool preserveExistingLegacyProjection = false,
    bool seasonEpisodesAuthoritative = true,
    Map<String, (int, int)> episodeOverrides = const <String, (int, int)>{},
    Map<String, AnidbEpisodeXref> anidbEpisodeXrefs =
        const <String, AnidbEpisodeXref>{},
    AnidbAdditionalEpisodeBindings additionalEpisodeBindings =
        const <String, Map<(int, int), AnidbEpisodeXref>>{},
    Set<String> userVerifiedBooks = const <String>{},
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    late int workId;
    final Map<int, int> seasonIds = <int, int>{};
    final Map<(int, int), int> episodeIds = <(int, int), int>{};
    final Map<String, VideoMetadataEpisode> episodesByBookUid =
        <String, VideoMetadataEpisode>{};

    await database.transaction(() async {
      // v99 字段锁：先读旧行，被锁字段一律保留旧值。必须在
      // `_removeBookOwnedWorksForCollection` 之前读——那一步只删「成员自己拥有的
      // 作品行」，但把读放在最前面才不用去推理它到底删了谁。
      VideoMetadataWorkRow? existingWork = localWork.collection == null
          ? await database.getVideoMetadataWorkByBook(
              localWork.members.single.bookUid,
            )
          : await database.getVideoMetadataWorkByCollection(
              localWork.collection!.id,
            );
      // BUG-5110：单集作品长成合集（下到第二集）后第一次按合集刮——合集还没有
      // 自己的行、成员上恰好挂着一条作品行时，把那一行升格成合集行（改归属，
      // 不删），用户手填的值、字段锁、锁住的图 / 词条随行保留；下面的整组替换
      // 按「同一作品重刮」的语义作用在这条行上。
      if (existingWork == null) {
        if (localWork.collection case final MediaCollectionRow collection) {
          existingWork = await _promoteSoleMemberWork(collection.id);
        }
      }
      final Set<VideoMetadataLockableField> locked = parseLockedFields(
        existingWork?.lockedFields,
      );
      bool isLocked(VideoMetadataLockableField field) =>
          existingWork != null && locked.contains(field);

      if (localWork.collection case final MediaCollectionRow collection) {
        await _removeBookOwnedWorksForCollection(collection.id);
      }
      workId = await database.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(localWork.collection?.id),
          bookUid: Value<String?>(
            localWork.collection == null
                ? localWork.members.single.bookUid
                : null,
          ),
          mediaType: metadata.kind.name,
          title: isLocked(VideoMetadataLockableField.title)
              ? existingWork!.title
              : metadata.title,
          originalTitle: Value<String?>(
            isLocked(VideoMetadataLockableField.originalTitle)
                ? existingWork!.originalTitle
                : metadata.originalTitle,
          ),
          overview: Value<String?>(
            isLocked(VideoMetadataLockableField.overview)
                ? existingWork!.overview
                : metadata.plot,
          ),
          tagline: Value<String?>(
            isLocked(VideoMetadataLockableField.tagline)
                ? existingWork!.tagline
                : metadata.tagline,
          ),
          premiereDate: Value<String?>(metadata.premiered),
          endDate: Value<String?>(metadata.endDate),
          year: Value<int?>(
            isLocked(VideoMetadataLockableField.year)
                ? existingWork!.year
                : metadata.year,
          ),
          rating: Value<double?>(
            isLocked(VideoMetadataLockableField.rating)
                ? existingWork!.rating
                : metadata.rating,
          ),
          ratingCount: Value<int?>(metadata.ratingVotes),
          runtimeMinutes: Value<int?>(metadata.runtimeMinutes),
          contentRating: Value<String?>(metadata.contentRating),
          status: Value<String?>(metadata.status),
          originalLanguage: Value<String?>(metadata.originalLanguage),
          homepage: Value<String?>(metadata.homepage),
          episodeGroupId: Value<String?>(
            isLocked(VideoMetadataLockableField.episodeGroup)
                ? existingWork!.episodeGroupId
                : metadata.episodeGroupId,
          ),
          updatedAt: now,
        ),
      );

      await _replaceIdentities(
        workId: workId,
        ids: metadata.ids,
        primaryProvider: metadata.provider,
        now: now,
      );
      await _replaceRawSnapshot(workId, metadata, now);
      // 系列关系（续作 / 前传 / 外传…）：起点是作品的归属——合集，或挂在单个
      // 视频上的作品（散装电影，v162）。只用本次响应里本来就有的关系（TMDB 电影
      // 的合集成员由 provider 在刮削时随详情附上）；载荷没带关系信息（AniDB 只有
      // 目录、TMDB 剧集、合集请求失败）时不动已有行。
      final MediaCollectionRow? ownerCollection = localWork.collection;
      final VideoRelationOwner relationOwner = ownerCollection != null
          ? VideoRelationOwner.collection(ownerCollection.id)
          : VideoRelationOwner.video(localWork.members.single.bookUid);
      final List<VideoRelatedWork>? related = relatedWorksFromRawPayload(
        metadata.provider.name,
        metadata.rawPayload,
      );
      if (related != null) {
        await syncScrapedCollectionRelations(
          database,
          owner: relationOwner,
          source: metadata.provider.name,
          related: related,
        );
      }
      // 别处指向本作品外部 id 的纯刮削行升级成已绑定。
      await bindCollectionRelationsToWork(
        database,
        owner: relationOwner,
        identities: <(String, String)>[
          for (final VideoMetadataId id in _uniqueIds(metadata.ids))
            if (canBindRelationIdentity(
              provider: id.type.trim().toLowerCase(),
              mediaType: metadata.kind.name,
            ))
              (id.type.trim().toLowerCase(), id.value),
        ],
      );
      // 锁住的整组词（genres / studios）保留旧集合；其余种类照常整体替换。
      final Map<String, List<String>> lockedTerms =
          isLocked(VideoMetadataLockableField.genres) ||
              isLocked(VideoMetadataLockableField.studios)
          ? await _termsByKind(workId)
          : const <String, List<String>>{};
      await _replaceTerms(
        workId,
        countries: metadata.countries,
        keywords: metadata.keywords,
        genres: isLocked(VideoMetadataLockableField.genres)
            ? (lockedTerms['genre'] ?? const <String>[])
            : metadata.genres,
        studios: isLocked(VideoMetadataLockableField.studios)
            ? (lockedTerms['studio'] ?? const <String>[])
            : metadata.studios,
      );
      // 来源本轮人物表残缺（MAL characters / staff 端点抖动）而库里已有上一轮
      // 的表：只补不覆盖，否则一次 504 就把整张声优表清空（BUG-2612）。
      final bool keepExistingCredits =
          hasIncompleteMalCredits(metadata) &&
          (await database.getVideoMetadataCredits(workId: workId)).isNotEmpty;
      await _replaceCredits(
        workId: workId,
        credits: metadata.credits,
        now: now,
        keepExisting: keepExistingCredits,
      );
      await _replaceImages(
        workId: workId,
        images: metadata.images,
        now: now,
        lockedKinds: <VideoMetadataImageKind>{
          if (isLocked(VideoMetadataLockableField.cover))
            VideoMetadataImageKind.cover,
          if (isLocked(VideoMetadataLockableField.backdrop))
            VideoMetadataImageKind.backdrop,
        },
      );
      await database.replaceOnlineVideoMetadataExtras(
        workId,
        <VideoMetadataExtrasCompanion>[
          for (final VideoMetadataExtra extra in metadata.extras)
            if (extra.remoteUrl != null)
              VideoMetadataExtrasCompanion.insert(
                extraKey: _extraKey(extra),
                workId: workId,
                kind: _extraKind(extra.kind),
                sourceKind: 'online',
                title: extra.title,
                provider: Value<String?>(extra.provider?.name),
                providerVideoId: Value<String?>(extra.providerVideoId),
                site: Value<String?>(extra.site),
                remoteUrl: Value<String?>(extra.remoteUrl),
                thumbnailUrl: Value<String?>(extra.thumbnailUrl),
                durationMs: Value<int?>(extra.durationMs),
                official: Value<bool>(extra.official),
                language: Value<String?>(extra.language),
                publishedAt: Value<String?>(extra.publishedAt),
                sortOrder: Value<int>(extra.order),
                updatedAt: now,
              ),
        ],
      );

      final Map<int, VideoMetadataSeasonRow> existingSeasons =
          <int, VideoMetadataSeasonRow>{
            for (final VideoMetadataSeasonRow row
                in await database.getVideoMetadataSeasons(workId))
              row.seasonNumber: row,
          };
      final List<VideoMetadataSeasonsCompanion> seasonRows =
          <VideoMetadataSeasonsCompanion>[
            for (final VideoMetadataSeason season in metadata.seasons)
              VideoMetadataSeasonsCompanion.insert(
                workId: workId,
                seasonNumber: season.seasonNumber,
                title: Value<String?>(season.title),
                overview: Value<String?>(
                  season.plot ??
                      (!seasonEpisodesAuthoritative
                          ? existingSeasons[season.seasonNumber]?.overview
                          : null),
                ),
                premiereDate: Value<String?>(
                  season.airDate ??
                      (!seasonEpisodesAuthoritative
                          ? existingSeasons[season.seasonNumber]?.premiereDate
                          : null),
                ),
                year: Value<int?>(
                  season.year ??
                      (!seasonEpisodesAuthoritative
                          ? existingSeasons[season.seasonNumber]?.year
                          : null),
                ),
                episodeCount: Value<int?>(
                  season.episodeCount ??
                      (!seasonEpisodesAuthoritative
                          ? existingSeasons[season.seasonNumber]?.episodeCount
                          : null),
                ),
                rating: Value<double?>(
                  season.rating ??
                      (!seasonEpisodesAuthoritative
                          ? existingSeasons[season.seasonNumber]?.rating
                          : null),
                ),
                updatedAt: now,
              ),
          ];
      if (seasonEpisodesAuthoritative) {
        await database.replaceVideoMetadataSeasons(workId, seasonRows);
      } else {
        for (final VideoMetadataSeasonsCompanion season in seasonRows) {
          await database.upsertVideoMetadataSeason(season);
        }
      }
      for (final VideoMetadataSeasonRow row
          in await database.getVideoMetadataSeasons(workId)) {
        seasonIds[row.seasonNumber] = row.id;
      }

      final Map<(int, int), VideoBookRow> localEpisodeBooks =
          _localEpisodeBooks(
            localWork.members,
            episodeOverrides,
            additionalEpisodeBindings,
            userVerifiedBooks: userVerifiedBooks,
          );
      await _clearReassignedEpisodeBooks(
        localEpisodeBooks: localEpisodeBooks,
        seasons: metadata.seasons,
      );
      for (final VideoMetadataSeason season in metadata.seasons) {
        final int? seasonId = seasonIds[season.seasonNumber];
        if (seasonId == null) continue;
        if (seasonEpisodesAuthoritative || season.ids.isNotEmpty) {
          await _replaceIdentities(
            seasonId: seasonId,
            ids: season.ids,
            primaryProvider: metadata.provider,
            now: now,
          );
        }
        if (seasonEpisodesAuthoritative || season.images.isNotEmpty) {
          await _replaceImages(
            seasonId: seasonId,
            images: season.images,
            now: now,
          );
        }
        final Map<int, VideoMetadataEpisodeRow> existingEpisodes =
            <int, VideoMetadataEpisodeRow>{
              for (final VideoMetadataEpisodeRow row
                  in await database.getVideoMetadataEpisodes(seasonId))
                row.episodeNumber: row,
            };
        final List<VideoMetadataEpisodesCompanion>
        episodeRows = <VideoMetadataEpisodesCompanion>[
          for (final VideoMetadataEpisode episode in season.episodes)
            () {
              final String? bookUid =
                  localEpisodeBooks[(
                        episode.seasonNumber,
                        episode.episodeNumber,
                      )]
                      ?.bookUid ??
                  existingEpisodes[episode.episodeNumber]?.bookUid;
              // AniDB 集身份跟着绑定的文件走：这一轮有身份就写，没有身份但书还
              // 是原来那本就保留旧值，换了书 / 解绑就清掉。一文件多集时，额外
              // 绑定的那一集用它自己的 AniDB 身份，不是主集的。
              final AnidbEpisodeXref? xref = bookUid == null
                  ? null
                  : additionalEpisodeBindings[bookUid]?[(
                          episode.seasonNumber,
                          episode.episodeNumber,
                        )] ??
                        anidbEpisodeXrefs[bookUid];
              final VideoMetadataEpisodeRow? existing =
                  existingEpisodes[episode.episodeNumber];
              final bool keepExisting =
                  xref == null &&
                  existing != null &&
                  existing.bookUid != null &&
                  existing.bookUid == bookUid;
              return VideoMetadataEpisodesCompanion.insert(
                seasonId: seasonId,
                bookUid: Value<String?>(bookUid),
                anidbEpisodeId: Value<int?>(
                  xref?.episodeId ??
                      (keepExisting ? existing.anidbEpisodeId : null),
                ),
                anidbEpisodeNumber: Value<String?>(
                  xref?.episodeNumber ??
                      (keepExisting ? existing.anidbEpisodeNumber : null),
                ),
                anidbMatchRating: Value<String?>(
                  xref?.matchRating ??
                      (keepExisting ? existing.anidbMatchRating : null),
                ),
                episodeNumber: episode.episodeNumber,
                absoluteNumber: Value<int?>(
                  episode.absoluteNumber ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]
                                ?.absoluteNumber
                          : null),
                ),
                title: Value<String?>(episode.title),
                overview: Value<String?>(
                  episode.plot ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]?.overview
                          : null),
                ),
                airDate: Value<String?>(
                  episode.airDate ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]?.airDate
                          : null),
                ),
                year: Value<int?>(
                  episode.year ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]?.year
                          : null),
                ),
                rating: Value<double?>(
                  episode.rating ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]?.rating
                          : null),
                ),
                ratingCount: Value<int?>(
                  episode.ratingVotes ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]?.ratingCount
                          : null),
                ),
                runtimeMinutes: Value<int?>(
                  episode.runtimeMinutes ??
                      (!seasonEpisodesAuthoritative
                          ? existingEpisodes[episode.episodeNumber]
                                ?.runtimeMinutes
                          : null),
                ),
                updatedAt: now,
              );
            }(),
        ];
        if (seasonEpisodesAuthoritative) {
          await database.replaceVideoMetadataEpisodes(seasonId, episodeRows);
        } else {
          for (final VideoMetadataEpisodesCompanion episode in episodeRows) {
            await database.upsertVideoMetadataEpisode(episode);
          }
        }
        for (final VideoMetadataEpisodeRow row
            in await database.getVideoMetadataEpisodes(seasonId)) {
          episodeIds[(season.seasonNumber, row.episodeNumber)] = row.id;
        }
        for (final VideoMetadataEpisode episode in season.episodes) {
          final int? episodeId =
              episodeIds[(season.seasonNumber, episode.episodeNumber)];
          if (episodeId == null) continue;
          if (seasonEpisodesAuthoritative || episode.ids.isNotEmpty) {
            await _replaceIdentities(
              episodeId: episodeId,
              ids: episode.ids,
              primaryProvider: metadata.provider,
              now: now,
            );
          }
          if (seasonEpisodesAuthoritative || episode.credits.isNotEmpty) {
            await _replaceCredits(
              episodeId: episodeId,
              credits: episode.credits,
              now: now,
            );
          }
          if (seasonEpisodesAuthoritative || episode.images.isNotEmpty) {
            await _replaceImages(
              episodeId: episodeId,
              images: episode.images,
              now: now,
            );
          }
          final VideoBookRow? book =
              localEpisodeBooks[(episode.seasonNumber, episode.episodeNumber)];
          // 旧投影 / 改书名只跟主集：一文件多集的额外绑定不进 bookUid → 集表。
          if (book != null &&
              additionalEpisodeBindings[book.bookUid]?.containsKey((
                    episode.seasonNumber,
                    episode.episodeNumber,
                  )) !=
                  true) {
            episodesByBookUid[book.bookUid] = episode;
          }
        }
      }
      await _writeLegacyProjection(
        localWork,
        metadata,
        episodesByBookUid,
        preserveExisting: preserveExistingLegacyProjection,
      );
    });

    return PersistedVideoMetadata(
      workId: workId,
      seasonIds: Map<int, int>.unmodifiable(seasonIds),
      episodeIds: Map<(int, int), int>.unmodifiable(episodeIds),
      episodesByBookUid: Map<String, VideoMetadataEpisode>.unmodifiable(
        episodesByBookUid,
      ),
    );
  }

  /// 删掉合集自己拥有的作品行（成员按 AniDB 作品拆成各自的电影作品后，合集级
  /// 的那一行是残留——否则合集详情页会继续展示旧身份）。与
  /// [_removeBookOwnedWorksForCollection] 对称；季 / 集 / 身份 / 图随 FK 级联。
  /// 那部作品刮来的系列关系（合集起点、非 `local` 的行）一并删掉——它们描述的是
  /// 已经不存在的身份；按季拆分建的 `local` 行是用户结构，不动。
  Future<void> removeCollectionOwnedWork(int collectionId) async {
    await (database.delete(
      database.videoMetadataWorks,
    )..where((table) => table.collectionId.equals(collectionId))).go();
    await (database.delete(database.collectionRelations)..where(
          (table) =>
              table.collectionId.equals(collectionId) &
              table.source.equals('local').not(),
        ))
        .go();
  }

  /// [collectionId] 没有合集行、视频成员里恰好一个自己挂着作品行时，把那一行
  /// 改归属到合集（`book_uid` → `collection_id`），返回升格后的行；不满足（0 个
  /// 或多个成员各有作品——那是各自独立的作品，没有哪一条能代表合集）返回 null。
  /// 那部作品起点的系列关系一并改挂到合集（合集已有同 `(source, subject_id)` 的
  /// 行时保留合集的，成员那条随后由 [_removeBookOwnedWorksForCollection] 清掉）。
  /// 调用方须在事务里。
  Future<VideoMetadataWorkRow?> _promoteSoleMemberWork(int collectionId) async {
    final Set<String> memberBookUids =
        (await database.getCollectionItems(collectionId))
            .where((MediaCollectionItemRow row) => row.mediaType == 'video')
            .map((MediaCollectionItemRow row) => row.entryKey)
            .toSet();
    if (memberBookUids.isEmpty) return null;
    final List<VideoMetadataWorkRow> owned = await (database.select(
      database.videoMetadataWorks,
    )..where((table) => table.bookUid.isIn(memberBookUids))).get();
    if (owned.length != 1) return null;
    final VideoMetadataWorkRow work = owned.single;
    final String memberUid = work.bookUid!;
    await (database.update(
      database.videoMetadataWorks,
    )..where((table) => table.id.equals(work.id))).write(
      VideoMetadataWorksCompanion(
        collectionId: Value<int?>(collectionId),
        bookUid: const Value<String?>(null),
      ),
    );
    await database.customUpdate(
      'UPDATE OR IGNORE collection_relations '
      'SET collection_id = ?, book_uid = NULL WHERE book_uid = ?',
      variables: <Variable<Object>>[
        Variable<int>(collectionId),
        Variable<String>(memberUid),
      ],
      updates: <TableInfo<Table, dynamic>>{database.collectionRelations},
      updateKind: UpdateKind.update,
    );
    return database.getVideoMetadataWorkByCollection(collectionId);
  }

  Future<void> _removeBookOwnedWorksForCollection(int collectionId) async {
    final Set<String> memberBookUids =
        (await database.getCollectionItems(collectionId))
            .where((MediaCollectionItemRow row) => row.mediaType == 'video')
            .map((MediaCollectionItemRow row) => row.entryKey)
            .toSet();
    if (memberBookUids.isEmpty) return;
    await (database.delete(
      database.videoMetadataWorks,
    )..where((table) => table.bookUid.isIn(memberBookUids))).go();
    // 成员自己那部作品（散装电影）刮来的系列关系随作品一起作废（v162 单视频起点）。
    await (database.delete(
      database.collectionRelations,
    )..where((table) => table.bookUid.isIn(memberBookUids))).go();
  }

  Future<void> _clearReassignedEpisodeBooks({
    required Map<(int, int), VideoBookRow> localEpisodeBooks,
    required Iterable<VideoMetadataSeason> seasons,
  }) async {
    final Set<String> reassignedBookUids = <String>{
      for (final VideoMetadataSeason season in seasons)
        for (final VideoMetadataEpisode episode in season.episodes)
          if (localEpisodeBooks[(episode.seasonNumber, episode.episodeNumber)]
              case final VideoBookRow book)
            book.bookUid,
    };
    if (reassignedBookUids.isEmpty) return;
    await (database.update(
      database.videoMetadataEpisodes,
    )..where((table) => table.bookUid.isIn(reassignedBookUids))).write(
      const VideoMetadataEpisodesCompanion(bookUid: Value<String?>(null)),
    );
  }

  Future<void> updateCanonicalImagePaths({
    required PersistedVideoMetadata persisted,
    required VideoMetadataWork metadata,
    required Map<String, String> localPathByRemoteUrl,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 下载落盘后这一趟会整体重写作品级图行；锁住的图种必须在这里也守住，否则
    // apply() 保住的旧封面会被同一次刮削的第二步又换掉。
    final VideoMetadataWorkRow? workRow = await database
        .getVideoMetadataWorkById(persisted.workId);
    final Set<VideoMetadataLockableField> locked = parseLockedFields(
      workRow?.lockedFields,
    );
    await _replaceImages(
      workId: persisted.workId,
      images: metadata.images,
      now: now,
      localPathByRemoteUrl: localPathByRemoteUrl,
      lockedKinds: <VideoMetadataImageKind>{
        if (locked.contains(VideoMetadataLockableField.cover))
          VideoMetadataImageKind.cover,
        if (locked.contains(VideoMetadataLockableField.backdrop))
          VideoMetadataImageKind.backdrop,
      },
    );
    for (final VideoMetadataSeason season in metadata.seasons) {
      final int? seasonId = persisted.seasonIds[season.seasonNumber];
      if (seasonId == null) continue;
      await _replaceImages(
        seasonId: seasonId,
        images: season.images,
        now: now,
        localPathByRemoteUrl: localPathByRemoteUrl,
      );
      for (final VideoMetadataEpisode episode in season.episodes) {
        final int? episodeId =
            persisted.episodeIds[(episode.seasonNumber, episode.episodeNumber)];
        if (episodeId == null) continue;
        await _replaceImages(
          episodeId: episodeId,
          images: episode.images,
          now: now,
          localPathByRemoteUrl: localPathByRemoteUrl,
        );
      }
    }
  }

  Future<void> _replaceIdentities({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataId> ids,
    required VideoMetadataProviderKind primaryProvider,
    required int now,
  }) async {
    final String owner = workId != null
        ? 'work:$workId'
        : seasonId != null
        ? 'season:$seasonId'
        : 'episode:$episodeId';
    await database.replaceVideoMetadataProviderIdentities(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        for (final VideoMetadataId id in _uniqueIds(ids))
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: '$owner:${id.type.toLowerCase()}',
            workId: Value<int?>(workId),
            seasonId: Value<int?>(seasonId),
            episodeId: Value<int?>(episodeId),
            provider: id.type.toLowerCase(),
            externalId: id.value,
            isPrimary: Value<bool>(
              id.type.trim().toLowerCase() == primaryProvider.name,
            ),
            updatedAt: now,
          ),
      ],
    );
  }

  Future<void> _replaceRawSnapshot(
    int workId,
    VideoMetadataWork metadata,
    int now,
  ) async {
    final Map<String, Object?>? payload = metadata.rawPayload;
    if (payload == null) return;
    final List<VideoMetadataProviderIdentityRow> identities = await database
        .getVideoMetadataProviderIdentities(workId: workId);
    final VideoMetadataProviderIdentityRow? primary = identities
        .where(
          (VideoMetadataProviderIdentityRow row) =>
              row.provider == metadata.provider.name,
        )
        .firstOrNull;
    if (primary == null) return;
    await database.replaceVideoMetadataRawSnapshots(
      primary.identityKey,
      <VideoMetadataRawSnapshotsCompanion>[
        VideoMetadataRawSnapshotsCompanion.insert(
          identityKey: primary.identityKey,
          snapshotKind: 'details',
          rawJson: jsonEncode(payload),
          fetchedAt: now,
        ),
      ],
    );
  }

  /// 编辑对话框的初值：目标作品行的当前值；还没有作品行时只有标题（取
  /// [fallbackTitle]，即合集名 / 视频名），其余为空。
  Future<VideoWorkManualEdit> currentManualEdit(
    VideoWorkManualTarget target, {
    required String fallbackTitle,
  }) async {
    if (target case VideoWorkManualTargetExisting(
      :final VideoMetadataWorkRow work,
    )) {
      final VideoMetadataWorkRow row =
          await database.getVideoMetadataWorkById(work.id) ?? work;
      final Map<String, List<String>> terms = await _termsByKind(row.id);
      return VideoWorkManualEdit(
        title: row.title,
        originalTitle: row.originalTitle,
        overview: row.overview,
        tagline: row.tagline,
        year: row.year,
        genres: terms['genre'] ?? const <String>[],
        studios: terms['studio'] ?? const <String>[],
      );
    }
    return VideoWorkManualEdit(title: fallbackTitle);
  }

  /// 落库用户手填的作品资料（BUG-5082），返回作品行 id。
  ///
  /// 逐字段判断「用户改没改」：**改过**的字段写新值并进字段锁（之后刮削保留手填值，
  /// 与封面锁同一语义）；**改成空**的字段清值并解锁（撤回手填，下次刮削回填）；
  /// 没改的字段值与锁状态都不动（保留库里此刻的值）。标题列非空：清空标题 = 回到
  /// [fallbackTitle] 并解锁。目标还没有作品行（刮削全失败）时按 [target] 的归属
  /// 新建一行，不写 provider 身份——作品仍算未识别，自动补刮照常会去找它。
  ///
  /// 「改没改」以 [baseline] 为准——对话框打开时展示给用户的那份值
  /// （[currentManualEdit]）。对话框开着时自动补刮可能已经落库：拿库里的新值当
  /// 基准，用户没碰过的旧初值会被当成「改过」，把刚刮到的简介 / 类型清空或锁成
  /// 旧值（丢失更新）。不传 [baseline] 时以库里当前值为基准（程序化调用）。
  Future<int> applyManualEdit(
    VideoWorkManualTarget target,
    VideoWorkManualEdit edit, {
    required String fallbackTitle,
    VideoWorkManualEdit? baseline,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return database.transaction<int>(() async {
      final VideoMetadataWorkRow? existing = switch (target) {
        VideoWorkManualTargetExisting(:final VideoMetadataWorkRow work) =>
          await database.getVideoMetadataWorkById(work.id),
        VideoWorkManualTargetCollection(:final int collectionId) =>
          await database.getVideoMetadataWorkByCollection(collectionId),
        VideoWorkManualTargetBook(:final String bookUid) =>
          await database.getVideoMetadataWorkByBook(bookUid),
      };
      if (existing == null && target is VideoWorkManualTargetExisting) {
        throw StateError(
          'video metadata work ${target.work.id} no longer exists',
        );
      }
      final Set<VideoMetadataLockableField> locked = parseLockedFields(
        existing?.lockedFields,
      );
      final Map<String, List<String>> currentTerms = existing == null
          ? const <String, List<String>>{}
          : await _termsByKind(existing.id);
      final String fallback =
          normalizeManualText(fallbackTitle) ?? fallbackTitle;

      // 基准：对话框初值；没给时取库里当前值。
      final VideoWorkManualEdit base =
          baseline ??
          VideoWorkManualEdit(
            title: existing?.title ?? fallback,
            originalTitle: existing?.originalTitle,
            overview: existing?.overview,
            tagline: existing?.tagline,
            year: existing?.year,
            genres: currentTerms['genre'] ?? const <String>[],
            studios: currentTerms['studio'] ?? const <String>[],
          );

      // 改过（与基准不同）→ 写 [after] 并按空 / 非空解锁 / 上锁；没改 → 原值原锁。
      T? resolve<T>(
        VideoMetadataLockableField field,
        T? before,
        T? after,
        T? current,
      ) {
        if (before == after) return current;
        if (after == null) {
          locked.remove(field);
        } else {
          locked.add(field);
        }
        return after;
      }

      final String? typedTitle = normalizeManualText(edit.title);
      final String baseTitle = normalizeManualText(base.title) ?? fallback;
      final String currentTitle = existing?.title ?? fallback;
      final String title;
      if (typedTitle == null) {
        locked.remove(VideoMetadataLockableField.title);
        title = fallback;
      } else if (typedTitle != baseTitle) {
        locked.add(VideoMetadataLockableField.title);
        title = typedTitle;
      } else {
        title = currentTitle;
      }
      final String? originalTitle = resolve<String>(
        VideoMetadataLockableField.originalTitle,
        normalizeManualText(base.originalTitle),
        normalizeManualText(edit.originalTitle),
        existing?.originalTitle,
      );
      final String? overview = resolve<String>(
        VideoMetadataLockableField.overview,
        normalizeManualText(base.overview),
        normalizeManualText(edit.overview),
        existing?.overview,
      );
      final String? tagline = resolve<String>(
        VideoMetadataLockableField.tagline,
        normalizeManualText(base.tagline),
        normalizeManualText(edit.tagline),
        existing?.tagline,
      );
      final int? year = resolve<int>(
        VideoMetadataLockableField.year,
        base.year,
        edit.year,
        existing?.year,
      );

      // 列表按「逐项相同且同序」比较；空列表与 null 同义（没有手填值）。
      String? termsKey(List<String> values) =>
          values.isEmpty ? null : values.join('\u0000');
      List<String> resolveTerms(
        VideoMetadataLockableField field,
        List<String> before,
        List<String> after,
        List<String> current,
      ) {
        final List<String> normalizedAfter = normalizeManualTerms(after);
        final String? beforeKey = termsKey(normalizeManualTerms(before));
        final String? afterKey = termsKey(normalizedAfter);
        if (beforeKey == afterKey) return current;
        resolve<String>(field, beforeKey, afterKey, null);
        return normalizedAfter;
      }

      final List<String> currentGenres =
          currentTerms['genre'] ?? const <String>[];
      final List<String> currentStudios =
          currentTerms['studio'] ?? const <String>[];
      final List<String> genres = resolveTerms(
        VideoMetadataLockableField.genres,
        base.genres,
        edit.genres,
        currentGenres,
      );
      final List<String> studios = resolveTerms(
        VideoMetadataLockableField.studios,
        base.studios,
        edit.studios,
        currentStudios,
      );
      final bool termsChanged =
          !identical(genres, currentGenres) ||
          !identical(studios, currentStudios);

      final int workId;
      if (existing != null) {
        workId = existing.id;
        await (database.update(
          database.videoMetadataWorks,
        )..where((table) => table.id.equals(workId))).write(
          VideoMetadataWorksCompanion(
            title: Value<String>(title),
            originalTitle: Value<String?>(originalTitle),
            overview: Value<String?>(overview),
            tagline: Value<String?>(tagline),
            year: Value<int?>(year),
            lockedFields: Value<String?>(encodeLockedFields(locked)),
            updatedAt: Value<int>(now),
          ),
        );
      } else {
        final (
          int? collectionId,
          String? bookUid,
          String mediaType,
        ) = switch (target) {
          VideoWorkManualTargetCollection(:final int collectionId) => (
            collectionId,
            null,
            VideoMetadataMediaKind.tv.name,
          ),
          VideoWorkManualTargetBook(:final String bookUid) => (
            null,
            bookUid,
            VideoMetadataMediaKind.movie.name,
          ),
          VideoWorkManualTargetExisting() => throw StateError(
            'existing target without a row',
          ),
        };
        workId = await database.upsertVideoMetadataWork(
          VideoMetadataWorksCompanion.insert(
            collectionId: Value<int?>(collectionId),
            bookUid: Value<String?>(bookUid),
            mediaType: mediaType,
            title: title,
            originalTitle: Value<String?>(originalTitle),
            overview: Value<String?>(overview),
            tagline: Value<String?>(tagline),
            year: Value<int?>(year),
            lockedFields: Value<String?>(encodeLockedFields(locked)),
            updatedAt: now,
          ),
        );
      }
      if (termsChanged) {
        await _replaceTerms(
          workId,
          genres: genres,
          studios: studios,
          countries: currentTerms['country'] ?? const <String>[],
          keywords: currentTerms['keyword'] ?? const <String>[],
        );
      }
      return workId;
    });
  }

  /// 读回本作品当前的词条，按 kind 分组（字段锁保留整组词 / 手填时用）。
  Future<Map<String, List<String>>> _termsByKind(int workId) async {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final VideoMetadataTermRow row
        in await database.getVideoMetadataTermsForWork(workId)) {
      out.putIfAbsent(row.kind, () => <String>[]).add(row.name);
    }
    return out;
  }

  /// 四种词整体替换。[genres] / [studios] 由调用方给出：字段锁生效时传旧集合，
  /// 否则传 `metadata` 自己的；手填（[applyManualEdit]）传用户填的、country /
  /// keyword 原样传回旧集合。
  Future<void> _replaceTerms(
    int workId, {
    required List<String> genres,
    required List<String> studios,
    required List<String> countries,
    required List<String> keywords,
  }) async {
    final List<(String, String)> values = <(String, String)>[
      for (final String value in genres) ('genre', value),
      for (final String value in studios) ('studio', value),
      for (final String value in countries) ('country', value),
      for (final String value in keywords) ('keyword', value),
    ];
    final List<VideoMetadataTermsCompanion> terms =
        <VideoMetadataTermsCompanion>[];
    final List<VideoMetadataWorkTermsCompanion> mappings =
        <VideoMetadataWorkTermsCompanion>[];
    final Set<String> seen = <String>{};
    for (final (String kind, String name) in values) {
      final String normalized = TitleNormalizer.normalize(name);
      if (normalized.isEmpty || !seen.add('$kind:$normalized')) continue;
      final String key = '$kind:${_digest(normalized)}';
      terms.add(
        VideoMetadataTermsCompanion.insert(
          termKey: key,
          kind: kind,
          name: name,
          normalizedName: normalized,
        ),
      );
      mappings.add(
        VideoMetadataWorkTermsCompanion.insert(
          workId: workId,
          termKey: key,
          sortOrder: Value<int>(mappings.length),
        ),
      );
    }
    await database.replaceVideoMetadataTermsForWork(
      workId: workId,
      terms: terms,
      mappings: mappings,
    );
  }

  Future<void> _replaceCredits({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataCredit> credits,
    required int now,
    bool keepExisting = false,
  }) async {
    final List<VideoMetadataPeopleCompanion> people =
        <VideoMetadataPeopleCompanion>[];
    final List<VideoMetadataCharactersCompanion> characters =
        <VideoMetadataCharactersCompanion>[];
    final List<VideoMetadataCreditsCompanion> rows =
        <VideoMetadataCreditsCompanion>[];
    final Set<String> seenCredits = <String>{};
    // 真正写进库的 credit。下面补外部 id 时只认它们：去重丢掉的那条 credit 的人物 /
    // 角色行没写，给它写 provider identity 会撞外键、让整部作品刮削失败（BUG-5281：
    // AniDB 同一部作品里两个同名角色由同一位声优配音，第二条 credit 被去重，它的
    // 角色 id 却照样去写 identity）。
    final List<VideoMetadataCredit> written = <VideoMetadataCredit>[];
    for (final VideoMetadataCredit credit in credits) {
      final String personKey = _personKey(credit.person);
      // 与表上 UNIQUE(owner, person_key, credit_kind, role_name) 同一判据。
      final String creditKey = <String>[
        personKey,
        credit.kind.name,
        credit.roleName ?? credit.character?.name ?? '',
      ].join('\u0000');
      if (!seenCredits.add(creditKey)) continue;
      written.add(credit);
      people.add(
        VideoMetadataPeopleCompanion.insert(
          personKey: personKey,
          name: credit.person.name,
          originalName: Value<String?>(credit.person.originalName),
          biography: Value<String?>(credit.person.biography),
          birthday: Value<String?>(credit.person.birthday),
          deathday: Value<String?>(credit.person.deathday),
          gender: Value<int?>(credit.person.gender),
          placeOfBirth: Value<String?>(credit.person.placeOfBirth),
          profileUrl: Value<String?>(credit.person.profileUrl),
          updatedAt: now,
        ),
      );
      String? characterKey;
      if (credit.character case final VideoMetadataCharacter character) {
        characterKey = _characterKey(character);
        characters.add(
          VideoMetadataCharactersCompanion.insert(
            characterKey: characterKey,
            name: character.name,
            originalName: Value<String?>(character.originalName),
            description: Value<String?>(character.description),
            imageUrl: Value<String?>(character.imageUrl),
            updatedAt: now,
          ),
        );
      }
      rows.add(
        VideoMetadataCreditsCompanion.insert(
          workId: Value<int?>(workId),
          seasonId: Value<int?>(seasonId),
          episodeId: Value<int?>(episodeId),
          personKey: personKey,
          characterKey: Value<String?>(characterKey),
          creditKind: _creditKind(credit.kind),
          roleName: Value<String>(
            credit.roleName ?? credit.character?.name ?? '',
          ),
          department: Value<String?>(credit.department),
          job: Value<String?>(credit.job),
          language: Value<String?>(credit.language),
          providerCreditId: Value<String?>(credit.providerCreditId),
          sortOrder: Value<int>(credit.order),
        ),
      );
    }
    await database.upsertVideoMetadataPeople(people);
    await database.upsertVideoMetadataCharacters(characters);
    await database.replaceVideoMetadataCredits(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      credits: rows,
      keepExisting: keepExisting,
    );
    for (final VideoMetadataCredit credit in written) {
      await _mergeEntityIdentities(
        personKey: _personKey(credit.person),
        ids: credit.person.ids,
        now: now,
      );
      if (credit.character case final VideoMetadataCharacter character) {
        await _mergeEntityIdentities(
          characterKey: _characterKey(character),
          ids: character.ids,
          now: now,
        );
      }
    }
  }

  Future<void> _mergeEntityIdentities({
    String? personKey,
    String? characterKey,
    required List<VideoMetadataId> ids,
    required int now,
  }) async {
    if (ids.isEmpty) return;
    final List<VideoMetadataProviderIdentityRow> existing = await database
        .getVideoMetadataProviderIdentities(
          personKey: personKey,
          characterKey: characterKey,
        );
    final Map<String, VideoMetadataId> merged = <String, VideoMetadataId>{
      for (final VideoMetadataProviderIdentityRow row in existing)
        row.provider: VideoMetadataId(
          type: row.provider,
          value: row.externalId,
          isDefault: row.isPrimary,
        ),
      for (final VideoMetadataId id in ids) id.type.toLowerCase(): id,
    };
    final String owner = personKey == null
        ? 'character:$characterKey'
        : 'person:$personKey';
    await database.replaceVideoMetadataProviderIdentities(
      personKey: personKey,
      characterKey: characterKey,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        for (final VideoMetadataId id in merged.values)
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: '$owner:${id.type.toLowerCase()}',
            personKey: Value<String?>(personKey),
            characterKey: Value<String?>(characterKey),
            provider: id.type.toLowerCase(),
            externalId: id.value,
            isPrimary: Value<bool>(id.isDefault),
            updatedAt: now,
          ),
      ],
    );
  }

  /// [lockedKinds]：字段锁住的图种。这些种类的旧行**原样留下**（远端 url、本地
  /// 缓存路径、评分都不动），新抓到的同种图整批丢弃——锁的语义是「不换」，不是
  /// 「抓不到才不换」。
  Future<void> _replaceImages({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataImage> images,
    required int now,
    Map<String, String> localPathByRemoteUrl = const <String, String>{},
    Set<VideoMetadataImageKind> lockedKinds = const <VideoMetadataImageKind>{},
  }) async {
    final List<VideoMetadataImageRow> existing = await database
        .getVideoMetadataImages(
          workId: workId,
          seasonId: seasonId,
          episodeId: episodeId,
        );
    final Set<String> lockedKindNames = <String>{
      for (final VideoMetadataImageKind kind in lockedKinds) kind.name,
    };
    final Map<(String, String, String), String> existingLocalPaths =
        <(String, String, String), String>{
          for (final VideoMetadataImageRow row in existing)
            if (row.localPath case final String localPath
                when localPath.isNotEmpty)
              (row.provider, row.kind, row.remoteUrl): localPath,
        };
    final Map<VideoMetadataImageKind, int> positions =
        <VideoMetadataImageKind, int>{};
    final List<VideoMetadataImagesCompanion> rows =
        <VideoMetadataImagesCompanion>[];
    for (final VideoMetadataImageRow row in existing) {
      if (!lockedKindNames.contains(row.kind)) continue;
      rows.add(
        VideoMetadataImagesCompanion.insert(
          workId: Value<int?>(workId),
          seasonId: Value<int?>(seasonId),
          episodeId: Value<int?>(episodeId),
          provider: row.provider,
          kind: row.kind,
          position: Value<int>(row.position),
          language: Value<String?>(row.language),
          remoteUrl: row.remoteUrl,
          localPath: Value<String?>(row.localPath),
          rating: Value<double?>(row.rating),
          voteCount: Value<int?>(row.voteCount),
          updatedAt: row.updatedAt,
        ),
      );
    }
    for (final VideoMetadataImage image in images) {
      if (lockedKindNames.contains(image.kind.name)) continue;
      final int position = positions.update(
        image.kind,
        (int value) => value + 1,
        ifAbsent: () => 0,
      );
      rows.add(
        VideoMetadataImagesCompanion.insert(
          workId: Value<int?>(workId),
          seasonId: Value<int?>(seasonId),
          episodeId: Value<int?>(episodeId),
          provider: image.provider.name,
          kind: image.kind.name,
          position: Value<int>(position),
          language: Value<String?>(image.language),
          remoteUrl: image.url,
          localPath: Value<String?>(
            localPathByRemoteUrl[image.url] ??
                existingLocalPaths[(
                  image.provider.name,
                  image.kind.name,
                  image.url,
                )],
          ),
          rating: Value<double?>(image.voteAverage),
          voteCount: Value<int?>(image.voteCount),
          updatedAt: now,
        ),
      );
    }
    await database.replaceVideoMetadataImages(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      images: rows,
    );
  }

  /// [preserveExisting] 为 true 时只补写不存在的行（见
  /// [apply] 的 `preserveExistingLegacyProjection`）。
  Future<void> _writeLegacyProjection(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata,
    Map<String, VideoMetadataEpisode> episodeByBook, {
    required bool preserveExisting,
  }) async {
    final String subjectId = _primaryId(metadata)?.value ?? metadata.title;
    final String source = metadata.provider.name;
    final String? tags = metadata.genres.isEmpty && metadata.keywords.isEmpty
        ? null
        : jsonEncode(<Map<String, Object?>>[
            for (final String value in <String>{
              ...metadata.genres,
              ...metadata.keywords,
            })
              <String, Object?>{'name': value},
          ]);
    final String? infobox = _legacyInfobox(metadata);
    final DateTime scrapedAt = DateTime.now();
    if (localWork.collection case final MediaCollectionRow collection) {
      final bool keepCollectionRow =
          preserveExisting &&
          await database.getCollectionScrapeMeta(collection.id) != null;
      if (!keepCollectionRow) {
        await database.upsertCollectionScrapeMeta(
          CollectionScrapeMetaCompanion.insert(
            collectionId: Value<int>(collection.id),
            source: source,
            subjectId: subjectId,
            title: metadata.title,
            originalTitle: Value<String?>(metadata.originalTitle),
            summary: Value<String?>(metadata.plot),
            airDate: Value<String?>(metadata.premiered),
            rating: Value<double?>(metadata.rating),
            ratingCount: Value<int?>(metadata.ratingVotes),
            episodeCount: Value<int?>(metadata.episodeCount),
            tagsJson: Value<String?>(tags),
            infoboxJson: Value<String?>(infobox),
            backdropPath: const Value<String?>(null),
            detailUrl: Value<String?>(_detailUrl(metadata)),
            scrapedAt: scrapedAt,
          ),
        );
      }
      for (final VideoBookRow book in localWork.members) {
        final VideoMetadataEpisode? episode = episodeByBook[book.bookUid];
        if (episode == null) continue;
        final VideoScrapeMetaRow? previous = await database.getVideoScrapeMeta(
          book.bookUid,
        );
        if (preserveExisting && previous != null) continue;
        await database.upsertVideoScrapeMeta(
          VideoScrapeMetaCompanion.insert(
            bookUid: book.bookUid,
            source: source,
            subjectId:
                _primaryIdFrom(
                  episode.ids,
                  preferred: metadata.provider.name,
                )?.value ??
                subjectId,
            title: episode.title,
            summary: Value<String?>(episode.plot),
            airDate: Value<String?>(episode.airDate),
            rating: Value<double?>(episode.rating),
            episodeNumber: Value<int?>(episode.episodeNumber),
            detailUrl: Value<String?>(_detailUrl(metadata)),
            scrapedAt: scrapedAt,
          ),
        );
        final String episodeTitle = episode.title.trim();
        if (episodeTitle.isNotEmpty &&
            episodeTitle != metadata.title &&
            (_isImportedFilenameTitle(book) ||
                (previous?.episodeNumber != null &&
                    previous!.title.trim() == book.title.trim()))) {
          // MoviePilot 会整理磁盘文件名；Fushi 明确不移动用户媒体，所以只把
          // provider 的真实分集名投影到 VideoBook 展示标题。用户手动改过的标题
          // 不满足“原始文件 stem/上一版刮削标题”判据，永远保留。
          await database.updateVideoBookTitle(book.bookUid, episodeTitle);
        }
      }
    } else {
      final String bookUid = localWork.members.single.bookUid;
      if (preserveExisting &&
          await database.getVideoScrapeMeta(bookUid) != null) {
        return;
      }
      await database.upsertVideoScrapeMeta(
        VideoScrapeMetaCompanion.insert(
          bookUid: bookUid,
          source: source,
          subjectId: subjectId,
          title: metadata.title,
          originalTitle: Value<String?>(metadata.originalTitle),
          summary: Value<String?>(metadata.plot),
          airDate: Value<String?>(metadata.premiered),
          rating: Value<double?>(metadata.rating),
          ratingCount: Value<int?>(metadata.ratingVotes),
          episodeCount: Value<int?>(metadata.episodeCount),
          tagsJson: Value<String?>(tags),
          infoboxJson: Value<String?>(infobox),
          detailUrl: Value<String?>(_detailUrl(metadata)),
          scrapedAt: scrapedAt,
        ),
      );
    }
  }

  /// 卡片 (季, 集) → 成员文件。用户钉死（UserVerified，[userVerifiedBooks]）
  /// 的成员最先占位，其余主键按成员顺序先到先得（一集只能有一本书），再把
  /// 一文件多集的额外键补进去（同样先到先得，不抢别的文件的主集）。
  static Map<(int, int), VideoBookRow> _localEpisodeBooks(
    Iterable<VideoBookRow> books,
    Map<String, (int, int)> episodeOverrides,
    AnidbAdditionalEpisodeBindings additionalEpisodeBindings, {
    Set<String> userVerifiedBooks = const <String>{},
  }) {
    final Map<(int, int), VideoBookRow> result = <(int, int), VideoBookRow>{};
    final List<VideoBookRow> ordered = <VideoBookRow>[
      for (final VideoBookRow book in books)
        if (userVerifiedBooks.contains(book.bookUid)) book,
      for (final VideoBookRow book in books)
        if (!userVerifiedBooks.contains(book.bookUid)) book,
    ];
    for (final VideoBookRow book in ordered) {
      final (int, int)? key = localEpisodeKeyFor(book, episodeOverrides);
      if (key == null) continue;
      result.putIfAbsent(key, () => book);
    }
    for (final VideoBookRow book in books) {
      final Map<(int, int), AnidbEpisodeXref>? extra =
          additionalEpisodeBindings[book.bookUid];
      if (extra == null) continue;
      for (final (int, int) key in extra.keys) {
        result.putIfAbsent(key, () => book);
      }
    }
    return result;
  }

  static bool _isImportedFilenameTitle(VideoBookRow book) {
    final String stem = p.basenameWithoutExtension(book.videoPath).trim();
    return stem.isNotEmpty &&
        stem.toLowerCase() == book.title.trim().toLowerCase();
  }

  static List<VideoMetadataId> _uniqueIds(Iterable<VideoMetadataId> ids) {
    final Map<String, VideoMetadataId> result = <String, VideoMetadataId>{};
    for (final VideoMetadataId id in ids) {
      final String type = id.type.trim().toLowerCase();
      final String value = id.value.trim();
      if (type.isNotEmpty && value.isNotEmpty) {
        result[type] = id.copyWith(type: type, value: value);
      }
    }
    return result.values.toList();
  }

  static String _creditKind(VideoMetadataCreditKind kind) => switch (kind) {
    VideoMetadataCreditKind.voiceActor => 'voice_actor',
    _ => kind.name,
  };

  /// 人物行主键（`person:<provider>:<id>` / 按名字摘要），与 apply 写
  /// `video_metadata_people` 时用的同一把键——人物照片落地要按它回写 `profilePath`。
  static String personKeyFor(VideoMetadataPerson person) => _personKey(person);

  static String _personKey(VideoMetadataPerson person) {
    final VideoMetadataId? id = _primaryIdFrom(person.ids);
    return id == null
        ? 'person:name:${_digest(TitleNormalizer.normalize(person.name))}'
        : 'person:${id.type.toLowerCase()}:${id.value}';
  }

  static String _characterKey(VideoMetadataCharacter character) {
    final VideoMetadataId? id = _primaryIdFrom(character.ids);
    return id == null
        ? 'character:name:${_digest(TitleNormalizer.normalize(character.name))}'
        : 'character:${id.type.toLowerCase()}:${id.value}';
  }

  static VideoMetadataId? _primaryId(VideoMetadataWork work) =>
      _primaryIdFrom(work.ids, preferred: work.provider.name);

  static VideoMetadataId? _primaryIdFrom(
    Iterable<VideoMetadataId> ids, {
    String? preferred,
  }) {
    final List<VideoMetadataId> values = ids.toList();
    if (preferred != null) {
      final String normalizedPreferred = preferred.trim().toLowerCase();
      for (final VideoMetadataId id in values) {
        if (id.type.trim().toLowerCase() == normalizedPreferred) return id;
      }
    }
    for (final VideoMetadataId id in values) {
      if (id.isDefault) return id;
    }
    return values.firstOrNull;
  }

  static String? _detailUrl(VideoMetadataWork work) {
    final VideoMetadataId? id = _primaryId(work);
    if (id == null) return null;
    return switch (work.provider) {
      VideoMetadataProviderKind.local => null,
      VideoMetadataProviderKind.anidb => 'https://anidb.net/anime/${id.value}',
      VideoMetadataProviderKind.mal =>
        'https://myanimelist.net/anime/${id.value}',
      VideoMetadataProviderKind.tmdb =>
        'https://www.themoviedb.org/${work.kind.name}/${id.value}',
      VideoMetadataProviderKind.bangumi => 'https://bgm.tv/subject/${id.value}',
      VideoMetadataProviderKind.anilist =>
        'https://anilist.co/anime/${id.value}',
      VideoMetadataProviderKind.douban =>
        'https://movie.douban.com/subject/${id.value}/',
      VideoMetadataProviderKind.fanart => null,
      // 服务器网页地址带登录态、换线路就变，不落库。
      VideoMetadataProviderKind.mediaserver => null,
    };
  }

  static String? _legacyInfobox(VideoMetadataWork work) {
    final List<Map<String, String>> values = <Map<String, String>>[
      if (work.studios.isNotEmpty)
        <String, String>{'key': 'Studio', 'value': work.studios.join(' / ')},
      if (work.countries.isNotEmpty)
        <String, String>{'key': 'Country', 'value': work.countries.join(' / ')},
      if (work.runtimeMinutes != null)
        <String, String>{
          'key': 'Runtime',
          'value': '${work.runtimeMinutes} min',
        },
      if (work.contentRating != null)
        <String, String>{'key': 'Certification', 'value': work.contentRating!},
    ];
    return values.isEmpty ? null : jsonEncode(values);
  }

  static String _extraKey(VideoMetadataExtra extra) {
    final String provider = extra.provider?.name ?? 'online';
    final String value =
        extra.providerVideoId ??
        sha1.convert(utf8.encode(extra.remoteUrl ?? extra.title)).toString();
    return '$provider:$value';
  }

  static String _extraKind(VideoMetadataExtraKind kind) => switch (kind) {
    VideoMetadataExtraKind.behindTheScenes => 'behind_the_scenes',
    VideoMetadataExtraKind.deletedScene => 'deleted_scene',
    _ => kind.name,
  };

  static String _digest(String value) =>
      sha1.convert(utf8.encode(value)).toString();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
