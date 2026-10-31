import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart'
    show VideoSubtitleRegistry;
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart'
    show BrowserVideoSample;
import 'package:fushi/src/srs/srs_term_status_bridge.dart'
    show kSrsTermStatusBatchMax;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsTermQuery;
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/remote_lookup_routes.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart'
    show SyncServerPortInUseException, isAddressInUseError;
import 'package:fushi/src/sync/browser_extension_test_page.dart'
    show kBrowserExtensionTestPagePath;
import 'package:fushi/src/sync/extension_font_api.dart';
import 'package:fushi/src/sync/extension_profile_api.dart';
import 'package:fushi/src/sync/fushi_api_access_policy.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';
import 'package:fushi/src/sync/yomitan_term_entries_adapter.dart';
import 'package:fushi/src/sync/yomitan_tokenize_adapter.dart';

/// yomitan-api 默认端口（Kuuuube/yomitan-api）。
const int kFushiApiDefaultPort = 19633;

const List<String> _apiKeyParameterNames = <String>[
  'apiKey',
  'api_key',
  'key',
  'token',
  'fushiApiKey',
  'fushi_api_key',
  // 旧名：yomitan-api 时代的客户端仍在发，保留兼容。新代码与文档用上面两个。
  'yomitanApiKey',
  'yomitan_api_key',
];

/// 兼容 `Kuuuube/yomitan-api` 的独立 HTTP server（宽松兼容），同时是 Fushi 浏览器扩展
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
  '/api/lookup/audio/list',
  '/api/mine',
  '/api/duplicate',
  '/api/anki/open',
  '/api/extension/favorite',
  '/api/srs/term-status',
  '/api/srs/term-status-batch',
};

/// 反馈 biLEesNqWb（并入 TODO-2936 的「浏览器」媒体类型绑定）：「按配置生效」的端点。
/// 查词（词典启用 / 顺序 / 弹窗设置）、制卡与查重（Anki 牌组 / 字段映射 / 挖词目标）、单词
/// 音频（音频源）、在 Anki 中打开都按 [ExtensionProfileApi.resolveScope] 解析出的配置处理；
/// 字幕 / 字体 / 统计这类与配置无关的端点不在内。刻意**不含** `/api/extension/status`：
/// 那是扩展 SW 启动的探活 ping。
const Set<String> _kProfileScopedPaths = <String>{
  '/termEntries',
  '/tokenize',
  '/api/lookup/dictionary',
  '/api/lookup/audio',
  '/api/lookup/audio/list',
  '/api/mine',
  '/api/duplicate',
  '/api/anki/open',
  // 复习标记：词状态 / 点标记打开都按所选配置的复习（挖词目标 = 复习时卡就制进那份配置的复习）。
  '/api/srs/term-status',
  '/api/srs/term-status-batch',
  '/api/srs/open',
};

/// BUG-3141：扩展查词弹窗收藏请求（`/api/extension/favorite` 的体）。
class ExtensionFavoriteRequest {
  const ExtensionFavoriteRequest({
    required this.toggle,
    required this.expression,
    required this.reading,
    this.glossary = '',
    this.sentence = '',
  });

  /// true = 切换收藏（popup.js favoriteEntry），false = 只读（favoriteCheck）。
  final bool toggle;
  final String expression;
  final String reading;

  /// 释义快照（popup.js favoriteGlossaryText），只在切换时有意义。
  final String glossary;

  /// 扩展侧取到的当前句（字幕行 / 页面句），收藏夹显示用。
  final String sentence;

  /// 体不合契约（词形为空 / 非字符串）返回 null。
  static ExtensionFavoriteRequest? tryParse(Map<String, dynamic> body) {
    final Object? expression = body['expression'];
    if (expression is! String || expression.trim().isEmpty) return null;
    final Object? reading = body['reading'];
    final Object? glossary = body['glossary'];
    final Object? sentence = body['sentence'];
    return ExtensionFavoriteRequest(
      toggle: body['toggle'] == true,
      expression: expression,
      reading: reading is String ? reading : '',
      glossary: glossary is String ? glossary : '',
      sentence: sentence is String ? sentence : '',
    );
  }
}

/// 收藏读写的 app 侧实现：回**处理后**的收藏态。
typedef ExtensionFavoriteHandler =
    Future<bool> Function(ExtensionFavoriteRequest request);

/// 复习（Fushi SRS）给浏览器扩展弹窗的端点（`/api/srs/term-status`、
/// `/api/srs/term-status-batch`、`/api/srs/open`）。复习模块关着时供给器回 null → 都 404。
abstract interface class SrsExtensionApi {
  /// 词状态回包（null = 复习库里没有这个词）。形状见 srs_term_status_bridge.dart。
  Future<Map<String, Object?>?> termStatus(String expression, String reading);

  /// 批量词状态（`/api/srs/term-status-batch`）：回包与 [terms] 等长同序，没有的词为 null。
  Future<List<Map<String, Object?>?>> termStatuses(List<SrsTermQuery> terms);

  /// 在 app 里打开这张卡。
  Future<bool> openCard({required String cardId, String? noteId});
}

class FushiApiServer {
  static final RegExp _lookupTraceIdPattern = RegExp(
    r'^[A-Za-z0-9._:-]{1,64}$',
  );

  FushiApiServer({
    required int port,
    required FushiRemoteLookupService lookupService,
    required Tokenizer tokenizer,
    FushiRemoteMiningService? miningService,
    FushiRemoteHistoryService? historyService,
    RemoteThemeColorsProvider? themeColorsProvider,
    List<String> Function()? audioSourcesProvider,
    bool Function()? autoReadOnLookupProvider,
    bool Function()? dictionaryUnifiedStyleProvider,
    String? Function()? extensionBuildProvider,
    String Function()? appLocaleProvider,
    RemotePopupDictionaryCss Function()? popupDictionaryCssProvider,
    void Function(double maxWidth, double maxHeight)? onExtensionPopupSize,
    void Function(BrowserVideoSample sample)? onExtensionStudy,
    ExtensionFavoriteHandler? onExtensionFavorite,
    void Function()? onExtensionSeen,
    void Function(String build, String? version)? onExtensionReport,
    Future<VideoSubtitleRegistry?> Function()? subtitleRegistryProvider,
    String Function()? extensionTestPageProvider,
    ExtensionFontApi? fontApi,
    SrsExtensionApi? Function()? srsApiProvider,
    ExtensionProfileApi? profileApi,
    String? apiKey,
    FushiApiAccessPolicy accessPolicy = FushiApiAccessPolicy.localOnly,
    SrsAnkiConnectEndpoint? ankiConnectEndpoint,
    int? ankiConnectCompatPort,
    FushiExtensionApiCore? extensionApiCore,
  }) : _requestedPort = port,
       _ankiConnect = ankiConnectEndpoint,
       _ankiConnectCompatPort = ankiConnectCompatPort,
       _lookup = lookupService,
       _mining = miningService,
       _history = historyService,
       _tokenizer = tokenizer,
       _themeColorsProvider = themeColorsProvider,
       _audioSourcesProvider = audioSourcesProvider,
       _autoReadOnLookupProvider = autoReadOnLookupProvider,
       _dictionaryUnifiedStyleProvider = dictionaryUnifiedStyleProvider,
       _extensionBuildProvider = extensionBuildProvider,
       _appLocaleProvider = appLocaleProvider,
       _popupDictionaryCssProvider = popupDictionaryCssProvider,
       _onExtensionFavorite = onExtensionFavorite,
       _onExtensionSeen = onExtensionSeen,
       _onExtensionReport = onExtensionReport,
       _extensionTestPageProvider = extensionTestPageProvider,
       _fontApi = fontApi,
       _srsApiProvider = srsApiProvider,
       _profileApi = profileApi,
       _apiKey = apiKey,
       _accessPolicy = accessPolicy,
       _ownsExtensionApi = extensionApiCore == null,
       _extensionApi =
           extensionApiCore ??
           FushiExtensionApiCore(
             subtitleRegistryProvider: subtitleRegistryProvider,
             fontApi: fontApi,
             onExtensionPopupSize: onExtensionPopupSize,
             onExtensionStudy: onExtensionStudy,
           );

  final int _requestedPort;
  final FushiRemoteLookupService _lookup;
  final FushiRemoteMiningService? _mining;
  final FushiRemoteHistoryService? _history;
  final Tokenizer _tokenizer;
  // BUG-530：当前 app 主题的 CSS 变量供给器，随查词响应下发给浏览器扩展弹窗。参数是
  // 扩展显式要求的明暗（请求体 `colorScheme`），null = 跟随 app 当前明暗。
  final RemoteThemeColorsProvider? _themeColorsProvider;
  // 单词音频：当前 app 已启用的音频源供给器，随查词响应下发给扩展弹窗。
  final List<String> Function()? _audioSourcesProvider;

  /// 查词后自动朗读偏好（`autoReadOnLookup`）：随查词响应下发给浏览器扩展，让扩展弹窗
  /// 与 app 内/app 外三个表面用同一个开关自动发音。
  final bool Function()? _autoReadOnLookupProvider;

  /// 「统一词典样式」偏好：随查词响应下发，扩展弹窗与 app 内弹窗同一个开关。
  final bool Function()? _dictionaryUnifiedStyleProvider;
  // BUG-726：app 内置扩展内容指纹供给器，随查词响应下发，驱动扩展自 reload 拉新。
  final String? Function()? _extensionBuildProvider;
  // app 当前 UI 语言供给器（Slang languageTag）：随 /api/extension/status 的 `locale` 与
  // 查词响应的 `appLocale` 下发，扩展据此选文案；未注入时两处都省略字段（向后兼容）。
  final String Function()? _appLocaleProvider;
  // BUG-1718：词典自带 CSS + 用户自定义 CSS 供给器，按 revision 门控随查词响应下发给扩展弹窗。
  final RemotePopupDictionaryCss Function()? _popupDictionaryCssProvider;
  // 浏览器扩展与 HTTP 无关的一组端点（YouTube 字幕 / 外挂字幕解析 / 在线字幕搜索下载 /
  // 字体列表 / 弹窗尺寸回写 / 视频沉浸时间）的核心逻辑，见 [FushiExtensionApiCore.paths]。
  // 弹窗尺寸 / 沉浸时间 sink、在线字幕 registry 供给器都在这里；未注入时对应端点 404
  // （旧 app / 配对 sync host 向后兼容）。app 内浏览器进程内直接调同一实例。
  final FushiExtensionApiCore _extensionApi;
  // 核心是本 server 自建的（没注入）才归它管：停服时清候选缓存。注入的那份与 app 内
  // 浏览器共用，停 / 重启 HTTP 服务不能把浏览器里「查字幕」搜到一半的候选清掉。
  final bool _ownsExtensionApi;
  // BUG-3141：扩展查词弹窗 ☆/★ 收藏（POST `/api/extension/favorite`）。app 侧与 app 外
  // 浮窗的 favoriteEntry / favoriteCheck 两个桥同一份收藏读写。未注入时端点 404。
  final ExtensionFavoriteHandler? _onExtensionFavorite;
  // 浏览器扩展连接探活：任一扩展端点被命中即回调（app 侧记录 last-seen 时间戳，
  // 供「安装 → 验证插件已正常启用」的连接检测显示）。扩展 background 在 SW 启动时
  // 主动打 /api/extension/status，故装完扩展即刷新 last-seen，无需用户先划词。
  final void Function()? _onExtensionSeen;
  // BUG-1079：扩展经 /api/extension/status 请求体自报「浏览器中实际加载的 build」
  // （+ manifest version）。app 侧记录后与内置指纹比对，不一致时在扩展管理页给出
  // 更新提示。旧扩展发 '{}'（无 build 字段）时不回调——行为等同现状（向后兼容）。
  final void Function(String build, String? version)? _onExtensionReport;

  /// 新手引导「试一试」页的 HTML 供给器：请求到达时才生成（例句随用户已装词典的
  /// 词头语言走，文案随当前 app 语言走）。未注入时该路由 404。
  final String Function()? _extensionTestPageProvider;

  /// 扩展字幕外观「字体」下拉框的真源：app 字体目录 + 推荐字体下载
  /// （`/api/extension/fonts` / `fonts/file` / `fonts/download`）。未注入时三路 404。
  /// 列表端点经 [_extensionApi]；这里供字节 / 下载两路。
  final ExtensionFontApi? _fontApi;

  /// 复习（SRS）扩展端点的供给器；未注入或回 null（模块关）时 `/api/srs/*` 404。
  final SrsExtensionApi? Function()? _srsApiProvider;

  /// 反馈 biLEesNqWb：扩展手动选配置 + 「浏览器」媒体类型绑定的解析。未注入时
  /// `/api/extension/profiles` 404、请求头被忽略，全部请求走默认服务组。
  final ExtensionProfileApi? _profileApi;
  final String? _apiKey;

  /// 网络层「允许谁连」：决定监听地址，并在密钥校验之前对**每个**请求判来源。
  final FushiApiAccessPolicy _accessPolicy;

  HttpServer? _server;

  /// AnkiConnect v6 兼容端点（Fushi SRS）：挂在根路径 `/`。null（SRS 模块关闭）时根路径照旧 404、
  /// 不暴露。端点自己做 Origin 白名单 / 回环限制 / key 校验，所以根路径**不经** [_authMiddleware]
  /// （中间件的 401 纯文本会挡掉 CORS 预检，也不是 AnkiConnect 客户端认得的错误形状）。
  SrsAnkiConnectEndpoint? _ankiConnect;

  /// 「同时监听 AnkiConnect 默认端口（8765）」的预留参数：非 null 且端点已注入时，在回环地址
  /// 上另起一个只服务兼容端点的监听；端口被占（真 Anki 开着）就不监听、只记日志。
  final int? _ankiConnectCompatPort;
  HttpServer? _ankiConnectCompatServer;

  SrsAnkiConnectEndpoint? get ankiConnectEndpoint => _ankiConnect;

  /// 注入 / 卸下兼容端点（SRS 模块开关由 app 侧 provider 驱动）。运行中切换立即生效。
  set ankiConnectEndpoint(SrsAnkiConnectEndpoint? endpoint) {
    _ankiConnect = endpoint;
    if (endpoint == null) {
      unawaited(_stopAnkiConnectCompatListener());
    } else if (_server != null) {
      unawaited(_startAnkiConnectCompatListener());
    }
  }

  /// 兼容端口上实际在监听的端口（没监听为 null）。
  int? get ankiConnectCompatListenPort => _ankiConnectCompatServer?.port;

  Future<void> _startAnkiConnectCompatListener() async {
    final int? port = _ankiConnectCompatPort;
    if (port == null || _ankiConnect == null) return;
    if (_ankiConnectCompatServer != null) return;
    try {
      _ankiConnectCompatServer = await shelf_io.serve(
        (shelf.Request request) async {
          final SrsAnkiConnectEndpoint? endpoint = _ankiConnect;
          if (endpoint == null || request.url.path.isNotEmpty) {
            return shelf.Response.notFound('Not Found');
          }
          return endpoint.handle(request);
        },
        InternetAddress.loopbackIPv4,
        port,
      );
    } on SocketException catch (e) {
      debugPrint(
        'FushiApiServer: AnkiConnect compat port $port unavailable '
        '(${isAddressInUseError(e) ? 'in use — is Anki running?' : e.message}); '
        'not listening',
      );
    }
  }

  Future<void> _stopAnkiConnectCompatListener() async {
    final HttpServer? s = _ankiConnectCompatServer;
    _ankiConnectCompatServer = null;
    await s?.close(force: true);
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
        .addMiddleware(_networkAccessMiddleware())
        .addMiddleware(_authMiddleware())
        .addHandler(_handleRequest);
    try {
      _server = await shelf_io.serve(
        handler,
        _accessPolicy.bindAddress,
        _requestedPort,
      );
    } on SocketException catch (e) {
      if (isAddressInUseError(e)) {
        throw SyncServerPortInUseException(_requestedPort);
      }
      rethrow;
    }
    await _startAnkiConnectCompatListener();
  }

  Future<void> stop() async {
    await _stopAnkiConnectCompatListener();
    await _server?.close(force: true);
    _server = null;
    if (_ownsExtensionApi) _extensionApi.clearSubtitleCandidates();
  }

  /// 网络层访问控制，先于 [_authMiddleware]、覆盖全部路径（含免密钥的音频文件 /
  /// 「试一试」页与 AnkiConnect 兼容端点）。判据见 [FushiApiAccessPolicy.decide]：
  /// 本机恒放行；非本机须在允许范围内**且**已设密钥。
  shelf.Middleware _networkAccessMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) {
        final Object? info = request.context['shelf.io.connection_info'];
        final InternetAddress? remote = info is HttpConnectionInfo
            ? info.remoteAddress
            : null;
        final String? key = _apiKey;
        final FushiApiAccessDecision decision = _accessPolicy.decide(
          remote: remote,
          keyConfigured: key != null && key.isNotEmpty,
        );
        if (decision == FushiApiAccessDecision.allow) return inner(request);
        return shelf.Response.forbidden(_accessDeniedMessage(decision));
      };
    };
  }

  static String _accessDeniedMessage(FushiApiAccessDecision decision) =>
      switch (decision) {
        FushiApiAccessDecision.denyNoKey =>
          'Fushi API only accepts requests from this device until an API key '
              'is set',
        FushiApiAccessDecision.denyNotInAllowList =>
          'This address is not in the Fushi API allowed networks',
        FushiApiAccessDecision.denyLocalOnly =>
          'Fushi API only accepts requests from this device',
        FushiApiAccessDecision.denyUnknownPeer ||
        FushiApiAccessDecision.allow => 'Forbidden',
      };

  shelf.Middleware _authMiddleware() {
    return (shelf.Handler inner) {
      return (shelf.Request request) async {
        // 单词音频文件端点是裸 GET（HTML5 Audio 无 Authorization）→ 免鉴权放行，靠
        // 不可猜的短命 id 兜底（与 FushiSyncServer 的 /api/lookup/audio/file 同策略）。
        if (request.url.path == 'api/lookup/audio/file') return inner(request);
        // 「试一试」页是浏览器地址栏直接打开的裸 GET（无 Authorization），且只吐一张
        // 静态说明页（例句 + 操作步骤，无任何用户数据）→ 与音频文件端点同策略放行。
        if ('/${request.url.path}' == kBrowserExtensionTestPagePath) {
          return inner(request);
        }
        // AnkiConnect 兼容端点自带鉴权（见 [_ankiConnect]）；未注入时照常走鉴权后 404。
        if (request.url.path.isEmpty && _ankiConnect != null) {
          return inner(request);
        }
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
            base64Decode(authorization.substring(basicPrefix.length)),
          );
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
    // 「试一试」页同样是裸 GET/HEAD（用户从 app 点开、浏览器直接访问）→ 405 门之前处理。
    if (path == kBrowserExtensionTestPagePath) {
      if (method != 'GET' && method != 'HEAD') {
        return shelf.Response(405, body: 'Method Not Allowed');
      }
      final String Function()? build = _extensionTestPageProvider;
      if (build == null) return shelf.Response.notFound('Not Found');
      final String html = build();
      return shelf.Response.ok(
        method == 'HEAD' ? '' : html,
        headers: <String, String>{
          'content-type': 'text/html; charset=utf-8',
          'cache-control': 'no-store',
        },
      );
    }
    // 扩展 `@font-face` 拉字体字节是裸 GET/HEAD → 405 门之前处理。**仍走鉴权中间件**
    // （它已接受查询串 `token=`），不进免鉴权白名单：字体文件是用户数据目录里的东西。
    if (path == '/api/extension/fonts/file') {
      if (method != 'GET' && method != 'HEAD') {
        return shelf.Response(405, body: 'Method Not Allowed');
      }
      return _handleExtensionFontFile(request, headOnly: method == 'HEAD');
    }
    if (path == '/api/extension/fonts/dictionary') {
      if (method != 'GET' && method != 'HEAD') {
        return shelf.Response(405, body: 'Method Not Allowed');
      }
      return _handleExtensionFontFile(
        request,
        headOnly: method == 'HEAD',
        dictionary: true,
      );
    }
    // AnkiConnect 兼容端点（根路径）：OPTIONS 预检与 GET 探活都要在 405 门之前处理。
    if (path == '/') {
      final SrsAnkiConnectEndpoint? endpoint = _ankiConnect;
      if (endpoint == null) return shelf.Response.notFound('Unknown endpoint');
      return endpoint.handle(request);
    }
    if (method != 'POST') {
      return shelf.Response(405, body: 'Method Not Allowed');
    }
    // 浏览器扩展连接探活：这些 POST 端点只有已加载的扩展（或 in-app 弹窗）会命中，
    // 命中即刷新 app 侧 last-seen（连接检测据此判断「插件已正常启用」）。
    if (_kExtensionSeenPaths.contains(path)) {
      _onExtensionSeen?.call();
    }
    final ExtensionProfileApi? profileApi = _profileApi;
    if (profileApi == null || !_kProfileScopedPaths.contains(path)) {
      return _dispatchPost(request, path, _defaultServices);
    }
    // 反馈 biLEesNqWb：解析这次请求按哪份配置处理（扩展所选 > 浏览器绑定 > 跟随 App），
    // 拿到按那份配置读设置的服务组；App 的激活配置不动。
    final int? requestedProfileId = parseExtensionProfileHeader(
      request.headers[kExtensionProfileRequestHeader],
    );
    final ExtensionProfileScope scope = await profileApi.resolveScope(
      requestedProfileId,
    );
    final shelf.Response response = await _dispatchPost(
      request,
      path,
      scope.services ?? _defaultServices,
    );
    if (requestedProfileId == null) return response;
    final int? missing = scope.missingRequestedProfileId;
    return response.change(
      headers: <String, String>{
        kExtensionProfileActiveHeader: '${scope.effectiveProfileId}',
        if (missing != null) kExtensionProfileMissingHeader: '$missing',
      },
    );
  }

  /// 构造时注入的那一组服务（App 当前生效设置）：不带配置、或解析出的就是激活配置时用。
  late final ExtensionRequestServices _defaultServices =
      ExtensionRequestServices(
        lookup: _lookup,
        mining: _mining,
        themeColorsProvider: _themeColorsProvider,
        audioSourcesProvider: _audioSourcesProvider,
        autoReadOnLookupProvider: _autoReadOnLookupProvider,
        dictionaryUnifiedStyleProvider: _dictionaryUnifiedStyleProvider,
        popupDictionaryCssProvider: _popupDictionaryCssProvider,
        srsApiProvider: _srsApiProvider,
      );

  /// [services] 对应的查词 / 制卡路由：默认组复用 [_lookupRoutes]，按配置的组现建一个
  /// （只是几个引用的薄壳，单词音频 token 仓库仍是同一个）。
  RemoteLookupRoutes _routesFor(ExtensionRequestServices services) =>
      identical(services, _defaultServices)
      ? _lookupRoutes
      : RemoteLookupRoutes(
          audioTokens: _audioTokens,
          lookup: services.lookup,
          mining: services.mining,
        );

  /// 反馈 biLEesNqWb：`/api/extension/profiles` → `{profiles:[{id,name}], activeProfileId}`。
  Future<shelf.Response> _handleExtensionProfiles() async {
    final ExtensionProfileApi? api = _profileApi;
    if (api == null) return shelf.Response.notFound('Unknown endpoint');
    final ExtensionProfileList list = await api.listProfiles();
    return jsonResponse(list.toJson());
  }

  /// POST 端点的路由表（405 门与探活 / 配置前置步骤之后）。[services] 是这次请求按配置
  /// 解析出的服务组（只有 [_kProfileScopedPaths] 用得到）。
  Future<shelf.Response> _dispatchPost(
    shelf.Request request,
    String path,
    ExtensionRequestServices services,
  ) async {
    if (FushiExtensionApiCore.paths.contains(path)) {
      return _handleExtensionApiCore(request, path);
    }
    switch (path) {
      case '/serverVersion':
        return jsonResponse(<String, dynamic>{'version': 1});
      case '/yomitanVersion':
        return jsonResponse(<String, dynamic>{'version': '0.0.0.0'});
      case '/termEntries':
        return _handleTermEntries(request, services.lookup);
      case '/tokenize':
        return _handleTokenize(request);
      case '/api/lookup/dictionary':
        return _handleDictionaryLookup(request, services);
      case '/api/lookup/audio':
        return _routesFor(services).handleAudioLookup(request);
      case '/api/lookup/audio/list':
        return _routesFor(services).handleAudioList(request);
      case '/api/mine':
        return _routesFor(services).handleMine(request);
      case '/api/mine/forward':
        return _lookupRoutes.handleMineForward(request);
      case '/api/anki/note-type/read':
      case '/api/anki/note-type/styling':
      case '/api/anki/note-type/templates':
        return _lookupRoutes.handleAnkiNoteType(request, path);
      case '/api/duplicate':
        return _routesFor(services).handleDuplicate(request);
      // Issue #1409：弹窗 ↗「在 Anki 中打开」（与 app 内 openInAnki 桥同一 repo 方法）。
      case '/api/anki/open':
        return _routesFor(services).handleOpenInAnki(request);
      case '/api/extension/favorite':
        return _handleExtensionFavorite(request);
      case '/api/srs/term-status':
        return _handleSrsTermStatus(request, services.srsApiProvider);
      case '/api/srs/term-status-batch':
        return _handleSrsTermStatusBatch(request, services.srsApiProvider);
      case '/api/srs/open':
        return _handleSrsOpen(request, services.srsApiProvider);
      case '/api/extension/status':
        return _handleExtensionStatus(request);
      case '/api/extension/site-cookies':
        return _handleSiteCookies(request);
      case '/api/extension/fonts/download':
        return _handleExtensionFontDownload(request);
      case kExtensionProfilesPath:
        return _handleExtensionProfiles();
      default:
        return shelf.Response.notFound('Unknown endpoint');
    }
  }

  /// [FushiExtensionApiCore.paths] 的 HTTP 外壳：未注入 404 优先 → 读 JSON body（非法
  /// 400 'Invalid JSON'；字体列表不读 body）→ 交核心 → 成功 JSON / 失败纯文本。
  Future<shelf.Response> _handleExtensionApiCore(
    shelf.Request request,
    String path,
  ) async {
    final FushiExtensionApiResponse? unavailable = _extensionApi
        .unavailableResponse(path);
    if (unavailable != null) return _extensionApiShelfResponse(unavailable);
    final Map<String, dynamic> body;
    if (path == FushiExtensionApiCore.fontsPath) {
      body = const <String, dynamic>{};
    } else {
      final Map<String, dynamic>? parsed = await readJsonObjectBody(request);
      if (parsed == null) return shelf.Response(400, body: 'Invalid JSON');
      body = parsed;
    }
    return _extensionApiShelfResponse(await _extensionApi.handle(path, body));
  }

  static shelf.Response _extensionApiShelfResponse(
    FushiExtensionApiResponse response,
  ) {
    final Map<String, dynamic>? json = response.json;
    if (response.ok && json != null) return jsonResponse(json);
    return shelf.Response(response.status, body: response.text);
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
    final String? locale = _appLocaleProvider?.call();
    // BUG-2480：app 正在等某站会话时随探活回包带出去，扩展据此决定要不要
    // `chrome.cookies.getAll` 后回传 `/api/extension/site-cookies`。
    final BrowserCookieImportRequest? cookieImport =
        BrowserCookieImportGate.pending;
    return jsonResponse(<String, dynamic>{
      'app': 'fushi',
      'ready': true,
      'port': port,
      if (extensionBuild != null) 'extensionBuild': extensionBuild,
      if (locale != null) 'locale': locale,
      if (cookieImport != null) 'cookieImport': cookieImport.toJson(),
    });
  }

  /// GET/HEAD `?id=<font_id>`：按**目录 id** 回字体字节（不接受任意路径）。
  /// `Access-Control-Allow-Origin: *`：网页里 `@font-face` 跨源加载必需。
  ///
  /// [dictionary] = 查词弹窗词典字体（`/api/extension/fonts/dictionary?path=`）：
  /// 按 `path` 经 [ExtensionFontApi.findDictionaryFont] 的白名单解析。
  Future<shelf.Response> _handleExtensionFontFile(
    shelf.Request request, {
    required bool headOnly,
    bool dictionary = false,
  }) async {
    final ExtensionFontApi? api = _fontApi;
    if (api == null) return shelf.Response.notFound('Not Found');
    final String key = dictionary ? 'path' : 'id';
    final String? id = request.url.queryParameters[key];
    if (id == null || id.isEmpty) return shelf.Response.notFound('Not found');
    final ExtensionFontEntry? font = dictionary
        ? await api.findDictionaryFont(id)
        : await api.findFont(id);
    if (font == null) return shelf.Response.notFound('Not found');
    final File file = File(font.path);
    if (!await file.exists()) return shelf.Response.notFound('Not found');
    final int length = await file.length();
    return shelf.Response.ok(
      headOnly ? null : file.openRead(),
      headers: <String, String>{
        'Content-Type': ExtensionFontEntry.contentTypeForExt(font.ext),
        'Content-Length': '$length',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'private, max-age=86400',
      },
    );
  }

  /// body `{name}`：下载推荐表里的字体进 app 字体目录（已装则直接回已有条目）。
  /// 404 `unknown_font` / 502 `download_failed`。
  Future<shelf.Response> _handleExtensionFontDownload(
    shelf.Request request,
  ) async {
    final ExtensionFontApi? api = _fontApi;
    if (api == null) return shelf.Response.notFound('Not Found');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? name = body['name'];
    if (name is! String || name.isEmpty) {
      return shelf.Response(400, body: 'Missing name');
    }
    final ExtensionFontDownloadOutcome outcome = await api.downloadRecommended(
      name,
    );
    switch (outcome.status) {
      case ExtensionFontDownloadStatus.ok:
        return jsonResponse(<String, dynamic>{
          'ok': true,
          'fonts': <Map<String, dynamic>>[
            for (final ExtensionFontEntry font in outcome.fonts) font.toJson(),
          ],
        });
      case ExtensionFontDownloadStatus.unknownFont:
        return _jsonError(404, <String, dynamic>{
          'ok': false,
          'error': 'unknown_font',
        });
      case ExtensionFontDownloadStatus.downloadFailed:
        return _jsonError(502, <String, dynamic>{
          'ok': false,
          'error': 'download_failed',
          'detail': outcome.detail ?? '',
        });
    }
  }

  static shelf.Response _jsonError(int status, Map<String, dynamic> body) =>
      shelf.Response(
        status,
        body: jsonEncode(body),
        headers: <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
        },
      );

  /// BUG-2480：扩展回传站点 cookie。nonce 必须与当前登记一致（409），否则任何
  /// 拿到本地端口的进程都能往源站 jar 里塞会话。
  Future<shelf.Response> _handleSiteCookies(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? nonce = body['nonce'];
    final Object? host = body['host'];
    final Object? raw = body['cookies'];
    if (nonce is! String || host is! String || raw is! List) {
      return shelf.Response(400, body: 'Missing nonce/host/cookies');
    }
    final List<BrowserSiteCookie> cookies = raw
        .map(BrowserSiteCookie.fromJson)
        .whereType<BrowserSiteCookie>()
        .toList(growable: false);
    final bool accepted = BrowserCookieImportGate.deliver(
      nonce: nonce,
      host: host,
      cookies: cookies,
    );
    if (!accepted) return shelf.Response(409, body: 'No matching request');
    return jsonResponse(<String, dynamic>{'ok': true, 'count': cookies.length});
  }

  /// BUG-530：浏览器扩展查词端点（与 FushiSyncServer 共享契约）。
  Future<shelf.Response> _handleDictionaryLookup(
    shelf.Request request,
    ExtensionRequestServices services,
  ) async {
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
          lookup: services.lookup,
          history: _history,
          popupTiming: popupTiming,
          themeColorsProvider: services.themeColorsProvider,
          audioSourcesProvider: services.audioSourcesProvider,
          autoReadOnLookupProvider: services.autoReadOnLookupProvider,
          dictionaryUnifiedStyleProvider:
              services.dictionaryUnifiedStyleProvider,
          extensionBuildProvider: _extensionBuildProvider,
          popupDictionaryCssProvider: services.popupDictionaryCssProvider,
          appLocaleProvider: _appLocaleProvider,
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
    final String? traceId =
        rawTraceId is String &&
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
  // /api/anki/open、/api/lookup/audio[/file] 的 handler 正文在 [RemoteLookupRoutes]（与
  // FushiSyncServer 共用）；扩展默认指向本 server（19633），故那是真正被命中的路径。

  /// BUG-3141：扩展查词弹窗的 ☆/★（POST `/api/extension/favorite`）。body
  /// `{toggle, expression, reading, glossary?, sentence?}`：`toggle` 为 true 切换收藏并回
  /// **切换后**的状态，false 只读当前状态（popup.js 的 favoriteEntry / favoriteCheck）。
  /// 与查词同一 [_authMiddleware] 鉴权——这是写收藏夹 / 学习统计的入口，绝不无鉴权开放。
  /// 词形为空 400；未注入 handler 404；成功 `{favorite: bool}`。
  Future<shelf.Response> _handleExtensionFavorite(shelf.Request request) async {
    final ExtensionFavoriteHandler? handler = _onExtensionFavorite;
    if (handler == null) return shelf.Response.notFound('Favorite sink off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final ExtensionFavoriteRequest? favorite =
        ExtensionFavoriteRequest.tryParse(body);
    if (favorite == null) {
      return shelf.Response(400, body: 'Missing expression');
    }
    final bool state = await handler(favorite);
    return jsonResponse(<String, dynamic>{'favorite': state});
  }

  /// 复习词状态（扩展弹窗的复习标记）：body `{expression, reading}` → `{status: null | {...}}`。
  /// 复习模块关着时 404（扩展 shim 据此退避，不再每次查词都问）。
  Future<shelf.Response> _handleSrsTermStatus(
    shelf.Request request,
    SrsExtensionApi? Function()? srsApiProvider,
  ) async {
    final SrsExtensionApi? api = srsApiProvider?.call();
    if (api == null) return shelf.Response.notFound('SRS module off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? expression = body['expression'];
    final Object? reading = body['reading'];
    if (expression is! String || expression.trim().isEmpty) {
      return shelf.Response(400, body: 'Missing expression');
    }
    final Map<String, Object?>? status = await api.termStatus(
      expression,
      reading is String ? reading : '',
    );
    return jsonResponse(<String, dynamic>{'status': status});
  }

  /// 批量复习词状态（扩展弹窗一轮可见批次一次）：body `{terms: [{expression, reading}, …]}`
  /// → `{statuses: [null | {...}, …]}`（等长同序）。复习模块关着时 404（与单条端点同文案，
  /// 扩展照样退避）；超过 [kSrsTermStatusBatchMax] 个词 400。老 app 没有本端点时扩展收到
  /// 非 200 → 退回逐条 `/api/srs/term-status`。
  Future<shelf.Response> _handleSrsTermStatusBatch(
    shelf.Request request,
    SrsExtensionApi? Function()? srsApiProvider,
  ) async {
    final SrsExtensionApi? api = srsApiProvider?.call();
    if (api == null) return shelf.Response.notFound('SRS module off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? raw = body['terms'];
    if (raw is! List || raw.length > kSrsTermStatusBatchMax) {
      return shelf.Response(400, body: 'Invalid terms');
    }
    final List<SrsTermQuery> terms = <SrsTermQuery>[];
    for (final Object? item in raw) {
      if (item is! Map) return shelf.Response(400, body: 'Invalid terms');
      final Object? expression = item['expression'];
      final Object? reading = item['reading'];
      terms.add(
        SrsTermQuery(
          expression is String ? expression : '',
          reading is String && reading.trim().isNotEmpty ? reading : null,
        ),
      );
    }
    return jsonResponse(<String, dynamic>{
      'statuses': await api.termStatuses(terms),
    });
  }

  /// 扩展里点复习标记：body `{cardId, noteId?}` → `{opened: bool}`。模块关着时 404。
  Future<shelf.Response> _handleSrsOpen(
    shelf.Request request,
    SrsExtensionApi? Function()? srsApiProvider,
  ) async {
    final SrsExtensionApi? api = srsApiProvider?.call();
    if (api == null) return shelf.Response.notFound('SRS module off');
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    if (body == null) return shelf.Response(400, body: 'Invalid JSON');
    final Object? cardId = body['cardId'];
    final Object? noteId = body['noteId'];
    if (cardId is! String || cardId.isEmpty) {
      return shelf.Response(400, body: 'Missing cardId');
    }
    final bool opened = await api.openCard(
      cardId: cardId,
      noteId: noteId is String && noteId.isNotEmpty ? noteId : null,
    );
    return jsonResponse(<String, dynamic>{'opened': opened});
  }

  Future<shelf.Response> _handleTermEntries(
    shelf.Request request,
    FushiRemoteLookupService lookup,
  ) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final dynamic term = body?['term'];
    if (term is List) {
      final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
      for (int i = 0; i < term.length; i++) {
        out.add(await _termEntriesFor(lookup, term[i]?.toString() ?? '', i));
      }
      return jsonRawResponse(jsonEncode(out));
    }
    return jsonResponse(
      await _termEntriesFor(lookup, term?.toString() ?? '', 0),
    );
  }

  Future<Map<String, dynamic>> _termEntriesFor(
    FushiRemoteLookupService lookup,
    String term,
    int index,
  ) async {
    if (term.trim().isEmpty) {
      return buildYomitanTermEntriesResponse(null, index);
    }
    final DictionarySearchResult? result = await lookup.searchDictionary(
      term: term,
      wildcards: false,
      maximumTerms: 10,
    );
    return buildYomitanTermEntriesResponse(result, index);
  }

  Future<shelf.Response> _handleTokenize(shelf.Request request) async {
    final Map<String, dynamic>? body = await readJsonObjectBody(request);
    final dynamic text = body?['text'];
    final List<String> texts = text is List
        ? <String>[for (final dynamic t in text) t?.toString() ?? '']
        : <String>[text?.toString() ?? ''];
    // 整批一次交给分词器（后台 isolate 里切完，HBK-AUDIT-009），不在本 isolate 上逐条
    // 同步切。
    final List<List<TokenizedSegment>> tokenized = await _tokenizer(texts);
    if (tokenized.length != texts.length) {
      throw StateError(
        'tokenizer returned ${tokenized.length} results for ${texts.length} texts',
      );
    }
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[
      for (int i = 0; i < texts.length; i++)
        buildYomitanTokenizeResponse(
          text: texts[i],
          index: i,
          segments: tokenized[i],
        ),
    ];
    if (text is List) return jsonRawResponse(jsonEncode(out));
    return jsonResponse(out.single);
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
