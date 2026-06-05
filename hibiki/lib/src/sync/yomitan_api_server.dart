import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart'
    show SyncServerPortInUseException, isAddressInUseError;
import 'package:hibiki/src/sync/yomitan_term_entries_adapter.dart';
import 'package:hibiki/src/sync/yomitan_tokenize_adapter.dart';

/// yomitan-api 默认端口（Kuuuube/yomitan-api）。
const int kYomitanApiDefaultPort = 19633;

/// 兼容 `Kuuuube/yomitan-api` 的独立 HTTP server（宽松兼容）。
/// 只接受 POST；可选 X-API-Key 鉴权；端点 serverVersion/yomitanVersion/
/// termEntries/tokenize。查词复用 [HibikiRemoteLookupService]。
class YomitanApiServer {
  YomitanApiServer({
    required int port,
    required HibikiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    required ReadingResolver readingResolver,
    String? apiKey,
    bool allowLan = false,
  })  : _requestedPort = port,
        _lookup = lookupService,
        _tokenizer = tokenizer,
        _readingResolver = readingResolver,
        _apiKey = apiKey,
        _allowLan = allowLan;

  final int _requestedPort;
  final HibikiRemoteLookupService _lookup;
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
      return (shelf.Request request) {
        final String? key = _apiKey;
        if (key == null || key.isEmpty) return inner(request);
        final String? provided = request.headers['x-api-key'];
        if (provided != key) {
          return shelf.Response(401, body: 'Unauthorized');
        }
        return inner(request);
      };
    };
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
      default:
        return shelf.Response.notFound('Unknown endpoint');
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
