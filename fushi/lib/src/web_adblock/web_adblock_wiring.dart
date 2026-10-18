import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

/// WebView 接线读的拦截策略（app 侧是 `WebAdblockService`，测试注入假实现）。
///
/// 每次请求 / 每次 JS 回调都**现读**：引擎晚于 WebView 就绪、用户中途关开关、改白名单，
/// 已开着的页面下一次请求就生效（contentBlockers 例外：它在 WebView 创建时固化）。
abstract interface class WebAdblockPolicy {
  /// 总开关开着且引擎已就绪。
  bool get isActive;

  /// 当前引擎；未就绪 / 不可用为 null。
  AdblockMatcher? get matcher;

  /// [pageUrl] 所在站点是否在用户白名单里（白名单站点完全不拦）。
  bool isAllowlisted(Uri? pageUrl);

  /// 给不能逐请求拦截的平台的 WebKit 内容拦截规则（原始 JSON 形态）；没有就空。
  List<Map<String, Object?>> get contentBlockingRules;
}

/// 交给 `contentBlockers` 的规则条数上限。真实默认四份列表导出约 16.7 万条
/// （2026-10 实测），超过 WKContentRuleList 的单表上限（iOS 15+ 15 万、更早 5 万），
/// 编译也慢；取 5 万保守值。截断时**只丢拦截规则、保留全部例外规则**（少拦，不误拦）。
const int kWebAdblockMaxContentBlockers = 50000;

/// 页面被拦截的子资源的应答。
final WebResourceResponse _blockedResponse = WebResourceResponse(
  contentType: 'text/plain',
  contentEncoding: 'utf-8',
  data: Uint8List(0),
  statusCode: 403,
  reasonPhrase: 'Blocked by Fushi',
);

/// documentStart 注入的 cosmetic 引导脚本：向 Dart 取本页的隐藏选择器 / scriptlet，
/// 再用 MutationObserver 收集页面上出现的 class / id，分批取通用（generic）隐藏选择器。
/// 选择器逐条 `insertRule`：一条非法选择器只丢它自己，不连坐整张样式表。
const String kWebAdblockCosmeticScript = r'''
(function () {
  if (window.__fushiAdblockInstalled) return;
  window.__fushiAdblockInstalled = true;
  var STYLE_ID = 'fushi-web-core-style';
  var seen = Object.create(null);
  var href = location.href;
  function root() { return document.head || document.documentElement; }
  function appendCss(selectors) {
    if (!selectors || !selectors.length) return;
    var style = document.getElementById(STYLE_ID);
    if (!style) {
      var r = root();
      if (!r) return;
      style = document.createElement('style');
      style.id = STYLE_ID;
      r.appendChild(style);
    }
    for (var i = 0; i < selectors.length; i++) {
      var s = selectors[i];
      if (typeof s !== 'string' || !s || seen[s]) continue;
      seen[s] = 1;
      var rule = s + '{display:none!important}';
      var sheet = style.sheet;
      if (sheet) {
        try { sheet.insertRule(rule, sheet.cssRules.length); } catch (e) {}
      } else {
        style.appendChild(document.createTextNode(rule + '\n'));
      }
    }
  }
  function call(name, arg) {
    var b = window.flutter_inappwebview;
    if (b && b.callHandler) return b.callHandler(name, arg);
    return new Promise(function (resolve) {
      window.addEventListener('flutterInAppWebViewPlatformReady', function () {
        resolve(window.flutter_inappwebview.callHandler(name, arg));
      }, { once: true });
    });
  }
  function startGeneric() {
    var seenClass = Object.create(null);
    var seenId = Object.create(null);
    var classes = [];
    var ids = [];
    var timer = 0;
    function collect(el) {
      if (!el || el.nodeType !== 1) return;
      var id = el.id;
      if (id && typeof id === 'string' && !seenId[id]) { seenId[id] = 1; ids.push(id); }
      var cl = el.classList;
      if (!cl) return;
      for (var i = 0; i < cl.length; i++) {
        var c = cl[i];
        if (!seenClass[c]) { seenClass[c] = 1; classes.push(c); }
      }
    }
    function scan(node) {
      collect(node);
      if (node && node.querySelectorAll) {
        var all = node.querySelectorAll('[id],[class]');
        for (var i = 0; i < all.length; i++) collect(all[i]);
      }
    }
    function flush() {
      timer = 0;
      if (!classes.length && !ids.length) return;
      var payload = { href: href, classes: classes.splice(0), ids: ids.splice(0) };
      call('fushiAdblockGeneric', payload).then(appendCss, function () {});
    }
    function schedule() { if (!timer) timer = setTimeout(flush, 120); }
    function start() {
      var de = document.documentElement;
      if (!de) return;
      scan(de);
      schedule();
      new MutationObserver(function (muts) {
        for (var i = 0; i < muts.length; i++) {
          var m = muts[i];
          if (m.type === 'attributes') { collect(m.target); continue; }
          for (var j = 0; j < m.addedNodes.length; j++) scan(m.addedNodes[j]);
        }
        schedule();
      }).observe(de, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id'] });
    }
    if (document.documentElement) start();
    else document.addEventListener('readystatechange', start, { once: true });
  }
  call('fushiAdblockCosmetic', href).then(function (r) {
    if (!r) return;
    appendCss(r.hideSelectors);
    if (r.injectedScript) {
      try {
        var sc = document.createElement('script');
        sc.textContent = r.injectedScript;
        root().appendChild(sc);
        sc.remove();
      } catch (e) {}
    }
    if (!r.generichide) startGeneric();
  }, function () {});
})();
''';

/// JS → Dart 的 handler 名（与 [kWebAdblockCosmeticScript] 一致）。
const String kWebAdblockCosmeticHandler = 'fushiAdblockCosmetic';
const String kWebAdblockGenericHandler = 'fushiAdblockGeneric';

/// UserScript 分组名：调用方要整体移除时用 `removeUserScriptsByGroupName`。
const String kWebAdblockUserScriptGroup = 'fushi_web_core';

/// 原始 `shouldInterceptRequest` 回调签名（与 InAppWebView 的参数同型）。
typedef WebAdblockInterceptCallback =
    Future<WebResourceResponse?> Function(
      InAppWebViewController controller,
      WebResourceRequest request,
    );

/// [applyAdblockTo] 的产物：调用方把各字段原样接到自己的 `InAppWebView` 上。
///
/// ```dart
/// final WebAdblockWiring adblock = applyAdblockTo(
///   InAppWebViewSettings(javaScriptEnabled: true),
///   policy: ref.read(webAdblockServiceProvider),
///   shouldInterceptRequest: myExistingInterceptor, // 可选：本页已有的拦截器先跑
/// );
/// InAppWebView(
///   initialSettings: adblock.settings,
///   initialUserScripts: UnmodifiableListView(<UserScript>[...mine, ...adblock.userScripts]),
///   shouldInterceptRequest: adblock.shouldInterceptRequest,
///   onWebViewCreated: (c) { adblock.onWebViewCreated(c); ... },
///   onLoadStart: (c, url) { adblock.onLoadStart(url); ... },
/// );
/// ```
class WebAdblockWiring {
  WebAdblockWiring._({
    required this.mode,
    required this.settings,
    required this.userScripts,
    required WebAdblockPolicy policy,
    required WebAdblockInterceptCallback? existing,
  }) : _policy = policy,
       _existing = existing;

  /// 本平台用的网络层拦截方式。
  final WebAdblockNetworkMode mode;

  /// 已按 [mode] 改好的设置副本（原对象不动）。
  final InAppWebViewSettings settings;

  /// cosmetic 引导脚本（documentStart，含 iframe）。
  final List<UserScript> userScripts;

  final WebAdblockPolicy _policy;
  final WebAdblockInterceptCallback? _existing;
  Uri? _pageUrl;
  int _blockedCount = 0;

  /// 每个 href 最近一次 cosmetic 结果的例外集（generic 选择器要扣掉它们）。
  final Map<String, List<String>> _exceptionsByHref = <String, List<String>>{};

  /// 本 WebView 累计拦下的请求数（给 UI 角标 / 调试用）。
  int get blockedCount => _blockedCount;

  /// 当前顶层页面 URL（[onLoadStart] / [onUpdateVisitedHistory] 维护）。
  Uri? get pageUrl => _pageUrl;

  /// 接到 `InAppWebView.shouldInterceptRequest`。逐请求平台上：先跑调用方原有的拦截器
  /// （返回非 null 就用它的，例如本仓 `fushi.local` 虚拟域名），再过 adblock 引擎；
  /// 其它平台上只转发原有拦截器（为 null 时整个回调也是 null，不打开逐请求开关）。
  WebAdblockInterceptCallback? get shouldInterceptRequest {
    if (mode != WebAdblockNetworkMode.perRequest) return _existing;
    return _intercept;
  }

  Future<WebResourceResponse?> _intercept(
    InAppWebViewController controller,
    WebResourceRequest request,
  ) async {
    final WebAdblockInterceptCallback? existing = _existing;
    if (existing != null) {
      final WebResourceResponse? own = await existing(controller, request);
      if (own != null) return own;
    }
    return interceptForAdblock(request);
  }

  /// 纯判定部分（不依赖 controller，便于测试）：该拦返回替身 / 空应答，否则 null。
  WebResourceResponse? interceptForAdblock(WebResourceRequest request) {
    if (!_policy.isActive) return null;
    final AdblockMatcher? matcher = _policy.matcher;
    if (matcher == null) return null;
    // 顶层导航不拦：拦了只会得到一张白页，ABP 语义里 document 也默认放行。
    if (request.isForMainFrame ?? false) return null;
    final String url = request.url.toString();
    if (!url.startsWith('http://') &&
        !url.startsWith('https://') &&
        !url.startsWith('ws://') &&
        !url.startsWith('wss://')) {
      return null;
    }
    if (_policy.isAllowlisted(_pageUrl)) return null;
    final String? source = _sourceUrlFor(request);
    final AdblockRequestType type = inferAdblockRequestType(request);
    final AdblockDecision decision = matcher.check(
      url,
      sourceUrl: source,
      type: type,
    );
    if (!decision.shouldBlock) return null;
    _blockedCount++;
    if (decision == AdblockDecision.redirect) {
      final AdblockCheckResult detail = matcher.checkDetailed(
        url,
        sourceUrl: source,
        type: type,
      );
      final WebResourceResponse? replacement = _responseFromDataUrl(
        detail.redirect,
      );
      if (replacement != null) return replacement;
    }
    return _blockedResponse;
  }

  String? _sourceUrlFor(WebResourceRequest request) {
    final Map<String, String>? headers = request.headers;
    if (headers != null) {
      for (final MapEntry<String, String> e in headers.entries) {
        if (e.key.toLowerCase() == 'referer' && e.value.isNotEmpty) {
          return e.value;
        }
      }
    }
    return _pageUrl?.toString();
  }

  /// 接到 `onWebViewCreated`：注册 cosmetic 两个 JS handler。
  void onWebViewCreated(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: kWebAdblockCosmeticHandler,
      callback: (List<dynamic> args) =>
          cosmeticFor(args.isEmpty ? null : args.first),
    );
    controller.addJavaScriptHandler(
      handlerName: kWebAdblockGenericHandler,
      callback: (List<dynamic> args) =>
          genericSelectorsFor(args.isEmpty ? null : args.first),
    );
  }

  /// 接到 `onLoadStart`：记下顶层页面 URL（第三方判定的兜底来源 + 白名单判定）。
  void onLoadStart(WebUri? url) {
    if (url != null) _pageUrl = Uri.tryParse(url.toString());
  }

  /// 接到 `onUpdateVisitedHistory`（SPA 改 URL 不触发 onLoadStart）。
  void onUpdateVisitedHistory(WebUri? url) => onLoadStart(url);

  /// `fushiAdblockCosmetic` handler 的实现：`href` → `{hideSelectors, injectedScript,
  /// generichide}`；未激活 / 白名单返回 null（JS 侧什么也不做）。
  Map<String, Object?>? cosmeticFor(Object? hrefArg) {
    if (!_policy.isActive || hrefArg is! String) return null;
    final AdblockMatcher? matcher = _policy.matcher;
    if (matcher == null) return null;
    if (_policy.isAllowlisted(_pageUrl ?? Uri.tryParse(hrefArg))) return null;
    final AdblockCosmeticResources res = matcher.cosmetic(hrefArg);
    _rememberExceptions(hrefArg, res.exceptions);
    return <String, Object?>{
      'hideSelectors': res.hideSelectors,
      'injectedScript': res.injectedScript,
      'generichide': res.generichide,
    };
  }

  /// `fushiAdblockGeneric` handler 的实现：`{href, classes, ids}` → 选择器数组。
  List<String> genericSelectorsFor(Object? payload) {
    if (!_policy.isActive || payload is! Map) return const <String>[];
    final AdblockMatcher? matcher = _policy.matcher;
    if (matcher == null) return const <String>[];
    final Object? href = payload['href'];
    if (_policy.isAllowlisted(
      _pageUrl ?? (href is String ? Uri.tryParse(href) : null),
    )) {
      return const <String>[];
    }
    List<String> strings(Object? v) =>
        v is List ? v.whereType<String>().toList() : const <String>[];
    final List<String> exceptions = href is String
        ? (_exceptionsByHref[href] ??
              _rememberExceptions(href, matcher.cosmetic(href).exceptions))
        : const <String>[];
    return matcher.genericSelectors(
      classes: strings(payload['classes']),
      ids: strings(payload['ids']),
      exceptions: exceptions,
    );
  }

  List<String> _rememberExceptions(String href, List<String> exceptions) {
    if (_exceptionsByHref.length >= 16) {
      _exceptionsByHref.remove(_exceptionsByHref.keys.first);
    }
    return _exceptionsByHref[href] = exceptions;
  }
}

/// 把 adblock 拦截接到一份 [settings] 上（返回副本，不改原对象）。
///
/// - 逐请求平台（Android / Windows）：打开 `useShouldInterceptRequest`，请求走引擎判定；
/// - contentBlockers 平台（iOS / macOS）：把 [WebAdblockPolicy.contentBlockingRules]
///   转成 `ContentBlocker` 追加到 `contentBlockers`（**WebView 创建时固化**：引擎晚到时这类
///   平台要等下次创建 WebView 才有网络层拦截）；
/// - Linux 网络层不拦（见 `webAdblockNetworkModeFor` 的说明），只做 cosmetic；
/// - 五端都加 cosmetic 引导 UserScript（记得把 [WebAdblockWiring.onWebViewCreated] 接上，
///   否则脚本拿不到选择器）。
///
/// 总开关关着时照样返回一份可用的 wiring（回调现读策略，用户中途打开即生效），只是
/// 不改设置、不加 contentBlockers。[mode] 只给测试覆盖平台判定。
WebAdblockWiring applyAdblockTo(
  InAppWebViewSettings settings, {
  required WebAdblockPolicy policy,
  WebAdblockInterceptCallback? shouldInterceptRequest,
  WebAdblockNetworkMode? mode,
  int maxContentBlockers = kWebAdblockMaxContentBlockers,
}) {
  final WebAdblockNetworkMode resolved = mode ?? currentWebAdblockNetworkMode;
  final InAppWebViewSettings out = settings.copy();
  switch (resolved) {
    case WebAdblockNetworkMode.perRequest:
      out.useShouldInterceptRequest = true;
    case WebAdblockNetworkMode.contentBlockers:
      if (policy.isActive) {
        out.contentBlockers = <ContentBlocker>[
          ...?out.contentBlockers,
          ...contentBlockersFromRules(
            policy.contentBlockingRules,
            maxRules: maxContentBlockers,
          ),
        ];
      }
    case WebAdblockNetworkMode.cosmeticOnly:
      break;
  }
  return WebAdblockWiring._(
    mode: resolved,
    settings: out,
    userScripts: <UserScript>[
      UserScript(
        groupName: kWebAdblockUserScriptGroup,
        source: kWebAdblockCosmeticScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ),
    ],
    policy: policy,
    existing: shouldInterceptRequest,
  );
}

/// adblock-rust 导出的 WebKit 规则 → InAppWebView 的 [ContentBlocker]。
///
/// - 只保留 `block` 与 `ignore-previous-rules`：cosmetic 隐藏五端统一走 UserScript，
///   `css-display-none` 再进规则表只是重复占名额；`block-cookies` / `make-https` 不属于广告拦截。
/// - `resource-type` 里插件枚举不认识的值（`popup` 等）丢掉；**全部**不认识的规则整条丢弃
///   ——留个空数组等于「匹配所有类型」，会把规则放大。
/// - 总数超过 [maxRules] 时只截拦截规则，例外规则全留（顺序：拦截在前、例外在后）。
List<ContentBlocker> contentBlockersFromRules(
  List<Map<String, Object?>> rules, {
  int maxRules = kWebAdblockMaxContentBlockers,
}) {
  final List<ContentBlocker> blocks = <ContentBlocker>[];
  final List<ContentBlocker> ignores = <ContentBlocker>[];
  for (final Map<String, Object?> rule in rules) {
    final ContentBlocker? blocker = _toContentBlocker(rule);
    if (blocker == null) continue;
    if (blocker.action.type == ContentBlockerActionType.IGNORE_PREVIOUS_RULES) {
      ignores.add(blocker);
    } else {
      blocks.add(blocker);
    }
  }
  final int keptIgnores = ignores.length > maxRules ? maxRules : ignores.length;
  final int blockBudget = maxRules - keptIgnores;
  return <ContentBlocker>[
    ...blocks.take(blockBudget < 0 ? 0 : blockBudget),
    ...ignores.take(keptIgnores),
  ];
}

ContentBlocker? _toContentBlocker(Map<String, Object?> rule) {
  final Object? action = rule['action'];
  final Object? trigger = rule['trigger'];
  if (action is! Map || trigger is! Map) return null;
  final Object? type = action['type'];
  // 动作类型直接取静态常量，不走 `fromNativeValue`：插件的枚举按 defaultTargetPlatform
  // 生成原生值，`values` 集合里只要有一个当前平台不支持的成员（Android 上的
  // BLOCK_COOKIES 等）初始化就抛 TypeError，`fromNativeValue` 会把它吞成 null。
  final ContentBlockerActionType actionType;
  if (type == 'block') {
    actionType = ContentBlockerActionType.BLOCK;
  } else if (type == 'ignore-previous-rules') {
    actionType = ContentBlockerActionType.IGNORE_PREVIOUS_RULES;
  } else {
    return null;
  }
  final Object? urlFilter = trigger['url-filter'];
  if (urlFilter is! String || urlFilter.isEmpty) return null;

  List<String> strings(Object? v) =>
      v is List ? v.whereType<String>().toList() : const <String>[];

  final List<ContentBlockerTriggerResourceType> resourceTypes =
      <ContentBlockerTriggerResourceType>[];
  final List<String> rawTypes = strings(trigger['resource-type']);
  for (final String v in rawTypes) {
    final ContentBlockerTriggerResourceType? rt = _resourceTypes[v];
    if (rt != null) resourceTypes.add(rt);
  }
  if (rawTypes.isNotEmpty && resourceTypes.isEmpty) return null;

  final List<ContentBlockerTriggerLoadType> loadTypes =
      <ContentBlockerTriggerLoadType>[
        for (final String v in strings(trigger['load-type']))
          if (v == 'first-party')
            ContentBlockerTriggerLoadType.FIRST_PARTY
          else if (v == 'third-party')
            ContentBlockerTriggerLoadType.THIRD_PARTY,
      ];
  final List<String> ifDomain = strings(trigger['if-domain']);
  final List<String> unlessDomain = strings(trigger['unless-domain']);
  final List<String> ifTopUrl = strings(trigger['if-top-url']);
  final List<String> unlessTopUrl = strings(trigger['unless-top-url']);
  // WebKit 规定 if-* / unless-* 互斥；导出端本不会同时给，防御一下免得触发插件断言。
  if ((ifDomain.isNotEmpty && unlessDomain.isNotEmpty) ||
      (ifTopUrl.isNotEmpty && unlessTopUrl.isNotEmpty)) {
    return null;
  }
  return ContentBlocker(
    trigger: ContentBlockerTrigger(
      urlFilter: urlFilter,
      urlFilterIsCaseSensitive: trigger['url-filter-is-case-sensitive'] == true,
      resourceType: resourceTypes,
      loadType: loadTypes,
      ifDomain: ifDomain,
      unlessDomain: unlessDomain,
      ifTopUrl: ifTopUrl,
      unlessTopUrl: unlessTopUrl,
    ),
    action: ContentBlockerAction(type: actionType),
  );
}

/// WebKit `resource-type` 值 → 插件枚举（这些是平台无关的 const）。`popup` 等插件不认识的值不在表里。
const Map<String, ContentBlockerTriggerResourceType> _resourceTypes =
    <String, ContentBlockerTriggerResourceType>{
      'document': ContentBlockerTriggerResourceType.DOCUMENT,
      'image': ContentBlockerTriggerResourceType.IMAGE,
      'style-sheet': ContentBlockerTriggerResourceType.STYLE_SHEET,
      'script': ContentBlockerTriggerResourceType.SCRIPT,
      'font': ContentBlockerTriggerResourceType.FONT,
      'raw': ContentBlockerTriggerResourceType.RAW,
      'svg-document': ContentBlockerTriggerResourceType.SVG_DOCUMENT,
      'media': ContentBlockerTriggerResourceType.MEDIA,
    };

/// 从请求推断 adblock 资源类型：优先 `Sec-Fetch-Dest`（Chromium / WebView2 会带），
/// 其次 `Accept`，最后看扩展名。推断不出就是 `other`（`$script` 之类带类型的规则不命中，
/// 不带类型的照常命中——宁可少拦，不误拦）。
AdblockRequestType inferAdblockRequestType(WebResourceRequest request) {
  if (request.isForMainFrame ?? false) return AdblockRequestType.document;
  String? dest;
  String? accept;
  final Map<String, String>? headers = request.headers;
  if (headers != null) {
    for (final MapEntry<String, String> e in headers.entries) {
      final String k = e.key.toLowerCase();
      if (k == 'sec-fetch-dest') dest = e.value.toLowerCase();
      if (k == 'accept') accept = e.value.toLowerCase();
    }
  }
  switch (dest) {
    case 'script':
    case 'worker':
    case 'sharedworker':
    case 'serviceworker':
      return AdblockRequestType.script;
    case 'style':
      return AdblockRequestType.stylesheet;
    case 'image':
      return AdblockRequestType.image;
    case 'font':
      return AdblockRequestType.font;
    case 'iframe':
    case 'frame':
    case 'embed':
    case 'object':
      return AdblockRequestType.subdocument;
    case 'audio':
    case 'video':
    case 'track':
      return AdblockRequestType.media;
    case 'empty':
      return AdblockRequestType.xmlhttprequest;
  }
  if (accept != null) {
    if (accept.startsWith('text/css')) return AdblockRequestType.stylesheet;
    if (accept.startsWith('image/')) return AdblockRequestType.image;
    if (accept.startsWith('text/html')) return AdblockRequestType.subdocument;
  }
  final String path = request.url.path.toLowerCase();
  final int dot = path.lastIndexOf('.');
  final String ext = dot >= 0 ? path.substring(dot + 1) : '';
  switch (ext) {
    case 'js':
    case 'mjs':
      return AdblockRequestType.script;
    case 'css':
      return AdblockRequestType.stylesheet;
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'svg':
    case 'ico':
    case 'avif':
    case 'bmp':
      return AdblockRequestType.image;
    case 'woff':
    case 'woff2':
    case 'ttf':
    case 'otf':
    case 'eot':
      return AdblockRequestType.font;
    case 'mp4':
    case 'webm':
    case 'm3u8':
    case 'mp3':
    case 'm4a':
    case 'aac':
    case 'ogg':
      return AdblockRequestType.media;
  }
  final String scheme = request.url.scheme;
  if (scheme == 'ws' || scheme == 'wss') return AdblockRequestType.websocket;
  return AdblockRequestType.other;
}

/// `data:<mime>;base64,<payload>` → 200 应答；解析失败返回 null（调用方退回空应答）。
WebResourceResponse? _responseFromDataUrl(String? dataUrl) {
  if (dataUrl == null || !dataUrl.startsWith('data:')) return null;
  final int comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  final String meta = dataUrl.substring(5, comma);
  final String payload = dataUrl.substring(comma + 1);
  final bool isBase64 = meta.endsWith(';base64');
  final String mime = (isBase64 ? meta.substring(0, meta.length - 7) : meta)
      .split(';')
      .first;
  try {
    final Uint8List bytes = isBase64
        ? base64Decode(payload)
        : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
    return WebResourceResponse(
      contentType: mime.isEmpty ? 'text/plain' : mime,
      contentEncoding: 'utf-8',
      data: bytes,
      statusCode: 200,
      reasonPhrase: 'OK',
    );
  } on FormatException {
    return null;
  }
}
