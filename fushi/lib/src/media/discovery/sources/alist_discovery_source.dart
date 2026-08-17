/// AList v3 站点的发现源 adapter：标准 `/api/fs/list`（目录浏览）、
/// `/api/fs/search`（关键词搜索，站点开了索引才可用）、`/api/fs/get`
/// （下载时延迟取 `raw_url` 直链——签名临期，列表阶段取了也会过期）。
///
/// 一个实例 = 一个 AList 站；内置 alist.erogame.space，用户加任意站 = 再
/// 注册一个实例。匿名访问；站点要求登录时可给 [username]/[password]，
/// 首次请求前换 token（`/api/auth/login`），token 失效重登一次。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/utils/net/app_http.dart';

class AListDiscoverySource extends MediaDiscoverySource {
  AListDiscoverySource({
    required this.id,
    required this.displayName,
    required String baseUrl,
    required Iterable<DiscoveryMediaKind> kinds,
    this.priority = 20,
    this.username,
    this.password,
    http.Client? client,
  })  : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _kinds = Set<DiscoveryMediaKind>.unmodifiable(kinds),
        _client = client ?? createAppHttpIoClient();

  @override
  final String id;

  @override
  final String displayName;

  @override
  final int priority;

  final String? username;
  final String? password;

  final String _baseUrl;
  final Set<DiscoveryMediaKind> _kinds;
  final http.Client _client;

  /// 已换取的登录 token（匿名站恒 null）。
  String? _token;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        kinds: _kinds,
        supportsBrowse: true,
        supportsPaging: true,
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    final String path = request.path ?? '/';
    final Map<String, dynamic> data =
        await _post('/api/fs/list', <String, dynamic>{
      'path': path,
      'password': '',
      'page': request.page,
      'per_page': request.pageSize,
      'refresh': false,
    });
    final List<dynamic> content =
        (data['content'] as List<dynamic>?) ?? <dynamic>[];
    final int total = (data['total'] as num?)?.toInt() ?? content.length;
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final Map<String, dynamic> raw
                in content.cast<Map<String, dynamic>>())
              _entryFrom(raw, parent: path, kind: request.kind),
          ],
          page: request.page,
          hasMore: request.page * request.pageSize < total,
        ),
      ],
    );
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    final Map<String, dynamic> data =
        await _post('/api/fs/search', <String, dynamic>{
      'parent': '/',
      'keywords': request.query!.trim(),
      'scope': 0,
      'page': request.page,
      'per_page': request.pageSize,
      'password': '',
    });
    final List<dynamic> content =
        (data['content'] as List<dynamic>?) ?? <dynamic>[];
    final int total = (data['total'] as num?)?.toInt() ?? content.length;
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final Map<String, dynamic> raw
                in content.cast<Map<String, dynamic>>())
              _entryFrom(
                raw,
                parent: raw['parent'] as String? ?? '/',
                kind: request.kind,
              ),
          ],
          page: request.page,
          hasMore: request.page * request.pageSize < total,
        ),
      ],
    );
  }

  /// 下载时经 `/api/fs/get` 取带签名的 `raw_url`。
  @override
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    final Map<String, dynamic> data =
        await _post('/api/fs/get', <String, dynamic>{
      'path': item.id,
      'password': '',
    });
    final String? rawUrl = data['raw_url'] as String?;
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'resolvePayload',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'fs/get returned no raw_url',
      );
    }
    return DiscoveryHttpPayload(
      url: rawUrl,
      fileName: data['name'] as String?,
      sizeBytes: (data['size'] as num?)?.toInt(),
    );
  }

  DiscoveryEntry _entryFrom(
    Map<String, dynamic> raw, {
    required String parent,
    required DiscoveryMediaKind kind,
  }) {
    final String name = raw['name'] as String? ?? '';
    final bool isDir = raw['is_dir'] == true;
    final String fullPath = parent == '/' ? '/$name' : '$parent/$name';
    if (isDir) {
      return DiscoveryFolder(sourceId: id, title: name, path: fullPath);
    }
    final String? modified = raw['modified'] as String?;
    return DiscoveryResourceItem(
      sourceId: id,
      id: fullPath,
      title: name,
      kind: kind,
      payloadKind: DiscoveryPayloadKind.httpFile,
      // payload 留空 → 下载时 resolvePayload 取临期直链。
      sizeBytes: (raw['size'] as num?)?.toInt(),
      dateText: modified != null && modified.length >= 10
          ? modified.substring(0, 10)
          : modified,
    );
  }

  /// POST JSON → 校验 AList 信封（`code`/`message`/`data`）→ 返回 data。
  ///
  /// `code` 401 时若配了账号自动重登一次再试；其余非 200 code 一律按
  /// invalidResponse 失败上浮（信封 message 是站点自述文案，脱敏保留）。
  Future<Map<String, dynamic>> _post(
    String apiPath,
    Map<String, dynamic> body, {
    bool retriedAuth = false,
  }) async {
    await _ensureToken();
    final http.Response response = await _client.post(
      Uri.parse('$_baseUrl$apiPath'),
      headers: <String, String>{
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': _token!,
      },
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: apiPath,
        kind: ExternalProviderFailureKind.unavailable,
        message: 'http status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final Map<String, dynamic> envelope =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final int code = (envelope['code'] as num?)?.toInt() ?? -1;
    if (code == 401 && !retriedAuth && username != null) {
      _token = null;
      return _post(apiPath, body, retriedAuth: true);
    }
    if (code != 200) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: apiPath,
        kind: code == 401 || code == 403
            ? ExternalProviderFailureKind.unauthorized
            : ExternalProviderFailureKind.invalidResponse,
        message: 'alist code $code: ${envelope['message'] ?? ''}',
        statusCode: code,
      );
    }
    return (envelope['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  Future<void> _ensureToken() async {
    final String? user = username;
    if (user == null || _token != null) return;
    final http.Response response = await _client.post(
      Uri.parse('$_baseUrl/api/auth/login'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'username': user,
        'password': password ?? '',
      }),
    );
    final Map<String, dynamic> envelope =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final String? token =
        (envelope['data'] as Map<String, dynamic>?)?['token'] as String?;
    if (response.statusCode != 200 || token == null || token.isEmpty) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: '/api/auth/login',
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'alist login failed',
        statusCode: response.statusCode,
      );
    }
    _token = token;
  }

  @override
  void close() => _client.close();
}
