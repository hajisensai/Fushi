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

  /// search 结果路径相对 `fs/list` 命名空间多出来的前缀，已归一：无前缀时为空串。
  ///
  /// BUG-1771：AList 的 `/api/fs/search` 返回的 `parent` 在**用户根命名空间**里
  /// （erogame.space 的 guest 是 `/guest`），而 `/api/fs/list` 与 `/api/fs/get`
  /// 收的是**相对该根**的路径。原样把 search 的 `parent` 当路径用，站点对每一条
  /// 都回 `object not found` —— 搜索结果里的目录一个都打不开、文件一个都下不了。
  /// 实测：`/guest/其他/…/Leaf/WHITE ALBUM2` → 500 object not found；
  /// 剥掉 `/guest` 后 → 200，`fs/get` 拿到真实 `raw_url`。
  /// null = 还没推断出结论（下次继续试）；`''` = 推断过、和搜索结果同命名空间、
  /// 无需剥；`'/guest'` = 推断过、要剥这一段。
  ///
  /// 刻意用可空而不是「`''` + 一个 _basePathProbed 布尔」：那样 `''` 同时背着
  /// 「没推断」和「推断出无需剥」两个意思，两份状态一旦不同步就会出现「一次探测
  /// 失败即永久放弃」——而失败恰恰是最该重试的情形。合成一份就没有这个边界。
  String? _basePath;

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
    // 先拿本次结果里的 parent 当样本反推命名空间前缀，再逐条转换（BUG-1771）。
    // 推断失败只是不剥前缀，不影响本次搜索返回。
    await _ensureBasePath(<String>[
      for (final Map<String, dynamic> raw
          in content.cast<Map<String, dynamic>>())
        if (raw['parent'] is String) raw['parent'] as String,
    ]);
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[
        DiscoveryResultPage(
          entries: <DiscoveryEntry>[
            for (final Map<String, dynamic> raw
                in content.cast<Map<String, dynamic>>())
              _entryFrom(
                raw,
                parent: _stripBasePath(raw['parent'] as String? ?? '/'),
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

  /// 反推 search 命名空间相对 `fs/list` 命名空间多出来的前缀。
  ///
  /// 判据只用**本来就必须能用**的 `fs/list '/'`：真实根下的第一层名字一定会出现在
  /// search 的 `parent` 里，它**之前**的那一段就是前缀。例如根是 `[其他, 年份合集]`、
  /// parent 是 `/guest/其他/…`，`其他` 落在第 2 段，于是前缀 = `/guest`。
  ///
  /// 为什么不问 `/api/me`（它直接给 `base_path`）：本机实测 alist.erogame.space 的
  /// `/api/me` **直连 3/3 连接超时**，而同一时刻 `fs/list` / `fs/search` /
  /// `/api/public/settings` / 首页都正常。拿一个可能连不上的端点当前置依赖，
  /// 结果是每次首搜先白等一个连接超时，然后照样拿不到前缀——比不做还差。
  /// 这里改成只依赖已有链路，且推断失败就退回「不剥前缀」的老行为。
  Future<void> _ensureBasePath(Iterable<String> sampleParents) async {
    if (_basePath != null) return;
    final List<String> samples = sampleParents
        .where((String p) => p.startsWith('/') && p.length > 1)
        .toList(growable: false);
    if (samples.isEmpty) return; // 没样本，下次再推
    // 注意：这里不做任何「已尝试」标记。下面每条不产生结论的出口（根目录列不出、
    // 样本一个都对不上、网络异常）都必须让 _basePath 保持 null，否则本会话再也
    // 不会重推，而搜索结果的目录会一直打不开。只有两个 return 才算有结论。
    try {
      final Map<String, dynamic> data =
          await _post('/api/fs/list', <String, dynamic>{
        'path': '/',
        'password': '',
        'page': 1,
        'per_page': 200,
        'refresh': false,
      });
      final Set<String> rootNames = <String>{
        for (final Map<String, dynamic> raw
            in ((data['content'] as List<dynamic>?) ?? <dynamic>[])
                .cast<Map<String, dynamic>>())
          if (raw['name'] is String) raw['name'] as String,
      };
      if (rootNames.isEmpty) return;
      for (final String parent in samples) {
        final List<String> segments = parent
            .split('/')
            .where((String s) => s.isNotEmpty)
            .toList(growable: false);
        final int hit = segments.indexWhere(rootNames.contains);
        if (hit < 0) continue; // 这条对不上，看下一条
        if (hit == 0) {
          _basePath = ''; // 已经在同一命名空间，无需剥
          return;
        }
        _basePath = '/${segments.take(hit).join('/')}';
        return;
      }
    } catch (_) {
      // 根目录列不出来（站点只开搜索、网络抖动、信封变形）：拿不到前缀而已，
      // 不是源不可用——本次搜索照常返回，只是路径保持原样。
    }
  }

  /// 把 search 返回的、带 [_basePath] 前缀的路径转成 `fs/list`/`fs/get` 能用的路径。
  /// 不带该前缀的路径原样返回（站点未启用用户根，或已是相对路径）。
  String _stripBasePath(String path) {
    final String base = _basePath ?? '';
    if (base.isEmpty) return path;
    if (path == base) return '/';
    if (path.startsWith('$base/')) {
      final String rest = path.substring(base.length);
      return rest.isEmpty ? '/' : rest;
    }
    return path;
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
