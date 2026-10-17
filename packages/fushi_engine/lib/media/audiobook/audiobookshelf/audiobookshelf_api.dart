/// Audiobookshelf（ABS）协议层：HTTP 封装 + 令牌生命周期 + URL 构造。
///
/// 纯 Dart（无 Flutter / 插件），app 侧的发现源把这里的 DTO 适配成
/// `MediaDiscoverySource` 契约。失败一律抛脱敏的 [ExternalProviderFailure]
/// （同 AList 客户端），发现聚合层据此亮源徽标。
///
/// 协议事实（按服务端 v2.37.1 源码核实）：
/// - 鉴权一律 `Authorization: Bearer <token>`；
/// - 登录 `POST /login`（**不在** `/api` 下），带 `x-return-tokens: true` 才回
///   `user.refreshToken`；`user.accessToken` 1 小时过期；
/// - 刷新 `POST /auth/refresh` 带 `x-refresh-token`，**refresh token 每次轮换**，
///   新值经 [AudiobookshelfApi.onTokensChanged] 交调用方持久化——不落盘的话下次冷
///   启动拿旧 refresh token 去刷，服务端的宽限期一过就只能重新登录；
/// - 封面 `GET /api/items/:id/cover` 是免鉴权路由（`Auth.ignorePatterns`），图片
///   解码器不带头也能取；
/// - 下载 `GET /api/items/:id/download`：多文件条目现场打 zip 流式回（无
///   Content-Length），单文件条目直接回原文件；用户没有 `permissions.download`
///   时 403。
/// - 服务器可挂在子路径下（`RouterBasePath`，如 `https://host/audiobookshelf`），
///   所有端点都相对用户填的根地址拼接。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';

/// 令牌变化（登录 / 刷新轮换）后的持久化回调。
typedef AudiobookshelfTokensChanged =
    Future<void> Function(AudiobookshelfTokens tokens);

/// 一次下载所需的全部信息：交给 HTTP 下载队列。
class AudiobookshelfDownloadTarget {
  const AudiobookshelfDownloadTarget({
    required this.url,
    required this.headers,
    required this.fileName,
    this.sizeBytes,
  });

  final Uri url;

  /// 只含 `Authorization`。凭据不跨 origin 由下载链路（`HttpClient` 自动跟随
  /// 重定向时跨 origin 剥 `Authorization`）保证。
  final Map<String, String> headers;

  /// 带扩展名的落盘文件名：多文件条目 `<标题>.zip`，单文件条目即原文件名。
  /// 下载队列不读 `Content-Disposition`，不给扩展名导入分类器就认不出类型。
  final String fileName;

  /// 服务端报的条目体积；zip 是现场打包的，只能当进度提示。
  final int? sizeBytes;
}

/// 单次 API 往返（连接 + 响应体）的总时限。
const Duration kAudiobookshelfRequestTimeout = Duration(seconds: 30);

class AudiobookshelfApi {
  AudiobookshelfApi({
    required this.serverUrl,
    required this.providerId,
    AudiobookshelfTokens? tokens,
    this.onTokensChanged,
    http.Client? client,
    this.requestTimeout = kAudiobookshelfRequestTimeout,
  }) : _tokens = tokens,
       _client = client ?? createAppHttpIoClient();

  /// 服务器根地址（可带子路径，无尾斜杠）。见 [normalizeServerUrl]。
  final Uri serverUrl;

  /// 失败上浮时标的 provider（发现源 id）。
  final String providerId;

  final AudiobookshelfTokensChanged? onTokensChanged;
  final Duration requestTimeout;
  final http.Client _client;

  AudiobookshelfTokens? _tokens;

  /// 进行中的刷新：并发请求同时 401 时只刷一次（refresh token 会轮换，两个并发
  /// 刷新里后到的那个拿的是刚作废的旧值）。
  Future<bool>? _refreshing;

  /// 当前令牌（登录前 / 未配置为 null）。
  AudiobookshelfTokens? get tokens => _tokens;

  /// 归一化用户输入的服务器地址：折全角、补 scheme（缺省 http——自建 ABS 多在
  /// 局域网 `http://192.168.x.x:13378`）、去查询/片段与尾斜杠。无法解析或没有
  /// 主机时返回 null。
  static Uri? normalizeServerUrl(String raw) {
    String text = normalizeUrlInput(raw);
    if (text.isEmpty) return null;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text)) {
      text = 'http://$text';
    }
    final Uri? parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) return null;
    final String scheme = parsed.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    String path = parsed.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: path,
    );
  }

  /// 拼端点地址：[path] 以 `/` 开头，相对 [serverUrl]（保留子路径）。
  Uri uri(String path, [Map<String, String>? query]) => serverUrl.replace(
    path: '${serverUrl.path}$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  /// 条目封面（免鉴权路由）。
  Uri coverUri(String itemId, {int width = 400}) => uri(
    '/api/items/${Uri.encodeComponent(itemId)}/cover',
    <String, String>{'width': '$width'},
  );

  /// 条目整包下载地址（需鉴权 + 下载权限）。
  Uri downloadUri(String itemId) =>
      uri('/api/items/${Uri.encodeComponent(itemId)}/download');

  /// 当前令牌对应的鉴权头；未登录为空表。
  Map<String, String> get authorizationHeaders {
    final AudiobookshelfTokens? current = _tokens;
    if (current == null) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer ${current.accessToken}'};
  }

  /// [target] 是否与本服务器同 origin（scheme + host + 端口）。鉴权头只发往
  /// 同 origin——条目里的链接理论上可以指向任何主机。
  bool isServerOrigin(Uri target) =>
      target.scheme.toLowerCase() == serverUrl.scheme &&
      target.host.toLowerCase() == serverUrl.host.toLowerCase() &&
      target.port == serverUrl.port;

  /// 账号密码登录。成功后令牌即生效并经 [onTokensChanged] 交出。
  Future<AudiobookshelfSession> login(String username, String password) async {
    const String operation = 'login';
    final http.Response response = await _rawSend(
      'POST',
      uri('/login'),
      operation: operation,
      headers: <String, String>{
        'Content-Type': 'application/json',
        // 不带这个头服务端只把 refresh token 放进 cookie，不回到响应体里。
        'x-return-tokens': 'true',
      },
      body: jsonEncode(<String, String>{
        'username': username,
        'password': password,
      }),
    );
    if (response.statusCode == 401) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'invalid username or password',
        statusCode: 401,
      );
    }
    _ensureOk(response, operation);
    final AudiobookshelfSession session = _parseSession(response, operation);
    await _adopt(session.tokens);
    return session;
  }

  /// 当前用户（含下载权限）。
  Future<AudiobookshelfUser> me() async =>
      AudiobookshelfUser.parse(await _getJson('/api/me', operation: 'me'));

  /// 全部可见媒体库（含 podcast 库，由调用方按 [AudiobookshelfLibrary.isBookLibrary]
  /// 过滤）。
  Future<List<AudiobookshelfLibrary>> libraries() async =>
      AudiobookshelfLibrary.parseList(
        await _getJson('/api/libraries', operation: 'libraries'),
      );

  /// 库内条目一页（[page] 0 基），按标题排序、minified 形状。
  Future<AudiobookshelfItemPage> libraryItems(
    String libraryId, {
    int page = 0,
    int limit = 50,
  }) async => AudiobookshelfItemPage.parse(
    await _getJson(
      '/api/libraries/${Uri.encodeComponent(libraryId)}/items',
      operation: 'libraryItems',
      query: <String, String>{
        'limit': '$limit',
        'page': '$page',
        'sort': 'media.metadata.title',
        'minified': '1',
      },
    ),
    requestedPage: page,
    requestedLimit: limit,
  );

  /// 库内搜索（书名 / 作者 / 系列 …，服务端不分页）。
  Future<List<AudiobookshelfItem>> search(
    String libraryId,
    String query, {
    int limit = 25,
  }) async => parseAudiobookshelfSearch(
    await _getJson(
      '/api/libraries/${Uri.encodeComponent(libraryId)}/search',
      operation: 'search',
      query: <String, String>{'q': query, 'limit': '$limit'},
    ),
  );

  /// 单个条目详情（expanded）。
  Future<AudiobookshelfItem> item(String itemId) async {
    const String operation = 'item';
    final AudiobookshelfItem? parsed = AudiobookshelfItem.parse(
      await _getJson(
        '/api/items/${Uri.encodeComponent(itemId)}',
        operation: operation,
        query: const <String, String>{'expanded': '1'},
      ),
    );
    if (parsed == null) throw _invalid(operation);
    return parsed;
  }

  /// 下载前的物化：先核下载权限（顺带把过期 access token 刷新好），再取条目定
  /// 文件名。
  ///
  /// 先问 `/api/me` 而不是直接把下载地址交出去：没有下载权限时服务端对下载端点只回
  /// 一个裸 403，到了下载队列里就是一句看不懂的「download failed (403)」；在这里
  /// 判掉可以给出「该账号没有下载权限」这种用户能照着改的结论。
  Future<AudiobookshelfDownloadTarget> prepareDownload(String itemId) async {
    final AudiobookshelfUser user = await me();
    if (!user.canDownload) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: 'download',
        kind: ExternalProviderFailureKind.forbidden,
        message: 'account lacks download permission',
        statusCode: 403,
      );
    }
    final AudiobookshelfItem detail = await item(itemId);
    return AudiobookshelfDownloadTarget(
      url: downloadUri(itemId),
      headers: authorizationHeaders,
      fileName: downloadFileNameFor(detail),
      sizeBytes: detail.sizeBytes,
    );
  }

  /// 条目的落盘文件名：单文件条目取原文件名（下载端点回的就是它），否则
  /// `<标题>.zip`（服务端 `zipDirectoryPipe` 的命名）。
  static String downloadFileNameFor(AudiobookshelfItem item) {
    final String? relPath = item.relPath;
    if (item.isFile && relPath != null) {
      final List<String> segments = relPath
          .split(RegExp(r'[\\/]'))
          .where((String s) => s.isNotEmpty)
          .toList(growable: false);
      if (segments.isNotEmpty && segments.last.contains('.')) {
        return segments.last;
      }
    }
    final String base = item.title.trim().isEmpty ? item.id : item.title.trim();
    return '$base.zip';
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    required String operation,
    Map<String, String>? query,
  }) async {
    final http.Response response = await _authorizedSend(
      'GET',
      uri(path, query),
      operation: operation,
    );
    return _decodeObject(response, operation);
  }

  /// 带鉴权发送；401 时刷新一次令牌再重试一次，仍 401 即判会话失效。
  Future<http.Response> _authorizedSend(
    String method,
    Uri target, {
    required String operation,
  }) async {
    final AudiobookshelfTokens? used = _tokens;
    if (used == null) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'not signed in to the server',
      );
    }
    http.Response response = await _rawSend(
      method,
      target,
      operation: operation,
      headers: _bearer(used),
    );
    if (response.statusCode == 401 && await _refreshAfter(used, operation)) {
      response = await _rawSend(
        method,
        target,
        operation: operation,
        headers: _bearer(_tokens!),
      );
    }
    if (response.statusCode == 401) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'server session expired; sign in again',
        statusCode: 401,
      );
    }
    _ensureOk(response, operation);
    return response;
  }

  /// 令牌 [stale] 被拒后尝试刷新。返回 true = 现在手上有一组**比 [stale] 新**的
  /// 令牌，值得重试。
  Future<bool> _refreshAfter(
    AudiobookshelfTokens stale,
    String operation,
  ) async {
    // 别的请求已经刷新过了：直接用新的重试，不再刷第二次。
    if (_tokens != stale) return _tokens != null;
    if (!stale.canRefresh) return false;
    final Future<bool> inFlight = _refreshing ??= _refresh(
      stale,
    ).whenComplete(() => _refreshing = null);
    return inFlight;
  }

  Future<bool> _refresh(AudiobookshelfTokens stale) async {
    const String operation = 'refresh';
    final http.Response response = await _rawSend(
      'POST',
      uri('/auth/refresh'),
      operation: operation,
      headers: <String, String>{'x-refresh-token': stale.refreshToken!},
    );
    // 401 = refresh token 本身失效（过期 / 被吊销 / 轮换宽限期已过）：不是故障，
    // 是「该重新登录了」，交给调用方抛 unauthorized。
    if (response.statusCode == 401) return false;
    _ensureOk(response, operation);
    final AudiobookshelfSession session = _parseSession(response, operation);
    await _adopt(
      AudiobookshelfTokens(
        accessToken: session.tokens.accessToken,
        // 带了 x-refresh-token 服务端必回新 refresh token；万一没回（未知版本），
        // 保留旧值总比丢掉刷新能力强。
        refreshToken: session.tokens.refreshToken ?? stale.refreshToken,
      ),
    );
    return true;
  }

  Future<void> _adopt(AudiobookshelfTokens tokens) async {
    _tokens = tokens;
    await onTokensChanged?.call(tokens);
  }

  static Map<String, String> _bearer(AudiobookshelfTokens tokens) =>
      <String, String>{'Authorization': 'Bearer ${tokens.accessToken}'};

  Future<http.Response> _rawSend(
    String method,
    Uri target, {
    required String operation,
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    final http.Request request = http.Request(method, target)
      ..headers.addAll(<String, String>{
        'Accept': 'application/json',
        ...headers,
      });
    if (body != null) request.body = body;
    try {
      final http.StreamedResponse streamed = await _client
          .send(request)
          .timeout(requestTimeout);
      return await http.Response.fromStream(streamed).timeout(requestTimeout);
    } on TimeoutException {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.timeout,
        message: 'server request timed out',
        retryable: true,
      );
    } on http.ClientException {
      // 原始异常文本里带完整 URL，不往上带。
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.network,
        message: 'could not reach the server',
        retryable: true,
      );
    }
  }

  void _ensureOk(http.Response response, String operation) {
    final int status = response.statusCode;
    if (status >= 200 && status < 300) return;
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: operation,
      kind: switch (status) {
        401 => ExternalProviderFailureKind.unauthorized,
        403 => ExternalProviderFailureKind.forbidden,
        404 => ExternalProviderFailureKind.notFound,
        429 => ExternalProviderFailureKind.rateLimited,
        _ => ExternalProviderFailureKind.unavailable,
      },
      message: 'http status $status',
      statusCode: status,
      retryable: status >= 500 || status == 429,
    );
  }

  AudiobookshelfSession _parseSession(
    http.Response response,
    String operation,
  ) {
    final Map<String, Object?> json = _decodeObject(response, operation);
    try {
      return AudiobookshelfSession.parse(json);
    } on FormatException {
      throw _invalid(operation);
    }
  }

  Map<String, Object?> _decodeObject(http.Response response, String operation) {
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } on FormatException {
      throw _invalid(operation);
    }
    if (decoded is! Map<String, Object?>) throw _invalid(operation);
    return decoded;
  }

  ExternalProviderFailure _invalid(String operation) => ExternalProviderFailure(
    providerId: providerId,
    operation: operation,
    kind: ExternalProviderFailureKind.invalidResponse,
    message: 'response is not a readable Audiobookshelf payload',
  );

  void close() => _client.close();
}
