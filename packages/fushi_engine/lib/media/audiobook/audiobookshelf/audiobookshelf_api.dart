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
/// - 播放 `POST /api/items/:id/play[/:episodeId]`（forceDirectPlay）开会话，音轨
///   文件 `GET /api/items/:id/file/:ino` 支持 Range；进度走会话 `sync` / `close`
///   或 `PATCH /api/me/progress/:id[/:episodeId]`；
/// - 服务端不认 `.srt`：字幕在 `libraryFiles` 里 `fileType` 是 `unknown`，按扩展名认；
/// - `x-return-tokens` 在部分部署（反代剥头）下不生效，refresh token 只在
///   `Set-Cookie: refresh_token=` 里，登录时要兜底取；
/// - 服务器可挂在子路径下（`RouterBasePath`，如 `https://host/audiobookshelf`），
///   所有端点都相对用户填的根地址拼接。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/bounded_read.dart';
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

  /// 换上外部给的令牌（用户在设置里重新登录之类）。**不**触发 [onTokensChanged]：
  /// 令牌本来就是从持久层来的，再写回去只会造成回声。
  void adoptTokens(AudiobookshelfTokens tokens) => _tokens = tokens;

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

  /// 服务器状态（免鉴权）：确认对面是 ABS，并看支持哪些登录方式。
  Future<AudiobookshelfServerStatus> status() async {
    const String operation = 'status';
    final http.Response response = await _rawSend(
      'GET',
      uri('/status'),
      operation: operation,
    );
    _ensureOk(response, operation);
    final AudiobookshelfServerStatus? parsed = AudiobookshelfServerStatus.parse(
      _decodeObject(response, operation),
    );
    if (parsed == null) throw _invalid(operation);
    return parsed;
  }

  /// 条目详情（音轨 / 文件 / 章节 / 单集 / 进度）。
  ///
  /// 播客请传 `expanded: false`：展开形状带整套单集的 audioTrack，实测 176 KB 以上、
  /// 慢服务器上会超时；非展开形状已含每集 `audioFile.ino`，足够拼文件地址。
  Future<AudiobookshelfItemDetail> itemDetail(
    String itemId, {
    bool expanded = true,
  }) async {
    const String operation = 'itemDetail';
    final AudiobookshelfItemDetail? parsed = AudiobookshelfItemDetail.parse(
      await _getJson(
        '/api/items/${Uri.encodeComponent(itemId)}',
        operation: operation,
        query: <String, String>{
          if (expanded) 'expanded': '1',
          'include': 'progress',
        },
        timeout: requestTimeout * 2,
      ),
    );
    if (parsed == null) throw _invalid(operation);
    return parsed;
  }

  /// 开播放会话（direct play）。返回音轨表与服务端记的续播位置。
  Future<AudiobookshelfPlaySession> startPlay(
    String itemId, {
    required String deviceId,
    String? episodeId,
    String clientName = 'Fushi',
  }) async {
    const String operation = 'play';
    final String episodePart = episodeId == null
        ? ''
        : '/${Uri.encodeComponent(episodeId)}';
    final http.Response response = await _authorizedSend(
      'POST',
      uri('/api/items/${Uri.encodeComponent(itemId)}/play$episodePart'),
      operation: operation,
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, Object?>{
        'deviceInfo': <String, String>{
          'clientName': clientName,
          'deviceId': deviceId,
        },
        'forceDirectPlay': true,
        'forceTranscode': false,
        'mediaPlayer': 'just_audio',
        'supportedMimeTypes': const <String>[
          'audio/flac',
          'audio/mpeg',
          'audio/mp4',
          'audio/x-m4b',
          'audio/aac',
          'audio/ogg',
          'audio/opus',
          'audio/wav',
        ],
      }),
    );
    final AudiobookshelfPlaySession? parsed = AudiobookshelfPlaySession.parse(
      _decodeObject(response, operation),
    );
    if (parsed == null || parsed.tracks.isEmpty) throw _invalid(operation);
    return parsed;
  }

  /// 会话同步：[timeListenedSeconds] 是距上次同步新增的收听秒数（不是累计）。
  /// 会话已被服务端清掉时抛 `notFound`，调用方退回 [patchProgress]。
  Future<void> syncSession(
    String sessionId, {
    required double currentTimeSeconds,
    required double timeListenedSeconds,
    required double durationSeconds,
  }) => _sessionCall(
    'sync',
    sessionId,
    currentTimeSeconds: currentTimeSeconds,
    timeListenedSeconds: timeListenedSeconds,
    durationSeconds: durationSeconds,
  );

  /// 结束会话（附最后一次位置）。
  Future<void> closeSession(
    String sessionId, {
    required double currentTimeSeconds,
    required double timeListenedSeconds,
    required double durationSeconds,
  }) => _sessionCall(
    'close',
    sessionId,
    currentTimeSeconds: currentTimeSeconds,
    timeListenedSeconds: timeListenedSeconds,
    durationSeconds: durationSeconds,
  );

  Future<void> _sessionCall(
    String action,
    String sessionId, {
    required double currentTimeSeconds,
    required double timeListenedSeconds,
    required double durationSeconds,
  }) async {
    await _authorizedSend(
      'POST',
      uri('/api/session/${Uri.encodeComponent(sessionId)}/$action'),
      operation: 'session.$action',
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, num>{
        'currentTime': currentTimeSeconds,
        'timeListening': timeListenedSeconds,
        'duration': durationSeconds,
      }),
    );
  }

  /// 没有开会话时直接写进度（离线补写、会话过期后的兜底）。
  Future<void> patchProgress(
    String itemId, {
    String? episodeId,
    required double currentTimeSeconds,
    required double durationSeconds,
    bool isFinished = false,
  }) async {
    await _authorizedSend(
      'PATCH',
      uri(_progressPath(itemId, episodeId)),
      operation: 'patchProgress',
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, Object>{
        'currentTime': currentTimeSeconds,
        'duration': durationSeconds,
        'progress': durationSeconds > 0
            ? (currentTimeSeconds / durationSeconds).clamp(0.0, 1.0)
            : 0.0,
        'isFinished': isFinished,
      }),
    );
  }

  /// 读进度；服务端没有记录（404）时返回 null。
  Future<AudiobookshelfMediaProgress?> getProgress(
    String itemId, {
    String? episodeId,
  }) async {
    try {
      return AudiobookshelfMediaProgress.parse(
        await _getJson(
          _progressPath(itemId, episodeId),
          operation: 'getProgress',
        ),
      );
    } on ExternalProviderFailure catch (failure) {
      if (failure.kind == ExternalProviderFailureKind.notFound) return null;
      rethrow;
    }
  }

  /// 「继续收听」：进行中的条目（播客带最近收听的那一集）。
  Future<List<AudiobookshelfInProgressEntry>> itemsInProgress() async =>
      AudiobookshelfInProgressEntry.parseList(
        await _getJson('/api/me/items-in-progress', operation: 'inProgress'),
      );

  static String _progressPath(String itemId, String? episodeId) {
    final String episodePart = episodeId == null
        ? ''
        : '/${Uri.encodeComponent(episodeId)}';
    return '/api/me/progress/${Uri.encodeComponent(itemId)}$episodePart';
  }

  /// 条目内某个文件的地址（inline，支持 Range；需鉴权头）。
  Uri fileUri(String itemId, String ino) => uri(
    '/api/items/${Uri.encodeComponent(itemId)}/file/${Uri.encodeComponent(ino)}',
  );

  /// 条目内某个文件的下载地址（需 `permissions.download`）。
  Uri fileDownloadUri(String itemId, String ino) => uri(
    '/api/items/${Uri.encodeComponent(itemId)}/file/'
    '${Uri.encodeComponent(ino)}/download',
  );

  /// 带「马上就能用」的鉴权头：access token 快过期（[minValidity] 内）就先刷新。
  ///
  /// 给一次性读取（ffmpeg 切句、单句回放）用——它们把头交给外部进程后就不再受
  /// 本类 401 重试管辖。无法判断过期时间的令牌（API key / 旧版永久 token）原样返回。
  Future<Map<String, String>> freshAuthorizationHeaders({
    Duration minValidity = const Duration(minutes: 2),
  }) async {
    const String operation = 'token';
    final AudiobookshelfTokens used = _requireTokens(operation);
    final DateTime? expiry = audiobookshelfTokenExpiry(used.accessToken);
    final bool nearExpiry =
        expiry != null &&
        expiry.difference(DateTime.now()).compareTo(minValidity) <= 0;
    if (nearExpiry && await _refreshAfter(used, operation)) {
      return _bearer(_tokens!);
    }
    return _bearer(_tokens ?? used);
  }

  /// 读 [target] 的字节区间 `[start, end]`（闭区间，均可省）。返回的是未消费的
  /// 流式响应，**调用方负责读完或取消**。
  ///
  /// 复用 401 → 刷新 → 重试，所以长时间播放中令牌过期不会让 seek 失败。鉴权头只
  /// 发往本服务器同 origin 的地址。
  Future<http.StreamedResponse> openRange(
    Uri target, {
    int? start,
    int? end,
  }) async {
    const String operation = 'stream';
    if (!isServerOrigin(target)) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.forbidden,
        message: 'refusing to send credentials to another origin',
      );
    }
    final String? range = start == null && end == null
        ? null
        : 'bytes=${start ?? 0}-${end ?? ''}';
    Map<String, String> headersFor(AudiobookshelfTokens tokens) =>
        <String, String>{if (range != null) 'Range': range, ..._bearer(tokens)};

    final AudiobookshelfTokens used = _requireTokens(operation);
    http.StreamedResponse response = await _rawSendStreamed(
      target,
      operation: operation,
      headers: headersFor(used),
    );
    if (response.statusCode == 401) {
      // 每个响应的流只能消费一次：这一枚 401 排空后就不再碰它。
      await response.stream.drain<void>();
      if (!await _refreshAfter(used, operation)) {
        throw _sessionExpired(operation);
      }
      response = await _rawSendStreamed(
        target,
        operation: operation,
        headers: headersFor(_tokens!),
      );
    }
    final int status = response.statusCode;
    if (status < 200 || status >= 300) {
      await response.stream.drain<void>();
      throw status == 401
          ? _sessionExpired(operation)
          : _failureForStatus(status, operation);
    }
    return response;
  }

  ExternalProviderFailure _sessionExpired(String operation) =>
      ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'server session expired; sign in again',
        statusCode: 401,
      );

  /// 取条目里的小文本文件（字幕）。超过 [maxBytes] 抛 `invalidResponse`，不会先把
  /// 整份读进内存——条目文件夹里可能有任意大的文件。
  Future<Uint8List> fetchLibraryTextFile(
    String itemId,
    String ino, {
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    const String operation = 'fetchFile';
    final http.StreamedResponse response = await openRange(
      fileUri(itemId, ino),
    );
    try {
      return await readBoundedBytes(
        response.stream,
        maxBytes,
      ).timeout(requestTimeout * 2);
    } on BodyTooLargeException {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'file is larger than $maxBytes bytes',
      );
    } on TimeoutException {
      throw _timeoutFailure(operation);
    } on http.ClientException {
      throw _networkFailure(operation);
    }
  }

  /// 单个文件（播客单集的音频 / 条目内的字幕）的下载物化。同 [prepareDownload]：
  /// 先核下载权限，让「没有权限」以一句能看懂的话报出来，而不是下载队列里的裸 403。
  Future<AudiobookshelfDownloadTarget> prepareFileDownload(
    String itemId,
    String ino, {
    required String fileName,
    int? sizeBytes,
  }) async {
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
    return AudiobookshelfDownloadTarget(
      url: fileDownloadUri(itemId, ino),
      headers: authorizationHeaders,
      fileName: fileName,
      sizeBytes: sizeBytes,
    );
  }

  Future<Map<String, Object?>> _getJson(
    String path, {
    required String operation,
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    final http.Response response = await _authorizedSend(
      'GET',
      uri(path, query),
      operation: operation,
      timeout: timeout,
    );
    return _decodeObject(response, operation);
  }

  AudiobookshelfTokens _requireTokens(String operation) {
    final AudiobookshelfTokens? used = _tokens;
    if (used == null) {
      throw ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.unauthorized,
        message: 'not signed in to the server',
      );
    }
    return used;
  }

  /// 带鉴权发送；401 时刷新一次令牌再重试一次，仍 401 即判会话失效。
  Future<http.Response> _authorizedSend(
    String method,
    Uri target, {
    required String operation,
    Map<String, String> headers = const <String, String>{},
    String? body,
    Duration? timeout,
  }) async {
    final AudiobookshelfTokens used = _requireTokens(operation);
    http.Response response = await _rawSend(
      method,
      target,
      operation: operation,
      headers: <String, String>{...headers, ..._bearer(used)},
      body: body,
      timeout: timeout,
    );
    if (response.statusCode == 401 && await _refreshAfter(used, operation)) {
      response = await _rawSend(
        method,
        target,
        operation: operation,
        headers: <String, String>{...headers, ..._bearer(_tokens!)},
        body: body,
        timeout: timeout,
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
    Duration? timeout,
  }) async {
    final Duration limit = timeout ?? requestTimeout;
    final http.Request request = http.Request(method, target)
      ..headers.addAll(<String, String>{
        'Accept': 'application/json',
        ...headers,
      });
    if (body != null) request.body = body;
    try {
      final http.StreamedResponse streamed = await _client
          .send(request)
          .timeout(limit);
      return await http.Response.fromStream(streamed).timeout(limit);
    } on TimeoutException {
      throw _timeoutFailure(operation);
    } on http.ClientException {
      throw _networkFailure(operation);
    }
  }

  ExternalProviderFailure _timeoutFailure(String operation) =>
      ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.timeout,
        message: 'server request timed out',
        retryable: true,
      );

  // 原始异常文本里带完整 URL，不往上带。
  ExternalProviderFailure _networkFailure(String operation) =>
      ExternalProviderFailure(
        providerId: providerId,
        operation: operation,
        kind: ExternalProviderFailureKind.network,
        message: 'could not reach the server',
        retryable: true,
      );

  /// 只等响应头（正文留给调用方按流消费），用于音频区间读取。
  Future<http.StreamedResponse> _rawSendStreamed(
    Uri target, {
    required String operation,
    required Map<String, String> headers,
  }) async {
    final http.Request request = http.Request('GET', target)
      ..headers.addAll(<String, String>{'Accept': '*/*', ...headers});
    try {
      return await _client.send(request).timeout(requestTimeout);
    } on TimeoutException {
      throw _timeoutFailure(operation);
    } on http.ClientException {
      throw _networkFailure(operation);
    }
  }

  void _ensureOk(http.Response response, String operation) {
    final int status = response.statusCode;
    if (status >= 200 && status < 300) return;
    throw _failureForStatus(status, operation);
  }

  ExternalProviderFailure _failureForStatus(int status, String operation) =>
      ExternalProviderFailure(
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

  AudiobookshelfSession _parseSession(
    http.Response response,
    String operation,
  ) {
    final Map<String, Object?> json = _decodeObject(response, operation);
    final AudiobookshelfSession session;
    try {
      session = AudiobookshelfSession.parse(json);
    } on FormatException {
      throw _invalid(operation);
    }
    if (session.tokens.canRefresh) return session;
    // 部分部署（反代剥掉 x-return-tokens）只通过 Set-Cookie 下发 refresh token。
    final String? cookieToken = refreshTokenFromSetCookie(
      response.headers['set-cookie'],
    );
    if (cookieToken == null) return session;
    return AudiobookshelfSession(
      tokens: AudiobookshelfTokens(
        accessToken: session.tokens.accessToken,
        refreshToken: cookieToken,
      ),
      user: session.user,
      defaultLibraryId: session.defaultLibraryId,
      serverVersion: session.serverVersion,
    );
  }

  /// 从（可能被 IOClient 用逗号拼成一行的）`Set-Cookie` 里取 `refresh_token`。
  /// JWT 的字符集里没有逗号 / 分号 / 空白，用它们做边界是安全的。
  static String? refreshTokenFromSetCookie(String? header) {
    if (header == null) return null;
    final Match? match = RegExp(
      r'(?:^|[;,]\s*)refresh_token=([^;,\s]+)',
    ).firstMatch(header);
    final String? value = match?.group(1);
    return value == null || value.isEmpty ? null : value;
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
