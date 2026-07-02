import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

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
class YomitanApiServer {
  YomitanApiServer({
    required int port,
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    HibikiRemoteMiningService? miningService,
    HibikiRemoteHistoryService? historyService,
    String? apiKey,
    bool allowLan = false,
  })  : _requestedPort = port,
        _lookup = lookupService,
        _mining = miningService,
        _history = historyService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _apiKey = apiKey,
        _allowLan = allowLan;

  final int _requestedPort;
  final HibikiRemoteLookupService _lookup;
  final HibikiRemoteMiningService? _mining;
  final HibikiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  final ReadingResolver _readingResolver;
  final String? _apiKey;
  final bool _allowLan;

  HttpServer? _server;

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
    if (request.method.toUpperCase() != 'POST') {
      return shelf.Response(405, body: 'Method Not Allowed');
    }
    final String path = '/${request.url.path}';
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
      case '/api/mine':
        return _handleMine(request);
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
