import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// A backend torrent observed while importing one legacy JSON plan.
///
/// The importer deliberately does not know how credentials are stored or how a
/// backend is contacted. The composition root may provide [LegacyTorrentMatcher]
/// after it has opened the configured backend; this value contains only the
/// non-secret identity that is safe to persist in a durable job.
class LegacyTorrentBinding {
  const LegacyTorrentBinding({
    required this.torrentHash,
    required this.title,
    required this.category,
    required this.backendKind,
    required this.fingerprint,
    this.backendTaskId,
    this.backendProfileId,
    this.observedSavePath,
  });

  final String torrentHash;
  final String title;
  final String category;
  final String backendKind;
  final String fingerprint;
  final String? backendTaskId;
  final String? backendProfileId;
  final String? observedSavePath;
}

class LegacyTorrentProbe {
  const LegacyTorrentProbe({
    required this.torrentHash,
    required this.title,
    required this.category,
  });

  final String torrentHash;
  final String title;
  final String category;
}

typedef LegacyTorrentMatcher = Future<LegacyTorrentBinding?> Function(
  LegacyTorrentProbe probe,
);

/// Non-secret backend identity used by a migrated subscription. Legacy
/// subscription JSON did not persist a qB category or connection identity, so
/// the caller must supply both explicitly. Without this binding the migrated
/// subscription is retained but disabled with a needs-attention error.
class LegacySubscriptionBackendBinding {
  const LegacySubscriptionBackendBinding({
    required this.backendKind,
    required this.fingerprint,
    required this.category,
    this.backendProfileId,
  });

  final String backendKind;
  final String fingerprint;
  final String category;
  final String? backendProfileId;
}

typedef LegacySubscriptionBackendResolver
    = Future<LegacySubscriptionBackendBinding?> Function(
  AnimeDownloadSubscription subscription,
);

enum LegacyImportIssueKind {
  corruptFile,
  backendUnconfirmed,
  missingReference,
  databaseWrite,
  archiveFailure,
}

class LegacyImportIssue {
  const LegacyImportIssue({
    required this.kind,
    required this.fileName,
    required this.message,
  });

  final LegacyImportIssueKind kind;
  final String fileName;
  final String message;
}

class LegacyVideoDownloadImportReport {
  const LegacyVideoDownloadImportReport({
    required this.importedPlans,
    required this.importedSubscriptions,
    required this.importedSubscriptionItems,
    required this.alreadyImportedFiles,
    required this.archivedFiles,
    required this.quarantinedFiles,
    required this.issues,
  });

  final int importedPlans;
  final int importedSubscriptions;
  final int importedSubscriptionItems;
  final int alreadyImportedFiles;
  final List<String> archivedFiles;
  final List<String> quarantinedFiles;
  final List<LegacyImportIssue> issues;

  bool get hasIssues => issues.isNotEmpty;
}

/// One-time, crash-safe importer for the JSON stores used before schema v71.
///
/// Every source file is committed in one Drift transaction and is archived
/// only after that transaction returns. If the process dies between those two
/// operations, the deterministic `legacy-plan:` / `legacy-sub:` keys make the
/// next launch observe the already-imported row and only finish the archive.
/// Subtitle staging files are never copied, renamed, or deleted by this class.
class VideoDownloadLegacyImporter {
  VideoDownloadLegacyImporter({
    required this.database,
    required this.baseDirectory,
    this.torrentMatcher,
    this.subscriptionBackendResolver,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final FushiDatabase database;
  final Directory baseDirectory;
  final LegacyTorrentMatcher? torrentMatcher;
  final LegacySubscriptionBackendResolver? subscriptionBackendResolver;
  final DateTime Function() _now;

  Directory get _plansDirectory =>
      Directory(p.join(baseDirectory.path, 'plans'));
  Directory get _subscriptionsDirectory =>
      Directory(p.join(baseDirectory.path, 'subscriptions'));
  Directory get _archiveDirectory =>
      Directory(p.join(baseDirectory.path, 'legacy_import_archive'));
  Directory get _quarantineDirectory =>
      Directory(p.join(baseDirectory.path, 'legacy_import_quarantine'));

  Future<LegacyVideoDownloadImportReport> importAll() async {
    final _MutableLegacyImportReport report = _MutableLegacyImportReport();
    await _importDirectory(
      source: _plansDirectory,
      kind: 'plans',
      report: report,
      importFile: _importPlanFile,
    );
    await _importDirectory(
      source: _subscriptionsDirectory,
      kind: 'subscriptions',
      report: report,
      importFile: _importSubscriptionFile,
    );
    return report.freeze();
  }

  Future<void> _importDirectory({
    required Directory source,
    required String kind,
    required _MutableLegacyImportReport report,
    required Future<_LegacyFileImportOutcome> Function(
      File file,
      _MutableLegacyImportReport report,
    ) importFile,
  }) async {
    if (!await source.exists()) return;
    final List<File> files = <File>[];
    try {
      await for (final FileSystemEntity entity in source.list()) {
        if (entity is File &&
            p.extension(entity.path).toLowerCase() == '.json') {
          files.add(entity);
        }
      }
    } on FileSystemException {
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.corruptFile,
        fileName: p.basename(source.path),
        message: 'legacy import directory is not readable',
      ));
      return;
    }
    files.sort((File a, File b) => a.path.compareTo(b.path));
    for (final File file in files) {
      final _LegacyFileImportOutcome outcome = await importFile(file, report);
      if (outcome == _LegacyFileImportOutcome.committed ||
          outcome == _LegacyFileImportOutcome.alreadyImported) {
        final bool archived = await _archive(file, kind);
        if (archived) {
          report.archivedFiles.add(p.basename(file.path));
        } else {
          report.issues.add(LegacyImportIssue(
            kind: LegacyImportIssueKind.archiveFailure,
            fileName: p.basename(file.path),
            message: 'database commit succeeded but JSON archive failed',
          ));
        }
      } else if (outcome == _LegacyFileImportOutcome.corrupt) {
        final bool quarantined = await _quarantine(file, kind);
        if (quarantined) {
          report.quarantinedFiles.add(p.basename(file.path));
          await _persistQuarantineReport(
            kind: kind,
            fileName: p.basename(file.path),
            report: report,
          );
        }
      }
    }
  }

  /// 五张 v71 表没有单独的迁移报告表。把已隔离的损坏 JSON 记成不可调度的
  /// needsAttention 记录，使下载任务面板能明确告诉用户，而不是只写开发日志。
  /// 稳定 id 让崩溃重试/重复扫描仍只保留一条。
  Future<void> _persistQuarantineReport({
    required String kind,
    required String fileName,
    required _MutableLegacyImportReport report,
  }) async {
    final int now = _now().millisecondsSinceEpoch;
    final String digest =
        sha256.convert(utf8.encode('$kind|$fileName')).toString();
    try {
      await database.upsertVideoDownloadJob(
        VideoDownloadJobsCompanion.insert(
          jobId: 'legacy-import-report:$digest',
          resourceProvider: 'legacy-import-report',
          selectedResourceId: '$kind:$digest',
          resourceTitle: Value<String?>('Quarantined legacy JSON: $fileName'),
          mediaKind: 'tv',
          title: fileName,
          backendKind: 'legacy',
          fingerprint: 'legacy-import-report:$digest',
          organizationPolicy: const Value<String>('legacy'),
          lifecycle: const Value<String>(
            VideoDownloadJobLifecycle.needsAttention,
          ),
          stage: const Value<String>(VideoDownloadJobStage.enqueue),
          lastError: const Value<String?>(
            'A malformed legacy download file was isolated and was not imported',
          ),
          createdAt: now,
          updatedAt: now,
        ),
      );
    } on Object {
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.databaseWrite,
        fileName: fileName,
        message: 'quarantine report could not be persisted for the UI',
      ));
    }
  }

  Future<_LegacyFileImportOutcome> _importPlanFile(
    File file,
    _MutableLegacyImportReport report,
  ) async {
    final Map<dynamic, dynamic>? raw = await _readJsonMap(file);
    final AnimeDownloadPlan? plan =
        raw == null ? null : decodeAnimeDownloadPlan(raw);
    if (plan == null || !_validPlan(plan)) {
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.corruptFile,
        fileName: p.basename(file.path),
        message: 'legacy plan JSON is malformed or incomplete',
      ));
      return _LegacyFileImportOutcome.corrupt;
    }

    final String jobId = 'legacy-plan:${plan.id.trim().toLowerCase()}';
    final LegacyTorrentBinding? binding = await _confirmedBinding(plan);
    final bool backendConfirmed = binding != null;
    final List<String> attentionReasons = <String>[];
    if (!backendConfirmed) {
      attentionReasons.add(
        'needsAttention: backend torrent was not confirmed by hash, title, '
        'and category',
      );
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.backendUnconfirmed,
        fileName: p.basename(file.path),
        message: 'legacy backend binding requires matching hash/title/category',
      ));
    }

    int? collectionId = plan.collectionId;
    if (collectionId != null &&
        await database.getMediaCollectionById(collectionId) == null) {
      collectionId = null;
      attentionReasons.add(
        'needsAttention: legacy collection is unavailable on this device',
      );
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.missingReference,
        fileName: p.basename(file.path),
        message: 'legacy collection reference is unavailable',
      ));
    }
    if (plan.status == AnimeDownloadPlan.statusFailed) {
      attentionReasons.add('legacy task previously failed');
    }
    if (plan.subtitleStatus == AnimeDownloadPlan.subtitleUnavailable) {
      attentionReasons.add('legacy subtitle selection was unavailable');
    }

    final int importedAt = _nonNegativeTimestamp(plan.createdAtMs);
    final String stage = _legacyPlanStage(plan);
    final String lifecycle = attentionReasons.any(
      (String reason) => reason.startsWith('needsAttention:'),
    )
        ? VideoDownloadJobLifecycle.needsAttention
        : _legacyPlanLifecycle(plan);
    final String? magnet =
        plan.magnet.trim().toLowerCase().startsWith('magnet:')
            ? plan.magnet.trim()
            : null;
    final String backendKind = binding?.backendKind.trim() ?? 'legacy';
    final String fingerprint = binding?.fingerprint.trim() ??
        _stableFingerprint('plan|${plan.id}|${plan.qbCategory}');

    try {
      bool inserted = false;
      await database.transaction(() async {
        if (await database.getVideoDownloadJob(jobId) != null) return;
        await database.upsertVideoDownloadJob(
          VideoDownloadJobsCompanion.insert(
            jobId: jobId,
            resourceProvider: 'nyaa',
            selectedResourceId: plan.id,
            magnetUri: Value<String?>(magnet),
            resourceTitle: Value<String?>(plan.torrentTitle.trim()),
            torrentHash: Value<String?>(plan.id.trim().toLowerCase()),
            metadataProvider: plan.anilistId == null
                ? const Value<String?>.absent()
                : const Value<String?>('anilist'),
            externalId: plan.anilistId == null
                ? const Value<String?>.absent()
                : Value<String?>('${plan.anilistId}'),
            mediaKind: 'tv',
            discoveryCategory: const Value<String?>('anime'),
            title: plan.seriesTitle.trim(),
            coverUrl: Value<String?>(_nonEmpty(plan.coverUrl)),
            backendKind: backendKind.isEmpty ? 'legacy' : backendKind,
            backendTaskId: Value<String?>(_nonEmpty(binding?.backendTaskId)),
            backendProfileId:
                Value<String?>(_nonEmpty(binding?.backendProfileId)),
            fingerprint: fingerprint.isEmpty
                ? _stableFingerprint('plan|${plan.id}')
                : fingerprint,
            category: Value<String?>(_nonEmpty(plan.qbCategory)),
            collectionId: Value<int?>(collectionId),
            organizationPolicy: const Value<String>('legacy'),
            subtitlePolicy: Value<String>(
              plan.subtitleStatus == AnimeDownloadPlan.subtitleNone
                  ? 'none'
                  : 'bestEffort',
            ),
            observedSavePath:
                Value<String?>(_nonEmpty(binding?.observedSavePath)),
            lifecycle: Value<String>(lifecycle),
            stage: Value<String>(stage),
            stageProgress: Value<double>(
              plan.status == AnimeDownloadPlan.statusImported ? 1.0 : 0.0,
            ),
            lastError: Value<String?>(
              attentionReasons.isEmpty ? null : attentionReasons.join('; '),
            ),
            createdAt: importedAt,
            updatedAt: importedAt,
            completedAt: plan.status == AnimeDownloadPlan.statusImported &&
                    lifecycle == VideoDownloadJobLifecycle.completed
                ? Value<int?>(importedAt)
                : const Value<int?>.absent(),
          ),
        );
        for (int index = 0; index < plan.subtitles.length; index++) {
          final PlanSubtitle subtitle = plan.subtitles[index];
          await database.upsertVideoDownloadJobSubtitle(
            VideoDownloadJobSubtitlesCompanion.insert(
              subtitleId: _legacySubtitleId(jobId, index, subtitle),
              jobId: jobId,
              provider: 'jimaku',
              selectedSubtitleId: Value<String?>(
                '${plan.jimakuEntryId ?? 'legacy'}:${subtitle.fileName}',
              ),
              language: Value<String?>(_nonEmpty(subtitle.language)),
              episode: Value<int?>(subtitle.episode),
              originalFileName: Value<String?>(subtitle.fileName),
              stagedPath: Value<String?>(subtitle.stagedPath),
              status: const Value<String>(
                VideoDownloadJobSubtitleStatus.staged,
              ),
              createdAt: importedAt,
              updatedAt: importedAt,
            ),
          );
        }
        inserted = true;
      });
      if (!inserted) {
        report.alreadyImportedFiles++;
        return _LegacyFileImportOutcome.alreadyImported;
      }
      report.importedPlans++;
      return _LegacyFileImportOutcome.committed;
    } catch (_) {
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.databaseWrite,
        fileName: p.basename(file.path),
        message: 'legacy plan database transaction failed and was rolled back',
      ));
      return _LegacyFileImportOutcome.failed;
    }
  }

  Future<_LegacyFileImportOutcome> _importSubscriptionFile(
    File file,
    _MutableLegacyImportReport report,
  ) async {
    final Map<dynamic, dynamic>? raw = await _readJsonMap(file);
    final AnimeDownloadSubscription? subscription =
        raw == null ? null : decodeAnimeDownloadSubscription(raw);
    if (subscription == null) {
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.corruptFile,
        fileName: p.basename(file.path),
        message: 'legacy subscription JSON is malformed or incomplete',
      ));
      return _LegacyFileImportOutcome.corrupt;
    }

    final String subscriptionId = 'legacy-sub:${subscription.id}';
    LegacySubscriptionBackendBinding? binding;
    try {
      binding = await subscriptionBackendResolver?.call(subscription);
    } catch (_) {
      binding = null;
    }
    if (binding == null ||
        binding.backendKind.trim().isEmpty ||
        binding.fingerprint.trim().isEmpty ||
        binding.category.trim().isEmpty) {
      binding = null;
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.backendUnconfirmed,
        fileName: p.basename(file.path),
        message: 'legacy subscription needs a configured backend binding',
      ));
    }
    final int createdAt = _nonNegativeTimestamp(subscription.createdAtMs);
    final bool enabled = subscription.enabled && binding != null;
    final Map<String, Object?> filters = <String, Object?>{
      'strict': true,
      'releaseGroup': subscription.releaseGroup,
      'resolution': subscription.resolution,
      'trustedOnly': subscription.trustedOnly,
      'nyaaCategory': subscription.category,
      'jimakuEntryId': subscription.jimakuEntryId,
      'jimakuEntryName': subscription.jimakuEntryName,
      'jimakuLanguage': subscription.jimakuLanguage,
    };

    try {
      bool inserted = false;
      int itemCount = 0;
      await database.transaction(() async {
        if (await database.getVideoDownloadSubscription(subscriptionId) !=
            null) {
          return;
        }
        await database.upsertVideoDownloadSubscription(
          VideoDownloadSubscriptionsCompanion.insert(
            subscriptionId: subscriptionId,
            resourceProvider: 'nyaa',
            metadataProvider: const Value<String?>('anilist'),
            externalId: Value<String?>('${subscription.anilistId}'),
            mediaKind: 'tv',
            discoveryCategory: const Value<String?>('anime'),
            title: subscription.seriesTitle.trim(),
            coverUrl: Value<String?>(_nonEmpty(subscription.coverUrl)),
            searchQuery: subscription.nyaaQuery.trim(),
            filterJson: Value<String>(jsonEncode(filters)),
            mode: const Value<String>('ongoing'),
            startAfterEpisode: Value<int?>(subscription.startAfterEpisode),
            backendKind: binding?.backendKind.trim() ?? 'legacy',
            backendProfileId:
                Value<String?>(_nonEmpty(binding?.backendProfileId)),
            fingerprint: binding?.fingerprint.trim() ??
                _stableFingerprint('subscription|${subscription.id}'),
            category: Value<String?>(_nonEmpty(binding?.category)),
            organizationPolicy: const Value<String>('legacy'),
            subtitlePolicy: Value<String>(
              subscription.jimakuEntryId == null ? 'none' : 'required',
            ),
            enabled: Value<bool>(enabled),
            nextCheckAt: enabled
                ? Value<int?>(_now().millisecondsSinceEpoch)
                : const Value<int?>(null),
            lastCheckedAt: Value<int?>(subscription.lastCheckedAtMs),
            lastMatchedAt: Value<int?>(subscription.lastMatchedAtMs),
            lastError: Value<String?>(binding == null
                ? 'needsAttention: legacy subscription backend is unbound'
                : _safeLegacySubscriptionError(subscription.lastError)),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
        final List<int> episodes = subscription.processedEpisodes.toList()
          ..sort();
        for (final int episode in episodes) {
          final String logicalItemKey = _episodeKey(episode);
          await database.upsertVideoDownloadSubscriptionItem(
            VideoDownloadSubscriptionItemsCompanion.insert(
              subscriptionId: subscriptionId,
              logicalItemKey: logicalItemKey,
              resourceProvider: 'nyaa',
              selectedResourceId: 'legacy:${subscription.id}:$logicalItemKey',
              title: '${subscription.seriesTitle} - $logicalItemKey',
              season: const Value<int?>(1),
              episode: Value<int?>(episode),
              status: const Value<String>(
                VideoDownloadSubscriptionItemStatus.processed,
              ),
              discoveredAt: subscription.lastMatchedAtMs ?? createdAt,
              updatedAt: subscription.lastMatchedAtMs ?? createdAt,
            ),
          );
          itemCount++;
        }
        inserted = true;
      });
      if (!inserted) {
        report.alreadyImportedFiles++;
        return _LegacyFileImportOutcome.alreadyImported;
      }
      report.importedSubscriptions++;
      report.importedSubscriptionItems += itemCount;
      return _LegacyFileImportOutcome.committed;
    } catch (_) {
      report.issues.add(LegacyImportIssue(
        kind: LegacyImportIssueKind.databaseWrite,
        fileName: p.basename(file.path),
        message:
            'legacy subscription database transaction failed and was rolled back',
      ));
      return _LegacyFileImportOutcome.failed;
    }
  }

  Future<LegacyTorrentBinding?> _confirmedBinding(
    AnimeDownloadPlan plan,
  ) async {
    final LegacyTorrentMatcher? matcher = torrentMatcher;
    if (matcher == null) return null;
    LegacyTorrentBinding? candidate;
    try {
      candidate = await matcher(LegacyTorrentProbe(
        torrentHash: plan.id,
        title: plan.torrentTitle,
        category: plan.qbCategory,
      ));
    } catch (_) {
      return null;
    }
    if (candidate == null ||
        candidate.backendKind.trim().isEmpty ||
        candidate.fingerprint.trim().isEmpty ||
        candidate.torrentHash.trim().toLowerCase() !=
            plan.id.trim().toLowerCase() ||
        candidate.title.trim() != plan.torrentTitle.trim() ||
        candidate.category.trim() != plan.qbCategory.trim()) {
      return null;
    }
    return candidate;
  }

  Future<Map<dynamic, dynamic>?> _readJsonMap(File file) async {
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _archive(File source, String kind) async => _moveAfterCommit(
        source,
        Directory(p.join(_archiveDirectory.path, kind)),
      );

  Future<bool> _quarantine(File source, String kind) async => _moveAfterCommit(
        source,
        Directory(p.join(_quarantineDirectory.path, kind)),
      );

  Future<bool> _moveAfterCommit(File source, Directory destination) async {
    try {
      await destination.create(recursive: true);
      File target = File(p.join(destination.path, p.basename(source.path)));
      if (await target.exists()) {
        final List<int> sourceBytes = await source.readAsBytes();
        final List<int> targetBytes = await target.readAsBytes();
        if (_sameBytes(sourceBytes, targetBytes)) {
          await source.delete();
          return true;
        }
        final String stem = p.basenameWithoutExtension(source.path);
        target = File(p.join(
          destination.path,
          '$stem.${_now().microsecondsSinceEpoch}.json',
        ));
      }
      await source.rename(target.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _validPlan(AnimeDownloadPlan plan) =>
      plan.id.trim().isNotEmpty &&
      plan.seriesTitle.trim().isNotEmpty &&
      plan.torrentTitle.trim().isNotEmpty;

  static String _legacyPlanStage(AnimeDownloadPlan plan) {
    if (plan.status == AnimeDownloadPlan.statusImported) {
      return VideoDownloadJobStage.scrape;
    }
    // 旧 JSON 的 importInProgress 可能恰好停在“DB 尚未提交”的崩溃窗口，v71
    // 又没有可从 JSON 恢复的绝对文件列表。统一从 download 对账后端文件，再走
    // legacy（不整理）导入，既不丢原路径也不会在 import 阶段凭空失败。
    return VideoDownloadJobStage.download;
  }

  static String _legacyPlanLifecycle(AnimeDownloadPlan plan) {
    switch (plan.status) {
      case AnimeDownloadPlan.statusImported:
        return VideoDownloadJobLifecycle.completed;
      case AnimeDownloadPlan.statusFailed:
        return VideoDownloadJobLifecycle.failed;
      default:
        return VideoDownloadJobLifecycle.active;
    }
  }

  static int _nonNegativeTimestamp(int value) => value < 0 ? 0 : value;

  static String? _nonEmpty(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String? _safeLegacySubscriptionError(String? value) =>
      value == null || value.trim().isEmpty
          ? null
          : 'legacy subscription previously reported an error';

  static String _stableFingerprint(String input) =>
      'legacy-unbound:${sha256.convert(utf8.encode(input))}';

  static String _legacySubtitleId(
    String jobId,
    int index,
    PlanSubtitle subtitle,
  ) =>
      'legacy-subtitle:${sha256.convert(utf8.encode(
        '$jobId|$index|${subtitle.fileName}|${subtitle.stagedPath}',
      ))}';

  static String _episodeKey(int episode) =>
      'S01E${episode.toString().padLeft(2, '0')}';

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

enum _LegacyFileImportOutcome {
  committed,
  alreadyImported,
  corrupt,
  failed,
}

class _MutableLegacyImportReport {
  int importedPlans = 0;
  int importedSubscriptions = 0;
  int importedSubscriptionItems = 0;
  int alreadyImportedFiles = 0;
  final List<String> archivedFiles = <String>[];
  final List<String> quarantinedFiles = <String>[];
  final List<LegacyImportIssue> issues = <LegacyImportIssue>[];

  LegacyVideoDownloadImportReport freeze() => LegacyVideoDownloadImportReport(
        importedPlans: importedPlans,
        importedSubscriptions: importedSubscriptions,
        importedSubscriptionItems: importedSubscriptionItems,
        alreadyImportedFiles: alreadyImportedFiles,
        archivedFiles: List<String>.unmodifiable(archivedFiles),
        quarantinedFiles: List<String>.unmodifiable(quarantinedFiles),
        issues: List<LegacyImportIssue>.unmodifiable(issues),
      );
}
