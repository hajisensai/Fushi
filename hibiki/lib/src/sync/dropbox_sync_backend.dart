import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki/src/sync/desktop_oauth.dart';
import 'package:hibiki/src/sync/sync_http.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:url_launcher/url_launcher.dart';

/// Dropbox sync backend via Dropbox API v2.
///
/// Auth: OAuth 2.0 PKCE flow.
/// Folder IDs are path strings like `/ttu-reader-data/BookTitle`.
class DropboxSyncBackend extends SyncBackend {
  DropboxSyncBackend._();
  static final DropboxSyncBackend instance = DropboxSyncBackend._();

  static const _clientId = 'lt0ufixv6si14dc';

  /// Whether a real OAuth app key has been configured. Until it is, the
  /// backend cannot authenticate, so the UI hides it from the picker.
  static bool get isConfigured => !_clientId.startsWith('YOUR_');

  static const _redirectUri = 'hibiki://auth/dropbox';
  static const _authorizeEndpoint = 'https://www.dropbox.com/oauth2/authorize';
  static const _tokenEndpoint = 'https://api.dropboxapi.com/oauth2/token';
  static const _apiBase = 'https://api.dropboxapi.com/2';
  static const _contentBase = 'https://content.dropboxapi.com/2';
  static const _rootFolderPath = '/ttu-reader-data';

  String? _accessToken;
  String? _refreshToken;
  String? _email;
  String? _rootFolderId; // Path string.
  final Map<String, String> _titleToFolderId = {};

  // ── OAuth PKCE helpers ──────────────────────────────────────────────

  static String _generateCodeVerifier() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  // ── Auth ──────────────────────────────────────────────────────────

  @override
  Future<bool> get isAuthenticated async => _accessToken != null;

  @override
  Future<String?> get currentEmail async => _email;

  String? _pendingVerifier;
  SyncRepository? _pendingRepo;

  /// Fixed loopback port for desktop OAuth. Dropbox requires an exact
  /// redirect-URI match, so this must be registered verbatim in the Dropbox
  /// app console as `http://localhost:9004`.
  static const int _desktopLoopbackPort = 9004;

  Uri _buildAuthUrl(String challenge, String redirectUri) =>
      Uri.parse(_authorizeEndpoint).replace(queryParameters: {
        'client_id': _clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'token_access_type': 'offline',
      });

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    if (_clientId.startsWith('YOUR_')) {
      throw SyncAuthError('Dropbox integration not configured');
    }
    _pendingVerifier = null;
    _pendingRepo = null;

    final verifier = _generateCodeVerifier();
    final challenge = _generateCodeChallenge(verifier);

    // Desktop: loopback HTTP redirect (RFC 8252), exchange inline.
    if (isDesktopOAuthPlatform) {
      final result = await runDesktopOAuthLoopback(
        buildAuthUrl: (redirectUri) => _buildAuthUrl(challenge, redirectUri),
        port: _desktopLoopbackPort,
      );
      await _exchangeCode(
        code: result.code,
        verifier: verifier,
        redirectUri: result.redirectUri,
        repo: repo,
      );
      return;
    }

    // Mobile: custom-URI-scheme redirect handled later by [handleAuthCode].
    final authUrl = _buildAuthUrl(challenge, _redirectUri);
    if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
      throw SyncAuthError('Failed to launch browser for Dropbox auth');
    }

    _pendingVerifier = verifier;
    _pendingRepo = repo;
  }

  /// Called when the app receives the redirect URI with an auth code (mobile
  /// custom-scheme flow).
  Future<void> handleAuthCode(String code) async {
    final verifier = _pendingVerifier;
    final repo = _pendingRepo;
    if (verifier == null || repo == null) {
      throw SyncAuthError('No pending auth flow');
    }
    _pendingVerifier = null;
    _pendingRepo = null;

    await _exchangeCode(
      code: code,
      verifier: verifier,
      redirectUri: _redirectUri,
      repo: repo,
    );
  }

  /// Exchange an authorization code for tokens. [redirectUri] must match the
  /// value sent in the authorization request (custom scheme on mobile, the
  /// loopback URL on desktop).
  Future<void> _exchangeCode({
    required String code,
    required String verifier,
    required String redirectUri,
    required SyncRepository repo,
  }) async {
    final response = await syncHttpClient.post(
      Uri.parse(_tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _clientId,
        'code': code,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      },
    );

    if (response.statusCode != 200) {
      throw SyncAuthError(
          'Token exchange failed: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = json['access_token'] as String;
    _refreshToken = json['refresh_token'] as String?;

    await _fetchUserEmail();
    await repo.setDropboxToken(jsonEncode({'refresh_token': _refreshToken}));
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    // Revoke the token.
    if (_accessToken != null) {
      try {
        await syncHttpClient.post(
          Uri.parse('$_apiBase/auth/token/revoke'),
          headers: {'Authorization': 'Bearer $_accessToken'},
        );
      } catch (_) {}
    }
    _accessToken = null;
    _refreshToken = null;
    _email = null;
    clearCache();
    await repo.setDropboxToken(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final stored = await repo.getDropboxToken();
    if (stored == null) return false;

    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      _refreshToken = json['refresh_token'] as String?;
      if (_refreshToken == null) return false;

      await refreshAuth();
      await _fetchUserEmail();
      return true;
    } catch (_) {
      // Refresh failed — drop the stale tokens so isAuthenticated reports
      // false instead of letting sync proceed with an expired token and loop
      // on non-retryable 401s (HBK-AUDIT-159).
      _accessToken = null;
      _refreshToken = null;
      return false;
    }
  }

  @override
  Future<void> refreshAuth() async {
    if (_refreshToken == null) {
      throw SyncAuthError('No refresh token available');
    }

    final response = await syncHttpClient.post(
      Uri.parse(_tokenEndpoint),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': _clientId,
        'grant_type': 'refresh_token',
        'refresh_token': _refreshToken!,
      },
    );

    if (response.statusCode != 200) {
      throw SyncAuthError('Token refresh failed: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = json['access_token'] as String;
    // Dropbox may or may not return a new refresh token.
    if (json.containsKey('refresh_token')) {
      _refreshToken = json['refresh_token'] as String;
    }
  }

  Future<void> _fetchUserEmail() async {
    try {
      final resp = await _apiPost('/users/get_current_account', null);
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      _email = json['email'] as String?;
    } catch (_) {
      // Non-fatal.
    }
  }

  // ── HTTP helpers ──────────────────────────────────────────────────

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      };

  Future<http.Response> _apiPost(
      String endpoint, Map<String, dynamic>? body) async {
    final resp = await syncHttpClient.post(
      Uri.parse('$_apiBase$endpoint'),
      headers: _authHeaders,
      body: body != null ? jsonEncode(body) : null,
    );
    _checkResponse(resp, 'POST $endpoint');
    return resp;
  }

  void _checkResponse(http.Response resp, String context) {
    if (resp.statusCode == 401) {
      throw SyncAuthError('Authentication expired: $context');
    }
    if (resp.statusCode == 409) {
      // Dropbox uses 409 for path/not_found and conflict errors.
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final error = body['error'] as Map<String, dynamic>?;
      final tag = error?['.tag'] as String?;
      if (tag == 'path' || tag == 'path_lookup') {
        throw SyncBackendError('Not found: $context', isRetryable: true);
      }
      throw SyncBackendError(
          '$context failed: HTTP ${resp.statusCode} ${resp.body}');
    }
    if (resp.statusCode >= 400) {
      throw SyncBackendError(
          '$context failed: HTTP ${resp.statusCode} ${resp.body}');
    }
  }

  // ── Folder operations ─────────────────────────────────────────────

  @override
  Future<String> findOrCreateRootFolder() async {
    if (_rootFolderId != null) return _rootFolderId!;

    // Try to get metadata for the root folder.
    try {
      await _apiPost('/files/get_metadata', {'path': _rootFolderPath});
      _rootFolderId = _rootFolderPath;
      return _rootFolderId!;
    } on SyncBackendError catch (e) {
      if (!e.isRetryable) rethrow;
    }

    // Create the folder.
    try {
      await _apiPost('/files/create_folder_v2', {
        'path': _rootFolderPath,
        'autorename': false,
      });
    } on SyncBackendError catch (e) {
      // 409 conflict means it already exists — that is fine.
      if (!e.message.contains('409')) rethrow;
    }

    _rootFolderId = _rootFolderPath;
    return _rootFolderId!;
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    final entries = await _listFolder(rootFolderId);
    return entries
        .where((e) => e['.tag'] == 'folder')
        .map((e) => DriveFile(
              id: e['path_lower'] as String? ?? e['path_display'] as String,
              name: e['name'] as String,
            ))
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

    final folderPath = '$rootFolderId/$sanitized';

    // Try to create; ignore conflict if it already exists.
    try {
      await _apiPost('/files/create_folder_v2', {
        'path': folderPath,
        'autorename': false,
      });
    } on SyncBackendError catch (e) {
      if (!e.message.contains('409')) rethrow;
    }

    _titleToFolderId[sanitized] = folderPath;

    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverName = 'cover_1_6.${format.extension}';
        final existing = await findContentFile(folderPath, coverName);
        if (existing == null) {
          await _uploadBytes(
            '$folderPath/$coverName',
            coverData,
            mode: 'add',
          );
        }
      } catch (_) {}
    }

    return folderPath;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final entries = await _listFolder(folderId);
    final files = entries
        .where((e) => e['.tag'] == 'file')
        .map((e) => DriveFile(
              id: e['path_lower'] as String? ?? e['path_display'] as String,
              name: e['name'] as String,
            ))
        .toList();

    return DriveSyncFiles(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }

  @override
  Future<TtuProgress> getProgressFile(String fileId) async {
    final json = await _downloadFileJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _downloadFileJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _downloadFileJson(fileId);
    return TtuAudioBook.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    final fileName =
        progressFileName(progress.lastBookmarkModified, progress.progress);
    await _uploadJsonFile(folderId, fileName, progress.toJson());
    // Upload-then-delete: keep the old file until the new one is uploaded so a
    // failed upload never destroys the only copy (HBK-AUDIT-048).
    if (fileId != null) await _deleteFile(fileId);
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    final fileName = statisticsFileName(stats);
    await _uploadJsonFile(
        folderId, fileName, stats.map((s) => s.toJson()).toList());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _deleteFile(fileId);
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _uploadJsonFile(folderId, fileName, audioBook.toJson());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _deleteFile(fileId);
  }

  // ── Content file sync ─────────────────────────────────────────────

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    final fileLength = await file.length();
    final apiArg = jsonEncode({
      'path': '$folderId/$fileName',
      'mode': 'overwrite',
      'autorename': false,
      'mute': true,
    });
    final request = http.StreamedRequest(
      'POST',
      Uri.parse('$_contentBase/files/upload'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.headers['Content-Type'] = 'application/octet-stream';
    request.headers['Dropbox-API-Arg'] = apiArg;
    request.contentLength = fileLength;

    final response = await streamUpload(request, file, fileLength, onProgress);
    if (response.statusCode != 200) {
      throw SyncBackendError(
          'Dropbox upload failed: ${response.statusCode} ${response.body}');
    }
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    final apiArg = jsonEncode({'path': fileId});
    final request = http.Request(
      'POST',
      Uri.parse('$_contentBase/files/download'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.headers['Dropbox-API-Arg'] = apiArg;

    final streamedResp = await syncHttpClient.send(request);
    if (streamedResp.statusCode >= 400) {
      throw SyncBackendError(
          'Download failed: HTTP ${streamedResp.statusCode}');
    }

    final totalBytes = streamedResp.contentLength ?? -1;
    final sink = destination.openWrite();
    int bytesReceived = 0;
    bool success = false;
    try {
      await for (final chunk in streamedResp.stream) {
        sink.add(chunk);
        bytesReceived += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(bytesReceived / totalBytes);
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
    final path = '$folderId/$fileName';
    try {
      final resp = await _apiPost('/files/get_metadata', {'path': path});
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return DriveFile(
        id: json['path_lower'] as String? ?? json['path_display'] as String,
        name: json['name'] as String,
      );
    } on SyncBackendError catch (e) {
      if (e.isRetryable) return null; // 404 / path not found.
      rethrow;
    }
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

  // ── Private helpers ───────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _listFolder(String path) async {
    final resp = await _apiPost('/files/list_folder', {
      'path': path,
      'include_deleted': false,
    });
    var json = jsonDecode(resp.body) as Map<String, dynamic>;
    final entries = (json['entries'] as List).cast<Map<String, dynamic>>();

    while (json['has_more'] == true) {
      final contResp = await _apiPost('/files/list_folder/continue', {
        'cursor': json['cursor'] as String,
      });
      json = jsonDecode(contResp.body) as Map<String, dynamic>;
      entries.addAll((json['entries'] as List).cast<Map<String, dynamic>>());
    }

    return entries;
  }

  Future<dynamic> _downloadFileJson(String fileId) async {
    final apiArg = jsonEncode({'path': fileId});
    final resp = await syncHttpClient.post(
      Uri.parse('$_contentBase/files/download'),
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Dropbox-API-Arg': apiArg,
      },
    );
    if (resp.statusCode >= 400) {
      throw SyncBackendError(
          'Download failed: HTTP ${resp.statusCode} ${resp.body}');
    }
    return jsonDecode(resp.body);
  }

  Future<void> _uploadJsonFile(
      String folderId, String fileName, dynamic data) async {
    final bytes = utf8.encode(jsonEncode(data));
    await _uploadBytes(
      '$folderId/$fileName',
      bytes,
      mode: 'overwrite',
    );
  }

  Future<void> _uploadBytes(
    String path,
    List<int> bytes, {
    String mode = 'add',
  }) async {
    final apiArg = jsonEncode({
      'path': path,
      'mode': mode,
      'autorename': false,
      'mute': true,
    });

    final resp = await syncHttpClient.post(
      Uri.parse('$_contentBase/files/upload'),
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Dropbox-API-Arg': apiArg,
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );

    if (resp.statusCode >= 400) {
      throw SyncBackendError(
          'Upload failed: HTTP ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> _deleteFile(String path) async {
    try {
      await _apiPost('/files/delete_v2', {'path': path});
    } on SyncBackendError catch (e) {
      // Ignore not-found on delete.
      if (!e.isRetryable) rethrow;
    }
  }
}
