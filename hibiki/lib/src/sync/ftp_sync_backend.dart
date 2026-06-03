import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class FtpSyncBackend extends SyncBackend {
  FtpSyncBackend._();
  static final FtpSyncBackend instance = FtpSyncBackend._();

  /// The login directory captured via PWD on connect (the user's home, or the
  /// chroot root). Defaults to '/' until connected.
  ///
  /// NOTE: the persisted folder cache (rootFolderId / titleToFolderId) embeds
  /// this home-anchored absolute path. If the same (host, user) ever reports a
  /// different home across sessions, restored cache entries become stale — but
  /// the op then throws a retryable error and SyncManager clears the cache and
  /// reconnects, which re-captures PWD. So it self-heals; it is not persisted
  /// data loss.
  String _homeDir = '/';

  /// Sync root, anchored UNDER the login home — never the raw server root. A
  /// chrooted server reports PWD '/', so this reproduces the legacy
  /// '/ttu-reader-data' exactly (no data move); a normal server reports the
  /// real home, so the folder lands there instead of failing at '/'.
  String get _rootPath => ftpRootPath(_homeDir);

  /// Pure helper for [_rootPath]; exposed for testing.
  @visibleForTesting
  static String ftpRootPath(String home) {
    final String trimmed = home.replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/ttu-reader-data' : '$trimmed/ttu-reader-data';
  }

  /// Normalize a PWD reply into a clean directory path (strip surrounding
  /// quotes and trailing slashes; fall back to '/').
  static String _normalizeFtpDir(String raw) {
    var dir = raw.trim();
    if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
      dir = dir.substring(1, dir.length - 1);
    }
    dir = dir.replaceAll(RegExp(r'/+$'), '');
    return dir.isEmpty ? '/' : dir;
  }

  final _opLock = AsyncMutex();
  FTPConnect? _client;
  String? _host;
  int _port = 21;
  String? _username;
  String? _password;
  bool _useTls = false;
  bool _connected = false;

  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};

  // Collision-proof temp-file naming (HBK-AUDIT-087). A millisecond timestamp
  // is not unique: two ops in the same ms — or a second isolate/app instance
  // sharing systemTemp — produce identical paths and clobber each other's
  // in-flight transfer. The secure-random token + per-instance counter make
  // the name unique regardless of clock resolution or concurrent callers.
  static final Random _tempRng = Random.secure();
  int _tempCounter = 0;

  /// Build a collision-proof temp path under [Directory.systemTemp] for the
  /// given [prefix]/[extension]. Combines a per-instance counter with a
  /// secure-random suffix so concurrent or sub-millisecond callers never
  /// collide (HBK-AUDIT-087).
  File _uniqueTempFile(String prefix, String extension) {
    final int seq = _tempCounter++;
    final int token = _tempRng.nextInt(1 << 32);
    final String name =
        'hibiki_${prefix}_${seq}_${token.toRadixString(16)}$extension';
    return File('${Directory.systemTemp.path}/$name');
  }

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async =>
      _host != null && _username != null && _password != null;

  @override
  Future<String?> get currentEmail async => _username;

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    final host = await repo.getFtpHost();
    final port = await repo.getFtpPort();
    final user = await repo.getFtpUsername();
    final pass = await repo.getFtpPassword();
    final tls = await repo.isFtpTlsEnabled();

    if (host == null || user == null || pass == null) {
      throw SyncAuthError('FTP credentials not configured');
    }

    _host = host;
    _port = port;
    _username = user;
    _password = pass;
    _useTls = tls;

    await _connect();
    await _disconnect();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    await _disconnect();
    _host = null;
    _username = null;
    _password = null;
    _useTls = false;
    _port = 21;
    clearCache();
    await repo.setFtpHost(null);
    await repo.setFtpUsername(null);
    await repo.setFtpPassword(null);
    await repo.setFtpTlsEnabled(false);
    await repo.setFtpPort(21);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final host = await repo.getFtpHost();
    final user = await repo.getFtpUsername();
    final pass = await repo.getFtpPassword();

    if (host == null || user == null || pass == null) return false;

    _host = host;
    _port = await repo.getFtpPort();
    _username = user;
    _password = pass;
    _useTls = await repo.isFtpTlsEnabled();
    return true;
  }

  @override
  Future<void> refreshAuth() async {
    // FTP uses username/password, no token refresh needed.
  }

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() => _opLock.withLock(() async {
        if (_rootFolderId != null) return _rootFolderId!;

        await _ensureConnected();
        try {
          final exists = await _client!.checkFolderExistence(_rootPath);
          if (!exists) {
            final created = await _client!.makeDirectory(_rootPath);
            if (!created) {
              throw SyncBackendError(
                  'Failed to create root folder: $_rootPath');
            }
          }
          await _client!.changeDirectory(_homeDir);
          _rootFolderId = _rootPath;
          return _rootPath;
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to find/create root folder: $e',
              isRetryable: true);
        }
      });

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(rootFolderId);
          final entries = await _client!.listDirectoryContent();
          return entries
              .where((e) => e.type == FTPEntryType.dir)
              .map((e) => DriveFile(
                    id: '$rootFolderId/${e.name}',
                    name: e.name,
                  ))
              .toList();
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to list books: $e', isRetryable: true);
        }
      });

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _opLock.withLock(() async {
        final sanitized = sanitizeTtuFilename(bookTitle);

        if (_titleToFolderId.containsKey(sanitized)) {
          return _titleToFolderId[sanitized]!;
        }

        final folderPath = '$rootFolderId/$sanitized';
        await _ensureConnected();
        try {
          final exists = await _client!.checkFolderExistence(folderPath);
          if (!exists) {
            await _client!.changeDirectory(rootFolderId);
            final created = await _client!.makeDirectory(sanitized);
            if (!created) {
              throw SyncBackendError(
                  'Failed to create book folder: $folderPath');
            }
          }
          await _client!.changeDirectory(_homeDir);
          _titleToFolderId[sanitized] = folderPath;

          if (coverData != null) {
            try {
              final format = detectCoverFormat(coverData);
              final coverName = 'cover_1_6.${format.extension}';
              await _client!.changeDirectory(folderPath);
              final coverExists = await _client!.existFile(coverName);
              if (!coverExists) {
                final tmpFile = await _writeTempFile(coverData, 'cover');
                try {
                  await _client!.uploadFile(tmpFile, sRemoteName: coverName);
                } finally {
                  await _deleteTempFile(tmpFile);
                }
              }
              await _client!.changeDirectory(_homeDir);
            } catch (_) {
              // Cover upload is best-effort.
            }
          }

          return folderPath;
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to ensure book folder: $e',
              isRetryable: true);
        }
      });

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(folderId);
          final entries = await _client!.listDirectoryContent();
          final files = entries
              .where((e) => e.type == FTPEntryType.file)
              .map((e) => DriveFile(id: '$folderId/${e.name}', name: e.name))
              .toList();

          return DriveSyncFiles(
            progress: findSyncFileByPrefix(files, 'progress_'),
            statistics: findSyncFileByPrefix(files, 'statistics_'),
            audioBook: findSyncFileByPrefix(files, 'audioBook_'),
          );
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to list sync files: $e',
              isRetryable: true);
        }
      });

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _downloadJson(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        final fileName =
            progressFileName(progress.lastBookmarkModified, progress.progress);
        await _uploadJsonImpl(folderId, fileName, progress.toJson());
        // Upload-then-delete: keep the old file until the new one is uploaded
        // so a failed upload never loses the only copy (HBK-AUDIT-048).
        if (fileId != null) await _deleteRemoteFileImpl(fileId);
      });

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        final fileName = statisticsFileName(stats);
        await _uploadJsonImpl(
            folderId, fileName, stats.map((s) => s.toJson()).toList());
        // Upload-then-delete (HBK-AUDIT-048).
        if (fileId != null) await _deleteRemoteFileImpl(fileId);
      });

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        final fileName = audioBookFileName(
            audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
        await _uploadJsonImpl(folderId, fileName, audioBook.toJson());
        // Upload-then-delete (HBK-AUDIT-048).
        if (fileId != null) await _deleteRemoteFileImpl(fileId);
      });

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(folderId);
          await _client!.uploadFile(
            file,
            sRemoteName: fileName,
            onProgress: onProgress != null
                ? (percent, received, total) => onProgress(percent / 100.0)
                : null,
          );
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to upload content file: $e',
              isRetryable: true);
        }
      });

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        final dir = _parentPath(fileId);
        final name = _fileName(fileId);
        try {
          await _client!.changeDirectory(dir);
          await _client!.downloadFile(
            name,
            destination,
            onProgress: onProgress != null
                ? (percent, received, total) => onProgress(percent / 100.0)
                : null,
          );
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to download content file: $e',
              isRetryable: true);
        }
      });

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(folderId);
          final exists = await _client!.existFile(fileName);
          if (!exists) return null;
          return DriveFile(id: '$folderId/$fileName', name: fileName);
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to find content file: $e',
              isRetryable: true);
        }
      });

  // ── Generic asset store (SyncAssetStore) ──────────────────────────
  //
  // Ids are home-anchored absolute FTP paths: a namespace's id is the folder
  // path under [_rootPath], and an asset's id is `'<folderId>/<name>'`. All
  // direct-client operations take [_opLock] and call [_ensureConnected] (same
  // shape as findOrCreateRootFolder / ensureBookFolder / listBooks). Methods
  // that merely delegate to an already-locking public op (uploadContentFile /
  // downloadContentFile / findContentFile / _downloadJson) must NOT re-wrap in
  // [_opLock] — AsyncMutex is non-reentrant and would deadlock.

  @override
  Future<String> ensureNamespace(String name) =>
      _ensureFolderAt(_rootPath, name);

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _ensureFolderAt(parentId, name);

  /// Ensure a child folder [name] exists under [parentId] and return its
  /// home-anchored absolute path `'<parentId>/<name>'`. Mirrors the
  /// create-if-missing path of ensureBookFolder (checkFolderExistence →
  /// changeDirectory(parent) → makeDirectory(name)).
  Future<String> _ensureFolderAt(String parentId, String name) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        final folderPath = '$parentId/$name';
        try {
          final exists = await _client!.checkFolderExistence(folderPath);
          if (!exists) {
            await _client!.changeDirectory(parentId);
            final created = await _client!.makeDirectory(name);
            if (!created) {
              throw SyncBackendError('Failed to create folder: $folderPath');
            }
          }
          await _client!.changeDirectory(_homeDir);
          return folderPath;
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to ensure folder: $e',
              isRetryable: true);
        }
      });

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          await _client!.changeDirectory(namespaceId);
          final entries = await _client!.listDirectoryContent();
          return entries
              .map((e) => AssetEntry(
                    id: '$namespaceId/${e.name}',
                    name: e.name,
                    isFolder: e.type == FTPEntryType.dir,
                  ))
              .toList();
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to list children: $e',
              isRetryable: true);
        }
      });

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    // Delegates to the already-locking findContentFile; do not re-wrap.
    final file = await findContentFile(namespaceId, name);
    if (file == null) return null;
    return AssetEntry(id: file.id, name: file.name);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) {
    // Delegates to the already-locking uploadContentFile; do not re-wrap.
    return uploadContentFile(
      folderId: namespaceId,
      fileName: name,
      file: file,
      onProgress: onProgress,
    );
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) {
    // Delegates to the already-locking downloadContentFile; do not re-wrap.
    return downloadContentFile(
      fileId: assetId,
      destination: destination,
      onProgress: onProgress,
    );
  }

  @override
  Future<Object?> getJsonAsset(String assetId) {
    // Delegates to the already-locking _downloadJson (temp-file → utf8 →
    // jsonDecode); do not re-wrap.
    return _downloadJson(assetId);
  }

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        // _uploadJsonImpl writes utf8(jsonEncode(...)) to a temp file and
        // uploads to `'<namespaceId>/<name>'` (same path as updateProgressFile).
        await _uploadJsonImpl(namespaceId, name, json);
      });

  // ── Cache ─────────────────────────────────────────────────────────

  @override
  void clearCache() {
    _rootFolderId = null;
    _titleToFolderId.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _rootFolderId = rootFolderId;
    if (titleToFolderId != null) {
      _titleToFolderId.addAll(titleToFolderId);
    }
  }

  @override
  String? get cachedRootFolderId => _rootFolderId;

  @override
  Map<String, String> get cachedFolderIds => Map.unmodifiable(_titleToFolderId);

  @override
  void cacheBookFolderIds(List<DriveFile> folders) {
    for (final f in folders) {
      _titleToFolderId[f.name] = f.id;
    }
  }

  // ── Credentials ───────────────────────────────────────────────────

  /// Wipe stored credentials from the repository without clearing
  /// in-memory connection state. Call [signOut] for full cleanup.
  Future<void> clearCredentials(SyncRepository repo) async {
    await repo.setFtpHost(null);
    await repo.setFtpUsername(null);
    await repo.setFtpPassword(null);
    await repo.setFtpTlsEnabled(false);
    await repo.setFtpPort(21);
  }

  // ── Test connection ───────────────────────────────────────────────

  /// Verify FTP credentials without persisting any state.
  static Future<void> testConnection({
    required String host,
    required int port,
    required String username,
    required String password,
    required bool useTls,
  }) async {
    final client = FTPConnect(
      host,
      port: port,
      user: username,
      pass: password,
      securityType: useTls ? SecurityType.ftps : SecurityType.ftp,
      timeout: 15,
    );
    try {
      final ok = await client.connect();
      if (!ok) throw SyncAuthError('FTP authentication failed');
      await client.disconnect();
    } on FTPConnectException catch (e) {
      throw SyncBackendError('FTP connection failed: ${e.message}');
    } catch (e) {
      if (e is SyncAuthError || e is SyncBackendError) rethrow;
      throw SyncBackendError('FTP connection failed: $e');
    }
  }

  // ── Connection management ─────────────────────────────────────────

  Future<void> _connect() async {
    if (_host == null || _username == null || _password == null) {
      throw SyncAuthError('FTP credentials not set');
    }
    _client = FTPConnect(
      _host!,
      port: _port,
      user: _username!,
      pass: _password!,
      securityType: _useTls ? SecurityType.ftps : SecurityType.ftp,
      timeout: 30,
    );
    try {
      final ok = await _client!.connect();
      if (!ok) {
        _client = null;
        throw SyncAuthError('FTP authentication failed');
      }
      _connected = true;
      // Anchor all paths under the login directory rather than the raw server
      // root. Best-effort: if PWD fails, fall back to '/' (legacy behavior).
      try {
        _homeDir = _normalizeFtpDir(await _client!.currentDirectory());
      } catch (_) {
        _homeDir = '/';
      }
    } on FTPConnectException catch (e) {
      _client = null;
      _connected = false;
      throw SyncBackendError('FTP connection failed: ${e.message}');
    }
  }

  Future<void> _disconnect() async {
    if (_client != null && _connected) {
      try {
        await _client!.disconnect();
      } catch (_) {
        // Best-effort disconnect.
      }
    }
    _client = null;
    _connected = false;
  }

  Future<void> _ensureConnected() async {
    if (_client != null && _connected) return;
    await _connect();
  }

  /// Drop the current connection handle without network I/O. Called when an
  /// operation fails on a possibly-dead control socket (FTP servers close
  /// idle connections) so the next [_ensureConnected] reconnects instead of
  /// reusing a stale socket. Pairs with throwing a retryable error so the
  /// SyncManager retry reconnects within the same sync.
  void _resetConnection() {
    final stale = _client;
    _client = null;
    _connected = false;
    // Best-effort close the (possibly half-open) control socket so its file
    // descriptor is released. Fire-and-forget: the connection may be dead and
    // disconnect() could block, so we never await it here.
    if (stale != null) {
      unawaited(stale.disconnect().then<void>((_) {}, onError: (_) {}));
    }
  }

  // ── Private helpers ───────────────────────────────────────────────

  Future<dynamic> _downloadJson(String fileId) => _opLock.withLock(() async {
        await _ensureConnected();
        final dir = _parentPath(fileId);
        final name = _fileName(fileId);
        final tmpFile = _uniqueTempFile('ftp_dl', '.json');
        try {
          await _client!.changeDirectory(dir);
          final ok = await _client!.downloadFile(name, tmpFile);
          if (!ok) {
            throw SyncBackendError('Failed to download: $fileId',
                isRetryable: true);
          }
          final content = await tmpFile.readAsString(encoding: utf8);
          return jsonDecode(content);
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          _resetConnection();
          throw SyncBackendError('Failed to download JSON: $e',
              isRetryable: true);
        } finally {
          await _deleteTempFile(tmpFile);
        }
      });

  Future<void> _uploadJsonImpl(
      String folderId, String fileName, dynamic data) async {
    final bytes = utf8.encode(jsonEncode(data));
    final tmpFile = await _writeTempFile(bytes, 'ftp_ul');
    try {
      await _client!.changeDirectory(folderId);
      final ok = await _client!.uploadFile(tmpFile, sRemoteName: fileName);
      if (!ok) {
        throw SyncBackendError('Failed to upload: $folderId/$fileName');
      }
    } catch (e) {
      if (e is SyncBackendError || e is SyncAuthError) rethrow;
      _resetConnection();
      throw SyncBackendError('Failed to upload JSON: $e', isRetryable: true);
    } finally {
      await _deleteTempFile(tmpFile);
    }
  }

  Future<void> _deleteRemoteFileImpl(String fileId) async {
    final dir = _parentPath(fileId);
    final name = _fileName(fileId);
    try {
      await _client!.changeDirectory(dir);
      await _client!.deleteFile(name);
    } catch (e) {
      // Deletion failure is non-fatal for update operations.
    }
  }

  /// Write [bytes] to a uniquely-named temp file and return it.
  Future<File> _writeTempFile(List<int> bytes, String prefix) async {
    final file = _uniqueTempFile(prefix, '.tmp');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _deleteTempFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {/* best-effort: failure is non-critical here */}
  }

  /// Extract the parent directory from an FTP path.
  static String _parentPath(String path) {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  /// Extract the file name from an FTP path.
  static String _fileName(String path) {
    final idx = path.lastIndexOf('/');
    if (idx < 0) return path;
    return path.substring(idx + 1);
  }
}
