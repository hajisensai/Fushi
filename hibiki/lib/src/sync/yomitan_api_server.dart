import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:hibiki/src/media/video/video_subtitle_source.dart'
    show buildParsedSubtitleResponse;
import 'package:hibiki/src/media/video/youtube_source_resolver.dart'
    show resolveYoutubeCaptionsForExtension;
import 'package:hibiki/src/sync/hibiki_remote_api_handlers.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart'
    show SyncServerPortInUseException, isAddressInUseError;
import 'package:hibiki/src/sync/yomitan_term_entries_adapter.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

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
/// `Basic base64('hibiki:'+key)`）。端点：serverVersion/yomitanVersion/termEntries/tokenize
/// （yomitan-api 兼容）+ `/api/lookup/dictionary` + `/api/mine`（BUG-530：浏览器扩展契约，
/// 与 HibikiSyncServer 共享 [buildRemoteDictionaryLookupResponse]/[buildRemoteMineResponse]）。
/// 浏览器扩展连接探活的 POST 端点集合：命中其一即视作「扩展（或 in-app 弹窗）活跃」。
/// 只列扩展真正会主动打的端点——状态探测 + 查词/制卡/查重/音频，不含裸 GET 音频文件。
const Set<String> _kExtensionSeenPaths = <String>{
  '/api/extension/status',
  '/api/lookup/dictionary',
  '/api/lookup/audio',
  '/api/mine',
  '/api/duplicate',
};

class YomitanApiServer {
  YomitanApiServer({
    required int port,
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    HibikiRemoteMiningService? miningService,
    HibikiRemoteHistoryService? historyService,
    Map<String, String> Function()? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    String? Function()? extensionBuildProvider,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function()? onExtensionSeen,
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
        _extensionBuildProvider = extensionBuildProvider,
        _onExtensionPopupSize = onExtensionPopupSize,
        _onExtensionSeen = onExtensionSeen,
        _apiKey = apiKey,
        _allowLan = allowLan;

  final int _requestedPort;
  final HibikiRemoteLookupService _lookup;
  final HibikiRemoteMiningService? _mining;
  final HibikiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  // BUG-530：当前 app 主题的 CSS 变量供给器，随查词响应下发给浏览器扩展弹窗。
  final Map<String, String> Function()? _themeColorsProvider;
  // 单词音频：当前 app 已启用的音频源供给器，随查词响应下发给扩展弹窗。
  final List<String> Function()? _audioSourcesProvider;
  // BUG-726：app 内置扩展内容指纹供给器，随查词响应下发，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;
  // 弹窗尺寸精细化 Phase D：扩展弹窗被拖角调整尺寸后，content.js 经 bridge 回写最终基准
  // 最大宽高；这个 sink 收到（未 clamp 的原始逻辑像素）→ app 侧 clamp + 拖即解锁 + 写扩展键。
  // 未注入（旧 app / 配对 sync host）时端点 404（向后兼容，无写偏好副作用）。
  final void Function(double maxWidth, double maxHeight)? _onExtensionPopupSize;
  // 浏览器扩展连接探活：任一扩展端点被命中即回调（app 侧记录 last-seen 时间戳，
  // 供「安装 → 验证插件已正常启用」的连接检测显示）。扩展 background 在 SW 启动时
  // 主动打 /api/extension/status，故装完扩展即刷新 last-seen，无需用户先划词。
  final void Function()? _onExtensionSeen;
  final String? _apiKey;
  final bool _allowLan;

  HttpServer? _server;

  // 单词音频短命 token（与 HibikiSyncServer 同款模型）：/api/lookup/audio 存字节、返
  // 免鉴权的 /api/lookup/audio/file?id= URL；命中即续期，5 分钟无访问后 prune。
  final Map<String, _YomitanAudioToken> _remoteAudioTokens =
      <String, _YomitanAudioToken>{};

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
  }

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) async {
        // 单词音频文件端点是裸 GET（HTML5 Audio 无 Authorization）→ 免鉴权放行，靠
        // 不可猜的短命 id 兜底（与 HibikiSyncServer 的 /api/lookup/audio/file 同策略）。
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
      // BUG-530：Hibiki 浏览器扩展用 `Basic base64('hibiki:'+key)`（与 HibikiSyncServer
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
      return _handleAudioFile(request, headOnly: method == 'HEAD');
    }
    if (method != 'POST') {
      return shelf.Response(405, body: 'Method Not Allowed');
    }
    // 浏览器扩展连接探活：这些 POST 端点只有已加载的扩展（或 in-app 弹窗）会命中，
    // 命中即刷新 app 侧 last-seen（连接检测据此判断「插件已正常启用」）。
    if (_kExtensionSeenPaths.contains(path)) {
      _onExtensionSeen?.call();
    }
    switch (path) {
      case '/serverVersion':
        return _json(<String, dynamic>{'version': 1});
      case '/yomitanVersion':
        return _json(<String, dynamic>{'version': '0.0.0.0'});
      case '/termEntries':
        return _handleTermEntries(request);
      case '/tokenize':
        return _handleTokenize(request);
      case '/api/lookup/dictionary':
        return _handleDictionaryLookup(request);
      case '/api/lookup/audio':
        return _handleAudioLookup(request);
      case '/api/mine':
        return _handleMine(request);
      case '/api/duplicate':
        return _handleDuplicate(request);
      case '/api/extension/popup-size':
        return _handleExtensionPopupSize(request);
      case '/api/extension/status':
        // BUG-726/自更新：状态端点回带当前内置扩展指纹（extensionBuild），扩展
        // background 在 SW 启动时打这里比对自身 build，不一致即 chrome.runtime.reload()
        // 从磁盘拉新——把「只有查词才检查更新」升级为「启动即主动检查」。null（指纹
        // 尚未算好 / 旧 app）时省略该字段，向后兼容。
        {
          final String? extensionBuild = _extensionBuildProvider?.call();
          return _json(<String, dynamic>{
            'app': 'hibiki',
            'ready': true,
            'port': port,
            if (extensionBuild != null) 'extensionBuild': extensionBuild,
          });
        }
      case '/api/youtube/captions':
        return _handleYoutubeCaptions(request);
      case '/api/subtitle/parse':
        return _handleSubtitleParse(request);
      default:
        return shelf.Response.notFound('Unknown endpoint');
    }
  }

  /// BUG-530：浏览器扩展查词端点（与 HibikiSyncServer 共享契约）。
  Future<shelf.Response> _handleDictionaryLookup(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    return _json(await buildRemoteDictionaryLookupResponse(
      body,
      lookup: _lookup,
      history: _history,
      themeColorsProvider: _themeColorsProvider,
      audioSourcesProvider: _audioSourcesProvider,
      extensionBuildProvider: _extensionBuildProvider,
    ));
  }

  /// BUG-530：浏览器扩展制卡端点（与 HibikiSyncServer 共享契约）。未注入挖词 service
  /// 时 404（mining off）；fields 缺失/类型错 → 400。
  Future<shelf.Response> _handleMine(shelf.Request request) async {
    final HibikiRemoteMiningService? mining = _mining;
    if (mining == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    try {
      return _json(await buildRemoteMineResponse(body, mining: mining));
    } on FormatException {
      return shelf.Response(400, body: 'Missing fields');
    }
  }

  /// TODO-1176：浏览器扩展查词弹窗制卡按钮真查重端点（`+`→`✓`，与 HibikiSyncServer 共享
  /// 契约）。扩展默认指向本 server（19633），故这里是真正被命中的路径。未注入挖词 service
  /// 时返回 `{duplicate:false}`（弹窗降级为「+」）。
  Future<shelf.Response> _handleDuplicate(shelf.Request request) async {
    final HibikiRemoteMiningService? mining = _mining;
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    if (mining == null) {
      return _json(<String, dynamic>{'duplicate': false});
    }
    return _json(await buildRemoteDuplicateResponse(body, mining: mining));
  }

  /// A（BUG-783 后续）：浏览器扩展抓 YouTube 网页视频**真整集字幕**端点——复用 app 内已
  /// 修好的 `resolveYoutubeCaptionsForExtension`（androidVr getPlayerResponse + 现在认得
  /// format-3 的 timedtext 解析），返回全部轨（自动/人工）+ 各轨 cue，替扩展脆弱的 DOM 刮取。
  /// body：`{videoId 或 url, preferLang?}`。best-effort：无字幕/失败返回 `{tracks:[]}`（扩展
  /// 面板回落 live 采样，视频照看）。
  Future<shelf.Response> _handleYoutubeCaptions(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? id = body['videoId'] ?? body['url'];
    if (id is! String || id.isEmpty) {
      return shelf.Response(400, body: 'Missing videoId');
    }
    final Object? lang = body['preferLang'];
    return _json(await resolveYoutubeCaptionsForExtension(
      id,
      preferLang: lang is String && lang.isNotEmpty ? lang : 'ja',
    ));
  }

  /// B（asb 招牌）：浏览器扩展**给任意网页视频加载用户自己的外挂字幕文件**端点——扩展读本地
  /// srt/ass/vtt 文本 POST 上来，server 复用 app 内已测的 SRT/ASS/VTT parser 解析成 cue，扩展把
  /// cue 叠到当前网页视频。body：`{filename, content}`。不支持的扩展名回 `{error:'unsupported'}`。
  Future<shelf.Response> _handleSubtitleParse(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? filename = body['filename'];
    final Object? content = body['content'];
    if (filename is! String || content is! String || filename.isEmpty) {
      return shelf.Response(400, body: 'Missing filename/content');
    }
    return _json(
        buildParsedSubtitleResponse(filename: filename, content: content));
  }

  /// 弹窗尺寸精细化 Phase D：浏览器扩展弹窗被拖右下角把手调整尺寸后，content.js 经
  /// background（POST `/api/extension/popup-size` {maxWidth,maxHeight}）回写最终基准最大宽
  /// 高。走与查词同一 [_authMiddleware]（Basic `hibiki:'+key`）鉴权——**不在**免鉴权白名
  /// 单里，绝不新开无鉴权写入口。收到 → 交给注入的 [_onExtensionPopupSize] sink（app 侧
  /// clamp 250-2000/200-1600 + 「拖即解锁」extensionPopupIndependentSize + 只写扩展键，
  /// 绝不碰 overlay/popupMax）。未注入（旧 app / 配对 host）时 404，无副作用（向后兼容）。
  Future<shelf.Response> _handleExtensionPopupSize(
      shelf.Request request) async {
    final void Function(double, double)? sink = _onExtensionPopupSize;
    if (sink == null) return shelf.Response.notFound('Popup size sink off');
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final dynamic w = body['maxWidth'];
    final dynamic h = body['maxHeight'];
    if (w is! num || h is! num) {
      return shelf.Response(400, body: 'Missing maxWidth/maxHeight');
    }
    sink(w.toDouble(), h.toDouble());
    return _json(<String, dynamic>{'ok': true});
  }

  /// 单词音频①解析：POST /api/lookup/audio {expression,reading}。用与 app 同一
  /// [HibikiRemoteLookupService.lookupAudio]（本地音频库）解析出字节，存进短命 token，
  /// 返回免鉴权的 /api/lookup/audio/file?id= URL 供扩展 HTML5 Audio 直接播放。未命中
  /// 返回 {url:null}（弹窗降级为 ✕，与 app 一致）。与 HibikiSyncServer 同款实现。
  Future<shelf.Response> _handleAudioLookup(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final String expression = body['expression']?.toString() ?? '';
    final String reading = body['reading']?.toString() ?? '';
    if (expression.trim().isEmpty) return _audioMissResponse();
    final RemoteAudioLookup? lookup = await _lookup.lookupAudio(
      expression: expression,
      reading: reading,
    );
    if (lookup == null) return _audioMissResponse();
    final String id = _generateAudioToken();
    _remoteAudioTokens[id] = _YomitanAudioToken(
      bytes: lookup.bytes,
      contentType: lookup.contentType,
      createdAt: DateTime.now(),
    );
    final Uri url = request.requestedUri.replace(
      path: '/api/lookup/audio/file',
      queryParameters: <String, String>{'id': id},
    );
    return _json(<String, dynamic>{
      'type': 'audioResult',
      'url': url.toString(),
      'contentType': lookup.contentType,
    });
  }

  /// 单词音频②取字节：GET /api/lookup/audio/file?id=（免鉴权，靠不可猜 id）。命中即续期
  /// 5 分钟窗口，使正在播放的音频不会中途被 prune。
  shelf.Response _handleAudioFile(shelf.Request request,
      {required bool headOnly}) {
    _pruneAudioTokens();
    final String? id = request.url.queryParameters['id'];
    final _YomitanAudioToken? token =
        id == null ? null : _remoteAudioTokens[id];
    if (token == null) return shelf.Response.notFound('Not found');
    token.createdAt = DateTime.now();
    return shelf.Response.ok(
      headOnly ? null : token.bytes,
      headers: <String, String>{
        'Content-Type': token.contentType,
        'Content-Length': '${token.bytes.length}',
      },
    );
  }

  shelf.Response _audioMissResponse() => _json(<String, dynamic>{
        'type': 'audioResult',
        'url': null,
        'contentType': null,
      });

  String _generateAudioToken() {
    final Random random = Random.secure();
    final List<int> bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _pruneAudioTokens() {
    final DateTime cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    _remoteAudioTokens.removeWhere(
      (String _, _YomitanAudioToken token) => token.createdAt.isBefore(cutoff),
    );
  }

  Future<shelf.Response> _handleTermEntries(shelf.Request request) async {
    final Map<String, dynamic>? body = await _readJson(request);
    final dynamic term = body?['term'];
    if (term is List) {
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (int i = 0; i < term.length; i++) {
        out.add(await _termEntriesFor(term[i]?.toString() ?? '', i));
      }
      return _jsonRaw(jsonEncode(out));
    }
    return _json(await _termEntriesFor(term?.toString() ?? '', 0));
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
    final Map<String, dynamic>? body = await _readJson(request);
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
      return _jsonRaw(jsonEncode(out));
    }
    return _json(buildYomitanTokenizeResponse(
      text: text?.toString() ?? '',
      index: 0,
      tokenize: _tokenizer,
      readingOf: _readingResolver,
    ));
  }

  Future<Map<String, dynamic>?> _readJson(shelf.Request request) async {
    try {
      final String raw = await request.readAsString();
      if (raw.isEmpty) return null;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 客户端请求体非法 JSON：当作无 body 处理，由调用方回 400。
    }
    return null;
  }

  shelf.Response _json(Object body) => _jsonRaw(jsonEncode(body));

  shelf.Response _jsonRaw(String body) => shelf.Response.ok(
        body,
        headers: <String, String>{
          'Content-Type': 'application/json; charset=utf-8'
        },
      );
}

/// 单词音频短命 token（[YomitanApiServer] 私有，镜像 HibikiSyncServer 的同款模型）。
/// createdAt 非 final——每次被 [YomitanApiServer._handleAudioFile] 命中即刷新，重置 5
/// 分钟过期窗口，使正在被访问的音频不会中途过期。
class _YomitanAudioToken {
  _YomitanAudioToken({
    required this.bytes,
    required this.contentType,
    required this.createdAt,
  });

  final Uint8List bytes;
  final String contentType;
  DateTime createdAt;
}
