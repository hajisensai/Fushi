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
    if (reqPath == '/api/lookup/dictionary/styles') {
      if (method != 'POST') return shelf.Response(405);
      return _handleRemoteDictionaryStyles(request);
    }
    if (reqPath == '/api/lookup/dictionary/media') {
      if (method != 'POST') return shelf.Response(405);
      return _handleRemoteDictionaryMedia(request);
    }
    if (reqPath == '/api/lookup/audio') {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleAudioLookup(request);
    }
    if (reqPath == '/api/lookup/audio/list') {
      if (method != 'POST') return shelf.Response(405);
      return _lookupRoutes.handleAudioList(request);
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
    // 契约与 FushiApiServer 共享（BUG-530，单一真相源）。
    return jsonResponse(
      await buildRemoteDictionaryLookupResponse(
        body,
        lookup: service,
        history: _historyService,
        // BUG-3425：对端（游戏串流）在它那边渲染、导出本机的查词结果，必须用本机的
        // 词典样式。与浏览器扩展同一套 `stylesRevision` 门控：请求不带该字段（老
        // 客户端）一个字节都不多发；带了且指纹不同才整表下发一次。
        popupDictionaryCssProvider: _dictionaryStylesProvider == null
            ? null
            : _peerDictionaryCss,
      ),
    );
  }

  /// 只含词典自带 CSS 的弹窗样式快照：用户自定义 CSS 属于**对端**自己的弹窗设置，
  /// 不从 host 下发。按 provider 返回的 map 身份缓存（`FushiDicts.dictionaryStyles`
  /// 只在词典集合变化时换实例），避免每次查词重新哈希数百 KB 的 CSS。
  RemotePopupDictionaryCss _peerDictionaryCss() {
    final Map<String, String> styles = _dictionaryStylesProvider!();
    final RemotePopupDictionaryCss? cached = _peerPopupDictionaryCss;
    if (cached != null && identical(cached.dictionaryStyles, styles)) {
      return cached;
    }
    return _peerPopupDictionaryCss = RemotePopupDictionaryCss(
      dictionaryStyles: styles,
      globalDictCss: '',
      customDictCss: const <String, String>{},
    );
  }

  /// `POST /api/lookup/dictionary/styles {dictionaries:[name…]}` →
  /// `{type:'dictionaryStyles', styles:{name: css}}`。
  ///
  /// 查词结果来自本机时，对端（手机遥控 / 远端查词）的弹窗必须用**本机**这份词典
  /// 样式渲染。点名时只回点名且本机确实装着的词典（一次最多 [_kMaxStyleNames] 个）；
  /// 不点名回整套。
  /// 鉴权走上方中间件（无豁免）。
  Future<shelf.Response> _handleRemoteDictionaryStyles(
    shelf.Request request,
  ) async {
    final Map<String, String> Function()? provider = _dictionaryStylesProvider;
    if (provider == null) return shelf.Response.notFound('Styles off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? names = body['dictionaries'];
    final Map<String, String> all = provider();
    if (names == null) {
      // 不点名 = 整套样式（客户端会话首查一次拿全，之后只在出现没见过的词典名时
      // 再拉）：结果里的释义可能来自词条之外的多部词典，逐名点要先解析 popupJson。
      return jsonResponse(<String, dynamic>{
        'type': 'dictionaryStyles',
        'styles': all,
      });
    }
    if (names is! List ||
        names.length > _kMaxStyleNames ||
        names.any((Object? name) => name is! String)) {
      return shelf.Response(400, body: 'Invalid dictionaries');
    }
    return jsonResponse(<String, dynamic>{
      'type': 'dictionaryStyles',
      'styles': <String, String>{
        for (final Object? name in names)
          if (all[name] != null) name! as String: all[name]!,
      },
    });
  }

  /// `POST /api/lookup/dictionary/media {dictionary, path}` →
  /// `{type:'dictionaryMedia', contentType, data:<base64>}`。
  ///
  /// 与免 Basic 的 `GET /api/media/dictionary`（浏览器扩展 `<img>` 用、凭 query
  /// token）不同，这条走配对凭据 + JSON，客户端复用互联 POST 传输层的候选 / 钉扎 /
  /// 401 语义。安全措施：
  ///  * 路径经 [safeDictionaryMediaPath] 规范化，越级 / 绝对路径 / 盘符 / NUL 一律
  ///    400，绝不交给引擎；
  ///  * 单文件上限 [kRemoteDictionaryMediaMaxBytes]，超了 413；
  ///  * Content-Type 由服务端按扩展名判定（[dictionaryMediaMimeType]），不信客户端。
  Future<shelf.Response> _handleRemoteDictionaryMedia(
    shelf.Request request,
  ) async {
    final Uint8List? Function(String, String)? provider =
        _dictionaryMediaProvider;
    if (provider == null) return shelf.Response.notFound('Media off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? dictionary = body['dictionary'];
    final Object? rawPath = body['path'];
    if (dictionary is! String ||
        dictionary.trim().isEmpty ||
        dictionary.contains('\u0000') ||
        rawPath is! String) {
      return shelf.Response(400, body: 'Invalid media request');
    }
    final String? path = safeDictionaryMediaPath(rawPath);
    if (path == null) return shelf.Response(400, body: 'Invalid media path');
    final Uint8List? bytes = provider(dictionary, path);
    if (bytes == null || bytes.isEmpty) {
      return shelf.Response.notFound('Not found');
    }
    if (bytes.length > kRemoteDictionaryMediaMaxBytes) {
      return shelf.Response(413, body: 'Media too large');
    }
    return jsonResponse(<String, dynamic>{
      'type': 'dictionaryMedia',
      'contentType': dictionaryMediaMimeType(path),
      'data': base64Encode(bytes),
    });
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

  static const int _kMaxStyleNames = 64;

  // /api/mine、/api/mine/forward、/api/anki/note-type/*、/api/duplicate、
  // /api/lookup/audio[/file] 的 handler 正文在 [RemoteLookupRoutes]（与
  // FushiApiServer 共用）；本文件只留互联独有的端点。

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
            await buildAnkiMediaDedupProbeResponse(mining: svc),
          );
        case '/api/anki/media/dedup/run':
          return jsonResponse(
            await buildAnkiMediaDedupRunResponse(body, mining: svc),
          );
        default:
          return shelf.Response.notFound('Unknown endpoint');
      }
    } on FormatException catch (e) {
      return shelf.Response(400, body: e.message);
    }
  }
}
