import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class FtpSyncBackend extends SyncBackend {
  FtpSyncBackend._();
  static final FtpSyncBackend instance = FtpSyncBackend._();

  static const String _rootPath = '/ttu-reader-data';

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
          await _client!.changeDirectory('/');
          _rootFolderId = _rootPath;
          return _rootPath;
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          throw SyncBackendError('Failed to find/create root folder: $e');
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
          throw SyncBackendError('Failed to list books: $e');
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
          await _client!.changeDirectory('/');
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
              await _client!.changeDirectory('/');
            } catch (_) {
              // Cover upload is best-effort.
            }
          }

          return folderPath;
        } catch (e) {
          if (e is SyncBackendError || e is SyncAuthError) rethrow;
          throw SyncBackendError('Failed to ensure book folder: $e');
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
          throw SyncBackendError('Failed to list sync files: $e');
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
        if (fileId != null) await _deleteRemoteFileImpl(fileId);
        final fileName =
            progressFileName(progress.lastBookmarkModified, progress.progress);
        await _uploadJsonImpl(folderId, fileName, progress.toJson());
      });

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        if (fileId != null) await _deleteRemoteFileImpl(fileId);
        final fileName = statisticsFileName(stats);
        await _uploadJsonImpl(
            folderId, fileName, stats.map((s) => s.toJson()).toList());
      });

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        if (fileId != null) await _deleteRemoteFileImpl(fileId);
        final fileName = audioBookFileName(
            audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
        await _uploadJsonImpl(folderId, fileName, audioBook.toJson());
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
          throw SyncBackendError('Failed to upload content file: $e');
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
          throw SyncBackendError('Failed to download content file: $e');
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
          throw SyncBackendError('Failed to find content file: $e');
        }
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

  // ── Private helpers ───────────────────────────────────────────────

  Future<dynamic> _downloadJson(String fileId) => _opLock.withLock(() async {
        await _ensureConnected();
        final dir = _parentPath(fileId);
        final name = _fileName(fileId);
        final tmpFile = File(
            '${Directory.systemTemp.path}/hibiki_ftp_dl_${DateTime.now().millisecondsSinceEpoch}.json');
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
          throw SyncBackendError('Failed to download JSON: $e');
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
      throw SyncBackendError('Failed to upload JSON: $e');
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
    final path =
        '${Directory.systemTemp.path}/hibiki_${prefix}_${DateTime.now().millisecondsSinceEpoch}.tmp';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _deleteTempFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
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
