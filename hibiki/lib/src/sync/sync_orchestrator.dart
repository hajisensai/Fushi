import 'dart:io';

import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// Reserved top-level folder (under the backend root) that holds dictionary
/// packages. It lives alongside the per-book folders, so every place that
/// treats root children as *books* must skip it ([isReservedSyncFolderName]).
const String kSyncDictionaryNamespace = '__dictionaries__';

/// Asset file name (inside a book's folder) holding the audiobook package
/// (audio + subtitles + cues + alignment), produced by
/// [SyncAssetPackageService.exportAudioDatabasePackage].
const String kSyncAudiobookAssetName = 'audiobook.hibikiaudio';

const String _dictionaryAssetSuffix = '.hibikidict';

/// Reserved top-level folder holding local-audio source packages (pronunciation
/// DB + config manifest), alongside the dictionary namespace and per-book
/// folders. Must be filtered from any listing that treats root children as
/// books ([isReservedSyncFolderName]).
const String kSyncLocalAudioNamespace = '__local_audio__';

const String _localAudioAssetSuffix = '.hibikiaudiolib';

/// True for reserved folder names that are NOT books and must be filtered from
/// any listing of book folders (compare dialog, remote-book import).
bool isReservedSyncFolderName(String name) =>
    name == kSyncDictionaryNamespace || name == kSyncLocalAudioNamespace;

/// One sync item judged a genuine fork (both sides moved off the common-ancestor
/// baseline) and therefore skipped instead of auto-resolved. Carries everything
/// a later resolution prompt needs, including both versions so [fingerprint] can
/// dedup re-surfacing of the same conflict.
class SyncConflict {
  SyncConflict({
    required this.assetKey,
    required this.dimension,
    required this.title,
    this.localVersion,
    this.remoteVersion,
  });

  final String assetKey;
  final String dimension;
  final String title;
  final int? localVersion;
  final int? remoteVersion;

  /// 去重指纹：资产+维度+两端版本。两端任一版本变化即视为新冲突。
  String get fingerprint => '$assetKey|$dimension|$localVersion|$remoteVersion';
}

/// Tally of what one orchestrated run transferred. `errors` collects per-item
/// failures that were skipped without aborting the whole run. `conflicts`
/// collects items judged a genuine fork and skipped without auto-resolving —
/// they are neither failures nor transfers, so they never feed `booksImported`
/// nor `errors`.
class SyncRunReport {
  int booksImported = 0;
  int dictionariesImported = 0;
  int dictionariesExported = 0;
  int audiobooksImported = 0;
  int audiobooksExported = 0;
  int localAudioImported = 0;
  int localAudioExported = 0;
  final List<String> errors = <String>[];
  final List<SyncConflict> conflicts = <SyncConflict>[];
}

/// Bidirectional, union-based sync across any [SyncBackend].
///
/// Layers the three previously-missing capabilities on top of the existing
/// per-book [SyncManager] (progress / stats / content / audiobook position),
/// which is left unchanged:
///   1. import remote-only books (download EPUB → [EpubImporter] → local row);
///   2. dictionary packages (push/pull in the `__dictionaries__` namespace);
///   3. audiobook packages (push/pull `audiobook.hibikiaudio` per book folder).
///
/// Sync is an additive union: present-on-one-side ⇒ copy to the other. Deletes
/// are never propagated. Large immutable assets (EPUB / audiobook / dictionary)
/// are skipped when already present on the far side.
class SyncOrchestrator {
  SyncOrchestrator({
    required HibikiDatabase db,
    required SyncBackend backend,
    required Directory dictionaryResourceRoot,
    required Directory audioDatabaseRoot,
    required Directory tempDir,
    required this.syncStats,
    required this.syncAudioBookPosition,
    required this.syncContent,
    required this.syncAudioBookFiles,
    required this.syncDictionary,
    required this.syncLocalAudio,
    this.localAudioEntries = const <LocalAudioDbEntry>[],
    this.onLocalAudioImported,
    this.statsSyncMode = StatisticsSyncMode.merge,
    this.onProgress,
  })  : _db = db,
        _backend = backend,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _audioDatabaseRoot = audioDatabaseRoot,
        _tempDir = tempDir,
        _packages = SyncAssetPackageService(db: db);

  final HibikiDatabase _db;
  final SyncBackend _backend;
  final Directory _dictionaryResourceRoot;
  final Directory _audioDatabaseRoot;
  final Directory _tempDir;
  final SyncAssetPackageService _packages;

  final bool syncStats;
  final bool syncAudioBookPosition;
  final bool syncContent;
  final bool syncAudioBookFiles;
  final bool syncDictionary;

  /// 是否同步本地音频来源（DB 文件 + 配置）。orchestrator 不依赖 AppModel：导出用的
  /// 条目列表由 [localAudioEntries] 注入，导入注册经 [onLocalAudioImported] 回调。
  final bool syncLocalAudio;
  final List<LocalAudioDbEntry> localAudioEntries;
  final Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported;
  final StatisticsSyncMode statsSyncMode;

  /// Optional progress sink (manual sync only). Null for background auto-sync,
  /// which keeps its old silent behaviour.
  final SyncProgressCallback? onProgress;

  void _emit(
    SyncPhase phase, {
    required int itemIndex,
    required int itemTotal,
    String? title,
    double? fileFraction,
  }) {
    final cb = onProgress;
    if (cb == null) return;
    cb(SyncProgress(
      phase: phase,
      itemIndex: itemIndex,
      itemTotal: itemTotal,
      title: title,
      fileFraction: fileFraction,
    ));
  }

  int _tmpCounter = 0;

  File _tmpFile(String suffix) {
    _tmpCounter++;
    return File(p.join(_tempDir.path, 'hibiki_sync_$_tmpCounter$suffix'));
  }

  /// Runs the full bidirectional sweep. Order matters: remote books are
  /// imported first so the subsequent [SyncManager] sweep and audiobook pull
  /// see them as local books.
  Future<SyncRunReport> run() async {
    final SyncRunReport report = SyncRunReport();
    final String root = await _backend.findOrCreateRootFolder();

    if (syncContent) {
      await importRemoteBooks(root, report);
    }

    // Existing per-book progress / stats / content / audiobook-position sync
    // for every local book (now including any just-imported remote books).
    int readingDone = 0;
    int readingTotal = 0;
    String? readingTitle;
    final List<SyncBookResult> bookResults = await SyncManager(
      db: _db,
      backend: _backend,
      onContentProgress: (double f) => _emit(SyncPhase.readingData,
          itemIndex: readingDone,
          itemTotal: readingTotal,
          title: readingTitle,
          fileFraction: f),
    ).syncAllBooks(
      syncStats: syncStats,
      statsSyncMode: statsSyncMode,
      syncAudioBook: syncAudioBookPosition,
      syncContent: syncContent,
      onBookProgress: (int done, int total, String title) {
        readingDone = done;
        readingTotal = total;
        readingTitle = title;
        _emit(SyncPhase.readingData,
            itemIndex: done, itemTotal: total, title: title);
      },
    );
    _collectConflicts(bookResults, report);

    if (syncDictionary) await syncDictionaries(report);
    if (syncLocalAudio) await syncLocalAudioPackages(report);
    if (syncAudioBookFiles) await syncAudiobookPackages(root, report);

    return report;
  }

  /// Folds the per-book sweep results into [SyncRunReport.conflicts]. Only
  /// [SyncResult.conflict] rows are collected; everything else (imported /
  /// exported / synced / skipped) is left to the existing per-phase tallies
  /// and is NOT counted here. A conflict carries the four fields filled by
  /// [SyncManager] when it detects a genuine three-way fork.
  void _collectConflicts(
    List<SyncBookResult> results,
    SyncRunReport report,
  ) {
    for (final SyncBookResult result in results) {
      if (result.direction != SyncResult.conflict) continue;
      report.conflicts.add(SyncConflict(
        assetKey: result.conflictAssetKey!,
        dimension: result.conflictDimension!,
        title: result.title,
        localVersion: result.conflictLocalVersion,
        remoteVersion: result.conflictRemoteVersion,
      ));
    }
  }

  /// Downloads and imports books that exist on the backend but not locally
  /// (matched by sanitized title). Requires the remote book folder to carry a
  /// `.epub` content asset; folders without one (sender had content sync off)
  /// are skipped.
  Future<void> importRemoteBooks(String root, SyncRunReport report) async {
    final List<DriveFile> remoteFolders = await _backend.listBooks(root);
    final Set<String> localKeys = <String>{
      for (final EpubBookRow b in await _db.getAllEpubBooks())
        sanitizeTtuFilename(b.title),
    };

    // Resolve the remote-only set first so progress has a real denominator.
    final List<DriveFile> toImport = <DriveFile>[
      for (final DriveFile folder in remoteFolders)
        if (!isReservedSyncFolderName(folder.name) &&
            !isReservedSyncFolderName(sanitizeTtuFilename(folder.name)) &&
            !localKeys.contains(sanitizeTtuFilename(folder.name)))
          folder,
    ];
    final int total = toImport.length;

    for (int i = 0; i < total; i++) {
      final DriveFile folder = toImport[i];
      _emit(SyncPhase.books,
          itemIndex: i, itemTotal: total, title: folder.name);
      try {
        if (await importRemoteBookFolder(
          db: _db,
          backend: _backend,
          folderId: folder.id,
          tempDir: _tempDir,
          onProgress: (double f) => _emit(SyncPhase.books,
              itemIndex: i,
              itemTotal: total,
              title: folder.name,
              fileFraction: f),
        )) {
          report.booksImported++;
        }
      } catch (e) {
        report.errors.add('import book "${folder.name}": $e');
      }
    }
  }

  /// Union-syncs dictionary packages in the `__dictionaries__` namespace.
  Future<void> syncDictionaries(SyncRunReport report) async {
    final String ns = await _backend.ensureNamespace(kSyncDictionaryNamespace);
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && e.name.endsWith(_dictionaryAssetSuffix))
          e.name.substring(0, e.name.length - _dictionaryAssetSuffix.length),
    };
    final Set<String> localNames = <String>{
      for (final DictionaryMetaRow d in localDicts) d.name,
    };

    // Resolve both sides' work first so progress has a real denominator.
    final List<DictionaryMetaRow> toPush = <DictionaryMetaRow>[
      for (final DictionaryMetaRow d in localDicts)
        if (!remoteNames.contains(d.name)) d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      for (final AssetEntry e in remote)
        if (!e.isFolder &&
            e.name.endsWith(_dictionaryAssetSuffix) &&
            !localNames.contains(e.name
                .substring(0, e.name.length - _dictionaryAssetSuffix.length)))
          e,
    ];
    final int total = toPush.length + toPull.length;
    int index = 0;

    // Push local-only dictionaries.
    for (final DictionaryMetaRow d in toPush) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: d.name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: d.name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await _backend.putAsset(ns, '${d.name}$_dictionaryAssetSuffix', tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: d.name,
                fileFraction: f));
        report.dictionariesExported++;
      } catch (e) {
        report.errors.add('export dictionary "${d.name}": $e');
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // Pull remote-only dictionaries.
    for (final AssetEntry e in toPull) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: e.name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _backend.getAsset(e.id, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: e.name,
                fileFraction: f));
        await _packages.importDictionaryPackage(
          packageFile: tmp,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
        report.dictionariesImported++;
      } catch (err) {
        report.errors.add('import dictionary "${e.name}": $err');
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }

  /// Union-syncs local audio source DBs in the `__local_audio__` namespace.
  /// 资产名 = displayName（[LocalAudioDbEntry.path] 含本机时间戳，每机不同不可用）。
  /// push 本地独有（displayName 不在远端）/ pull 远端独有（displayName 不在本地）。
  ///
  /// 已知限制：displayName 无唯一约束，撞名按「同一库」union 跳过（与词典按 name
  /// 同语义）；真正的唯一性去重列为 follow-up。
  Future<void> syncLocalAudioPackages(SyncRunReport report) async {
    final String ns = await _backend.ensureNamespace(kSyncLocalAudioNamespace);
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && e.name.endsWith(_localAudioAssetSuffix))
          e.name.substring(0, e.name.length - _localAudioAssetSuffix.length),
    };
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };

    // Resolve both sides' work first so progress has a real denominator. The
    // push side also drops libraries whose DB file is gone (nothing to send).
    final List<LocalAudioDbEntry> toPush = <LocalAudioDbEntry>[
      for (final LocalAudioDbEntry d in localAudioEntries)
        if (!remoteNames.contains(d.displayName) && File(d.path).existsSync())
          d,
    ];
    final List<AssetEntry> toPull = <AssetEntry>[
      for (final AssetEntry e in remote)
        if (!e.isFolder &&
            e.name.endsWith(_localAudioAssetSuffix) &&
            !localNames.contains(e.name
                .substring(0, e.name.length - _localAudioAssetSuffix.length)))
          e,
    ];
    final int total = toPush.length + toPull.length;
    int index = 0;

    // Push local-only.
    for (final LocalAudioDbEntry d in toPush) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: d.displayName);
      final File dbFile = File(d.path);
      File? tmp;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _packages.exportLocalAudioPackage(
          displayName: d.displayName,
          enabled: d.enabled,
          sources: d.sources,
          dbFile: dbFile,
          outputFile: tmp,
        );
        await _backend.putAsset(
            ns, '${d.displayName}$_localAudioAssetSuffix', tmp,
            onProgress: (double f) => _emit(SyncPhase.localAudio,
                itemIndex: index,
                itemTotal: total,
                title: d.displayName,
                fileFraction: f));
        report.localAudioExported++;
      } catch (e) {
        report.errors.add('export local audio "${d.displayName}": $e');
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    // Pull remote-only.
    for (final AssetEntry e in toPull) {
      _emit(SyncPhase.localAudio,
          itemIndex: index, itemTotal: total, title: e.name);
      File? tmp;
      // Staging .db extracted from the package. AppModel.importSyncedLocalAudioDb
      // *copies* it into the library dir (never moves), so the staging copy
      // (potentially hundreds of MB) must be deleted here — otherwise every
      // pulled library leaks one .db into the OS temp dir.
      File? stagingDb;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _backend.getAsset(e.id, tmp,
            onProgress: (double f) => _emit(SyncPhase.localAudio,
                itemIndex: index,
                itemTotal: total,
                title: e.name,
                fileFraction: f));
        final LocalAudioPackageContents contents =
            await _packages.importLocalAudioPackage(
          packageFile: tmp,
          stagingDir: _tempDir,
        );
        stagingDb = contents.dbFile;
        if (onLocalAudioImported != null) {
          await onLocalAudioImported!(contents);
          report.localAudioImported++;
        }
      } catch (err) {
        report.errors.add('import local audio "${e.name}": $err');
      } finally {
        _safeDelete(tmp);
        _safeDelete(stagingDb);
      }
      index++;
    }
  }

  /// Union-syncs the audiobook package (`audiobook.hibikiaudio`) inside each
  /// book's folder. A book missing its audiobook locally but present remotely
  /// is pulled; a book with a local audiobook absent remotely is pushed.
  Future<void> syncAudiobookPackages(String root, SyncRunReport report) async {
    // A real "files transferred" denominator would need a findAsset network
    // round-trip per book before the loop; instead progress is keyed on the
    // book scan (k/N books), with the large pull/push fraction blended into the
    // current book's slot. The bar still advances monotonically.
    final List<EpubBookRow> books = await _db.getAllEpubBooks();
    final int total = books.length;
    for (int i = 0; i < total; i++) {
      final EpubBookRow book = books[i];
      _emit(SyncPhase.audiobooks,
          itemIndex: i, itemTotal: total, title: book.title);
      File? tmp;
      try {
        final String bookKey = book.bookKey;
        final AudiobookRow? ab = await _db.getAudiobookByBookKey(bookKey);
        final SrtBookRow? srt = await _db.getSrtBookByBookKey(bookKey);
        final bool hasLocal = ab != null && srt != null;

        final String folderId = await _backend.ensureBookFolder(
          bookTitle: book.title,
          rootFolderId: root,
        );
        final AssetEntry? existing =
            await _backend.findAsset(folderId, kSyncAudiobookAssetName);

        if (hasLocal && existing == null) {
          tmp = _tmpFile('.hibikiaudio');
          await _packages.exportAudioDatabasePackage(
            bookKey: bookKey,
            srtBookUid: srt.uid,
            outputFile: tmp,
          );
          await _backend.putAsset(folderId, kSyncAudiobookAssetName, tmp,
              onProgress: (double f) => _emit(SyncPhase.audiobooks,
                  itemIndex: i,
                  itemTotal: total,
                  title: book.title,
                  fileFraction: f));
          report.audiobooksExported++;
        } else if (!hasLocal && existing != null) {
          tmp = _tmpFile('.hibikiaudio');
          await _backend.getAsset(existing.id, tmp,
              onProgress: (double f) => _emit(SyncPhase.audiobooks,
                  itemIndex: i,
                  itemTotal: total,
                  title: book.title,
                  fileFraction: f));
          // Re-key to THIS device's book: bind the package to our resolved
          // local bookKey so the synced audiobook/cues/srt link to our book.
          await _packages.importAudioDatabasePackage(
            packageFile: tmp,
            audioDatabaseRoot: _audioDatabaseRoot,
            bookKeyOverride: bookKey,
          );
          report.audiobooksImported++;
        }
      } catch (e) {
        report.errors.add('audiobook "${book.title}": $e');
      } finally {
        _safeDelete(tmp);
      }
    }
  }

  void _safeDelete(File? f) {
    if (f == null) return;
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // Best-effort temp cleanup.
    }
  }
}

/// 下载远端书文件夹 [folderId] 里的 `.epub` 内容资产并导入为本地书。
/// 返回 true=导入成功；false=该文件夹没有 `.epub`（发送方关了内容同步，跳过）。
/// 传输/导入失败时抛出，交调用方决定如何提示。临时文件用后即删。
Future<bool> importRemoteBookFolder({
  required HibikiDatabase db,
  required SyncBackend backend,
  required String folderId,
  required Directory tempDir,
  void Function(double fraction)? onProgress,
}) async {
  final List<AssetEntry> children = await backend.listChildren(folderId);
  AssetEntry? epub;
  for (final AssetEntry e in children) {
    if (!e.isFolder && e.name.toLowerCase().endsWith('.epub')) {
      epub = e;
      break;
    }
  }
  if (epub == null) return false;

  tempDir.createSync(recursive: true);
  final File tmp = File(p.join(
    tempDir.path,
    'hibiki_remote_${DateTime.now().microsecondsSinceEpoch}.epub',
  ));
  try {
    await backend.getAsset(epub.id, tmp, onProgress: onProgress);
    await EpubImporter.importFromPath(
      db: db,
      filePath: tmp.path,
      fileName: epub.name,
    );
    return true;
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}
