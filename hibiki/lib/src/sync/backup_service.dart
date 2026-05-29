import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
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

  /// Removes sync credential rows from the standalone DB copy in [dbDirectory].
  /// Opened via [HibikiDatabase] (the copy is already at the current schema, so
  /// no migration runs). Keyed by the `sync_` prefix + secret-shaped suffixes
  /// so newly added credential prefs are covered without an exact allow-list to
  /// keep in sync. VACUUM + checkpoint so secrets are not recoverable from
  /// freelist/WAL pages.
  static Future<void> _stripCredentials(String dbDirectory) async {
    final db = HibikiDatabase(dbDirectory);
    try {
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

  /// Import a backup, replacing the current database files.
  ///
  /// This is a static method because the database must already be closed
  /// before calling — the caller is responsible for closing the DB first.
  static Future<void> importBackupFiles({
    required String dbDirectory,
    required String zipPath,
  }) async {
    final dbPath = p.join(dbDirectory, _dbName);
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final dbFile = archive.findFile(_dbName);
    if (dbFile == null) throw StateError('No $_dbName in backup archive');

    final currentDb = File(dbPath);
    if (currentDb.existsSync()) {
      await currentDb.copy('$dbPath.pre-restore.bak');
    }
    final walFile = File('$dbPath-wal');
    if (walFile.existsSync()) await walFile.delete();
    final shmFile = File('$dbPath-shm');
    if (shmFile.existsSync()) await shmFile.delete();

    await currentDb.writeAsBytes(dbFile.content as List<int>);
  }

  String defaultFilename() {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'hibiki-backup-$date.hibiki.zip';
  }
}
