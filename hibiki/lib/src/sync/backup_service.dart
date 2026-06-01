import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

class BackupMeta {
  BackupMeta({
    required this.appVersion,
    required this.schemaVersion,
    required this.createdAt,
    required this.bookCount,
    required this.statsCount,
  });

  final String appVersion;
  final int schemaVersion;
  final DateTime createdAt;
  final int bookCount;
  final int statsCount;

  Map<String, dynamic> toJson() => {
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'bookCount': bookCount,
        'statsCount': statsCount,
      };

  factory BackupMeta.fromJson(Map<String, dynamic> json) => BackupMeta(
        appVersion: json['appVersion'] as String,
        schemaVersion: json['schemaVersion'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        // Optional for backward compatibility with older backups.
        bookCount: json['bookCount'] as int? ?? 0,
        statsCount: json['statsCount'] as int? ?? 0,
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
  })  : _db = db,
        _dbDirectory = dbDirectory,
        _appVersion = appVersion;

  final HibikiDatabase _db;
  final String _dbDirectory;
  final String _appVersion;

  static const String _dbName = 'hibiki.db';
  static const String _metaName = 'backup_meta.json';
  static const int _maxImportBytes = 512 * 1024 * 1024; // 512 MB

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
      await _stripCredentials(tmpDir.path);
      await _stripDictionaryState(tmpDir.path);

      final books = await _db.getAllEpubBooks();
      final stats = await _db.getAllReadingStatistics();
      final meta = BackupMeta(
        appVersion: _appVersion,
        schemaVersion: _db.schemaVersion,
        createdAt: DateTime.now(),
        bookCount: books.length,
        statsCount: stats.length,
      );

      final archive = Archive();
      final dbBytes = await File(cleanDbPath).readAsBytes();
      archive.addFile(ArchiveFile(_dbName, dbBytes.length, dbBytes));
      final metaBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(meta.toJson()),
      );
      archive.addFile(ArchiveFile(_metaName, metaBytes.length, metaBytes));

      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) throw StateError('Failed to encode ZIP archive');
      await File(outputPath).writeAsBytes(zipData);

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

  /// Removes dictionary rows from the exported DB copy. Dictionary entries and
  /// media live under `dictionaryResources/`, not inside this backup archive;
  /// keeping only DB metadata would restore ghost dictionaries that cannot be
  /// queried.
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
  Future<BackupMeta?> validateBackup(String zipPath) async {
    try {
      final file = File(zipPath);
      final size = await file.length();
      if (size > _maxImportBytes) return null;
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final metaFile = archive.findFile(_metaName);
      if (metaFile == null) return null;
      final metaJson = utf8.decode(metaFile.content as List<int>);
      final meta = BackupMeta.tryParse(metaJson);
      if (meta == null) return null;
      if (archive.findFile(_dbName) == null) return null;
      return meta;
    } catch (_) {
      return null;
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
  }) async {
    final dbPath = p.join(dbDirectory, _dbName);
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final dbFile = archive.findFile(_dbName);
    if (dbFile == null) throw StateError('No $_dbName in backup archive');

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
    // connection) and BEFORE overwriting the main .db: leftover WAL frames from
    // the old DB would otherwise be replayed against the imported file and
    // corrupt it.
    final walFile = File('$dbPath-wal');
    if (walFile.existsSync()) await walFile.delete();
    final shmFile = File('$dbPath-shm');
    if (shmFile.existsSync()) await shmFile.delete();

    // 2) Overwrite with the backup DB bytes.
    await currentDb.writeAsBytes(dbFile.content as List<int>);

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

    // 4) Success: drop the sidecar and the pre-restore copy (no disk leak).
    await _safeDelete(sidecar.path);
    await _safeDelete(bakPath);
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
