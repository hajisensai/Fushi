import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart'
    show hostOwnsWebViewHoverLookup;
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/manga/web/web_comic_reader_launch.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/media/novel/web/web_novel_reader_launch.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/reader/reader_host_hover_lookup.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_list_tile.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// app 内通用浏览器（五端：Windows / macOS / Linux / Android / iOS）。
///
/// - 地址栏 + 后退 / 前进 / 刷新 + 站点书签（偏好 `web_browser_sites`）；
/// - **Fushi 查词**：复用复习卡面那一套（[SrsCardLookupHost] 弹窗栈 + 阅读器选区
///   脚本 [ReaderSelectionScripts] + 卡面取词监听 [kSrsCardLookupScript]）：点按
///   正文取词、Shift / 「悬停即查词」悬停取词，链接 / 按钮 / 表单上不取词，弹窗里
///   继续嵌套查、制卡。页头「点词查词」可临时关掉（浏览时点正文不弹窗）；
/// - **网页漫画**（附加动作）：「用 Fushi 阅读本章」扫当前页的漫画图交给漫画
///   阅读器。只在 [webComicReaderActionAvailable]（`onlineMangaSource` 合规门）
///   为真时出现——iOS 上浏览器照常可用，只是没有这项动作，也不预置漫画站；
/// - **网页小说**（附加动作）：「用 Fushi 阅读（小说）」把当前页整页 HTML 交给 Rust
///   提取正文、并进连载会话，预览确认后进书架并在阅读器打开（读到末尾自动拉下一章）。
///   只在 [webNovelReaderActionAvailable]（`onlineNovelSource` 合规门）为真时出现；
/// - **广告 / 跟踪拦截**：[applyAdblockTo]（Rust adblock 引擎，设置 › 系统里的
///   开关、订阅列表与白名单现读生效；iOS / macOS 的规则在 WebView 创建时固化）。
///
/// [navigation] 非 null 时由宿主 hub 提供页头标题位（子页页签），用
/// [FushiPageHeader.customTitle] 摆；null 时画自己的标题。
class FushiWebBrowserPage extends ConsumerStatefulWidget {
  const FushiWebBrowserPage({this.navigation, this.initialUrl, super.key});

  /// hub 的子页页签（占页头标题位）；null = 独立页面，画自己的标题。
  final Widget? navigation;

  /// 打开即加载的地址；null = 先显示站点书签。
  final String? initialUrl;

  /// 测试注入：widget 测试里没有平台视图。
  @visibleForTesting
  static Widget Function(BuildContext context)? debugWebViewBuilder;

  @override
  ConsumerState<FushiWebBrowserPage> createState() =>
      _FushiWebBrowserPageState();
}

class _FushiWebBrowserPageState extends ConsumerState<FushiWebBrowserPage>
    implements SrsCardLookupSurface {
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'fushi-web-browser',
  );
  final GlobalKey _webViewKey = GlobalKey(debugLabel: 'fushi-web-browser');
  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode(debugLabel: 'web-browser-address');

  /// 页内取词：与复习卡面同一套控制器 / 宿主。设置现读，「点词查词」开关即时生效。
  late final SrsCardLookupController _lookup = SrsCardLookupController(
    settings: () {
      final SrsCardLookupSettings reader = srsCardLookupSettingsFromReader();
      return (
        tap: _lookupEnabled,
        hoverAuto: _lookupEnabled && reader.hoverAuto,
      );
    },
  );
  final ReaderHostHoverLookupGate _hostHover = ReaderHostHoverLookupGate();
  static final String _lookupInstallScript = srsCardLookupInstallScript(
    ReaderSelectionScripts.source(),
  );
  bool _lookupEnabled = true;

  /// 网页漫画扫图（合规门关时为 null，整条能力不装）。
  final WebComicScanDriver? _scanDriver = webComicReaderActionAvailable()
      ? WebComicScanDriver()
      : null;
  bool _scanning = false;

  /// 网页小说动作（合规门关时整条能力不装）。
  final bool _novelAvailable = webNovelReaderActionAvailable();
  bool _extractingNovel = false;

  /// 广告拦截接线：环境就绪时建一次，WebView 重建（死亡守卫）也沿用同一份，
  /// 让 cosmetic 的 JS handler 与按 href 记的例外集始终是同一个对象。
  WebAdblockWiring? _adblock;

  bool _environmentReady = false;
  WebViewEnvironment? _environment;
  InAppWebViewController? _controller;
  bool _canGoBack = false;
  bool _canGoForward = false;
  Uri? _currentUrl;
  String _pageTitle = '';

  /// 第一次打开地址前 WebView 不建（站点书签页不必背一个空白平台视图）。
  Uri? _pendingUrl;
  bool _webViewCreated = false;
  bool _showSites = true;
  late List<WebBrowserSite> _sites;

  AppModel get _appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _sites = parseWebBrowserSites(
      _appModel.prefsRepo.webBrowserSitesJson,
      presets: webBrowserPresetSites(
        mangaAvailable: webComicReaderActionAvailable(),
      ),
    );
    final Uri? initial = widget.initialUrl == null
        ? null
        : parseWebBrowserAddress(widget.initialUrl!);
    if (initial != null) {
      _pendingUrl = initial;
      _showSites = false;
      _webViewCreated = true;
      _address.text = initial.toString();
    }
    _lookup.register(this);
    unawaited(_prepareEnvironment());
  }

  @override
  void dispose() {
    _lookup.unregister(this);
    _lookup.dispose();
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
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
    final WebAdblockService adblock = ref.read(webAdblockServiceProvider);
    final WebAdblockNetworkMode mode = currentWebAdblockNetworkMode;
    final Future<void> loading = adblock.ensureLoaded().catchError((
      Object e,
      StackTrace s,
    ) {
      ErrorLogService.instance.log('FushiWebBrowserPage.adblockLoad', e, s);
    });
    // contentBlockers 平台（iOS / macOS）的规则在 WebView 创建时固化：等引擎就绪
    // 再建，否则这一页整页不拦。逐请求平台每次请求现读策略，后台加载即可，不让
    // 首次下载订阅列表卡住页面。
    if (mode == WebAdblockNetworkMode.contentBlockers) await loading;
    if (!mounted) return;
    setState(() {
      _environment = environment;
      _adblock = applyAdblockTo(
        InAppWebViewSettings(
          javaScriptEnabled: true,
          sharedCookiesEnabled: true,
        ),
        policy: adblock,
        mode: mode,
      );
      _environmentReady = true;
    });
  }

  // ── 导航 ───────────────────────────────────────────────────────────

  void _openAddress(String input) {
    final Uri? url = parseWebBrowserAddress(input);
    if (url == null) {
      FushiToast.show(
        msg: t.web_browser_address_invalid,
        severity: ToastSeverity.warning,
      );
      return;
    }
    _open(url);
  }

  void _open(Uri url) {
    _addressFocus.unfocus();
    _address.text = url.toString();
    final InAppWebViewController? controller = _controller;
    setState(() {
      _showSites = false;
      _webViewCreated = true;
      if (controller == null) _pendingUrl = url;
    });
    if (controller != null) {
      unawaited(
        controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url))),
      );
    }
  }

  Future<void> _syncNavigation(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    bool back = false;
    bool forward = false;
    String title = '';
    try {
      back = await controller.canGoBack();
      forward = await controller.canGoForward();
      title = await controller.getTitle() ?? '';
    } on Object {
      // 平台实现没给（或 WebView 已销毁）：按钮保持禁用即可。
    }
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
      _pageTitle = title;
      if (url != null) {
        _currentUrl = url;
        if (!_addressFocus.hasFocus) _address.text = url.toString();
      }
    });
  }

  Future<void> _onBackInvoked() async {
    final InAppWebViewController? controller = _controller;
    if (!_showSites && controller != null && _canGoBack) {
      await controller.goBack();
      return;
    }
    if (!_showSites && _webViewCreated) {
      setState(() => _showSites = true);
      return;
    }
    if (mounted) await Navigator.of(context).maybePop();
  }

  // ── 站点书签 ─────────────────────────────────────────────────────────

  Future<void> _saveSites(List<WebBrowserSite> sites) async {
    setState(() => _sites = sites);
    await _appModel.prefsRepo.setWebBrowserSitesJson(
      encodeWebBrowserSites(sites),
    );
  }

  Future<void> _addCurrentSite() async {
    final Uri? url = _currentUrl;
    if (url == null) return;
    final String name = _pageTitle.trim().isEmpty ? url.host : _pageTitle;
    await _saveSites(
      addWebBrowserSite(_sites, WebBrowserSite(name: name, url: url)),
    );
    FushiToast.show(
      msg: t.web_browser_site_added,
      severity: ToastSeverity.success,
    );
  }

  // ── 网页漫画 ─────────────────────────────────────────────────────────

  Future<void> _readChapterInFushi() async {
    final WebComicScanDriver? driver = _scanDriver;
    final InAppWebViewController? controller = _controller;
    final Uri? url = _currentUrl;
    if (driver == null || controller == null || url == null || _scanning) {
      return;
    }
    setState(() => _scanning = true);
    FushiToast.show(msg: t.manga_web_scan_running);
    try {
      final WebComicScanResult scan = await driver.scan(
        controller,
        pageUrl: url,
      );
      if (!mounted) return;
      if (scan.isEmpty) {
        FushiToast.show(
          msg: t.manga_web_scan_empty,
          severity: ToastSeverity.warning,
        );
        return;
      }
      await openWebComicScanInReader(context: context, ref: ref, scan: scan);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'FushiWebBrowserPage.readChapter',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(
          msg: t.manga_web_scan_failed,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  // ── 网页小说 ─────────────────────────────────────────────────────────

  Future<void> _readNovelInFushi() async {
    final InAppWebViewController? controller = _controller;
    final Uri? url = _currentUrl;
    if (!_novelAvailable ||
        controller == null ||
        url == null ||
        _extractingNovel) {
      return;
    }
    setState(() => _extractingNovel = true);
    FushiToast.show(msg: t.novel_web_extract_running);
    try {
      await readWebNovelPageInFushi(
        context: context,
        ref: ref,
        controller: controller,
        pageUrl: url,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'FushiWebBrowserPage.readNovel',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(
          msg: t.novel_web_extract_failed(error: '$error'),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _extractingNovel = false);
    }
  }

  Future<void> _toggleAdFilter() async {
    final bool next = !_appModel.prefsRepo.webComicAdFilter;
    await _appModel.prefsRepo.setWebComicAdFilter(next);
    if (mounted) setState(() {});
  }

  // ── 查词 ─────────────────────────────────────────────────────────────

  Future<void> _evaluateQuiet(String source) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: source);
    } on Object {
      // 平台视图半销毁 / 页面正在跳转：取词失败 no-op。
    }
  }

  String _lookupGateScript() {
    final SrsCardLookupSettings settings = _lookup.settings;
    return srsCardLookupGateScript(
      tap: settings.tap,
      hover: settings.hoverAuto,
      hostHover: hostOwnsWebViewHoverLookup,
      open: _lookup.isOpen,
    );
  }

  /// 每个新文档（onLoadStop）装一次取词脚本（脚本自带幂等守卫）并下发门控。
  Future<void> _installLookup(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: _lookupInstallScript);
      await controller.evaluateJavascript(source: _lookupGateScript());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'FushiWebBrowserPage.installLookup',
        error,
        stack,
      );
    }
  }

  void _toggleLookup() {
    setState(() => _lookupEnabled = !_lookupEnabled);
    if (!_lookupEnabled) _lookup.closeAll();
    unawaited(_evaluateQuiet(_lookupGateScript()));
  }

  RenderBox? get _webViewBox {
    final RenderObject? r = _webViewKey.currentContext?.findRenderObject();
    return r is RenderBox && r.attached && r.hasSize ? r : null;
  }

  void _onTextSelected(Object? raw) {
    final RenderBox? box = _webViewBox;
    if (box == null || raw is! String || !_lookupEnabled) return;
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
    _lookup.lookup(
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
    if (_controller == null || box == null || !mounted || _showSites) {
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
    if (!_lookupEnabled || _lookup.isOpen) return;
    if (!_hostHover.shouldLookup(
      event.localPosition,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      hoverAutoLookup: _lookup.settings.hoverAuto,
    )) {
      return;
    }
    lookupAt(event.position, fromHover: true);
  }

  // ── 构建 ─────────────────────────────────────────────────────────────

  List<FushiToolbarItem> _navigationItems() {
    final InAppWebViewController? controller = _controller;
    final bool web = !_showSites && controller != null;
    return <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('web-browser-back'),
        icon: FushiIcons.back,
        label: t.back,
        onPressed: web && _canGoBack
            ? () => unawaited(controller.goBack())
            : null,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('web-browser-forward'),
        icon: FushiIcons.forward,
        label: t.web_browser_forward,
        onPressed: web && _canGoForward
            ? () => unawaited(controller.goForward())
            : null,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('web-browser-reload'),
        icon: FushiIcons.refresh,
        label: t.refresh,
        onPressed: web ? () => unawaited(controller.reload()) : null,
      ),
    ];
  }

  List<List<FushiToolbarItem>> _actionGroups() {
    final bool web = !_showSites && _controller != null;
    return <List<FushiToolbarItem>>[
      // 小说动作排最前：动作按给出顺序定优先级，宽度不够时它最后收进「⋯」。
      if (_novelAvailable)
        <FushiToolbarItem>[
          FushiToolbarItem(
            key: const ValueKey<String>('web-browser-read-novel'),
            icon: FushiIcons.books,
            label: t.novel_web_read_page,
            selected: _extractingNovel,
            onPressed: web && _currentUrl != null && !_extractingNovel
                ? () => unawaited(_readNovelInFushi())
                : null,
          ),
        ],
      <FushiToolbarItem>[
        FushiToolbarItem(
          key: const ValueKey<String>('web-browser-lookup'),
          icon: FushiIcons.readerMode,
          label: _lookupEnabled
              ? t.web_browser_lookup_on
              : t.web_browser_lookup_off,
          selected: _lookupEnabled,
          onPressed: _toggleLookup,
        ),
        FushiToolbarItem(
          key: const ValueKey<String>('web-browser-sites'),
          icon: FushiIcons.bookmarks,
          label: t.web_browser_sites_title,
          selected: _showSites,
          onPressed: () => setState(() => _showSites = !_showSites),
        ),
        FushiToolbarItem(
          key: const ValueKey<String>('web-browser-site-add'),
          icon: FushiIcons.bookmarkAdd,
          label: t.web_browser_site_add,
          onPressed: web && _currentUrl != null
              ? () => unawaited(_addCurrentSite())
              : null,
        ),
      ],
    ];
  }

  List<FushiToolbarItem> _menuItems() => <FushiToolbarItem>[
    if (_scanDriver != null)
      FushiToolbarItem(
        key: const ValueKey<String>('web-browser-ad-filter'),
        icon: FushiIcons.webAssetOff,
        label: _appModel.prefsRepo.webComicAdFilter
            ? t.manga_web_ad_filter_on
            : t.manga_web_ad_filter_off,
        onPressed: () => unawaited(_toggleAdFilter()),
      ),
  ];

  Widget _buildChromeBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiTextField(
            key: const ValueKey<String>('web-browser-address'),
            controller: _address,
            focusNode: _addressFocus,
            hintText: t.web_browser_address_hint,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            prefixIcon: const FushiIcon(FushiIcons.globe),
            onSubmitted: _openAddress,
          ),
          SizedBox(height: tokens.spacing.gap),
          // 动作默认全部平铺，宽度不够才按优先级收进「⋯」（adaptiveOverflow）。
          FushiFloatingTopBar(
            title: _showSites ? t.web_browser_sites_title : _pageTitle,
            leading: _navigationItems(),
            actions: _actionGroups(),
            menu: _menuItems(),
          ),
        ],
      ),
    );
  }

  Widget _buildSites(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_sites.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.web_browser_sites_empty,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return FushiEntranceScope(
      replayKey: _sites.length,
      child: ListView.builder(
        key: const ValueKey<String>('web-browser-site-list'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: _sites.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final WebBrowserSite site = _sites[i];
          return FushiPressScale(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: FushiListTile(
                    key: ValueKey<String>('web-browser-site-${site.url}'),
                    title: site.name,
                    subtitle: site.url.host,
                    icon: FushiIcons.globe,
                    selected: false,
                    onTap: () => _open(site.url),
                  ),
                ),
                FushiIconButton(
                  icon: FushiIcons.delete,
                  tooltip: t.web_browser_site_remove,
                  onTap: () =>
                      unawaited(_saveSites(removeWebBrowserSite(_sites, site))),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildWebView(BuildContext context) {
    final Widget Function(BuildContext context)? stub =
        FushiWebBrowserPage.debugWebViewBuilder;
    if (stub != null) return stub(context);
    final WebAdblockWiring? adblock = _adblock;
    if (!_environmentReady || adblock == null) return const FushiLoadingView();
    final Uri? initial = _pendingUrl;
    final Widget webView = KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        key: _webViewKey,
        webViewEnvironment: _environment,
        initialUrlRequest: initial == null
            ? null
            : URLRequest(url: WebUri.uri(initial)),
        initialSettings: adblock.settings,
        initialUserScripts: UnmodifiableListView<UserScript>(
          adblock.userScripts,
        ),
        shouldInterceptRequest: adblock.shouldInterceptRequest,
        onLoadStart: (InAppWebViewController _, WebUri? url) =>
            adblock.onLoadStart(url),
        onWebViewCreated: (InAppWebViewController controller) {
          adblock.onWebViewCreated(controller);
          controller.addJavaScriptHandler(
            handlerName: 'onTextSelected',
            callback: (List<dynamic> arguments) {
              if (mounted && arguments.isNotEmpty) {
                _onTextSelected(arguments.first);
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'onTapEmpty',
            callback: (List<dynamic> _) => null,
          );
          _scanDriver?.attach(controller);
          if (mounted) {
            setState(() {
              _controller = controller;
              _pendingUrl = null;
            });
          }
        },
        onLoadStop: (InAppWebViewController controller, WebUri? url) {
          unawaited(_syncNavigation(controller, url));
          unawaited(_installLookup(controller));
        },
        onTitleChanged: (InAppWebViewController controller, String? _) =>
            unawaited(_syncNavigation(controller, null)),
        onUpdateVisitedHistory:
            (InAppWebViewController controller, WebUri? url, bool? _) {
              adblock.onUpdateVisitedHistory(url);
              unawaited(_syncNavigation(controller, url));
            },
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
    if (!hostOwnsWebViewHoverLookup) return webView;
    return Listener(onPointerHover: _onHostHover, child: webView);
  }

  Widget _buildBody(BuildContext context) {
    return Column(
      children: <Widget>[
        _buildChromeBar(context),
        Expanded(
          child: Stack(
            children: <Widget>[
              // WebView 建过就一直挂着（切去站点书签再回来不丢页面与历史）。
              if (_webViewCreated)
                Positioned.fill(
                  child: Offstage(
                    offstage: _showSites,
                    child: _buildWebView(context),
                  ),
                ),
              if (_showSites) Positioned.fill(child: _buildSites(context)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = widget.navigation;
    final bool canRead =
        _scanDriver != null && !_showSites && _controller != null;
    return PopScope(
      canPop: _showSites || !_webViewCreated,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) unawaited(_onBackInvoked());
      },
      child: SrsCardLookupHost(
        controller: _lookup,
        child: FushiPageScaffold(
          title: t.web_browser_title,
          header: navigation == null
              ? null
              : FushiPageHeader.customTitle(title: navigation),
          // 正文是平台 WebView，内容在 WebView 内部滚动、拿不到页头让位：不叠放。
          extendBodyBehindHeader: false,
          floatingActionButton: canRead
              ? FushiFab(
                  key: const ValueKey<String>('web-browser-read-in-fushi'),
                  icon: _scanning
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const FushiIcon(FushiIcons.manga),
                  label: Text(t.manga_web_read_chapter),
                  tooltip: t.manga_web_read_chapter,
                  onPressed: _scanning
                      ? null
                      : () => unawaited(_readChapterInFushi()),
                )
              : null,
          body: _buildBody(context),
        ),
      ),
    );
  }
}

/// 推一页独立的 [FushiWebBrowserPage]（宿主 hub 挂载时直接把 widget 放进页签，
/// 不经这里）。路由层中和界面整体缩放：WebView 纹理按原生密度栅格化（BUG-2522），
/// 取词矩形与查词浮层同一坐标系。
Future<void> openFushiWebBrowser(BuildContext context, {String? initialUrl}) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => FushiAppUiScaleNeutralizer(
          child: FushiWebBrowserPage(initialUrl: initialUrl),
        ),
      ),
    );
