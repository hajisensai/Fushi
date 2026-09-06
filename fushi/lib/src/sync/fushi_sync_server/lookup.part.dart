part of '../fushi_sync_server.dart';

/// 远程查词域（B3 按域拆出）：/api/lookup 分发、词典查询、词典媒体、Anki 媒体去重。
/// 查词音频 / 制卡六条路由在共享的 [RemoteLookupRoutes]；方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerLookup on FushiSyncServer {
  Future<shelf.Response> _handleLookupApi(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    if (reqPath == '/api/lookup/dictionary') {
      if (method != 'POST') return shelf.Response(405);
      return _handleDictionaryLookup(request);
    }
    if (reqPath == '/api/lookup/audio') {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleAudioLookup(request);
    }
    if (reqPath == '/api/lookup/audio/file') {
      if (method != 'GET' && method != 'HEAD') return shelf.Response(405);
      return _lookupRoutes.handleAudioFile(request, headOnly: method == 'HEAD');
    }
    return shelf.Response.notFound('Not found');
  }

  Future<shelf.Response> _handleDictionaryLookup(shelf.Request request) async {
    final FushiRemoteLookupService? service = _remoteLookupService;
    if (service == null) return shelf.Response.notFound('Remote lookup off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    // 契约与 YomitanApiServer 共享（BUG-530，单一真相源）。
    return jsonResponse(await buildRemoteDictionaryLookupResponse(
      body,
      lookup: service,
      history: _historyService,
    ));
  }

  /// Validates that [request]'s query token (?token= etc.) equals [_token].
  /// Used to admit the dictionary media endpoint without Basic auth (a web
  /// page <img> GET has no Authorization header). Constant-time comparison.
  bool _dictionaryMediaTokenValid(shelf.Request request) {
    for (final String name in _kDictionaryMediaTokenParams) {
      final String? value = request.url.queryParameters[name];
      if (value != null &&
          _constantTimeEquals(
            Uint8List.fromList(utf8.encode(value)),
            Uint8List.fromList(utf8.encode(_token)),
          )) {
        return true;
      }
    }
    return false;
  }

  /// TODO-1215: GET /api/media/dictionary?dictionary=<name>&path=<rel>&token=<t>
  /// -- dictionary gaiji / pitch-accent SVG (etc.) media bytes. The browser
  /// extension popup rewrites a term's <img src> from the in-app image:// URL
  /// to this endpoint (a real browser has no image:// handler). Bytes are
  /// resolved by the injected [_dictionaryMediaProvider] (bridged to
  /// FushiDicts.getMediaFile in-app); the MIME reuses the same
  /// [dictionaryMediaMimeType] as the app scheme handler.
  shelf.Response _handleDictionaryMedia(shelf.Request request, bool headOnly) {
    final Uint8List? Function(String, String)? provider =
        _dictionaryMediaProvider;
    if (provider == null) return shelf.Response.notFound('Media off');
    final String dictionary = request.url.queryParameters['dictionary'] ?? '';
    final String path = normalizeDictionaryMediaPath(
      request.url.queryParameters['path'] ?? '',
    );
    if (dictionary.isEmpty || path.isEmpty) {
      return shelf.Response.notFound('Not found');
    }
    final Uint8List? bytes = provider(dictionary, path);
    if (bytes == null || bytes.isEmpty) {
      return shelf.Response.notFound('Not found');
    }
    final String mime = dictionaryMediaMimeType(path);
    return shelf.Response.ok(
      headOnly ? null : bytes,
      headers: <String, String>{
        'Content-Type': mime,
        'Content-Length': '${bytes.length}',
        // The extension loads the image cross-origin on a real web page (and
        // may drawImage it onto a canvas for monochrome recolor); allow CORS
        // so any read-back path never taints the canvas. Media is
        // non-sensitive and already token-authenticated.
        'Access-Control-Allow-Origin': '*',
      },
    );
  }

  // /api/mine、/api/mine/forward、/api/anki/note-type/*、/api/duplicate、
  // /api/lookup/audio[/file] 的 handler 正文在 [RemoteLookupRoutes]（与
  // YomitanApiServer 共用）；本文件只留互联独有的端点。

  /// 互联媒体存储优化：客户端（手机）经互联对**主机端** collection.media 做字节级
  /// 去重——卡片落在主机的 Anki 上，重复媒体也堆在主机，客户端本机根本没有那个
  /// 目录。未注入挖词 service → 404（旧版主机对新客户端同样 404 → 客户端按
  /// 「不支持」隐藏区块）；dryRun 类型错 → 400。
  Future<shelf.Response> _handleAnkiMediaDedup(
    shelf.Request request,
    String path,
  ) async {
    final FushiRemoteMiningService? svc = _miningService;
    if (svc == null) return shelf.Response.notFound('Mining off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    try {
      switch (path) {
        case '/api/anki/media/dedup/probe':
          return jsonResponse(
              await buildAnkiMediaDedupProbeResponse(mining: svc));
        case '/api/anki/media/dedup/run':
          return jsonResponse(
              await buildAnkiMediaDedupRunResponse(body, mining: svc));
        default:
          return shelf.Response.notFound('Unknown endpoint');
      }
    } on FormatException catch (e) {
      return shelf.Response(400, body: e.message);
    }
  }
}
