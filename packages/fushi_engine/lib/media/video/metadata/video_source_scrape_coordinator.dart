/// 视频来源规范刮削协调器：按作品识别、抓取、写 v77/兼容投影并安全导出 NFO/图片。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:http/http.dart' as http;
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_asset_downloader.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_merge.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_nfo_builder.dart';
import 'package:fushi_engine/media/video/metadata/video_nfo_reader.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_target_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_writer.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/scraper/filename_parser.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
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
    this.primaryProvider = VideoMetadataProviderKind.mal,
    AnidbHashIdentityService? hashIdentityService,
    VideoMetadataAssetDownloader? assetDownloader,
    this.onWorkScraped,
  })  : registry = registry ?? _createRegistry(config),
        assetDownloader = assetDownloader ?? VideoMetadataAssetDownloader(),
        hashIdentityService = hashIdentityService ??
            AnidbHashIdentityService(
                enabled: config.hashEnabled, config: config.anidbUdpConfig),
        _ownsHashIdentityService = hashIdentityService == null,
        _ownsRegistry = registry == null,
        _ownsAssetDownloader = assetDownloader == null,
        _store = VideoMetadataDatabaseStore(database);

  final FushiDatabase database;
  final VideoSourceScrapeGlobalConfig config;
  final VideoMetadataProviderRegistry registry;
  final VideoMetadataProviderKind primaryProvider;
  final AnidbHashIdentityService hashIdentityService;
  final bool _ownsHashIdentityService;
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
        MalVideoMetadataProvider(),
        TmdbVideoMetadataProvider(
          apiKey: config.tmdbApiKey,
          language: config.locale,
        ),
      ]);

  /// 对刚完成下载导入的单个作品执行身份受控的刮削。
  ///
  /// [lookup] 来自发现页已确认的身份。MAL/TMDB lookup 锁定本次作品来源；
  /// 用户指定的身份失败时不回退到另一作品。
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
    String? workStableKey,
    required String query,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const <VideoSourceScrapeConfirmationCandidate>[];
    }
    // 作品可能已不在当前计划里（文件改名/移动/删除后标题漂移，BUG-1998）。
    // 搜索只需要「电影还是剧集」这一个参数：拿不到就双形态各搜一次再按身份
    // 去重合并，绝不让只读的候选搜索因为计划回查失败而整个抛异常。
    final VideoSourceScrapeWork? work = await _plannedWorkOrNull(
        source, workTitle,
        workStableKey: workStableKey);
    final List<VideoMetadataLookup> explicit = parseExplicitVideoMetadataIds(
      <String>[trimmed],
      fallbackMediaKind:
          work == null ? VideoMetadataMediaKind.tv : _manualMediaKind(work),
    );
    final bool identityInput = explicit.isNotEmpty ||
        trimmed.contains('://') ||
        RegExp(r'^(?:mal|myanimelist|tmdb|anidb|aid)\s*[:=]',
                caseSensitive: false)
            .hasMatch(trimmed);
    if (identityInput) {
      final VideoMetadataLookup? lookup =
          explicit.length == 1 ? explicit.single : null;
      if (lookup == null ||
          !(lookup.provider == primaryProvider ||
              (primaryProvider == VideoMetadataProviderKind.mal &&
                  lookup.provider == VideoMetadataProviderKind.tmdb)) ||
          !RegExp(r'^[0-9]+$').hasMatch(lookup.externalId) ||
          (int.tryParse(lookup.externalId) ?? 0) <= 0) {
        throw const FormatException('Invalid video metadata work ID');
      }
      if (trimmed.contains('://') &&
          !<String>{'http', 'https'}.contains(Uri.tryParse(trimmed)?.scheme)) {
        throw const FormatException('Invalid video metadata work URL');
      }
      final VideoMetadataProvider? provider =
          _manualSearchProvider(lookup.provider);
      if (provider == null) {
        return const <VideoSourceScrapeConfirmationCandidate>[];
      }
      final VideoMetadataWork? result = await provider.fetchWork(lookup);
      return <VideoSourceScrapeConfirmationCandidate>[
        if (result != null)
          VideoSourceScrapeConfirmationCandidate(
              lookup: lookup.provider == VideoMetadataProviderKind.mal
                  ? VideoMetadataLookup(
                      provider: lookup.provider,
                      externalId: lookup.externalId,
                      mediaKind: result.kind)
                  : lookup,
              work: result),
      ];
    }
    final List<VideoMetadataMediaKind> kinds = work == null
        ? const <VideoMetadataMediaKind>[
            VideoMetadataMediaKind.tv,
            VideoMetadataMediaKind.movie,
          ]
        : <VideoMetadataMediaKind>[_manualMediaKind(work)];
    final List<VideoSourceScrapeConfirmationCandidate> candidates =
        <VideoSourceScrapeConfirmationCandidate>[];
    final Set<String> seenLookups = <String>{};
    final VideoMetadataProviderKind selected = await _sourceProvider(source);
    final List<VideoMetadataProviderKind> chain = <VideoMetadataProviderKind>[
      selected,
      if (selected == VideoMetadataProviderKind.mal)
        VideoMetadataProviderKind.tmdb,
    ];
    for (final VideoMetadataProviderKind providerKind in chain) {
      final VideoMetadataProvider? provider =
          _manualSearchProvider(providerKind);
      if (provider == null) continue;
      try {
        for (final VideoMetadataMediaKind kind in kinds) {
          final List<VideoMetadataWork> results = await provider.search(
            VideoMetadataSearchRequest(title: trimmed, mediaKind: kind),
          );
          for (final VideoMetadataWork candidate in results) {
            if (_lookupForCandidate(candidate, provider.providerKind)
                case final VideoMetadataLookup lookup) {
              if (!seenLookups.add(
                  '${lookup.provider.name}:${lookup.mediaKind.name}:${lookup.externalId}')) {
                continue;
              }
              candidates.add(VideoSourceScrapeConfirmationCandidate(
                  lookup: lookup, work: candidate));
            }
          }
        }
      } catch (error) {
        if (!_isProviderFailure(error)) rethrow;
        // Any candidates already returned by MAL still require user choice.
        // Only a completely empty/unavailable primary search uses TMDB.
      }
      if (candidates.isNotEmpty) break;
    }
    return candidates;
  }

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    final VideoSourceScrapeWork work =
        await _plannedWork(source, workTitle, workStableKey: workStableKey);
    // 手动指定与下载导入共用身份受控刮削入口，保留用户选定的来源和作品 ID。
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
    String workTitle, {
    String? workStableKey,
  }) async =>
      await _plannedWorkOrNull(source, workTitle,
          workStableKey: workStableKey) ??
      (throw VideoSourceScrapeWorkNotFound(workTitle));

  Future<VideoSourceScrapeWork?> _plannedWorkOrNull(
    SourceLibraryRow source,
    String workTitle, {
    String? workStableKey,
  }) async {
    final List<VideoSourceScrapeWork> works =
        await VideoSourceWorkPlanner(database).plan(source);
    final List<VideoSourceScrapeWork> matching = works
        .where(
          (VideoSourceScrapeWork work) => workStableKey != null
              ? work.stableKey == workStableKey
              : work.title == workTitle,
        )
        .toList();
    // 历史记录只有标题，遇同名作品必须拒绝绑定，不能默选第一个。
    if (matching.length > 1) {
      throw VideoSourceScrapeWorkAmbiguous(workTitle);
    }
    return matching.singleOrNull;
  }

  Future<VideoMetadataProviderKind> _sourceProvider(
    SourceLibraryRow source,
  ) async =>
      _EffectiveSourceSettings.from(
        await database.getVideoSourceScrapeSettings(source.id),
        config,
        allowProtectedOverwrite: false,
        primaryProvider: primaryProvider,
      ).provider;

  /// 取一个已配置的来源，手动搜索由上层按 MAL → TMDB 顺序调用。
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
      primaryProvider: primaryProvider,
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

      final bool hasProvider =
          (registry.provider(settings.provider)?.isAvailable ?? false) ||
              (settings.provider == VideoMetadataProviderKind.mal &&
                  (registry
                          .provider(VideoMetadataProviderKind.tmdb)
                          ?.isAvailable ??
                      false));
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

      // AniDB 明确下发 banned 后整批停手。封禁按客户端 IP 记在服务端、是 endpoint
      // 级的，继续按 3s 一条往下走：每条都注定失败，且每条都在延长封禁。provider
      // 侧已经闩住不再发请求（见 AniDbVideoMetadataProvider.isBanned），这里负责把
      // 「剩下的没做」如实结账成一条可操作说明，而不是让用户对着 N 条一模一样的分
      // 集抓取失败去猜发生了什么。
      final AniDbVideoMetadataProvider? anidb =
          switch (registry.provider(VideoMetadataProviderKind.anidb)) {
        final AniDbVideoMetadataProvider provider => provider,
        _ => null,
      };
      int startedWorks = 0;

      for (int index = 0;
          hasProvider && anidb?.isBanned != true && index < works.length;
          index++) {
        startedWorks++;
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
            cancellationToken: cancellationToken,
            onHashProgress: (String path, int bytes, int totalBytes) =>
                onProgress(
              VideoSourceScrapeProgress(
                phase: VideoSourceScrapePhase.recognizing,
                sourceId: source.id,
                sourceLabel: source.label,
                currentWorkTitle: localWork.title,
                current: index,
                total: works.length,
                message:
                    'AniDB ED2K ${p.basename(path)}：$bytes / $totalBytes 字节',
              ),
            ),
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

      final Duration? banRemaining = anidb?.banRemaining;
      final int skippedByBan = works.length - startedWorks;
      if (banRemaining != null && hasProvider && skippedByBan > 0) {
        failed += skippedByBan;
        errors.add(SourceScrapeIssue(
          workTitle: source.label,
          message: 'AniDB 已封禁本客户端，本轮剩余 $skippedByBan 个作品全部跳过'
              '（约 ${banRemaining.inHours + 1} 小时后自动恢复）。'
              '封禁期间继续请求只会延长封禁。',
        ));
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
    required VideoSourceScrapeCancellationToken cancellationToken,
    required void Function(String, int, int) onHashProgress,
    required Map<String, VideoMetadataWork> resolvedWorkCache,
    required Map<String, bool> authoritativeSeasonEpisodesCache,
    required SourceLibraryRow source,
    required VideoSourceScrapeConfirmationCallback? onConfirmation,
  }) async {
    final String cacheKey = localWork.stableKey;
    final VideoMetadataWork? cached = resolvedWorkCache[cacheKey];
    if (cached != null && confirmedLookup == null) {
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
    VideoMetadataWork? nfo = await VideoNfoReader(
      generatedArtifactChecker:
          DatabaseSidecarGeneratedArtifactChecker(database),
    ).readForPaths(
      sourceRoot: source.rootPath,
      fallbackTitle: localWork.title,
      videoPaths: <String>[
        for (final VideoBookRow member in localWork.members) member.videoPath,
      ],
    );
    final List<VideoMetadataLookup> storedLookups =
        await _store.lookupsForWork(localWork);
    bool acceptsCanonical(VideoMetadataLookup lookup) =>
        lookup.provider == selectedProvider ||
        (selectedProvider == VideoMetadataProviderKind.mal &&
            lookup.provider == VideoMetadataProviderKind.tmdb);
    final VideoMetadataLookup? confirmedCanonical =
        confirmedLookup != null && acceptsCanonical(confirmedLookup)
            ? confirmedLookup
            : null;
    // The first persisted identity is the primary. A retired primary's TMDB
    // cross-reference must not silently become a new canonical binding.
    final VideoMetadataLookup? storedPrimary = storedLookups.firstOrNull;
    final bool retiredStoredIdentity =
        selectedProvider == VideoMetadataProviderKind.mal &&
            storedPrimary != null &&
            !acceptsCanonical(storedPrimary);
    final VideoMetadataLookup? storedCanonical =
        selectedProvider == VideoMetadataProviderKind.mal
            ? (storedPrimary != null && acceptsCanonical(storedPrimary)
                ? storedPrimary
                : null)
            : storedLookups.where(acceptsCanonical).firstOrNull;
    final List<VideoMetadataLookup> nfoLookups = _lookupsForNfo(nfo);
    final Set<String> defaultNfoSources = <String>{
      for (final VideoMetadataId id in nfo?.ids ?? <VideoMetadataId>[])
        if (id.isDefault) id.type,
    };
    final VideoMetadataLookup? nfoPrimary = nfoLookups
        .where((VideoMetadataLookup lookup) =>
            defaultNfoSources.contains(lookup.provider.name))
        .firstOrNull;
    final VideoMetadataLookup? nfoIdentityOwner =
        nfoPrimary ?? nfoLookups.firstOrNull;
    final bool retiredNfoIdentity =
        selectedProvider == VideoMetadataProviderKind.mal &&
            nfoIdentityOwner != null &&
            !acceptsCanonical(nfoIdentityOwner);
    final VideoMetadataLookup? nfoCanonical =
        selectedProvider == VideoMetadataProviderKind.mal
            ? (nfoPrimary != null && acceptsCanonical(nfoPrimary)
                ? nfoPrimary
                : null)
            : nfoLookups.where(acceptsCanonical).firstOrNull;
    final VideoMetadataLookup? storedSameSource = confirmedCanonical == null
        ? null
        : _lookupForProvider(storedLookups, confirmedCanonical.provider);
    final bool changedIdentity = confirmedCanonical != null &&
        storedLookups.isNotEmpty &&
        (storedSameSource == null ||
            !_sameLookup(confirmedCanonical, storedSameSource));
    final VideoMetadataLookup? nfoSameSource = confirmedCanonical == null
        ? null
        : _lookupForProvider(nfoLookups, confirmedCanonical.provider);
    final bool conflictingNfo = nfo != null &&
        confirmedCanonical != null &&
        (nfoSameSource != null
            ? !_sameLookup(confirmedCanonical, nfoSameSource)
            : changedIdentity ||
                nfoLookups.any((VideoMetadataLookup lookup) =>
                    lookup.provider == VideoMetadataProviderKind.mal ||
                    lookup.provider == VideoMetadataProviderKind.tmdb ||
                    lookup.provider == VideoMetadataProviderKind.anidb));
    if (conflictingNfo) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message:
              '本地 NFO 与本次确认的 ${confirmedCanonical.provider.name.toUpperCase()} 作品身份不一致，未应用其中的资料；原文件仍按已有写入保护策略保留。'));
      nfo = null;
    }
    if (retiredNfoIdentity && nfo != null) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message:
              '本地 NFO 的主身份来自旧资料源，需按当前主源重新识别；未沿用旧跨源关联或展示资料，原文件仍按已有写入保护策略保留。'));
      nfo = null;
    }
    final List<VideoMetadataLookup> reusableLookups =
        changedIdentity || retiredStoredIdentity
            ? const <VideoMetadataLookup>[]
            : storedLookups;
    final List<String> candidates = <String>[
      if (nfo != null) nfo.title,
      ..._titleCandidates(localWork, parsed),
    ];
    final List<VideoMetadataLookup> identityHints = <VideoMetadataLookup>[
      if (confirmedLookup != null) confirmedLookup,
      ...reusableLookups,
      ..._lookupsForNfo(nfo),
    ];
    final VideoMetadataLookup? canonicalLookup = confirmedCanonical ??
        storedCanonical ??
        (conflictingNfo || retiredNfoIdentity ? null : nfoCanonical);
    final VideoMetadataLookup? tmdbLookupHint =
        _lookupForProvider(identityHints, VideoMetadataProviderKind.tmdb);
    final List<String> pathHints = <String>[
      for (final VideoBookRow member in localWork.members) member.videoPath,
    ];
    final bool hasExplicitId =
        parseExplicitVideoMetadataIds(pathHints, fallbackMediaKind: kind)
            .isNotEmpty;
    final _HashWorkEvidence hashEvidence =
        canonicalLookup == null && !hasExplicitId
            ? await _identifyWork(
                localWork, warnings, cancellationToken, onHashProgress)
            : const _HashWorkEvidence();
    cancellationToken.throwIfCancelled();
    if (hashEvidence.conflicting) {
      return const _ResolvedWork(
          pending: true,
          status: VideoMetadataResolutionStatus.ambiguous,
          reason: 'AniDB 文件哈希识别结果属于不同作品，或 AniDB→MAL 映射不唯一；请拆分合集或手动确认作品。');
    }
    final VideoMetadataLookup? hashLookup = hashEvidence.malId == null
        ? null
        : VideoMetadataLookup(
            provider: VideoMetadataProviderKind.mal,
            externalId: '${hashEvidence.malId}',
            mediaKind: kind,
          );
    final List<String> searchTitles = <String>[
      if (hashEvidence.animeId != null)
        ...hashEvidence.titles
      else
        ...candidates,
    ];
    final VideoMetadataResolver resolver =
        VideoMetadataResolver(registry: registry);
    VideoMetadataResolution resolution =
        await resolver.resolve(VideoMetadataResolveRequest(
      selectedProvider: selectedProvider,
      mediaKind: kind,
      titleCandidates: searchTitles,
      year: nfo?.year ?? _parsedYear(localWork),
      seasonNumber: seasonNumber,
      episodeCount: localWork.isEpisodic ? localWork.members.length : null,
      confirmedLookup: canonicalLookup ?? hashLookup,
      identityHints: pathHints,
    ));
    if (canonicalLookup == null &&
        hashLookup != null &&
        resolution.status ==
            VideoMetadataResolutionStatus.providerUnavailable) {
      // A hash mapping is automatic evidence, not a user-locked MAL binding.
      // Only the unavailable mapped source may fall back to strict TMDB titles.
      resolution = await resolver.resolve(VideoMetadataResolveRequest(
        selectedProvider: VideoMetadataProviderKind.tmdb,
        mediaKind: kind,
        titleCandidates: searchTitles,
        year: nfo?.year ?? _parsedYear(localWork),
        seasonNumber: seasonNumber,
        episodeCount: localWork.isEpisodic ? localWork.members.length : null,
      ));
    }
    VideoMetadataWork? resolvedWork = resolution.work;
    VideoMetadataLookup? resolvedLookup = resolution.lookup;
    if (resolution.status == VideoMetadataResolutionStatus.ambiguous) {
      // 候选身份使用实际返回来源；TMDB 兜底结果必须保留 TMDB ID 命名空间。
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
    if (metadata.provider == VideoMetadataProviderKind.mal &&
        _hasIncompleteMalCredits(metadata)) {
      warnings.add(SourceScrapeIssue(
          workTitle: localWork.title,
          message: 'MAL 演职员资料抓取不完整，已保留作品身份和现有资料；将尝试严格匹配 TMDB 补充缺项。'));
    }
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
      final _TmdbSupplementResult tmdb =
          metadata.provider == VideoMetadataProviderKind.mal &&
                  !_needsTmdbSupplement(metadata, seasonEpisodesAuthoritative)
              ? const _TmdbSupplementResult()
              : await _tmdbSupplement(
                  metadata,
                  changedIdentity || conflictingNfo
                      ? <String>[metadata.title, ...metadata.aliases]
                      : candidates,
                  seasonNumber,
                  warnings,
                  localWork.title,
                  lookupHint: tmdbLookupHint,
                );
      metadata = supplementVideoMetadataWithTmdb(metadata, tmdb.metadata);
    }
    if (hashEvidence.animeId != null &&
        hashEvidence.malId != null &&
        metadata.provider == VideoMetadataProviderKind.mal &&
        _lookupForCandidate(metadata, VideoMetadataProviderKind.mal)
                ?.externalId ==
            '${hashEvidence.malId}') {
      metadata = metadata.copyWith(ids: <VideoMetadataId>[
        ...metadata.ids.where((VideoMetadataId id) => id.type != 'anidb'),
        VideoMetadataId(type: 'anidb', value: '${hashEvidence.animeId}'),
      ]);
    }
    metadata = _preserveHistoricalIdentities(
      metadata,
      <VideoMetadataLookup>[
        ...reusableLookups,
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

  Future<_HashWorkEvidence> _identifyWork(
    VideoSourceScrapeWork work,
    List<SourceScrapeIssue> warnings,
    VideoSourceScrapeCancellationToken token,
    void Function(String, int, int) onProgress,
  ) async {
    if (!hashIdentityService.enabled) return const _HashWorkEvidence();
    if (!hashIdentityService.isConfigured) {
      warnings.add(SourceScrapeIssue(
          workTitle: work.title,
          message:
              'AniDB 哈希识别未执行：哈希识别不可用，缺少账号或注册客户端配置。请填写用户名、密码及已注册的 client name/version；继续按标题刮削。'));
      return const _HashWorkEvidence();
    }
    final Set<int> animeIds = <int>{};
    final Set<int> malIds = <int>{};
    final Set<String> titles = <String>{};
    bool conflicting = false;
    for (final VideoBookRow member in work.members) {
      token.throwIfCancelled();
      final AnidbHashIdentityResult result =
          await hashIdentityService.identifyFile(
        member.videoPath,
        isCancelled: () => token.isCancelled,
        onProgress: (int bytes, int total) =>
            onProgress(member.videoPath, bytes, total),
      );
      token.throwIfCancelled();
      if (result.status == AnidbHashIdentityStatus.cancelled) {
        throw const VideoSourceScrapeCancelled();
      }
      final AnidbFileIdentity? identity = result.identity;
      if (result.status == AnidbHashIdentityStatus.matched &&
          identity != null) {
        animeIds.add(identity.animeId);
        if (result.confirmedMalId case final int malId) malIds.add(malId);
        conflicting = conflicting || (result.mapping?.isAmbiguous ?? false);
        titles.addAll(<String>[
          identity.romajiTitle,
          identity.kanjiTitle,
          identity.englishTitle
        ]
            .map((String title) => title.trim())
            .where((String title) => title.isNotEmpty));
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message: 'AniDB ED2K 文件识别成功：${p.basename(member.videoPath)}; '
                'hash=${result.matchedEd2k ?? result.hash?.ed2k}; fileId=${identity.fileId}; animeId=${identity.animeId}; '
                'episodeId=${identity.episodeId}; episodeNumber=${identity.episodeNumber}。'
                '${result.confirmedMalId == null ? '文件身份已确定，MAL 元数据映射未确定。' : 'MAL 作品映射=${result.confirmedMalId}。'}'
                'AniDB 原生集号仅记录，不推断 MAL 季集对应。'));
      } else if (result.status != AnidbHashIdentityStatus.disabled) {
        warnings.add(SourceScrapeIssue(
            workTitle: work.title,
            message:
                '${p.basename(member.videoPath)}：${_hashFailureReason(result)}'
                '继续严格标题识别。'));
      }
    }
    return _HashWorkEvidence(
      animeId: animeIds.length == 1 ? animeIds.single : null,
      malId: malIds.length == 1 ? malIds.single : null,
      titles: titles.toList(growable: false),
      conflicting: conflicting || animeIds.length > 1 || malIds.length > 1,
    );
  }

  static bool _sameLookup(
          VideoMetadataLookup first, VideoMetadataLookup second) =>
      first.provider == second.provider &&
      first.externalId == second.externalId &&
      first.mediaKind == second.mediaKind;

  static String _hashFailureReason(AnidbHashIdentityResult result) {
    if (result.status == AnidbHashIdentityStatus.notFound) {
      return 'ED2K 已计算，但 AniDB 未收录此文件哈希。';
    }
    if (result.error case final AnidbUdpException error) {
      return switch (error.reason) {
        AnidbUdpFailure.authentication => 'AniDB 登录失败，请检查用户名和密码。',
        AnidbUdpFailure.unavailable ||
        AnidbUdpFailure.clientOutdated ||
        AnidbUdpFailure.clientBanned =>
          'AniDB 客户端不可用，请核对注册的客户端名称与版本。',
        AnidbUdpFailure.network ||
        AnidbUdpFailure.timeout =>
          'AniDB UDP 连接失败，请检查 UDP 9000 网络与防火墙；普通 HTTP 代理不能代替 UDP 连接。',
        AnidbUdpFailure.banned ||
        AnidbUdpFailure.maintenance =>
          'AniDB 当前限流或维护，已暂停请求，请稍后重试。',
        _ => 'AniDB 未返回有效文件身份，请检查账号及客户端配置后重试。',
      };
    }
    return '无法完成 AniDB 文件识别，请确认文件可读且未被修改，并检查账号和网络配置。';
  }

  static bool _isProviderFailure(Object error) =>
      error is VideoMetadataProviderUnavailable ||
      error is VideoMetadataNetworkException ||
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is TlsException ||
      error is http.ClientException;

  static bool _hasIncompleteMalCredits(VideoMetadataWork work) {
    final Object? endpoints = work.rawPayload?[malIncompleteCreditEndpointsKey];
    return endpoints is List && endpoints.isNotEmpty;
  }

  static bool _needsTmdbSupplement(
          VideoMetadataWork work, bool episodesComplete) =>
      (work.plot?.trim().isEmpty ?? true) ||
      work.credits.isEmpty ||
      _hasIncompleteMalCredits(work) ||
      !work.images.any((VideoMetadataImage image) =>
          image.kind == VideoMetadataImageKind.cover) ||
      !work.images.any((VideoMetadataImage image) =>
          image.kind == VideoMetadataImageKind.backdrop) ||
      (work.kind == VideoMetadataMediaKind.tv &&
          (!episodesComplete || work.seasons.isEmpty));

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
          lookup.provider == VideoMetadataProviderKind.mal ||
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
    bool incompleteMalEpisodes = false;
    final bool isMal = provider.providerKind == VideoMetadataProviderKind.mal;
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
      if (isMal && fetched.isEmpty) incompleteMalEpisodes = true;
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
        if (isMal && fetched.isEmpty) incompleteMalEpisodes = true;
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
    if (isMal) {
      final Set<(int, int)> episodeKeys = <(int, int)>{};
      for (final VideoMetadataSeason season in hydrated) {
        final Set<int> seasonEpisodes = <int>{
          for (final VideoMetadataEpisode episode in season.episodes)
            if (episode.episodeNumber > 0 && episode.title.trim().isNotEmpty)
              episode.episodeNumber,
        };
        episodeKeys.addAll(seasonEpisodes
            .map((int episode) => (season.seasonNumber, episode)));
        if (seasonEpisodes.isEmpty ||
            (season.episodeCount != null &&
                seasonEpisodes.length < season.episodeCount!)) {
          incompleteMalEpisodes = true;
        }
      }
      if (hydrated.isEmpty ||
          episodeKeys.isEmpty ||
          (work.episodeCount != null &&
              episodeKeys.length < work.episodeCount!)) {
        incompleteMalEpisodes = true;
      }
      if (incompleteMalEpisodes) {
        complete = false;
        warnings.add(SourceScrapeIssue(
            workTitle: localTitle,
            message: 'MAL 季集资料不完整：实际取得 ${episodeKeys.length} 集'
                '${work.episodeCount == null ? '' : '，作品声明 ${work.episodeCount} 集'}。'
                '保留已有季集记录，并尝试 TMDB 补充；空响应或缺集不作为删除依据。'));
      }
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
    if (_ownsHashIdentityService) unawaited(hashIdentityService.close());
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
    VideoMetadataProviderKind primaryProvider = VideoMetadataProviderKind.mal,
  }) {
    return _EffectiveSourceSettings(
      enabled: row?.enabled ?? true,
      // 历史 provider_override 不改变生产 MAL 主源策略。
      provider: primaryProvider,
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
        '视频资料源不可用：请检查 MAL/Jikan 网络及 TMDB API 配置。${fallback == null ? '' : ' $fallback'}',
      VideoMetadataResolutionStatus.notFound => '没有匹配到作品：标题、类型、年份或季号都没通过严格校验。'
          '可以改文件名/目录名，或在文件名里写明 mal=/tmdb:tv=/tmdb:movie= 等明确身份。',
      VideoMetadataResolutionStatus.ambiguous =>
        '匹配结果存在歧义，需要人工确认${fallback == null ? '' : '：$fallback'}',
      VideoMetadataResolutionStatus.matched ||
      null =>
        fallback ?? '没有找到严格匹配的作品',
    };

class _HashWorkEvidence {
  const _HashWorkEvidence(
      {this.animeId,
      this.malId,
      this.titles = const <String>[],
      this.conflicting = false});
  final int? animeId;
  final int? malId;
  final List<String> titles;
  final bool conflicting;
}

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
