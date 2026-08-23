import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_cleanup_service.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;

FushiDatabase _freshDatabase() => FushiDatabase.forTesting(
  NativeDatabase.memory(
    setup: (CommonDatabase raw) {
      raw.execute('PRAGMA foreign_keys = ON');
    },
  ),
);

void main() {
  late FushiDatabase database;
  late Directory temporaryDirectory;
  late Directory sourceDirectory;
  late Directory coversDirectory;

  setUp(() async {
    database = _freshDatabase();
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'video_scrape_cleanup_',
    );
    sourceDirectory = Directory(p.join(temporaryDirectory.path, 'media'));
    coversDirectory = Directory(p.join(temporaryDirectory.path, 'covers'));
    await sourceDirectory.create(recursive: true);
    await coversDirectory.create(recursive: true);
  });

  tearDown(() async {
    await database.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('只删除 ledger 中未修改的生成 sidecar，并保留媒体结构、设置与用户资产', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final Map<String, File> mediaFiles = <String, File>{};
    final Map<String, File> coverFiles = <String, File>{};
    for (final String uid in <String>['auto', 'manual', 'user']) {
      final File media = File(p.join(sourceDirectory.path, '$uid.mkv'));
      await media.writeAsBytes(<int>[0x10, uid.length, 0x20]);
      mediaFiles[uid] = media;

      final File cover = File(p.join(coversDirectory.path, '$uid.jpg'));
      await cover.writeAsBytes(<int>[0x30, uid.length, 0x40]);
      coverFiles[uid] = cover;

      await database.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: 'video-$uid',
          videoPath: media.path,
          coverPath: Value<String?>(cover.path),
          lastPositionMs: const Value<int>(4321),
          sourceId: Value<int?>(sourceId),
        ),
      );
    }
    final File externalMedia = File(
      p.join(sourceDirectory.path, 'external-auto.mkv'),
    );
    await externalMedia.writeAsBytes(<int>[0x44, 0x55]);
    mediaFiles['external-auto'] = externalMedia;
    final File externalCover = File(
      p.join(temporaryDirectory.path, 'external-auto.jpg'),
    );
    await externalCover.writeAsBytes(<int>[0x66, 0x77]);
    coverFiles['external-auto'] = externalCover;
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'external-auto',
        title: 'video-external-auto',
        videoPath: externalMedia.path,
        coverPath: Value<String?>(externalCover.path),
        lastPositionMs: const Value<int>(4321),
        sourceId: Value<int?>(sourceId),
      ),
    );

    final CoverMetaStore coverMetaStore = CoverMetaStore(coversDirectory);
    await coverMetaStore.set(
      'auto',
      CoverMeta(
        origin: CoverOrigin.autoScraped,
        contentSha256: sha256.convert(await coverFiles['auto']!.readAsBytes())
            .toString(),
      ),
    );
    await coverMetaStore.set(
      'manual',
      const CoverMeta(origin: CoverOrigin.manual),
    );
    await coverMetaStore.set(
      'user',
      const CoverMeta(origin: CoverOrigin.userScraped),
    );
    await coverMetaStore.set(
      'external-auto',
      const CoverMeta(origin: CoverOrigin.autoScraped),
    );

    final int collectionId = await database.createMediaCollection(
      '用户合集',
      collectionType: 'playlist',
    );
    await database.updateMediaCollectionAudioTrackId(collectionId, 'ja');
    for (final String uid in mediaFiles.keys) {
      await database.addToCollection(collectionId, MediaKind.video, uid);
    }
    await database.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        autoAfterScan: const Value<bool>(true),
        writeNfo: const Value<bool>(true),
        updatedAt: 100,
      ),
    );

    await database.upsertVideoScrapeMeta(
      VideoScrapeMetaCompanion.insert(
        bookUid: 'auto',
        source: 'anidb',
        subjectId: '1',
        title: '刮削标题',
        scrapedAt: DateTime.fromMillisecondsSinceEpoch(100),
      ),
    );
    await database.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(collectionId),
        source: 'anidb',
        subjectId: '1',
        title: '刮削合集标题',
        scrapedAt: DateTime.fromMillisecondsSinceEpoch(100),
      ),
    );
    await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'canonical work',
        updatedAt: 100,
      ),
    );

    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File manualBackdrop = File(
      p.join(sourceDirectory.path, 'manual-backdrop.jpg'),
    );
    final List<int> manualBackdropBytes = <int>[4, 2, 4, 2];
    await manualBackdrop.writeAsBytes(manualBackdropBytes);
    await database.replaceMediaImagesForCollection(
      collectionId,
      <MediaImagesCompanion>[
        MediaImagesCompanion.insert(
          collectionId: Value<int?>(collectionId),
          kind: MediaImageKind.backdrop.dbValue,
          path: manualBackdrop.path,
        ),
      ],
    );
    // 即使历史 ledger 错误残留，sourceUrl=null 的手动附加图也必须优先受保护。
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: manualBackdrop,
      recordedBytes: manualBackdropBytes,
      artifactKind: 'backdrop',
    );
    final File generatedNfo = File(
      p.join(sourceDirectory.path, 'generated.nfo'),
    );
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    await generatedNfo.writeAsBytes(generatedBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: generatedNfo,
      recordedBytes: generatedBytes,
    );

    final File modifiedNfo = File(p.join(sourceDirectory.path, 'modified.nfo'));
    final List<int> originalBytes = '<movie>original</movie>'.codeUnits;
    final List<int> modifiedBytes = '<movie>user edited</movie>'.codeUnits;
    await modifiedNfo.writeAsBytes(originalBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: modifiedNfo,
      recordedBytes: originalBytes,
    );
    await modifiedNfo.writeAsBytes(modifiedBytes);

    final File userNfo = File(p.join(sourceDirectory.path, 'user.nfo'));
    final List<int> userNfoBytes = '<movie>user owned</movie>'.codeUnits;
    await userNfo.writeAsBytes(userNfoBytes);

    final File modifiedPoster = File(
      p.join(sourceDirectory.path, 'modified-poster.jpg'),
    );
    final List<int> originalPosterBytes = <int>[1, 2, 3, 4];
    final List<int> modifiedPosterBytes = <int>[9, 8, 7, 6];
    await modifiedPoster.writeAsBytes(originalPosterBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: modifiedPoster,
      recordedBytes: originalPosterBytes,
      artifactKind: 'cover',
    );
    await modifiedPoster.writeAsBytes(modifiedPosterBytes);
    await database.updateMediaCollectionCoverPath(
      collectionId,
      modifiedPoster.path,
    );

    // 即使历史 ledger 损坏并指向真实媒体，类型/扩展名与 media path 双护栏都必须
    // fail closed，绝不能因为 SHA 恰好一致就删原视频。
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: mediaFiles['auto']!,
      recordedBytes: await mediaFiles['auto']!.readAsBytes(),
      artifactKind: 'nfo',
    );

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();

    expect(result.deletedGeneratedFiles, 1);
    expect(result.protectedGeneratedFiles, 4);
    expect(result.protectedLegacyCoverFiles, 1);
    expect(result.deletedLegacyCoverFiles, 1);
    expect(
      await generatedNfo.exists(),
      isFalse,
      reason: 'ledger SHA 与当前内容一致的 Fushi 生成 NFO 才能删除',
    );
    expect(
      await modifiedNfo.readAsBytes(),
      modifiedBytes,
      reason: '用户改过的 artifact 已不再由 Fushi 拥有',
    );
    expect(
      await userNfo.readAsBytes(),
      userNfoBytes,
      reason: '没有 ledger 的 NFO 不能靠文件名猜测后删除',
    );
    expect(await modifiedPoster.readAsBytes(), modifiedPosterBytes);
    expect(await manualBackdrop.readAsBytes(), manualBackdropBytes);
    final List<MediaImageRow> retainedManualImages =
        await database.getMediaImagesForCollection(collectionId);
    expect(retainedManualImages, hasLength(1));
    expect(retainedManualImages.single.path, manualBackdrop.path);
    expect(retainedManualImages.single.sourceUrl, isNull);

    final Map<String, VideoBookRow> books = <String, VideoBookRow>{
      for (final VideoBookRow row in await database.allVideoBooks())
        row.bookUid: row,
    };
    expect(
      books.keys,
      unorderedEquals(<String>['auto', 'manual', 'user', 'external-auto']),
    );
    expect(books['auto']!.coverPath, isNull);
    expect(books['manual']!.coverPath, coverFiles['manual']!.path);
    expect(books['user']!.coverPath, coverFiles['user']!.path);
    expect(books['external-auto']!.coverPath, externalCover.path);
    for (final VideoBookRow book in books.values) {
      expect(book.lastPositionMs, 4321);
    }
    for (final File media in mediaFiles.values) {
      expect(await media.exists(), isTrue, reason: '清理不得删除视频媒体本身');
    }
    expect(await coverFiles['auto']!.exists(), isFalse);
    expect(await coverFiles['manual']!.exists(), isTrue);
    expect(await coverFiles['user']!.exists(), isTrue);
    expect(await externalCover.exists(), isTrue);

    final CoverMetaStore reloadedCoverMeta = CoverMetaStore(coversDirectory);
    expect(await reloadedCoverMeta.get('auto'), isNull);
    expect((await reloadedCoverMeta.get('manual'))!.origin, CoverOrigin.manual);
    expect(
      (await reloadedCoverMeta.get('user'))!.origin,
      CoverOrigin.userScraped,
    );
    expect(
      (await reloadedCoverMeta.get('external-auto'))!.origin,
      CoverOrigin.autoScraped,
    );

    final MediaCollectionRow collection = (await database
        .getMediaCollectionById(collectionId))!;
    expect(collection.name, '用户合集');
    expect(collection.collectionType, 'playlist');
    expect(collection.audioTrackId, 'ja');
    expect(collection.coverPath, modifiedPoster.path);
    expect(
      (await database.getCollectionItems(
        collectionId,
      )).map((MediaCollectionItemRow row) => row.entryKey),
      unorderedEquals(<String>['auto', 'manual', 'user', 'external-auto']),
    );
    final VideoSourceScrapeSettingRow settings = (await database
        .getVideoSourceScrapeSettings(sourceId))!;
    expect(settings.autoAfterScan, isTrue);
    expect(settings.writeNfo, isTrue);

    expect(await database.getAllVideoScrapeMeta(), isEmpty);
    expect(await database.getAllCollectionScrapeMeta(), isEmpty);
    expect(await database.getAllVideoMetadataWorks(), isEmpty);
    expect(await database.getVideoSourceScrapeRuns(), isEmpty);
    // 已被用户修改、来源根无效或指向手工资源的 ledger 继续保留，作为后续
    // 清理仍需 fail closed 的所有权证据。
    expect(await database.getVideoSidecarArtifacts(), hasLength(4));
    expect(
      await database.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
  });

  test('存在 running scrape 时 fail closed 且不触碰记录或文件', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'running',
    );
    final File generatedNfo = File(p.join(sourceDirectory.path, 'busy.nfo'));
    final List<int> bytes = '<movie>still running</movie>'.codeUnits;
    await generatedNfo.writeAsBytes(bytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: generatedNfo,
      recordedBytes: bytes,
    );

    final VideoScrapeCleanupService service = VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    );

    await expectLater(
      service.clearAll(),
      throwsA(isA<VideoScrapeCleanupBusyException>()),
    );
    expect(await generatedNfo.readAsBytes(), bytes);
    expect((await database.getVideoSourceScrapeRun(runId))!.status, 'running');
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
  });

  test('来源扫描占用共享排他门时，即使尚无 running run 也不产生副作用', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final File generatedNfo = File(p.join(sourceDirectory.path, 'scan.nfo'));
    final List<int> bytes = '<movie>scan</movie>'.codeUnits;
    await generatedNfo.writeAsBytes(bytes);
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: generatedNfo,
      recordedBytes: bytes,
    );
    final VideoScrapeOperationLease lease =
        VideoScrapeOperationGate.tryEnterOperation()!;
    try {
      await expectLater(
        VideoScrapeCleanupService(
          database: database,
          coversDirectory: coversDirectory,
        ).clearAll(),
        throwsA(isA<VideoScrapeCleanupBusyException>()),
      );
    } finally {
      lease.release();
    }
    expect(await generatedNfo.readAsBytes(), bytes);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
  });

  test('artifact 原子隔离后同路径新建的用户文件不会被旧 SHA 删除', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File generatedNfo = File(
      p.join(sourceDirectory.path, 'replaced-during-cleanup.nfo'),
    );
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    final List<int> userBytes = '<movie>new user file</movie>'.codeUnits;
    await generatedNfo.writeAsBytes(generatedBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: generatedNfo,
      recordedBytes: generatedBytes,
    );

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
      onArtifactQuarantined: (String originalPath, String _) async {
        await File(originalPath).writeAsBytes(userBytes, flush: true);
      },
    ).clearAll();

    expect(result.deletedGeneratedFiles, 0);
    expect(result.protectedGeneratedFiles, 1);
    expect(await generatedNfo.readAsBytes(), userBytes);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
    expect(
      await sourceDirectory
          .list()
          .where(
            (FileSystemEntity entity) =>
                entity.path.contains('.fushi-scrape-cleanup'),
          )
          .toList(),
      isEmpty,
    );
  });

  test('legacy autoScraped 隔离后出现同路径替换物时永久保护，二次清理也不误删', () async {
    const String bookUid = 'legacy-replaced';
    final File cover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final List<int> generatedBytes = <int>[1, 2, 3, 4];
    final List<int> userBytes = <int>[9, 8, 7, 6];
    await cover.writeAsBytes(generatedBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(cover.path),
      ),
    );
    final CoverMetaStore store = CoverMetaStore(coversDirectory);
    await store.set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.autoScraped,
        contentSha256: sha256.convert(generatedBytes).toString(),
      ),
    );

    final VideoScrapeCleanupResult first = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
      onArtifactQuarantined: (String originalPath, String _) async {
        if (p.equals(originalPath, cover.path)) {
          await File(originalPath).writeAsBytes(userBytes, flush: true);
        }
      },
    ).clearAll();

    expect(first.deletedLegacyCoverFiles, 0);
    expect(first.protectedLegacyCoverFiles, 1);
    expect(await cover.readAsBytes(), userBytes);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupReplacement);

    await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();
    expect(await cover.readAsBytes(), userBytes);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupReplacement);
    expect(await File('${cover.path}.fushi-scrape-cleanup').exists(), isFalse);
  });

  test('无历史摘要的 legacy autoScraped 不以当前内容自证，保留文件与指针', () async {
    const String bookUid = 'legacy-unverifiable';
    final File cover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final List<int> userBytes = <int>[7, 7, 1, 9];
    await cover.writeAsBytes(userBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(cover.path),
      ),
    );
    final CoverMetaStore store = CoverMetaStore(coversDirectory);
    await store.set(
      bookUid,
      const CoverMeta(origin: CoverOrigin.autoScraped),
    );

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();

    expect(result.deletedLegacyCoverFiles, 0);
    expect(result.protectedLegacyCoverFiles, 1);
    expect(await cover.readAsBytes(), userBytes);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupReplacement);
  });

  test('下次清理恢复 rename 后崩溃遗留的 artifact 与 legacy quarantine', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File artifact = File(p.join(sourceDirectory.path, 'recover.nfo'));
    final List<int> artifactBytes = '<movie>recover</movie>'.codeUnits;
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: artifact,
      recordedBytes: artifactBytes,
    );
    final File artifactQuarantine = File(
      '${artifact.path}.fushi-scrape-cleanup',
    );
    await artifactQuarantine.writeAsBytes(artifactBytes);

    const String bookUid = 'legacy-crash';
    final File legacyCover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final List<int> legacyBytes = <int>[4, 3, 2, 1];
    final File legacyQuarantine = File(
      '${legacyCover.path}.fushi-scrape-cleanup',
    );
    await legacyQuarantine.writeAsBytes(legacyBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(legacyCover.path),
      ),
    );
    await CoverMetaStore(coversDirectory).set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.cleanupPending,
        contentSha256: sha256.convert(legacyBytes).toString(),
      ),
    );

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();

    expect(result.deletedGeneratedFiles, 1);
    expect(result.deletedLegacyCoverFiles, 1);
    expect(await artifact.exists(), isFalse);
    expect(await artifactQuarantine.exists(), isFalse);
    expect(await legacyCover.exists(), isFalse);
    expect(await legacyQuarantine.exists(), isFalse);
    expect((await database.getVideoBookByBookUid(bookUid))!.coverPath, isNull);
    expect(await CoverMetaStore(coversDirectory).get(bookUid), isNull);
  });

  test('崩溃隔离到用户替换物时先恢复原路径，摘要不符也不会永久隐藏', () async {
    const String bookUid = 'legacy-crash-replacement';
    final File cover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final File quarantine = File('${cover.path}.fushi-scrape-cleanup');
    final List<int> oldGeneratedBytes = <int>[1, 1, 2, 3];
    final List<int> userReplacementBytes = <int>[9, 9, 8, 7];
    await quarantine.writeAsBytes(userReplacementBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(cover.path),
      ),
    );
    final CoverMetaStore store = CoverMetaStore(coversDirectory);
    await store.set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.cleanupPending,
        contentSha256: sha256.convert(oldGeneratedBytes).toString(),
      ),
    );

    await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();

    expect(await cover.readAsBytes(), userReplacementBytes);
    expect(await quarantine.exists(), isFalse);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupReplacement);

    // replacement 状态自身若再在 rename 后崩溃，也要恢复可见原路径，不能删掉 q
    // 后永久留下空指针。
    await cover.rename(quarantine.path);
    await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();
    expect(await cover.readAsBytes(), userReplacementBytes);
    expect(await quarantine.exists(), isFalse);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupReplacement);
  });

  test('artifact 崩溃恢复时晚到目标抢先创建则不覆盖并保留 quarantine', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File artifact = File(
      p.join(sourceDirectory.path, 'late-artifact-target.nfo'),
    );
    final File quarantine = File('${artifact.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    final List<int> lateUserBytes = '<movie>late user target</movie>'.codeUnits;
    await quarantine.writeAsBytes(generatedBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: artifact,
      recordedBytes: generatedBytes,
    );

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
      onBeforeQuarantineRestore:
          (String originalPath, String quarantinePath) async {
            expect(originalPath, artifact.path);
            expect(quarantinePath, quarantine.path);
            await File(originalPath).writeAsBytes(lateUserBytes, flush: true);
          },
    ).clearAll();

    expect(result.deletedGeneratedFiles, 0);
    expect(result.protectedGeneratedFiles, 1);
    expect(await artifact.readAsBytes(), lateUserBytes);
    expect(await quarantine.readAsBytes(), generatedBytes);
  });

  test('no-replace 恒不可用时，摘要不符的用户文件也不会离开原路径', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File artifact = File(p.join(sourceDirectory.path, 'unsupported.nfo'));
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    final List<int> userBytes = '<movie>user changed</movie>'.codeUnits;
    await artifact.writeAsBytes(generatedBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: artifact,
      recordedBytes: generatedBytes,
    );
    await artifact.writeAsBytes(userBytes);

    int restoreCalls = 0;
    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
      restoreQuarantineAtomically: (String _, String __) {
        restoreCalls++;
        return false;
      },
    ).clearAll();

    final File quarantine = File('${artifact.path}.fushi-scrape-cleanup');
    expect(result.protectedGeneratedFiles, 1);
    expect(restoreCalls, 0);
    expect(await artifact.readAsBytes(), userBytes);
    expect(await quarantine.exists(), isFalse);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
    expect(await database.getVideoSourceScrapeRuns(), isEmpty);
  });

  test('遗留 quarantine 无安全恢复原语时整笔回滚并保留 ledger', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File artifact = File(p.join(sourceDirectory.path, 'unsupported.nfo'));
    final File quarantine = File('${artifact.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    final List<int> userBytes = '<movie>user changed</movie>'.codeUnits;
    await quarantine.writeAsBytes(userBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: artifact,
      recordedBytes: generatedBytes,
    );

    await expectLater(
      VideoScrapeCleanupService(
        database: database,
        coversDirectory: coversDirectory,
        restoreQuarantineAtomically: (String _, String __) => false,
      ).clearAll(),
      throwsA(isA<VideoScrapeCleanupRecoveryException>()),
    );

    expect(await artifact.exists(), isFalse);
    expect(await quarantine.readAsBytes(), userBytes);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
    expect(await database.getVideoSourceScrapeRuns(), hasLength(1));

    await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
    ).clearAll();
    expect(await artifact.readAsBytes(), userBytes);
    expect(await quarantine.exists(), isFalse);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
  });

  test('legacy 崩溃恢复时晚到目标抢先创建则不覆盖且不清指针', () async {
    const String bookUid = 'legacy-late-target';
    final File cover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final File quarantine = File('${cover.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = <int>[1, 2, 3, 4];
    final List<int> lateUserBytes = <int>[9, 8, 7, 6];
    await quarantine.writeAsBytes(generatedBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(cover.path),
      ),
    );
    final CoverMetaStore store = CoverMetaStore(coversDirectory);
    await store.set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.cleanupPending,
        contentSha256: sha256.convert(generatedBytes).toString(),
      ),
    );

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
      coversDirectory: coversDirectory,
      onBeforeQuarantineRestore:
          (String originalPath, String quarantinePath) async {
            expect(originalPath, cover.path);
            expect(quarantinePath, quarantine.path);
            await File(originalPath).writeAsBytes(lateUserBytes, flush: true);
          },
    ).clearAll();

    expect(result.deletedLegacyCoverFiles, 0);
    expect(result.protectedLegacyCoverFiles, 1);
    expect(await cover.readAsBytes(), lateUserBytes);
    expect(await quarantine.exists(), isFalse);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupReplacement);
  });

  test('artifact quarantine 是用户替换物且原路径占用时显式回滚', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File artifact = File(p.join(sourceDirectory.path, 'conflict.nfo'));
    final File quarantine = File('${artifact.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    final List<int> hiddenUserBytes = '<movie>user U</movie>'.codeUnits;
    final List<int> occupyingUserBytes = '<movie>user V</movie>'.codeUnits;
    await artifact.writeAsBytes(occupyingUserBytes);
    await quarantine.writeAsBytes(hiddenUserBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: artifact,
      recordedBytes: generatedBytes,
    );

    await expectLater(
      VideoScrapeCleanupService(
        database: database,
        coversDirectory: coversDirectory,
      ).clearAll(),
      throwsA(
        isA<VideoScrapeCleanupRecoveryException>()
            .having(
              (VideoScrapeCleanupRecoveryException error) =>
                  error.originalPath,
              'originalPath',
              artifact.path,
            )
            .having(
              (VideoScrapeCleanupRecoveryException error) =>
                  error.quarantinePath,
              'quarantinePath',
              quarantine.path,
            ),
      ),
    );

    expect(await artifact.readAsBytes(), occupyingUserBytes);
    expect(await quarantine.readAsBytes(), hiddenUserBytes);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
    expect(await database.getVideoSourceScrapeRuns(), hasLength(1));
  });

  test('legacy quarantine 是用户替换物且原路径占用时显式回滚', () async {
    const String bookUid = 'legacy-conflict';
    final File cover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final File quarantine = File('${cover.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = <int>[1, 2, 3, 4];
    final List<int> hiddenUserBytes = <int>[9, 8, 7, 6];
    final List<int> occupyingUserBytes = <int>[6, 7, 8, 9];
    await cover.writeAsBytes(occupyingUserBytes);
    await quarantine.writeAsBytes(hiddenUserBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(cover.path),
      ),
    );
    final CoverMetaStore store = CoverMetaStore(coversDirectory);
    await store.set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.cleanupPending,
        contentSha256: sha256.convert(generatedBytes).toString(),
      ),
    );

    await expectLater(
      VideoScrapeCleanupService(
        database: database,
        coversDirectory: coversDirectory,
      ).clearAll(),
      throwsA(isA<VideoScrapeCleanupRecoveryException>()),
    );

    expect(await cover.readAsBytes(), occupyingUserBytes);
    expect(await quarantine.readAsBytes(), hiddenUserBytes);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupPending);
  });

  test('artifact rename 后任意 I/O 异常遇到目标占用也显式回滚', () async {
    final int sourceId = await _insertLocalVideoSource(
      database,
      sourceDirectory.path,
    );
    final int runId = await _insertRun(
      database,
      sourceId: sourceId,
      status: 'completed',
    );
    final File artifact = File(p.join(sourceDirectory.path, 'io-race.nfo'));
    final File quarantine = File('${artifact.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = '<movie>generated</movie>'.codeUnits;
    final List<int> lateUserBytes = '<movie>late user</movie>'.codeUnits;
    await artifact.writeAsBytes(generatedBytes);
    await _insertArtifact(
      database,
      sourceId: sourceId,
      runId: runId,
      file: artifact,
      recordedBytes: generatedBytes,
    );

    await expectLater(
      VideoScrapeCleanupService(
        database: database,
        coversDirectory: coversDirectory,
        onArtifactQuarantined: (String originalPath, String _) async {
          await File(originalPath).writeAsBytes(lateUserBytes, flush: true);
          throw const FileSystemException('simulated post-rename I/O failure');
        },
      ).clearAll(),
      throwsA(isA<VideoScrapeCleanupRecoveryException>()),
    );

    expect(await artifact.readAsBytes(), lateUserBytes);
    expect(await quarantine.readAsBytes(), generatedBytes);
    expect(await database.getVideoSidecarArtifacts(), hasLength(1));
    expect(await database.getVideoSourceScrapeRuns(), hasLength(1));
  });

  test('legacy rename 后任意 I/O 异常遇到目标占用也显式回滚', () async {
    const String bookUid = 'legacy-io-race';
    final File cover = File(p.join(coversDirectory.path, '$bookUid.jpg'));
    final File quarantine = File('${cover.path}.fushi-scrape-cleanup');
    final List<int> generatedBytes = <int>[1, 2, 3, 4];
    final List<int> lateUserBytes = <int>[9, 8, 7, 6];
    await cover.writeAsBytes(generatedBytes);
    await database.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: bookUid,
        title: bookUid,
        videoPath: p.join(sourceDirectory.path, '$bookUid.mkv'),
        coverPath: Value<String?>(cover.path),
      ),
    );
    final CoverMetaStore store = CoverMetaStore(coversDirectory);
    await store.set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.cleanupPending,
        contentSha256: sha256.convert(generatedBytes).toString(),
      ),
    );

    await expectLater(
      VideoScrapeCleanupService(
        database: database,
        coversDirectory: coversDirectory,
        onArtifactQuarantined: (String originalPath, String _) async {
          await File(originalPath).writeAsBytes(lateUserBytes, flush: true);
          throw const FileSystemException('simulated post-rename I/O failure');
        },
      ).clearAll(),
      throwsA(isA<VideoScrapeCleanupRecoveryException>()),
    );

    expect(await cover.readAsBytes(), lateUserBytes);
    expect(await quarantine.readAsBytes(), generatedBytes);
    expect(
      (await database.getVideoBookByBookUid(bookUid))!.coverPath,
      cover.path,
    );
    expect((await store.get(bookUid))!.origin, CoverOrigin.cleanupPending);
  });
}

Future<int> _insertLocalVideoSource(FushiDatabase database, String rootPath) =>
    database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Local videos',
        mediaKind: 'video',
        rootPath: rootPath,
        createdAt: 1,
      ),
    );

Future<int> _insertRun(
  FushiDatabase database, {
  required int sourceId,
  required String status,
}) => database.insertVideoSourceScrapeRun(
  VideoSourceScrapeRunsCompanion.insert(
    sourceId: Value<int?>(sourceId),
    scope: 'source',
    status: status,
    startedAt: 100,
    updatedAt: 100,
  ),
);

Future<void> _insertArtifact(
  FushiDatabase database, {
  required int sourceId,
  required int runId,
  required File file,
  required List<int> recordedBytes,
  String artifactKind = 'nfo',
}) async {
  await database.upsertVideoSidecarArtifact(
    VideoSidecarArtifactsCompanion.insert(
      sourceId: Value<int?>(sourceId),
      runId: Value<int?>(runId),
      artifactKind: artifactKind,
      path: p.normalize(p.absolute(file.path)),
      sha256: sha256.convert(recordedBytes).toString(),
      fileSize: Value<int?>(recordedBytes.length),
      generatorVersion: 'test',
      writePolicy: 'missingOnly',
      createdAt: 100,
      updatedAt: 100,
    ),
  );
}
