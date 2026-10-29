import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/sync/fushi_extension_api_core.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_bundle.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_messages.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_subtitle_panel.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_activity.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_video_remote.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';

/// 页内脚本调 Dart 的唯一 JS 处理器名（宿主运行时 `__fushiExtSend`）。
const String kWebBrowserExtensionHandler = 'fushiExt';

/// 应用内浏览器运行浏览器扩展的内容脚本栈（「扩展宿主」）。
///
/// 页内必须画在站点播放器里的 UI 与逻辑——播放器控制条里的 Fushi 按钮与菜单
/// （player-controls.js）、字幕覆盖层与样式（subtitle-panel.js / subtitle-style.js）、
/// 字幕轨与时轴偏移、查词暂停 / 续播时序（content.js）、沉浸计时（study-tracker.js）——
/// 直接复用扩展同一份脚本（[buildWebBrowserExtensionBundle]）；能力后端一律走 app 原生：
/// - `chrome.runtime.sendMessage` → [routeWebBrowserExtensionMessage] → [FushiExtensionApiCore]
///   （与本机 HTTP 服务同一份实现，进程内直接调，服务没开也能用）；
/// - `chrome.storage.local` → [WebBrowserExtensionStorage]（设备本地偏好，有真源的键桥接真源）；
/// - 查词 → content.js 的宿主适配口 → app 的查词弹窗（与页内取词同一个
///   [SrsCardLookupController]）；关窗回调 JS 续播，命中字数回调 JS 高亮；
/// - 字幕侧栏 → app 原生侧栏 [WebBrowserSubtitlePanel]（扩展 Side Panel 同一份消息契约）；
/// - 扩展设置 → [openSettings]（app 原生「浏览器设置」里的扩展分组）。
///
/// 安全：整栈在页面主世界跑，但 chrome 垫片、桥、适配口都是闭包局部的；页面唯一看得到的
/// `window.__fushiExtHost` 每个方法都先核对本会话密钥，Dart 侧同样只认带密钥的调用。
/// 注意密钥只挡「顺手调用」，不是隔离边界：插件 JS 桥的 `callHandler` 在调用时现取全局
/// `JSON.stringify` 序列化参数，页面换掉它就能读到密钥。所以开放给页内的每个 op 都要按
/// 「任意网页可伪造」来设计（无痕不落统计、存储写入串行等都以此为前提）。
class WebBrowserExtensionHostFeature extends WebBrowserFeature {
  WebBrowserExtensionHostFeature({
    required WebBrowserExtensionStorage storage,
    required Future<FushiExtensionApiResponse> Function(
      String path,
      Map<String, dynamic> body,
    )
    api,
    required this.lookup,
    required this.videoActivity,
    this.openSettings,
    WebBrowserVideoRemote Function(WebBrowserExtensionHostFeature host)?
    videoRemote,
    Future<WebBrowserExtensionBundleParts> Function()? loadParts,
    Future<String> Function(String asset)? loadAsset,
    String? secret,
  }) : _storage = storage,
       _api = api,
       _loadAsset = loadAsset,
       secret = secret ?? _newSecret() {
    // 存储的任何写入（页内脚本、设置页、别的浏览页）都推给本浏览页打开着的标签页。
    _storageChanges = storage.changes.listen(_broadcastStorage);
    _bundleLoad = (loadParts ?? loadWebBrowserExtensionBundleParts)()
        .then<String?>(
          (WebBrowserExtensionBundleParts parts) => _bundle =
              buildWebBrowserExtensionBundle(parts, secret: this.secret),
          onError: (Object e, StackTrace stack) {
            debugPrint('[web-browser] extension bundle: $e');
            return null;
          },
        );
    this.videoRemote = videoRemote?.call(this);
  }

  /// 手机视频遥控：把前台标签页的网页正片登记成遥控播放器（状态与控制都经本宿主的
  /// [request] 走页内扩展整栈）。null = 不接遥控。
  late final WebBrowserVideoRemote? videoRemote;

  final WebBrowserExtensionStorage _storage;
  late final StreamSubscription<Map<String, WebBrowserExtensionStorageChange>>
  _storageChanges;
  final Future<FushiExtensionApiResponse> Function(
    String path,
    Map<String, dynamic> body,
  )
  _api;
  final Future<String> Function(String asset)? _loadAsset;

  /// 页内取词与扩展查词共用的查词弹窗控制器（浏览页一份）。null = 不查词。
  final SrsCardLookupController? lookup;

  /// 网页视频在播的登记处：浏览器阅读计时据此避让，防同一段时间双计。
  final WebBrowserVideoActivity videoActivity;

  /// 打开扩展设置（播放器菜单「扩展设置」、报错 toast）。浏览页注入，用它自己的 context 推页。
  final void Function()? openSettings;

  /// 本会话密钥：写进注入脚本源码（页面读不到），页内每次调用都带上，Dart 只认它。
  final String secret;

  late final Future<String?> _bundleLoad;
  String? _bundle;
  bool _lastScriptsHadBundle = false;

  final Map<String, WebBrowserTab> _tabs = <String, WebBrowserTab>{};
  final Set<String> _tabsWithoutStartScript = <String>{};
  final Map<String, _ExtensionLookupSurface> _surfaces =
      <String, _ExtensionLookupSurface>{};
  final Map<String, Completer<Object?>> _pending =
      <String, Completer<Object?>>{};
  int _requestSeq = 0;
  final WebBrowserFeatureNotifier _changed = WebBrowserFeatureNotifier();

  /// 侧栏开在哪个标签页上（null = 关）。
  String? _panelTabId;

  static String _newSecret() {
    final Random r = Random.secure();
    return base64UrlEncode(List<int>.generate(24, (_) => r.nextInt(256)));
  }

  @override
  String get id => 'extension_host';

  @override
  Listenable? get actionsChanged => _changed;

  /// 测试用：整栈脚本读完（或失败 = null）。
  @visibleForTesting
  Future<String?> get bundleReady => _bundleLoad;

  /// 侧栏开在 [tab] 上？
  bool sidePanelOpenFor(WebBrowserTab tab) => _panelTabId == tab.id;

  @override
  List<UserScript> userScripts() {
    final String? bundle = _bundle;
    _lastScriptsHadBundle = bundle != null;
    if (bundle == null) return const <UserScript>[];
    return <UserScript>[
      UserScript(
        source: bundle,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ];
  }

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    _tabs[tab.id] = tab;
    if (!_lastScriptsHadBundle) {
      _tabsWithoutStartScript.add(tab.id);
    } else {
      _tabsWithoutStartScript.remove(tab.id);
    }
    controller.addJavaScriptHandler(
      handlerName: kWebBrowserExtensionHandler,
      callback: limitWebPayload(
        kWebBrowserExtensionHandler,
        kWebPayloadLargeMaxChars,
        (List<dynamic> args) => _onCall(tab, args),
      ),
    );
  }

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {
    _tabs[tab.id] = tab;
    videoRemote?.tabNavigated(tab);
    // 建 WebView 时整栈还没读完：这一页没有 document-start 脚本，加载完补装（脚本自带
    // 「同文档只装一次」守卫）。主世界桥错过了页面最早的请求，但字幕仍可经 app 后端取。
    if (!_tabsWithoutStartScript.contains(tab.id)) return;
    final String? bundle = await _bundleLoad;
    if (bundle == null) return;
    try {
      await controller.evaluateJavascript(source: bundle);
    } catch (e) {
      debugPrint('[web-browser] extension bundle late install: $e');
    }
  }

  @override
  void onUrlChanged(
    BuildContext context,
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) {
    videoRemote?.tabNavigated(tab);
  }

  @override
  void onPageCoveredChanged({required bool covered}) {
    // 盖住期间手机遥控不新登记，免得下面这页换视频后抢走上层播放器的手机。
    videoRemote?.setCovered(covered);
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    videoRemote?.tabClosed(tab);
    _tabs.remove(tab.id);
    _tabsWithoutStartScript.remove(tab.id);
    final _ExtensionLookupSurface? s = _surfaces.remove(tab.id);
    if (s != null) lookup?.unregister(s);
    videoActivity.clear(tab.id);
    if (_panelTabId == tab.id) {
      _panelTabId = null;
      _changed.notify();
    }
  }

  @override
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) {
    final WebBrowserVideoRemote? remote = videoRemote;
    if (remote != null) {
      if (active) {
        remote.setActiveTab(tab);
      } else {
        // 失活紧跟着的「新前台页激活」会再报一次；这里先撤掉，免得换页间隙还控着旧页。
        remote.tabDeactivated(tab);
      }
    }
    if (!active && _panelTabId == tab.id) {
      _panelTabId = null;
      _changed.notify();
    }
  }

  @override
  Widget? sidePanel(BuildContext context, WebBrowserTab tab) {
    if (_panelTabId != tab.id) return null;
    return WebBrowserSubtitlePanel(
      key: ValueKey<String>('web-browser-subtitle-panel-${tab.id}'),
      request: (Map<String, Object?> message) => request(tab, message),
      // 侧栏的后台消息（加载本地字幕 / 在线搜索）走与页内脚本同一份路由。
      runtime: (Map<String, Object?> message) =>
          routeWebBrowserExtensionMessage(
            Map<String, dynamic>.from(message),
            _servicesFor(tab),
          ),
      storage: _storage,
      onOpenSettings: openSettings,
      tabTitle: () => tab.title,
      onClose: closeSidePanel,
    );
  }

  /// 打开 / 关闭字幕侧栏。
  void openSidePanel(WebBrowserTab tab) {
    if (_panelTabId == tab.id) return;
    _panelTabId = tab.id;
    _changed.notify();
  }

  void closeSidePanel() {
    if (_panelTabId == null) return;
    _panelTabId = null;
    _changed.notify();
  }

  // ── 页内 → Dart ──────────────────────────────────────────────────────

  Future<Object?> _onCall(WebBrowserTab tab, List<dynamic> args) async {
    if (args.isEmpty) return null;
    final Object? raw = args.first;
    if (raw is! Map) return null;
    final Map<String, dynamic> body = Map<String, dynamic>.from(raw);
    if (body['secret'] != secret) return null;
    try {
      return await handleCall(tab, body);
    } catch (e, stack) {
      debugPrint('[web-browser] extension call ${body['op']}: $e\n$stack');
      return null;
    }
  }

  /// 处理一次页内调用（[body] 已验过密钥）。公开给测试。
  @visibleForTesting
  Future<Object?> handleCall(
    WebBrowserTab tab,
    Map<String, dynamic> body,
  ) async {
    switch (body['op']) {
      case 'message':
        final Object? message = body['message'];
        if (message is! Map) return kWebBrowserExtensionUnsupported;
        return routeWebBrowserExtensionMessage(
          Map<String, dynamic>.from(message),
          _servicesFor(tab),
        );
      case 'storageGet':
        final Object? keys = body['keys'];
        return _storage.get(
          keys is List ? <String>[for (final Object? k in keys) '$k'] : null,
        );
      case 'storageSet':
        final Object? items = body['items'];
        if (items is! Map) return null;
        // 广播走 [_storageChanges]（写入方是谁都一样）。
        await _storage.set(Map<String, Object?>.from(items));
        return null;
      case 'storageRemove':
        final Object? keys = body['keys'];
        if (keys is! List) return null;
        await _storage.remove(<String>[for (final Object? k in keys) '$k']);
        return null;
      case 'asset':
        return _readAsset(body['path']);
      case 'lookup':
        _presentLookup(tab, body);
        return null;
      case 'lookupDismiss':
        final _ExtensionLookupSurface? s = _surfaces[tab.id];
        final SrsCardLookupController? c = lookup;
        if (s == null || !s.session) return null;
        // content.js 已自己收了尾（续播 / 撤高亮）：先摘会话再关，关窗不再回调 JS。
        s.session = false;
        if (c != null && c.isOpen) c.closeAll();
        return null;
      case 'reply':
        final Completer<Object?>? done = _pending.remove('${body['id']}');
        if (done != null && !done.isCompleted) done.complete(body['response']);
        return null;
    }
    return null;
  }

  WebBrowserExtensionHostServices _servicesFor(WebBrowserTab tab) =>
      WebBrowserExtensionHostServices(
        api: _api,
        openSidePanel: () => openSidePanel(tab),
        openOptions: () => openSettings?.call(),
        dismissLookup: () {
          final _ExtensionLookupSurface? s = _surfaces[tab.id];
          if (s != null && s.session) lookup?.closeAll();
        },
        recordStudy: !tab.incognito,
        onStudySample: (Map<String, dynamic> sample) {
          if (tab.incognito) return;
          videoActivity.report(
            tab.id,
            playing: sample['playing'] == true && sample['ended'] != true,
          );
        },
      );

  /// 以 [tab] 的身份发一条扩展后台消息（`chrome.runtime.sendMessage` 同一份路由）：
  /// 字幕侧栏之外的 app 侧调用方（手机视频遥控的在线搜字幕）用。
  Future<Object?> runtimeMessage(
    WebBrowserTab tab,
    Map<String, Object?> message,
  ) => routeWebBrowserExtensionMessage(
    Map<String, dynamic>.from(message),
    _servicesFor(tab),
  );

  /// 扩展资源里只开放各语言的界面字典（i18n.js 按需取）；其它路径一律不给。
  static final RegExp _kAssetAllow = RegExp(
    r'^locales/[A-Za-z]{2}(-[A-Za-z]{2})?\.json$',
  );

  Future<String?> _readAsset(Object? path) async {
    if (path is! String || !_kAssetAllow.hasMatch(path)) return null;
    try {
      final Future<String> Function(String) load =
          _loadAsset ?? rootBundle.loadString;
      return await load('$kWebBrowserExtensionRoot$path');
    } catch (_) {
      return null;
    }
  }

  void _presentLookup(WebBrowserTab tab, Map<String, dynamic> body) {
    final SrsCardLookupController? c = lookup;
    final String term = body['term'] is String ? body['term'] as String : '';
    final String id = '${body['id']}';
    if (c == null || term.trim().isEmpty || !tab.hasViewport) {
      unawaited(_evaluate(tab, _closedScript()));
      return;
    }
    final Object? r = body['rect'];
    Rect local = Rect.zero;
    if (r is Map) {
      double n(Object? v) => v is num ? v.toDouble() : 0;
      local = Rect.fromLTWH(
        n(r['x']),
        n(r['y']),
        n(r['width']),
        n(r['height']),
      );
    }
    final Rect anchor =
        tab.viewportRectToGlobal(local) ?? Rect.fromLTWH(0, 0, 1, 1);
    final _ExtensionLookupSurface surface = _surfaces.putIfAbsent(tab.id, () {
      final _ExtensionLookupSurface s = _ExtensionLookupSurface(
        onClosed: () => unawaited(_evaluate(tab, _closedScript())),
      );
      c.register(s);
      return s;
    });
    surface.session = true;
    c.lookup(
      SrsCardLookupRequest(
        term: term,
        anchor: anchor,
        sentence: body['sentence'] is String ? body['sentence'] as String : '',
        fromHover: body['fromHover'] == true,
        origin: surface,
        onMatched: (int matched) => unawaited(
          _evaluate(
            tab,
            'window.__fushiExtHost && window.__fushiExtHost.lookupMatched('
            '${jsonEncode(secret)}, ${jsonEncode(id)}, $matched);',
          ),
        ),
      ),
    );
  }

  String _closedScript() =>
      'window.__fushiExtHost && window.__fushiExtHost.lookupClosed(${jsonEncode(secret)});';

  // ── Dart → 页内 ──────────────────────────────────────────────────────

  Future<void> _evaluate(WebBrowserTab tab, String source) async {
    final InAppWebViewController? controller = tab.controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      // 标签页正在导航 / WebView 已销毁：这次推送作废。
      debugPrint('[web-browser] extension evaluate: $e');
    }
  }

  /// 往 [tab] 页里派发一条 `runtime.onMessage` 消息并等它的 `sendResponse`（侧栏取状态、
  /// 跳转、选轨、偏移……扩展 Side Panel 同一份契约）。页面没装整栈 / 超时 → null。
  Future<Object?> request(
    WebBrowserTab tab,
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final String id = 'r${++_requestSeq}';
    final Completer<Object?> done = Completer<Object?>();
    _pending[id] = done;
    await _evaluate(
      tab,
      'window.__fushiExtHost && window.__fushiExtHost.dispatch('
      '${jsonEncode(secret)}, ${jsonEncode(id)}, ${jsonEncode(message)});',
    );
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      _pending.remove(id);
    }
  }

  void _broadcastStorage(
    Map<String, WebBrowserExtensionStorageChange> changes,
  ) {
    if (changes.isEmpty) return;
    final String script =
        'window.__fushiExtHost && window.__fushiExtHost.storageChanged('
        '${jsonEncode(secret)}, ${jsonEncode(webBrowserExtensionChangesJson(changes))});';
    for (final WebBrowserTab tab in _tabs.values.toList()) {
      unawaited(_evaluate(tab, script));
    }
  }

  /// app 侧改了存储：落库（广播经 [_storageChanges] 推给所有打开的页面）。
  Future<void> setStorage(Map<String, Object?> items) => _storage.set(items);

  /// 读存储。
  Map<String, Object?> readStorage(List<String>? keys) => _storage.get(keys);

  @override
  void dispose() {
    videoRemote?.dispose();
    unawaited(_storageChanges.cancel());
    for (final _ExtensionLookupSurface s in _surfaces.values) {
      lookup?.unregister(s);
    }
    _surfaces.clear();
    _tabs.clear();
    for (final Completer<Object?> c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    _changed.dispose();
  }
}

/// 扩展查词在查词控制器里的「取词表面」：只用来认出「这次弹窗是扩展发起的」，
/// 弹窗栈整个关掉时回调 JS 续播（换词 / 被别的表面接手不算关）。
class _ExtensionLookupSurface implements SrsCardLookupSurface {
  _ExtensionLookupSurface({required this.onClosed});

  final VoidCallback onClosed;

  /// 扩展的查词会话在场（content.js 那边有视频等着续播）。
  bool session = false;

  @override
  bool lookupAt(Offset globalPosition, {required bool fromHover}) => false;

  @override
  void onLookupStateChanged({
    required bool open,
    required SrsCardLookupSurface? origin,
  }) {
    if (open || !session) return;
    session = false;
    onClosed();
  }
}
