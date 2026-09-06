import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:fushi/src/media/video/jimaku_client.dart' show JimakuClient;
import 'package:fushi/src/media/video/video_subtitle_source.dart'
    show buildParsedSubtitleResponse;
import 'package:fushi/src/media/video/youtube_source_resolver.dart'
    show resolveYoutubeCaptionsForExtension;
import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/remote_jimaku_subtitle_handlers.dart';
import 'package:fushi/src/sync/remote_lookup_routes.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart'
    show SyncServerPortInUseException, isAddressInUseError;
import 'package:fushi/src/sync/yomitan_term_entries_adapter.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

/// yomitan-api 默认端口（Kuuuube/yomitan-api）。
const int kYomitanApiDefaultPort = 19633;

const List<String> _apiKeyParameterNames = <String>[
  'apiKey',
  'api_key',
  'key',
  'token',
  'yomitanApiKey',
  'yomitan_api_key',
];

/// 兼容 `Kuuuube/yomitan-api` 的独立 HTTP server（宽松兼容），同时是 Hibiki 浏览器扩展
/// （Netflix 等流媒体查词/制卡）的 API surface。只接受 POST；可选 API key 鉴权（支持
/// x-api-key / Bearer / 裸 Authorization / query / body，也支持扩展用的
/// `Basic base64('fushi:'+key)`）。端点：serverVersion/yomitanVersion/termEntries/tokenize
/// （yomitan-api 兼容）+ `/api/lookup/dictionary` + `/api/mine`（BUG-530：浏览器扩展契约，
/// 与 FushiSyncServer 共享 [buildRemoteDictionaryLookupResponse]/[buildRemoteMineResponse]）。
/// 浏览器扩展连接探活的 POST 端点集合：命中其一即视作「扩展（或 in-app 弹窗）活跃」。
/// 只列扩展真正会主动打的端点——状态探测 + 查词/制卡/查重/音频，不含裸 GET 音频文件。
const Set<String> _kExtensionSeenPaths = <String>{
  '/api/extension/status',
  '/api/lookup/dictionary',
  '/api/lookup/audio',
  '/api/mine',
  '/api/duplicate',
};

/// TODO-2936：「浏览器」媒体类型 Profile 绑定的触发端点集合——真正代表「用户正在
/// 浏览器里查词/制卡」的端点。刻意**不含** `/api/extension/status`：那是扩展 SW
/// 启动的探活 ping（浏览器一开就发），不代表用户在用扩展查词，不该据此切 Profile。
const Set<String> _kLookupActivityPaths = <String>{
  '/termEntries',
  '/tokenize',
  '/api/lookup/dictionary',
  '/api/mine',
};

class YomitanApiServer {
  static final RegExp _lookupTraceIdPattern =
      RegExp(r'^[A-Za-z0-9._:-]{1,64}$');

  YomitanApiServer({
    required int port,
    required FushiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    FushiRemoteMiningService? miningService,
    FushiRemoteHistoryService? historyService,
    Map<String, String> Function()? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    bool Function()? autoReadOnLookupProvider,
    String? Function()? extensionBuildProvider,
    RemotePopupDictionaryCss Function()? popupDictionaryCssProvider,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function()? onExtensionSeen,
    void Function()? onLookupActivity,
    void Function(String build, String? version)? onExtensionReport,
    String? Function()? jimakuApiKeyProvider,
    String? apiKey,
    bool allowLan = false,
  })  : _requestedPort = port,
        _lookup = lookupService,
        _mining = miningService,
        _history = historyService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _themeColorsProvider = themeColorsProvider,
        _audioSourcesProvider = audioSourcesProvider,
        _autoReadOnLookupProvider = autoReadOnLookupProvider,
        _extensionBuildProvider = extensionBuildProvider,
        _popupDictionaryCssProvider = popupDictionaryCssProvider,
        _onExtensionPopupSize = onExtensionPopupSize,
        _onExtensionSeen = onExtensionSeen,
        _onLookupActivity = onLookupActivity,
        _onExtensionReport = onExtensionReport,
        _jimakuApiKeyProvider = jimakuApiKeyProvider,
        _apiKey = apiKey,
        _allowLan = allowLan;

  final int _requestedPort;
  final FushiRemoteLookupService _lookup;
  final FushiRemoteMiningService? _mining;
  final FushiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  // BUG-530：当前 app 主题的 CSS 变量供给器，随查词响应下发给浏览器扩展弹窗。
  final Map<String, String> Function()? _themeColorsProvider;
  // 单词音频：当前 app 已启用的音频源供给器，随查词响应下发给扩展弹窗。
  final List<String> Function()? _audioSourcesProvider;

  /// 查词后自动朗读偏好（`autoReadOnLookup`）：随查词响应下发给浏览器扩展，让扩展弹窗
  /// 与 app 内/app 外三个表面用同一个开关自动发音。
  final bool Function()? _autoReadOnLookupProvider;
  // BUG-726：app 内置扩展内容指纹供给器，随查词响应下发，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;
  // BUG-1718：词典自带 CSS + 用户自定义 CSS 供给器，按 revision 门控随查词响应下发给扩展弹窗。
  final RemotePopupDictionaryCss Function()? _popupDictionaryCssProvider;
  // 弹窗尺寸精细化 Phase D：扩展弹窗被拖角调整尺寸后，content.js 经 bridge 回写最终基准
  // 最大宽高；这个 sink 收到（未 clamp 的原始逻辑像素）→ app 侧 clamp + 拖即解锁 + 写扩展键。
  // 未注入（旧 app / 配对 sync host）时端点 404（向后兼容，无写偏好副作用）。
  final void Function(double maxWidth, double maxHeight)? _onExtensionPopupSize;
  // 浏览器扩展连接探活：任一扩展端点被命中即回调（app 侧记录 last-seen 时间戳，
  // 供「安装 → 验证插件已正常启用」的连接检测显示）。扩展 background 在 SW 启动时
  // 主动打 /api/extension/status，故装完扩展即刷新 last-seen，无需用户先划词。
  final void Function()? _onExtensionSeen;
  // TODO-2936：查词/制卡端点被命中即回调（已过鉴权中间件，只代表真实扩展活动）。
  // app 侧据此应用「浏览器」媒体类型的 Profile 绑定（未绑定时为 no-op）。
  final void Function()? _onLookupActivity;
  // BUG-1079：扩展经 /api/extension/status 请求体自报「浏览器中实际加载的 build」
  // （+ manifest version）。app 侧记录后与内置指纹比对，不一致时在扩展管理页给出
  // 更新提示。旧扩展发 '{}'（无 build 字段）时不回调——行为等同现状（向后兼容）。
  final void Function(String build, String? version)? _onExtensionReport;
  // 「Jimaku 查字幕」扩展桥：从偏好读用户 API key 的供给器。未注入/key 为空时两个
  // jimaku 端点回 {ok:false, error:'no-api-key'}（扩展提示去 app 设置里填 key）。
  final String? Function()? _jimakuApiKeyProvider;
  final String? _apiKey;
  final bool _allowLan;

  HttpServer? _server;

  // Jimaku client 按 key 缓存复用（每请求新建会泄漏 http.Client）；key 变更时换新关旧。
  JimakuClient? _jimakuClient;
  String? _jimakuClientKey;
  // 搜索候选按 handle 暂存（download 需要 file url 等上下文）；插入序 LRU，上限截断。
  static const int _kJimakuCandidateCacheLimit = 200;
  final Map<String, RemoteJimakuCandidate> _jimakuCandidates =
      <String, RemoteJimakuCandidate>{};

  JimakuClient? _jimakuClientFor() {
    final String? key = _jimakuApiKeyProvider?.call();
    if (key == null || key.trim().isEmpty) return null;
    if (_jimakuClient == null || _jimakuClientKey != key) {
      _jimakuClient?.close();
      _jimakuClient = JimakuClient(apiKey: key);
      _jimakuClientKey = key;
    }
    return _jimakuClient;
  }

  void _rememberJimakuCandidate(String handle, RemoteJimakuCandidate c) {
    _jimakuCandidates.remove(handle); // 重插到尾部（LRU 触达即续期）
    _jimakuCandidates[handle] = c;
    while (_jimakuCandidates.length > _kJimakuCandidateCacheLimit) {
      _jimakuCandidates.remove(_jimakuCandidates.keys.first);
    }
  }

  // 单词音频短命 token 与查词/制卡端点的 handler 正文收在 [RemoteLookupRoutes]，
  // 与 FushiSyncServer 共用一份（TTL 5 分钟 + BUG-908(a) 上限 128）。
  final RemoteAudioTokenStore _audioTokens = RemoteAudioTokenStore();
  late final RemoteLookupRoutes _lookupRoutes = RemoteLookupRoutes(
    audioTokens: _audioTokens,
    lookup: _lookup,
    mining: _mining,
  );

  bool get isRunning => _server != null;
  int get port => _server?.port ?? _requestedPort;

  Future<void> start() async {
    if (_server != null) return;
    final shelf.Handler handler = const shelf.Pipeline()
        .addMiddleware(_authMiddleware())
        .addHandler(_handleRequest);
    try {
      _server = await shelf_io.serve(
        handler,
        _allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        _requestedPort,
      );
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) {
        throw SyncServerPortInUseException(_requestedPort);
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _jimakuClient?.close();
    _jimakuClient = null;
    _jimakuClientKey = null;
    _jimakuCandidates.clear();
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) async {
        // 单词音频文件端点是裸 GET（HTML5 Audio 无 Authorization）→ 免鉴权放行，靠
        // 不可猜的短命 id 兜底（与 FushiSyncServer 的 /api/lookup/audio/file 同策略）。
        if (request.url.path == 'api/lookup/audio/file') return inner(request);
        final String? key = _apiKey;
        if (key == null || key.isEmpty) return inner(request);

        final String? provided = _apiKeyFromRequestMetadata(request);
        if (provided == key) return inner(request);

        final String rawBody = await request.readAsString();
        final String? bodyKey = _apiKeyFromJsonBody(rawBody);
        if (bodyKey == key) {
          return inner(request.change(body: rawBody));
        }

        return shelf.Response(401, body: 'Unauthorized');
      };
    };
  }

  String? _apiKeyFromRequestMetadata(shelf.Request request) {
    final String? headerKey = request.headers['x-api-key'];
    if (headerKey != null) return headerKey;

    final String? authorization = request.headers['authorization'];
    if (authorization != null) {
      const String bearerPrefix = 'Bearer ';
      if (authorization.length > bearerPrefix.length &&
          authorization.toLowerCase().startsWith(bearerPrefix.toLowerCase())) {
        return authorization.substring(bearerPrefix.length);
      }
      // BUG-530：Fushi 浏览器扩展用 `Basic base64('fushi:'+key)`（与 FushiSyncServer
      // 同款鉴权），密码段=API key。解码取冒号后的 password 段与 _apiKey 比对。
      const String basicPrefix = 'Basic ';
      if (authorization.length > basicPrefix.length &&
          authorization.toLowerCase().startsWith(basicPrefix.toLowerCase())) {
        try {
          final String decoded = utf8.decode(
              base64Decode(authorization.substring(basicPrefix.length)));
          final int colon = decoded.indexOf(':');
          if (colon >= 0) return decoded.substring(colon + 1);
        } catch (_) {
          // 非法 base64/编码：按无 key 处理（回落其它来源）。
        }
      }
      if (!authorization.contains(' ')) return authorization;
    }

    for (final String name in _apiKeyParameterNames) {
      final String? value = request.url.queryParameters[name];
      if (value != null) return value;
    }
    return null;
  }

  String? _apiKeyFromJsonBody(String rawBody) {
    if (rawBody.isEmpty) return null;
    try {
      final dynamic decoded = jsonDecode(rawBody);
      if (decoded is! Map) return null;
      for (final String name in _apiKeyParameterNames) {
        final dynamic value = decoded[name];
        if (value is String) return value;
      }
    } catch (_) {
      // 鉴权阶段只读取可识别的 JSON token；非法 body 仍按未授权处理。
    }
    return null;
  }

  Future<shelf.Response> _handleRequest(shelf.Request request) async {
    final String path = '/${request.url.path}';
    final String method = request.method.toUpperCase();
    // 单词音频文件是裸 GET/HEAD（不是 POST）→ 在 405 门之前单独处理。
    if (path == '/api/lookup/audio/file') {
      if (method != 'GET' && method != 'HEAD') {
        return shelf.Response(405, body: 'Method Not Allowed');
      }
      return _lookupRoutes.handleAudioFile(request, headOnly: method == 'HEAD');
    }
    if (method != 'POST') {
      return shelf.Response(405, body: 'Method Not Allowed');
    }
    // 浏览器扩展连接探活：这些 POST 端点只有已加载的扩展（或 in-app 弹窗）会命中，
    // 命中即刷新 app 侧 last-seen（连接检测据此判断「插件已正常启用」）。
    if (_kExtensionSeenPaths.contains(path)) {
      _onExtensionSeen?.call();
    }
    // TODO-2936：查词/制卡活动 → 应用「浏览器」媒体类型 Profile 绑定。
    if (_kLookupActivityPaths.contains(path)) {
      _onLookupActivity?.call();
    }
    switch (path) {
      case '/serverVersion':
        return jsonResponse(<String, dynamic>{'version': 1});
      case '/yomitanVersion':
        return jsonResponse(<String, dynamic>{'version': '0.0.0.0'});
      case '/termEntries':
        return _handleTermEntries(request);
      case '/tokenize':
        return _handleTokenize(request);
      case '/api/lookup/dictionary':
        return _handleDictionaryLookup(request);
      case '/api/lookup/audio':
        return _lookupRoutes.handleAudioLookup(request);
      case '/api/mine':
        return _lookupRoutes.handleMine(request);
      case '/api/mine/forward':
        return _lookupRoutes.handleMineForward(request);
      case '/api/anki/note-type/read':
      case '/api/anki/note-type/styling':
      case '/api/anki/note-type/templates':
        return _lookupRoutes.handleAnkiNoteType(request, path);
      case '/api/duplicate':
        return _lookupRoutes.handleDuplicate(request);
      case '/api/extension/popup-size':
        return _handleExtensionPopupSize(request);
      case '/api/extension/status':
        return _handleExtensionStatus(request);
      case '/api/youtube/captions':
        return _handleYoutubeCaptions(request);
      case '/api/subtitle/parse':
        return _handleSubtitleParse(request);
      case '/api/subtitle/jimaku/search':
        return _handleJimakuSearch(request);
      case '/api/subtitle/jimaku/fetch':
        return _handleJimakuFetch(request);
      default:
        return shelf.Response.notFound('Unknown endpoint');
    }
  }

  /// 「Jimaku 查字幕」扩展桥①搜索：body `{query?, anilistId?, episode?, anime?}`。
  /// 逻辑在 [buildJimakuSearchResponse]（含真人剧 anime=false 补搜）；候选按 handle
  /// 暂存供 fetch。
  Future<shelf.Response> _handleJimakuSearch(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    return jsonResponse(await buildJimakuSearchResponse(
      body,
      clientProvider: _jimakuClientFor,
      rememberCandidate: _rememberJimakuCandidate,
    ));
  }

  /// 「Jimaku 查字幕」扩展桥②下载+解析：body `{handle}`。响应与 `/api/subtitle/parse`
  /// 同形（`{format, cues:[...]}` + filename/language），扩展直接走既有 InstallTrack 落地。
  Future<shelf.Response> _handleJimakuFetch(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    return jsonResponse(await buildJimakuFetchResponse(
      body,
      clientProvider: _jimakuClientFor,
      resolveCandidate: (String handle) => _jimakuCandidates[handle],
    ));
  }

  /// BUG-726/自更新：状态端点回带当前内置扩展指纹（extensionBuild），扩展
  /// background 在 SW 启动时打这里比对自身 build，不一致即 chrome.runtime.reload()
  /// 从磁盘拉新——把「只有查词才检查更新」升级为「启动即主动检查」。null（指纹
  /// 尚未算好 / 旧 app）时省略该字段，向后兼容。
  ///
  /// BUG-1079：请求体可携带扩展自报的 `{build, version}`（浏览器中实际加载的版本），
  /// 有非空 build 时经 [_onExtensionReport] 记到 app 侧。旧扩展发 '{}' / 空 body /
  /// 非法 JSON 一律容错——不回调、不报错，响应与现状完全一致（向后兼容）。
  Future<shelf.Response> _handleExtensionStatus(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final Object? reportedBuild = body?['build'];
    if (reportedBuild is String && reportedBuild.isNotEmpty) {
      final Object? reportedVersion = body?['version'];
      _onExtensionReport?.call(
        reportedBuild,
        reportedVersion is String && reportedVersion.isNotEmpty
            ? reportedVersion
            : null,
      );
    }
    final String? extensionBuild = _extensionBuildProvider?.call();
    return jsonResponse(<String, dynamic>{
      'app': 'fushi',
      'ready': true,
      'port': port,
      if (extensionBuild != null) 'extensionBuild': extensionBuild,
    });
  }

  /// BUG-530：浏览器扩展查词端点（与 FushiSyncServer 共享契约）。
  Future<shelf.Response> _handleDictionaryLookup(shelf.Request request) async {
    final Stopwatch serverWatch = Stopwatch()..start();
    final Stopwatch requestJsonWatch = Stopwatch()..start();
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    requestJsonWatch.stop();
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');

    final RemoteDictionaryPopupTiming popupTiming =
        RemoteDictionaryPopupTiming();
    final Stopwatch handlerWatch = Stopwatch()..start();
    final Map<String, dynamic> response =
        await buildRemoteDictionaryLookupResponse(
      body,
      lookup: _lookup,
      history: _history,
      popupTiming: popupTiming,
      themeColorsProvider: _themeColorsProvider,
      audioSourcesProvider: _audioSourcesProvider,
      autoReadOnLookupProvider: _autoReadOnLookupProvider,
      extensionBuildProvider: _extensionBuildProvider,
      popupDictionaryCssProvider: _popupDictionaryCssProvider,
    );
    handlerWatch.stop();

    // jsonEncode 必须只做一次。把最终编码阶段放进响应 header，避免为了把耗时写回
    // JSON body 而二次编码同一份（popupJson 可能数百 KB）。
    final Stopwatch jsonEncodeWatch = Stopwatch()..start();
    final String encoded = jsonEncode(response);
    jsonEncodeWatch.stop();
    serverWatch.stop();

    final Object? rawTraceId = body['lookupTraceId'];
    final Match? traceIdMatch = rawTraceId is String
        ? _lookupTraceIdPattern.firstMatch(rawTraceId)
        : null;
    final String? traceId = rawTraceId is String &&
            traceIdMatch != null &&
            traceIdMatch.start == 0 &&
            traceIdMatch.end == rawTraceId.length
        ? rawTraceId
        : null;
    return jsonRawResponse(
      encoded,
      extraHeaders: <String, String>{
        'Server-Timing': _dictionaryLookupServerTiming(
          requestJsonMicros: requestJsonWatch.elapsedMicroseconds,
          handlerMicros: handlerWatch.elapsedMicroseconds,
          jsonEncodeMicros: jsonEncodeWatch.elapsedMicroseconds,
          serverTotalMicros: serverWatch.elapsedMicroseconds,
          popupTiming: popupTiming,
        ),
        if (popupTiming.measured) 'X-Fushi-Lookup-Cache': popupTiming.cache,
        if (traceId != null) 'X-Fushi-Lookup-Id': traceId,
        'Access-Control-Expose-Headers':
            'Server-Timing, X-Fushi-Lookup-Cache, X-Fushi-Lookup-Id',
      },
    );
  }

  // /api/mine、/api/mine/forward、/api/anki/note-type/*、/api/duplicate、
  // /api/lookup/audio[/file] 的 handler 正文在 [RemoteLookupRoutes]（与
  // FushiSyncServer 共用）；扩展默认指向本 server（19633），故那是真正被命中的路径。

  /// A（BUG-783 后续）：浏览器扩展抓 YouTube 网页视频**真整集字幕**端点——复用 app 内已
  /// 修好的 `resolveYoutubeCaptionsForExtension`（androidVr getPlayerResponse + 现在认得
  /// format-3 的 timedtext 解析），返回全部轨（自动/人工）+ 各轨 cue，替扩展脆弱的 DOM 刮取。
  /// body：`{videoId 或 url, preferLang?}`。best-effort：无字幕/失败返回 `{tracks:[]}`（扩展
  /// 面板回落 live 采样，视频照看）。
  Future<shelf.Response> _handleYoutubeCaptions(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? id = body['videoId'] ?? body['url'];
    if (id is! String || id.isEmpty) {
      return shelf.Response(400, body: 'Missing videoId');
    }
    final Object? lang = body['preferLang'];
    return jsonResponse(await resolveYoutubeCaptionsForExtension(
      id,
      preferLang: lang is String && lang.isNotEmpty ? lang : 'ja',
    ));
  }

  /// B（asb 招牌）：浏览器扩展**给任意网页视频加载用户自己的外挂字幕文件**端点——扩展读本地
  /// srt/ass/vtt 文本 POST 上来，server 复用 app 内已测的 SRT/ASS/VTT parser 解析成 cue，扩展把
  /// cue 叠到当前网页视频。body：`{filename, content}`。不支持的扩展名回 `{error:'unsupported'}`。
  Future<shelf.Response> _handleSubtitleParse(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? filename = body['filename'];
    final Object? content = body['content'];
    if (filename is! String || content is! String || filename.isEmpty) {
      return shelf.Response(400, body: 'Missing filename/content');
    }
    return jsonResponse(
        buildParsedSubtitleResponse(filename: filename, content: content));
  }

  /// 弹窗尺寸精细化 Phase D：浏览器扩展弹窗被拖右下角把手调整尺寸后，content.js 经
  /// background（POST `/api/extension/popup-size` {maxWidth,maxHeight}）回写最终基准最大宽
  /// 高。走与查词同一 [_authMiddleware]（Basic `fushi:'+key`）鉴权——**不在**免鉴权白名
  /// 单里，绝不新开无鉴权写入口。收到 → 交给注入的 [_onExtensionPopupSize] sink（app 侧
  /// clamp 250-2000/200-1600 + 「拖即解锁」extensionPopupIndependentSize + 只写扩展键，
  /// 绝不碰 overlay/popupMax）。未注入（旧 app / 配对 host）时 404，无副作用（向后兼容）。
  Future<shelf.Response> _handleExtensionPopupSize(
      shelf.Request request) async {
    final void Function(double, double)? sink = _onExtensionPopupSize;
    if (sink == null) return shelf.Response.notFound('Popup size sink off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final dynamic w = body['maxWidth'];
    final dynamic h = body['maxHeight'];
    if (w is! num || h is! num) {
      return shelf.Response(400, body: 'Missing maxWidth/maxHeight');
    }
    sink(w.toDouble(), h.toDouble());
    return jsonResponse(<String, dynamic>{'ok': true});
  }

  Future<shelf.Response> _handleTermEntries(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final dynamic term = body?['term'];
    if (term is List) {
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (int i = 0; i < term.length; i++) {
        out.add(await _termEntriesFor(term[i]?.toString() ?? '', i));
      }
      return jsonRawResponse(jsonEncode(out));
    }
    return jsonResponse(await _termEntriesFor(term?.toString() ?? '', 0));
  }

  Future<Map<String, dynamic>> _termEntriesFor(String term, int index) async {
    if (term.trim().isEmpty) {
      return buildYomitanTermEntriesResponse(null, index);
    }
    final DictionarySearchResult? result = await _lookup.searchDictionary(
      term: term,
      wildcards: false,
      maximumTerms: 10,
    );
    return buildYomitanTermEntriesResponse(result, index);
  }

  Future<shelf.Response> _handleTokenize(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final dynamic text = body?['text'];
    if (text is List) {
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (int i = 0; i < text.length; i++) {
        out.add(buildYomitanTokenizeResponse(
          text: text[i]?.toString() ?? '',
          index: i,
          tokenize: _tokenizer,
          readingOf: _readingResolver,
        ));
      }
      return jsonRawResponse(jsonEncode(out));
    }
    return jsonResponse(buildYomitanTokenizeResponse(
      text: text?.toString() ?? '',
      index: 0,
      tokenize: _tokenizer,
      readingOf: _readingResolver,
    ));
  }

  String _dictionaryLookupServerTiming({
    required int requestJsonMicros,
    required int handlerMicros,
    required int jsonEncodeMicros,
    required int serverTotalMicros,
    required RemoteDictionaryPopupTiming popupTiming,
  }) {
    String metric(String name, int micros) =>
        '$name;dur=${(micros / 1000).toStringAsFixed(3)}';

    return <String>[
      metric('request-json', requestJsonMicros),
      metric('handler-map', handlerMicros),
      if (popupTiming.measured) ...<String>[
        metric('normalize', popupTiming.normalizeMicros),
        metric('popup-cache', popupTiming.popupCacheMicros),
        metric('full-cache', popupTiming.fullCacheMicros),
        metric('ffi-cache', popupTiming.ffiCacheMicros),
        metric('ffi-lookup', popupTiming.ffiLookupMicros),
        metric('popup-json', popupTiming.popupJsonMicros),
        metric('service-total', popupTiming.serviceTotalMicros),
      ],
      metric('json-encode', jsonEncodeMicros),
      metric('server-total', serverTotalMicros),
    ].join(', ');
  }
}
