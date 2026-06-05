import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:hibiki/src/sync/desktop_oauth.dart';
import 'package:hibiki/src/sync/sync_http.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_utils.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:url_launcher/url_launcher.dart';

/// OneDrive sync backend via Microsoft Graph API.
///
/// Auth: OAuth 2.0 PKCE flow.
/// Redirect URI: `hibiki://auth/onedrive`
class OneDriveSyncBackend extends SyncBackend {
  OneDriveSyncBackend._();
  static final OneDriveSyncBackend instance = OneDriveSyncBackend._();

  static const _clientId = '49f7e6d1-fab5-48ef-90ab-13ce04986b46';

  /// Whether a real OAuth client ID has been configured. Until it is, the
  /// backend cannot authenticate, so the UI hides it from the picker.
  static bool get isConfigured => !_clientId.startsWith('YOUR_');

  static const _redirectUri = 'hibiki://auth/onedrive';
  static const _tokenEndpoint =
      'https://login.microsoftonline.com/common/oauth2/v2.0/token';
  static const _authorizeEndpoint =
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize';
  static const _apiBase = 'https://graph.microsoft.com/v1.0';
  static const _scopes = 'Files.ReadWrite.All User.Read offline_access';
  static const _rootFolderName = kSyncRootFolderName;

  String? _accessToken;
  String? _refreshToken;
  String? _email;
  String? _rootFolderId;
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

  Uri _buildAuthUrl(String challenge, String redirectUri) =>
      Uri.parse(_authorizeEndpoint).replace(queryParameters: {
        'client_id': _clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': _scopes,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      });

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    if (_clientId.startsWith('YOUR_')) {
      throw SyncAuthError('OneDrive integration not configured');
    }
    _pendingVerifier = null;
    _pendingRepo = null;

    final verifier = _generateCodeVerifier();
    final challenge = _generateCodeChallenge(verifier);

    // Desktop: loopback HTTP redirect (RFC 8252), exchange inline.
    if (isDesktopOAuthPlatform) {
      final result = await runDesktopOAuthLoopback(
        buildAuthUrl: (redirectUri) => _buildAuthUrl(challenge, redirectUri),
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
      throw SyncAuthError('Failed to launch browser for OneDrive auth');
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
    await repo.setOneDriveToken(jsonEncode({'refresh_token': _refreshToken}));
  }

  @override
  Future<void> signOut({required SyncRepository repo}) async {
    _accessToken = null;
    _refreshToken = null;
    _email = null;
    clearCache();
    await repo.setOneDriveToken(null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final stored = await repo.getOneDriveToken();
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
        'scope': _scopes,
      },
    );

    if (response.statusCode != 200) {
      throw SyncAuthError('Token refresh failed: ${response.statusCode}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _accessToken = json['access_token'] as String;
    if (json.containsKey('refresh_token')) {
      _refreshToken = json['refresh_token'] as String;
    }
  }

  Future<void> _fetchUserEmail() async {
    try {
      final resp = await _graphGet('/me');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      _email = json['mail'] as String? ?? json['userPrincipalName'] as String?;
    } catch (_) {
      // Non-fatal: email is optional for display.
    }
  }

  // ── HTTP helpers ──────────────────────────────────────────────────

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      };

  Future<http.Response> _graphGet(String path) async {
    final resp = await syncHttpClient.get(
      Uri.parse('$_apiBase$path'),
      headers: _authHeaders,
    );
    _checkResponse(resp, 'GET $path');
    return resp;
  }

  Future<http.Response> _graphPost(
      String path, Map<String, dynamic> body) async {
    final resp = await syncHttpClient.post(
      Uri.parse('$_apiBase$path'),
      headers: _authHeaders,
      body: jsonEncode(body),
    );
    _checkResponse(resp, 'POST $path');
    return resp;
  }

  Future<http.Response> _graphPut(String path, List<int> bytes,
      {String contentType = 'application/octet-stream'}) async {
    final resp = await syncHttpClient.put(
      Uri.parse('$_apiBase$path'),
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': contentType,
      },
      body: bytes,
    );
    _checkResponse(resp, 'PUT $path');
    return resp;
  }

  Future<http.Response> _graphDelete(String path) async {
    final resp = await syncHttpClient.delete(
      Uri.parse('$_apiBase$path'),
      headers: {'Authorization': 'Bearer $_accessToken'},
    );
    // 204 No Content is success for DELETE.
    if (resp.statusCode != 204 && resp.statusCode != 404) {
      _checkResponse(resp, 'DELETE $path');
    }
    return resp;
  }

  void _checkResponse(http.Response resp, String context) {
    if (resp.statusCode == 401) {
      throw SyncAuthError('Authentication expired: $context');
    }
    if (resp.statusCode == 404) {
      throw SyncBackendError('Not found: $context', isRetryable: true);
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

    // Try to find existing folder.
    try {
      final resp = await _graphGet('/me/drive/root:/$_rootFolderName');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      _rootFolderId = json['id'] as String;
      return _rootFolderId!;
    } on SyncBackendError catch (e) {
      if (!e.isRetryable) rethrow; // Only catch 404.
    }

    // Create the folder. (GET above already handled the existing case;
    // 'fail' is the only valid conflictBehavior here — 'useExisting' is not
    // a valid Graph value and returns HTTP 400.)
    final resp = await _graphPost('/me/drive/root/children', {
      'name': _rootFolderName,
      'folder': <String, dynamic>{},
      '@microsoft.graph.conflictBehavior': 'fail',
    });
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    _rootFolderId = json['id'] as String;
    return _rootFolderId!;
  }

  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async {
    final items = await _listChildren('/me/drive/items/$rootFolderId/children');
    return items
        .where((item) => item.containsKey('folder'))
        .map((item) => DriveFile(
              id: item['id'] as String,
              name: item['name'] as String,
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

    // Find the existing book folder first (idempotent); only create on 404.
    // 'useExisting' is not a valid conflictBehavior (HTTP 400), so we cannot
    // rely on a single create-or-reuse POST.
    String? folderId;
    try {
      final resp = await _graphGet(
          '/me/drive/items/$rootFolderId:/${Uri.encodeComponent(sanitized)}');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      folderId = json['id'] as String;
    } on SyncBackendError catch (e) {
      if (!e.isRetryable) rethrow; // Only catch 404.
    }

    if (folderId == null) {
      final resp = await _graphPost('/me/drive/items/$rootFolderId/children', {
        'name': sanitized,
        'folder': <String, dynamic>{},
        '@microsoft.graph.conflictBehavior': 'fail',
      });
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      folderId = json['id'] as String;
    }
    _titleToFolderId[sanitized] = folderId;

    if (coverData != null) {
      try {
        final format = detectCoverFormat(coverData);
        final coverName = 'cover_1_6.${format.extension}';
        final existing = await findContentFile(folderId, coverName);
        if (existing == null) {
          await _graphPut(
            '/me/drive/items/$folderId:/${Uri.encodeComponent(coverName)}:/content',
            coverData,
            contentType: format.mimeType,
          );
        }
      } catch (_) {/* best-effort: failure is non-critical here */}
    }

    return folderId;
  }

  // ── Metadata sync ─────────────────────────────────────────────────

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async {
    final items = await _listChildren('/me/drive/items/$folderId/children');
    final files = items
        .where((item) => !item.containsKey('folder'))
        .map((item) => DriveFile(
              id: item['id'] as String,
              name: item['name'] as String,
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
    final json = await _downloadItemJson(fileId);
    return TtuProgress.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async {
    final json = await _downloadItemJson(fileId);
    return (json as List)
        .cast<Map<String, dynamic>>()
        .map(TtuStatistics.fromJson)
        .toList();
  }

  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async {
    final json = await _downloadItemJson(fileId);
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
    await _uploadJson(folderId, fileName, progress.toJson());
    // Upload-then-delete: keep the old file until the new one is uploaded so a
    // failed upload never destroys the only copy (HBK-AUDIT-048).
    if (fileId != null) await _deleteItem(fileId);
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    final fileName = statisticsFileName(stats);
    await _uploadJson(
        folderId, fileName, stats.map((s) => s.toJson()).toList());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _deleteItem(fileId);
  }

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    final fileName = audioBookFileName(
        audioBook.lastAudioBookModified, audioBook.playbackPositionSec);
    await _uploadJson(folderId, fileName, audioBook.toJson());
    // Upload-then-delete (HBK-AUDIT-048).
    if (fileId != null) await _deleteItem(fileId);
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
    final request = http.StreamedRequest(
      'PUT',
      Uri.parse(
          '$_apiBase/me/drive/items/$folderId:/${Uri.encodeComponent(fileName)}:/content'),
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.headers['Content-Type'] = _guessContentType(fileName);
    request.contentLength = fileLength;

    final response = await streamUpload(request, file, fileLength, onProgress);
    _checkResponse(response, 'PUT upload $fileName');
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    // Get the download URL from item metadata.
    final metaResp = await _graphGet('/me/drive/items/$fileId');
    final meta = jsonDecode(metaResp.body) as Map<String, dynamic>;
    final downloadUrl = meta['@microsoft.graph.downloadUrl'] as String?;
    if (downloadUrl == null) {
      throw SyncBackendError('No download URL for item $fileId');
    }

    final request = http.Request('GET', Uri.parse(downloadUrl));
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
        } catch (_) {/* best-effort: failure is non-critical here */}
      }
    }
  }

  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async {
    final items = await _listChildren('/me/drive/items/$folderId/children');
    for (final item in items) {
      if (item['name'] == fileName) {
        return DriveFile(
            id: item['id'] as String, name: item['name'] as String);
      }
    }
    return null;
  }

  // ── SyncAssetStore implementation ─────────────────────────────────

  @override
  Future<String> ensureNamespace(String name) async {
    final rootId = await findOrCreateRootFolder();
    return _ensureChildFolder(rootId, name);
  }

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _ensureChildFolder(parentId, name);

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final items = await _listChildren('/me/drive/items/$namespaceId/children');
    return items
        .map((item) => AssetEntry(
              id: item['id'] as String,
              name: item['name'] as String,
              isFolder: item.containsKey('folder'),
              sizeBytes: (item['size'] as num?)?.toInt(),
            ))
        .toList();
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
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
  }) =>
      uploadContentFile(
        folderId: namespaceId,
        fileName: name,
        file: file,
        onProgress: onProgress,
      );

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) =>
      downloadContentFile(
        fileId: assetId,
        destination: destination,
        onProgress: onProgress,
      );

  @override
  Future<Object?> getJsonAsset(String assetId) => _downloadItemJson(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _uploadJson(namespaceId, name, json);

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    // AssetEntry.id 对 OneDrive 是不透明 item id；Graph DELETE 对文件夹递归删，
    // _graphDelete 已把 404 当作成功，天然幂等，isFolder 无需分支。其它错误
    // （网络/权限/协议）必须自然抛出，否则 UI 会把真实失败误报为「已删除」。
    await _deleteItem(id);
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

  /// Ensure a child folder named [name] exists directly under [parentId],
  /// returning its Graph item id. Find-then-create-on-404 (idempotent):
  /// 'useExisting' is not a valid conflictBehavior (HTTP 400), so a single
  /// create-or-reuse POST is not possible — same pattern as [ensureBookFolder].
  Future<String> _ensureChildFolder(String parentId, String name) async {
    try {
      final resp = await _graphGet(
          '/me/drive/items/$parentId:/${Uri.encodeComponent(name)}');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return json['id'] as String;
    } on SyncBackendError catch (e) {
      if (!e.isRetryable) rethrow; // Only catch 404.
    }

    final resp = await _graphPost('/me/drive/items/$parentId/children', {
      'name': name,
      'folder': <String, dynamic>{},
      '@microsoft.graph.conflictBehavior': 'fail',
    });
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['id'] as String;
  }

  Future<List<Map<String, dynamic>>> _listChildren(String firstPath) async {
    final items = <Map<String, dynamic>>[];
    String? url = '$_apiBase$firstPath';

    while (url != null) {
      final resp =
          await syncHttpClient.get(Uri.parse(url), headers: _authHeaders);
      _checkResponse(resp, 'GET $firstPath');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      items.addAll((json['value'] as List).cast<Map<String, dynamic>>());
      url = json['@odata.nextLink'] as String?;
    }

    return items;
  }

  Future<dynamic> _downloadItemJson(String fileId) async {
    final metaResp = await _graphGet('/me/drive/items/$fileId');
    final meta = jsonDecode(metaResp.body) as Map<String, dynamic>;
    final downloadUrl = meta['@microsoft.graph.downloadUrl'] as String?;
    if (downloadUrl == null) {
      throw SyncBackendError('No download URL for item $fileId');
    }

    final resp = await syncHttpClient.get(Uri.parse(downloadUrl));
    if (resp.statusCode >= 400) {
      throw SyncBackendError('Download failed: HTTP ${resp.statusCode}');
    }
    return jsonDecode(resp.body);
  }

  Future<void> _uploadJson(
      String folderId, String fileName, dynamic data) async {
    final bytes = utf8.encode(jsonEncode(data));
    await _graphPut(
      '/me/drive/items/$folderId:/${Uri.encodeComponent(fileName)}:/content',
      bytes,
      contentType: 'application/json',
    );
  }

  Future<void> _deleteItem(String fileId) async {
    await _graphDelete('/me/drive/items/$fileId');
  }

  static String _guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.epub')) return 'application/epub+zip';
    if (lower.endsWith('.m4b') || lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }
}
