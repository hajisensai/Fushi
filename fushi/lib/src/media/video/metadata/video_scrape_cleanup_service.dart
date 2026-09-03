/// 视频刮削记录、生成 sidecar 与兼容封面投影的全局清理边界。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

typedef VideoScrapeArtifactQuarantinedCallback =
    Future<void> Function(String originalPath, String quarantinePath);

typedef VideoScrapeQuarantineRestoreCallback =
    Future<void> Function(String originalPath, String quarantinePath);

typedef VideoScrapeQuarantineRestoreStrategy =
    bool Function(String quarantinePath, String originalPath);

typedef _CreateHardLinkWNative =
    Int32 Function(
      Pointer<Utf16> fileName,
      Pointer<Utf16> existingFileName,
      Pointer<Void> securityAttributes,
    );
typedef _CreateHardLinkWDart =
    int Function(
      Pointer<Utf16> fileName,
      Pointer<Utf16> existingFileName,
      Pointer<Void> securityAttributes,
    );
typedef _MoveFileWNative = Int32 Function(
  Pointer<Utf16> existingFileName,
  Pointer<Utf16> newFileName,
);
typedef _MoveFileWDart = int Function(
  Pointer<Utf16> existingFileName,
  Pointer<Utf16> newFileName,
);
typedef _PosixLinkNative =
    Int32 Function(Pointer<Utf8> existingPath, Pointer<Utf8> newPath);
typedef _PosixLinkDart =
    int Function(Pointer<Utf8> existingPath, Pointer<Utf8> newPath);
typedef _RenameAt2Native = Int32 Function(
  Int32 oldDirectory,
  Pointer<Utf8> oldPath,
  Int32 newDirectory,
  Pointer<Utf8> newPath,
  Uint32 flags,
);
typedef _RenameAt2Dart = int Function(
  int oldDirectory,
  Pointer<Utf8> oldPath,
  int newDirectory,
  Pointer<Utf8> newPath,
  int flags,
);
typedef _RenameExclusiveNative = Int32 Function(
  Pointer<Utf8> oldPath,
  Pointer<Utf8> newPath,
  Uint32 flags,
);
typedef _RenameExclusiveDart = int Function(
  Pointer<Utf8> oldPath,
  Pointer<Utf8> newPath,
  int flags,
);

class VideoScrapeCleanupResult {
  const VideoScrapeCleanupResult({
    required this.clearedRecords,
    required this.clearedSeries,
    required this.deletedGeneratedFiles,
    required this.deletedLegacyCoverFiles,
    required this.protectedGeneratedFiles,
    required this.protectedLegacyCoverFiles,
    required this.missingGeneratedFiles,
  });

  final int clearedRecords;
  final int clearedSeries;
  final int deletedGeneratedFiles;
  final int deletedLegacyCoverFiles;
  final int protectedGeneratedFiles;
  final int protectedLegacyCoverFiles;
  final int missingGeneratedFiles;

  bool get preservedFiles =>
      protectedGeneratedFiles > 0 || protectedLegacyCoverFiles > 0;
}

class VideoScrapeCleanupBusyException implements Exception {
  const VideoScrapeCleanupBusyException();

  @override
  String toString() => 'VideoScrapeCleanupBusyException';
}

/// 隔离实体无法以 no-replace 语义恢复。必须让 SQLite 清理事务回滚，保留
/// artifact ledger / cover pointer 供下一轮恢复，不能把隐藏 quarantine 当成功。
class VideoScrapeCleanupRecoveryException implements Exception {
  const VideoScrapeCleanupRecoveryException({
    required this.originalPath,
    required this.quarantinePath,
  });

  final String originalPath;
  final String quarantinePath;

  @override
  String toString() =>
      'VideoScrapeCleanupRecoveryException($originalPath, $quarantinePath)';
}

/// 只删除有持久化所有权证据的文件；真实视频、字幕、用户 NFO/封面与合集结构均不碰。
class VideoScrapeCleanupService {
  VideoScrapeCleanupService({
    required this.database,
    Directory? coversDirectory,
    this.onArtifactQuarantined,
    this.onBeforeQuarantineRestore,
    this.restoreQuarantineAtomically,
  }) : _coversDirectory = coversDirectory;

  static const Set<String> _imageArtifactKinds = <String>{
    'cover',
    'backdrop',
    'logo',
    'disc',
    'banner',
    'thumb',
    'clearart',
    'landscape',
  };
  static const Set<String> _imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.avif',
  };
  static const Set<CoverOrigin> _protectedCoverOrigins = <CoverOrigin>{
    CoverOrigin.autoFrame,
    CoverOrigin.manual,
    CoverOrigin.scraped,
    CoverOrigin.userScraped,
    CoverOrigin.sidecar,
    CoverOrigin.cleanupPending,
    CoverOrigin.cleanupReplacement,
  };

  final FushiDatabase database;
  final Directory? _coversDirectory;

  /// 测试接缝：生成 artifact 或 legacy 封面已原子摘到隔离名、但尚未验
  /// hash/删除时触发。
  final VideoScrapeArtifactQuarantinedCallback? onArtifactQuarantined;

  /// 测试接缝：恢复隔离实体前触发，用于确定性模拟另一进程抢先创建原路径。
  final VideoScrapeQuarantineRestoreCallback? onBeforeQuarantineRestore;

  /// 测试接缝：返回 false 模拟目标文件系统不支持 no-replace move/hard-link。
  final VideoScrapeQuarantineRestoreStrategy? restoreQuarantineAtomically;

  static _CreateHardLinkWDart? _createHardLinkW;
  static _MoveFileWDart? _moveFileW;
  static _PosixLinkDart? _posixLink;
  static _RenameAt2Dart? _renameAt2;
  static _RenameExclusiveDart? _renameExclusive;

  Future<VideoScrapeCleanupResult> clearAll() async {
    final VideoScrapeOperationLease? lease =
        VideoScrapeOperationGate.tryEnterMaintenance();
    if (lease == null) throw const VideoScrapeCleanupBusyException();
    try {
      final _VideoScrapeCleanupTransactionResult committed = await database
          .transaction(_clearAllExclusive);
      // provenance 只能在 SQLite 成功提交之后清。若 commit 失败，旧标记仍会让
      // 下一次清理识别已删/缺失的 legacy 文件并收敛 coverPath；不会永久失去证据。
      try {
        await committed.coverMetaStore.removeAllWhereOrigin(
          committed.clearAutoScrapedMetaUids,
          CoverOrigin.autoScraped,
        );
        await committed.coverMetaStore.removeAllWhereOrigin(
          committed.clearCleanupPendingMetaUids,
          CoverOrigin.cleanupPending,
        );
      } on Object {
        // DB 指针已经提交为空；残留 autoScraped 标记只会过度保护，后续成功写入
        // 或再次清理即可收敛，不能反向回滚已提交的刮削记录删除。
      }
      return committed.result;
    } finally {
      lease.release();
    }
  }

  Future<_VideoScrapeCleanupTransactionResult> _clearAllExclusive() async {
    if (await database.hasRunningVideoSourceScrapeRun()) {
      throw const VideoScrapeCleanupBusyException();
    }

    // 同事务 marker 先取得 SQLite 写锁；另一进程若启动刮削，其 run insert 会等到
    // 本事务提交后才继续，不会夹在文件清理中间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int markerRunId = await database.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        scope: 'cleanup',
        status: 'clearing',
        startedAt: now,
        updatedAt: now,
      ),
    );

    final List<VideoMetadataWorkRow> works = await database
        .getAllVideoMetadataWorks();
    final List<VideoScrapeMetaRow> videoMeta = await database
        .getAllVideoScrapeMeta();
    final List<CollectionScrapeMetaRow> collectionMeta = await database
        .getAllCollectionScrapeMeta();
    final List<VideoSourceScrapeRunRow> runs = <VideoSourceScrapeRunRow>[
      for (final VideoSourceScrapeRunRow run
          in await database.getVideoSourceScrapeRuns(limit: 1 << 30))
        if (run.id != markerRunId) run,
    ];
    final List<VideoSidecarArtifactRow> artifacts = await database
        .getVideoSidecarArtifacts();
    final Set<int> scrapedCollections = await database
        .aniDbScrapedVideoCollectionIds();
    final Set<String> scrapedBooks = await database.aniDbScrapedVideoBookUids();
    final List<VideoBookRow> books = await database.allVideoBooks();
    final List<MediaCollectionRow> collections = await database
        .getAllMediaCollections();
    final List<MediaImageRow> mediaImages = await database.getAllMediaImages();
    final Map<int, String> legacyScrapedMediaImagePaths = <int, String>{
      for (final CollectionScrapeMetaRow meta in collectionMeta)
        if (meta.backdropPath case final String path when path.isNotEmpty)
          meta.collectionId: path,
    };
    final List<MediaSourceRow> sources = await database.getAllMediaSources();
    final Directory covers = _coversDirectory ?? await VideoStorage.coversDir();
    final CoverMetaStore coverMetaStore = CoverMetaStore(covers);
    final Map<String, CoverMeta> coverMeta = await coverMetaStore.all();

    // 先让 DB 图谱删除完整跑过；若 schema/trigger/FK 失败，尚未触碰磁盘。外层
    // transaction 尚未提交，后续仍可按清理前快照处理文件与封面引用。
    try {
      await database.clearAllVideoScrapeRecords(
        clearLegacyScrapedMediaImagePaths: legacyScrapedMediaImagePaths,
        preserveAllSidecarArtifacts: true,
      );
    } on VideoScrapeRecordsBusyException {
      throw const VideoScrapeCleanupBusyException();
    }

    final Set<String> protectedCoverPathKeys = <String>{
      for (final VideoBookRow book in books)
        if (book.coverPath case final String path
            when _protectedCoverOrigins.contains(
              coverMeta[book.bookUid]?.origin,
            ))
          _pathKey(path),
      // sourceUrl=null 是表级契约中的手动附加图，即使存在陈旧 artifact ledger
      // 也不能按旧 SHA 删除其当前文件。
      for (final MediaImageRow image in mediaImages)
        if (image.sourceUrl == null) _pathKey(image.path),
    };
    final _ArtifactCleanupSummary artifactSummary =
        await _deleteGeneratedArtifacts(
          artifacts,
          <int, MediaSourceRow>{
            for (final MediaSourceRow source in sources) source.id: source,
          },
          protectedMediaPathKeys: _mediaPathKeys(books),
          protectedCoverPathKeys: protectedCoverPathKeys,
        );
    final _LegacyCoverCleanupSummary legacySummary =
        await _deleteLegacyAutoScrapedCovers(
          coverMeta: coverMeta,
          coverMetaStore: coverMetaStore,
          books: books,
          collections: collections,
          covers: covers,
          clearedArtifactPathKeys: artifactSummary.clearedPathKeys,
          protectedArtifactPathKeys: artifactSummary.protectedPathKeys,
        );

    final Map<String, String> clearBookCoverPaths = <String, String>{
      for (final VideoBookRow book in books)
        if (book.coverPath case final String path
            when artifactSummary.clearedPathKeys.contains(_pathKey(path)) &&
                !protectedCoverPathKeys.contains(_pathKey(path)))
          book.bookUid: path,
      ...legacySummary.clearBookCoverPaths,
    };
    final Map<int, String> clearCollectionCoverPaths = <int, String>{
      for (final MediaCollectionRow collection in collections)
        if (collection.coverPath case final String path
            when artifactSummary.clearedPathKeys.contains(_pathKey(path)))
          collection.id: path,
    };
    try {
      await database.clearAllVideoScrapeRecords(
        clearBookCoverPaths: clearBookCoverPaths,
        clearCollectionCoverPaths: clearCollectionCoverPaths,
        clearLegacyScrapedMediaImagePaths: legacyScrapedMediaImagePaths,
        clearSidecarArtifactIds: <int>{
          for (final VideoSidecarArtifactRow artifact in artifacts)
            if (!artifactSummary.protectedArtifactIds.contains(artifact.id))
              artifact.id,
        },
      );
    } on VideoScrapeRecordsBusyException {
      throw const VideoScrapeCleanupBusyException();
    }

    return _VideoScrapeCleanupTransactionResult(
      result: VideoScrapeCleanupResult(
        clearedRecords:
            works.length +
            videoMeta.length +
            collectionMeta.length +
            runs.length +
            artifacts.length - artifactSummary.protectedArtifactIds.length,
        clearedSeries: scrapedCollections.length + scrapedBooks.length,
        deletedGeneratedFiles: artifactSummary.deleted,
        deletedLegacyCoverFiles: legacySummary.deleted,
        protectedGeneratedFiles: artifactSummary.protected,
        protectedLegacyCoverFiles: legacySummary.protected,
        missingGeneratedFiles: artifactSummary.missing,
      ),
      coverMetaStore: coverMetaStore,
      clearAutoScrapedMetaUids: legacySummary.clearAutoScrapedMetaUids,
      clearCleanupPendingMetaUids: legacySummary.clearCleanupPendingMetaUids,
    );
  }

  Future<_ArtifactCleanupSummary> _deleteGeneratedArtifacts(
    Iterable<VideoSidecarArtifactRow> artifacts,
    Map<int, MediaSourceRow> sources, {
    required Set<String> protectedMediaPathKeys,
    required Set<String> protectedCoverPathKeys,
  }) async {
    int deleted = 0;
    int protected = 0;
    int missing = 0;
    final Set<String> clearedPathKeys = <String>{};
    final Set<String> protectedPathKeys = <String>{};
    final Set<int> protectedArtifactIds = <int>{};
    for (final VideoSidecarArtifactRow artifact in artifacts) {
      final String target = p.normalize(p.absolute(artifact.path));
      final String pathKey = _pathKey(target);
      final int? sourceId = artifact.sourceId;
      final MediaSourceRow? source = sourceId == null
          ? null
          : sources[sourceId];
      if (source == null ||
          source.mediaKind != 'video' ||
          source.transport != 'local' ||
          !_isSupportedArtifactPath(artifact.artifactKind, target) ||
          protectedMediaPathKeys.contains(pathKey) ||
          protectedCoverPathKeys.contains(pathKey)) {
        protected++;
        protectedPathKeys.add(pathKey);
        protectedArtifactIds.add(artifact.id);
        continue;
      }

      final _FileDisposition disposition = await _deleteVerifiedArtifact(
        artifact,
        target,
        source.rootPath,
      );
      switch (disposition) {
        case _FileDisposition.deleted:
          deleted++;
          clearedPathKeys.add(pathKey);
          // BUG-1118 的不变量对**删**同样成立：图片一旦从这条路径消失，两个解码
          // 缓存键（FileImage / resizedFileImage）还留着旧位图，书架与详情页会继续
          // 画一张文件已经不在的封面，直到重启。删完立刻双键驱逐。
          if (_imageArtifactKinds.contains(artifact.artifactKind)) {
            await MediaCoverService.applyCoverRemoval(destPath: target);
          }
        case _FileDisposition.missing:
          missing++;
          clearedPathKeys.add(pathKey);
        case _FileDisposition.protected:
        case _FileDisposition.replaced:
          protected++;
          protectedPathKeys.add(pathKey);
          protectedArtifactIds.add(artifact.id);
      }
    }
    return _ArtifactCleanupSummary(
      deleted: deleted,
      protected: protected,
      missing: missing,
      clearedPathKeys: clearedPathKeys,
      protectedPathKeys: protectedPathKeys,
      protectedArtifactIds: protectedArtifactIds,
    );
  }

  Future<_FileDisposition> _deleteVerifiedArtifact(
    VideoSidecarArtifactRow artifact,
    String target,
    String sourceRoot,
  ) async {
    final _FileDisposition? recovered =
        await _recoverVerifiedArtifactQuarantine(artifact, target, sourceRoot);
    if (recovered != null) return recovered;
    for (int attempt = 0; attempt < 6; attempt++) {
      File? quarantine;
      try {
        final FileSystemEntityType type = await FileSystemEntity.type(
          target,
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) {
          return _FileDisposition.missing;
        }
        if (type != FileSystemEntityType.file ||
            !await _isSafeSourceFile(target, sourceRoot)) {
          return _FileDisposition.protected;
        }
        // 先在原路径做一次廉价 fail-closed 校验。用户已经改写的 NFO/图片不应
        // 为了证明“不匹配”而先被藏进 quarantine；这也让不支持 no-replace
        // move/hard-link 的 NAS/可移动介质无需进入恢复路径。
        final String preMoveHash =
            (await sha256.bind(File(target).openRead()).first).toString();
        if (preMoveHash.toLowerCase() != artifact.sha256.toLowerCase()) {
          return _FileDisposition.protected;
        }
        // 先把当前路径原子摘到同目录唯一隔离名，再对被移动的实体验 hash。
        // 即使目标在前一次类型检查后被替换，也只会移动并校验替换物；不匹配会恢复，
        // 不会按旧路径的校验结果删除新文件。
        quarantine = await File(target).rename(_quarantinePath(target));
        await onArtifactQuarantined?.call(target, quarantine.path);
        if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
            FileSystemEntityType.file) {
          await _restoreQuarantine(quarantine, target);
          return _FileDisposition.protected;
        }
        final String currentHash =
            (await sha256.bind(quarantine.openRead()).first).toString();
        if (currentHash.toLowerCase() != artifact.sha256.toLowerCase()) {
          final _QuarantineRestoreResult restore =
              await _restoreQuarantine(quarantine, target);
          if (restore == _QuarantineRestoreResult.targetOccupied) {
            throw VideoScrapeCleanupRecoveryException(
              originalPath: target,
              quarantinePath: quarantine.path,
            );
          }
          return _FileDisposition.protected;
        }
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          // 隔离后出现同路径新文件：旧实体已由 ledger hash 证明可删，但新路径及其
          // DB 指针必须保留。若此处崩溃，确定性 quarantine 会在下一轮按 ledger 恢复。
          await quarantine.delete();
          return _FileDisposition.protected;
        }
        await quarantine.delete();
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return _FileDisposition.protected;
        }
        return _FileDisposition.deleted;
      } on VideoScrapeCleanupRecoveryException {
        rethrow;
      } on Object {
        if (quarantine != null && await quarantine.exists()) {
          final _QuarantineRestoreResult restore =
              await _restoreQuarantine(quarantine, target);
          if (restore == _QuarantineRestoreResult.targetOccupied) {
            throw VideoScrapeCleanupRecoveryException(
              originalPath: target,
              quarantinePath: quarantine.path,
            );
          }
        }
        if (attempt < 5) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    }
    return _FileDisposition.protected;
  }

  /// 恢复上一次进程在 `rename → hash/delete` 窗口退出留下的确定性隔离文件。
  /// 原路径为空时先原样放回再走正常 SHA 校验；原路径已有替换物时，仅在隔离实体
  /// 仍匹配 ledger SHA 时删除旧生成物，并保护当前路径。
  Future<_FileDisposition?> _recoverVerifiedArtifactQuarantine(
    VideoSidecarArtifactRow artifact,
    String target,
    String sourceRoot,
  ) async {
    final File quarantine = File(_quarantinePath(target));
    try {
      final FileSystemEntityType quarantineType = await FileSystemEntity.type(
        quarantine.path,
        followLinks: false,
      );
      if (quarantineType == FileSystemEntityType.notFound) return null;
      if (quarantineType != FileSystemEntityType.file ||
          !await _isSafeSourceFile(target, sourceRoot)) {
        return _FileDisposition.protected;
      }
      final FileSystemEntityType targetType = await FileSystemEntity.type(
        target,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.notFound) {
        final _QuarantineRestoreResult restore =
            await _restoreQuarantine(quarantine, target);
        return restore == _QuarantineRestoreResult.restored
            ? null
            : _FileDisposition.protected;
      }
      final String quarantineHash =
          (await sha256.bind(quarantine.openRead()).first).toString();
      if (quarantineHash.toLowerCase() == artifact.sha256.toLowerCase()) {
        await quarantine.delete();
      } else {
        // q 不是 ledger 证明的旧生成物，极可能是 prehash→rename 窗口内到达的
        // 用户替换物；原路径又已被另一文件占用时不能把它永久藏起来后报成功。
        throw VideoScrapeCleanupRecoveryException(
          originalPath: target,
          quarantinePath: quarantine.path,
        );
      }
      return _FileDisposition.protected;
    } on VideoScrapeCleanupRecoveryException {
      rethrow;
    } on Object {
      return _FileDisposition.protected;
    }
  }

  Future<_LegacyCoverCleanupSummary> _deleteLegacyAutoScrapedCovers({
    required Map<String, CoverMeta> coverMeta,
    required CoverMetaStore coverMetaStore,
    required List<VideoBookRow> books,
    required List<MediaCollectionRow> collections,
    required Directory covers,
    required Set<String> clearedArtifactPathKeys,
    required Set<String> protectedArtifactPathKeys,
  }) async {
    final Map<String, VideoBookRow> booksByUid = <String, VideoBookRow>{
      for (final VideoBookRow book in books) book.bookUid: book,
    };
    final Set<String> retainedReferenceKeys = <String>{
      for (final VideoBookRow book in books)
        if (book.coverPath case final String path
            when !_isLegacyCleanupOrigin(coverMeta[book.bookUid]?.origin))
          _pathKey(path),
      for (final MediaCollectionRow collection in collections)
        if (collection.coverPath case final String path) _pathKey(path),
    };
    int deleted = 0;
    int protected = 0;
    final Map<String, String> clearBookCoverPaths = <String, String>{};
    final Set<String> clearAutoScrapedMetaUids = <String>{};
    final Set<String> clearCleanupPendingMetaUids = <String>{};

    for (final String bookUid in coverMeta.keys.toList(growable: false)) {
      CoverMeta meta = coverMeta[bookUid]!;
      final VideoBookRow? book = booksByUid[bookUid];
      final String? path = book?.coverPath;
      if (path != null &&
          path.isNotEmpty &&
          (meta.origin == CoverOrigin.autoScraped ||
              meta.origin == CoverOrigin.cleanupPending ||
              meta.origin == CoverOrigin.cleanupReplacement)) {
        final _LegacyQuarantineRecovery recovery =
            await _recoverLegacyCoverQuarantine(
              bookUid: bookUid,
              path: path,
              covers: covers,
              coverMetaStore: coverMetaStore,
              origin: meta.origin,
            );
        if (recovery == _LegacyQuarantineRecovery.blocked) {
          if (_isLegacyCleanupOrigin(meta.origin)) protected++;
          continue;
        }
        if (recovery == _LegacyQuarantineRecovery.replacement) {
          if (_isLegacyCleanupOrigin(meta.origin)) protected++;
          coverMeta[bookUid] = const CoverMeta(
            origin: CoverOrigin.cleanupReplacement,
          );
          continue;
        }
      }

      meta = (await coverMetaStore.get(bookUid)) ?? meta;
      if (!_isLegacyCleanupOrigin(meta.origin)) continue;
      if (!_isLegacyCleanupOrigin(
        (await coverMetaStore.get(bookUid))?.origin,
      )) {
        protected++;
        continue;
      }
      if (book == null || path == null || path.isEmpty) {
        _recordLegacyMetaClear(
          bookUid,
          meta.origin,
          clearAutoScrapedMetaUids,
          clearCleanupPendingMetaUids,
        );
        continue;
      }
      final String pathKey = _pathKey(path);
      if (clearedArtifactPathKeys.contains(pathKey)) {
        clearBookCoverPaths[bookUid] = path;
        _recordLegacyMetaClear(
          bookUid,
          meta.origin,
          clearAutoScrapedMetaUids,
          clearCleanupPendingMetaUids,
        );
        continue;
      }
      if (retainedReferenceKeys.contains(pathKey) ||
          protectedArtifactPathKeys.contains(pathKey)) {
        try {
          await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
          coverMeta[bookUid] = const CoverMeta(
            origin: CoverOrigin.cleanupReplacement,
          );
        } on Object {
          // 保留旧标记与文件；下一次清理仍会 fail closed 重试。
        }
        protected++;
        continue;
      }
      final _FileDisposition disposition = await _deleteLegacyCover(
        bookUid: bookUid,
        path: path,
        covers: covers,
        coverMetaStore: coverMetaStore,
        meta: meta,
      );
      switch (disposition) {
        case _FileDisposition.protected:
          protected++;
          continue;
        case _FileDisposition.replaced:
          coverMeta[bookUid] = const CoverMeta(
            origin: CoverOrigin.cleanupReplacement,
          );
          protected++;
          continue;
        case _FileDisposition.deleted:
          deleted++;
          // 同上（BUG-1118 的删侧）：旧自动封面的位图已解码在内存里，不驱逐就会
          // 在清理后继续显示一张不存在的图。
          await MediaCoverService.applyCoverRemoval(destPath: path);
          break;
        case _FileDisposition.missing:
          break;
      }
      clearBookCoverPaths[bookUid] = path;
      _recordLegacyMetaClear(
        bookUid,
        (await coverMetaStore.get(bookUid))?.origin ?? meta.origin,
        clearAutoScrapedMetaUids,
        clearCleanupPendingMetaUids,
      );
    }
    return _LegacyCoverCleanupSummary(
      deleted: deleted,
      protected: protected,
      clearBookCoverPaths: clearBookCoverPaths,
      clearAutoScrapedMetaUids: clearAutoScrapedMetaUids,
      clearCleanupPendingMetaUids: clearCleanupPendingMetaUids,
    );
  }

  Future<_LegacyQuarantineRecovery> _recoverLegacyCoverQuarantine({
    required String bookUid,
    required String path,
    required Directory covers,
    required CoverMetaStore coverMetaStore,
    required CoverOrigin origin,
  }) async {
    final String target = p.normalize(p.absolute(path));
    final String root = p.normalize(p.absolute(covers.path));
    if (!p.equals(p.dirname(target), root) ||
        !_imageExtensions.contains(p.extension(target).toLowerCase())) {
      return _LegacyQuarantineRecovery.blocked;
    }
    final File quarantine = File(_quarantinePath(target));
    try {
      final FileSystemEntityType quarantineType = await FileSystemEntity.type(
        quarantine.path,
        followLinks: false,
      );
      if (quarantineType == FileSystemEntityType.notFound) {
        return _LegacyQuarantineRecovery.none;
      }
      if (quarantineType != FileSystemEntityType.file ||
          !await _hasResolvedParent(target, root)) {
        return _LegacyQuarantineRecovery.blocked;
      }
      final FileSystemEntityType targetType = await FileSystemEntity.type(
        target,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.notFound) {
        // rename 前后文件可能被替换：隔离摘要不匹配并不能证明 q 是旧生成物。
        // 原路径为空时必须先原样恢复，再由正常删除路径做 expected/current CAS；
        // 否则用户替换物会永久隐藏在 suffix 下。
        final _QuarantineRestoreResult restore =
            await _restoreQuarantine(quarantine, target);
        if (restore == _QuarantineRestoreResult.restored) {
          return _LegacyQuarantineRecovery.restored;
        }
        // targetOccupied：继续走下方 q 摘要校验，把旧生成物与晚到替换物收敛。
      }
      final CoverMeta? current = await coverMetaStore.get(bookUid);
      final String? expectedHash = current?.contentSha256;
      if (expectedHash == null) {
        return _LegacyQuarantineRecovery.blocked;
      }
      final String quarantineHash =
          (await sha256.bind(quarantine.openRead()).first).toString();
      if (quarantineHash.toLowerCase() != expectedHash.toLowerCase()) {
        throw VideoScrapeCleanupRecoveryException(
          originalPath: target,
          quarantinePath: quarantine.path,
        );
      }
      if (origin == CoverOrigin.cleanupReplacement) {
        await quarantine.delete();
        return _LegacyQuarantineRecovery.replacement;
      }
      await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
      await quarantine.delete();
      return _LegacyQuarantineRecovery.replacement;
    } on VideoScrapeCleanupRecoveryException {
      rethrow;
    } on Object {
      return _LegacyQuarantineRecovery.blocked;
    }
  }

  Future<_FileDisposition> _deleteLegacyCover({
    required String bookUid,
    required String path,
    required Directory covers,
    required CoverMetaStore coverMetaStore,
    required CoverMeta meta,
  }) async {
    final String target = p.normalize(p.absolute(path));
    final String root = p.normalize(p.absolute(covers.path));
    if (!p.equals(p.dirname(target), root) ||
        !_imageExtensions.contains(p.extension(target).toLowerCase())) {
      return _FileDisposition.protected;
    }
    for (int attempt = 0; attempt < 6; attempt++) {
      File? quarantine;
      try {
        final FileSystemEntityType type = await FileSystemEntity.type(
          target,
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) {
          return _FileDisposition.missing;
        }
        if (type != FileSystemEntityType.file ||
            !await _hasResolvedParent(target, root)) {
          return _FileDisposition.protected;
        }
        final String currentHash =
            (await sha256.bind(File(target).openRead()).first).toString();
        String? expectedHash = meta.contentSha256;
        if (meta.origin == CoverOrigin.autoScraped) {
          // 旧版本只记 autoScraped 来源、没有内容摘要。不能在清理当下对“当前文件”
          // 现算 hash 再把它自证成生成物：用户可能早已在同路径原地替换海报。
          // 无历史证据一律 fail closed，并把它转成长期保护态。
          if (expectedHash == null) {
            await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
            return _FileDisposition.replaced;
          }
          if (currentHash.toLowerCase() != expectedHash.toLowerCase()) {
            await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
            return _FileDisposition.replaced;
          }
          final bool marked = await coverMetaStore
              .markAutoScrapedCleanupPending(bookUid, expectedHash);
          if (!marked) return _FileDisposition.protected;
        }
        if (expectedHash == null ||
            currentHash.toLowerCase() != expectedHash.toLowerCase()) {
          await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
          return _FileDisposition.replaced;
        }
        quarantine = await File(target).rename(_quarantinePath(target));
        await onArtifactQuarantined?.call(target, quarantine.path);
        if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
            FileSystemEntityType.file) {
          await _restoreQuarantine(quarantine, target);
          return _FileDisposition.protected;
        }
        final String movedHash =
            (await sha256.bind(quarantine.openRead()).first).toString();
        if (movedHash.toLowerCase() != expectedHash.toLowerCase()) {
          final _QuarantineRestoreResult restore =
              await _restoreQuarantine(quarantine, target);
          if (restore == _QuarantineRestoreResult.targetOccupied) {
            throw VideoScrapeCleanupRecoveryException(
              originalPath: target,
              quarantinePath: quarantine.path,
            );
          }
          await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
          return _FileDisposition.replaced;
        }
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
          await quarantine.delete();
          return _FileDisposition.replaced;
        }
        await quarantine.delete();
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await coverMetaStore.protectLegacyCleanupReplacement(bookUid);
          return _FileDisposition.replaced;
        }
        return _FileDisposition.deleted;
      } on VideoScrapeCleanupRecoveryException {
        rethrow;
      } on Object {
        if (quarantine != null && await quarantine.exists()) {
          final _QuarantineRestoreResult restore =
              await _restoreQuarantine(quarantine, target);
          if (restore == _QuarantineRestoreResult.targetOccupied) {
            throw VideoScrapeCleanupRecoveryException(
              originalPath: target,
              quarantinePath: quarantine.path,
            );
          }
        }
        if (attempt < 5) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    }
    return _FileDisposition.protected;
  }

  /// 确定性名称让进程在 rename 后退出时，下一轮能从 ledger/cleanupPending
  /// 恢复同一实体；maintenance + source-root admission 保证 app 内不会并发占用。
  static String _quarantinePath(String target) =>
      '$target.fushi-scrape-cleanup';

  Future<_QuarantineRestoreResult> _restoreQuarantine(
    File quarantine,
    String target,
  ) async {
    try {
      if (await FileSystemEntity.type(quarantine.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('quarantine is not a regular file');
      }
      await onBeforeQuarantineRestore?.call(target, quarantine.path);
      // 先用平台原生 no-replace move（覆盖 exFAT/SMB 等不支持 hard-link 的介质），
      // 再以 hard-link create-if-absent 兜底。两者都失败时抛出，让外层 SQLite
      // transaction 回滚并保留 ledger/pointer，绝不能把隐藏 q 当成普通 protected。
      final bool restored = restoreQuarantineAtomically?.call(
            quarantine.path,
            target,
          ) ??
          await _moveOrLinkNoReplace(quarantine, target);
      if (restored) {
        return _QuarantineRestoreResult.restored;
      }
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return _QuarantineRestoreResult.targetOccupied;
      }
      throw VideoScrapeCleanupRecoveryException(
        originalPath: target,
        quarantinePath: quarantine.path,
      );
    } on VideoScrapeCleanupRecoveryException {
      rethrow;
    } on Object {
      throw VideoScrapeCleanupRecoveryException(
        originalPath: target,
        quarantinePath: quarantine.path,
      );
    }
  }

  static Future<bool> _moveOrLinkNoReplace(
    File quarantine,
    String target,
  ) async {
    if (_moveFileNoReplace(quarantine.path, target)) return true;
    if (!_createHardLinkIfAbsent(quarantine.path, target)) return false;
    try {
      await quarantine.delete();
      return true;
    } on Object {
      // target 与 q 此时是同一 inode；保留两者并让事务回滚，下一轮可安全收敛。
      return false;
    }
  }

  static bool _moveFileNoReplace(String existingPath, String newPath) {
    try {
      if (Platform.isWindows) {
        final _MoveFileWDart moveFile = _moveFileW ??= DynamicLibrary.open(
          'kernel32.dll',
        ).lookupFunction<_MoveFileWNative, _MoveFileWDart>('MoveFileW');
        final Pointer<Utf16> existingPointer = existingPath.toNativeUtf16();
        final Pointer<Utf16> newPointer = newPath.toNativeUtf16();
        try {
          return moveFile(existingPointer, newPointer) != 0;
        } finally {
          calloc.free(existingPointer);
          calloc.free(newPointer);
        }
      }

      final Pointer<Utf8> existingPointer = existingPath.toNativeUtf8();
      final Pointer<Utf8> newPointer = newPath.toNativeUtf8();
      try {
        if (Platform.isLinux || Platform.isAndroid) {
          const int atCurrentWorkingDirectory = -100;
          const int renameNoReplace = 1;
          final _RenameAt2Dart renameAt2 = _renameAt2 ??= DynamicLibrary.process()
              .lookupFunction<_RenameAt2Native, _RenameAt2Dart>('renameat2');
          return renameAt2(
                atCurrentWorkingDirectory,
                existingPointer,
                atCurrentWorkingDirectory,
                newPointer,
                renameNoReplace,
              ) ==
              0;
        }
        if (Platform.isMacOS || Platform.isIOS) {
          const int renameExclusive = 0x00000004;
          final _RenameExclusiveDart renameExclusiveCall =
              _renameExclusive ??= DynamicLibrary.process().lookupFunction<
                _RenameExclusiveNative,
                _RenameExclusiveDart
              >('renamex_np');
          return renameExclusiveCall(
                existingPointer,
                newPointer,
                renameExclusive,
              ) ==
              0;
        }
      } finally {
        calloc.free(existingPointer);
        calloc.free(newPointer);
      }
    } on Object {
      return false;
    }
    return false;
  }

  static bool _createHardLinkIfAbsent(String existingPath, String newPath) {
    try {
      if (Platform.isWindows) {
        final _CreateHardLinkWDart createHardLink = _createHardLinkW ??=
            DynamicLibrary.open(
              'kernel32.dll',
            ).lookupFunction<_CreateHardLinkWNative, _CreateHardLinkWDart>(
              'CreateHardLinkW',
            );
        final Pointer<Utf16> newPathPointer = newPath.toNativeUtf16();
        final Pointer<Utf16> existingPathPointer = existingPath.toNativeUtf16();
        try {
          return createHardLink(newPathPointer, existingPathPointer, nullptr) !=
              0;
        } finally {
          calloc.free(newPathPointer);
          calloc.free(existingPathPointer);
        }
      }

      final _PosixLinkDart link = _posixLink ??= DynamicLibrary.process()
          .lookupFunction<_PosixLinkNative, _PosixLinkDart>('link');
      final Pointer<Utf8> existingPathPointer = existingPath.toNativeUtf8();
      final Pointer<Utf8> newPathPointer = newPath.toNativeUtf8();
      try {
        return link(existingPathPointer, newPathPointer) == 0;
      } finally {
        calloc.free(existingPathPointer);
        calloc.free(newPathPointer);
      }
    } on Object {
      return false;
    }
  }

  static bool _isSupportedArtifactPath(String kind, String target) {
    final String extension = p.extension(target).toLowerCase();
    if (kind == 'nfo') return extension == '.nfo';
    return _imageArtifactKinds.contains(kind) &&
        _imageExtensions.contains(extension);
  }

  static bool _isLegacyCleanupOrigin(CoverOrigin? origin) =>
      origin == CoverOrigin.autoScraped || origin == CoverOrigin.cleanupPending;

  static void _recordLegacyMetaClear(
    String bookUid,
    CoverOrigin origin,
    Set<String> clearAutoScrapedMetaUids,
    Set<String> clearCleanupPendingMetaUids,
  ) {
    if (origin == CoverOrigin.cleanupPending) {
      clearCleanupPendingMetaUids.add(bookUid);
    } else if (origin == CoverOrigin.autoScraped) {
      clearAutoScrapedMetaUids.add(bookUid);
    }
  }

  static Future<bool> _isSafeSourceFile(
    String target,
    String sourceRoot,
  ) async {
    try {
      final Directory root = Directory(p.normalize(p.absolute(sourceRoot)));
      if (!await root.exists()) return false;
      final Directory parent = Directory(p.dirname(target));
      if (!await parent.exists()) return false;
      final String realRoot = p.normalize(await root.resolveSymbolicLinks());
      final String realParent = p.normalize(
        await parent.resolveSymbolicLinks(),
      );
      return p.equals(realRoot, realParent) || p.isWithin(realRoot, realParent);
    } on Object {
      return false;
    }
  }

  static Future<bool> _hasResolvedParent(String target, String root) async {
    try {
      final String realRoot = p.normalize(
        await Directory(root).resolveSymbolicLinks(),
      );
      final String realParent = p.normalize(
        await Directory(p.dirname(target)).resolveSymbolicLinks(),
      );
      return p.equals(realRoot, realParent);
    } on Object {
      return false;
    }
  }

  static Set<String> _mediaPathKeys(Iterable<VideoBookRow> books) {
    final Set<String> result = <String>{};
    for (final VideoBookRow book in books) {
      if (!_isRemotePath(book.videoPath)) result.add(_pathKey(book.videoPath));
      final String? playlistJson = book.playlistJson;
      if (playlistJson == null || playlistJson.isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(playlistJson);
        if (decoded is! List<Object?>) continue;
        for (final Object? value in decoded) {
          if (value is! Map<String, Object?>) continue;
          final Object? path = value['path'];
          if (path is String && path.isNotEmpty && !_isRemotePath(path)) {
            result.add(_pathKey(path));
          }
        }
      } on FormatException {
        // 损坏 playlist 仍至少由 videoPath 护住；清理不因用户旧数据而中断。
      }
    }
    return result;
  }

  static bool _isRemotePath(String value) {
    final Uri? uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static String _pathKey(String value) {
    final String normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

enum _FileDisposition { deleted, missing, protected, replaced }

enum _LegacyQuarantineRecovery { none, restored, replacement, blocked }

enum _QuarantineRestoreResult { restored, targetOccupied }

class _ArtifactCleanupSummary {
  const _ArtifactCleanupSummary({
    required this.deleted,
    required this.protected,
    required this.missing,
    required this.clearedPathKeys,
    required this.protectedPathKeys,
    required this.protectedArtifactIds,
  });

  final int deleted;
  final int protected;
  final int missing;
  final Set<String> clearedPathKeys;
  final Set<String> protectedPathKeys;
  final Set<int> protectedArtifactIds;
}

class _LegacyCoverCleanupSummary {
  const _LegacyCoverCleanupSummary({
    required this.deleted,
    required this.protected,
    required this.clearBookCoverPaths,
    required this.clearAutoScrapedMetaUids,
    required this.clearCleanupPendingMetaUids,
  });

  final int deleted;
  final int protected;
  final Map<String, String> clearBookCoverPaths;
  final Set<String> clearAutoScrapedMetaUids;
  final Set<String> clearCleanupPendingMetaUids;
}

class _VideoScrapeCleanupTransactionResult {
  const _VideoScrapeCleanupTransactionResult({
    required this.result,
    required this.coverMetaStore,
    required this.clearAutoScrapedMetaUids,
    required this.clearCleanupPendingMetaUids,
  });

  final VideoScrapeCleanupResult result;
  final CoverMetaStore coverMetaStore;
  final Set<String> clearAutoScrapedMetaUids;
  final Set<String> clearCleanupPendingMetaUids;
}
