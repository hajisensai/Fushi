import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

class SftpSyncBackend extends SyncBackend {
  SftpSyncBackend._();
  static final SftpSyncBackend instance = SftpSyncBackend._();

  /// Sync root folder, RELATIVE to the SFTP login directory (the user's home),
  /// never the server filesystem root. An absolute '/ttu-reader-data' fails on
  /// a normal non-chrooted sshd (permission denied at '/'). The name is kept
  /// identical to the other backends so one library syncs across them.
  @visibleForTesting
  static const String rootFolderName = 'ttu-reader-data';

  final _opLock = AsyncMutex();
  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  String? _host;
  int? _port;
  String? _username;
  String? _password;
  String? _privateKey;
  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async =>
      _host != null &&
      _username != null &&
      (_password != null || _privateKey != null);

  @override
  Future<String?> get currentEmail async =>
      _username != null && _host != null ? '$_username@$_host' : null;

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    final host = await repo.getSftpHost();
    final port = await repo.getSftpPort();
    final user = await repo.getSftpUsername();
    final pass = await repo.getSftpPassword();
    final key = await repo.getSftpPrivateKey();

    if (host == null || user == null) {
      throw SyncAuthError('SFTP credentials not configured');
    }
    if (pass == null && key == null) {
      throw SyncAuthError('SFTP requires either a password or private key');
    }

    _host = host;
    _port = port;
    _username = user;
    _password = pass;
    _privateKey = key;

    await _ensureConnected();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _disconnect();
    _host = null;
    _port = null;
    _username = null;
    _password = null;
    _privateKey = null;
    await repo.setSftpHost(null);
    await repo.setSftpUsername(null);
    await repo.setSftpPassword(null);
    await repo.setSftpPrivateKey(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final host = await repo.getSftpHost();
    final user = await repo.getSftpUsername();
    final pass = await repo.getSftpPassword();
    final key = await repo.getSftpPrivateKey();

    if (host == null || user == null) return false;
    if (pass == null && key == null) return false;

    _host = host;
    _port = await repo.getSftpPort();
    _username = user;
    _password = pass;
    _privateKey = key;
    return true;
  }

  @override
  Future<void> refreshAuth() async {
    // SSH connections don't have token refresh; reconnect if stale.
    if (_sshClient != null && _sshClient!.isClosed) {
      _sftpClient = null;
      _sshClient = null;
    }
  }

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() => _guarded(() async {
        if (_rootFolderId != null) return _rootFolderId!;

        final sftp = await _ensureConnected();
        await _mkdirIfAbsent(sftp, rootFolderName);
        _rootFolderId = rootFolderName;
        return rootFolderName;
      });

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        final entries = await sftp.listdir(rootFolderId);
        return entries
            .where((e) =>
                e.attr.isDirectory && e.filename != '.' && e.filename != '..')
            .map((e) => DriveFile(
                  id: '$rootFolderId/${e.filename}',
                  name: e.filename,
                ))
            .toList();
      });

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _guarded(() async {
        final sanitized = sanitizeTtuFilename(bookTitle);

        if (_titleToFolderId.containsKey(sanitized)) {
          return _titleToFolderId[sanitized]!;
        }

        final sftp = await _ensureConnected();
        final path = '$rootFolderId/$sanitized';
        await _mkdirIfAbsent(sftp, path);
        _titleToFolderId[sanitized] = path;

        if (coverData != null) {
          try {
            final format = detectCoverFormat(coverData);
            final coverPath = '$path/cover_1_6.${format.extension}';
            if (!await _fileExists(sftp, coverPath)) {
              await _writeBytes(sftp, coverPath, coverData);
            }
          } catch (_) {}
        }

        return path;
      });

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        final entries = await sftp.listdir(folderId);
        final files = entries
            .where((e) =>
                !e.attr.isDirectory && e.filename != '.' && e.filename != '..')
            .map((e) => DriveFile(
                  id: '$folderId/${e.filename}',
                  name: e.filename,
                ))
            .toList();

        return DriveSyncFiles(
          progress: findSyncFileByPrefix(files, 'progress_'),
          statistics: findSyncFileByPrefix(files, 'statistics_'),
          audioBook: findSyncFileByPrefix(files, 'audioBook_'),
        );
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
      _guarded(() async {
        final sftp = await _ensureConnected();
        if (fileId != null) await _deleteIfExists(sftp, fileId);
        final fileName =
            progressFileName(progress.lastBookmarkModified, progress.progress);
        await _uploadJson(sftp, folderId, fileName, progress.toJson());
      });

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        if (fileId != null) await _deleteIfExists(sftp, fileId);
        final fileName = statisticsFileName(stats);
        await _uploadJson(
            sftp, folderId, fileName, stats.map((s) => s.toJson()).toList());
      });

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        if (fileId != null) await _deleteIfExists(sftp, fileId);
        final fileName = audioBookFileName(
            audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
        await _uploadJson(sftp, folderId, fileName, audioBook.toJson());
      });

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        final remotePath = '$folderId/$fileName';
        final length = await file.length();

        final handle = await sftp.open(
          remotePath,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.write |
              SftpFileOpenMode.truncate,
        );
        try {
          int offset = 0;
          await for (final chunk in file.openRead()) {
            final bytes = Uint8List.fromList(chunk);
            await handle.writeBytes(bytes, offset: offset);
            offset += bytes.length;
            if (length > 0) onProgress?.call(offset / length);
          }
        } finally {
          await handle.close();
        }
      });

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        final stat = await sftp.stat(fileId);
        final totalSize = stat.size ?? 0;

        final handle = await sftp.open(fileId, mode: SftpFileOpenMode.read);
        bool success = false;
        final sink = destination.openWrite();
        try {
          int received = 0;
          await for (final chunk in handle.read()) {
            sink.add(chunk);
            received += chunk.length;
            if (totalSize > 0) onProgress?.call(received / totalSize);
          }
          success = true;
        } finally {
          await handle.close();
          await sink.close();
          if (!success) {
            try {
              destination.deleteSync();
            } catch (_) {}
          }
        }
      });

  @override
  Future<DriveFile?> findContentFile(
          String folderId, String fileName) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        final path = '$folderId/$fileName';
        if (!await _fileExists(sftp, path)) return null;
        return DriveFile(id: path, name: fileName);
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

  // ── Test connection ───────────────────────────────────────────────

  Future<void> testConnection({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKey,
  }) async {
    if (password == null && privateKey == null) {
      throw SyncAuthError('Either password or private key is required');
    }

    SSHClient? client;
    try {
      client = SSHClient(
        await SSHSocket.connect(host, port),
        username: username,
        onPasswordRequest: password != null ? () => password : null,
        identities: privateKey != null ? _parseIdentities(privateKey) : null,
      );
      // Verify the connection is usable by opening an SFTP session.
      final sftp = await client.sftp();
      sftp.close();
    } on SSHAuthFailError {
      throw SyncAuthError('Authentication failed');
    } on SSHAuthAbortError {
      throw SyncAuthError('Authentication aborted');
    } on SocketException catch (e) {
      throw SyncBackendError('Connection failed: ${e.message}');
    } catch (e) {
      if (e is SyncAuthError || e is SyncBackendError) rethrow;
      throw SyncBackendError('Connection failed: $e');
    } finally {
      client?.close();
    }
  }

  /// Wipe stored credentials from the repository without clearing
  /// in-memory connection state. Call [signOut] for full cleanup.
  Future<void> clearCredentials(SyncRepository repo) async {
    await repo.setSftpHost(null);
    await repo.setSftpUsername(null);
    await repo.setSftpPassword(null);
    await repo.setSftpPrivateKey(null);
  }

  // ── Private: connection management ────────────────────────────────

  Future<SftpClient> _ensureConnected() async {
    if (_sftpClient != null && _sshClient != null && !_sshClient!.isClosed) {
      return _sftpClient!;
    }

    // Tear down stale references.
    _sftpClient = null;
    _sshClient = null;

    if (_host == null || _username == null) {
      throw SyncAuthError('SFTP credentials not configured');
    }
    if (_password == null && _privateKey == null) {
      throw SyncAuthError('SFTP requires either a password or private key');
    }

    try {
      _sshClient = SSHClient(
        await SSHSocket.connect(_host!, _port ?? 22),
        username: _username!,
        onPasswordRequest: _password != null ? () => _password! : null,
        identities: _privateKey != null ? _parseIdentities(_privateKey!) : null,
      );
      _sftpClient = await _sshClient!.sftp();
      return _sftpClient!;
    } on SSHAuthFailError {
      _disconnect();
      throw SyncAuthError('Authentication failed');
    } on SSHAuthAbortError {
      _disconnect();
      throw SyncAuthError('Authentication aborted');
    } on SocketException catch (e) {
      _disconnect();
      throw SyncBackendError(
        'Connection failed: ${e.message}',
        isRetryable: true,
      );
    } catch (e) {
      _disconnect();
      if (e is SyncAuthError || e is SyncBackendError) rethrow;
      throw SyncBackendError('Connection failed: $e', isRetryable: true);
    }
  }

  void _disconnect() {
    try {
      _sftpClient?.close();
    } catch (_) {}
    try {
      _sshClient?.close();
    } catch (_) {}
    _sftpClient = null;
    _sshClient = null;
  }

  /// Runs [op] under the op lock and translates raw SFTP failures into the
  /// SyncBackend error contract. SyncAuthError/SyncBackendError pass through;
  /// a per-file [SftpStatusError] or any other transport failure becomes a
  /// RETRYABLE SyncBackendError so SyncManager retries (recreating folders as
  /// needed) — matching FTP/WebDAV — instead of escaping uncaught and the sync
  /// being silently skipped (HBK-AUDIT-161).
  Future<T> _guarded<T>(Future<T> Function() op) {
    return _opLock.withLock(() async {
      try {
        return await op();
      } on SyncAuthError {
        rethrow;
      } on SyncBackendError {
        rethrow;
      } on SftpStatusError catch (e) {
        // Per-file failure; the connection is still usable, so keep it.
        throw SyncBackendError('SFTP error: $e', isRetryable: true);
      } catch (e) {
        // Transport/IO failure — drop the (likely dead) connection so the
        // retry reconnects.
        _disconnect();
        throw SyncBackendError('SFTP operation failed: $e', isRetryable: true);
      }
    });
  }

  List<SSHKeyPair> _parseIdentities(String pem) {
    try {
      return SSHKeyPair.fromPem(pem);
    } catch (e) {
      throw SyncAuthError('Invalid private key: $e');
    }
  }

  // ── Private: SFTP helpers ─────────────────────────────────────────

  Future<void> _mkdirIfAbsent(SftpClient sftp, String path) async {
    try {
      final stat = await sftp.stat(path);
      if (stat.isDirectory) return;
      throw SyncBackendError('Path exists but is not a directory: $path');
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) {
        await sftp.mkdir(path);
        return;
      }
      rethrow;
    }
  }

  Future<bool> _fileExists(SftpClient sftp, String path) async {
    try {
      await sftp.stat(path);
      return true;
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return false;
      rethrow;
    }
  }

  Future<void> _deleteIfExists(SftpClient sftp, String path) async {
    try {
      await sftp.remove(path);
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return;
      rethrow;
    }
  }

  Future<dynamic> _downloadJson(String fileId) => _guarded(() async {
        final sftp = await _ensureConnected();
        final handle = await sftp.open(fileId, mode: SftpFileOpenMode.read);
        try {
          final bytes = await handle.readBytes();
          final text = utf8.decode(bytes);
          return jsonDecode(text);
        } finally {
          await handle.close();
        }
      });

  Future<void> _uploadJson(
    SftpClient sftp,
    String folderId,
    String fileName,
    dynamic data,
  ) async {
    final path = '$folderId/$fileName';
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    await _writeBytes(sftp, path, bytes);
  }

  Future<void> _writeBytes(
      SftpClient sftp, String path, Uint8List bytes) async {
    final handle = await sftp.open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await handle.writeBytes(bytes);
    } finally {
      await handle.close();
    }
  }

}
