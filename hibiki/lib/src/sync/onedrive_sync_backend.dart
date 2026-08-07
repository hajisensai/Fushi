import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/pkce_oauth.dart';
import 'package:fushi/src/sync/sync_http.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_backend_file_trio_mixin.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_root_migration.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/ttu_models.dart';
import 'package:url_launcher/url_launcher.dart';

/// OneDrive sync backend via Microsoft Graph API.
///
/// Auth: OAuth 2.0 PKCE flow.
/// Redirect URI: `hibiki://auth/onedrive`
class OneDriveSyncBackend extends SyncBackend
    with SyncFolderCache, SyncBackendFileTrioMixin, SyncAssetStoreDefaults {
  OneDriveSyncBackend._();
  static final OneDriveSyncBackend instance = OneDriveSyncBackend._();

  static const _clientId = '49f7e6d1-fab5-48ef-90ab-13ce04986b46';

  /// Whether a real OAuth client ID has been configured. Until it is, the
  /// backend cannot authenticate, so the UI hides it from the picker.
  static bool get isConfigured => !_clientId.startsWith('YOUR_');

  static const _redirectUri = 'fushi://auth/onedrive';
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

  /// Shared OAuth 2.0 PKCE token exchange (verifier/challenge + code/refresh).
  /// OneDrive requires the `scope` param echoed on token refresh.
  static final PkceOAuthFlow _oauth = PkceOAuthFlow(
    clientId: _clientId,
    tokenEndpoint: _tokenEndpoint,
    extraRefreshBody: const <String, String>{'scope': _scopes},
  );

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

    final verifier = PkceOAuthFlow.generateCodeVerifier();
    final challenge = PkceOAuthFlow.codeChallenge(verifier);

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
    final tokens = await _oauth.exchangeCode(
      code: code,
      redirectUri: redirectUri,
      verifier: verifier,
    );
    _accessToken = tokens.accessToken;
    _refreshToken = tokens.refreshToken;

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

    final tokens = await _oauth.refreshTokens(refreshToken: _refreshToken!);
    _accessToken = tokens.accessToken;
    if (tokens.refreshToken != null) {
      _refreshToken = tokens.refreshToken;
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
    final resp = await (await obtainSyncHttpClient()).get(
      Uri.parse('$_apiBase$path'),
      headers: _authHeaders,
    );
    _checkResponse(resp, 'GET $path');
    return resp;
  }

  Future<http.Response> _graphPost(
      String path, Map<String, dynamic> body) async {
    final resp = await (await obtainSyncHttpClient()).post(
      Uri.parse('$_apiBase$path'),
      headers: _authHeaders,
      body: jsonEncode(body),
    );
    _checkResponse(resp, 'POST $path');
    return resp;
  }

  Future<http.Response> _graphPatch(
      String path, Map<String, dynamic> body) async {
    final resp = await (await obtainSyncHttpClient()).patch(
      Uri.parse('$_apiBase$path'),
      headers: _authHeaders,
      body: jsonEncode(body),
    );
    _checkResponse(resp, 'PATCH $path');
    return resp;
  }

  Future<http.Response> _graphPut(String path, List<int> bytes,
      {String contentType = 'application/octet-stream'}) async {
    final resp = await (await obtainSyncHttpClient()).put(
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
    final resp = await (await obtainSyncHttpClient()).delete(
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
    if (rootFolderIdCache != null) return rootFolderIdCache!;

    // Fushi 改名迁移三段（找新根 → 旧根 Graph PATCH 改名 → 新建）。根在普通
    // My Drive 根路径（`/me/drive/root:/<name>`，非 approot）；item id 不随改名
    // 变化，云端数据原地不动。结果经 rootFolderIdCache 记忆化，旧根探测仅在
    // 新根缺席时发生。
    final String? existing = await migrateLegacySyncRoot<String>(
      find: (String name) async {
        try {
          final resp = await _graphGet('/me/drive/root:/$name');
          final json = jsonDecode(resp.body) as Map<String, dynamic>;
          return json['id'] as String;
        } on SyncBackendError catch (e) {
          if (e.isRetryable) return null; // 404：不存在。
          rethrow;
        }
      },
      renameLegacy: (String legacyId) async {
        await _graphPatch(
            '/me/drive/items/$legacyId', {'name': _rootFolderName});
        return legacyId;
      },
      onRenameError: (Object e, StackTrace st) => ErrorLogService.instance
          .log('OneDriveSyncBackend.migrateLegacyRoot', e, st),
    );
    if (existing != null) {
      rootFolderIdCache = existing;
      return existing;
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
    rootFolderIdCache = json['id'] as String;
    return rootFolderIdCache!;
  }

  @override
  Future<List<SyncFileRef>> listBooks(String rootFolderId) async {
    final items = await _listChildren('/me/drive/items/$rootFolderId/children');
    return items
        .where((item) => item.containsKey('folder'))
        .map((item) => SyncFileRef(
              id: item['id'] as String,
              name: item['name'] as String,
            ))
        .toList();
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final sanitized = requireBookFolderName(bookTitle);

    if (folderIdCache.containsKey(sanitized)) {
      return folderIdCache[sanitized]!;
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
    folderIdCache[sanitized] = folderId;

    final Uint8List? coverData = await readCoverData?.call();
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
  Future<SyncFileTrio> listSyncFiles(String folderId) async {
    final items = await _listChildren('/me/drive/items/$folderId/children');
    final files = items
        .where((item) => !item.containsKey('folder'))
        .map((item) => SyncFileRef(
              id: item['id'] as String,
              name: item['name'] as String,
            ))
        .toList();

    return SyncFileTrio(
      progress: findSyncFileByPrefix(files, 'progress_'),
      statistics: findSyncFileByPrefix(files, 'statistics_'),
      audioBook: findSyncFileByPrefix(files, 'audioBook_'),
    );
  }

  // get{Progress,Stats,AudioBook}File 三件套由 SyncBackendFileTrioMixin 提供；
  // 这里只给出 OneDrive 的下载原语（Graph item content GET + jsonDecode）。
  @override
  Future<Object?> readJsonById(String fileId) => _downloadItemJson(fileId);

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
    final streamedResp = await (await obtainSyncHttpClient()).send(request);
    if (streamedResp.statusCode >= 400) {
      throw SyncBackendError(
          'Download failed: HTTP ${streamedResp.statusCode}');
    }

    await writeSyncStreamToFile(
      source: streamedResp.stream,
      destination: destination,
      totalBytes: streamedResp.contentLength,
      onProgress: onProgress,
    );
  }

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) async {
    final items = await _listChildren('/me/drive/items/$folderId/children');
    for (final item in items) {
      if (item['name'] == fileName) {
        return SyncFileRef(
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
  //
  // 缓存字段 + 六个 cache 方法收敛进 [SyncFolderCache] mixin（恒等 folderId，无尾
  // 斜杠规范化）。

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
      final resp = await (await obtainSyncHttpClient())
          .get(Uri.parse(url), headers: _authHeaders);
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

    final resp =
        await (await obtainSyncHttpClient()).get(Uri.parse(downloadUrl));
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

  static String _guessContentType(String fileName) =>
      guessSyncContentType(fileName);
}
