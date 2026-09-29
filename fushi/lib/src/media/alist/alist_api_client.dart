/// AList v3 / OpenList 站点的 JSON API 薄客户端：发现源 adapter
/// （`alist_discovery_source.dart`）与媒体库 `alist` 网络来源
/// （`source_file_system.dart`）共用，两边的信封校验、游客/账号 token、401 重登
/// 只写一份。
///
/// 协议事实（本仓实探 od.catimage.work / alist.erogame.space）：
/// - 三个端点都是 `POST` JSON：`/api/fs/list`（目录）、`/api/fs/search`、
///   `/api/fs/get`（取带临期签名的 `raw_url`）；
/// - 不带 `Authorization` 即以站点 guest 身份访问，guest 关掉时信封 `code` 401；
/// - 账号访问先 `/api/auth/login` 换 token，token 原样放 `Authorization` 头
///   （**不是** `Bearer`）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// `fs/list` / `fs/search` 返回的一条目录项。
class AListEntry {
  const AListEntry({
    required this.name,
    required this.isDir,
    this.sizeBytes,
    this.modified,
    this.parent,
  });

  final String name;
  final bool isDir;
  final int? sizeBytes;

  /// ISO-8601 修改时间原文；站点不给则 null。
  final String? modified;

  /// 仅 `fs/search` 结果携带：条目所在目录（站点用户根命名空间）。
  final String? parent;

  static AListEntry fromJson(Map<String, dynamic> raw) => AListEntry(
        name: raw['name'] as String? ?? '',
        isDir: raw['is_dir'] == true,
        sizeBytes: (raw['size'] as num?)?.toInt(),
        modified: raw['modified'] as String?,
        parent: raw['parent'] as String?,
      );
}

/// 一页目录 / 搜索结果。
class AListPage {
  const AListPage({required this.entries, required this.total});

  final List<AListEntry> entries;

  /// 站点报的总数；`page * perPage < total` 即还有下一页。
  final int total;
}

/// `fs/get` 结果：临期签名直链 + 文件元数据。
class AListFileLink {
  const AListFileLink({required this.rawUrl, this.name, this.sizeBytes});

  final String rawUrl;
  final String? name;
  final int? sizeBytes;
}

/// [AListApiClient.listAll] 最多翻多少页（perPage=200 → 4 万条）；到顶即停，
/// 防站点 total 与页长同时失真时无限翻页。
const int kAListListAllMaxPages = 200;

class AListApiClient {
  AListApiClient({
    required String baseUrl,
    required this.providerId,
    String? username,
    String? password,
    http.Client? client,
  })  : _baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _username = (username ?? '').trim().isEmpty ? null : username!.trim(),
        _password = password ?? '',
        _client = client ?? createAppHttpIoClient();

  /// 失败上浮时标的 provider（发现源 id / 来源库 `alist-source`）。
  final String providerId;

  final String _baseUrl;
  final String? _username;
  final String _password;
  final http.Client _client;

  /// 已换取的登录 token（游客恒 null）。
  String? _token;

  /// 站点根地址（无尾斜杠）。
  String get baseUrl => _baseUrl;

  /// 是否以游客身份访问（没配账号）。
  bool get isGuest => _username == null;

  Future<AListPage> list(
    String path, {
    int page = 1,
    int perPage = 100,
    String password = '',
  }) async {
    final Map<String, dynamic> data =
        await post('/api/fs/list', <String, dynamic>{
      'path': path,
      'password': password,
      'page': page,
      'per_page': perPage,
      'refresh': false,
    });
    return _page(data);
  }

  /// 拉全一个目录（按 [perPage] 翻到 `total` 为止）。
  ///
  /// 站点 `total` 报 0 又返回了内容（部分存储驱动不计数）时以「本页不满」收尾，
  /// 不会因 total 失真而死循环。
  Future<List<AListEntry>> listAll(
    String path, {
    int perPage = 200,
    String password = '',
  }) async {
    final List<AListEntry> all = <AListEntry>[];
    for (int page = 1;; page++) {
      final AListPage result = await list(
        path,
        page: page,
        perPage: perPage,
        password: password,
      );
      all.addAll(result.entries);
      // 满页才可能还有下一页；total 只在 > 0 时可信（部分驱动恒报 0，不能拿它
      // 把满页截断成一页）。页数封顶防 total 与页长都失真时的死循环。
      final bool more = result.entries.length >= perPage &&
          (result.total <= 0 || page * perPage < result.total) &&
          page < kAListListAllMaxPages;
      if (!more) break;
    }
    return all;
  }

  Future<AListPage> search(
    String keywords, {
    String parent = '/',
    int page = 1,
    int perPage = 100,
  }) async {
    final Map<String, dynamic> data =
        await post('/api/fs/search', <String, dynamic>{
      'parent': parent,
      'keywords': keywords,
      'scope': 0,
      'page': page,
      'per_page': perPage,
      'password': '',
    });
    return _page(data);
  }

  /// 取带签名的直链；站点不给 `raw_url` 按 invalidResponse 上浮。
  Future<AListFileLink> getFile(String path, {String password = ''}) async {
    final Map<String, dynamic> data = await post(
      '/api/fs/get',
      <String, dynamic>{'path': path, 'password': password},
    );
    final String? rawUrl = data['raw_url'] as String?;
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: 'fs/get',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'fs/get returned no raw_url',
      );
    }
    return AListFileLink(
      rawUrl: rawUrl,
      name: data['name'] as String?,
      sizeBytes: (data['size'] as num?)?.toInt(),
    );
  }

  /// POST JSON → 校验 AList 信封（`code`/`message`/`data`）→ 返回 data。
  ///
  /// `code` 401 时若配了账号自动重登一次再试；其余非 200 code 一律按
  /// invalidResponse 失败上浮（信封 message 是站点自述文案，脱敏保留）。
  Future<Map<String, dynamic>> post(
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
        providerId: providerId,
        operation: apiPath,
        kind: ExternalProviderFailureKind.unavailable,
        message: 'http status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final Map<String, dynamic> envelope =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final int code = (envelope['code'] as num?)?.toInt() ?? -1;
    if (code == 401 && !retriedAuth && _username != null) {
      _token = null;
      return post(apiPath, body, retriedAuth: true);
    }
    if (code != 200) {
      throw ExternalProviderFailure(
        providerId: providerId,
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
    final String? user = _username;
    if (user == null || _token != null) return;
    final http.Response response = await _client.post(
      Uri.parse('$_baseUrl/api/auth/login'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'username': user,
        'password': _password,
      }),
    );
    final Map<String, dynamic> envelope =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final String? token =
        (envelope['data'] as Map<String, dynamic>?)?['token'] as String?;
    if (response.statusCode != 200 || token == null || token.isEmpty) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: '/api/auth/login',
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'alist login failed',
        statusCode: response.statusCode,
      );
    }
    _token = token;
  }

  static AListPage _page(Map<String, dynamic> data) {
    final List<dynamic> content =
        (data['content'] as List<dynamic>?) ?? <dynamic>[];
    final List<AListEntry> entries = <AListEntry>[
      for (final Map<String, dynamic> raw
          in content.cast<Map<String, dynamic>>())
        AListEntry.fromJson(raw),
    ];
    return AListPage(
      entries: entries,
      total: (data['total'] as num?)?.toInt() ?? entries.length,
    );
  }

  void close() => _client.close();
}
