/// 视频来源规范刮削协调器：按作品识别、抓取、写 v77/兼容投影并安全导出 NFO/图片。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/anilist_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/authorized_douban_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/bangumi_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/fanart_video_image_provider.dart';
import 'package:fushi/src/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_asset_downloader.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_nfo_builder.dart';
import 'package:fushi/src/media/video/metadata/video_nfo_reader.dart';
import 'package:fushi/src/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:fushi/src/media/video/metadata/video_sidecar_target_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_sidecar_writer.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

class VideoSourceScrapeCoordinator
    implements VideoSourceScrapeRunner, VideoSourceScrapeInterruptible {
  VideoSourceScrapeCoordinator({
    required this.database,
    required this.config,
    VideoMetadataProviderRegistry? registry,
    VideoMetadataImageProvider? fanartProvider,
    VideoMetadataAssetDownloader? assetDownloader,
  })  : registry = registry ?? _createRegistry(config),
        fanartProvider = fanartProvider ??
            FanartVideoImageProvider(apiKey: config.fanartApiKey),
        assetDownloader = assetDownloader ?? VideoMetadataAssetDownloader(),
        _ownsRegistry = registry == null,
        _ownsFanartProvider = fanartProvider == null,
        _ownsAssetDownloader = assetDownloader == null,
        _store = VideoMetadataDatabaseStore(database);

  final FushiDatabase database;
  final VideoSourceScrapeGlobalConfig config;
  final VideoMetadataProviderRegistry registry;
  final VideoMetadataImageProvider fanartProvider;
  final VideoMetadataAssetDownloader assetDownloader;
  final bool _ownsRegistry;
  final bool _ownsFanartProvider;
  final bool _ownsAssetDownloader;
  final VideoMetadataDatabaseStore _store;
  final Set<int> _interruptedRunIds = <int>{};
  int? _activeRunId;

  static VideoMetadataProviderRegistry _createRegistry(
    VideoSourceScrapeGlobalConfig config,
  ) =>
      VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        TmdbVideoMetadataProvider(
          apiKey: config.tmdbApiKey,
          language: config.locale,
        ),
        BangumiVideoMetadataProvider(accessToken: config.bangumiToken),
        AniListVideoMetadataProvider(),
        AuthorizedDoubanVideoMetadataProvider(
          endpoint: config.doubanEndpoint,
          token: config.doubanToken,
        ),
      ]);

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
  }) async {
    // 识别结果只在本次用户批次内复用。全部来源时混来源合集共享同一份作品资料，
    // 但每个来源仍独立执行安全 sidecar 落盘；下次用户重刮会创建新 context。
    final VideoSourceScrapeBatchContext effectiveBatch =
        batchContext ?? VideoSourceScrapeBatchContext();
    if (source.mediaKind != 'video' || source.transport != 'local') {
      return SourceScrapeReport(
        sourceIds: <int>[source.id],
        warnings: <SourceScrapeIssue>[
          SourceScrapeIssue(
            workTitle: source.label,
            message: '只允许刮削已登记的本地视频来源',
          ),
        ],
      );
    }
    final VideoSourceScrapeSettingRow? storedSettings =
        await database.getVideoSourceScrapeSettings(source.id);
    final _EffectiveSourceSettings settings = _EffectiveSourceSettings.from(
      storedSettings,
      config,
      allowProtectedOverwrite: cancellationToken.allowProtectedOverwrite,
    );
    if (!settings.enabled) {
      return SourceScrapeReport(sourceIds: <int>[source.id]);
    }

    final int startedAt = DateTime.now().millisecondsSinceEpoch;
    final int runId = await database.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(source.id),
        scope: 'source',
        status: 'running',
        provider: Value<String?>(settings.provider.name),
        phase: const Value<String?>('planning'),
        startedAt: startedAt,
        updatedAt: startedAt,
      ),
    );
    _activeRunId = runId;

    final List<SourceScrapeIssue> warnings = <SourceScrapeIssue>[];
    final List<SourceScrapeIssue> errors = <SourceScrapeIssue>[];
    int succeeded = 0;
    int failed = 0;
    int pending = 0;
    int nfoWritten = 0;
    int imagesWritten = 0;
    int protectedArtifacts = 0;
    int unchangedArtifacts = 0;
    List<VideoSourceScrapeWork> works = const <VideoSourceScrapeWork>[];
    try {
      cancellationToken.throwIfCancelled();
      works = await VideoSourceWorkPlanner(database).plan(source);
      final List<String> knownSourcePaths = (await database.allVideoBooks())
          .where((VideoBookRow row) => row.sourceId == source.id)
          .map((VideoBookRow row) => row.videoPath)
          .toList(growable: false);
      await _publish(
        runId,
        onProgress,
        VideoSourceScrapeProgress(
          phase: VideoSourceScrapePhase.planning,
          sourceId: source.id,
          sourceLabel: source.label,
          total: works.length,
        ),
        totalWorks: works.length,
      );

      for (int index = 0; index < works.length; index++) {
        cancellationToken.throwIfCancelled();
        final VideoSourceScrapeWork localWork = works[index];
        await _publish(
          runId,
          onProgress,
          VideoSourceScrapeProgress(
            phase: VideoSourceScrapePhase.recognizing,
            sourceId: source.id,
            sourceLabel: source.label,
            currentWorkTitle: localWork.title,
            current: index,
            total: works.length,
          ),
          currentWorkTitle: localWork.title,
          processedWorks: index,
          succeededWorks: succeeded,
          failedWorks: failed,
          pendingConfirmations: pending,
        );
        try {
          final _ResolvedWork resolved = await _resolveWork(
            localWork,
            settings.provider,
            warnings,
            resolvedWorkCache: effectiveBatch.resolvedWorks,
            authoritativeSeasonEpisodesCache:
                effectiveBatch.authoritativeSeasonEpisodes,
            fanartEnabled: settings.fanartEnabled,
            source: source,
            onConfirmation: onConfirmation,
          );
          if (resolved.pending) {
            pending++;
            warnings.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: resolved.reason ?? '匹配结果存在歧义，需要人工确认',
            ));
            continue;
          }
          final VideoMetadataWork? metadata = resolved.metadata;
          if (metadata == null) {
            failed++;
            errors.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: resolved.reason ?? '没有找到严格匹配的作品',
            ));
            continue;
          }

          cancellationToken.throwIfCancelled();
          await _publish(
            runId,
            onProgress,
            VideoSourceScrapeProgress(
              phase: VideoSourceScrapePhase.applying,
              sourceId: source.id,
              sourceLabel: source.label,
              currentWorkTitle: localWork.title,
              current: index,
              total: works.length,
            ),
          );
          final PersistedVideoMetadata persisted = await _store.apply(
            localWork,
            metadata,
            seasonEpisodesAuthoritative: resolved.seasonEpisodesAuthoritative,
          );

          cancellationToken.throwIfCancelled();
          await _publish(
            runId,
            onProgress,
            VideoSourceScrapeProgress(
              phase: VideoSourceScrapePhase.writingSidecars,
              sourceId: source.id,
              sourceLabel: source.label,
              currentWorkTitle: localWork.title,
              current: index,
              total: works.length,
            ),
          );
          final _SidecarOutcome sidecars = await _writeSidecars(
            source: source,
            runId: runId,
            localWork: localWork,
            metadata: metadata,
            persisted: persisted,
            knownSourcePaths: knownSourcePaths,
            settings: settings,
            cancellationToken: cancellationToken,
          );
          nfoWritten += sidecars.nfoWritten;
          imagesWritten += sidecars.imagesWritten;
          protectedArtifacts += sidecars.protectedArtifacts;
          unchangedArtifacts += sidecars.unchangedArtifacts;
          warnings.addAll(sidecars.warnings);
          errors.addAll(sidecars.errors);
          succeeded++;
        } on VideoSourceScrapeCancelled {
          rethrow;
        } catch (error) {
          failed++;
          errors.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: error.toString(),
          ));
        } finally {
          await _updateRunCounts(
            runId,
            processedWorks: index + 1,
            succeededWorks: succeeded,
            failedWorks: failed,
            pendingConfirmations: pending,
          );
        }
      }

      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        totalWorks: works.length,
        succeededWorks: succeeded,
        failedWorks: failed,
        pendingConfirmations: pending,
        nfoWritten: nfoWritten,
        imagesWritten: imagesWritten,
        protectedArtifacts: protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts,
        warnings: List<SourceScrapeIssue>.unmodifiable(warnings),
        errors: List<SourceScrapeIssue>.unmodifiable(errors),
      );
      cancellationToken.throwIfCancelled();
      await _finishRun(runId, status: 'completed', report: report);
      return report;
    } on VideoSourceScrapeCancelled {
      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        totalWorks: works.length,
        succeededWorks: succeeded,
        failedWorks: failed,
        pendingConfirmations: pending,
        nfoWritten: nfoWritten,
        imagesWritten: imagesWritten,
        protectedArtifacts: protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts,
        warnings: warnings,
        errors: errors,
        cancelled: true,
      );
      final String status =
          _interruptedRunIds.contains(runId) ? 'interrupted' : 'cancelled';
      await _finishRun(runId, status: status, report: report);
      rethrow;
    } catch (error) {
      final SourceScrapeReport report = SourceScrapeReport(
        sourceIds: <int>[source.id],
        totalWorks: works.length,
        succeededWorks: succeeded,
        failedWorks: failed + 1,
        pendingConfirmations: pending,
        nfoWritten: nfoWritten,
        imagesWritten: imagesWritten,
        protectedArtifacts: protectedArtifacts,
        unchangedArtifacts: unchangedArtifacts,
        warnings: warnings,
        errors: <SourceScrapeIssue>[
          ...errors,
          SourceScrapeIssue(workTitle: source.label, message: error.toString()),
        ],
      );
      await _finishRun(
        runId,
        status: 'failed',
        report: report,
        lastError: error.toString(),
      );
      rethrow;
    } finally {
      if (_activeRunId == runId) _activeRunId = null;
      _interruptedRunIds.remove(runId);
    }
  }

  Future<_ResolvedWork> _resolveWork(
    VideoSourceScrapeWork localWork,
    VideoMetadataProviderKind selectedProvider,
    List<SourceScrapeIssue> warnings, {
    required Map<String, VideoMetadataWork> resolvedWorkCache,
    required Map<String, bool> authoritativeSeasonEpisodesCache,
    required bool fanartEnabled,
    required SourceLibraryRow source,
    required VideoSourceScrapeConfirmationCallback? onConfirmation,
  }) async {
    final String cacheKey = localWork.stableKey;
    final VideoMetadataWork? cached = resolvedWorkCache[cacheKey];
    if (cached != null) {
      return _ResolvedWork(
        metadata: cached,
        seasonEpisodesAuthoritative:
            authoritativeSeasonEpisodesCache[cacheKey] ?? false,
      );
    }

    final VideoNameInfo parsed =
        parseVideoFilename(p.basename(localWork.members.first.videoPath));
    final int? seasonNumber = _parsedSeason(localWork, parsed);
    final VideoMetadataMediaKind kind =
        localWork.isEpisodic || parsed.episode != null
            ? VideoMetadataMediaKind.tv
            : VideoMetadataMediaKind.movie;
    final VideoMetadataWork? nfo = await VideoNfoReader(
      generatedArtifactChecker:
          DatabaseSidecarGeneratedArtifactChecker(database),
    ).readForPaths(
      sourceRoot: source.rootPath,
      fallbackTitle: localWork.title,
      videoPaths: <String>[
        for (final VideoBookRow member in localWork.members) member.videoPath,
      ],
    );
    final List<String> candidates = <String>[
      if (nfo != null) nfo.title,
      ..._titleCandidates(localWork, parsed),
    ];
    final VideoMetadataLookup? storedLookup =
        await _store.confirmedLookup(localWork);
    final VideoMetadataResolution resolution = await VideoMetadataResolver(
      registry: registry,
    ).resolve(VideoMetadataResolveRequest(
      selectedProvider: selectedProvider,
      mediaKind: kind,
      titleCandidates: candidates,
      year: nfo?.year ?? _parsedYear(localWork),
      seasonNumber: seasonNumber,
      episodeCount: localWork.isEpisodic ? localWork.members.length : null,
      confirmedLookup: storedLookup ?? _lookupForNfo(nfo),
      identityHints: <String>[
        for (final VideoBookRow member in localWork.members) member.videoPath,
      ],
    ));
    VideoMetadataWork? resolvedWork = resolution.work;
    VideoMetadataLookup? resolvedLookup = resolution.lookup;
    if (resolution.status == VideoMetadataResolutionStatus.ambiguous) {
      final List<VideoSourceScrapeConfirmationCandidate> options =
          <VideoSourceScrapeConfirmationCandidate>[
        for (final VideoMetadataWork candidate in resolution.candidates)
          if (_lookupForCandidate(candidate, selectedProvider)
              case final VideoMetadataLookup lookup)
            VideoSourceScrapeConfirmationCandidate(
              lookup: lookup,
              work: candidate,
            ),
      ];
      if (onConfirmation == null || options.isEmpty) {
        return _ResolvedWork(pending: true, reason: resolution.reason);
      }
      final VideoSourceScrapeConfirmationCandidate? selected =
          await onConfirmation(VideoSourceScrapeConfirmation(
        sourceId: source.id,
        sourceLabel: source.label,
        localWorkTitle: localWork.title,
        candidates: options,
      ));
      if (selected == null) {
        return _ResolvedWork(pending: true, reason: resolution.reason);
      }
      resolvedWork = selected.work;
      resolvedLookup = selected.lookup;
    }
    if ((resolvedWork == null || resolvedLookup == null) && nfo != null) {
      resolvedWorkCache[cacheKey] = nfo;
      authoritativeSeasonEpisodesCache[cacheKey] = nfo.seasons.isNotEmpty;
      return _ResolvedWork(
        metadata: nfo,
        seasonEpisodesAuthoritative: nfo.seasons.isNotEmpty,
      );
    }
    if (resolvedWork == null || resolvedLookup == null) {
      return _ResolvedWork(reason: resolution.reason);
    }

    final _HydratedWork primaryHydration = await _hydrateWork(
      resolvedWork,
      resolvedLookup,
      warnings,
      localWork.title,
    );
    VideoMetadataWork metadata = primaryHydration.metadata;
    if (metadata.episodeGroupId == null &&
        resolvedLookup.episodeGroupId != null) {
      metadata = metadata.copyWith(
        episodeGroupId: resolvedLookup.episodeGroupId,
      );
    }
    bool seasonEpisodesAuthoritative = primaryHydration.complete;
    if (metadata.provider != VideoMetadataProviderKind.tmdb) {
      metadata = remapStandaloneVideoMetadataSeason(
        metadata,
        seasonNumber,
      );
      final _TmdbSupplementResult tmdb = await _tmdbSupplement(
        metadata,
        candidates,
        seasonNumber,
        warnings,
        localWork.title,
      );
      metadata = supplementVideoMetadataWithTmdb(metadata, tmdb.metadata);
      seasonEpisodesAuthoritative = tmdb.complete;
    }
    metadata = await _mergeImages(
      metadata,
      warnings,
      localWork.title,
      fanartEnabled: fanartEnabled,
    );
    if (nfo != null) metadata = mergeNfoAuthority(nfo, metadata);
    resolvedWorkCache[cacheKey] = metadata;
    authoritativeSeasonEpisodesCache[cacheKey] = seasonEpisodesAuthoritative;
    return _ResolvedWork(
      metadata: metadata,
      seasonEpisodesAuthoritative: seasonEpisodesAuthoritative,
    );
  }

  static VideoMetadataLookup? _lookupForNfo(VideoMetadataWork? nfo) {
    if (nfo == null) return null;
    for (final VideoMetadataId id in nfo.ids) {
      final VideoMetadataProviderKind? provider =
          VideoMetadataProviderKind.values.asNameMap()[id.type];
      if (provider == null || provider == VideoMetadataProviderKind.fanart) {
        continue;
      }
      return VideoMetadataLookup(
        provider: provider,
        externalId: id.value,
        mediaKind: nfo.kind,
        episodeGroupId: nfo.episodeGroupId,
      );
    }
    return null;
  }

  Future<_HydratedWork> _hydrateWork(
    VideoMetadataWork work,
    VideoMetadataLookup lookup,
    List<SourceScrapeIssue> warnings,
    String localTitle,
  ) async {
    final VideoMetadataProvider? provider = registry.provider(lookup.provider);
    if (provider == null) {
      return _HydratedWork(metadata: work, complete: false);
    }
    bool complete = true;
    List<VideoMetadataExtra> extras = work.extras;
    try {
      final List<VideoMetadataExtra> fetched = provider
              is VideoMetadataExtrasProvider
          ? await (provider as VideoMetadataExtrasProvider).fetchExtras(lookup)
          : const <VideoMetadataExtra>[];
      if (fetched.isNotEmpty) extras = fetched;
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: '预告片与花絮抓取失败，作品资料仍已保留：$error',
      ));
    }
    if (work.kind == VideoMetadataMediaKind.movie) {
      return _HydratedWork(
        metadata: work.copyWith(extras: extras),
        complete: true,
      );
    }
    List<VideoMetadataSeason> seasons = work.seasons;
    try {
      final List<VideoMetadataSeason> fetched =
          await provider.fetchSeasons(lookup);
      if (fetched.isNotEmpty) seasons = fetched;
    } catch (error) {
      complete = false;
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: '季资料抓取失败，保留作品摘要：$error',
      ));
    }
    final List<VideoMetadataSeason> hydrated = <VideoMetadataSeason>[];
    for (final VideoMetadataSeason season in seasons) {
      List<VideoMetadataEpisode> episodes = season.episodes;
      try {
        final List<VideoMetadataEpisode> fetched = await provider.fetchEpisodes(
          lookup,
          seasonNumber: season.seasonNumber,
        );
        if (fetched.isNotEmpty) episodes = fetched;
      } catch (error) {
        complete = false;
        warnings.add(SourceScrapeIssue(
          workTitle: localTitle,
          message: '第 ${season.seasonNumber} 季分集资料抓取失败：$error',
        ));
      }
      hydrated.add(season.copyWith(
        episodes: episodes,
        episodeCount: season.episodeCount ?? episodes.length,
      ));
    }
    return _HydratedWork(
      metadata: work.copyWith(seasons: hydrated, extras: extras),
      complete: complete,
    );
  }

  Future<_TmdbSupplementResult> _tmdbSupplement(
    VideoMetadataWork primary,
    List<String> titles,
    int? seasonNumber,
    List<SourceScrapeIssue> warnings,
    String localTitle,
  ) async {
    final VideoMetadataProvider? tmdb =
        registry.provider(VideoMetadataProviderKind.tmdb);
    if (tmdb == null || !tmdb.isAvailable) {
      return const _TmdbSupplementResult();
    }
    VideoMetadataLookup? lookup;
    for (final VideoMetadataId id in primary.ids) {
      if (id.type.toLowerCase() == 'tmdb') {
        lookup = VideoMetadataLookup(
          provider: VideoMetadataProviderKind.tmdb,
          externalId: id.value,
          mediaKind: primary.kind,
          episodeGroupId: primary.episodeGroupId,
        );
        break;
      }
    }
    VideoMetadataWork? work;
    try {
      if (lookup != null) {
        work = await tmdb.fetchWork(lookup);
      } else {
        final VideoMetadataResolution resolution = await VideoMetadataResolver(
          registry: registry,
        ).resolve(VideoMetadataResolveRequest(
          selectedProvider: VideoMetadataProviderKind.tmdb,
          mediaKind: primary.kind,
          titleCandidates: <String>[primary.title, ...titles],
          year: primary.year,
          seasonNumber: seasonNumber,
        ));
        if (resolution.status == VideoMetadataResolutionStatus.matched) {
          work = resolution.work;
          lookup = resolution.lookup;
        }
      }
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'TMDB 规范身份补充失败，主源资料仍已保留：$error',
      ));
      return const _TmdbSupplementResult();
    }
    if (work == null || lookup == null) {
      return const _TmdbSupplementResult();
    }
    try {
      final _HydratedWork hydrated =
          await _hydrateWork(work, lookup, warnings, localTitle);
      return _TmdbSupplementResult(
        metadata: hydrated.metadata,
        complete: hydrated.complete,
      );
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'TMDB 季集骨架补充失败，主源资料仍已保留：$error',
      ));
      return _TmdbSupplementResult(metadata: work);
    }
  }

  Future<VideoMetadataWork> _mergeImages(
    VideoMetadataWork metadata,
    List<SourceScrapeIssue> warnings,
    String localTitle, {
    required bool fanartEnabled,
  }) async {
    List<VideoMetadataImage> fanart = const <VideoMetadataImage>[];
    if (fanartEnabled && fanartProvider.isAvailable) {
      try {
        fanart = await fanartProvider.fetchImages(metadata);
      } catch (error) {
        warnings.add(SourceScrapeIssue(
          workTitle: localTitle,
          message: 'Fanart 图片补充失败：$error',
        ));
      }
    }
    final List<VideoMetadataImage> primary = <VideoMetadataImage>[
      ...metadata.images,
      for (final VideoMetadataSeason season
          in metadata.seasons) ...<VideoMetadataImage>[
        ...season.images,
        for (final VideoMetadataEpisode episode in season.episodes)
          ...episode.images,
      ],
    ];
    final List<VideoMetadataImage> selected = selectVideoMetadataImages(
      primary: primary,
      fanart: fanart,
    );
    final List<VideoMetadataSeason> seasons = <VideoMetadataSeason>[
      for (final VideoMetadataSeason season in metadata.seasons)
        season.copyWith(
          images: selected
              .where((VideoMetadataImage image) =>
                  image.seasonNumber == season.seasonNumber &&
                  image.episodeNumber == null)
              .toList(),
          episodes: <VideoMetadataEpisode>[
            for (final VideoMetadataEpisode episode in season.episodes)
              episode.copyWith(
                images: selected
                    .where((VideoMetadataImage image) =>
                        image.seasonNumber == episode.seasonNumber &&
                        image.episodeNumber == episode.episodeNumber)
                    .toList(),
              ),
          ],
        ),
    ];
    return metadata.copyWith(
      images: selected
          .where((VideoMetadataImage image) =>
              image.seasonNumber == null && image.episodeNumber == null)
          .toList(),
      seasons: seasons,
    );
  }

  Future<_SidecarOutcome> _writeSidecars({
    required SourceLibraryRow source,
    required int runId,
    required VideoSourceScrapeWork localWork,
    required VideoMetadataWork metadata,
    required PersistedVideoMetadata persisted,
    required List<String> knownSourcePaths,
    required _EffectiveSourceSettings settings,
    required VideoSourceScrapeCancellationToken cancellationToken,
  }) async {
    if (!settings.writeNfo && !settings.writeImages) {
      return const _SidecarOutcome();
    }
    final List<SourceScrapeIssue> warnings = <SourceScrapeIssue>[];
    final List<SourceScrapeIssue> errors = <SourceScrapeIssue>[];
    final VideoSidecarLayout layout;
    if (metadata.kind == VideoMetadataMediaKind.movie) {
      layout = VideoSidecarTargetResolver.resolveMovie(
        sourceRoot: source.rootPath,
        videoPath: localWork.members.single.videoPath,
        knownSourceVideoPaths: knownSourcePaths,
      );
    } else {
      final List<VideoEpisodePath> members = <VideoEpisodePath>[];
      for (final VideoBookRow member in localWork.members) {
        final VideoNameInfo parsed =
            parseVideoFilename(p.basename(member.videoPath));
        if (parsed.episode == null) {
          warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            path: member.videoPath,
            message: '无法从文件名确定集号，跳过该分集 sidecar',
          ));
          continue;
        }
        members.add(VideoEpisodePath(
          path: member.videoPath,
          seasonNumber: parsed.season ?? 1,
          episodeNumber: parsed.episode!,
        ));
      }
      layout = VideoSidecarTargetResolver.resolveTv(
        sourceRoot: source.rootPath,
        members: members,
        knownSourceVideoPaths: knownSourcePaths,
      );
    }
    warnings.addAll(<SourceScrapeIssue>[
      for (final String warning in layout.warnings)
        SourceScrapeIssue(workTitle: localWork.title, message: warning),
    ]);

    final DatabaseSidecarArtifactStore artifacts = DatabaseSidecarArtifactStore(
      database: database,
      sourceId: source.id,
      runId: runId,
    );
    final VideoSidecarWriter writer = VideoSidecarWriter(
      sourceRoot: source.rootPath,
      artifactStore: artifacts,
    );
    final Map<String, _PlannedArtifact> planned = <String, _PlannedArtifact>{};

    void plan({
      required String path,
      required Uint8List bytes,
      required SidecarWritePolicy policy,
      required String kind,
      int? seasonId,
      int? episodeId,
      String? remoteUrl,
    }) {
      final _PlannedArtifact value = _PlannedArtifact(
        request: SidecarWriteRequest(
          targetPath: path,
          bytes: bytes,
          policy: policy,
          allowProtectedOverwrite: settings.allowExternalOverwrite,
        ),
        context: VideoSidecarArtifactContext(
          artifactKind: kind,
          writePolicy: policy.name,
          workId:
              seasonId == null && episodeId == null ? persisted.workId : null,
          seasonId: episodeId == null ? seasonId : null,
          episodeId: episodeId,
          fileSize: bytes.length,
          remoteUrl: remoteUrl,
        ),
      );
      planned[_pathKey(path)] = value;
      artifacts.register(path, value.context);
    }

    if (settings.writeNfo) {
      final SidecarWritePolicy policy = settings.nfoPolicy;
      if (layout.work case final VideoSidecarTarget target) {
        plan(
          path: target.nfoPath,
          bytes: VideoNfoBuilder.buildWork(metadata),
          policy: policy,
          kind: 'nfo',
        );
      }
      for (final VideoSidecarTarget target in layout.seasons) {
        final VideoMetadataSeason? season = metadata.seasons
            .where((VideoMetadataSeason value) =>
                value.seasonNumber == target.seasonNumber)
            .firstOrNull;
        if (season == null) continue;
        plan(
          path: target.nfoPath,
          bytes: VideoNfoBuilder.buildSeason(
            season,
            primaryProvider: metadata.provider,
          ),
          policy: policy,
          kind: 'nfo',
          seasonId: persisted.seasonIds[season.seasonNumber],
        );
      }
      for (final VideoSidecarTarget target in layout.episodes) {
        final VideoMetadataEpisode episode =
            _episode(metadata, target.seasonNumber!, target.episodeNumber!) ??
                VideoMetadataEpisode(
                  seasonNumber: target.seasonNumber!,
                  episodeNumber: target.episodeNumber!,
                  title: '',
                );
        plan(
          path: target.nfoPath,
          bytes: VideoNfoBuilder.buildEpisode(
            episode,
            primaryProvider: metadata.provider,
          ),
          policy: policy,
          kind: 'nfo',
          episodeId: persisted
              .episodeIds[(episode.seasonNumber, episode.episodeNumber)],
        );
      }
    }

    final Map<String, VideoMetadataDownloadedAsset> downloads =
        <String, VideoMetadataDownloadedAsset>{};
    if (settings.writeImages) {
      // 规范库可以保留多张 backdrop 供应用内轮播，但 MoviePilot/Kodi 的
      // sidecar 命名对同一层级和图种只有一个稳定槽位。只把排序后的首选图
      // 写到媒体目录，避免后续候选覆盖首选图或因扩展名不同留下冲突副本。
      final Set<String> plannedImageSlots = <String>{};
      for (final VideoMetadataImage image in _allImages(metadata)) {
        cancellationToken.throwIfCancelled();
        final List<VideoSidecarTarget> targets =
            _targetsForImage(layout, image);
        if (targets.isEmpty) continue;
        final String imageSlot = '${image.seasonNumber ?? 'work'}:'
            '${image.episodeNumber ?? 'work'}:${image.kind.name}';
        if (!plannedImageSlots.add(imageSlot)) continue;
        VideoMetadataDownloadedAsset asset;
        try {
          asset = downloads[image.url] ??=
              await assetDownloader.download(image.url);
        } catch (error) {
          errors.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: '图片下载失败：$error',
            path: image.url,
          ));
          continue;
        }
        for (final VideoSidecarTarget target in targets) {
          final int? seasonId = image.seasonNumber == null
              ? null
              : persisted.seasonIds[image.seasonNumber!];
          final int? episodeId = image.episodeNumber == null
              ? null
              : persisted
                  .episodeIds[(image.seasonNumber ?? 1, image.episodeNumber!)];
          for (final String path in target.imagePaths(
            image.kind,
            extension: asset.extension,
          )) {
            plan(
              path: path,
              bytes: asset.bytes,
              policy: settings.imagePolicy,
              kind: image.kind.name,
              seasonId: seasonId,
              episodeId: episodeId,
              remoteUrl: image.url,
            );
          }
        }
      }
    }

    cancellationToken.throwIfCancelled();
    final SidecarWriteSummary summary = await writer.writeAll(
      planned.values.map((_PlannedArtifact value) => value.request),
    );
    int nfoWritten = 0;
    int imagesWritten = 0;
    int protected = 0;
    final Map<String, String> localPathByUrl = <String, String>{};
    for (final SidecarWriteResult result in summary.results) {
      final _PlannedArtifact? artifact = planned[_pathKey(result.targetPath)];
      final VideoSidecarArtifactContext? context = artifact?.context;
      if (result.didWrite) {
        if (context?.artifactKind == 'nfo') {
          nfoWritten++;
        } else {
          imagesWritten++;
        }
      }
      if (result.status == SidecarWriteStatus.protectedExisting ||
          result.status == SidecarWriteStatus.protectedModified ||
          result.status == SidecarWriteStatus.skippedExisting) {
        protected++;
      }
      if ((result.didWrite || result.status == SidecarWriteStatus.unchanged) &&
          context?.remoteUrl != null) {
        localPathByUrl.putIfAbsent(
          context!.remoteUrl!,
          () => result.targetPath,
        );
      }
      if (result.isFailure || result.artifactStoreError != null) {
        errors.add(SourceScrapeIssue(
          workTitle: localWork.title,
          path: result.targetPath,
          message: result.message ?? result.error?.toString() ?? 'sidecar 写入失败',
        ));
      }
    }
    if (localPathByUrl.isNotEmpty) {
      await _store.updateCanonicalImagePaths(
        persisted: persisted,
        metadata: metadata,
        localPathByRemoteUrl: localPathByUrl,
      );
      await _writeLegacyImages(localWork, metadata, localPathByUrl);
    }
    return _SidecarOutcome(
      nfoWritten: nfoWritten,
      imagesWritten: imagesWritten,
      protectedArtifacts: protected,
      unchangedArtifacts: summary.unchangedCount,
      warnings: warnings,
      errors: errors,
    );
  }

  Future<void> _writeLegacyImages(
    VideoSourceScrapeWork localWork,
    VideoMetadataWork metadata,
    Map<String, String> localPathByUrl,
  ) async {
    final VideoMetadataImage? cover = metadata.images
        .where((VideoMetadataImage image) =>
            image.kind == VideoMetadataImageKind.cover &&
            localPathByUrl.containsKey(image.url))
        .firstOrNull;
    if (cover != null) {
      final String coverPath = localPathByUrl[cover.url]!;
      final DatabaseSidecarGeneratedArtifactChecker generated =
          DatabaseSidecarGeneratedArtifactChecker(database);
      if (localWork.collection case final MediaCollectionRow collection) {
        if (collection.coverPath == null ||
            await generated
                .isUnmodifiedGeneratedArtifact(collection.coverPath!)) {
          await database.updateMediaCollectionCoverPath(
              collection.id, coverPath);
        }
      } else {
        final VideoBookRow book = localWork.members.single;
        if (book.coverPath == null ||
            await generated.isUnmodifiedGeneratedArtifact(book.coverPath!)) {
          await database.updateVideoBookCover(book.bookUid, coverPath);
        }
      }
    }

    final List<MediaImagesCompanion> workImages = _legacyImageRows(
      metadata.images,
      localPathByUrl,
      collectionId: localWork.collection?.id,
      bookUid: localWork.collection == null
          ? localWork.members.single.bookUid
          : null,
    );
    if (workImages.isNotEmpty) {
      if (localWork.collection case final MediaCollectionRow collection) {
        await database.replaceMediaImagesForCollection(
            collection.id, workImages);
      } else {
        await database.replaceMediaImagesForBook(
          localWork.members.single.bookUid,
          workImages,
        );
      }
    }
    for (final VideoBookRow book in localWork.members) {
      final VideoNameInfo parsed =
          parseVideoFilename(p.basename(book.videoPath));
      if (parsed.episode == null) continue;
      final VideoMetadataEpisode? episode =
          _episode(metadata, parsed.season ?? 1, parsed.episode!);
      if (episode == null) continue;
      final List<MediaImagesCompanion> rows = _legacyImageRows(
        episode.images,
        localPathByUrl,
        bookUid: book.bookUid,
      );
      if (rows.isNotEmpty) {
        await database.replaceMediaImagesForBook(book.bookUid, rows);
      }
    }
  }

  static List<MediaImagesCompanion> _legacyImageRows(
    Iterable<VideoMetadataImage> images,
    Map<String, String> localPathByUrl, {
    int? collectionId,
    String? bookUid,
  }) {
    final Map<String, int> positions = <String, int>{};
    final List<MediaImagesCompanion> result = <MediaImagesCompanion>[];
    for (final VideoMetadataImage image in images) {
      final String? path = localPathByUrl[image.url];
      if (path == null || image.kind == VideoMetadataImageKind.cover) continue;
      final MediaImageKind? kind = switch (image.kind) {
        VideoMetadataImageKind.backdrop => MediaImageKind.backdrop,
        VideoMetadataImageKind.logo => MediaImageKind.logo,
        VideoMetadataImageKind.thumb ||
        VideoMetadataImageKind.landscape =>
          MediaImageKind.titleCard,
        _ => null,
      };
      if (kind == null) continue;
      final int position = positions.update(
        kind.dbValue,
        (int value) => value + 1,
        ifAbsent: () => 0,
      );
      if (kind != MediaImageKind.backdrop && position > 0) continue;
      result.add(MediaImagesCompanion.insert(
        collectionId: Value<int?>(collectionId),
        bookUid: Value<String?>(bookUid),
        kind: kind.dbValue,
        position: Value<int>(position),
        path: path,
        sourceUrl: Value<String?>(image.url),
      ));
    }
    return result;
  }

  static List<VideoSidecarTarget> _targetsForImage(
    VideoSidecarLayout layout,
    VideoMetadataImage image,
  ) {
    if (image.episodeNumber != null) {
      return layout.episodes
          .where((VideoSidecarTarget target) =>
              target.seasonNumber == (image.seasonNumber ?? 1) &&
              target.episodeNumber == image.episodeNumber)
          .toList();
    }
    if (image.seasonNumber != null) {
      return layout.seasons
          .where((VideoSidecarTarget target) =>
              target.seasonNumber == image.seasonNumber)
          .toList();
    }
    return layout.work == null
        ? const <VideoSidecarTarget>[]
        : <VideoSidecarTarget>[layout.work!];
  }

  static Iterable<VideoMetadataImage> _allImages(
    VideoMetadataWork work,
  ) sync* {
    yield* work.images;
    for (final VideoMetadataSeason season in work.seasons) {
      yield* season.images;
      for (final VideoMetadataEpisode episode in season.episodes) {
        yield* episode.images;
      }
    }
  }

  static VideoMetadataEpisode? _episode(
    VideoMetadataWork work,
    int seasonNumber,
    int episodeNumber,
  ) {
    for (final VideoMetadataSeason season in work.seasons) {
      if (season.seasonNumber != seasonNumber) continue;
      for (final VideoMetadataEpisode episode in season.episodes) {
        if (episode.episodeNumber == episodeNumber) return episode;
      }
    }
    return null;
  }

  static List<String> _titleCandidates(
    VideoSourceScrapeWork work,
    VideoNameInfo parsed,
  ) {
    final String path = work.members.first.videoPath;
    final List<String> rawValues = <String>[
      work.title,
      parsed.series,
      p.basename(p.dirname(path)),
      p.basename(p.dirname(p.dirname(path))),
    ];
    // MoviePilot MetaInfoPath 会分别解析文件名、父目录和祖父目录后再合并。
    // 原始目录名通常还带字幕组、全集范围、编码等块，直接拿它请求 provider 会
    // 得到零结果；清洗后的标题必须先进入候选，原值仅保留显式 ID 等兼容信息。
    final List<String> values = <String>[
      for (final String value in rawValues) ...<String>[
        FilenameParser.parse(value).title,
        value,
      ],
    ];
    final Set<String> seen = <String>{};
    return <String>[
      for (final String value in values)
        if (value.trim().isNotEmpty && seen.add(value.trim().toLowerCase()))
          value.trim(),
    ];
  }

  static int? _parsedSeason(
    VideoSourceScrapeWork work,
    VideoNameInfo filename,
  ) {
    if (filename.season != null) return filename.season;
    final String path = work.members.first.videoPath;
    for (final String directory in <String>[
      p.basename(p.dirname(path)),
      p.basename(p.dirname(p.dirname(path))),
    ]) {
      final int? season = FilenameParser.parse(directory).season;
      if (season != null) return season;
    }
    return null;
  }

  static int? _parsedYear(VideoSourceScrapeWork work) {
    final List<String> candidates = <String>[
      work.title,
      for (final VideoBookRow row in work.members) ...<String>[
        p.basenameWithoutExtension(row.videoPath),
        p.basename(p.dirname(row.videoPath)),
        p.basename(p.dirname(p.dirname(row.videoPath))),
      ],
    ];
    // 年份必须经过仓内唯一的 anitomy 式解析器。直接在整段路径上找 4 位数字会
    // 把 `[1920x1080]` 的 1920 当成年份，随后严格匹配会把真正的 2015 候选拒掉。
    // 逐候选解析还保留了文件名 > 父目录 > 祖父目录的确定优先级。
    for (final String candidate in candidates) {
      final int? year = FilenameParser.parse(candidate).year;
      if (year != null) return year;
    }
    return null;
  }

  static VideoMetadataLookup? _lookupForCandidate(
    VideoMetadataWork work,
    VideoMetadataProviderKind provider,
  ) {
    final VideoMetadataId? id = work.ids
        .where((VideoMetadataId value) =>
            value.type.toLowerCase() == provider.name &&
            value.value.trim().isNotEmpty)
        .firstOrNull;
    return id == null
        ? null
        : VideoMetadataLookup(
            provider: provider,
            externalId: id.value,
            mediaKind: work.kind,
            episodeGroupId: work.episodeGroupId,
          );
  }

  Future<void> _publish(
    int runId,
    VideoSourceScrapeProgressCallback callback,
    VideoSourceScrapeProgress progress, {
    int? totalWorks,
    int? processedWorks,
    int? succeededWorks,
    int? failedWorks,
    int? pendingConfirmations,
    String? currentWorkTitle,
  }) async {
    callback(progress);
    await database.updateVideoSourceScrapeRun(
      runId,
      VideoSourceScrapeRunsCompanion(
        phase: Value<String?>(progress.phase.name),
        totalWorks:
            totalWorks == null ? const Value<int>.absent() : Value(totalWorks),
        processedWorks: processedWorks == null
            ? const Value<int>.absent()
            : Value(processedWorks),
        succeededWorks: succeededWorks == null
            ? const Value<int>.absent()
            : Value(succeededWorks),
        failedWorks: failedWorks == null
            ? const Value<int>.absent()
            : Value(failedWorks),
        pendingConfirmations: pendingConfirmations == null
            ? const Value<int>.absent()
            : Value(pendingConfirmations),
        currentWorkTitle: currentWorkTitle == null
            ? const Value<String?>.absent()
            : Value<String?>(currentWorkTitle),
        updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  Future<void> _updateRunCounts(
    int runId, {
    required int processedWorks,
    required int succeededWorks,
    required int failedWorks,
    required int pendingConfirmations,
  }) =>
      database.updateVideoSourceScrapeRun(
        runId,
        VideoSourceScrapeRunsCompanion(
          processedWorks: Value<int>(processedWorks),
          succeededWorks: Value<int>(succeededWorks),
          failedWorks: Value<int>(failedWorks),
          pendingConfirmations: Value<int>(pendingConfirmations),
          updatedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<void> _finishRun(
    int runId, {
    required String status,
    required SourceScrapeReport report,
    String? lastError,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return database.updateVideoSourceScrapeRun(
      runId,
      VideoSourceScrapeRunsCompanion(
        status: Value<String>(status),
        phase: Value<String?>(status),
        totalWorks: Value<int>(report.totalWorks),
        processedWorks: Value<int>(
          report.succeededWorks +
              report.failedWorks +
              report.pendingConfirmations,
        ),
        succeededWorks: Value<int>(report.succeededWorks),
        failedWorks: Value<int>(report.failedWorks),
        pendingConfirmations: Value<int>(report.pendingConfirmations),
        summaryJson: Value<String?>(_reportJson(report)),
        lastError: Value<String?>(lastError),
        updatedAt: Value<int>(now),
        finishedAt: Value<int?>(now),
      ),
    );
  }

  static String _reportJson(SourceScrapeReport report) => jsonEncode(
        <String, Object?>{
          'sourceIds': report.sourceIds,
          'totalWorks': report.totalWorks,
          'succeededWorks': report.succeededWorks,
          'failedWorks': report.failedWorks,
          'pendingConfirmations': report.pendingConfirmations,
          'nfoWritten': report.nfoWritten,
          'imagesWritten': report.imagesWritten,
          'protectedArtifacts': report.protectedArtifacts,
          'unchangedArtifacts': report.unchangedArtifacts,
          'cancelled': report.cancelled,
          'warnings': <Map<String, Object?>>[
            for (final SourceScrapeIssue issue in report.warnings)
              <String, Object?>{
                'work': issue.workTitle,
                'message': issue.message,
                if (issue.path != null) 'path': issue.path,
              },
          ],
          'errors': <Map<String, Object?>>[
            for (final SourceScrapeIssue issue in report.errors)
              <String, Object?>{
                'work': issue.workTitle,
                'message': issue.message,
                if (issue.path != null) 'path': issue.path,
              },
          ],
        },
      );

  @override
  Future<void> markActiveRunInterrupted() async {
    final int? runId = _activeRunId;
    if (runId == null) return;
    _interruptedRunIds.add(runId);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await database.updateVideoSourceScrapeRun(
      runId,
      VideoSourceScrapeRunsCompanion(
        status: const Value<String>('interrupted'),
        phase: const Value<String?>('interrupted'),
        updatedAt: Value<int>(now),
        finishedAt: Value<int?>(now),
      ),
    );
  }

  void close() {
    if (_ownsRegistry) registry.close();
    if (_ownsFanartProvider) fanartProvider.close();
    if (_ownsAssetDownloader) assetDownloader.close();
  }

  static String _pathKey(String value) {
    final String normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

class _EffectiveSourceSettings {
  const _EffectiveSourceSettings({
    required this.enabled,
    required this.provider,
    required this.writeNfo,
    required this.writeImages,
    required this.fanartEnabled,
    required this.nfoPolicy,
    required this.imagePolicy,
    required this.allowExternalOverwrite,
  });

  factory _EffectiveSourceSettings.from(
    VideoSourceScrapeSettingRow? row,
    VideoSourceScrapeGlobalConfig config, {
    required bool allowProtectedOverwrite,
  }) {
    final VideoMetadataProviderKind provider = row?.providerOverride == null
        ? config.primaryProvider
        : parsePrimaryVideoMetadataProvider(row!.providerOverride);
    return _EffectiveSourceSettings(
      enabled: row?.enabled ?? true,
      provider: provider,
      writeNfo: row?.writeNfo ?? true,
      writeImages: row?.writeImages ?? true,
      fanartEnabled: row?.fanartEnabled ?? true,
      nfoPolicy: _policy(row?.nfoPolicy),
      imagePolicy: _policy(row?.imagePolicy),
      allowExternalOverwrite:
          (row?.allowExternalOverwrite ?? false) && allowProtectedOverwrite,
    );
  }

  final bool enabled;
  final VideoMetadataProviderKind provider;
  final bool writeNfo;
  final bool writeImages;
  final bool fanartEnabled;
  final SidecarWritePolicy nfoPolicy;
  final SidecarWritePolicy imagePolicy;
  final bool allowExternalOverwrite;

  static SidecarWritePolicy _policy(String? value) =>
      SidecarWritePolicy.values.asNameMap()[value] ??
      SidecarWritePolicy.missingOnly;
}

class _ResolvedWork {
  const _ResolvedWork({
    this.metadata,
    this.pending = false,
    this.reason,
    this.seasonEpisodesAuthoritative = false,
  });

  final VideoMetadataWork? metadata;
  final bool pending;
  final String? reason;
  final bool seasonEpisodesAuthoritative;
}

class _HydratedWork {
  const _HydratedWork({required this.metadata, required this.complete});

  final VideoMetadataWork metadata;
  final bool complete;
}

class _TmdbSupplementResult {
  const _TmdbSupplementResult({this.metadata, this.complete = false});

  final VideoMetadataWork? metadata;
  final bool complete;
}

class _PlannedArtifact {
  const _PlannedArtifact({required this.request, required this.context});

  final SidecarWriteRequest request;
  final VideoSidecarArtifactContext context;
}

class _SidecarOutcome {
  const _SidecarOutcome({
    this.nfoWritten = 0,
    this.imagesWritten = 0,
    this.protectedArtifacts = 0,
    this.unchangedArtifacts = 0,
    this.warnings = const <SourceScrapeIssue>[],
    this.errors = const <SourceScrapeIssue>[],
  });

  final int nfoWritten;
  final int imagesWritten;
  final int protectedArtifacts;
  final int unchangedArtifacts;
  final List<SourceScrapeIssue> warnings;
  final List<SourceScrapeIssue> errors;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
