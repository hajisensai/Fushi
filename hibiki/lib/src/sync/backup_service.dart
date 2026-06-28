import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/backup_merge_engine.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// Optional file-tree categories a backup export can include. The database
/// (`hibiki.db`) is NOT a category - it carries every table's metadata
/// (books / stats / favorites / profiles / settings / dictionary records) whose
/// rows FK into each other, so it is ALWAYS exported as one consistent blob;
/// only the bulky sidecar file trees below are individually selectable.
///
/// When [BackupService.exportBackup] is called with a [categories] set, only the
/// listed trees are packed; an unselected tree's root is skipped exactly as if
/// the user had no such content. A null set means "everything" (the legacy
/// all-in export), so existing callers are unchanged.
enum BackupCategory {
  /// Imported dictionary resource files (`dictionaryResources/`).
  dictionary,

  /// Extracted book content tree (`hoshi_books/`: epub + html/images/fonts +
  /// covers).
  books,

  /// Audiobook audio + alignment files (`audiobooks/`).
  audiobooks,

  /// User-imported custom font files (`custom_fonts/`).
  fonts,

  /// Video files referenced by `video_books.video_path` / playlist episodes.
  ///
  /// Videos can be very large and are often stored outside the app documents
  /// directory, so the UI leaves this category opt-in by default.
  videos,

  /// Local audio pronunciation databases (`local_audio_*.db` + `-wal`/`-shm`),
  /// stored flat in the support/database directory alongside `hibiki.db`. The
  /// `local_audio_dbs` preference stores their absolute paths, so without
  /// packing the files a restore points at databases that never crossed over
  /// and the local audio sources silently disappear (TODO-941). Packed under
  /// the `localAudio/` archive prefix; these sets can be large (Forvo-style
  /// audio), so the UI leaves this opt-in by default like videos.
  localAudio,
}

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

/// Rebases every file-font `path` inside a persisted font-list JSON string
/// (`[{name, path, enabled}, ...]`) from [oldRoot] onto [newRoot] via
/// [rebasePath]. System fonts (`path == null`) and paths not under [oldRoot]
/// are left untouched. A malformed value (not a JSON list of maps) is returned
/// verbatim so a corrupt pref never aborts the import.
///
/// Custom fonts live under the SOURCE device's `<appDoc>/custom_fonts`; the
/// importing device's root differs, so the stored absolute paths would not
/// resolve and the fonts (shown as imported & enabled) would silently never
/// apply (BUG-183). Import rebases them so the reader/AppFontLoader find them.
String rebaseFontListJson(String json, String oldRoot, String newRoot) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Object? path = e['path'];
      if (path is! String) return e; // system font (null) or odd shape
      return <String, dynamic>{
        ...Map<String, dynamic>.from(e),
        'path': rebasePath(path, oldRoot, newRoot),
      };
    }).toList();
    return jsonEncode(out);
  } catch (_) {
    return json; // never throw on a corrupt pref value
  }
}

/// Rebases every file-font `path` inside the canonical font catalog JSON
/// (`{version, fonts:[{id, name, path}]}`) from [oldRoot] onto [newRoot].
/// Target rows (`font_targets`) refer to catalog entries by id and do not carry
/// paths, so preserving ids while rebasing catalog paths keeps targets valid.
/// Malformed values are returned verbatim so a corrupt pref never aborts import.
String rebaseFontCatalogJson(String json, String oldRoot, String newRoot) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map) return json;
    final Map<String, dynamic> root = Map<String, dynamic>.from(decoded);
    final dynamic fonts = root['fonts'];
    if (fonts is! List) return json;
    root['fonts'] = fonts.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Map<String, dynamic> row = Map<String, dynamic>.from(e);
      final Object? path = row['path'];
      if (path is! String) return row;
      return <String, dynamic>{
        ...row,
        'path': rebasePath(path, oldRoot, newRoot),
      };
    }).toList();
    return jsonEncode(root);
  } catch (_) {
    return json; // never throw on a corrupt pref value
  }
}

/// Rebases every entry's `path` inside a persisted `local_audio_dbs` JSON
/// string (`[{path, displayName, enabled, sources}, ...]`) from [oldRoot] onto
/// [newRoot] via [rebasePath]. Each `path` points at a `local_audio_*.db` file
/// under the source device's support directory; the importing device's root
/// differs, so without rebasing the restored config points at databases that
/// never crossed over and the local audio sources silently never apply
/// (TODO-941). A malformed value (not a JSON list of maps) is returned verbatim
/// so a corrupt pref never aborts the import.
String rebaseLocalAudioDbsJson(String json, String oldRoot, String newRoot) {
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Object? path = e['path'];
      if (path is! String) return e;
      return <String, dynamic>{
        ...Map<String, dynamic>.from(e),
        'path': rebasePath(path, oldRoot, newRoot),
      };
    }).toList();
    return jsonEncode(out);
  } catch (_) {
    return json; // never throw on a corrupt pref value
  }
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
    this.fontsRoot,
    this.localAudioRoot,
    this.videoFiles = const <String, String>{},
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

  /// Absolute root of the custom-font tree on the SOURCE device
  /// (`<appDoc>/custom_fonts`), captured so import can rebase the stored
  /// font-config paths (`font_catalog` plus legacy shadow prefs) to
  /// this device's root. Null for legacy backups → import skips font rebasing.
  final String? fontsRoot;

  /// Absolute root of the support/database directory on the SOURCE device,
  /// where the local-audio pronunciation databases (`local_audio_*.db`) live
  /// flat alongside `hibiki.db`. Captured so import can rebase the stored
  /// `local_audio_dbs` preference paths onto this device's root. Null when the
  /// local-audio category was not packed (or a legacy backup).
  final String? localAudioRoot;

  /// Exact source video path -> archive-relative path under `videos/`.
  ///
  /// Imported videos are not copied into one stable app directory today; the DB
  /// stores the user's original absolute file paths. A single source root is
  /// therefore not enough to rebase them after restore, so the backup records
  /// the exact paths it packed and import rewrites matching DB paths onto the
  /// chosen local video restore root.
  final Map<String, String> videoFiles;

  Map<String, dynamic> toJson() => {
        'appVersion': appVersion,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'bookCount': bookCount,
        'statsCount': statsCount,
        if (booksRoot != null) 'booksRoot': booksRoot,
        if (audiobooksRoot != null) 'audiobooksRoot': audiobooksRoot,
        if (fontsRoot != null) 'fontsRoot': fontsRoot,
        if (localAudioRoot != null) 'localAudioRoot': localAudioRoot,
        if (videoFiles.isNotEmpty) 'videoFiles': videoFiles,
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
        fontsRoot: json['fontsRoot'] as String?,
        localAudioRoot: json['localAudioRoot'] as String?,
        videoFiles: (json['videoFiles'] as Map?)?.map(
                (dynamic k, dynamic v) => MapEntry(k as String, v as String)) ??
            const <String, String>{},
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
    String? fontsRootDirectory,
  })  : _db = db,
        _dbDirectory = dbDirectory,
        _dictionaryResourceDirectory = dictionaryResourceDirectory,
        _booksRootDirectory = booksRootDirectory,
        _audiobooksRootDirectory = audiobooksRootDirectory,
        _fontsRootDirectory = fontsRootDirectory,
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

  /// Root of the custom-font tree (`<appDoc>/custom_fonts`). When provided, the
  /// imported font files are packed into the backup so they travel with the
  /// font config (BUG-183: otherwise the config points at files that never
  /// crossed over).
  final String? _fontsRootDirectory;

  final String _appVersion;

  static const String _dbName = 'hibiki.db';
  static const String _metaName = 'backup_meta.json';
  static const String _dictionaryResourcesPrefix = 'dictionaryResources';
  static const String _booksPrefix = 'hoshi_books';
  static const String _audiobooksPrefix = 'audiobooks';
  static const String _fontsPrefix = 'custom_fonts';
  static const String _videosPrefix = 'videos';
  static const String _localAudioPrefix = 'localAudio';

  /// Preference key (in the `preferences` table) whose JSON value is the
  /// local-audio library list `[{path, displayName, enabled, sources}]`. The
  /// `path` of each entry points at a `local_audio_*.db` file in the support
  /// directory and is rebased onto this device's root on import (TODO-941).
  static const String _localAudioDbsPrefKey = 'local_audio_dbs';

  /// Matches a packed local-audio database file (and its `-wal`/`-shm`
  /// siblings). Only these are packed from the support directory so the export
  /// never sweeps in `hibiki.db` or other unrelated support files.
  static final RegExp _localAudioFileName =
      RegExp(r'^local_audio_\d+\.db(-wal|-shm)?$');

  /// Persisted preference key (ReaderSettings prefix included) whose JSON
  /// value is the canonical catalog `{version, fonts:[{id, name, path}]}`.
  static const String _fontCatalogPrefKey = 'src:reader_ttu:font_catalog';

  /// Persisted legacy shadow preference keys (ReaderSettings prefix included)
  /// whose JSON value is a font list `[{name, path, enabled}]`. These remain
  /// import-compatible while `font_catalog` is the canonical model.
  static const List<String> _legacyFontPrefKeys = <String>[
    'src:reader_ttu:custom_fonts',
    'src:reader_ttu:app_ui_fonts',
    'src:reader_ttu:dict_fonts',
    'src:reader_ttu:video_sub_fonts',
  ];

  /// Sidecar file holding this device's sync config across an import. Written
  /// BEFORE the destructive DB overwrite so a crash mid-import is recoverable
  /// (a startup sweep re-applies it). Deleted once the import completes.
  static const String _preserveSidecar = 'hibiki.db.sync-preserve.json';

  String get _dbPath => p.join(_dbDirectory, _dbName);

  /// Create a backup ZIP file at [outputPath].
  ///
  /// [categories] selects which optional file trees are packed. A null set
  /// (default) packs every tree this service was constructed with - the legacy
  /// all-in export, so existing callers are unchanged. A non-null set packs
  /// ONLY the listed trees; an omitted tree is skipped (its root treated as if
  /// it carried no content), exactly the same as constructing the service
  /// without that root. The database (`hibiki.db`) is always included
  /// regardless, since it holds every table's metadata. [BackupMeta] still
  /// records the source roots of the trees that were actually packed so import
  /// can rebase them; an omitted tree's root is left null in the meta.
  Future<BackupMeta> exportBackup(
    String outputPath, {
    Set<BackupCategory>? categories,
  }) async {
    bool wants(BackupCategory c) =>
        categories == null || categories.contains(c);
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
      // Honor the category selection: when the user unticked Dictionaries,
      // exclude them entirely (and strip their DB rows below) even if the
      // resource files are present on disk.
      final bool includeDictionary = wants(BackupCategory.dictionary) &&
          await _hasCompleteDictionaryResources(dictionaryResourceRoot);
      await _stripCredentials(tmpDir.path);
      if (!includeDictionary) {
        await _stripDictionaryState(tmpDir.path);
      }

      final books = await _db.getAllEpubBooks();
      final stats = await _db.getAllReadingStatistics();

      // Build the flat "zip-path → disk-path" map, then stream every file into
      // the ZIP off the UI isolate. The old path read each file fully into a
      // single in-memory Archive and ran a synchronous ZipEncoder().encode() on
      // the UI isolate — that froze the app (ANR) on any non-trivial library.
      final Map<String, String> files = <String, String>{
        _dbName: cleanDbPath,
      };
      Map<String, String> videoFiles = const <String, String>{};
      if (wants(BackupCategory.videos)) {
        videoFiles = await _collectVideoFiles(files);
      }
      if (wants(BackupCategory.localAudio)) {
        await _collectLocalAudioFiles(files);
      }

      // Record the SOURCE-device content roots so import can rebase the stored
      // absolute paths (epubPath/extractDir/coverPath/audioRoot/...) onto the
      // importing device's roots. Null roots → legacy db-only backup.
      final meta = BackupMeta(
        appVersion: _appVersion,
        schemaVersion: _db.schemaVersion,
        createdAt: DateTime.now(),
        bookCount: books.length,
        statsCount: stats.length,
        // Only record a tree's source root when that tree is actually packed,
        // so import never rebases stored paths against a tree the backup never
        // carried (a no-op for the missing tree either way, but keeping the
        // meta honest avoids surprising the restore code).
        booksRoot: wants(BackupCategory.books) ? _booksRootDirectory : null,
        audiobooksRoot:
            wants(BackupCategory.audiobooks) ? _audiobooksRootDirectory : null,
        fontsRoot: wants(BackupCategory.fonts) ? _fontsRootDirectory : null,
        localAudioRoot: wants(BackupCategory.localAudio) ? _dbDirectory : null,
        videoFiles: videoFiles,
      );

      if (includeDictionary) {
        await _collectTreeFiles(
            dictionaryResourceRoot!, _dictionaryResourcesPrefix, files);
      }
      if (_booksRootDirectory != null && wants(BackupCategory.books)) {
        await _collectTreeFiles(
            Directory(_booksRootDirectory), _booksPrefix, files);
      }
      if (_audiobooksRootDirectory != null &&
          wants(BackupCategory.audiobooks)) {
        await _collectTreeFiles(
            Directory(_audiobooksRootDirectory), _audiobooksPrefix, files);
      }
      if (_fontsRootDirectory != null && wants(BackupCategory.fonts)) {
        await _collectTreeFiles(
            Directory(_fontsRootDirectory), _fontsPrefix, files);
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
      await _deleteDirectoryIfPresent(tmpDir);
    }
  }

  static Future<void> _deleteDirectoryIfPresent(Directory directory) async {
    await deleteDirectoryWithRetry(
      exists: directory.exists,
      delete: () => directory.delete(recursive: true),
      sleep: (int ms) => Future<void>.delayed(Duration(milliseconds: ms)),
      isWindows: Platform.isWindows,
    );
  }

  /// Whether a Windows OS error code is a transient filesystem-busy condition
  /// that clears once an external handle is released. The recursive delete of
  /// the export's temp dir runs right after [_stripCredentials] /
  /// [_stripDictionaryState] closed their sqlite connections; on Windows the OS
  /// (and Defender / search-indexer scanning the just-written `hibiki.db` copy)
  /// can keep a handle open for a brief window after `close()` returns, so the
  /// delete fails with ERROR_ACCESS_DENIED(5), ERROR_SHARING_VIOLATION(32) or
  /// ERROR_DIR_NOT_EMPTY(145, a child file still locked). Same family as the
  /// dictionary-import rename lock (BUG-050).
  static bool _isWindowsTransientFsBusy(int? code) =>
      code == 5 || code == 32 || code == 145;

  /// Pure, dependency-injected core of [_deleteDirectoryIfPresent]: deletes a
  /// directory tree, tolerating both a vanished tree ([PathNotFoundException]:
  /// already cleaned up) and -- on Windows only -- a transient filesystem-busy
  /// error (see [_isWindowsTransientFsBusy]) via a bounded, backing-off retry
  /// that gives the lingering external handle time to release.
  ///
  /// A non-Windows error, or a Windows error that is NOT transient FS-busy, is
  /// rethrown immediately (never swallowed -- a real cleanup failure must
  /// surface). If every attempt hits transient FS-busy the last exception is
  /// rethrown rather than silently leaving the temp tree on disk. POSIX deletes
  /// succeed on the first attempt and never enter the retry branch.
  @visibleForTesting
  static Future<void> deleteDirectoryWithRetry({
    required Future<bool> Function() exists,
    required Future<void> Function() delete,
    required Future<void> Function(int delayMs) sleep,
    required bool isWindows,
    int maxAttempts = 10,
  }) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (await exists()) {
          await delete();
        }
        return;
      } on PathNotFoundException {
        // Cleanup is already satisfied if the temp tree vanished between the
        // existence check and deletion.
        return;
      } on FileSystemException catch (e) {
        final int? code = e.osError?.errorCode;
        final bool transient = isWindows && _isWindowsTransientFsBusy(code);
        if (!transient || attempt == maxAttempts) rethrow;
        await sleep(50 * attempt); // backoff: 50ms,100ms,... let handle drop
      }
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
    } catch (e, st) {
      // A null result tells the UI "invalid backup". Surface the real reason
      // (corrupt zip / read error / OOM) so it is not silently indistinguishable
      // from a genuinely malformed archive (review W4).
      debugPrint('BackupService.validateBackup failed for $zipPath: $e\n$st');
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
    String? fontsRootDirectory,
    String? videosRootDirectory,
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
      // BUG-454: a backup exported WITHOUT the dictionary category carries no
      // `dictionaryResources/` files AND has its dictionary DB rows stripped on
      // export (`_stripDictionaryState`). Detecting "the backup has no
      // dictionary files" lets the overwrite import PRESERVE this device's
      // existing dictionaries (metadata rows + resource files) instead of
      // wiping them — the backup simply didn't include that category, the same
      // selective-preserve contract the device-local sync prefs already follow.
      final bool backupHasDictionaries = archive.files.any((ArchiveFile f) =>
          f.isFile &&
          f.name
              .replaceAll(r'\', '/')
              .startsWith('$_dictionaryResourcesPrefix/'));

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

      if (backupHasDictionaries &&
          dictionaryRestorePlan != null &&
          dictionaryRestoreDirectory != null) {
        // Backup carries dictionaries → replace this device's resources with
        // the backup's (the DB overwrite already brought the matching rows).
        await _restoreDictionaryResources(
          restorePlan: dictionaryRestorePlan,
          dictionaryResourceDirectory: dictionaryRestoreDirectory,
        );
      } else if (!backupHasDictionaries &&
          haveCurrent &&
          dictionaryRestoreDirectory != null) {
        // BUG-454: backup has NO dictionaries → keep this device's. The DB was
        // just overwritten with the backup's (dictionary tables empty), so
        // re-seat the local dictionary rows from pre-restore.bak. The resource
        // FILES on disk were never touched (we skipped the unconditional wipe
        // in _restoreDictionaryResources), so rows + files stay consistent.
        // Gated on a managed dictionary dir: the live app always supplies it;
        // a null dir means the caller isn't managing dictionaries at all, so
        // there is nothing to preserve (and bak may not even be a real DB in
        // such minimal call sites).
        await _restoreDictionaryTablesFromBak(dbDirectory, bakPath);
      }

      // 2b) Restore the book + audiobook content trees (full-data backup).
      //     PREPARE both (write to sibling `.import-tmp` dirs) BEFORE COMMITTING
      //     either (fast rename-swap), so a failure during the GB-scale write
      //     phase swaps nothing and leaves both existing trees intact — a user's
      //     whole library must never be half-destroyed. Only runs when the
      //     caller supplies the roots AND the backup carries that tree.
      final List<String> toCommit = <String>[];
      try {
        if (booksRootDirectory != null &&
            await _prepareTreeRestore(
                archive, _booksPrefix, booksRootDirectory)) {
          toCommit.add(booksRootDirectory);
        }
        if (audiobooksRootDirectory != null &&
            await _prepareTreeRestore(
                archive, _audiobooksPrefix, audiobooksRootDirectory)) {
          toCommit.add(audiobooksRootDirectory);
        }
        if (fontsRootDirectory != null &&
            await _prepareTreeRestore(
                archive, _fontsPrefix, fontsRootDirectory)) {
          toCommit.add(fontsRootDirectory);
        }
        if (videosRootDirectory != null &&
            await _prepareTreeRestore(
                archive, _videosPrefix, videosRootDirectory)) {
          toCommit.add(videosRootDirectory);
        }
      } catch (_) {
        // A write failed: drop every staged temp dir; no tree was swapped.
        if (booksRootDirectory != null) {
          await _abortPreparedTree(booksRootDirectory);
        }
        if (audiobooksRootDirectory != null) {
          await _abortPreparedTree(audiobooksRootDirectory);
        }
        if (fontsRootDirectory != null) {
          await _abortPreparedTree(fontsRootDirectory);
        }
        if (videosRootDirectory != null) {
          await _abortPreparedTree(videosRootDirectory);
        }
        rethrow;
      }
      // All writes succeeded → commit each prepared tree (fast renames).
      for (final String root in toCommit) {
        await _commitPreparedTree(root);
      }

      // 2c) Restore local-audio databases into the support directory. These are
      //     individual files sharing the directory with hibiki.db, so they are
      //     extracted file-by-file (never the destructive tree swap). When the
      //     backup carries no localAudio/ prefix the existing local-audio DBs
      //     are left untouched (same preserve-on-absent contract as the trees).
      await _restoreLocalAudioFiles(archive, dbDirectory);

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
        // Custom-font config is content too (the files come from the backup),
        // so rebase its stored paths onto this device's font root. No-op for a
        // legacy backup (meta has no fontsRoot) or a keep-settings import where
        // the preserved local paths aren't under the source root.
        await _rebaseFontPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newFontsRoot: fontsRootDirectory,
        );
        // Local-audio DBs are content (their files come from the backup), so
        // rebase the stored `local_audio_dbs` pref paths onto this device's
        // support directory. No-op for a legacy/db-only backup (no
        // localAudioRoot in meta).
        await _rebaseLocalAudioPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newLocalAudioRoot: dbDirectory,
        );
        await _rebaseVideoPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newVideosRoot: videosRootDirectory,
        );
      }

      // 4) Success: drop the sidecar and the pre-restore copy (no disk leak).
      await _safeDelete(sidecar.path);
      await _safeDelete(bakPath);
    } finally {
      await input.close();
    }
  }

  /// Sidecar file marking a pending MERGE import (TODO-888). The merge runs in
  /// one Drift transaction, so a crash leaves the DB already-consistent (the
  /// transaction either committed or rolled back); this sidecar only drives
  /// startup cleanup of the temp `merge-src` + `pre-merge.bak` files.
  static const String _mergeSidecar = 'hibiki.db.merge-preserve.json';
  static const String _mergeSrcName = 'hibiki.db.merge-src';

  /// MERGE a backup into the current database instead of overwriting it
  /// (TODO-888). The device keeps everything it has; the backup only ADDS what
  /// is missing and MAX-unions statistics, so re-importing the same backup is
  /// idempotent. Unlike [importBackupFiles] this NEVER touches the destructive
  /// overwrite path (`writeAsBytes`) or the two-phase tree swap; content trees
  /// are restored copy-if-absent (existing files are never replaced or deleted).
  ///
  /// The caller must close the app's DB first (same contract as
  /// [importBackupFiles]); this opens its own connections. Crash safety: the
  /// whole row merge is ONE [HibikiDatabase.transaction] (rolled back on any
  /// failure) plus a `pre-merge.bak` snapshot for manual recovery, and a
  /// `mode:'merge'` sidecar so [recoverPendingImport] cleans up temp files.
  static Future<void> mergeImportBackupFiles({
    required String dbDirectory,
    required String zipPath,
    String? dictionaryResourceDirectory,
    String? booksRootDirectory,
    String? audiobooksRootDirectory,
    String? fontsRootDirectory,
    String? videosRootDirectory,
  }) async {
    final String dbPath = p.join(dbDirectory, _dbName);
    final String mergeSrcPath = p.join(dbDirectory, _mergeSrcName);
    final String bakPath = '$dbPath.pre-merge.bak';
    final File sidecar = File(p.join(dbDirectory, _mergeSidecar));

    final InputFileStream input = InputFileStream(zipPath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile? dbFile = archive.findFile(_dbName);
      if (dbFile == null) throw StateError('No $_dbName in backup archive');

      BackupMeta? meta;
      final ArchiveFile? metaFile = archive.findFile(_metaName);
      if (metaFile != null) {
        meta = BackupMeta.tryParse(utf8.decode(metaFile.content as List<int>));
      }

      // 1) Extract the backup DB to a sibling temp file (NEVER overwrite the
      //    live DB). Drop any stale merge-src/-wal/-shm from a prior crash.
      await _safeDelete(mergeSrcPath);
      await _safeDelete('$mergeSrcPath-wal');
      await _safeDelete('$mergeSrcPath-shm');
      await File(mergeSrcPath)
          .writeAsBytes(dbFile.content as List<int>, flush: true);

      // 2) Migrate the backup DB up to the current schema so its columns align
      //    with the live DB for the ATTACH-based row merge. (Its schemaVersion
      //    is <= current — validated by the caller.) Opening + closing
      //    HibikiDatabase on its file runs onUpgrade if needed.
      final HibikiDatabase srcMigrate = HibikiDatabase.atFile(mergeSrcPath);
      try {
        await srcMigrate.customStatement('PRAGMA user_version');
      } finally {
        await srcMigrate.close();
      }
      await _safeDelete('$mergeSrcPath-wal');
      await _safeDelete('$mergeSrcPath-shm');

      // 3) Snapshot the live DB for manual recovery + drop the crash-cleanup
      //    sidecar BEFORE mutating the live DB.
      final File currentDb = File(dbPath);
      if (currentDb.existsSync()) {
        await currentDb.copy(bakPath);
      }
      await sidecar.writeAsString(jsonEncode(<String, dynamic>{
        'mode': 'merge',
        'mergeSrc': mergeSrcPath,
      }));

      // 4) Open the live DB, ATTACH the backup, run the whole row merge in one
      //    transaction (rolled back on any failure -> DB unchanged).
      final HibikiDatabase db = HibikiDatabase(dbDirectory);
      try {
        final String safeSrc =
            mergeSrcPath.replaceAll(r'\', '/').replaceAll("'", "''");
        await db.customStatement("ATTACH DATABASE '$safeSrc' AS mergesrc");
        try {
          await BackupMergeEngine(db).merge();
        } finally {
          await db.customStatement('DETACH DATABASE mergesrc');
        }
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        await db.close();
      }

      // 5) Restore content trees COPY-IF-ABSENT (never delete/replace existing
      //    files — the device's own library must stay intact).
      if (dictionaryResourceDirectory != null) {
        await _copyTreeIfAbsent(
            archive, _dictionaryResourcesPrefix, dictionaryResourceDirectory);
      }
      if (booksRootDirectory != null) {
        await _copyTreeIfAbsent(archive, _booksPrefix, booksRootDirectory);
      }
      if (audiobooksRootDirectory != null) {
        await _copyTreeIfAbsent(
            archive, _audiobooksPrefix, audiobooksRootDirectory);
      }
      if (fontsRootDirectory != null) {
        await _copyTreeIfAbsent(archive, _fontsPrefix, fontsRootDirectory);
      }
      if (videosRootDirectory != null) {
        await _copyTreeIfAbsent(archive, _videosPrefix, videosRootDirectory);
      }
      // Local-audio DBs are copy-if-absent into the support directory (never
      // overwrite the device's own local_audio_*.db files).
      await _restoreLocalAudioFiles(archive, dbDirectory, overwrite: false);

      // 6) Rebase the newly-merged backup rows' stored paths onto this device's
      //    roots. Device-local rows aren't under the backup's source root, so
      //    rebasePath leaves them untouched (a no-op for them).
      if (meta != null) {
        await _rebaseContentPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newBooksRoot: booksRootDirectory,
          newAudiobooksRoot: audiobooksRootDirectory,
        );
        await _rebaseFontPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newFontsRoot: fontsRootDirectory,
        );
        await _rebaseLocalAudioPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newLocalAudioRoot: dbDirectory,
        );
        await _rebaseVideoPaths(
          dbDirectory: dbDirectory,
          meta: meta,
          newVideosRoot: videosRootDirectory,
        );
      }

      // 7) Success: drop the merge-src temp, the bak, and the sidecar.
      await _safeDelete(mergeSrcPath);
      await _safeDelete('$mergeSrcPath-wal');
      await _safeDelete('$mergeSrcPath-shm');
      await _safeDelete(bakPath);
      await _safeDelete(sidecar.path);
    } finally {
      await input.close();
    }
  }

  /// Copies every file under `<prefix>/` in [archive] into [targetRootPath],
  /// SKIPPING any whose destination already exists (the merge-import invariant:
  /// never delete or overwrite the device's own content). Reuses the same path
  /// traversal safety checks as the overwrite path's [_buildTreeRestorePlan].
  static Future<void> _copyTreeIfAbsent(
    Archive archive,
    String prefix,
    String targetRootPath,
  ) async {
    final List<MapEntry<ArchiveFile, String>> plan = _buildTreeRestorePlan(
      archive: archive,
      prefix: prefix,
      targetRootPath: targetRootPath,
    );
    for (final MapEntry<ArchiveFile, String> entry in plan) {
      final File dest = File(entry.value);
      if (await dest.exists()) continue; // copy-if-absent: never overwrite
      dest.parent.createSync(recursive: true);
      await dest.writeAsBytes(entry.key.content as List<int>, flush: true);
    }
  }

  /// Cleans up a crashed/finished MERGE import's temp files (TODO-888). Returns
  /// true when a merge sidecar was present (and was handled), false otherwise.
  /// The DB itself is untouched: the merge transaction is all-or-nothing, so the
  /// live DB is already consistent regardless of when a crash happened.
  static Future<bool> recoverMergeImport(String dbDirectory) async {
    final File sidecar = File(p.join(dbDirectory, _mergeSidecar));
    if (!sidecar.existsSync()) return false;
    try {
      final Map<String, dynamic> decoded =
          jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      final Object? mergeSrc = decoded['mergeSrc'];
      if (mergeSrc is String) {
        await _safeDelete(mergeSrc);
        await _safeDelete('$mergeSrc-wal');
        await _safeDelete('$mergeSrc-shm');
      }
    } catch (e, st) {
      debugPrint('BackupService.recoverMergeImport failed: $e\n$st');
    }
    await _safeDelete(p.join(dbDirectory, _mergeSrcName));
    await _safeDelete(p.join(dbDirectory, '$_mergeSrcName-wal'));
    await _safeDelete(p.join(dbDirectory, '$_mergeSrcName-shm'));
    await _safeDelete(p.join(dbDirectory, '$_dbName.pre-merge.bak'));
    await _safeDelete(sidecar.path);
    return true;
  }

  /// Finish a pending import at startup, before any sync code reads prefs.
  /// Handles both: (a) re-applying device-local sync prefs if a full-restore
  /// import crashed mid-way; (b) restoring this device's settings layer for a
  /// keep-settings import. No-op when no sidecar is present.
  static Future<void> recoverPendingImport(String dbDirectory) async {
    // MERGE import (TODO-888) leaves its own sidecar. The row merge ran in ONE
    // Drift transaction, so the live DB is already consistent whether or not we
    // crashed (the transaction either committed or rolled back) — there is
    // NOTHING to apply to the DB, only leftover temp files to sweep. Handle it
    // first + return so a 'merge' marker can never fall through to the legacy
    // bare-map prefs path and get mis-applied. (recoverMergeImport is reused by
    // tests; keep the sweep there.)
    if (await recoverMergeImport(dbDirectory)) return;

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

  /// Tables holding this device's imported dictionaries. Re-seated from
  /// pre-restore.bak when a backup that carries NO dictionaries is imported in
  /// overwrite mode (BUG-454), so an unselected-dictionary backup never wipes
  /// the device's dictionary library. `dictionary_metadata` is the queryable
  /// dictionary set; `dictionary_history` is its recent-lookup list. Neither is
  /// FK-targeted by content tables, so a wholesale per-table swap is FK-safe.
  static const List<String> _dictionaryLayerTables = <String>[
    'dictionary_metadata',
    'dictionary_history',
  ];

  /// Restores [_dictionaryLayerTables] from [bakPath] (this device's pre-import
  /// snapshot) into the freshly-overwritten DB in [dbDirectory]. Runs inline
  /// during import while both DBs are at the current schema (bak is a copy of
  /// the live DB), so `SELECT *` columns align. No-op (logged) if bak is gone.
  static Future<void> _restoreDictionaryTablesFromBak(
    String dbDirectory,
    String bakPath,
  ) async {
    if (!File(bakPath).existsSync()) {
      // bak is the only copy of this device's dictionary rows after the
      // overwrite. Missing it means a crash + external deletion before this
      // ran; surface loudly rather than silently dropping the dictionaries.
      debugPrint('BackupService._restoreDictionaryTablesFromBak: '
          'pre-restore.bak missing — local dictionaries could not be '
          'preserved on import.');
      return;
    }
    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      final String safeBak =
          bakPath.replaceAll(r'\', '/').replaceAll("'", "''");
      await db.customStatement("ATTACH DATABASE '$safeBak' AS dictbak");
      await db.transaction(() async {
        for (final String t in _dictionaryLayerTables) {
          await db.customStatement('DELETE FROM $t');
          await db.customStatement('INSERT INTO $t SELECT * FROM dictbak.$t');
        }
      });
      await db.customStatement('DETACH DATABASE dictbak');
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

  /// Adds every local-audio pronunciation database file (`local_audio_*.db`
  /// plus its `-wal`/`-shm` siblings) from the support/database directory to
  /// [into], keyed by its zip path (`localAudio/<filename>`). Only files
  /// matching [_localAudioFileName] are packed, so `hibiki.db`, sidecars and
  /// every other support file stay out of the backup (TODO-941).
  Future<void> _collectLocalAudioFiles(Map<String, String> into) async {
    final Directory root = Directory(_dbDirectory);
    if (!await root.exists()) return;
    await for (final FileSystemEntity entity in root.list()) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (!_localAudioFileName.hasMatch(name)) continue;
      into[p.posix.join(_localAudioPrefix, name)] = entity.path;
    }
  }

  Future<Map<String, String>> _collectVideoFiles(
    Map<String, String> into,
  ) async {
    final Map<String, String> sourcePathToArchiveRelative = <String, String>{};
    final Set<String> usedArchiveRelativePaths = <String>{};
    final List<VideoBookRow> rows = await _db.allVideoBooks();
    for (final VideoBookRow row in rows) {
      int index = 0;
      for (final String videoPath in _videoPathsForRow(row)) {
        if (videoPath.isEmpty ||
            sourcePathToArchiveRelative.containsKey(videoPath)) {
          continue;
        }
        final File videoFile = File(videoPath);
        if (!await videoFile.exists()) continue;
        final String relativePath = _videoArchiveRelativePath(
          bookUid: row.bookUid,
          sourcePath: videoPath,
          index: index,
          used: usedArchiveRelativePaths,
        );
        sourcePathToArchiveRelative[videoPath] = relativePath;
        into[p.posix.join(_videosPrefix, relativePath)] = videoPath;
        index++;
      }
    }
    return sourcePathToArchiveRelative;
  }

  static Iterable<String> _videoPathsForRow(VideoBookRow row) sync* {
    yield row.videoPath;
    final String? playlistJson = row.playlistJson;
    if (playlistJson == null || playlistJson.isEmpty) return;
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return;
      for (final dynamic entry in decoded) {
        if (entry is! Map) continue;
        final Object? path = entry['path'];
        if (path is String) yield path;
      }
    } catch (_) {
      return;
    }
  }

  static String _videoArchiveRelativePath({
    required String bookUid,
    required String sourcePath,
    required int index,
    required Set<String> used,
  }) {
    final String folder = _safeArchiveSegment(bookUid);
    final String basename = _safeArchiveSegment(
      _crossPlatformBasename(sourcePath).isEmpty
          ? 'video'
          : _crossPlatformBasename(sourcePath),
    );
    String candidate = p.posix.join(folder, '${index + 1}-$basename');
    int suffix = 2;
    while (used.contains(candidate)) {
      candidate = p.posix.join(folder, '${index + 1}-$suffix-$basename');
      suffix++;
    }
    used.add(candidate);
    return candidate;
  }

  static String _crossPlatformBasename(String path) {
    final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
    return sep >= 0 ? path.substring(sep + 1) : path;
  }

  static String _safeArchiveSegment(String value) {
    final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return safe.isEmpty ? 'item' : safe;
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

  /// Extracts the packed local-audio databases (`localAudio/<file>`) into the
  /// support directory [dbDirectory]. Unlike the content TREES these are
  /// individual files SHARING the directory with `hibiki.db`, so they are
  /// written file-by-file rather than via the destructive tree swap. Only file
  /// names matching [_localAudioFileName] are accepted (defense in depth: an
  /// archive entry naming `hibiki.db` under `localAudio/` is rejected).
  ///
  /// When the backup carries no `localAudio/` entries this is a no-op, so an
  /// audio-less backup leaves this device's local-audio DBs intact (the same
  /// preserve-on-absent contract the content trees follow — BUG-454 family).
  ///
  /// [overwrite] true (overwrite import) replaces an existing same-named file;
  /// false (merge import) keeps the device's own file (copy-if-absent).
  static Future<void> _restoreLocalAudioFiles(
    Archive archive,
    String dbDirectory, {
    bool overwrite = true,
  }) async {
    final Directory targetRoot = Directory(dbDirectory);
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String rawName = file.name.replaceAll(r'\', '/');
      if (!rawName.startsWith('$_localAudioPrefix/')) continue;
      final String name = rawName.substring(_localAudioPrefix.length + 1);
      // Reject nested paths / traversal / non-local-audio names: these files
      // must land flat in the support dir and never escape it or clobber
      // hibiki.db.
      if (name.isEmpty ||
          name.contains('/') ||
          !_localAudioFileName.hasMatch(name)) {
        throw FormatException('Invalid local audio backup path: ${file.name}');
      }
      final File dest = File(p.join(targetRoot.path, name));
      if (!overwrite && await dest.exists()) continue;
      dest.parent.createSync(recursive: true);
      await dest.writeAsBytes(file.content as List<int>, flush: true);
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

  static String _importTmpPath(String root) => '$root.import-tmp';
  static String _importOldPath(String root) => '$root.import-old';

  /// Removes any stale `.import-tmp` / `.import-old` siblings left by a prior
  /// import that crashed mid-swap. Called on entry to every prepare so a stale
  /// `.import-old` can never be mistaken for a valid rollback target by a later
  /// import (review W1).
  static Future<void> _clearImportLeftovers(String targetRootPath) async {
    for (final String path in <String>[
      _importTmpPath(targetRootPath),
      _importOldPath(targetRootPath),
    ]) {
      final Directory d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    }
  }

  /// PHASE 1 of the content-tree restore: write every file under `<prefix>/`
  /// into the sibling `<root>.import-tmp` (NO swap yet). Returns true when there
  /// is something staged to commit; false when the backup carries no files under
  /// [prefix] (db-only / audio-less backup) so the existing tree is left alone.
  ///
  /// Splitting write (slow, GB-scale, failure-prone) from the swap (fast rename)
  /// lets the caller stage ALL trees before committing ANY — a write failure
  /// then swaps nothing and leaves every existing tree intact (review W2).
  static Future<bool> _prepareTreeRestore(
    Archive archive,
    String prefix,
    String targetRootPath,
  ) async {
    final String tmpRoot = _importTmpPath(targetRootPath);
    final List<MapEntry<ArchiveFile, String>> plan = _buildTreeRestorePlan(
      archive: archive,
      prefix: prefix,
      targetRootPath: tmpRoot,
    );
    await _clearImportLeftovers(targetRootPath);
    if (plan.isEmpty) return false;

    final Directory tmpDir = Directory(tmpRoot);
    await tmpDir.create(recursive: true);
    try {
      for (final MapEntry<ArchiveFile, String> entry in plan) {
        final File dest = File(entry.value);
        dest.parent.createSync(recursive: true);
        await dest.writeAsBytes(entry.key.content as List<int>, flush: true);
      }
    } catch (_) {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      rethrow; // nothing swapped; existing tree untouched
    }
    return true;
  }

  /// PHASE 2: swap the staged `<root>.import-tmp` into place. tmp and target are
  /// siblings → rename is atomic on the same filesystem. Caller invokes this for
  /// each prepared tree back-to-back; only the (rare) rename failure between two
  /// trees leaves a cross-tree half-state, which is far smaller than the old
  /// write-between-swaps window.
  static Future<void> _commitPreparedTree(String targetRootPath) async {
    final String asideRoot = _importOldPath(targetRootPath);
    final Directory aside = Directory(asideRoot);
    final Directory target = Directory(targetRootPath);
    final Directory tmpDir = Directory(_importTmpPath(targetRootPath));
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

  /// Drops a staged-but-not-committed `<root>.import-tmp` (idempotent).
  static Future<void> _abortPreparedTree(String targetRootPath) async {
    final Directory tmpDir = Directory(_importTmpPath(targetRootPath));
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
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
          // Rebase each path inside audioPathsJson. A malformed value (corrupt
          // row, not a JSON string-list) must not abort the whole import — keep
          // it as-is and move on (review W3).
          String? rebasedJson = a.audioPathsJson;
          if (a.audioPathsJson != null) {
            try {
              final dynamic decoded = jsonDecode(a.audioPathsJson!);
              if (decoded is List) {
                rebasedJson = jsonEncode(decoded
                    .whereType<String>()
                    .map((s) => rebasePath(s, oldAudio, newAudiobooksRoot))
                    .toList());
              }
            } catch (e) {
              debugPrint('BackupService: skipped rebasing audioPathsJson for '
                  '${a.bookKey}: $e');
            }
          }
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

  /// Rebases the imported DB's stored custom-font paths from the backup's
  /// [BackupMeta.fontsRoot] onto this device's [newFontsRoot]. The canonical
  /// `font_catalog` carries paths, while `font_targets` only carries catalog
  /// ids/order/enabled rows; legacy shadow lists also carry paths. Every stored
  /// file-font path is rebased (system fonts and unrelated paths untouched).
  /// No-op when either root is null.
  static Future<void> _rebaseFontPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newFontsRoot,
  }) async {
    final String? oldFonts = meta.fontsRoot;
    if (oldFonts == null || newFontsRoot == null) return;
    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      final Map<String, String> prefs = await db.getAllPrefs();
      final String? catalog = prefs[_fontCatalogPrefKey];
      if (catalog != null) {
        final String rebasedCatalog = rebaseFontCatalogJson(
          catalog,
          oldFonts,
          newFontsRoot,
        );
        if (rebasedCatalog != catalog) {
          await db.setPref(_fontCatalogPrefKey, rebasedCatalog);
        }
      }
      for (final String key in _legacyFontPrefKeys) {
        final String? raw = prefs[key];
        if (raw == null) continue;
        final String rebased = rebaseFontListJson(raw, oldFonts, newFontsRoot);
        if (rebased != raw) await db.setPref(key, rebased);
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  /// Rebases the imported DB's `local_audio_dbs` preference paths from the
  /// backup's [BackupMeta.localAudioRoot] onto this device's
  /// [newLocalAudioRoot] (its support directory). No-op when the backup did not
  /// pack local-audio DBs (meta has no localAudioRoot) or the value is absent.
  static Future<void> _rebaseLocalAudioPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newLocalAudioRoot,
  }) async {
    final String? oldRoot = meta.localAudioRoot;
    if (oldRoot == null || newLocalAudioRoot == null) return;
    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      final Map<String, String> prefs = await db.getAllPrefs();
      final String? raw = prefs[_localAudioDbsPrefKey];
      if (raw != null) {
        final String rebased =
            rebaseLocalAudioDbsJson(raw, oldRoot, newLocalAudioRoot);
        if (rebased != raw) {
          await db.setPref(_localAudioDbsPrefKey, rebased);
        }
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  static Future<void> _rebaseVideoPaths({
    required String dbDirectory,
    required BackupMeta meta,
    required String? newVideosRoot,
  }) async {
    if (newVideosRoot == null || meta.videoFiles.isEmpty) return;
    final HibikiDatabase db = HibikiDatabase(dbDirectory);
    try {
      for (final VideoBookRow row in await db.allVideoBooks()) {
        final String videoPath =
            _rebaseVideoPath(row.videoPath, meta.videoFiles, newVideosRoot);
        final String? playlistJson = _rebaseVideoPlaylistJson(
          row.playlistJson,
          meta.videoFiles,
          newVideosRoot,
        );
        if (videoPath == row.videoPath && playlistJson == row.playlistJson) {
          continue;
        }
        await db.customStatement(
          'UPDATE video_books SET video_path = ?, playlist_json = ? '
          'WHERE book_uid = ?',
          <Object?>[videoPath, playlistJson, row.bookUid],
        );
      }
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      await db.close();
    }
  }

  static String _rebaseVideoPath(
    String oldPath,
    Map<String, String> sourcePathToArchiveRelative,
    String newVideosRoot,
  ) {
    final String? relativePath = sourcePathToArchiveRelative[oldPath];
    if (relativePath == null) return oldPath;
    return _restoredVideoPath(newVideosRoot, relativePath);
  }

  static String? _rebaseVideoPlaylistJson(
    String? playlistJson,
    Map<String, String> sourcePathToArchiveRelative,
    String newVideosRoot,
  ) {
    if (playlistJson == null || playlistJson.isEmpty) return playlistJson;
    try {
      final dynamic decoded = jsonDecode(playlistJson);
      if (decoded is! List) return playlistJson;
      bool changed = false;
      final List<dynamic> rewritten = decoded.map<dynamic>((dynamic entry) {
        if (entry is! Map) return entry;
        final Map<String, dynamic> row = Map<String, dynamic>.from(entry);
        final Object? path = row['path'];
        if (path is! String) return row;
        final String rebased =
            _rebaseVideoPath(path, sourcePathToArchiveRelative, newVideosRoot);
        if (rebased != path) {
          row['path'] = rebased;
          changed = true;
        }
        return row;
      }).toList();
      return changed ? jsonEncode(rewritten) : playlistJson;
    } catch (_) {
      return playlistJson;
    }
  }

  static String _restoredVideoPath(
    String videosRoot,
    String archiveRelativePath,
  ) {
    final String relative = archiveRelativePath.replaceAll(r'\', '/');
    final String normalizedRelative = p.posix.normalize(relative);
    if (relative.isEmpty ||
        p.posix.isAbsolute(relative) ||
        normalizedRelative == '..' ||
        normalizedRelative.startsWith('../')) {
      throw FormatException('Invalid backup video path: $archiveRelativePath');
    }
    final String targetPath =
        p.normalize(p.join(videosRoot, normalizedRelative));
    final String canonicalRoot = p.canonicalize(videosRoot);
    final String canonicalTarget = p.canonicalize(targetPath);
    if (canonicalTarget != canonicalRoot &&
        !p.isWithin(canonicalRoot, canonicalTarget)) {
      throw FormatException('Invalid backup video path: $archiveRelativePath');
    }
    return targetPath;
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
