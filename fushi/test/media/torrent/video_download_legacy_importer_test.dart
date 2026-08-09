import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi/src/media/torrent/video_download_legacy_importer.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late FushiDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-legacy-v78-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<File> writePlan(AnimeDownloadPlan plan) async {
    final Directory directory = Directory(p.join(root.path, 'plans'));
    await directory.create(recursive: true);
    final File file = File(p.join(directory.path, '${plan.id}.json'));
    await file.writeAsString(jsonEncode(encodeAnimeDownloadPlan(plan)));
    return file;
  }

  Future<File> writeSubscription(
    AnimeDownloadSubscription subscription,
  ) async {
    final Directory directory = Directory(p.join(root.path, 'subscriptions'));
    await directory.create(recursive: true);
    final File file = File(p.join(directory.path, '${subscription.id}.json'));
    await file.writeAsString(
      jsonEncode(encodeAnimeDownloadSubscription(subscription)),
    );
    return file;
  }

  AnimeDownloadPlan plan({
    String status = AnimeDownloadPlan.statusDownloading,
    int? collectionId,
    List<PlanSubtitle> subtitles = const <PlanSubtitle>[],
  }) =>
      AnimeDownloadPlan(
        id: '0123456789abcdef0123456789abcdef01234567',
        createdAtMs: 1234,
        anilistId: 42,
        seriesTitle: 'Example Show',
        coverUrl: 'https://example.test/cover.jpg',
        torrentTitle: '[Group] Example Show - 02 [1080p]',
        magnet: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
        qbCategory: 'hibiki',
        subtitles: subtitles,
        status: status,
        collectionId: collectionId,
        jimakuEntryId: 77,
        jimakuEntryName: 'Example Show',
        subtitleStatus: subtitles.isEmpty
            ? AnimeDownloadPlan.subtitleNone
            : AnimeDownloadPlan.subtitleResolved,
      );

  LegacyTorrentBinding matchingBinding(AnimeDownloadPlan value) =>
      LegacyTorrentBinding(
        torrentHash: value.id.toUpperCase(),
        title: value.torrentTitle,
        category: value.qbCategory,
        backendKind: 'qbittorrent',
        backendTaskId: value.id,
        backendProfileId: 'default',
        fingerprint: 'qb:local-instance',
        observedSavePath: r'Z:\downloads\Example Show',
      );

  test(
    'imports a confirmed plan atomically, archives JSON, and leaves subtitle '
    'staging untouched',
    () async {
      final Directory staging = Directory(p.join(root.path, 'subs', 'plan'));
      await staging.create(recursive: true);
      final File subtitleFile = File(p.join(staging.path, 'episode-02.zh.ass'));
      await subtitleFile.writeAsString('subtitle bytes');
      final AnimeDownloadPlan legacy = plan(
        subtitles: <PlanSubtitle>[
          PlanSubtitle(
            episode: 2,
            fileName: 'episode-02.zh.ass',
            stagedPath: subtitleFile.path,
            language: 'zh',
          ),
        ],
      );
      final File source = await writePlan(legacy);
      final VideoDownloadLegacyImporter importer = VideoDownloadLegacyImporter(
        database: database,
        baseDirectory: root,
        torrentMatcher: (LegacyTorrentProbe _) async => matchingBinding(legacy),
      );

      final LegacyVideoDownloadImportReport report = await importer.importAll();

      expect(report.importedPlans, 1);
      expect(report.quarantinedFiles, isEmpty);
      expect(source.existsSync(), isFalse);
      expect(
        File(p.join(
          root.path,
          'legacy_import_archive',
          'plans',
          p.basename(source.path),
        )).existsSync(),
        isTrue,
      );
      expect(subtitleFile.readAsStringSync(), 'subtitle bytes');

      final VideoDownloadJobRow job =
          (await database.getVideoDownloadJobs()).single;
      expect(job.lifecycle, VideoDownloadJobLifecycle.active);
      expect(job.stage, VideoDownloadJobStage.download);
      expect(job.organizationPolicy, 'legacy');
      expect(job.backendKind, 'qbittorrent');
      expect(job.backendProfileId, 'default');
      expect(job.fingerprint, 'qb:local-instance');
      expect(job.torrentHash, legacy.id);
      expect(job.observedSavePath, r'Z:\downloads\Example Show');

      final VideoDownloadJobSubtitleRow subtitle =
          (await database.getVideoDownloadJobSubtitles(job.jobId)).single;
      expect(subtitle.status, VideoDownloadJobSubtitleStatus.staged);
      expect(subtitle.stagedPath, subtitleFile.path);
      expect(subtitle.finalPath, isNull);
    },
  );

  test('requires hash, title, and category before binding a legacy backend',
      () async {
    final AnimeDownloadPlan legacy = plan();
    await writePlan(legacy);
    final VideoDownloadLegacyImporter importer = VideoDownloadLegacyImporter(
      database: database,
      baseDirectory: root,
      torrentMatcher: (LegacyTorrentProbe _) async => LegacyTorrentBinding(
        torrentHash: legacy.id,
        title: '${legacy.torrentTitle} mismatch',
        category: legacy.qbCategory,
        backendKind: 'qbittorrent',
        fingerprint: 'qb:must-not-bind',
      ),
    );

    final LegacyVideoDownloadImportReport report = await importer.importAll();
    final VideoDownloadJobRow job =
        (await database.getVideoDownloadJobs()).single;

    expect(job.lifecycle, VideoDownloadJobLifecycle.needsAttention);
    expect(job.backendKind, 'legacy');
    expect(job.fingerprint, startsWith('legacy-unbound:'));
    expect(job.lastError, contains('hash, title, and category'));
    expect(
      report.issues.map((LegacyImportIssue issue) => issue.kind),
      contains(LegacyImportIssueKind.backendUnconfirmed),
    );
  });

  test('missing legacy collection is nulled and made actionable', () async {
    final AnimeDownloadPlan legacy = plan(collectionId: 999);
    await writePlan(legacy);
    final VideoDownloadLegacyImporter importer = VideoDownloadLegacyImporter(
      database: database,
      baseDirectory: root,
      torrentMatcher: (LegacyTorrentProbe _) async => matchingBinding(legacy),
    );

    final LegacyVideoDownloadImportReport report = await importer.importAll();
    final VideoDownloadJobRow job =
        (await database.getVideoDownloadJobs()).single;

    expect(job.collectionId, isNull);
    expect(job.lifecycle, VideoDownloadJobLifecycle.needsAttention);
    expect(job.lastError, contains('collection is unavailable'));
    expect(
      report.issues.map((LegacyImportIssue issue) => issue.kind),
      contains(LegacyImportIssueKind.missingReference),
    );
  });

  test('replaying a committed file is idempotent and only finishes archive',
      () async {
    final AnimeDownloadPlan legacy = plan();
    final File original = await writePlan(legacy);
    final VideoDownloadLegacyImporter importer = VideoDownloadLegacyImporter(
      database: database,
      baseDirectory: root,
      torrentMatcher: (LegacyTorrentProbe _) async => matchingBinding(legacy),
    );
    await importer.importAll();

    final File archived = File(p.join(
      root.path,
      'legacy_import_archive',
      'plans',
      p.basename(original.path),
    ));
    await Directory(p.dirname(original.path)).create(recursive: true);
    await original.writeAsBytes(await archived.readAsBytes());

    final LegacyVideoDownloadImportReport second = await importer.importAll();

    expect(second.importedPlans, 0);
    expect(second.alreadyImportedFiles, 1);
    expect(await database.getVideoDownloadJobs(), hasLength(1));
    expect(original.existsSync(), isFalse);
  });

  test('imports processed episodes and quarantines corrupt neighbours',
      () async {
    final AnimeDownloadSubscription subscription = AnimeDownloadSubscription(
      id: 'legacy-subscription-id',
      createdAtMs: 2000,
      anilistId: 84,
      seriesTitle: 'Subscribed Show',
      nyaaQuery: 'Subscribed Show',
      category: '1_2',
      trustedOnly: true,
      releaseGroup: 'Group',
      resolution: '1080p',
      jimakuEntryId: 99,
      jimakuEntryName: 'Subscribed Show',
      jimakuLanguage: 'ja',
      startAfterEpisode: 1,
      processedEpisodes: const <int>{2, 4},
      lastCheckedAtMs: 2100,
      lastMatchedAtMs: 2200,
    );
    await writeSubscription(subscription);
    final Directory subscriptionDirectory =
        Directory(p.join(root.path, 'subscriptions'));
    final File corrupt = File(p.join(subscriptionDirectory.path, 'bad.json'));
    await corrupt.writeAsString('{not-json');
    final VideoDownloadLegacyImporter importer = VideoDownloadLegacyImporter(
      database: database,
      baseDirectory: root,
      subscriptionBackendResolver: (AnimeDownloadSubscription _) async =>
          const LegacySubscriptionBackendBinding(
        backendKind: 'embedded',
        fingerprint: 'embedded:install-id',
        category: 'hibiki',
      ),
      now: () => DateTime.fromMillisecondsSinceEpoch(3000),
    );

    final LegacyVideoDownloadImportReport report = await importer.importAll();

    expect(report.importedSubscriptions, 1);
    expect(report.importedSubscriptionItems, 2);
    expect(report.quarantinedFiles, <String>['bad.json']);
    expect(
      File(p.join(
        root.path,
        'legacy_import_quarantine',
        'subscriptions',
        'bad.json',
      )).existsSync(),
      isTrue,
    );
    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscriptions()).single;
    expect(row.enabled, isTrue);
    expect(row.organizationPolicy, 'legacy');
    expect(row.subtitlePolicy, 'required');
    expect(row.nextCheckAt, 3000);
    final Map<String, dynamic> filters =
        jsonDecode(row.filterJson) as Map<String, dynamic>;
    expect(filters['strict'], isTrue);
    expect(filters['releaseGroup'], 'Group');
    expect(filters['resolution'], '1080p');
    expect(filters['trustedOnly'], isTrue);

    final List<VideoDownloadSubscriptionItemRow> items =
        await database.getVideoDownloadSubscriptionItems(row.subscriptionId);
    expect(
        items.map(
            (VideoDownloadSubscriptionItemRow item) => item.logicalItemKey),
        <String>['S01E02', 'S01E04']);
    expect(
      items.every((VideoDownloadSubscriptionItemRow item) =>
          item.status == VideoDownloadSubscriptionItemStatus.processed),
      isTrue,
    );
  });

  test('keeps an unbound legacy subscription visible but disabled', () async {
    final AnimeDownloadSubscription subscription = AnimeDownloadSubscription(
      id: 'unbound',
      createdAtMs: 100,
      anilistId: 12,
      seriesTitle: 'Unbound Show',
      nyaaQuery: 'Unbound Show',
      category: '1_0',
      releaseGroup: 'Group',
      startAfterEpisode: 0,
    );
    await writeSubscription(subscription);

    final LegacyVideoDownloadImportReport report =
        await VideoDownloadLegacyImporter(
      database: database,
      baseDirectory: root,
    ).importAll();
    final VideoDownloadSubscriptionRow row =
        (await database.getVideoDownloadSubscriptions()).single;

    expect(row.enabled, isFalse);
    expect(row.backendKind, 'legacy');
    expect(row.lastError, startsWith('needsAttention:'));
    expect(
      report.issues.map((LegacyImportIssue issue) => issue.kind),
      contains(LegacyImportIssueKind.backendUnconfirmed),
    );
  });
}
