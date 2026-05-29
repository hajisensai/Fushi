import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

/// Probes whether a single Hibiki server URL is reachable with [token].
/// Returns true if reachable, false on connectivity failure/timeout, and
/// throws [SyncAuthError] if the server rejects the token.
typedef HibikiProbe = Future<bool> Function(String url, String token);

/// Picks the first reachable URL from [candidates] (in order, skipping
/// disabled ones). A [SyncAuthError] from a probe propagates immediately —
/// every candidate shares one token, so one rejection means all fail. Throws
/// a retryable [SyncBackendError] when no enabled candidate is reachable.
Future<String> resolveReachableHibikiUrl(
  List<HibikiClientUrl> candidates,
  String token,
  HibikiProbe probe,
) async {
  for (final HibikiClientUrl candidate in candidates) {
    if (!candidate.enabled) continue;
    if (await probe(candidate.url, token)) return candidate.url;
  }
  throw SyncBackendError(
    'No reachable Hibiki server address',
    isRetryable: true,
  );
}

/// Default probe: a short-timeout WebDAV connection test. Connectivity
/// failures and timeouts map to `false` (unreachable); a rejected token
/// surfaces as [SyncAuthError] so the resolver stops trying other addresses.
Future<bool> _defaultHibikiProbe(String url, String token) async {
  WebDavOps? ops;
  try {
    ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
    );
    await ops.testConnection().timeout(HibikiClientSyncBackend.probeTimeout);
    return true;
  } on SyncAuthError {
    rethrow;
  } catch (_) {
    return false;
  } finally {
    ops?.close();
  }
}

/// Sync backend for connecting to another Hibiki instance's embedded server.
///
/// Uses the WebDAV protocol (same as [WebDavSyncBackend]) but stores
/// credentials in dedicated keys to avoid collision with the user's
/// standalone WebDAV config.
class HibikiClientSyncBackend extends SyncBackend {
  HibikiClientSyncBackend._({HibikiProbe? probe})
      : _probe = probe ?? _defaultHibikiProbe;
  static final HibikiClientSyncBackend instance =
      HibikiClientSyncBackend._();

  /// Test seam: inject a fake reachability probe.
  @visibleForTesting
  HibikiClientSyncBackend.withProbe(HibikiProbe probe) : _probe = probe;

  /// How long to wait for a single address probe before treating it as
  /// unreachable and trying the next candidate. Short so LAN-first failover
  /// to WAN is quick when you are away from home.
  static const Duration probeTimeout = Duration(seconds: 2);

  final HibikiProbe _probe;
  List<HibikiClientUrl> _candidates = const <HibikiClientUrl>[];
  String? _token;
  bool _sessionResolved = false;

  WebDavOps? _ops;
  String? _rootFolderId;
  final Map<String, String> _titleToFolderId = {};

  /// Test seam: force address resolution without performing a folder op.
  @visibleForTesting
  Future<void> ensureResolved() => _ensureResolved();

  /// Test seam: the base URL the session has settled on.
  @visibleForTesting
  String? get activeBaseUrl => _ops?.baseUrl;

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async => _ops != null;

  @override
  Future<String?> get currentEmail async => 'hibiki';

  Future<void> _loadConfig(SyncRepository repo) async {
    _candidates = (await repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList();
    _token = await repo.getHibikiClientToken();
    _sessionResolved = false;
  }

  /// Builds a provisional [WebDavOps] on the first well-formed candidate so
  /// [isAuthenticated] reflects "configured". The actually-reachable address
  /// is chosen later by [_ensureResolved] on the first network operation.
  void _buildProvisionalOps() {
    _ops?.close();
    _ops = null;
    if (_token == null) return;
    for (final HibikiClientUrl candidate in _candidates) {
      try {
        _ops = WebDavOps(
          baseUrl: WebDavOps.normalizeUrl(candidate.url),
          username: 'hibiki',
          password: _token!,
        );
        return;
      } on SyncBackendError {
        continue; // malformed URL — keep looking for a usable handle
      }
    }
  }

  /// Probes the candidate addresses (in order) and settles the session on the
  /// first reachable one. Switching addresses rebuilds [_ops] and clears the
  /// folder cache, whose paths embed the previous base URL.
  Future<void> _ensureResolved() async {
    if (_sessionResolved) return;
    final String? token = _token;
    if (token == null) {
      throw SyncAuthError('Hibiki server credentials not configured');
    }
    final String chosen =
        await resolveReachableHibikiUrl(_candidates, token, _probe);
    final String normalized = WebDavOps.normalizeUrl(chosen);
    if (_ops == null || _ops!.baseUrl != normalized) {
      _ops?.close();
      _ops =
          WebDavOps(baseUrl: normalized, username: 'hibiki', password: token);
      clearCache();
    }
    _sessionResolved = true;
  }

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    await _loadConfig(repo);
    if (_candidates.isEmpty || _token == null) {
      throw SyncAuthError('Hibiki server credentials not configured');
    }
    // Probes + selects a reachable address (or throws), confirming the token
    // is accepted by the server.
    await _ensureResolved();
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _ops?.close();
    _ops = null;
    _candidates = const <HibikiClientUrl>[];
    _token = null;
    _sessionResolved = false;
    await repo.setHibikiClientUrls(const <HibikiClientUrl>[]);
    // Also wipe the legacy single-url key, else getHibikiClientUrls would
    // migrate it back on the next read.
    // ignore: deprecated_member_use_from_same_package
    await repo.setHibikiClientUrl(null);
    await repo.setHibikiClientToken(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    await _loadConfig(repo);
    if (_candidates.isEmpty || _token == null) {
      _ops?.close();
      _ops = null;
      return false;
    }
    _buildProvisionalOps();
    return _ops != null;
  }

  @override
  Future<void> refreshAuth() async {}

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    await _ensureResolved();
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
      } catch (e) {
        debugPrint('[hibiki-client] cover upload failed: $e');
      }
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

    return DriveSyncFiles(
      progress: WebDavOps.findByPrefix(files, 'progress_'),
      statistics: WebDavOps.findByPrefix(files, 'statistics_'),
      audioBook: WebDavOps.findByPrefix(files, 'audioBook_'),
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
    await _ops!.uploadJson(
        folderId, fileName, stats.map((s) => s.toJson()).toList());
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
        } catch (e) {
          debugPrint('[hibiki-client] failed to clean up temp file: $e');
        }
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
    required String token,
  }) async {
    final ops = WebDavOps(
      baseUrl: WebDavOps.normalizeUrl(url),
      username: 'hibiki',
      password: token,
    );
    try {
      await ops.testConnection();
    } finally {
      ops.close();
    }
  }
}
