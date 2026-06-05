import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// Rewrites an absolute [oldPath] that lives under [oldRoot] so it lives under
/// [newRoot] instead, preserving the sub-path. Returns [oldPath] verbatim when
/// it is not under [oldRoot] (already local, or an unrelated location).
///
/// A full-data backup stores file paths captured on the SOURCE device. On the
/// importing device the app directories differ (iOS reassigns the container
/// UUID on every reinstall), so the stored absolute paths would not resolve.
/// Import rebases every stored path from the backup's recorded root to this
/// device's matching root. Separators are normalized so `/` vs `\` differences
/// between the compared strings don't defeat the prefix match.
String rebasePath(String oldPath, String oldRoot, String newRoot) {
  String stripTrailing(String s) =>
      (s.endsWith('/') || s.endsWith('\\')) ? s.substring(0, s.length - 1) : s;
  // Normalize separators ONLY for the prefix comparison; the returned path
  // keeps the source path's original separators (a POSIX backup restored on a
  // POSIX host must not gain Windows separators just because p.join would, and
  // vice-versa). So we slice the original oldPath rather than rebuild via join.
  final String nrOld = stripTrailing(oldRoot.replaceAll('\\', '/'));
  final String npOld = oldPath.replaceAll('\\', '/');
  if (npOld == nrOld) return stripTrailing(newRoot);
  // Require a separator boundary so "/a/books_extra" is not treated as under
  // "/a/books". replaceAll preserves length, so nrOld.length indexes the
  // original oldPath correctly.
  if (!npOld.startsWith('$nrOld/')) return oldPath;
  final String suffix = oldPath.substring(nrOld.length); // keeps leading sep
  return stripTrailing(newRoot) + suffix;
}

class BackupMeta {
  BackupMeta({
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.bookCount,
    required this.statsCount,
    this.booksRoot,
    this.audiobooksRoot,
  });

  final String appVersion;
  final int schemaVersion;
  final DateTime createdAt;
  final int bookCount;
  final int statsCount;

  /// Absolute root of the extracted-books tree on the SOURCE device
  /// (`<appDoc>/hoshi_books`), captured so import can rebase stored book paths
  /// to this device's root. Null for legacy (db-only) backups → import skips
  /// path rebasing.
  final String? booksRoot;

  /// Absolute root of the audiobook-audio tree on the SOURCE device
  /// (`<appDoc>/audiobooks`). Null for legacy backups.
  final String? audiobooksRoot;

  Map<String, dynamic> toJson() => {
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'bookCount': bookCount,
        'statsCount': statsCount,
        if (booksRoot != null) 'booksRoot': booksRoot,
        if (audiobooksRoot != null) 'audiobooksRoot': audiobooksRoot,
      };

  factory BackupMeta.fromJson(Map<String, dynamic> json) => BackupMeta(
        appVersion: json['appVersion'] as String,
        schemaVersion: json['schemaVersion'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        // Optional for backward compatibility with older backups.
        bookCount: json['bookCount'] as int? ?? 0,
        statsCount: json['statsCount'] as int? ?? 0,
        booksRoot: json['booksRoot'] as String?,
        audiobooksRoot: json['audiobooksRoot'] as String?,
      );

  static BackupMeta? tryParse(String source) {
    try {
      return BackupMeta.fromJson(
        jsonDecode(source) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}

class BackupService {
  BackupService({
    required HibikiDatabase db,
    required String dbDirectory,
    required String appVersion,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
  })  : _db = db,
        _dbDirectory = dbDirectory,
        _dictionaryResourceDirectory = dictionaryResourceDirectory,
        _booksRootDirectory = booksRootDirectory,
        _audiobooksRootDirectory = audiobooksRootDirectory,
        _appVersion = appVersion;

  final HibikiDatabase _db;
  final String _dbDirectory;
  final String? _dictionaryResourceDirectory;

  /// Root of the extracted-books tree (`<appDoc>/hoshi_books`). When provided,
  /// the full book content (epub + extracted html/images/fonts + covers) is
  /// packed into the backup; null keeps the legacy db-only export.
  final String? _booksRootDirectory;

  /// Root of the audiobook-audio tree (`<appDoc>/audiobooks`). When provided,
  /// audio files are packed into the backup.
  final String? _audiobooksRootDirectory;

  final String _appVersion;

  static const String _dbName = 'hibiki.db';
  static const String _metaName = 'backup_meta.json';
  static const String _dictionaryResourcesPrefix = 'dictionaryResources';
  static const String _booksPrefix = 'hoshi_books';
  static const String _audiobooksPrefix = 'audiobooks';

  /// Sidecar file holding this device's sync config across an import. Written
  /// BEFORE the destructive DB overwrite so a crash mid-import is recoverable
  /// (a startup sweep re-applies it). Deleted once the import completes.
  static const String _preserveSidecar = 'hibiki.db.sync-preserve.json';

  String get _dbPath => p.join(_dbDirectory, _dbName);

  /// Create a backup ZIP file at [outputPath].
  Future<BackupMeta> exportBackup(String outputPath) async {
    final tmpDir = await Directory.systemTemp.createTemp('hibiki_backup_');
    try {
      final cleanDbPath = p.join(tmpDir.path, _dbName);
      try {
        final safePath =
            cleanDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
        await _db.customStatement("VACUUM INTO '$safePath'");
      } catch (e, st) {
        // HBK-AUDIT-028: do NOT swallow the VACUUM INTO failure. The original
        // reason (disk full, locked, read-only temp, unsupported SQLite) is
        // the only diagnostic we have, so surface it before falling back.
        debugPrint('BackupService: VACUUM INTO failed, '
            'falling back to checkpoint+copy: $e\n$st');
        // Best-effort fallback: flush the WAL into the main DB file, then copy.
        // A raw copy of a still-open WAL database cannot be made fully torn-free
        // from Dart (that needs the SQLite C backup API or a closed DB); the
        // TRUNCATE checkpoint substantially reduces the window. We do an extra
        // PASSIVE checkpoint after the truncate to flush any frames committed
        // between the two awaits before reading bytes.
        await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
        await _db.customStatement('PRAGMA wal_checkpoint(PASSIVE)');
        await File(_dbPath).copy(cleanDbPath);
      }

      // Strip sync credentials from the copy before it leaves the device.
      // The backup ZIP is shared/saved anywhere the user picks, and the
      // preferences table holds OAuth refresh tokens and FTP/SFTP/WebDAV/SMB/
      // server passwords (base64 = encoding, not encryption). VACUUM after the
      // delete so the secrets are not recoverable from freelist pages.
      // (HBK-AUDIT-012)
      final Directory? dictionaryResourceRoot =
          _dictionaryResourceDirectory == null
              ? null
              : Directory(_dictionaryResourceDirectory);
      // Full-data backup includes dictionary resources whenever they exist on
      // disk — no longer gated on dictionary-sync being enabled (the user asked
      // for everything). Still strip dictionary DB rows when the resource files
      // are absent, so the restore never resurrects un-queryable ghost
      // dictionaries.
      final bool includeDictionary =
          await _hasCompleteDictionaryResources(dictionaryResourceRoot);
      await _stripCredentials(tmpDir.path);
      if (!includeDictionary) {
        await _stripDictionaryState(tmpDir.path);
      }

      final books = await _db.getAllEpubBooks();
      final stats = await _db.getAllReadingStatistics();

      // Record the SOURCE-device content roots so import can rebase the stored
      // absolute paths (epubPath/extractDir/coverPath/audioRoot/...) onto the
      // importing device's roots. Null roots → legacy db-only backup.
      final meta = BackupMeta(
        appVersion: _appVersion,
        schemaVersion: _db.schemaVersion,
        createdAt: DateTime.now(),
        bookCount: books.length,
        statsCount: stats.length,
        booksRoot: _booksRootDirectory,
        audiobooksRoot: _audiobooksRootDirectory,
      );

      // Build the flat "zip-path → disk-path" map, then stream every file into
      // the ZIP off the UI isolate. The old path read each file fully into a
      // single in-memory Archive and ran a synchronous ZipEncoder().encode() on
      // the UI isolate — that froze the app (ANR) on any non-trivial library.
      final Map<String, String> files = <String, String>{
        _dbName: cleanDbPath,
      };
      if (includeDictionary) {
        await _collectTreeFiles(
            dictionaryResourceRoot!, _dictionaryResourcesPrefix, files);
      }
      if (_booksRootDirectory != null) {
        await _collectTreeFiles(
            Directory(_booksRootDirectory), _booksPrefix, files);
      }
      if (_audiobooksRootDirectory != null) {
        await _collectTreeFiles(
            Directory(_audiobooksRootDirectory), _audiobooksPrefix, files);
      }

      final String metaJson =
          const JsonEncoder.withIndent('  ').convert(meta.toJson());
      await _writeBackupZipInIsolate(
        outputPath: outputPath,
        metaName: _metaName,
        metaJson: metaJson,
        archivePathToSource: files,
      );

      return meta;
    } finally {
      if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
    }
  }

  /// Strips device-local sync config from the standalone DB copy in
  /// [dbDirectory] before it leaves the device. Opened via [HibikiDatabase]
  /// (the copy is already at the current schema, so no migration runs).
  ///
  /// Two layers, both required:
  /// 1. [SyncRepository.deviceLocalPrefKeys] — the single source of truth for
  ///    "what stays on this device": backend choice, credentials, server config
  ///    AND server addresses / usernames / Hibiki client URLs. None of these
  ///    belong in a shareable backup — a backup that leaks your NAS address,
  ///    username or LAN/DDNS topology is a privacy hole. On import these are
  ///    preserved from the local DB, so stripping them here is symmetric.
  /// 2. A `sync_%` secret-shaped LIKE sweep — a future-proof catch-all so a
  ///    newly added credential key is stripped even before it's added to the
  ///    preserve list. (A test asserts every secret-shaped key is also in the
  ///    preserve list, so the catch-all never strips something import wouldn't
  ///    restore.)
  ///
  /// VACUUM + checkpoint so values are not recoverable from freelist/WAL pages.
  static Future<void> _stripCredentials(String dbDirectory) async {
    final db = HibikiDatabase(dbDirectory);
    try {
      await (db.delete(db.preferences)
            ..where((t) => t.key.isIn(SyncRepository.deviceLocalPrefKeys)))
          .go();
      await db.customStatement(
        "DELETE FROM preferences WHERE key LIKE 'sync_%password%'"
        " OR key LIKE 'sync_%token%' OR key LIKE 'sync_%secret%'"
        " OR key LIKE 'sync_%private_key%'"
        " OR key = 'sync_desktop_credentials'",
      );
      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Removes dictionary rows from the exported DB copy when dictionary sync is
  /// disabled. Keeping DB metadata without matching `dictionaryResources/`
  /// files would restore ghost dictionaries that cannot be queried.
  static Future<void> _stripDictionaryState(String dbDirectory) async {
    final db = HibikiDatabase(dbDirectory);
    try {
      await db.clearDictionaryHistory();
      await db.clearAllDictionaryMeta();
      await db.customStatement('VACUUM');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Validate a backup ZIP. Returns metadata if valid.
  ///
  /// Streams the central directory via [InputFileStream] instead of reading the
  /// whole archive into memory — a full-data backup can be many GB (book + audio
  /// trees), so there is no size cap and the whole file must never be buffered.
  /// Only the small `backup_meta.json` entry is decompressed; the db presence
  /// check is metadata-only.
  Future<BackupMeta?> validateBackup(String zipPath) async {
    InputFileStream? input;
    try {
      input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeBuffer(input);
      final metaFile = archive.findFile(_metaName);
      if (metaFile == null) return null;
      final metaJson = utf8.decode(metaFile.content as List<int>);
      final meta = BackupMeta.tryParse(metaJson);
      if (meta == null) return null;
      if (archive.findFile(_dbName) == null) return null;
      return meta;
    } catch (_) {
      return null;
    } finally {
      await input?.close();
    }
  }

  /// Settings-layer tables restored from THIS device when [importBackupFiles]
  /// runs with importSettings=false. Order matters: `profiles` first (FK target
  /// of the rest). `preferences` is handled separately (audiobook positions are
  /// content and follow the backup). No content table FKs into these, and
  /// `book_profiles.bookUid` is plain text, so a wholesale swap is FK-safe.
  static const List<String> _settingsLayerTables = <String>[
    'profiles',
    'profile_settings',
    'media_type_profiles',
    'book_profiles',
  ];

  /// Import a backup, replacing the current database files.
  ///
  /// This is a static method because the database must already be closed
  /// before calling — the caller is responsible for closing the DB first.
  ///
  /// [importSettings] (default true = full restore):
  /// - true: everything comes from the backup, EXCEPT device-local sync config
  ///   ([SyncRepository.deviceLocalPrefKeys]) which is always preserved (the
  ///   backup has none — they're stripped on export — so a naive swap would log
  ///   you out). Re-applied immediately; crash-recoverable via the sidecar.
  /// - false: keep THIS device's settings layer (preferences + profiles +
  ///   bindings = fonts/appearance/reading/profiles); only CONTENT comes from
  ///   the backup. Done inline: opening the imported DB migrates it to the
  ///   current schema, then the settings layer is copied back from
  ///   pre-restore.bak (both at current schema → column-aligned, FK-safe). The
  ///   sidecar + bak written before the overwrite are a crash-recovery net so
  ///   [recoverPendingImport] can finish the restore if this crashes mid-way.
  static Future<void> importBackupFiles({
    required String dbDirectory,
    required String zipPath,
    bool importSettings = true,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
  }) async {
    final dbPath = p.join(dbDirectory, _dbName);
    // Stream the central directory instead of buffering the whole (GB-scale)
    // archive in memory. Each entry's bytes are read lazily on `.content`; the
    // stream stays open until every read completes (closed in `finally`).
    final InputFileStream input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final dbFile = archive.findFile(_dbName);
      if (dbFile == null) throw StateError('No $_dbName in backup archive');

      // Parse the source-device content roots so book/audio paths can be
      // rebased onto this device after the trees are restored.
      BackupMeta? meta;
      final ArchiveFile? metaFile = archive.findFile(_metaName);
      if (metaFile != null) {
        meta = BackupMeta.tryParse(utf8.decode(metaFile.content as List<int>));
      }

      final String? dictionaryRestoreDirectory = dictionaryResourceDirectory;
      List<MapEntry<ArchiveFile, String>>? dictionaryRestorePlan;
      if (dictionaryRestoreDirectory != null) {
        dictionaryRestorePlan = _buildDictionaryRestorePlan(
          archive: archive,
          dictionaryResourceDirectory: dictionaryRestoreDirectory,
        );
      }

      final sidecar = File(p.join(dbDirectory, _preserveSidecar));
      final String bakPath = '$dbPath.pre-restore.bak';
      final currentDb = File(dbPath);
      final bool haveCurrent = currentDb.existsSync();

      // 1) Snapshot the current DB (crash safety) + record what to preserve.
      //    Skipped on a fresh install (no current DB) → backup applied verbatim,
      //    so the toggle is moot there.
      Map<String, String> preservedSync = const <String, String>{};
      if (haveCurrent) {
        if (importSettings) {
          preservedSync = await _readDeviceLocalPrefs(dbDirectory);
          if (preservedSync.isNotEmpty) {
            await sidecar.writeAsString(jsonEncode(
                <String, dynamic>{'mode': 'prefs', 'prefs': preservedSync}));
          }
        } else {
          await sidecar
              .writeAsString(jsonEncode(<String, dynamic>{'mode': 'settings'}));
        }
        await currentDb.copy(bakPath);
      }

      // Must delete -wal/-shm AFTER reading prefs (step 1 opened+closed a WAL
      // connection) and BEFORE overwriting the main .db: leftover WAL frames
      // from the old DB would otherwise be replayed against the imported file
      // and corrupt it.
      final walFile = File('$dbPath-wal');
      if (walFile.existsSync()) await walFile.delete();
      final shmFile = File('$dbPath-shm');
      if (shmFile.existsSync()) await shmFile.delete();

      // 2) Overwrite with the backup DB bytes.
      await currentDb.writeAsBytes(dbFile.content as List<int>);

      if (dictionaryRestorePlan != null && dictionaryRestoreDirectory != null) {
        await _restoreDictionaryResources(
          restorePlan: dictionaryRestorePlan,
          dictionaryResourceDirectory: dictionaryRestoreDirectory,
        );
      }

      // 2b) Restore the book + audiobook content trees (full-data backup).
      //     Atomic-swap per tree: write to a sibling temp dir, then rename over
      //     the old tree — a mid-way failure leaves the existing tree intact
      //     (a user's whole library must never be half-destroyed). Only runs
      //     when the caller supplies the roots AND the backup carries that tree.
      if (booksRootDirectory != null) {
        await _restoreTreeAtomic(
          archive: archive,
          prefix: _booksPrefix,
          targetRootPath: booksRootDirectory,
        );
      }
      if (audiobooksRootDirectory != null) {
        await _restoreTreeAtomic(
          archive: archive,
          prefix: _audiobooksPrefix,
          targetRootPath: audiobooksRootDirectory,
        );
      }

      // 3) Restore what must stay on this device — inline, not deferred to
      //    startup, so the common path never depends on bak surviving a restart.
      if (importSettings) {
        // Re-apply device-local sync config (preferences is schema-stable).
        if (preservedSync.isNotEmpty) {
          await _applyPreservedConfig(dbDirectory, preservedSync);
        }
      } else if (haveCurrent) {
        // Keep this device's whole settings layer.
        await _restoreSettingsLayer(dbDirectory);
      }

      // 3b) Rebase the imported DB's stored absolute paths (which point at the
      //     SOURCE device's roots) onto this device's roots. Books/audiobooks
      //     are content, so they come from the backup in BOTH import modes →
      //     always rebase. No-op for a legacy backup (meta has no roots).
      if (meta != null) {
        await _rebaseContentPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newBooksRoot: booksRootDirectory,
          newAudiobooksRoot: audiobooksRootDirectory,
        );
      }

      // 4) Success: drop the sidecar and the pre-restore copy (no disk leak).
      await _safeDelete(sidecar.path);
      await _safeDelete(bakPath);
    } finally {
      await input.close();
    }
  }

  /// Finish a pending import at startup, before any sync code reads prefs.
  /// Handles both: (a) re-applying device-local sync prefs if a full-restore
  /// import crashed mid-way; (b) restoring this device's settings layer for a
  /// keep-settings import. No-op when no sidecar is present.
  static Future<void> recoverPendingImport(String dbDirectory) async {
    final sidecar = File(p.join(dbDirectory, _preserveSidecar));
    if (!sidecar.existsSync()) return;
    try {
      final raw = await sidecar.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['mode'] == 'settings') {
        await _restoreSettingsLayer(dbDirectory);
      } else {
        // 'prefs' mode, or a legacy bare-map sidecar (no 'mode' field).
        final Map<String, dynamic> prefsRaw =
            (decoded['prefs'] as Map<String, dynamic>?) ?? decoded;
        final prefs = prefsRaw.map((k, v) => MapEntry(k, v as String));
        if (prefs.isNotEmpty) await _applyPreservedConfig(dbDirectory, prefs);
      }
    } catch (e, st) {
      // Corrupt sidecar: drop it rather than blocking startup forever.
      debugPrint('BackupService.recoverPendingImport failed: $e\n$st');
    }
    await _safeDelete(sidecar.path);
    await _safeDelete(p.join(dbDirectory, '$_dbName.pre-restore.bak'));
  }

  /// Restores the settings layer (preferences + profiles + bindings) from
  /// pre-restore.bak into the freshly-imported DB, keeping the backup's content.
  /// Runs at startup, so both DBs are at the current schema → `SELECT *` columns
  /// align. audiobook positions are content and stay from the backup.
  static Future<void> _restoreSettingsLayer(String dbDirectory) async {
    final String bakPath = p.join(dbDirectory, '$_dbName.pre-restore.bak');
    if (!File(bakPath).existsSync()) {
      // bak is the only copy of this device's settings layer (the main DB was
      // already overwritten with the backup). If it's gone we cannot restore —
      // surface it loudly rather than silently dropping the user's settings.
      // (Normal flow restores inline while bak definitely exists; reaching here
      // means a crash + external deletion of bak before the next launch.)
      debugPrint('BackupService._restoreSettingsLayer: pre-restore.bak missing '
          '— local settings/profiles could not be preserved on import.');
      return;
    }
    final db = HibikiDatabase(dbDirectory);
    try {
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      await db.customStatement("ATTACH DATABASE '$safeBak' AS bak");
      await db.transaction(() async {
        // preferences: keep local settings, but let audiobook positions (per
        // book content) follow the imported books.
        await db.customStatement(
            "DELETE FROM preferences WHERE key NOT LIKE 'audiobook_pos_%'");
        await db.customStatement(
            'INSERT INTO preferences SELECT * FROM bak.preferences '
            "WHERE key NOT LIKE 'audiobook_pos_%'");
        // profiles before its FK dependents.
        for (final String t in _settingsLayerTables) {
          await db.customStatement('DELETE FROM $t');
          await db.customStatement('INSERT INTO $t SELECT * FROM bak.$t');
        }
      });
      await db.customStatement('DETACH DATABASE bak');
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Reads the device-local sync prefs (only the keys in
  /// [SyncRepository.deviceLocalPrefKeys]) from the DB in [dbDirectory].
  static Future<Map<String, String>> _readDeviceLocalPrefs(
      String dbDirectory) async {
    HibikiDatabase? db;
    try {
      db = HibikiDatabase(dbDirectory);
      final all = await db.getAllPrefs();
      final out = <String, String>{};
      for (final key in SyncRepository.deviceLocalPrefKeys) {
        final value = all[key];
        if (value != null) out[key] = value;
      }
      return out;
    } catch (e, st) {
      // Current DB unreadable/corrupt: nothing to preserve. Import the backup
      // as-is rather than aborting — a broken local DB shouldn't block restore.
      debugPrint('BackupService._readDeviceLocalPrefs failed: $e\n$st');
      return const <String, String>{};
    } finally {
      try {
        await db?.close();
      } catch (_) {/* db may have failed to open */}
    }
  }

  /// Writes the preserved device-local [prefs] into the imported DB, clears the
  /// stale (backup-origin) folder cache so the next sync rebuilds it against the
  /// preserved backend account, then durably flushes.
  static Future<void> _applyPreservedConfig(
      String dbDirectory, Map<String, String> prefs) async {
    final db = HibikiDatabase(dbDirectory);
    try {
      for (final entry in prefs.entries) {
        await db.setPref(entry.key, entry.value);
      }
      // The imported DB carries the BACKUP's folder cache (title → source
      // account folder ids), which is wrong for the preserved local backend.
      await SyncRepository(db).clearFolderCache();
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Walks [root] and adds every file to [into] keyed by its zip path
  /// (`<archivePrefix>/<relative>`, always posix separators). Does not read file
  /// contents — only paths — so it is cheap regardless of tree size.
  static Future<void> _collectTreeFiles(
    Directory root,
    String archivePrefix,
    Map<String, String> into,
  ) async {
    if (!await root.exists()) return;
    await for (final FileSystemEntity entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final String relativePath = p.relative(entity.path, from: root.path);
      final String archivePath =
          p.posix.join(archivePrefix, relativePath.replaceAll(r'\', '/'));
      into[archivePath] = entity.path;
    }
  }

  /// Streams every file in [archivePathToSource] into a ZIP at [outputPath] on a
  /// background isolate, plus [metaJson] as [metaName]. Uses STORE (no deflate):
  /// epub/audio are already compressed and a full library can be GB-scale, so
  /// streaming-store keeps memory flat and the UI isolate free. A mid-way
  /// failure deletes the half-written archive so it is never mistaken for valid.
  static Future<void> _writeBackupZipInIsolate({
    required String outputPath,
    required String metaName,
    required String metaJson,
    required Map<String, String> archivePathToSource,
  }) async {
    await Isolate.run(() async {
      final ZipFileEncoder encoder = ZipFileEncoder();
      encoder.create(outputPath);
      try {
        final List<int> metaBytes = utf8.encode(metaJson);
        encoder
            .addArchiveFile(ArchiveFile(metaName, metaBytes.length, metaBytes));
        for (final MapEntry<String, String> entry
            in archivePathToSource.entries) {
          final File file = File(entry.value);
          if (!file.existsSync()) continue;
          await encoder.addFile(file, entry.key, ZipFileEncoder.STORE);
        }
        encoder.closeSync();
      } catch (_) {
        encoder.closeSync();
        try {
          final File partial = File(outputPath);
          if (partial.existsSync()) partial.deleteSync();
        } catch (_) {
          // best-effort cleanup; rethrow the real export failure below.
        }
        rethrow;
      }
    });
  }

  Future<bool> _hasCompleteDictionaryResources(Directory? root) async {
    if (root == null || !await root.exists()) return false;
    final List<DictionaryMetaRow> dictionaries =
        await _db.getAllDictionaryMetadata();
    if (dictionaries.isEmpty) return false;
    for (final DictionaryMetaRow dictionary in dictionaries) {
      final Directory dictionaryDir = Directory(
        p.join(root.path, dictionary.name),
      );
      if (!await _directoryHasFiles(dictionaryDir)) return false;
    }
    return true;
  }

  static Future<bool> _directoryHasFiles(Directory directory) async {
    if (!await directory.exists()) return false;
    await for (final FileSystemEntity entity
        in directory.list(recursive: true)) {
      if (entity is File) return true;
    }
    return false;
  }

  static List<ArchiveFile> _dictionaryResourceFiles(Archive archive) {
    return archive.files.where((ArchiveFile file) {
      if (!file.isFile) return false;
      return file.name
          .replaceAll(r'\', '/')
          .startsWith('$_dictionaryResourcesPrefix/');
    }).toList();
  }

  static List<MapEntry<ArchiveFile, String>> _buildDictionaryRestorePlan({
    required Archive archive,
    required String dictionaryResourceDirectory,
  }) {
    final Directory targetRoot = Directory(dictionaryResourceDirectory);
    final String canonicalRoot = p.canonicalize(targetRoot.path);
    final List<MapEntry<ArchiveFile, String>> restorePlan =
        <MapEntry<ArchiveFile, String>>[];
    for (final ArchiveFile file in _dictionaryResourceFiles(archive)) {
      final String rawName = file.name.replaceAll(r'\', '/');
      final String relativePath =
          rawName.substring(_dictionaryResourcesPrefix.length + 1);
      final String normalizedRelative = p.posix.normalize(relativePath);
      if (relativePath.isEmpty ||
          p.posix.isAbsolute(relativePath) ||
          normalizedRelative == '..' ||
          normalizedRelative.startsWith('../')) {
        throw FormatException('Invalid dictionary resource path: ${file.name}');
      }

      final String targetPath = p.normalize(
        p.join(targetRoot.path, normalizedRelative),
      );
      final String canonicalTarget = p.canonicalize(targetPath);
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        throw FormatException('Invalid dictionary resource path: ${file.name}');
      }
      restorePlan.add(MapEntry<ArchiveFile, String>(file, targetPath));
    }
    return restorePlan;
  }

  static Future<void> _restoreDictionaryResources({
    required List<MapEntry<ArchiveFile, String>> restorePlan,
    required String dictionaryResourceDirectory,
  }) async {
    final Directory targetRoot = Directory(dictionaryResourceDirectory);
    if (await targetRoot.exists()) {
      await targetRoot.delete(recursive: true);
    }
    await targetRoot.create(recursive: true);
    for (final MapEntry<ArchiveFile, String> entry in restorePlan) {
      final File targetFile = File(entry.value);
      targetFile.parent.createSync(recursive: true);
      await targetFile.writeAsBytes(
        entry.key.content as List<int>,
        flush: true,
      );
    }
  }

  /// Files in [archive] under `<prefix>/`, validated against path traversal and
  /// mapped to absolute targets under [targetRootPath]. Mirrors the dictionary
  /// plan's safety checks (reject absolute / `..` escapes, `p.isWithin` gate).
  static List<MapEntry<ArchiveFile, String>> _buildTreeRestorePlan({
    required Archive archive,
    required String prefix,
    required String targetRootPath,
  }) {
    final Directory targetRoot = Directory(targetRootPath);
    final String canonicalRoot = p.canonicalize(targetRoot.path);
    final List<MapEntry<ArchiveFile, String>> plan =
        <MapEntry<ArchiveFile, String>>[];
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String rawName = file.name.replaceAll(r'\', '/');
      if (!rawName.startsWith('$prefix/')) continue;
      final String relativePath = rawName.substring(prefix.length + 1);
      final String normalizedRelative = p.posix.normalize(relativePath);
      if (relativePath.isEmpty ||
          p.posix.isAbsolute(relativePath) ||
          normalizedRelative == '..' ||
          normalizedRelative.startsWith('../')) {
        throw FormatException('Invalid backup content path: ${file.name}');
      }
      final String targetPath =
          p.normalize(p.join(targetRoot.path, normalizedRelative));
      final String canonicalTarget = p.canonicalize(targetPath);
      if (canonicalTarget != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalTarget)) {
        throw FormatException('Invalid backup content path: ${file.name}');
      }
      plan.add(MapEntry<ArchiveFile, String>(file, targetPath));
    }
    return plan;
  }

  /// Restores a content tree (`<prefix>/…`) from [archive] to [targetRootPath]
  /// with an atomic-ish swap so a failure never half-destroys the existing tree:
  /// write every file into a sibling `…​.import-tmp`, then rename the old tree
  /// aside, rename tmp into place, and delete the old tree. A write failure
  /// drops only the temp dir and leaves the existing tree untouched.
  ///
  /// No-op when the backup carries no files under [prefix] (e.g. a db-only or
  /// audio-less backup) so an empty prefix never wipes the device's tree.
  static Future<void> _restoreTreeAtomic({
    required Archive archive,
    required String prefix,
    required String targetRootPath,
  }) async {
    final String tmpRoot = '$targetRootPath.import-tmp';
    final List<MapEntry<ArchiveFile, String>> plan = _buildTreeRestorePlan(
      archive: archive,
      prefix: prefix,
      targetRootPath: tmpRoot,
    );
    if (plan.isEmpty) return;

    final Directory tmpDir = Directory(tmpRoot);
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    await tmpDir.create(recursive: true);
    try {
      for (final MapEntry<ArchiveFile, String> entry in plan) {
        final File dest = File(entry.value);
        dest.parent.createSync(recursive: true);
        await dest.writeAsBytes(entry.key.content as List<int>, flush: true);
      }
    } catch (_) {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      rethrow; // existing tree untouched
    }

    // Swap. tmp and target are siblings (same parent) → rename is atomic on the
    // same filesystem.
    final String asideRoot = '$targetRootPath.import-old';
    final Directory aside = Directory(asideRoot);
    final Directory target = Directory(targetRootPath);
    if (await aside.exists()) await aside.delete(recursive: true);
    if (await target.exists()) await target.rename(asideRoot);
    try {
      await tmpDir.rename(targetRootPath);
    } catch (_) {
      // Roll back: put the old tree back if the new one didn't land.
      if (await aside.exists() && !await target.exists()) {
        await aside.rename(targetRootPath);
      }
      rethrow;
    }
    if (await aside.exists()) await aside.delete(recursive: true);
  }

  /// Rebases the imported DB's stored absolute content paths from the backup's
  /// source roots ([BackupMeta.booksRoot] / [BackupMeta.audiobooksRoot]) onto
  /// this device's [newBooksRoot] / [newAudiobooksRoot]. No-op for a legacy
  /// backup (meta has no roots). Cover paths can live under EITHER tree (epub
  /// covers in hoshi_books, audiobook covers in audiobooks), so they try both.
  static Future<void> _rebaseContentPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newBooksRoot,
    required String? newAudiobooksRoot,
  }) async {
    final String? oldBooks = meta.booksRoot;
    final String? oldAudio = meta.audiobooksRoot;
    final bool canBooks = oldBooks != null && newBooksRoot != null;
    final bool canAudio = oldAudio != null && newAudiobooksRoot != null;
    if (!canBooks && !canAudio) return;

    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      if (canBooks) {
        for (final EpubBookRow b in await db.getAllEpubBooks()) {
          await db.updateEpubBookContentPaths(
            b.bookKey,
            epubPath: rebasePath(b.epubPath, oldBooks, newBooksRoot),
            extractDir: rebasePath(b.extractDir, oldBooks, newBooksRoot),
            coverPath: b.coverPath == null
                ? null
                : _rebaseEither(b.coverPath!, oldBooks, newBooksRoot, oldAudio,
                    newAudiobooksRoot),
          );
        }
      }
      if (canAudio) {
        for (final AudiobookRow a in await db.getAllAudiobooks()) {
          final String? rebasedJson = a.audioPathsJson == null
              ? null
              : jsonEncode((jsonDecode(a.audioPathsJson!) as List)
                  .whereType<String>()
                  .map((s) => rebasePath(s, oldAudio, newAudiobooksRoot))
                  .toList());
          await db.updateAudiobookPaths(
            a.bookKey,
            audioRoot: a.audioRoot == null
                ? null
                : rebasePath(a.audioRoot!, oldAudio, newAudiobooksRoot),
            audioPathsJson: rebasedJson,
            alignmentPath:
                rebasePath(a.alignmentPath, oldAudio, newAudiobooksRoot),
          );
        }
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Rebases [path] trying the books mapping first, then the audiobooks mapping.
  /// A cover written under either tree resolves; one not under either is
  /// returned unchanged.
  static String _rebaseEither(
    String path,
    String oldBooks,
    String newBooks,
    String? oldAudio,
    String? newAudio,
  ) {
    final String viaBooks = rebasePath(path, oldBooks, newBooks);
    if (viaBooks != path) return viaBooks;
    if (oldAudio != null && newAudio != null) {
      return rebasePath(path, oldAudio, newAudio);
    }
    return path;
  }

  static Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // Best-effort cleanup; a leftover sidecar/bak is harmless and swept later.
    }
  }

  String defaultFilename() {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'hibiki-backup-$date.hibiki.zip';
  }
}
