/// 视频来源规范刮削协调器：按作品识别、抓取、写 v77/兼容投影并安全导出 NFO/图片。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/anidb_video_metadata_provider.dart';
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
import 'package:fushi/src/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/media/video/scraper/filename_parser.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

class VideoSourceScrapeCoordinator
    implements
        VideoSourceScrapeRunner,
        VideoSourceScrapeInterruptible,
        VideoSourceScrapeManualBinding {
  VideoSourceScrapeCoordinator({
    required this.database,
    required this.config,
    VideoMetadataProviderRegistry? registry,
    VideoMetadataAssetDownloader? assetDownloader,
    this.onWorkScraped,
  })  : registry = registry ?? _createRegistry(config),
        assetDownloader = assetDownloader ?? VideoMetadataAssetDownloader(),
        _ownsRegistry = registry == null,
        _ownsAssetDownloader = assetDownloader == null,
        _store = VideoMetadataDatabaseStore(database);

  final FushiDatabase database;
  final VideoSourceScrapeGlobalConfig config;
  final VideoMetadataProviderRegistry registry;
  final VideoMetadataAssetDownloader assetDownloader;
  final bool _ownsRegistry;
  final bool _ownsAssetDownloader;
  final VideoMetadataDatabaseStore _store;

  /// 一个作品刮完（规范数据已落库、sidecar 已写）后的通知。
  ///
  /// 刮削本身**不做**字幕：它是全仓唯一解析出规范身份（AniDB/TMDB id + 原名）
  /// 的地方，而字幕搜索的准确率几乎完全取决于身份准不准。把「谁需要字幕」这个
  /// 事实播出去，由消费方（AppModel → VideoSubtitleBackfillService）决定要不要
  /// 补、按什么偏好补——刮削协调器不该长出网络字幕依赖，也不该被字幕失败拖慢。
  ///
  /// 回调抛出的异常会被吞掉并记进本次 run 的 warnings，绝不让补字幕影响刮削结论。
  final Future<void> Function(VideoScrapedWorkNotice notice)? onWorkScraped;

  final Set<int> _interruptedRunIds = <int>{};
  int? _activeRunId;

  static VideoMetadataProviderRegistry _createRegistry(
    VideoSourceScrapeGlobalConfig config,
  ) =>
      VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        AniDbVideoMetadataProvider(
          clientName: config.anidbClientName,
          clientVersion: config.anidbClientVersion,
          language: config.locale,
        ),
        TmdbVideoMetadataProvider(
          apiKey: config.tmdbApiKey,
          language: config.locale,
        ),
      ]);

  /// 对刚完成下载导入的单个作品执行身份受控的刮削。
  ///
  /// [lookup] 来自发现页已确认的发现域身份。AniDB lookup 可直接作为规范身份；
  /// TMDB 等跨源 lookup 只能作为补充提示，主作品仍须经过 AniDB 的严格标题门控。
  /// provider hydration、规范数据库写入、NFO/图片 sidecar 与 run / artifact 审计
  /// 完整复用来源刮削管线。
  Future<SourceScrapeReport> scrapeImportedWork(
    VideoSourceScrapeWork work, {
    required VideoMetadataLookup lookup,
    VideoSourceScrapeCancellationToken? cancellationToken,
    VideoSourceScrapeProgressCallback? onProgress,
  }) =>
      scrapeSource(
        work.source,
        cancellationToken:
            cancellationToken ?? VideoSourceScrapeCancellationToken(),
        onProgress: onProgress ?? (_) {},
        plannedWorks: <VideoSourceScrapeWork>[work],
        confirmedLookups: <String, VideoMetadataLookup>{
          work.stableKey: lookup,
        },
        runScope: 'work',
      );

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    required SourceLibraryRow source,
    required String workTitle,
    required String query,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const <VideoSourceScrapeConfirmationCandidate>[];
    }
    final VideoSourceScrapeWork work = await _plannedWork(source, workTitle);
    final VideoMetadataProvider? provider =
        _manualSearchProvider(await _sourceProvider(source));
    if (provider == null) {
      return const <VideoSourceScrapeConfirmationCandidate>[];
    }
    final List<VideoMetadataWork> results = await provider.search(
      VideoMetadataSearchRequest(
        title: trimmed,
        mediaKind: _manualMediaKind(work),
      ),
    );
    return <VideoSourceScrapeConfirmationCandidate>[
      for (final VideoMetadataWork candidate in results)
        if (_lookupForCandidate(candidate, provider.providerKind)
            case final VideoMetadataLookup lookup)
          VideoSourceScrapeConfirmationCandidate(
            lookup: lookup,
            work: candidate,
          ),
    ];
  }

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    final VideoSourceScrapeWork work = await _plannedWork(source, workTitle);
    // 手动指定与下载导入后的身份受控刮削走同一入口；仅 AniDB lookup 可直接
    // 确认主身份，跨源 lookup 由下游降为提示。落库、sidecar、run 审计全复用。
    return scrapeSource(
      source,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
      plannedWorks: <VideoSourceScrapeWork>[work],
      confirmedLookups: <String, VideoMetadataLookup>{work.stableKey: lookup},
      runScope: 'work',
    );
  }

  Future<VideoSourceScrapeWork> _plannedWork(
    SourceLibraryRow source,
    String workTitle,
  ) async {
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(database).plan(source);
    for (final VideoSourceScrapeWork work in works) {
      if (work.title == workTitle) return work;
    }
    throw VideoSourceScrapeWorkNotFound(workTitle);
  }

  Future<VideoMetadataProviderKind> _sourceProvider(
    SourceLibraryRow source,
  ) async =>
      _EffectiveSourceSettings.from(
        await database.getVideoSourceScrapeSettings(source.id),
        config,
        allowProtectedOverwrite: false,
      ).provider;

  /// 手动搜索与自动识别共用严格单主源规则：只返回 selected provider；缺失或
  /// 不可用时 fail closed，补充/历史 provider 不得被提升为可绑定的规范身份源。
  VideoMetadataProvider? _manualSearchProvider(
    VideoMetadataProviderKind selected,
  ) {
    final VideoMetadataProvider? primary = registry.provider(selected);
    if (primary != null && primary.isAvailable) return primary;
    return null;
  }

  /// 剧集/电影形态由来源计划里的真实成员决定，与 [_resolveWork] 同一判据。
  VideoMetadataMediaKind _manualMediaKind(VideoSourceScrapeWork work) {
    final VideoNameInfo parsed =
        parseVideoFilename(p.basename(work.members.first.videoPath));
    return work.isEpisodic || parsed.episode != null
        ? VideoMetadataMediaKind.tv
        : VideoMetadataMediaKind.movie;
  }

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    Map<String, VideoMetadataLookup> confirmedLookups =
        const <String, VideoMetadataLookup>{},
    String runScope = 'source',
  }) {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterOperation();
    if (lease == null) {
      return Future<SourceScrapeReport>.error(
        StateError('视频刮削资料正在清理'),
      );
    }
    return _scrapeSourceUnlocked(
      source,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
      onConfirmation: onConfirmation,
      batchContext: batchContext,
      plannedWorks: plannedWorks,
      confirmedLookups: confirmedLookups,
      runScope: runScope,
    ).whenComplete(lease.release);
  }

  Future<SourceScrapeReport> _scrapeSourceUnlocked(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    Map<String, VideoMetadataLookup> confirmedLookups =
        const <String, VideoMetadataLookup>{},
    String runScope = 'source',
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
        scope: runScope,
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
      works =
          plannedWorks ?? await VideoSourceWorkPlanner(database).plan(source);
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

      // AniDB 规范主源缺失时 fail closed。即使 registry 里还有 TMDB 补充源，
      // 也不能让它接管身份；整批只给一条聚合、可操作的说明。
      final bool hasProvider =
          registry.provider(VideoMetadataProviderKind.anidb)?.isAvailable ??
              false;
      if (!hasProvider && works.isNotEmpty) {
        failed = works.length;
        errors.add(SourceScrapeIssue(
          workTitle: source.label,
          message: describeVideoScrapeFailure(
            VideoMetadataResolutionStatus.providerUnavailable,
            null,
          ),
        ));
      }

      for (int index = 0; hasProvider && index < works.length; index++) {
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
            confirmedLookup: confirmedLookups[localWork.stableKey],
            resolvedWorkCache: effectiveBatch.resolvedWorks,
            authoritativeSeasonEpisodesCache:
                effectiveBatch.authoritativeSeasonEpisodes,
            source: source,
            onConfirmation: onConfirmation,
          );
          if (resolved.pending) {
            pending++;
            warnings.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: describeVideoScrapeFailure(
                VideoMetadataResolutionStatus.ambiguous,
                resolved.reason,
              ),
            ));
            continue;
          }
          final VideoMetadataWork? metadata = resolved.metadata;
          if (metadata == null) {
            failed++;
            errors.add(SourceScrapeIssue(
              workTitle: localWork.title,
              message: describeVideoScrapeFailure(
                resolved.status,
                resolved.reason,
              ),
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
          // 播「这个作品刮完了」。放在 succeeded++ 之后：只有真正刮成功的作品
          // 才值得去补字幕，失败的连身份都不可信。
          final Future<void> Function(VideoScrapedWorkNotice)? notify =
              onWorkScraped;
          if (notify != null) {
            try {
              await notify(
                VideoScrapedWorkNotice(work: localWork, metadata: metadata),
              );
            } on VideoSourceScrapeCancelled {
              rethrow;
            } catch (error) {
              // 补字幕失败绝不影响刮削结论——它是刮削的下游增值，不是前置条件。
              warnings.add(SourceScrapeIssue(
                workTitle: localWork.title,
                message: '字幕补齐失败：$error',
              ));
            }
          }
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
    VideoMetadataLookup? confirmedLookup,
    required Map<String, VideoMetadataWork> resolvedWorkCache,
    required Map<String, bool> authoritativeSeasonEpisodesCache,
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
    final List<VideoMetadataLookup> storedLookups =
        await _store.lookupsForWork(localWork);
    final List<VideoMetadataLookup> identityHints = <VideoMetadataLookup>[
      if (confirmedLookup != null) confirmedLookup,
      ...storedLookups,
      ..._lookupsForNfo(nfo),
    ];
    final VideoMetadataLookup? canonicalLookup = _lookupForProvider(
      identityHints,
      VideoMetadataProviderKind.anidb,
    );
    final VideoMetadataLookup? tmdbLookupHint = _lookupForProvider(
      identityHints,
      VideoMetadataProviderKind.tmdb,
    );
    final VideoMetadataResolution resolution = await VideoMetadataResolver(
      registry: registry,
    ).resolve(VideoMetadataResolveRequest(
      selectedProvider: selectedProvider,
      mediaKind: kind,
      titleCandidates: candidates,
      year: nfo?.year ?? _parsedYear(localWork),
      seasonNumber: seasonNumber,
      episodeCount: localWork.isEpisodic ? localWork.members.length : null,
      confirmedLookup: canonicalLookup,
      identityHints: <String>[
        for (final VideoBookRow member in localWork.members) member.videoPath,
      ],
    ));
    VideoMetadataWork? resolvedWork = resolution.work;
    VideoMetadataLookup? resolvedLookup = resolution.lookup;
    if (resolution.status == VideoMetadataResolutionStatus.ambiguous) {
      // 候选身份按 resolver 明确返回的 provider 取 id；严格单源解析要求它与
      // selectedProvider 一致，保留显式字段可避免未来改动悄悄跨源。
      final VideoMetadataProviderKind candidateProvider =
          resolution.providerKind ?? selectedProvider;
      final List<VideoSourceScrapeConfirmationCandidate> options =
          <VideoSourceScrapeConfirmationCandidate>[
        for (final VideoMetadataWork candidate in resolution.candidates)
          if (_lookupForCandidate(candidate, candidateProvider)
              case final VideoMetadataLookup lookup)
            VideoSourceScrapeConfirmationCandidate(
              lookup: lookup,
              work: candidate,
            ),
      ];
      if (onConfirmation == null || options.isEmpty) {
        return _ResolvedWork(
          pending: true,
          reason: resolution.reason,
          status: resolution.status,
        );
      }
      final VideoSourceScrapeConfirmationCandidate? selected =
          await onConfirmation(VideoSourceScrapeConfirmation(
        sourceId: source.id,
        sourceLabel: source.label,
        localWorkTitle: localWork.title,
        candidates: options,
      ));
      if (selected == null) {
        return _ResolvedWork(
          pending: true,
          reason: resolution.reason,
          status: resolution.status,
        );
      }
      resolvedWork = selected.work;
      resolvedLookup = selected.lookup;
      if (selected.lookup.provider == VideoMetadataProviderKind.anidb &&
          selected.work.rawPayload?[
                  AniDbVideoMetadataProvider.catalogOnlyPayloadKey] ==
              true) {
        final VideoMetadataProvider? provider =
            registry.provider(selected.lookup.provider);
        try {
          resolvedWork =
              await provider?.fetchWork(selected.lookup) ?? selected.work;
        } catch (error) {
          warnings.add(SourceScrapeIssue(
            workTitle: localWork.title,
            message: 'AniDB 手工确认项详情抓取失败，已保留标题目录摘要：$error',
          ));
        }
      }
    }
    if (resolvedWork == null || resolvedLookup == null) {
      return _ResolvedWork(
        reason: resolution.reason,
        status: resolution.status,
      );
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
      metadata = _preserveTmdbIdentity(metadata, tmdbLookupHint);
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
        lookupHint: tmdbLookupHint,
      );
      metadata = supplementVideoMetadataWithTmdb(metadata, tmdb.metadata);
    }
    metadata = _preserveHistoricalIdentities(
      metadata,
      <VideoMetadataLookup>[
        ...storedLookups,
        if (confirmedLookup != null) confirmedLookup,
      ],
    );
    metadata = _selectImages(metadata);
    if (nfo != null) metadata = mergeNfoAuthority(nfo, metadata);
    resolvedWorkCache[cacheKey] = metadata;
    authoritativeSeasonEpisodesCache[cacheKey] = seasonEpisodesAuthoritative;
    return _ResolvedWork(
      metadata: metadata,
      seasonEpisodesAuthoritative: seasonEpisodesAuthoritative,
    );
  }

  static List<VideoMetadataLookup> _lookupsForNfo(VideoMetadataWork? nfo) {
    if (nfo == null) return const <VideoMetadataLookup>[];
    final List<VideoMetadataId> ids = <VideoMetadataId>[
      ...nfo.ids.where((VideoMetadataId id) => id.isDefault),
      ...nfo.ids.where((VideoMetadataId id) => !id.isDefault),
    ];
    return <VideoMetadataLookup>[
      for (final VideoMetadataId id in ids)
        if (VideoMetadataProviderKind.values.asNameMap()[id.type]
            case final VideoMetadataProviderKind provider)
          VideoMetadataLookup(
            provider: provider,
            externalId: id.value,
            mediaKind: nfo.kind,
            episodeGroupId: nfo.episodeGroupId,
          ),
    ];
  }

  static VideoMetadataLookup? _lookupForProvider(
    Iterable<VideoMetadataLookup> lookups,
    VideoMetadataProviderKind provider,
  ) {
    for (final VideoMetadataLookup lookup in lookups) {
      if (lookup.provider == provider) return lookup;
    }
    return null;
  }

  static VideoMetadataWork _preserveTmdbIdentity(
    VideoMetadataWork primary,
    VideoMetadataLookup? persisted,
  ) {
    if (persisted == null ||
        persisted.provider != VideoMetadataProviderKind.tmdb ||
        persisted.mediaKind != primary.kind) {
      return primary;
    }
    final VideoMetadataId? current = primary.ids
        .where(
          (VideoMetadataId id) => id.type.trim().toLowerCase() == 'tmdb',
        )
        .firstOrNull;
    if (current != null && current.value.trim() != persisted.externalId) {
      // A fresh AniDB cross-reference explicitly changed. Do not attach the
      // episode group belonging to the old TMDB identity.
      return primary;
    }
    return primary.copyWith(
      ids: current == null
          ? <VideoMetadataId>[
              ...primary.ids,
              VideoMetadataId(type: 'tmdb', value: persisted.externalId),
            ]
          : primary.ids,
      episodeGroupId: primary.episodeGroupId ?? persisted.episodeGroupId,
    );
  }

  static VideoMetadataWork _preserveHistoricalIdentities(
    VideoMetadataWork primary,
    Iterable<VideoMetadataLookup> persisted,
  ) {
    final List<VideoMetadataId> ids = <VideoMetadataId>[...primary.ids];
    final Set<String> keys = <String>{
      for (final VideoMetadataId id in ids)
        '${id.type.trim().toLowerCase()}\u0000${id.value.trim()}',
    };
    for (final VideoMetadataLookup lookup in persisted) {
      if (lookup.provider == VideoMetadataProviderKind.local ||
          lookup.provider == VideoMetadataProviderKind.anidb ||
          lookup.provider == VideoMetadataProviderKind.tmdb) {
        continue;
      }
      final String value = lookup.externalId.trim();
      final String key = '${lookup.provider.name}\u0000$value';
      if (value.isEmpty || !keys.add(key)) continue;
      // Retired providers remain inert database cross references only. They
      // are never added to the resolver registry or contacted over network.
      ids.add(VideoMetadataId(type: lookup.provider.name, value: value));
    }
    return ids.length == primary.ids.length
        ? primary
        : primary.copyWith(ids: ids);
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
    if (provider.providerKind == VideoMetadataProviderKind.anidb &&
        work.rawPayload?[AniDbVideoMetadataProvider.catalogOnlyPayloadKey] ==
            true) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'AniDB HTTP 详情不可用，已保留标题目录摘要且不会把分集标记为完整。',
      ));
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
    String localTitle, {
    VideoMetadataLookup? lookupHint,
  }) async {
    final VideoMetadataProvider? tmdb =
        registry.provider(VideoMetadataProviderKind.tmdb);
    if (tmdb == null || !tmdb.isAvailable) {
      return const _TmdbSupplementResult();
    }
    final bool incompatibleHint =
        lookupHint != null && lookupHint.mediaKind != primary.kind;
    VideoMetadataLookup? lookup = incompatibleHint ? null : lookupHint;
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
    if (lookup == null && incompatibleHint) {
      // A persisted/NFO TMDB id belongs to the other TMDB namespace. Do not
      // coerce movie ids into /tv/{id} (or vice versa), and do not silently
      // replace an explicit-but-incompatible binding with a title search.
      return const _TmdbSupplementResult();
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
      return _TmdbSupplementResult(metadata: hydrated.metadata);
    } catch (error) {
      warnings.add(SourceScrapeIssue(
        workTitle: localTitle,
        message: 'TMDB 季集骨架补充失败，主源资料仍已保留：$error',
      ));
      return _TmdbSupplementResult(metadata: work);
    }
  }

  VideoMetadataWork _selectImages(VideoMetadataWork metadata) {
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
      await VideoCoverMutationGate.runExclusive(() async {
        if (localWork.collection case final MediaCollectionRow collection) {
          final MediaCollectionRow? current =
              await database.getMediaCollectionById(collection.id);
          if (current != null &&
              (current.coverPath == null ||
                  await generated.isUnmodifiedGeneratedArtifact(
                    current.coverPath!,
                  ))) {
            await database.updateMediaCollectionCoverPath(
              collection.id,
              coverPath,
            );
          }
        } else {
          final VideoBookRow planned = localWork.members.single;
          final VideoBookRow? current =
              await database.getVideoBookByBookUid(planned.bookUid);
          if (current != null &&
              (current.coverPath == null ||
                  await generated.isUnmodifiedGeneratedArtifact(
                    current.coverPath!,
                  ))) {
            await database.updateVideoBookCover(planned.bookUid, coverPath);
          }
        }
      });
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

  static String _reportJson(SourceScrapeReport report) =>
      encodeSourceScrapeReport(report);

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
    required this.nfoPolicy,
    required this.imagePolicy,
    required this.allowExternalOverwrite,
  });

  factory _EffectiveSourceSettings.from(
    VideoSourceScrapeSettingRow? row,
    VideoSourceScrapeGlobalConfig config, {
    required bool allowProtectedOverwrite,
  }) {
    return _EffectiveSourceSettings(
      enabled: row?.enabled ?? true,
      // provider_override 仅作历史数据库兼容；AniDB 始终拥有作品与分集身份。
      provider: VideoMetadataProviderKind.anidb,
      writeNfo: row?.writeNfo ?? true,
      writeImages: row?.writeImages ?? true,
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
    this.status,
    this.seasonEpisodesAuthoritative = false,
  });

  final VideoMetadataWork? metadata;
  final bool pending;
  final String? reason;

  /// 失败分类。以前只往上传一个英文 `reason` 字符串，UI 因此既分不清「源没配」
  /// 和「没匹配上」，也无法把文案翻成中文；这里把 resolver 的结构化状态保留下来。
  final VideoMetadataResolutionStatus? status;
  final bool seasonEpisodesAuthoritative;
}

/// 把 resolver 的结构化失败状态翻成用户能看懂、能照着做的中文说明。
///
/// [fallback] 是 resolver 的英文诊断串，只在状态缺失时兜底。
String describeVideoScrapeFailure(
  VideoMetadataResolutionStatus? status,
  String? fallback,
) =>
    switch (status) {
      VideoMetadataResolutionStatus.providerUnavailable =>
        'AniDB 主资料源不可用：请检查标题目录缓存与网络。完整作品/分集详情另需配置'
            '已登记的 AniDB HTTP client name/version。',
      VideoMetadataResolutionStatus.notFound => '没有匹配到作品：标题、类型、年份或季号都没通过严格校验。'
          '可以改文件名/目录名，或在文件名里写明 anidbid=/tmdbid= 等明确身份。',
      VideoMetadataResolutionStatus.ambiguous => '匹配结果存在歧义，需要人工确认',
      VideoMetadataResolutionStatus.matched ||
      null =>
        fallback ?? '没有找到严格匹配的作品',
    };

class _HydratedWork {
  const _HydratedWork({required this.metadata, required this.complete});

  final VideoMetadataWork metadata;
  final bool complete;
}

class _TmdbSupplementResult {
  const _TmdbSupplementResult({this.metadata});

  final VideoMetadataWork? metadata;
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

/// 「一个作品刚刮完」的事实：本地是哪些视频 + 刮出来的规范身份。
///
/// 刻意只带这两样：消费方要什么（补字幕 / 推送通知 / 统计）自己从这两个对象里
/// 取，协调器不预先替它们裁剪。
class VideoScrapedWorkNotice {
  const VideoScrapedWorkNotice({required this.work, required this.metadata});

  /// 本地作品（`work.members` 是这次涉及的 `VideoBookRow`，可能多集）。
  final VideoSourceScrapeWork work;

  /// 刮出来的规范元数据（含 ids / seasons / episodes / runtimeMinutes）。
  final VideoMetadataWork metadata;
}
