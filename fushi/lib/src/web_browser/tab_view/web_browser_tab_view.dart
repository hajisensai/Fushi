import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart'
    show kFloatingBallOcrLanguage;
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart'
    show hostOwnsWebViewHoverLookup;
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/reader/reader_host_hover_lookup.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_context_menu.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_downloader.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_incognito_profile.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_load_errors.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_permissions.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_actions.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_visit_recorder.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab_host.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// 一个标签页的网页视图：持有该标签页的 `InAppWebView` 与控制器生命周期，把页面
/// 状态全部写进 [WebBrowserTab]（进度、地址、标题、图标、前进后退、失败、全屏）。
/// 壳（浏览页）每个标签页摆一个，用 `IndexedStack` / `Offstage` 只露前台那个；
/// 加载失败页（[tab.error]）、页内查找条（[tab.findOpen]）由壳盖在上面。
///
/// 从旧单页浏览页迁来、行为不变的能力：
/// - **Fushi 查词**：复习卡面那一套（[SrsCardLookupController] 弹窗栈 + 阅读器选区
///   脚本 + 卡面取词监听）。控制器与 [SrsCardLookupHost] **归壳所有**（整页一份），
///   本视图经 [SrsCardLookupScope] 找到它、作为一块取词表面登记；只有前台标签页
///   响应 barrier 转发的取词。「点词查词」开关由壳经 [lookupEnabled] 下发；
/// - **广告 / 跟踪拦截**：[applyAdblockTo]（每个标签页一份接线，contentBlockers 平台
///   等引擎就绪再建 WebView）；
/// - **WebView 死亡守卫**：renderer 死后按当前地址重建（恢复锚是 [tab.url]，始终
///   等于当前位置）；
/// - macOS 宿主接管悬停取词（BUG-2508 同法）。
///
/// 网页漫画 / 网页小说两个动作改成了功能插件（`tab_view/features/`），经
/// [WebBrowserTabHost.features] 接进来。
class WebBrowserTabView extends ConsumerStatefulWidget {
  const WebBrowserTabView({
    required this.tab,
    required this.host,
    this.lookupEnabled = true,
    super.key,
  });

  final WebBrowserTab tab;
  final WebBrowserTabHost host;

  /// 壳工具栏上的「点词查词」开关（关掉时点正文 / Shift 悬停都不弹窗）。
  final bool lookupEnabled;

  /// 测试注入：widget 测试里没有平台视图。设置后不建 WebView、不准备环境。
  @visibleForTesting
  static Widget Function(BuildContext context, WebBrowserTab tab)?
  debugWebViewBuilder;

  @override
  ConsumerState<WebBrowserTabView> createState() => WebBrowserTabViewState();
}

class WebBrowserTabViewState extends ConsumerState<WebBrowserTabView>
    implements SrsCardLookupSurface {
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'web-browser-tab',
    flushBeforeRebuild: () async => _detachController(),
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );
  final GlobalKey _webViewKey = GlobalKey(debugLabel: 'web-browser-tab');
  final ReaderHostHoverLookupGate _hostHover = ReaderHostHoverLookupGate();
  static final String _lookupInstallScript = srsCardLookupInstallScript(
    ReaderSelectionScripts.source(),
  );

  /// 系统 OCR 是否可用（整个进程问一次）。
  static Future<bool>? _ocrAvailable;

  /// 最近一次备好的 WebView 环境 / 系统默认 UA（进程内共享）。`onCreateWindow` 开出的
  /// 标签页必须**立刻**用 windowId 建出 WebView（平台侧正挂着这次新窗口请求，
  /// Windows 在 `in_app_webview_manager.cpp` 按 windowId 交接），不能再等一轮异步
  /// 准备；开它的那个页面已经备好过，这里直接复用同一个环境。
  static bool _sharedReady = false;
  static WebViewEnvironment? _sharedEnvironment;
  static String? _sharedDefaultUserAgent;

  SrsCardLookupController? _lookup;
  WebAdblockWiring? _adblock;
  bool _environmentReady = false;
  WebViewEnvironment? _environment;
  InAppWebViewController? _controller;
  PullToRefreshController? _pullToRefresh;
  late final WebBrowserDownloader _downloader;
  WebBrowserVisitRecorder? _recorder;
  late final InAppWebViewSettings _settings;
  late final TargetPlatform _platform = defaultTargetPlatform;
  String? _defaultUserAgent;

  /// 第一次建 WebView 用 `onCreateWindow` 给的窗口 id；之后（死亡守卫重建）按地址。
  bool _windowConsumed = false;

  /// 主框架 HTTP 4xx / 5xx 候选（加载结束按页面是否空白决定是否显示失败页）。
  int? _pendingHttpStatus;

  bool? _active;

  bool _appliedDesktopMode = false;
  int _appliedTextZoom = 100;
  bool _appliedForceDark = false;
  Offset? _lastPointerDown;
  bool _closed = false;

  /// Android：退出网页全屏后还原页面缩放（见 [WebBrowserFullscreenZoomGuard]）。
  final WebBrowserFullscreenZoomGuard _fullscreenZoom =
      WebBrowserFullscreenZoomGuard();

  WebBrowserTab get _tab => widget.tab;

  /// initState 里取一次：dispose 期间不能再经 ref 往上查（Riverpod 禁止）。
  late final PreferencesRepository _prefs = ref.read(appProvider).prefsRepo;
  bool get _mobile =>
      _platform == TargetPlatform.android || _platform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _appliedDesktopMode = _tab.desktopMode;
    _appliedTextZoom = _tab.textZoom;
    _appliedForceDark = _readForceDark();
    _downloader = WebBrowserDownloader(
      store: widget.host.store,
      // 按标签页会话取 cookie：Android 无痕页取本会话具名 Profile；其它平台无痕页
      // 没有可读的隔离罐，不带 cookie（绝不退回持久罐）。
      cookieHeader: (Uri url) =>
          WebBrowserIncognitoProfiles.instance.tabCookieHeader(
            url,
            incognito: _tab.incognito,
            persistent: webBrowserCookieHeaderResolverFor(_environment),
          ),
    );
    if (!_tab.incognito) {
      _recorder = WebBrowserVisitRecorder(
        record: (Uri url, String title) => unawaited(
          widget.host.store
              .recordVisit(url: url, title: title)
              .catchError(
                (Object e, StackTrace s) => ErrorLogService.instance.log(
                  'WebBrowserTabView.recordVisit',
                  e,
                  s,
                ),
              ),
        ),
      );
    }
    _tab.addListener(_onTabChanged);
    _prefs.addListener(_onPrefsChanged);
    if (WebBrowserTabView.debugWebViewBuilder == null) {
      _settings = _buildSettings();
      if (_mobile) {
        _pullToRefresh = PullToRefreshController(
          onRefresh: () {
            final InAppWebViewController? controller = _controller;
            if (controller == null) return;
            _recorder?.onReload();
            unawaited(controller.reload());
          },
        );
      }
      if (_tab.windowId != null && _sharedReady) {
        _prepareSynchronously();
      } else {
        unawaited(_prepareEnvironment());
      }
    } else {
      _settings = InAppWebViewSettings();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final SrsCardLookupController? lookup = SrsCardLookupScope.of(context);
    if (!identical(lookup, _lookup)) {
      _lookup?.unregister(this);
      _lookup = lookup;
      lookup?.register(this);
    }
  }

  @override
  void didUpdateWidget(WebBrowserTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      identical(oldWidget.tab, widget.tab),
      'WebBrowserTabView 要按标签页 id 设 key：换标签页必须换 State',
    );
    if (oldWidget.lookupEnabled != widget.lookupEnabled) {
      if (!widget.lookupEnabled && _lookup?.isOpen == true) {
        _lookup?.closeAll();
      }
      unawaited(_evaluateQuiet(_lookupGateScript()));
    }
  }

  @override
  void dispose() {
    _closed = true;
    _tab.removeListener(_onTabChanged);
    _prefs.removeListener(_onPrefsChanged);
    _lookup?.unregister(this);
    _recorder?.flush();
    // 插件的前后台 / 关闭回调只由标签控制器（WebBrowserTabsController）发：视图被
    // 回收（活 WebView 上限）或重建时也会 dispose，那不是「关闭」。
    _detachController();
    super.dispose();
  }

  void _detachController() {
    _controller = null;
    // 摘控制器会 notify 壳；dispose 期间壳可能正在重建，推迟到帧后。
    final WebBrowserTab tab = _tab;
    tab.attachViewport(null);
    if (tab.controller == null) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => tab.attachController(null),
      );
    } else {
      tab.attachController(null);
    }
  }

  // ── 设置 ─────────────────────────────────────────────────────────────

  bool _readForceDark() {
    try {
      return webBrowserForceDark(_prefs);
    } on Object {
      return false;
    }
  }

  InAppWebViewSettings _buildSettings() {
    final InAppWebViewSettings settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      sharedCookiesEnabled: !_tab.incognito,
      incognito: _tab.incognito,
      supportMultipleWindows: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useOnDownloadStart: true,
      disableLongPressContextMenuOnLinks: true,
      allowsLinkPreview: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      isElementFullscreenEnabled: true,
    );
    // 插件 `incognito` 在 Android 上会清全局 cookie：这里先把它关掉，后续
    // adblock 副本与 setSettings 都从这份派生。
    applyWebBrowserIncognito(settings, incognito: _tab.incognito);
    applyWebBrowserPageSettings(
      settings,
      platform: _platform,
      desktopMode: _appliedDesktopMode,
      textZoom: _appliedTextZoom,
      forceDark: _appliedForceDark,
      defaultUserAgent: _defaultUserAgent,
    );
    return settings;
  }

  /// 新窗口标签页：同步拿共享环境与拦截接线，本帧就建 WebView。
  void _prepareSynchronously() {
    _environment = _sharedEnvironment;
    _defaultUserAgent = _sharedDefaultUserAgent;
    applyWebBrowserPageSettings(
      _settings,
      platform: _platform,
      desktopMode: _appliedDesktopMode,
      textZoom: _appliedTextZoom,
      forceDark: _appliedForceDark,
      defaultUserAgent: _defaultUserAgent,
    );
    _adblock = applyAdblockTo(
      _settings,
      policy: ref.read(webAdblockServiceProvider),
      mode: currentWebAdblockNetworkMode,
    );
    _environmentReady = true;
  }

  Future<void> _prepareEnvironment() async {
    WebViewEnvironment? environment;
    try {
      // 与网页漫画的无界面扫图、CookieManager 同一个环境：取图带的 cookie 就是
      // 用户在这里登录 / 过验证得到的那份（Windows 上 cookie 归环境所有）。
      environment = await MangaWebViewEnvironment.obtain();
    } on Object {
      environment = null;
    }
    if (_platform == TargetPlatform.android) {
      try {
        _defaultUserAgent = await InAppWebViewController.getDefaultUserAgent();
      } on Object {
        _defaultUserAgent = null;
      }
      applyWebBrowserPageSettings(
        _settings,
        platform: _platform,
        desktopMode: _appliedDesktopMode,
        textZoom: _appliedTextZoom,
        forceDark: _appliedForceDark,
        defaultUserAgent: _defaultUserAgent,
      );
    }
    final WebAdblockService adblock = ref.read(webAdblockServiceProvider);
    final WebAdblockNetworkMode mode = currentWebAdblockNetworkMode;
    final Future<void> loading = adblock.ensureLoaded().catchError((
      Object e,
      StackTrace s,
    ) {
      ErrorLogService.instance.log('WebBrowserTabView.adblockLoad', e, s);
    });
    // contentBlockers 平台（iOS / macOS）的规则在 WebView 创建时固化：等引擎就绪
    // 再建，否则这一页整页不拦。逐请求平台后台加载即可。
    if (mode == WebAdblockNetworkMode.contentBlockers) await loading;
    _sharedEnvironment = environment;
    _sharedDefaultUserAgent = _defaultUserAgent;
    _sharedReady = true;
    if (!mounted) return;
    setState(() {
      _environment = environment;
      _adblock = applyAdblockTo(_settings, policy: adblock, mode: mode);
      _environmentReady = true;
    });
  }

  void _onPrefsChanged() {
    final bool forceDark = _readForceDark();
    if (forceDark == _appliedForceDark) return;
    _appliedForceDark = forceDark;
    unawaited(_applySettings(reload: false));
  }

  void _onTabChanged() {
    if (_closed) return;
    final bool desktop = _tab.desktopMode;
    final int zoom = _tab.textZoom;
    if (desktop != _appliedDesktopMode || zoom != _appliedTextZoom) {
      final bool reload = desktop != _appliedDesktopMode;
      _appliedDesktopMode = desktop;
      _appliedTextZoom = zoom;
      unawaited(_applySettings(reload: reload));
    }
  }

  /// 桌面版 / 文字大小 / 深色模式变化：原生设置走 `setSettings`，页内 CSS 立即注入
  /// 并换掉以后每个文档的 user script。桌面版切换要重新加载才生效。
  Future<void> _applySettings({required bool reload}) async {
    final InAppWebViewController? controller = _controller;
    final WebAdblockWiring? adblock = _adblock;
    final InAppWebViewSettings target = adblock?.settings ?? _settings;
    applyWebBrowserPageSettings(
      target,
      platform: _platform,
      desktopMode: _appliedDesktopMode,
      textZoom: _appliedTextZoom,
      forceDark: _appliedForceDark,
      defaultUserAgent: _defaultUserAgent,
    );
    if (controller == null) return;
    try {
      await controller.setSettings(settings: target);
      await _replaceGroupScripts(controller);
      await controller.evaluateJavascript(source: _pageStyleScripts());
      if (reload) {
        _recorder?.onReload();
        await controller.reload();
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserTabView.applySettings',
        error,
        stack,
      );
    }
  }

  static const String _kStyleScriptGroup = 'fushi-browser-page-style';

  /// 文字大小（非原生平台）+ 深色模式（非原生平台）的页内脚本。
  String _pageStyleScripts() {
    final StringBuffer out = StringBuffer();
    final String? zoom = webBrowserTextZoomScript(
      _appliedTextZoom,
      webBrowserTextZoomModeOn(_platform),
    );
    if (zoom != null) out.writeln(zoom);
    if (!webBrowserForceDarkNativeOn(_platform)) {
      out.writeln(webBrowserForceDarkScript(enabled: _appliedForceDark));
    }
    return out.toString();
  }

  UserScript _styleUserScript() => UserScript(
    groupName: _kStyleScriptGroup,
    source: _pageStyleScripts(),
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
  );

  Future<void> _replaceGroupScripts(InAppWebViewController controller) async {
    await controller.removeUserScriptsByGroupName(
      groupName: _kStyleScriptGroup,
    );
    await controller.addUserScript(userScript: _styleUserScript());
  }

  List<UserScript> _initialUserScripts(WebAdblockWiring adblock) {
    return <UserScript>[
      ...adblock.userScripts,
      UserScript(
        source: kWebBrowserScrollScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      UserScript(
        source: kWebBrowserFullscreenScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      // 桌面右键换成本 app 的链接 / 图片菜单；手机走原生长按命中（Android 的
      // 长按也会派发 contextmenu，装了会弹两次）。
      if (!_mobile)
        UserScript(
          source: kWebBrowserContextMenuScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      _styleUserScript(),
      for (final WebBrowserFeature f in widget.host.features)
        ...f.userScripts(),
    ];
  }

  // ── 前台 / 功能插件 ──────────────────────────────────────────────────

  /// 前台 / 后台切换：壳换前台标签页时会重建各标签页视图，这里在 build 里比对。
  /// 插件的 onTabActiveChanged 由标签控制器发，这里只收尾本视图自己的状态。
  void _syncActive() {
    final bool active = widget.host.isActive(_tab);
    if (active == _active) return;
    _active = active;
    if (active) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _active != false) return;
      // 后台标签页的查词弹窗没有意义（看不见它的网页）。
      if (_lookup?.isOpen == true) _lookup?.closeAll();
    });
  }

  void _guardFeature(WebBrowserFeature f, String hook, void Function() body) {
    try {
      body();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserFeature(${f.id}).$hook',
        error,
        stack,
      );
    }
  }

  // ── 导航状态 ─────────────────────────────────────────────────────────

  Future<void> _syncNavigation(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    bool back = false;
    bool forward = false;
    String? title;
    try {
      back = await controller.canGoBack();
      forward = await controller.canGoForward();
      title = await controller.getTitle();
    } on Object {
      // 平台实现没给（或 WebView 已销毁）：按钮保持禁用即可。
    }
    if (!mounted) return;
    _tab.update(
      url: url == null ? null : Uri.tryParse(url.toString()),
      title: title,
      canGoBack: back,
      canGoForward: forward,
    );
  }

  Future<void> _updateFavicon(InAppWebViewController controller) async {
    try {
      final Object? raw = await controller.evaluateJavascript(
        source: kWebBrowserFaviconScript,
      );
      if (raw is! String || raw.isEmpty || !mounted) return;
      final Uri? icon = Uri.tryParse(raw);
      if (icon != null) _tab.update(faviconUrl: icon);
    } on Object {
      // 拿不到就用首字母色块。
    }
  }

  void _onLoadStart(WebUri? url) {
    _adblock?.onLoadStart(url);
    _fullscreenZoom.stop();
    _pendingHttpStatus = null;
    if (_tab.error != null) _tab.setError(null);
    _tab.update(
      url: url == null ? null : Uri.tryParse(url.toString()),
      loading: true,
      progress: 0,
    );
  }

  Future<void> _onLoadStop(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    unawaited(_pullToRefresh?.endRefreshing());
    _tab.update(loading: false);
    await _syncNavigation(controller, url);
    if (!mounted) return;
    final Uri? pageUrl = url == null ? null : Uri.tryParse(url.toString());
    _recorder?.onLoadStop(pageUrl, _tab.title);
    unawaited(_updateFavicon(controller));
    unawaited(_installLookup(controller));
    unawaited(_evaluateQuiet(_pageStyleScripts()));
    unawaited(_checkHttpError(controller, pageUrl));
    for (final WebBrowserFeature f in widget.host.features) {
      unawaited(
        f.onLoadStop(_tab, controller, pageUrl).catchError((
          Object e,
          StackTrace s,
        ) {
          ErrorLogService.instance.log(
            'WebBrowserFeature(${f.id}).onLoadStop',
            e,
            s,
          );
        }),
      );
    }
  }

  Future<void> _checkHttpError(
    InAppWebViewController controller,
    Uri? url,
  ) async {
    final int? status = _pendingHttpStatus;
    if (status == null || url == null) return;
    int text = 1;
    int media = 1;
    try {
      final Object? raw = await controller.evaluateJavascript(
        source: kWebBrowserBlankPageProbeScript,
      );
      final Object? decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map) {
        text = (decoded['text'] as num?)?.toInt() ?? 1;
        media = (decoded['media'] as num?)?.toInt() ?? 1;
      }
    } on Object {
      return;
    }
    if (!mounted || _pendingHttpStatus != status) return;
    if (shouldShowWebBrowserHttpError(
      pendingStatusCode: status,
      visibleTextLength: text,
      mediaElementCount: media,
    )) {
      _tab.setError(
        WebBrowserLoadError(
          url: url,
          description: 'HTTP $status',
          statusCode: status,
        ),
      );
    }
  }

  void _onReceivedError(WebResourceRequest request, WebResourceError error) {
    final WebBrowserLoadError? classified = classifyWebBrowserMainFrameError(
      url: Uri.tryParse(request.url.toString()),
      isForMainFrame: request.isForMainFrame ?? true,
      type: error.type,
      description: error.description,
    );
    if (classified == null) return;
    unawaited(_pullToRefresh?.endRefreshing());
    _tab.update(loading: false);
    _tab.setError(classified);
  }

  void _setFullscreen(bool fullscreen) {
    if (_platform == TargetPlatform.android) {
      if (fullscreen) {
        _fullscreenZoom.onEnterFullscreen();
      } else {
        _applyZoomCorrection(_fullscreenZoom.onExitFullscreen());
      }
    }
    if (_tab.fullscreen == fullscreen) return;
    _tab.update(fullscreen: fullscreen);
    widget.host.onFullscreenChanged(_tab, fullscreen: fullscreen);
  }

  void _onZoomScaleChanged(double newScale) {
    if (_platform != TargetPlatform.android) return;
    _applyZoomCorrection(_fullscreenZoom.onScaleChanged(newScale));
  }

  void _applyZoomCorrection(double? factor) {
    final InAppWebViewController? controller = _controller;
    if (factor == null || controller == null) return;
    unawaited(controller.zoomBy(zoomFactor: factor).catchError((Object _) {}));
  }

  // ── 新窗口 ───────────────────────────────────────────────────────────

  Future<bool> _onCreateWindow(CreateWindowAction action) async {
    final String? origin = _originOf(_tab.url);
    if (origin != null &&
        WebBrowserSiteSettings(
              _prefs,
            ).decision(origin, WebBrowserSitePermission.popups) ==
            WebBrowserPermissionDecision.block) {
      return false;
    }
    final WebUri? raw = action.request.url;
    widget.host.openTab(
      raw == null || raw.toString().isEmpty || raw.toString() == 'about:blank'
          ? null
          : Uri.tryParse(raw.toString()),
      openerId: _tab.id,
      windowId: action.windowId,
      incognito: _tab.incognito,
    );
    return true;
  }

  String? _originOf(Uri? url) => url == null ? null : webBrowserOriginOf(url);

  // ── 下载 ─────────────────────────────────────────────────────────────

  Future<void> _download(WebBrowserDownloadRequest request) async {
    final String name = inferWebBrowserDownloadFileName(
      url: request.url,
      suggestedFileName: request.suggestedFileName,
      contentDisposition: request.contentDisposition,
      mimeType: request.mimeType,
    );
    if (_downloader.destination ==
        WebBrowserDownloadDestination.userDownloads) {
      FushiToast.show(msg: t.web_browser_download_started(name: name));
    }
    final WebBrowserDownloadOutcome outcome = await _downloader.download(
      request,
    );
    if (!outcome.succeeded) {
      FushiToast.show(
        msg: t.web_browser_download_failed(name: outcome.fileName),
        severity: ToastSeverity.error,
      );
      return;
    }
    final String? path = outcome.savedPath;
    if (outcome.sharedInstead || path == null || !mounted) return;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) {
      FushiToast.show(
        msg: t.web_browser_download_completed(name: outcome.fileName),
        severity: ToastSeverity.success,
      );
      return;
    }
    messenger.showSnackBar(
      FushiSnackBar(
        content: Text(t.web_browser_download_completed(name: outcome.fileName)),
        action: SnackBarAction(
          label: t.web_browser_download_open,
          onPressed: () => unawaited(openWebBrowserDownloadedFile(path)),
        ),
      ),
    );
  }

  void _onDownloadStart(DownloadStartRequest request) {
    unawaited(
      _download(
        WebBrowserDownloadRequest(
          url: Uri.parse(request.url.toString()),
          suggestedFileName: request.suggestedFilename,
          contentDisposition: request.contentDisposition,
          mimeType: request.mimeType,
          contentLength: request.contentLength > 0
              ? request.contentLength
              : null,
          userAgent: request.userAgent,
          referer: _tab.url,
          incognito: _tab.incognito,
        ),
      ),
    );
  }

  // ── 权限 ─────────────────────────────────────────────────────────────

  Future<PermissionResponse> _onPermissionRequest(
    PermissionRequest request,
  ) async {
    final List<WebBrowserSitePermission>? permissions =
        webBrowserSitePermissionsFor(request.resources);
    final String? origin = webBrowserOriginOf(
      Uri.tryParse(request.origin.toString()) ?? Uri(),
    );
    bool allow = false;
    if (permissions != null && origin != null && mounted) {
      allow = await resolveWebBrowserPermission(
        context: context,
        settings: WebBrowserSiteSettings(_prefs),
        origin: origin,
        permissions: permissions,
      );
      // 网页层允许了还要 app 自己有系统权限（Android 摄像头 / 麦克风），用户在
      // 系统框里拒绝就整条拒绝。
      if (allow) {
        allow = await ensureWebBrowserSystemPermissions(
          permissions,
          platform: _platform,
        );
      }
    }
    return PermissionResponse(
      resources: request.resources,
      action: allow
          ? PermissionResponseAction.GRANT
          : PermissionResponseAction.DENY,
    );
  }

  Future<GeolocationPermissionShowPromptResponse> _onGeolocationPrompt(
    String rawOrigin,
  ) async {
    final String? origin = webBrowserOriginOf(Uri.tryParse(rawOrigin) ?? Uri());
    bool allow = false;
    if (origin != null && mounted) {
      allow = await resolveWebBrowserPermission(
        context: context,
        settings: WebBrowserSiteSettings(_prefs),
        origin: origin,
        permissions: const <WebBrowserSitePermission>[
          WebBrowserSitePermission.geolocation,
        ],
      );
    }
    return GeolocationPermissionShowPromptResponse(
      origin: rawOrigin,
      allow: allow,
      retain: false,
    );
  }

  // ── 链接 / 图片菜单 ───────────────────────────────────────────────────

  Future<void> _onLongPressHitTest(
    InAppWebViewController controller,
    InAppWebViewHitTestResult result,
  ) async {
    Uri? href;
    String title = '';
    if (result.type == InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE ||
        result.type == InAppWebViewHitTestResultType.SRC_ANCHOR_TYPE) {
      try {
        final RequestFocusNodeHrefResult? focus = await controller
            .requestFocusNodeHref();
        final String? raw = focus?.url?.toString();
        href = raw == null ? null : Uri.tryParse(raw);
        title = focus?.title ?? '';
      } on Object {
        href = null;
      }
    }
    final WebBrowserHitTarget target = webBrowserHitTargetFromHitTest(
      result,
      focusHref: href,
      focusTitle: title,
    );
    await _showContextMenu(target, _lastPointerDown);
  }

  void _onDesktopContextMenu(Object? payload) {
    final WebBrowserHitTarget target = webBrowserHitTargetFromJs(
      payload,
      base: _tab.url,
    );
    Offset? at;
    final RenderBox? box = _webViewBox;
    if (payload is Map && box != null) {
      final Object? x = payload['x'];
      final Object? y = payload['y'];
      if (x is num && y is num) {
        at = box.localToGlobal(Offset(x.toDouble(), y.toDouble()));
      }
    }
    unawaited(_showContextMenu(target, at ?? _lastPointerDown));
  }

  Future<void> _showContextMenu(
    WebBrowserHitTarget target,
    Offset? globalPosition,
  ) async {
    if (target.isEmpty || !mounted) return;
    final bool ocr = await (_ocrAvailable ??= const MethodChannelSystemOcr()
        .isAvailable()
        .catchError((Object _) => false));
    if (!mounted) return;
    final List<WebBrowserContextMenuItem> items = webBrowserContextMenuItems(
      target,
      incognitoAvailable: webBrowserIncognitoSupported() && !_tab.incognito,
      ocrAvailable: ocr,
    );
    if (items.isEmpty) return;
    final RenderBox? overlay =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final Offset at =
        globalPosition ??
        (_webViewBox?.localToGlobal(_webViewBox!.size.center(Offset.zero)) ??
            overlay.size.center(Offset.zero));
    final Offset local = overlay.globalToLocal(at);
    final WebBrowserContextMenuItem? picked =
        await showFushiMenu<WebBrowserContextMenuItem>(
          context: context,
          position: RelativeRect.fromRect(
            Rect.fromLTWH(local.dx, local.dy, 0, 0),
            Offset.zero & overlay.size,
          ),
          items: <PopupMenuEntry<WebBrowserContextMenuItem>>[
            for (final WebBrowserContextMenuItem item in items)
              FushiPopupMenuItem<WebBrowserContextMenuItem>(
                key: ValueKey<String>('web-browser-menu-${item.name}'),
                value: item,
                label: _menuLabel(item),
                icon: _menuIcon(item),
              ),
          ],
        );
    if (picked == null || !mounted) return;
    await _runMenuItem(picked, target);
  }

  String _menuLabel(WebBrowserContextMenuItem item) => switch (item) {
    WebBrowserContextMenuItem.openNewTab => t.web_browser_link_open_new_tab,
    WebBrowserContextMenuItem.openBackgroundTab =>
      t.web_browser_link_open_background_tab,
    WebBrowserContextMenuItem.openIncognitoTab =>
      t.web_browser_link_open_incognito_tab,
    WebBrowserContextMenuItem.copyLink => t.web_browser_link_copy,
    WebBrowserContextMenuItem.shareLink => t.web_browser_link_share,
    WebBrowserContextMenuItem.openImageNewTab =>
      t.web_browser_image_open_new_tab,
    WebBrowserContextMenuItem.saveImage => t.web_browser_image_save,
    WebBrowserContextMenuItem.copyImageUrl => t.web_browser_image_copy_url,
    WebBrowserContextMenuItem.ocrImage => t.web_browser_image_ocr_lookup,
  };

  IconData _menuIcon(WebBrowserContextMenuItem item) => switch (item) {
    WebBrowserContextMenuItem.openNewTab => FushiIcons.openInNew,
    WebBrowserContextMenuItem.openBackgroundTab => FushiIcons.openInNew,
    WebBrowserContextMenuItem.openIncognitoTab => FushiIcons.incognito,
    WebBrowserContextMenuItem.copyLink => FushiIcons.link,
    WebBrowserContextMenuItem.shareLink => FushiIcons.share,
    WebBrowserContextMenuItem.openImageNewTab => FushiIcons.image,
    WebBrowserContextMenuItem.saveImage => FushiIcons.download,
    WebBrowserContextMenuItem.copyImageUrl => FushiIcons.copy,
    WebBrowserContextMenuItem.ocrImage => FushiIcons.ocr,
  };

  Future<void> _runMenuItem(
    WebBrowserContextMenuItem item,
    WebBrowserHitTarget target,
  ) async {
    final Uri? link = target.link;
    final Uri? image = target.image;
    switch (item) {
      case WebBrowserContextMenuItem.openNewTab:
        if (link != null) {
          widget.host.openTab(
            link,
            openerId: _tab.id,
            incognito: _tab.incognito,
          );
        }
      case WebBrowserContextMenuItem.openBackgroundTab:
        if (link != null) {
          widget.host.openTab(
            link,
            openerId: _tab.id,
            incognito: _tab.incognito,
            activate: false,
          );
        }
      case WebBrowserContextMenuItem.openIncognitoTab:
        if (link != null) widget.host.openTab(link, incognito: true);
      case WebBrowserContextMenuItem.copyLink:
        if (link != null) await copyWebBrowserText(link.toString());
      case WebBrowserContextMenuItem.shareLink:
        if (link != null) {
          await FushiShare.shareText(link.toString(), subject: target.linkText);
        }
      case WebBrowserContextMenuItem.openImageNewTab:
        if (image != null) {
          widget.host.openTab(
            image,
            openerId: _tab.id,
            incognito: _tab.incognito,
          );
        }
      case WebBrowserContextMenuItem.saveImage:
        if (image != null) {
          await _download(
            WebBrowserDownloadRequest(
              url: image,
              referer: _tab.url,
              incognito: _tab.incognito,
              userAgent: await _userAgent(),
            ),
          );
        }
      case WebBrowserContextMenuItem.copyImageUrl:
        if (image != null) await copyWebBrowserText(image.toString());
      case WebBrowserContextMenuItem.ocrImage:
        if (image != null) await _ocrImage(image);
    }
  }

  Future<String?> _userAgent() async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return null;
    try {
      final Object? ua = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      return ua is String ? ua : null;
    } on Object {
      return null;
    }
  }

  /// 「对图片 OCR 查词」：取图（同一套 cookie / Referer）→ 系统 OCR → 全屏选取页
  /// 点字查词。与悬浮球「拍照查词」同一条链路（[ScreenOcrPickerPage]）。
  Future<void> _ocrImage(Uri image) async {
    final Uint8List bytes;
    try {
      bytes = await _downloader.fetchBytes(
        image,
        referer: _tab.url,
        userAgent: await _userAgent(),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('WebBrowserTabView.ocrFetch', error, stack);
      FushiToast.show(
        msg: t.web_browser_image_load_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    final SystemOcrPageResult result;
    try {
      result = await const MethodChannelSystemOcr().recognize(
        bytes,
        language: kFloatingBallOcrLanguage,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('WebBrowserTabView.ocr', error, stack);
      FushiToast.show(
        msg: t.floating_ball_ocr_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (result.isEmpty) {
      FushiToast.show(msg: t.floating_ball_ocr_empty);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
            ) => FadeTransition(
              opacity: animation,
              child: ScreenOcrPickerPage(
                imageBytes: bytes,
                result: result,
                fit: ScreenOcrImageFit.contain,
              ),
            ),
      ),
    );
  }

  // ── 查词 ─────────────────────────────────────────────────────────────

  Future<void> _evaluateQuiet(String source) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: source);
    } on Object {
      // 平台视图半销毁 / 页面正在跳转：no-op。
    }
  }

  String _lookupGateScript() {
    final SrsCardLookupController? lookup = _lookup;
    final SrsCardLookupSettings settings =
        lookup?.settings ?? (tap: false, hoverAuto: false);
    final bool enabled = widget.lookupEnabled && lookup != null;
    return srsCardLookupGateScript(
      tap: enabled && settings.tap,
      hover: enabled && settings.hoverAuto,
      hostHover: hostOwnsWebViewHoverLookup,
      open: lookup?.isOpen ?? false,
    );
  }

  /// 每个新文档（onLoadStop）装一次取词脚本（脚本自带幂等守卫）并下发门控。
  Future<void> _installLookup(InAppWebViewController controller) async {
    if (_lookup == null) return;
    try {
      await controller.evaluateJavascript(source: _lookupInstallScript);
      await controller.evaluateJavascript(source: _lookupGateScript());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'WebBrowserTabView.installLookup',
        error,
        stack,
      );
    }
  }

  RenderBox? get _webViewBox {
    final RenderObject? r = _webViewKey.currentContext?.findRenderObject();
    return r is RenderBox && r.attached && r.hasSize ? r : null;
  }

  Rect? _viewportRectToGlobal(Rect local) {
    final RenderBox? box = _webViewBox;
    if (box == null || !mounted) return null;
    return box.localToGlobal(local.topLeft) & local.size;
  }

  void _onTextSelected(Object? raw) {
    final SrsCardLookupController? lookup = _lookup;
    final RenderBox? box = _webViewBox;
    if (lookup == null ||
        box == null ||
        raw is! String ||
        !widget.lookupEnabled ||
        !widget.host.isActive(_tab)) {
      return;
    }
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    final ReaderSelectionData data = ReaderSelectionData.fromJson(json);
    if (data.text.trim().isEmpty) return;
    final Map<String, double>? r = data.rect;
    final Rect local = r == null
        ? Rect.fromCenter(
            center: box.size.center(Offset.zero),
            width: 1,
            height: 1,
          )
        : Rect.fromLTWH(
            r['x'] ?? 0,
            r['y'] ?? 0,
            r['width'] ?? 0,
            r['height'] ?? 0,
          );
    lookup.lookup(
      SrsCardLookupRequest(
        term: data.text,
        anchor: box.localToGlobal(local.topLeft) & local.size,
        sentence: data.sentence.isEmpty ? data.text : data.sentence,
        fromHover: data.fromHover,
        origin: this,
        onMatched: (int count) => unawaited(
          _evaluateQuiet(ReaderSelectionScripts.highlightInvocation(count)),
        ),
      ),
    );
  }

  @override
  bool lookupAt(Offset globalPosition, {required bool fromHover}) {
    final RenderBox? box = _webViewBox;
    if (_controller == null ||
        box == null ||
        !mounted ||
        !widget.lookupEnabled ||
        !widget.host.isActive(_tab)) {
      return false;
    }
    final Offset local = box.globalToLocal(globalPosition);
    if (!readerHostHoverPointInside(local, box.size)) return false;
    unawaited(
      _evaluateQuiet(
        ReaderSelectionScripts.selectInvocation(
          local.dx,
          local.dy,
          400,
          fromHover: fromHover,
        ),
      ),
    );
    return true;
  }

  @override
  void onLookupStateChanged({
    required bool open,
    required SrsCardLookupSurface? origin,
  }) {
    if (!open) _hostHover.reset();
    unawaited(
      _evaluateQuiet(
        _lookupGateScript() +
            (!open || !identical(origin, this)
                ? ReaderSelectionScripts.clearInvocation()
                : ''),
      ),
    );
  }

  /// macOS：页内收不到 mousemove，宿主侧接管悬停取词（BUG-2508 同法）。
  void _onHostHover(PointerHoverEvent event) {
    final SrsCardLookupController? lookup = _lookup;
    if (lookup == null || !widget.lookupEnabled || lookup.isOpen) return;
    if (!_hostHover.shouldLookup(
      event.localPosition,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      hoverAutoLookup: lookup.settings.hoverAuto,
    )) {
      return;
    }
    lookupAt(event.position, fromHover: true);
  }

  // ── 构建 ─────────────────────────────────────────────────────────────

  void _registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onTextSelected',
      callback: limitWebPayload('onTextSelected', kWebPayloadSmallMaxChars, (
        List<dynamic> arguments,
      ) {
        if (mounted && arguments.isNotEmpty) {
          _onTextSelected(arguments.first);
        }
        return null;
      }),
    );
    controller.addJavaScriptHandler(
      handlerName: 'onTapEmpty',
      callback: (List<dynamic> _) => null,
    );
    controller.addJavaScriptHandler(
      handlerName: kWebBrowserScrollHandler,
      callback: limitWebPayload(
        kWebBrowserScrollHandler,
        kWebPayloadTinyMaxChars,
        (List<dynamic> args) {
          if (!mounted || args.length < 2) return null;
          final Object? y = args[0];
          final Object? dy = args[1];
          if (y is num && dy is num) {
            widget.host.onContentScrolled(_tab, y: y.toInt(), dy: dy.toInt());
          }
          return null;
        },
      ),
    );
    controller.addJavaScriptHandler(
      handlerName: kWebBrowserFullscreenHandler,
      callback: limitWebPayload(
        kWebBrowserFullscreenHandler,
        kWebPayloadTinyMaxChars,
        (List<dynamic> args) {
          if (mounted && args.isNotEmpty && args.first is bool) {
            _setFullscreen(args.first as bool);
          }
          return null;
        },
      ),
    );
    controller.addJavaScriptHandler(
      handlerName: kWebBrowserContextMenuHandler,
      callback: limitWebPayload(
        kWebBrowserContextMenuHandler,
        kWebPayloadSmallMaxChars,
        (List<dynamic> args) {
          if (mounted && args.isNotEmpty) _onDesktopContextMenu(args.first);
          return null;
        },
      ),
    );
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _adblock?.onWebViewCreated(controller);
    _registerHandlers(controller);
    _windowConsumed = true;
    _controller = controller;
    _tab.attachController(controller);
    _tab.attachViewport(_viewportRectToGlobal);
    for (final WebBrowserFeature f in widget.host.features) {
      _guardFeature(
        f,
        'onWebViewCreated',
        () => f.onWebViewCreated(_tab, controller),
      );
    }
  }

  Widget _buildWebView(BuildContext context) {
    final Widget Function(BuildContext, WebBrowserTab)? stub =
        WebBrowserTabView.debugWebViewBuilder;
    if (stub != null) return stub(context, _tab);
    final WebAdblockWiring? adblock = _adblock;
    if (!_environmentReady || adblock == null) return const FushiLoadingView();
    final int? windowId = _windowConsumed ? null : _tab.windowId;
    final Uri? initial = windowId != null ? null : _tab.url;
    // 具名 Profile 挂在设置**实例**上（adblock 给的是副本），所以对真正交给
    // WebView 的这份再接一次。
    applyWebBrowserIncognito(adblock.settings, incognito: _tab.incognito);
    return KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        windowId: windowId,
        webViewEnvironment: _environment,
        initialUrlRequest: initial == null
            ? null
            : URLRequest(url: WebUri.uri(initial)),
        initialSettings: adblock.settings,
        initialUserScripts: UnmodifiableListView<UserScript>(
          _initialUserScripts(adblock),
        ),
        pullToRefreshController: _pullToRefresh,
        shouldInterceptRequest: adblock.shouldInterceptRequest,
        onWebViewCreated: _onWebViewCreated,
        onLoadStart: (InAppWebViewController _, WebUri? url) =>
            _onLoadStart(url),
        onLoadStop: (InAppWebViewController controller, WebUri? url) =>
            unawaited(_onLoadStop(controller, url)),
        onProgressChanged: (InAppWebViewController _, int progress) =>
            _tab.update(progress: progress / 100),
        onTitleChanged: (InAppWebViewController controller, String? title) {
          _tab.update(title: title);
          _recorder?.onTitleChanged(title);
        },
        onUpdateVisitedHistory:
            (InAppWebViewController controller, WebUri? url, bool? _) {
              adblock.onUpdateVisitedHistory(url);
              _recorder?.onUrlChanged(
                url == null ? null : Uri.tryParse(url.toString()),
              );
              unawaited(_syncNavigation(controller, url));
              final Uri? pageUrl = url == null
                  ? null
                  : Uri.tryParse(url.toString());
              for (final WebBrowserFeature f in widget.host.features) {
                try {
                  f.onUrlChanged(context, _tab, controller, pageUrl);
                } catch (e, s) {
                  ErrorLogService.instance.log(
                    'WebBrowserFeature(${f.id}).onUrlChanged',
                    e,
                    s,
                  );
                }
              }
            },
        onReceivedError:
            (
              InAppWebViewController _,
              WebResourceRequest request,
              WebResourceError error,
            ) => _onReceivedError(request, error),
        onReceivedHttpError:
            (
              InAppWebViewController _,
              WebResourceRequest request,
              WebResourceResponse response,
            ) {
              if (isWebBrowserHttpErrorCandidate(
                isForMainFrame: request.isForMainFrame ?? true,
                statusCode: response.statusCode,
              )) {
                _pendingHttpStatus = response.statusCode;
              }
            },
        onCreateWindow: (InAppWebViewController _, CreateWindowAction action) =>
            _onCreateWindow(action),
        onCloseWindow: (InAppWebViewController _) => widget.host.closeTab(_tab),
        onZoomScaleChanged:
            (InAppWebViewController _, double oldScale, double newScale) =>
                _onZoomScaleChanged(newScale),
        onEnterFullscreen: (InAppWebViewController _) => _setFullscreen(true),
        onExitFullscreen: (InAppWebViewController _) => _setFullscreen(false),
        onDownloadStartRequest:
            (InAppWebViewController _, DownloadStartRequest request) =>
                _onDownloadStart(request),
        onPermissionRequest:
            (InAppWebViewController _, PermissionRequest request) =>
                _onPermissionRequest(request),
        onGeolocationPermissionsShowPrompt:
            (InAppWebViewController _, String origin) =>
                _onGeolocationPrompt(origin),
        onLongPressHitTestResult:
            (
              InAppWebViewController controller,
              InAppWebViewHitTestResult result,
            ) => unawaited(_onLongPressHitTest(controller, result)),
        onWebContentProcessDidTerminate: (InAppWebViewController _) =>
            unawaited(_deathGuard.handleWebContentTerminated()),
        onRenderProcessGone:
            (InAppWebViewController _, RenderProcessGoneDetail detail) =>
                unawaited(
                  _deathGuard.handleDeath(
                    didCrash: detail.didCrash,
                    rendererPriorityAtExit: detail.rendererPriorityAtExit,
                  ),
                ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncActive();
    Widget view = KeyedSubtree(key: _webViewKey, child: _buildWebView(context));
    view = Listener(
      onPointerDown: (PointerDownEvent event) {
        _lastPointerDown = event.position;
        _fullscreenZoom.stop();
      },
      onPointerHover: hostOwnsWebViewHoverLookup ? _onHostHover : null,
      child: view,
    );
    return view;
  }
}

/// 打开下载好的文件：桌面交给系统默认程序；手机交给系统分享 / 「用其他应用打开」
/// 面板（Android 没有直接按路径打开文件的通道）。
Future<void> openWebBrowserDownloadedFile(String path) async {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    await FushiShare.shareFiles(<XFile>[XFile(path)]);
    return;
  }
  bool ok = false;
  try {
    ok = await launchUrl(Uri.file(path));
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('WebBrowser.openDownloadedFile', error, stack);
  }
  if (!ok && File(path).existsSync()) {
    FushiToast.show(
      msg: t.web_browser_open_external_failed,
      severity: ToastSeverity.error,
    );
  }
}
