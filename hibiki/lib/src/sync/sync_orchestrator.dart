import 'dart:io';

import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
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

/// True for reserved folder names that are NOT books and must be filtered from
/// any listing of book folders (compare dialog, remote-book import).
bool isReservedSyncFolderName(String name) => name == kSyncDictionaryNamespace;

/// Tally of what one orchestrated run transferred. `errors` collects per-item
/// failures that were skipped without aborting the whole run.
class SyncRunReport {
  int booksImported = 0;
  int dictionariesImported = 0;
  int dictionariesExported = 0;
  int audiobooksImported = 0;
  int audiobooksExported = 0;
  final List<String> errors = <String>[];
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
    this.statsSyncMode = StatisticsSyncMode.merge,
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
  final StatisticsSyncMode statsSyncMode;

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
    await SyncManager(db: _db, backend: _backend).syncAllBooks(
      syncStats: syncStats,
      statsSyncMode: statsSyncMode,
      syncAudioBook: syncAudioBookPosition,
      syncContent: syncContent,
    );

    if (syncDictionary) await syncDictionaries(report);
    if (syncAudioBookFiles) await syncAudiobookPackages(root, report);

    return report;
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

    for (final DriveFile folder in remoteFolders) {
      if (isReservedSyncFolderName(folder.name)) continue;
      final String key = sanitizeTtuFilename(folder.name);
      if (isReservedSyncFolderName(key) || localKeys.contains(key)) continue;

      File? tmp;
      try {
        final List<AssetEntry> children =
            await _backend.listChildren(folder.id);
        AssetEntry? epub;
        for (final AssetEntry e in children) {
          if (!e.isFolder && e.name.toLowerCase().endsWith('.epub')) {
            epub = e;
            break;
          }
        }
        if (epub == null) continue;

        tmp = _tmpFile('.epub');
        await _backend.getAsset(epub.id, tmp);
        await EpubImporter.importFromPath(
          db: _db,
          filePath: tmp.path,
          fileName: epub.name,
        );
        report.booksImported++;
      } catch (e) {
        report.errors.add('import book "${folder.name}": $e');
      } finally {
        _safeDelete(tmp);
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

    // Push local-only dictionaries.
    for (final DictionaryMetaRow d in localDicts) {
      if (remoteNames.contains(d.name)) continue;
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: d.name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await _backend.putAsset(ns, '${d.name}$_dictionaryAssetSuffix', tmp);
        report.dictionariesExported++;
      } catch (e) {
        report.errors.add('export dictionary "${d.name}": $e');
      } finally {
        _safeDelete(tmp);
      }
    }

    // Pull remote-only dictionaries.
    for (final AssetEntry e in remote) {
      if (e.isFolder || !e.name.endsWith(_dictionaryAssetSuffix)) continue;
      final String base =
          e.name.substring(0, e.name.length - _dictionaryAssetSuffix.length);
      if (localNames.contains(base)) continue;
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _backend.getAsset(e.id, tmp);
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
    }
  }

  /// Union-syncs the audiobook package (`audiobook.hibikiaudio`) inside each
  /// book's folder. A book missing its audiobook locally but present remotely
  /// is pulled; a book with a local audiobook absent remotely is pushed.
  Future<void> syncAudiobookPackages(String root, SyncRunReport report) async {
    for (final EpubBookRow book in await _db.getAllEpubBooks()) {
      File? tmp;
      try {
        final String bookUid = buildLegacyBookUid(book.id);
        final AudiobookRow? ab = await _db.getAudiobookByBookUid(bookUid);
        final SrtBookRow? srt = await _db.getSrtBookByTtuBookId(book.id);
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
            bookUid: bookUid,
            srtBookUid: srt.uid,
            outputFile: tmp,
          );
          await _backend.putAsset(folderId, kSyncAudiobookAssetName, tmp);
          report.audiobooksExported++;
        } else if (!hasLocal && existing != null) {
          tmp = _tmpFile('.hibikiaudio');
          await _backend.getAsset(existing.id, tmp);
          await _packages.importAudioDatabasePackage(
            packageFile: tmp,
            audioDatabaseRoot: _audioDatabaseRoot,
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
