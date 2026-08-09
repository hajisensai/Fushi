import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-v71-backup-');
  });

  tearDown(() async {
    if (root.existsSync()) await cleanupTempDir(root);
  });

  Future<void> seedDownloadGraph(
    FushiDatabase database, {
    bool withLocalReferences = false,
  }) async {
    int? sourceId;
    int? collectionId;
    if (withLocalReferences) {
      sourceId = await database.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Local videos',
          mediaKind: 'video',
          rootPath: r'D:\Media\Videos',
          createdAt: 10,
        ),
      );
      collectionId = await database.createMediaCollection('Local collection');
    }
    await database.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job-local',
        resourceProvider: 'nyaa',
        selectedResourceId: 'resource-local',
        torrentHash: const Value<String?>(
          '0123456789abcdef0123456789abcdef01234567',
        ),
        mediaKind: 'tv',
        discoveryCategory: const Value<String?>('anime'),
        title: 'Local job',
        backendKind: 'qbittorrent',
        backendTaskId: const Value<String?>('backend-task'),
        backendProfileId: const Value<String?>('default'),
        fingerprint: 'qb:local',
        category: const Value<String?>('fushi'),
        targetSourceId: Value<int?>(sourceId),
        collectionId: Value<int?>(collectionId),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.active),
        stage: const Value<String>(VideoDownloadJobStage.organize),
        nextAttemptAt: const Value<int?>(123),
        claimedBy: const Value<String?>('worker-before-restore'),
        claimExpiresAt: const Value<int?>(999999),
        createdAt: 100,
        updatedAt: 100,
      ),
    );
    final int fileId = await database
        .into(database.videoDownloadJobFiles)
        .insert(
          VideoDownloadJobFilesCompanion.insert(
            jobId: 'job-local',
            backendFileIndex: const Value<int?>(0),
            originalRelativePath: 'Show/episode.mkv',
            currentRelativePath: 'Show/episode.mkv',
            targetRelativePath:
                const Value<String?>('Show/Season 01/Show - S01E01.mkv'),
            kind: const Value<String>('video'),
            season: const Value<int?>(1),
            episode: const Value<int?>(1),
            status: const Value<String>(VideoDownloadJobFileStatus.organized),
            createdAt: 100,
            updatedAt: 100,
          ),
        );
    await database.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion.insert(
        subtitleId: 'subtitle-local',
        jobId: 'job-local',
        jobFileId: Value<int?>(fileId),
        provider: 'jimaku',
        language: const Value<String?>('ja'),
        stagedPath: const Value<String?>(r'D:\staging\episode.ass'),
        status: const Value<String>(VideoDownloadJobSubtitleStatus.staged),
        createdAt: 100,
        updatedAt: 100,
      ),
    );
    await database.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: 'subscription-local',
        resourceProvider: 'nyaa',
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('42'),
        mediaKind: 'tv',
        discoveryCategory: const Value<String?>('anime'),
        title: 'Local subscription',
        searchQuery: 'Local subscription',
        backendKind: 'qbittorrent',
        backendProfileId: const Value<String?>('default'),
        fingerprint: 'qb:local',
        category: const Value<String?>('fushi'),
        targetSourceId: Value<int?>(sourceId),
        collectionId: Value<int?>(collectionId),
        enabled: const Value<bool>(true),
        nextCheckAt: const Value<int?>(321),
        claimedBy: const Value<String?>('subscription-worker'),
        claimExpiresAt: const Value<int?>(999999),
        createdAt: 100,
        updatedAt: 100,
      ),
    );
    await database.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'subscription-local',
        logicalItemKey: 'S01E01',
        resourceProvider: 'nyaa',
        selectedResourceId: 'release-local',
        title: 'Local subscription - S01E01',
        season: const Value<int?>(1),
        episode: const Value<int?>(1),
        jobId: const Value<String?>('job-local'),
        status: const Value<String>(VideoDownloadSubscriptionItemStatus.queued),
        discoveredAt: 100,
        updatedAt: 100,
      ),
    );
  }

  Future<int> count(FushiDatabase database, String table) async =>
      (await database
              .customSelect('SELECT COUNT(*) AS c FROM $table')
              .getSingle())
          .read<int>('c');

  test('shared backup strips all five device-local download tables', () async {
    final Directory sourceDirectory = Directory(p.join(root.path, 'source'));
    await sourceDirectory.create(recursive: true);
    final FushiDatabase source = FushiDatabase(sourceDirectory.path);
    await seedDownloadGraph(source, withLocalReferences: true);
    final String zipPath = p.join(root.path, 'shared.fushi.zip');
    await BackupService(
      db: source,
      dbDirectory: sourceDirectory.path,
      appVersion: '1.0.0',
    ).createBackup(zipPath);
    await source.close();

    final Directory restoredDirectory =
        Directory(p.join(root.path, 'fresh-restored'));
    await BackupService.restoreBackup(
      dbDirectory: restoredDirectory.path,
      zipPath: zipPath,
    );
    final FushiDatabase restored = FushiDatabase(restoredDirectory.path);
    addTearDown(restored.close);

    for (final String table in <String>[
      'video_download_jobs',
      'video_download_job_files',
      'video_download_job_subtitles',
      'video_download_subscriptions',
      'video_download_subscription_items',
    ]) {
      expect(await count(restored, table), 0, reason: '$table must not travel');
    }
  });

  test(
    'overwrite restore preserves local graph parent-first and makes missing '
    'source/collection actionable',
    () async {
      final Directory backupDirectory =
          Directory(p.join(root.path, 'other-device'));
      await backupDirectory.create(recursive: true);
      final FushiDatabase backupDatabase =
          FushiDatabase(backupDirectory.path);
      await backupDatabase.setPref('reader_font_size', '19');
      final String zipPath = p.join(root.path, 'other.fushi.zip');
      await BackupService(
        db: backupDatabase,
        dbDirectory: backupDirectory.path,
        appVersion: '1.0.0',
      ).createBackup(zipPath);
      await backupDatabase.close();

      final Directory currentDirectory =
          Directory(p.join(root.path, 'current-device'));
      await currentDirectory.create(recursive: true);
      final FushiDatabase before = FushiDatabase(currentDirectory.path);
      await seedDownloadGraph(before, withLocalReferences: true);
      await before.close();

      await BackupService.restoreBackup(
        dbDirectory: currentDirectory.path,
        zipPath: zipPath,
      );
      final FushiDatabase after = FushiDatabase(currentDirectory.path);
      addTearDown(after.close);

      final VideoDownloadJobRow job =
          (await after.getVideoDownloadJobs()).single;
      expect(job.targetSourceId, isNull);
      expect(job.collectionId, isNull);
      expect(job.lifecycle, VideoDownloadJobLifecycle.needsAttention);
      expect(job.claimedBy, isNull);
      expect(job.claimExpiresAt, isNull);
      expect(job.nextAttemptAt, isNull);
      expect(job.lastError, startsWith('needsAttention:'));
      expect(await after.getVideoDownloadJobFiles(job.jobId), hasLength(1));
      expect(await after.getVideoDownloadJobSubtitles(job.jobId), hasLength(1));

      final VideoDownloadSubscriptionRow subscription =
          (await after.getVideoDownloadSubscriptions()).single;
      expect(subscription.targetSourceId, isNull);
      expect(subscription.collectionId, isNull);
      expect(subscription.enabled, isFalse);
      expect(subscription.claimedBy, isNull);
      expect(subscription.claimExpiresAt, isNull);
      expect(subscription.nextCheckAt, isNull);
      expect(subscription.lastError, startsWith('needsAttention:'));
      expect(
        await after.getVideoDownloadSubscriptionItems(
          subscription.subscriptionId,
        ),
        hasLength(1),
      );

      final List<dynamic> foreignKeyErrors =
          await after.customSelect('PRAGMA foreign_key_check').get();
      expect(foreignKeyErrors, isEmpty);
    },
  );

  test(
    'recoverPendingRestore replays all five local tables after an overwrite '
    'crash and is idempotent',
    () async {
      final Directory currentDirectory =
          Directory(p.join(root.path, 'crashed-current'));
      await currentDirectory.create(recursive: true);
      final FushiDatabase before = FushiDatabase(currentDirectory.path);
      await seedDownloadGraph(before, withLocalReferences: true);
      await before.close();

      final String dbPath = p.join(currentDirectory.path, 'fushi.db');
      final String bakPath = '$dbPath.pre-restore.bak';
      final String repairBakPath = '$bakPath.repair';
      final String sidecarPath =
          p.join(currentDirectory.path, 'fushi.db.sync-preserve.json');
      await File(dbPath).copy(bakPath);
      await File(dbPath).copy(repairBakPath);

      // Simulate the destructive database swap completing before the inline
      // device-local replay. This replacement has no download rows and no
      // matching source/collection, exactly like a sanitized shared backup.
      final Directory replacementDirectory =
          Directory(p.join(root.path, 'crashed-replacement'));
      await replacementDirectory.create(recursive: true);
      final FushiDatabase replacement =
          FushiDatabase(replacementDirectory.path);
      await replacement.setPref('reader_font_size', '21');
      await replacement.close();
      for (final String suffix in <String>['-wal', '-shm']) {
        final File sideFile = File('$dbPath$suffix');
        if (sideFile.existsSync()) await sideFile.delete();
      }
      await File(dbPath).delete();
      await File(p.join(replacementDirectory.path, 'fushi.db')).copy(dbPath);

      // The common full-restore path can have zero preserved sync prefs. Its
      // marker still has to exist solely for the v71 device-local graph.
      await File(sidecarPath).writeAsString(
        jsonEncode(<String, dynamic>{
          'mode': 'prefs',
          'prefs': <String, String>{},
          'preserveDeviceLocalTables': true,
        }),
      );

      // A retryable replay failure must keep BOTH recovery artifacts. Preserve
      // the SQLite signature but truncate the snapshot so ATTACH/replay fails.
      final List<int> sqliteHeader =
          (await File(bakPath).readAsBytes()).take(16).toList(growable: false);
      await File(bakPath).writeAsBytes(sqliteHeader, flush: true);
      await BackupService.recoverPendingRestore(currentDirectory.path);
      expect(File(sidecarPath).existsSync(), isTrue);
      expect(File(bakPath).existsSync(), isTrue);

      final FushiDatabase overwritten = FushiDatabase(currentDirectory.path);
      for (final String table in <String>[
        'video_download_jobs',
        'video_download_job_files',
        'video_download_job_subtitles',
        'video_download_subscriptions',
        'video_download_subscription_items',
      ]) {
        expect(await count(overwritten, table), 0,
            reason: '$table was cleared by the overwrite');
      }
      await overwritten.close();

      await File(bakPath).delete();
      await File(repairBakPath).copy(bakPath);
      await BackupService.recoverPendingRestore(currentDirectory.path);
      expect(File(sidecarPath).existsSync(), isFalse);
      expect(File(bakPath).existsSync(), isFalse);

      // A second startup must be a no-op rather than duplicating graph rows.
      await BackupService.recoverPendingRestore(currentDirectory.path);

      final FushiDatabase recovered = FushiDatabase(currentDirectory.path);
      addTearDown(recovered.close);
      for (final String table in <String>[
        'video_download_jobs',
        'video_download_job_files',
        'video_download_job_subtitles',
        'video_download_subscriptions',
        'video_download_subscription_items',
      ]) {
        expect(await count(recovered, table), 1,
            reason: '$table must be restored exactly once');
      }

      final VideoDownloadJobRow job =
          (await recovered.getVideoDownloadJobs()).single;
      expect(job.targetSourceId, isNull);
      expect(job.collectionId, isNull);
      expect(job.lifecycle, VideoDownloadJobLifecycle.needsAttention);
      expect(job.claimedBy, isNull);
      expect(job.claimExpiresAt, isNull);

      final VideoDownloadSubscriptionRow subscription =
          (await recovered.getVideoDownloadSubscriptions()).single;
      expect(subscription.targetSourceId, isNull);
      expect(subscription.collectionId, isNull);
      expect(subscription.enabled, isFalse);
      expect(subscription.claimedBy, isNull);
      expect(subscription.claimExpiresAt, isNull);

      final List<dynamic> foreignKeyErrors =
          await recovered.customSelect('PRAGMA foreign_key_check').get();
      expect(foreignKeyErrors, isEmpty);
    },
  );

  test('merge import never adopts attached device-local download rows',
      () async {
    final Directory attachedDirectory =
        Directory(p.join(root.path, 'attached'));
    await attachedDirectory.create(recursive: true);
    final FushiDatabase attached = FushiDatabase(attachedDirectory.path);
    await seedDownloadGraph(attached);
    await attached.close();

    final FushiDatabase target =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    final String safePath = p
        .join(attachedDirectory.path, 'fushi.db')
        .replaceAll(r'\', '/')
        .replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safePath' AS mergesrc");
    await BackupMergeEngine(target).merge();

    for (final String table in mergeSkippedDeviceLocalTableNames()) {
      if (!table.startsWith('video_download_')) continue;
      expect(await count(target, table), 0, reason: '$table must not merge');
    }
    await target.customStatement('DETACH DATABASE mergesrc');
  });
}
