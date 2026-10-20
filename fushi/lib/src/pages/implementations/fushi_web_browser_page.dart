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
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_adblock/web_adblock_capability.dart';
import 'package:fushi/src/web_adblock/web_adblock_service.dart';
import 'package:fushi/src/web_adblock/web_adblock_wiring.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/src/webview/web_payload_limits.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';

/// 站点书签（偏好 `web_browser_sites`），入口页与浏览页共用同一份解析。
List<WebBrowserSite> _loadWebBrowserSites(AppModel appModel) =>
    parseWebBrowserSites(
      appModel.prefsRepo.webBrowserSitesJson,
      presets: webBrowserPresetSites(
        mangaAvailable: webComicReaderActionAvailable(),
      ),
    );

/// 浏览页上按一次「返回」（Android 系统返回 / iOS 侧滑 / 桌面 Esc）该做的那一步。
enum WebBrowserBackStep {
  /// 关掉最上面一层查词弹窗（弹窗栈在本页路由之内，没有自己的 PopScope）。
  closeLookup,

  /// 退一步网页历史。
  webHistoryBack,

  /// 离开浏览页（放行路由 pop）。
  leavePage,
}

/// 返回的优先级：查词弹窗 → 网页历史 → 离开浏览页。弹窗开着时若直接退网页历史
/// （或没有历史时整页 pop），弹窗会留在已经换掉的网页上 / 随浏览页一起被关掉。
@visibleForTesting
WebBrowserBackStep webBrowserBackStep({
  required bool lookupOpen,
  required bool canGoBack,
}) {
  if (lookupOpen) return WebBrowserBackStep.closeLookup;
  if (canGoBack) return WebBrowserBackStep.webHistoryBack;
  return WebBrowserBackStep.leavePage;
}

/// 浏览页 chrome（地址栏 + 工具栏）摆在哪。
enum WebBrowserChromeLayout {
  /// 桌面：顶部整行地址栏 + 底部居中悬浮工具栏。
  desktop,

  /// 手机竖屏：地址栏与工具栏都收在底部（拇指区），顶部只留状态栏。
  mobileBottom,

  /// 手机横屏：地址栏与工具栏并成顶部一行，竖向空间全让给网页。
  mobileTop,
}

/// 移动端（Android / iOS）按方向分：竖屏都放底部、横屏都放顶部（用户
/// 2026-10-20）；桌面维持顶部地址栏 + 底部工具栏。
@visibleForTesting
WebBrowserChromeLayout webBrowserChromeLayout({
  required TargetPlatform platform,
  required Size size,
}) {
  final bool mobile =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  if (!mobile) return WebBrowserChromeLayout.desktop;
  return size.width > size.height
      ? WebBrowserChromeLayout.mobileTop
      : WebBrowserChromeLayout.mobileBottom;
}

/// 手机横屏顶部一行里地址栏至少留的宽度；工具栏只拿剩下的，放不下的收进「⋯」。
const double _kMobileTopAddressMinWidth = 240;

/// 推出全屏浏览页（[FushiWebBrowserPage]）。它是独立子页：盖住首页外壳的主导航
/// 底栏 / 侧栏，网页独占整屏，退出回到入口页。
Future<void> openFushiWebBrowser(BuildContext context, Uri url) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext _) =>
            FushiWebBrowserPage(initialUrl: url.toString()),
      ),
    );

/// 「浏览器」模块里通用浏览子页的入口：地址栏 + 站点网格。
///
/// 只是入口，不挂 WebView：打开任何地址都推全屏的 [FushiWebBrowserPage]（用户
/// 2026-10-19「这个页面应该是独立的子页面，底栏不应该再继续原样显示」——旧版把
/// WebView 嵌在模块页里，底栏与「阅读本章」FAB 叠在网页上互相遮挡）。
///
/// [navigation] 非 null 时由宿主 hub 提供页头主位（子页页签）；null（手机上本模块
/// 只有这一个子页）时 MD3 不画页头——模块名已在底部导航上，地址栏就是顶部锚点；
/// Apple 保留 iOS 根页的左对齐大标题。
class FushiWebBrowserHomePage extends ConsumerStatefulWidget {
  const FushiWebBrowserHomePage({this.navigation, super.key});

  /// hub 的子页页签（占页头主位）；null = 本模块只有这一个子页。
  final Widget? navigation;

  @override
  ConsumerState<FushiWebBrowserHomePage> createState() =>
      _FushiWebBrowserHomePageState();
}

class _FushiWebBrowserHomePageState
    extends ConsumerState<FushiWebBrowserHomePage> {
  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode(debugLabel: 'web-browser-address');
  late List<WebBrowserSite> _sites;

  AppModel get _appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _sites = _loadWebBrowserSites(_appModel);
  }

  @override
  void dispose() {
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _openAddress(String input) {
    final Uri? url = parseWebBrowserAddress(input);
    if (url == null) {
      FushiToast.show(
        msg: t.web_browser_address_invalid,
        severity: ToastSeverity.warning,
      );
      return;
    }
    unawaited(_open(url));
  }

  Future<void> _open(Uri url) async {
    _addressFocus.unfocus();
    _address.clear();
    await openFushiWebBrowser(context, url);
    // 浏览页里可能「加入站点」了：回来时按偏好重读。
    if (mounted) setState(() => _sites = _loadWebBrowserSites(_appModel));
  }

  Future<void> _removeSite(WebBrowserSite site) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.web_browser_site_remove,
      message: site.name,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final List<WebBrowserSite> next = removeWebBrowserSite(_sites, site);
    setState(() => _sites = next);
    await _appModel.prefsRepo.setWebBrowserSitesJson(
      encodeWebBrowserSites(next),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    return FushiSearchField(
      fieldKey: const ValueKey<String>('web-browser-address'),
      controller: _address,
      focusNode: _addressFocus,
      hintText: t.web_browser_address_hint,
      keyboardType: TextInputType.url,
      leading: const FushiSearchLeading(child: FushiIcon(FushiIcons.globe)),
      size: FushiSearchFieldSize.large,
      onClear: _address.clear,
      onChanged: (String _) {},
      onSubmitted: _openAddress,
    );
  }

  Widget _buildSiteTile(BuildContext context, WebBrowserSite site) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final String trimmed = site.name.trim();
    final String name = trimmed.isEmpty ? site.url.host : trimmed;
    final String initial = name.characters.first.toUpperCase();
    return FushiCard(
      key: ValueKey<String>('web-browser-site-${site.url}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      onTap: () => unawaited(_open(site.url)),
      onLongPress: () => unawaited(_removeSite(site)),
      onSecondaryTap: () => unawaited(_removeSite(site)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 站点头像：首字母落在 tonal 圆里（Apple 用强调色淡底）。不取网站
          // favicon——入口页不为几个字节去联网。
          CircleAvatar(
            radius: 20,
            backgroundColor: glass
                ? appleColorsOf(context).accent.withValues(alpha: 0.16)
                : theme.colorScheme.secondaryContainer,
            foregroundColor: glass
                ? appleColorsOf(context).accent
                : theme.colorScheme.onSecondaryContainer,
            child: Text(
              initial,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Spacer(),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listTitle,
          ),
          const SizedBox(height: 2),
          Text(
            site.url.host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listSubtitle,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    // 正文从窗口顶端画起（脚手架默认叠放页头）：顶部让出「状态栏 + 页头」。
    final double top = MediaQuery.paddingOf(context).top;
    return CustomScrollView(
      key: const ValueKey<String>('web-browser-site-list'),
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(page, top + tokens.spacing.gap, page, 0),
          sliver: SliverToBoxAdapter(child: _buildAddressBar(context)),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            page,
            page + 4,
            page,
            tokens.spacing.gap,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              t.web_browser_sites_title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: isGlassDesign(context)
                    ? appleColorsOf(context).secondaryLabel
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (_sites.isEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: page, vertical: 24),
            sliver: SliverToBoxAdapter(
              child: Text(
                t.web_browser_sites_empty,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(page, 0, page, page),
            ),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisExtent: 116,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                fushiStaggeredItemBuilder(
                  (BuildContext context, int i) =>
                      _buildSiteTile(context, _sites[i]),
                ),
                childCount: _sites.length,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = widget.navigation;
    return FushiPageScaffold(
      title: t.web_browser_title,
      headerTitle: navigation,
      // 只有这一个子页时：MD3 整条页头不画（见类注释），Apple 走默认大标题。
      header: navigation == null && !isGlassDesign(context)
          ? const SizedBox.shrink()
          : null,
      body: FushiEntranceScope(
        replayKey: _sites.length,
        child: _buildBody(context),
      ),
    );
  }
}

/// app 内通用浏览器的全屏浏览页（五端：Windows / macOS / Linux / Android / iOS），
/// 由入口页 [FushiWebBrowserHomePage] 经 [openFushiWebBrowser] 推出。
///
/// 版面（两套设计系统同构，组件各自分派）：地址栏（M3E search bar / iOS 搜索
/// 胶囊，左侧 ✕ 退出浏览页，尾部刷新）+ 悬浮工具栏（纯图标，文字进 tooltip /
/// 语义）+ 网页漫画的「用 Fushi 阅读本章」FAB，摆放见 [webBrowserChromeLayout]：
/// 桌面顶部地址栏、底部工具栏；手机竖屏两者都在底部（紧凑档）；手机横屏并成顶部
/// 一行。工具栏默认全部平铺，宽度不够才按优先级把低优先级的收进「⋯」。
///
/// - **Fushi 查词**：复用复习卡面那一套（[SrsCardLookupHost] 弹窗栈 + 阅读器选区
///   脚本 [ReaderSelectionScripts] + 卡面取词监听 [kSrsCardLookupScript]）：点按
///   正文取词、Shift / 「悬停即查词」悬停取词，链接 / 按钮 / 表单上不取词，弹窗里
///   继续嵌套查、制卡。工具栏「点词查词」可临时关掉（浏览时点正文不弹窗）；
/// - **网页漫画**（附加动作）：「用 Fushi 阅读本章」扫当前页的漫画图交给漫画
///   阅读器。只在 [webComicReaderActionAvailable]（`onlineMangaSource` 合规门）
///   为真时出现——iOS 上浏览器照常可用，只是没有这项动作，也不预置漫画站；
/// - **网页小说**（附加动作）：「用 Fushi 阅读（小说）」把当前页整页 HTML 交给 Rust
///   提取正文、并进连载会话，预览确认后进书架并在阅读器打开（读到末尾自动拉下一章）。
///   只在 [webNovelReaderActionAvailable]（`onlineNovelSource` 合规门）为真时出现；
/// - **广告 / 跟踪拦截**：[applyAdblockTo]（Rust adblock 引擎，设置 › 系统里的
///   开关、订阅列表与白名单现读生效；iOS / macOS 的规则在 WebView 创建时固化）。
///
/// 系统返回 / 侧滑先退网页历史，退到头才离开浏览页；左上 ✕ 直接离开。
class FushiWebBrowserPage extends ConsumerStatefulWidget {
  const FushiWebBrowserPage({required this.initialUrl, super.key});

  /// 打开即加载的地址（地址栏的输入规则，见 [parseWebBrowserAddress]）。
  final String initialUrl;

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
  final FocusNode _addressFocus = FocusNode(
    debugLabel: 'web-browser-page-address',
  );

  /// 底部工具栏「放不下才收进 ⋯」的平铺颗数决策（与顶栏共用同一套测宽）。
  final FushiTopBarOverflowFit _toolbarFit = FushiTopBarOverflowFit();

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

  /// WebView 首次创建时加载的地址；创建后清空（之后的导航都走控制器）。
  Uri? _pendingUrl;
  late List<WebBrowserSite> _sites;

  AppModel get _appModel => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    _sites = _loadWebBrowserSites(_appModel);
    final Uri? initial = parseWebBrowserAddress(widget.initialUrl);
    _pendingUrl = initial;
    _currentUrl = initial;
    _address.text = initial?.toString() ?? widget.initialUrl;
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
    _addressFocus.unfocus();
    _address.text = url.toString();
    final InAppWebViewController? controller = _controller;
    if (controller == null) {
      setState(() => _pendingUrl = url);
      return;
    }
    unawaited(controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url))));
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

  /// 左上 ✕：不经网页历史，直接离开浏览页（[Navigator.pop] 不受 [PopScope] 拦）。
  void _close() => Navigator.of(context).pop();

  /// 返回被 [PopScope] 拦下时的那一步（判据见 [webBrowserBackStep]）。
  void _onBackBlocked() {
    switch (webBrowserBackStep(
      lookupOpen: _lookup.isOpen,
      canGoBack: _canGoBack,
    )) {
      case WebBrowserBackStep.closeLookup:
        // 搜索期占位没有可见层时 closeTop 返回 false：整栈关掉，别让返回键落空。
        if (!_lookup.closeTop()) _lookup.closeAll();
      case WebBrowserBackStep.webHistoryBack:
        final InAppWebViewController? controller = _controller;
        if (controller != null) unawaited(controller.goBack());
      case WebBrowserBackStep.leavePage:
        break;
    }
  }

  // ── 站点书签 ─────────────────────────────────────────────────────────

  Future<void> _addCurrentSite() async {
    final Uri? url = _currentUrl;
    if (url == null) return;
    final String name = _pageTitle.trim().isEmpty ? url.host : _pageTitle;
    _sites = addWebBrowserSite(_sites, WebBrowserSite(name: name, url: url));
    await _appModel.prefsRepo.setWebBrowserSitesJson(
      encodeWebBrowserSites(_sites),
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
    if (_controller == null || box == null || !mounted) return false;
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

  /// 底部工具栏的动作，按优先级从高到低（宽度不够时从末尾起收进「⋯」）。
  List<FushiToolbarItem> _toolbarItems() {
    final InAppWebViewController? controller = _controller;
    return <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('web-browser-back'),
        icon: FushiIcons.back,
        label: t.back,
        onPressed: controller != null && _canGoBack
            ? () => unawaited(controller.goBack())
            : null,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('web-browser-forward'),
        icon: FushiIcons.forward,
        label: t.web_browser_forward,
        onPressed: controller != null && _canGoForward
            ? () => unawaited(controller.goForward())
            : null,
      ),
      if (_novelAvailable)
        FushiToolbarItem(
          key: const ValueKey<String>('web-browser-read-novel'),
          icon: FushiIcons.books,
          label: t.novel_web_page_read,
          selected: _extractingNovel,
          onPressed: controller != null && _currentUrl != null
              ? (_extractingNovel ? null : () => unawaited(_readNovelInFushi()))
              : null,
        ),
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
        key: const ValueKey<String>('web-browser-site-add'),
        icon: FushiIcons.bookmarkAdd,
        label: t.web_browser_site_add,
        onPressed: controller != null && _currentUrl != null
            ? () => unawaited(_addCurrentSite())
            : null,
      ),
    ];
  }

  /// 恒在「⋯」里的低频开关。
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

  /// 地址栏：左侧 ✕ 退出浏览页，尾部刷新。[compact] = 手机上的 40 高胶囊
  /// （桌面是 56 高的独立搜索栏）。
  Widget _buildAddressField(BuildContext context, {required bool compact}) {
    final InAppWebViewController? controller = _controller;
    final double? iconSize = compact ? kFushiSearchFieldIconSize : null;
    final EdgeInsets? iconPadding = compact ? const EdgeInsets.all(4) : null;
    return FushiSearchField(
      fieldKey: const ValueKey<String>('web-browser-address'),
      controller: _address,
      focusNode: _addressFocus,
      hintText: t.web_browser_address_hint,
      keyboardType: TextInputType.url,
      size: compact ? FushiSearchFieldSize.regular : FushiSearchFieldSize.large,
      leading: FushiSearchLeading(
        child: FushiIconButton(
          key: const ValueKey<String>('web-browser-close'),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: FushiIcons.close,
          size: iconSize,
          padding: iconPadding,
          onTap: _close,
        ),
      ),
      trailing: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('web-browser-reload'),
          tooltip: t.refresh,
          icon: FushiIcons.refresh,
          size: iconSize,
          padding: iconPadding,
          onTap: controller == null
              ? null
              : () => unawaited(controller.reload()),
        ),
      ],
      onChanged: (String _) {},
      onSubmitted: _openAddress,
    );
  }

  /// 桌面：顶部整行地址栏。
  Widget _buildDesktopHeader(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: _buildAddressField(context, compact: false),
    );
  }

  /// 底部 chrome：桌面只有居中工具栏；手机竖屏是「地址栏 / 工具栏」两行紧凑档。
  /// 整块落在网页下方的页面底色上，不叠在网页上——WebView 内容拿不到底部让位，
  /// 叠上去末尾那段永远被挡。
  Widget _buildBottomBar(BuildContext context, {required bool withAddress}) {
    final double side = withAddress
        ? FushiDesignTokens.of(context).spacing.gap
        : kFushiFloatingToolbarEdgeMargin;
    return Padding(
      padding: withBottomSafeInset(
        context,
        withAddress
            ? EdgeInsets.fromLTRB(side, 4, side, 4)
            : EdgeInsets.fromLTRB(side, 8, side, 12),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Widget toolbar = Center(
            child: _buildToolbar(budget: box.maxWidth, compact: withAddress),
          );
          if (!withAddress) return toolbar;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildAddressField(context, compact: true),
              const SizedBox(height: 4),
              toolbar,
            ],
          );
        },
      ),
    );
  }

  /// 手机横屏：地址栏与工具栏并成顶部一行，地址栏吃剩余宽度。
  Widget _buildMobileTopBar(BuildContext context) {
    final double side = FushiDesignTokens.of(context).spacing.gap;
    return Padding(
      padding: EdgeInsets.fromLTRB(side, 4, side, 4),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) => Row(
          children: <Widget>[
            Expanded(child: _buildAddressField(context, compact: true)),
            SizedBox(width: side),
            _buildToolbar(
              budget: box.maxWidth - _kMobileTopAddressMinWidth - side,
              compact: true,
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮工具栏 + 「阅读本章」FAB，在 [budget] 宽度里能平铺几颗就平铺几颗。
  Widget _buildToolbar({required double budget, required bool compact}) {
    final bool canRead = _scanDriver != null && _controller != null;
    final Widget? fab = canRead
        ? FushiToolbarFab(
            key: const ValueKey<String>('web-browser-read-in-fushi'),
            icon: FushiIcons.manga,
            tooltip: t.manga_web_chapter_read,
            onPressed: _scanning
                ? null
                : () => unawaited(_readChapterInFushi()),
          )
        : null;
    final List<FushiToolbarItem> items = _toolbarItems();
    final List<FushiToolbarItem> menu = _menuItems();
    final int visible = _toolbarFit.visibleFor(
      groups: <List<FushiToolbarItem>>[items],
      budget: budget - (fab == null ? 0 : 56 + kFushiFloatingToolbarFabGap),
      pinnedMenu: menu.isNotEmpty,
      padding: 2 * (compact ? 4 : kFushiFloatingToolbarPadding),
    );
    final ({
      List<List<FushiToolbarItem>> groups,
      List<FushiToolbarItem> overflow,
    })
    split = fushiTopBarSplitActions(
      <List<FushiToolbarItem>>[items],
      const <FushiToolbarItem>[],
      visible,
    );
    return FushiFloatingToolbar(
      key: const ValueKey<String>('web-browser-toolbar'),
      // 一组：悬浮工具栏不画组间分隔线。
      groups: <List<FushiToolbarItem>>[
        <FushiToolbarItem>[
          for (final List<FushiToolbarItem> g in split.groups) ...g,
        ],
      ],
      overflow: <FushiToolbarItem>[...split.overflow, ...menu],
      fab: fab,
      compact: compact,
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
            callback: limitWebPayload(
              'onTextSelected',
              kWebPayloadSmallMaxChars,
              (List<dynamic> arguments) {
                if (mounted && arguments.isNotEmpty) {
                  _onTextSelected(arguments.first);
                }
                return null;
              },
            ),
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

  @override
  Widget build(BuildContext context) {
    final WebBrowserChromeLayout layout = webBrowserChromeLayout(
      platform: Theme.of(context).platform,
      size: MediaQuery.sizeOf(context),
    );
    // 查词弹窗开合要重算 PopScope：弹窗栈挂在本页路由之内、没有自己的 PopScope。
    return ListenableBuilder(
      listenable: _lookup,
      builder: (BuildContext context, Widget? page) => PopScope(
        // 系统返回 / 侧滑 / Esc：先关查词弹窗，再退网页历史，都退到头才离开浏览页。
        canPop:
            webBrowserBackStep(
              lookupOpen: _lookup.isOpen,
              canGoBack: _canGoBack,
            ) ==
            WebBrowserBackStep.leavePage,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) _onBackBlocked();
        },
        child: page!,
      ),
      child: SrsCardLookupHost(
        controller: _lookup,
        child: FushiPageScaffold(
          title: _pageTitle.trim().isEmpty ? t.web_browser_title : _pageTitle,
          header: switch (layout) {
            WebBrowserChromeLayout.desktop => _buildDesktopHeader(context),
            WebBrowserChromeLayout.mobileTop => _buildMobileTopBar(context),
            // 竖屏顶部只留状态栏（脚手架的 SafeArea 已让出）。
            WebBrowserChromeLayout.mobileBottom => const SizedBox.shrink(),
          },
          // 正文是平台 WebView，内容在 WebView 内部滚动、拿不到页头让位：不叠放。
          extendBodyBehindHeader: false,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: _buildWebView(context)),
              if (layout != WebBrowserChromeLayout.mobileTop)
                _buildBottomBar(
                  context,
                  withAddress: layout == WebBrowserChromeLayout.mobileBottom,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
