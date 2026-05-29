import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

/// SMB/CIFS sync backend that delegates to WebDAV over HTTP.
///
/// There is no pure-Dart SMB library. Instead the user sets up an external
/// SMB-to-WebDAV bridge (e.g. `rclone serve webdav`, NAS built-in WebDAV,
/// or any reverse proxy) and provides the resulting WebDAV endpoint URL.
///
/// This is a WebDAV-bridge-only facade: the only credentials it reads/writes
/// are the WebDAV endpoint URL, username and password. SMB host/share/domain
/// are NOT captured by the settings form and are never read, so they are not
/// touched here (HBK-AUDIT-086). All actual I/O goes through standard WebDAV
/// (PROPFIND / GET / PUT / MKCOL / DELETE) via [WebDavOps].
class SmbSyncBackend extends SyncBackend {
  SmbSyncBackend._();
  static final SmbSyncBackend instance = SmbSyncBackend._();

  WebDavOps? _ops;
  String? _username;
  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async => _ops != null;

  @override
  Future<String?> get currentEmail async => _username;

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    final webDavUrl = await repo.getSmbWebDavUrl();
    final user = await repo.getSmbUsername();
    final pass = await repo.getSmbPassword();

    if (webDavUrl == null || user == null || pass == null) {
      throw SyncAuthError('SMB credentials not configured');
    }

    final normalized = WebDavOps.normalizeUrl(webDavUrl);
    _ops = WebDavOps(baseUrl: normalized, username: user, password: pass);
    _username = user;

    await _ops!.testConnection();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _ops?.close();
    _ops = null;
    _username = null;
    // Only WebDAV-bridge credentials are ever set, so clear only those.
    // host/share/domain are write-null-only ghosts; not cleared (HBK-AUDIT-086).
    await repo.setSmbUsername(null);
    await repo.setSmbPassword(null);
    await repo.setSmbWebDavUrl(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final webDavUrl = await repo.getSmbWebDavUrl();
    final user = await repo.getSmbUsername();
    final pass = await repo.getSmbPassword();

    if (webDavUrl == null || user == null || pass == null) return false;

    final normalized = WebDavOps.normalizeUrl(webDavUrl);
    _ops = WebDavOps(baseUrl: normalized, username: user, password: pass);
    _username = user;
    return true;
  }

  @override
  Future<void> refreshAuth() async {}

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    final path = '${_ops!.baseUrl}/ttu-reader-data/';
    await _ops!.ensureCollection(path);
    _rootFolderId = path;
    return path;
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    final entries = await _ops!.propfindChildren(rootFolderId);
    return entries
        .where((e) => e.isCollection && e.href != rootFolderId)
        .map((e) => DriveFile(id: e.href, name: e.displayName))
        .toList();
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async {
    final sanitized = sanitizeTtuFilename(bookTitle);

    if (_titleToFolderId.containsKey(sanitized)) {
      return _titleToFolderId[sanitized]!;
    }

    final path = '$rootFolderId${Uri.encodeComponent(sanitized)}/';
    await _ops!.ensureCollection(path);
    _titleToFolderId[sanitized] = path;

    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverPath = '${path}cover_1_6.${format.extension}';
        final existing = await _ops!.headFile(coverPath);
        if (!existing) {
          await _ops!.putBytes(coverPath, coverData, format.mimeType);
        }
      } catch (_) {}
    }

    return path;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final entries = await _ops!.propfindChildren(folderId);
    final files = entries
        .where((e) => !e.isCollection && e.href != folderId)
        .map((e) => DriveFile(id: e.href, name: e.displayName))
        .toList();

    // HBK-AUDIT-085: route through the single canonical matcher in sync_utils.
    return DriveSyncFiles(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await _ops!.downloadJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _ops!.downloadJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _ops!.downloadJson(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _ops!.uploadJson(folderId, fileName, progress.toJson());
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName = statisticsFileName(stats);
    await _ops!
        .uploadJson(folderId, fileName, stats.map((s) => s.toJson()).toList());
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    if (fileId != null) await _ops!.deleteFile(fileId);
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _ops!.uploadJson(folderId, fileName, audioBook.toJson());
  }

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final length = await file.length();
    final request = await _ops!.buildRequest('PUT', path);
    request.headers.set('Content-Type', WebDavOps.guessContentType(fileName));
    request.headers.set('Content-Length', '$length');
    int bytesUploaded = 0;
    await request.addStream(file.openRead().map((chunk) {
      bytesUploaded += chunk.length;
      onProgress?.call(length > 0 ? bytesUploaded / length : 0);
      return chunk;
    }));
    final response = await request.close();
    await response.drain<void>();
    _ops!.checkStatus(response.statusCode, 'PUT $path');
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    final request = await _ops!.buildRequest('GET', fileId);
    final response = await request.close();
    _ops!.checkStatus(response.statusCode, 'GET $fileId');

    final contentLength = response.contentLength;
    final sink = destination.openWrite();
    int bytesReceived = 0;
    bool success = false;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(bytesReceived / contentLength);
        }
      }
      success = true;
    } finally {
      await sink.close();
      if (!success) {
        try {
          destination.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async {
    final path = '$folderId${Uri.encodeComponent(fileName)}';
    final exists = await _ops!.headFile(path);
    if (!exists) return null;
    return DriveFile(id: path, name: fileName);
  }

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
    required String url,
    required String username,
    required String password,
  }) async {
    final ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: username,
      password: password,
    );
    try {
      await ops.testConnection();
    } finally {
      ops.close();
    }
  }
}
