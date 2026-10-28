import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_address_bar.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_menus.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_routes.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_tab_lists.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_settings_page.dart';
import 'package:fushi/src/settings/settings_schema_web_browser.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show focusedEditableText;
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/data/web_browser_store_provider.dart';
import 'package:fushi/src/web_browser/features/study/web_card_source.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/features/web_browser_features.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_error_view.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_find_bar.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_actions.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_view.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab_host.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tabs_controller.dart';
import 'package:fushi/src/web_browser/web_browser_prefs.dart';
import 'package:fushi/src/media/video/web_video_sites.dart'
    show webVideoSitesAvailable;
import 'package:fushi/src/web_browser/web_browser_site_launch.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/web_browser/web_browser_suggestions.dart';

export 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';

/// 站点书签（偏好 `web_browser_sites`），入口页与新标签页起始页共用同一份解析。
List<WebBrowserSite> _loadWebBrowserSites(AppModel appModel) =>
    parseWebBrowserSites(appModel.prefsRepo.webBrowserSitesJson);

/// 全屏浏览页（[FushiWebBrowserPage]）的路由：所有推浏览页的入口（入口页、视频站点
/// 入口）都经这一处建路由。
///
/// 整页包 [FushiAppUiScaleNeutralizer]（与阅读器 / 漫画 / 网页漫画等 WebView 页同一
/// 写法）：不包时 WebView 先按「界面大小」缩小后的画布排版、再被整体放大，网页发软
/// （实测 1.12 倍界面缩放下 innerWidth=367、屏宽 411dp）。中和层在路由层包在页面外，
/// 页面 State.context、查词弹窗层与 WebView 落在同一套净缩放=1 的坐标里。
Route<void> fushiWebBrowserRoute(BuildContext context, String url) =>
    adaptivePageRoute<void>(
      context: context,
      builder: (BuildContext _) => FushiAppUiScaleNeutralizer(
        child: FushiWebBrowserPage(initialUrl: url),
      ),
    );

/// 推出全屏浏览页（[FushiWebBrowserPage]）。它是独立子页：盖住首页外壳的主导航
/// 底栏 / 侧栏，网页独占整屏，退出回到入口页。
Future<void> openFushiWebBrowser(BuildContext context, Uri url) => Navigator.of(
  context,
).push<void>(fushiWebBrowserRoute(context, url.toString()));

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
    unawaited(_settleLegacyVideoSites());
  }

  /// 旧「视频站点」子页的自加站点并进来（一次性，见 [settleLegacyVideoSites]）。
  Future<void> _settleLegacyVideoSites() async {
    final List<WebBrowserSite> merged = await settleLegacyVideoSites(
      _appModel.prefsRepo,
      sitesJson: _appModel.prefsRepo.webBrowserSitesJson,
      writeSitesJson: _appModel.prefsRepo.setWebBrowserSitesJson,
    );
    if (mounted && merged.length != _sites.length) {
      setState(() => _sites = merged);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _openAddress(String input) {
    final Uri? url = resolveWebBrowserInput(
      input,
      readWebBrowserSearchProvider(_appModel.prefsRepo),
    );
    if (url == null) return;
    unawaited(_open(url));
  }

  Future<void> _setSearchEngine(WebBrowserSearchProvider engine) async {
    await writeWebBrowserSearchProvider(_appModel.prefsRepo, engine);
    if (mounted) setState(() {});
  }

  /// 地址栏前导：当前搜索引擎，点开切换。
  Widget _buildEngineMenu(BuildContext context) {
    final WebBrowserSearchProvider current = readWebBrowserSearchProvider(
      _appModel.prefsRepo,
    );
    final List<WebBrowserSearchProvider> all = webBrowserSearchProviders(
      _appModel.prefsRepo,
    );
    return FushiOverflowMenu<String>(
      key: const ValueKey<String>('web-browser-search-engine'),
      tooltip: t.web_browser_search_engine,
      onSelected: (String value) {
        for (final WebBrowserSearchProvider p in all) {
          if (p.prefValue == value) unawaited(_setSearchEngine(p));
        }
      },
      items: <PopupMenuEntry<String>>[
        for (final WebBrowserSearchProvider engine in all)
          FushiPopupMenuItem<String>(
            value: engine.prefValue,
            label: engine.label,
            selected: engine.prefValue == current.prefValue,
          ),
      ],
      child: FushiSearchLeading(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const FushiIcon(FushiIcons.search),
            const SizedBox(width: 6),
            Text(current.label),
            const FushiIcon(FushiIcons.expandMore, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _open(Uri url) async {
    _addressFocus.unfocus();
    _address.clear();
    await openFushiWebBrowser(context, url);
    // 浏览页里可能「加入站点」了：回来时按偏好重读。
    if (mounted) setState(() => _sites = _loadWebBrowserSites(_appModel));
  }

  /// 点站点：标了「用播放页打开」且本平台有播放页就进播放页，否则进浏览器。
  Future<void> _openSite(WebBrowserSite site) async {
    if (!webBrowserSiteOpensInPlayer(site)) return _open(site.url);
    _addressFocus.unfocus();
    await openInWebVideoPlayer(
      context,
      url: site.url,
      title: site.name,
      repo: VideoBookRepository(_appModel.database),
    );
  }

  Future<void> _saveSites(List<WebBrowserSite> next) async {
    setState(() => _sites = next);
    await _appModel.prefsRepo.setWebBrowserSitesJson(
      encodeWebBrowserSites(next),
    );
  }

  /// 手动添加 / 编辑站点（5wWlKU_Rir：以前只能先打开网页再「加入站点」，本机
  /// 服务这类地址也没法编辑）。两步输入：地址（与地址栏同一份判据
  /// [parseWebBrowserAddress]，不像网址不让确认）→ 名称（留空用域名）。
  /// [previous] 非 null 为编辑。返回 null = 取消。
  Future<WebBrowserSite?> _promptSite({WebBrowserSite? previous}) async {
    final String title = previous == null
        ? t.web_browser_site_new
        : t.web_browser_site_edit;
    final String? rawUrl = await showFushiTextInputDialog(
      context: context,
      title: title,
      labelText: t.web_browser_site_url,
      hintText: 'https://',
      initialValue: previous?.url.toString() ?? '',
      keyboardType: TextInputType.url,
      icon: FushiIcons.link,
      validator: (String value) =>
          value.isEmpty || parseWebBrowserAddress(value) != null
          ? null
          : t.web_browser_site_url_invalid,
    );
    if (rawUrl == null || !mounted) return null;
    final Uri? url = parseWebBrowserAddress(rawUrl);
    if (url == null) return null;
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: title,
      labelText: t.web_browser_site_name,
      hintText: url.host,
      message: t.web_browser_site_name_hint,
      initialValue: previous?.name ?? '',
      allowEmpty: true,
    );
    if (name == null) return null;
    return WebBrowserSite(
      name: name.isEmpty ? url.host : name,
      url: url,
      openInPlayer:
          previous?.openInPlayer ??
          webBrowserSiteDefaultsToPlayer(
            url,
            playerAvailable: webVideoSitesAvailable(),
          ),
    );
  }

  Future<void> _addSite() async {
    final WebBrowserSite? site = await _promptSite();
    if (site == null || !mounted) return;
    await _saveSites(addWebBrowserSite(_sites, site));
  }

  Future<void> _editSite(WebBrowserSite site) async {
    final WebBrowserSite? next = await _promptSite(previous: site);
    if (next == null || !mounted) return;
    await _saveSites(replaceWebBrowserSite(_sites, site, next));
  }

  /// 长按 / 右键站点：切换打开方式（只在有播放页的平台）、编辑或移除。
  Future<void> _siteActions(WebBrowserSite site) async {
    final _SiteAction? action = await showFushiChoiceDialog<_SiteAction>(
      context: context,
      title: site.name,
      options: <FushiChoiceOption<_SiteAction>>[
        if (webVideoSitesAvailable())
          FushiChoiceOption<_SiteAction>(
            value: _SiteAction.togglePlayer,
            label: site.openInPlayer
                ? t.web_browser_site_open_in_browser
                : t.web_browser_site_open_in_player,
            subtitle: site.openInPlayer
                ? null
                : t.web_browser_site_open_in_player_hint,
            icon: site.openInPlayer ? FushiIcons.globe : FushiIcons.playCircle,
          ),
        FushiChoiceOption<_SiteAction>(
          value: _SiteAction.edit,
          label: t.web_browser_site_edit,
          icon: FushiIcons.edit,
        ),
        FushiChoiceOption<_SiteAction>(
          value: _SiteAction.remove,
          label: t.web_browser_site_remove,
          icon: FushiIcons.delete,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _SiteAction.togglePlayer:
        await _saveSites(
          replaceWebBrowserSite(
            _sites,
            site,
            site.copyWith(openInPlayer: !site.openInPlayer),
          ),
        );
      case _SiteAction.edit:
        await _editSite(site);
      case _SiteAction.remove:
        await _removeSite(site);
      case null:
        break;
    }
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
    await _saveSites(removeWebBrowserSite(_sites, site));
  }

  Widget _buildAddressBar(BuildContext context) {
    return FushiSearchField(
      fieldKey: const ValueKey<String>('web-browser-address'),
      controller: _address,
      focusNode: _addressFocus,
      hintText: t.web_browser_search_hint,
      keyboardType: TextInputType.url,
      leading: _buildEngineMenu(context),
      size: FushiSearchFieldSize.large,
      onClear: _address.clear,
      onChanged: (String _) {},
      onSubmitted: _openAddress,
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
            child: Row(
              children: <Widget>[
                Expanded(
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
                FushiTextButton.icon(
                  key: const ValueKey<String>('web-browser-site-new'),
                  onPressed: () => unawaited(_addSite()),
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(t.web_browser_site_new),
                ),
              ],
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
                  (BuildContext context, int i) => _WebBrowserSiteTile(
                    site: _sites[i],
                    onOpen: () => unawaited(_openSite(_sites[i])),
                    onActions: () => unawaited(_siteActions(_sites[i])),
                  ),
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
      // Builder：正文必须用脚手架内部的 context 读 MediaQuery——脚手架在那里
      // 把「状态栏 + 页头」写进 padding.top。直接用本页 context 读到的是脚手架
      // 上层的 0，地址栏会被悬浮页头盖住（2026-10-20 用户截图）。
      body: FushiEntranceScope(
        replayKey: _sites.length,
        child: Builder(builder: _buildBody),
      ),
    );
  }
}

/// 站点卡片长按 / 右键菜单的动作。
enum _SiteAction { togglePlayer, edit, remove }

/// 入口页与新标签页起始页共用的站点卡片。
class _WebBrowserSiteTile extends StatelessWidget {
  const _WebBrowserSiteTile({
    required this.site,
    required this.onOpen,
    this.onActions,
  });

  final WebBrowserSite site;
  final VoidCallback onOpen;
  final VoidCallback? onActions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final String trimmed = site.name.trim();
    final String name = trimmed.isEmpty ? site.url.host : trimmed;
    final String initial = name.characters.first.toUpperCase();
    return FushiCard(
      key: ValueKey<String>('web-browser-site-${site.url}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      onTap: onOpen,
      onLongPress: onActions,
      onSecondaryTap: onActions,
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
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
              ),
              // 点开进播放页的站点：标题后挂一个播放图标（只在有播放页的平台）。
              if (webBrowserSiteOpensInPlayer(site))
                FushiTooltip(
                  message: t.web_browser_site_opens_in_player,
                  child: FushiIcon(
                    FushiIcons.playCircle,
                    key: ValueKey<String>(
                      'web-browser-site-player-${site.url}',
                    ),
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
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
}

/// 网页持焦时把浏览器快捷键交回 Dart 的键盘桥 handler 名。
const String _kKeyBridgeHandler = 'onWebBrowserShortcutKey';

/// 浏览器快捷键的键盘桥：作为一个内部功能挂到每个标签页（WebView 持焦时键只在
/// DOM 里，见 docs/agent/focus-ownership.md「键盘桥」）。键表取自当前注册表里
/// [ShortcutScope.webBrowser] 的全部键盘绑定（token 即 `InputBinding.serialize()`）。
class _ShortcutKeyBridge extends WebBrowserFeature {
  _ShortcutKeyBridge({required this.registry, required this.onToken});

  final FushiShortcutRegistry registry;
  final void Function(WebBrowserTab tab, String token) onToken;

  @override
  String get id => 'shell-shortcut-key-bridge';

  List<String> _tokens() => <String>[
    for (final ShortcutAction action in ShortcutAction.actionsForScope(
      ShortcutScope.webBrowser,
    ))
      for (final InputBinding binding
          in registry.bindingsFor(action).keyboardBindings)
        binding.serialize(),
  ];

  @override
  List<UserScript> userScripts() => <UserScript>[
    UserScript(
      groupName: 'fushi-web-browser-shortcuts',
      source: webViewKeyBridgeScript(
        handlerName: _kKeyBridgeHandler,
        keys: _tokens(),
        stopPropagation: true,
      ),
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    ),
  ];

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: _kKeyBridgeHandler,
      callback: (List<dynamic> args) {
        if (args.isNotEmpty && args.first is String) {
          onToken(tab, args.first as String);
        }
        return null;
      },
    );
  }
}

/// app 内通用浏览器的全屏浏览页（五端），由入口页 [FushiWebBrowserHomePage] 经
/// [openFushiWebBrowser] 推出。多标签页：标签列表归 [WebBrowserTabsController]，
/// 每个标签页的 WebView 归 [WebBrowserTabView]，本页只是壳——摆放、chrome、菜单、
/// 快捷键与会话恢复。
///
/// 版式按窗口宽度分（[webBrowserShellLayout]，不看平台）：
/// - 窄窗口（竖屏）：底栏「后退 / 地址栏 / 查词 / 标签数 / ⋯」，标签数按钮打开全屏
///   标签页网格；往下滚收起成小地址条；
/// - 宽窗口 + 侧边栏（默认）：顶栏最左是侧边栏开关，260dp 侧边栏放标签页列表 +
///   书签 / 历史 / 下载；桌面挤开网页，手机横屏盖在网页上；
/// - 宽窗口 + 顶部标签栏：地址栏上方一排 36dp 标签；矮窗口（手机横屏）往下滚两排
///   一起收起。
/// 工具栏默认平铺、放不下才按优先级收进「⋯」（[FushiTopBarOverflowFit]）。
///
/// 返回（系统返回 / 侧滑 / Esc）：查词弹窗 → 全屏 / 查找条 / 网格 / 抽屉 → 网页
/// 历史 → 关掉由别的标签页打开的子页 → 离开浏览页（[webBrowserBackStep]）。
class FushiWebBrowserPage extends ConsumerStatefulWidget {
  const FushiWebBrowserPage({required this.initialUrl, super.key});

  /// 打开即加载的地址（地址栏的输入规则，见 [parseWebBrowserAddress]）；空串 =
  /// 只恢复上次的标签页（没有就开一个新标签页）。
  final String initialUrl;

  /// 测试注入：壳的 widget 测试用它代替整个 [WebBrowserTabView]（标签页 WebView 的
  /// 生命周期由 tab_view 自己的测试覆盖，壳测试只看摆放）。
  @visibleForTesting
  static Widget Function(BuildContext context, WebBrowserTab tab)?
  debugTabViewBuilder;

  @override
  ConsumerState<FushiWebBrowserPage> createState() =>
      FushiWebBrowserPageState();
}

/// 浏览页壳的状态（测试经它读标签列表、直接执行快捷键动作）。
class FushiWebBrowserPageState extends ConsumerState<FushiWebBrowserPage>
    with WidgetsBindingObserver
    implements WebBrowserTabHost {
  late final WebBrowserStore _store = ref.read(webBrowserStoreProvider);
  late final List<WebBrowserFeature> _features;
  late final WebBrowserTabsController _tabs;
  late final WebBrowserSuggestionsController _suggestions;
  final FocusNode _addressFocus = FocusNode(debugLabel: 'web-browser-address');
  final GlobalKey<WebBrowserAddressBarState> _addressBar =
      GlobalKey<WebBrowserAddressBarState>();
  final FushiTopBarOverflowFit _toolbarFit = FushiTopBarOverflowFit();

  /// 页内取词：与复习卡面同一套控制器，整页一份；标签页 WebView 经
  /// [SrsCardLookupScope] 登记成取词表面。
  late final SrsCardLookupController _lookup = SrsCardLookupController(
    settings: () {
      final SrsCardLookupSettings reader = srsCardLookupSettingsFromReader();
      return (
        tap: _lookupEnabled,
        hoverAuto: _lookupEnabled && reader.hoverAuto,
      );
    },
  );
  bool _lookupEnabled = true;

  late WebBrowserTabStyle _tabStyle;
  late bool _sidebarOpen;

  /// 侧边栏是抽屉形态时（手机横屏）的开合，与桌面推挤形态的记忆开关分开。
  bool _drawerOpen = false;
  bool _gridOpen = false;
  WebBrowserCollapseState _collapse = const WebBrowserCollapseState();
  final Map<String, Uint8List> _thumbnails = <String, Uint8List>{};

  WebBrowserTab? _watched;
  bool _bookmarked = false;
  Uri? _bookmarkCheckedFor;
  bool _systemUiHidden = false;

  AppModel get _appModel => ref.read(appProvider);

  @override
  WebBrowserStore get store => _store;

  @override
  List<WebBrowserFeature> get features => _features;

  @visibleForTesting
  WebBrowserTabsController get tabsController => _tabs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final PrefStore prefs = _appModel.prefsRepo;
    _tabStyle = webBrowserTabStyle(prefs);
    _sidebarOpen = webBrowserSidebarOpen(prefs);
    _features = <WebBrowserFeature>[
      ...buildWebBrowserFeatures(
        ref,
        lookup: _lookup,
        openExtensionSettings: _openExtensionSettings,
      ),
      _ShortcutKeyBridge(
        registry: _appModel.shortcutRegistry,
        onToken: _onBridgeToken,
      ),
    ];
    for (final WebBrowserFeature f in _features) {
      f.actionsChanged?.addListener(_rebuild);
    }
    _tabs = WebBrowserTabsController(store: _store, features: _features)
      ..persistSession = webBrowserRestoreTabs(prefs);
    // 带进来的地址先开（监听挂上之前：initState 里不能 setState），恢复的会话
    // 随后异步插到它前面。
    final Uri? initial = parseWebBrowserAddress(widget.initialUrl);
    if (initial != null) openTab(initial);
    _tabs.addListener(_onTabsChanged);
    _bindActiveTab();
    _store.addListener(_onStoreChanged);
    _suggestions = WebBrowserSuggestionsController(
      store: _store,
      provider: () => readWebBrowserSearchProvider(_appModel.prefsRepo),
      onlineEnabled: () => !(_tabs.activeTab?.incognito ?? false),
    );
    _addressFocus.addListener(_rebuild);
    _lookup.addListener(_rebuild);
    unawaited(_restore());
  }

  /// 扩展「扩展设置」（播放器菜单、报错 toast）：统一「浏览器设置」，落在扩展的字幕组。
  void _openExtensionSettings() {
    if (!mounted) return;
    unawaited(_openSettings(group: WebBrowserSettingsGroup.subtitle));
  }

  Future<void> _restore() async {
    try {
      await _tabs.restoreSession();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('FushiWebBrowserPage.restore', error, stack);
    }
    if (!mounted) return;
    if (_tabs.isEmpty) openTab(null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_systemUiHidden) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    _watched?.removeListener(_onActiveTabChanged);
    _tabs.removeListener(_onTabsChanged);
    _store.removeListener(_onStoreChanged);
    for (final WebBrowserFeature f in _features) {
      f.actionsChanged?.removeListener(_rebuild);
      f.dispose();
    }
    _tabs.dispose();
    _suggestions.dispose();
    _lookup.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_tabs.flushSession());
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// 前台标签页换了：改挂监听、重置滚动收起、按新页同步系统栏与书签星标。
  void _bindActiveTab() {
    final WebBrowserTab? active = _tabs.activeTab;
    if (identical(active, _watched)) return;
    _watched?.removeListener(_onActiveTabChanged);
    _watched = active;
    active?.addListener(_onActiveTabChanged);
    _collapse = const WebBrowserCollapseState();
    _applySystemUi(active?.fullscreen ?? false);
    _refreshBookmark();
  }

  void _onTabsChanged() {
    _bindActiveTab();
    _rebuild();
  }

  void _onActiveTabChanged() {
    final WebBrowserTab? tab = _watched;
    if (tab == null) return;
    _applySystemUi(tab.fullscreen);
    if (tab.url != _bookmarkCheckedFor) _refreshBookmark();
    _rebuild();
  }

  void _onStoreChanged() => _refreshBookmark();

  void _refreshBookmark() {
    final Uri? url = _tabs.activeTab?.url;
    _bookmarkCheckedFor = url;
    if (url == null) {
      if (_bookmarked && mounted) setState(() => _bookmarked = false);
      return;
    }
    unawaited(
      _store.bookmarkForUrl(url).then((WebBrowserBookmark? b) {
        if (!mounted || _tabs.activeTab?.url != url) return;
        if ((b != null) != _bookmarked) setState(() => _bookmarked = b != null);
      }, onError: (Object _) {}),
    );
  }

  void _applySystemUi(bool fullscreen) {
    if (fullscreen == _systemUiHidden) return;
    _systemUiHidden = fullscreen;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ),
    );
  }

  // ── WebBrowserTabHost ─────────────────────────────────────────────────

  @override
  WebBrowserTab openTab(
    Uri? url, {
    String? openerId,
    int? windowId,
    bool incognito = false,
    bool activate = true,
  }) {
    final WebBrowserTab tab = _tabs.openTab(
      url,
      openerId: openerId,
      windowId: windowId,
      incognito: incognito,
      activate: activate,
    );
    if (webBrowserDesktopModeSupported() &&
        webBrowserDesktopModeDefault(_appModel.prefsRepo)) {
      tab.update(desktopMode: true);
    }
    // 只有用户新建的空白页才把焦点给地址栏。window.open 开出的新窗口（带
    // windowId）在 Android 上发起时也拿不到地址（url 为 null），但它是网页自己
    // 开的页、马上加载内容：不弹地址栏和软键盘。
    if (url == null && windowId == null && activate) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && identical(_tabs.activeTab, tab)) {
          _addressBar.currentState?.beginEditing();
        }
      });
    }
    return tab;
  }

  @override
  void closeTab(WebBrowserTab tab) {
    _tabs.closeTab(tab);
    _thumbnails.remove(tab.id);
    if (_tabs.isEmpty && !_gridOpen && mounted) Navigator.of(context).pop();
  }

  @override
  bool isActive(WebBrowserTab tab) => _tabs.isActive(tab);

  @override
  void onContentScrolled(WebBrowserTab tab, {required int y, required int dy}) {
    if (!isActive(tab) || !mounted) return;
    final WebBrowserCollapseState next = _collapse.onScroll(y: y, dy: dy);
    if (next.collapsed != _collapse.collapsed) {
      setState(() => _collapse = next);
    } else {
      _collapse = next;
    }
  }

  @override
  void onFullscreenChanged(WebBrowserTab tab, {required bool fullscreen}) {
    tab.update(fullscreen: fullscreen);
  }

  // ── 导航 ─────────────────────────────────────────────────────────────

  PrefStore get _prefs => _appModel.prefsRepo;

  /// 在 [tab]（默认前台页）里打开 [url]；[newTab] 开新标签页。
  void _navigate(Uri url, {WebBrowserTab? tab, bool newTab = false}) {
    final WebBrowserTab? target = newTab ? null : (tab ?? _tabs.activeTab);
    if (target == null) {
      openTab(url);
      return;
    }
    final InAppWebViewController? controller = target.controller;
    if (controller != null) {
      unawaited(
        controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url))),
      );
    } else {
      target.update(url: url);
    }
    _tabs.activate(target);
  }

  void _submitAddress(String input) {
    final Uri? url = resolveWebBrowserInput(
      input,
      readWebBrowserSearchProvider(_prefs),
    );
    if (url != null) _navigate(url);
  }

  void _openSuggestion(WebBrowserSuggestion s) {
    final Uri? url =
        s.url ??
        (s.query == null
            ? null
            : readWebBrowserSearchProvider(_prefs).searchUrl(s.query!));
    if (url != null) _navigate(url);
  }

  void _goBack() => unawaited(_tabs.activeTab?.controller?.goBack());

  /// 工具栏「后退」：与系统返回同一条阶梯（[webBrowserBackStep]），退到头就离开
  /// 浏览页——桌面没有系统返回键，这是鼠标离开浏览器的入口。
  void _backOrLeave() => unawaited(Navigator.of(context).maybePop());

  /// 「退出浏览器」：不走后退阶梯（那要先退完网页历史），直接离开浏览页回到
  /// 入口——标签页留在会话里，下次进来照旧。
  void _exitBrowser() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _goForward() => unawaited(_tabs.activeTab?.controller?.goForward());

  void _reload() {
    final WebBrowserTab? tab = _tabs.activeTab;
    if (tab == null) return;
    tab.setError(null);
    unawaited(tab.controller?.reload());
  }

  Future<void> _toggleBookmark() async {
    final WebBrowserTab? tab = _tabs.activeTab;
    final Uri? url = tab?.url;
    if (tab == null || url == null || tab.incognito) return;
    final WebBrowserBookmark? existing = await _store.bookmarkForUrl(url);
    if (existing != null) {
      await _store.deleteBookmark(existing.id);
    } else {
      await _store.addBookmark(title: tab.displayTitle, url: url);
    }
    _refreshBookmark();
  }

  void _toggleLookup() {
    setState(() => _lookupEnabled = !_lookupEnabled);
    if (!_lookupEnabled) _lookup.closeAll();
  }

  void _setTextZoom(int value) => _tabs.activeTab?.update(textZoom: value);

  void _openFind() => _tabs.activeTab?.update(findOpen: true);

  void _newTab({bool incognito = false}) {
    setState(() => _gridOpen = false);
    openTab(null, incognito: incognito);
  }

  Future<void> _reopenClosedTab() async {
    await _tabs.reopenClosedTab();
  }

  Future<void> _addCurrentSite() async {
    final WebBrowserTab? tab = _tabs.activeTab;
    final Uri? url = tab?.url;
    if (tab == null || url == null) return;
    final List<WebBrowserSite> sites = addWebBrowserSite(
      _loadWebBrowserSites(_appModel),
      WebBrowserSite(
        name: tab.displayTitle,
        url: url,
        openInPlayer: webBrowserSiteDefaultsToPlayer(
          url,
          playerAvailable: webVideoSitesAvailable(),
        ),
      ),
    );
    await _appModel.prefsRepo.setWebBrowserSitesJson(
      encodeWebBrowserSites(sites),
    );
    FushiToast.show(
      msg: t.web_browser_site_added,
      severity: ToastSeverity.success,
    );
  }

  Future<void> _setTabStyle(WebBrowserTabStyle style) async {
    setState(() => _tabStyle = style);
    await setWebBrowserTabStyle(_prefs, style);
  }

  void _toggleSidebar(bool overlay) {
    if (overlay) {
      setState(() => _drawerOpen = !_drawerOpen);
      return;
    }
    setState(() => _sidebarOpen = !_sidebarOpen);
    unawaited(setWebBrowserSidebarOpen(_prefs, _sidebarOpen));
  }

  Future<void> _openGrid() async {
    final WebBrowserTab? tab = _tabs.activeTab;
    final InAppWebViewController? controller = tab?.controller;
    if (tab != null && controller != null && !tab.incognito) {
      try {
        final Uint8List? shot = await controller.takeScreenshot(
          screenshotConfiguration: ScreenshotConfiguration(
            compressFormat: CompressFormat.JPEG,
            quality: 60,
          ),
        );
        if (shot != null) _thumbnails[tab.id] = shot;
      } on Object {
        // 平台不支持截图：网格用色块。
      }
    }
    if (mounted) setState(() => _gridOpen = true);
  }

  void _openDataPage(WebBrowserDataPage page) {
    setState(() => _drawerOpen = false);
    unawaited(
      openWebBrowserDataPage(
        context,
        page,
        store: _store,
        prefs: _prefs,
        onOpen: (Uri url, {bool newTab = false}) =>
            _navigate(url, newTab: newTab),
      ),
    );
  }

  /// 「⋯ › 浏览器设置」与播放器菜单「扩展设置」共用的统一入口。
  Future<void> _openSettings({WebBrowserSettingsGroup? group}) async {
    await openWebBrowserSettings(context, group: group);
    if (!mounted) return;
    setState(() {
      _tabStyle = webBrowserTabStyle(_prefs);
      _tabs.persistSession = webBrowserRestoreTabs(_prefs);
    });
  }

  // ── 返回 ─────────────────────────────────────────────────────────────

  bool get _overlayOpen {
    final WebBrowserTab? tab = _tabs.activeTab;
    return _gridOpen ||
        _drawerOpen ||
        (tab?.fullscreen ?? false) ||
        (tab?.findOpen ?? false);
  }

  bool get _openedByOtherTab {
    final String? opener = _tabs.activeTab?.openerId;
    return opener != null && _tabs.tabById(opener) != null;
  }

  WebBrowserBackStep get _backStep => webBrowserBackStep(
    lookupOpen: _lookup.isOpen,
    canGoBack: _tabs.activeTab?.canGoBack ?? false,
    overlayOpen: _overlayOpen,
    openedByOtherTab: _openedByOtherTab,
  );

  void _onBackBlocked() {
    final WebBrowserTab? tab = _tabs.activeTab;
    switch (_backStep) {
      case WebBrowserBackStep.closeLookup:
        // 搜索期占位没有可见层时 closeTop 返回 false：整栈关掉，别让返回键落空。
        if (!_lookup.closeTop()) _lookup.closeAll();
      case WebBrowserBackStep.dismissOverlay:
        if (tab != null && tab.fullscreen) {
          unawaited(exitTabFullscreen(tab));
          tab.update(fullscreen: false);
        } else if (tab != null && tab.findOpen) {
          tab.update(findOpen: false);
        } else {
          setState(() {
            _gridOpen = false;
            _drawerOpen = false;
          });
        }
      case WebBrowserBackStep.webHistoryBack:
        _goBack();
      case WebBrowserBackStep.closeTab:
        if (tab != null) closeTab(tab);
      case WebBrowserBackStep.leavePage:
        break;
    }
  }

  // ── 快捷键 ───────────────────────────────────────────────────────────

  Set<ModifierKey> _pressedModifiers() {
    final HardwareKeyboard hw = HardwareKeyboard.instance;
    return <ModifierKey>{
      if (hw.isControlPressed) ModifierKey.ctrl,
      if (hw.isShiftPressed) ModifierKey.shift,
      if (hw.isAltPressed) ModifierKey.alt,
      if (hw.isMetaPressed) ModifierKey.meta,
    };
  }

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ShortcutAction? action = _appModel.shortcutRegistry.resolveKeyboard(
      event.logicalKey,
      modifiers: _pressedModifiers(),
      scope: ShortcutScope.webBrowser,
      physicalKey: focusedEditableText() == null ? event.physicalKey : null,
    );
    if (action == null) return KeyEventResult.ignored;
    return runShortcut(action)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// WebView 持焦时键盘桥回传的 token → 注册表解析（与 Flutter 持焦同一条路）。
  void _onBridgeToken(WebBrowserTab tab, String token) {
    if (!mounted || !isActive(tab)) return;
    final InputBinding? binding = InputBinding.deserialize(token);
    if (binding == null) return;
    final ShortcutAction? action = _appModel.shortcutRegistry.resolveKeyboard(
      binding.key,
      modifiers: binding.modifiers,
      scope: ShortcutScope.webBrowser,
    );
    if (action != null) runShortcut(action);
  }

  /// 执行一个浏览器快捷键动作；返回是否消费。
  @visibleForTesting
  bool runShortcut(ShortcutAction action) {
    final WebBrowserTab? tab = _tabs.activeTab;
    switch (action) {
      case ShortcutAction.webBrowserNewTab:
        _newTab();
      case ShortcutAction.webBrowserCloseTab:
        if (tab != null) closeTab(tab);
      case ShortcutAction.webBrowserReopenClosedTab:
        unawaited(_reopenClosedTab());
      case ShortcutAction.webBrowserFocusAddress:
        _addressBar.currentState?.beginEditing();
      case ShortcutAction.webBrowserNextTab:
        _tabs.activateRelative(1);
      case ShortcutAction.webBrowserPreviousTab:
        _tabs.activateRelative(-1);
      case ShortcutAction.webBrowserFindInPage:
        _openFind();
      case ShortcutAction.webBrowserBack:
        _goBack();
      case ShortcutAction.webBrowserForward:
        _goForward();
      case ShortcutAction.webBrowserReload:
        _reload();
      case ShortcutAction.webBrowserToggleBookmark:
        unawaited(_toggleBookmark());
      case ShortcutAction.webBrowserZoomIn:
        if (tab != null) _setTextZoom(webBrowserStepTextZoom(tab.textZoom, 1));
      case ShortcutAction.webBrowserZoomOut:
        if (tab != null) _setTextZoom(webBrowserStepTextZoom(tab.textZoom, -1));
      case ShortcutAction.webBrowserZoomReset:
        _setTextZoom(100);
      default:
        return false;
    }
    return true;
  }

  // ── 工具栏 / 菜单 ─────────────────────────────────────────────────────

  List<WebBrowserAction> _featureActions(WebBrowserTab? tab) {
    if (tab == null) return const <WebBrowserAction>[];
    final List<WebBrowserAction> all = <WebBrowserAction>[
      for (final WebBrowserFeature f in _features) ...f.actions(context, tab),
    ];
    all.sort(
      (WebBrowserAction a, WebBrowserAction b) =>
          b.priority.compareTo(a.priority),
    );
    return all;
  }

  FushiToolbarItem _toToolbarItem(WebBrowserAction a) => FushiToolbarItem(
    key: ValueKey<String>('web-browser-action-${a.id}'),
    icon: a.icon,
    label: a.label,
    selected: a.selected,
    onPressed: a.onPressed,
  );

  /// 工具栏动作（高 → 低优先级）。宽度不够时从末尾起收进「⋯」。
  List<FushiToolbarItem> _toolbarItems(WebBrowserShellLayout layout) {
    final WebBrowserTab? tab = _tabs.activeTab;
    final List<WebBrowserAction> feature = _featureActions(tab)
        .where(
          (WebBrowserAction a) =>
              a.placement == WebBrowserActionPlacement.toolbar,
        )
        .toList();
    final List<({int priority, FushiToolbarItem item})> ranked =
        <({int priority, FushiToolbarItem item})>[
          (
            priority: 85,
            item: FushiToolbarItem(
              key: const ValueKey<String>('web-browser-lookup'),
              icon: FushiIcons.readerMode,
              label: _lookupEnabled
                  ? t.web_browser_lookup_on
                  : t.web_browser_lookup_off,
              selected: _lookupEnabled,
              onPressed: _toggleLookup,
            ),
          ),
          for (final WebBrowserAction a in feature)
            (priority: a.priority, item: _toToolbarItem(a)),
          if (layout != WebBrowserShellLayout.bottomBar)
            (
              priority: 40,
              item: FushiToolbarItem(
                key: const ValueKey<String>('web-browser-downloads'),
                icon: FushiIcons.download,
                label: t.web_browser_menu_downloads,
                onPressed: () => _openDataPage(WebBrowserDataPage.downloads),
              ),
            ),
          if (layout == WebBrowserShellLayout.topStrip) ...<
            ({int priority, FushiToolbarItem item})
          >[
            (
              priority: 30,
              item: FushiToolbarItem(
                key: const ValueKey<String>('web-browser-bookmarks'),
                icon: FushiIcons.bookmarks,
                label: t.web_browser_menu_bookmarks,
                onPressed: () => _openDataPage(WebBrowserDataPage.bookmarks),
              ),
            ),
            (
              priority: 29,
              item: FushiToolbarItem(
                key: const ValueKey<String>('web-browser-history'),
                icon: FushiIcons.history,
                label: t.web_browser_menu_history,
                onPressed: () => _openDataPage(WebBrowserDataPage.history),
              ),
            ),
          ],
        ];
    ranked.sort(
      (
        ({int priority, FushiToolbarItem item}) a,
        ({int priority, FushiToolbarItem item}) b,
      ) => b.priority.compareTo(a.priority),
    );
    return <FushiToolbarItem>[for (final r in ranked) r.item];
  }

  List<WebBrowserMenuSection> _menuSections({
    required WebBrowserShellLayout layout,
    required List<FushiToolbarItem> overflow,
  }) {
    final WebBrowserTab? tab = _tabs.activeTab;
    final bool hasPage = tab?.url != null;
    final List<WebBrowserAction> featureMenu = _featureActions(tab)
        .where(
          (WebBrowserAction a) => a.placement == WebBrowserActionPlacement.menu,
        )
        .toList();
    return <WebBrowserMenuSection>[
      WebBrowserMenuItems(<WebBrowserMenuItem>[
        for (final FushiToolbarItem item in overflow)
          WebBrowserMenuItem(
            id: 'overflow-${item.key}',
            icon: item.icon,
            label: item.label,
            selected: item.selected,
            enabled: item.onPressed != null,
            onSelected: item.onPressed ?? () {},
          ),
      ]),
      WebBrowserMenuItems(<WebBrowserMenuItem>[
        WebBrowserMenuItem(
          id: 'new-tab',
          icon: FushiIcons.add,
          label: t.web_browser_tab_new,
          onSelected: _newTab,
        ),
        if (webBrowserIncognitoSupported())
          WebBrowserMenuItem(
            id: 'new-incognito-tab',
            icon: FushiIcons.incognito,
            label: t.web_browser_tab_new_incognito,
            onSelected: () => _newTab(incognito: true),
          ),
      ]),
      WebBrowserMenuItems(<WebBrowserMenuItem>[
        WebBrowserMenuItem(
          id: 'history',
          icon: FushiIcons.history,
          label: t.web_browser_menu_history,
          onSelected: () => _openDataPage(WebBrowserDataPage.history),
        ),
        WebBrowserMenuItem(
          id: 'bookmarks',
          icon: FushiIcons.bookmarks,
          label: t.web_browser_menu_bookmarks,
          onSelected: () => _openDataPage(WebBrowserDataPage.bookmarks),
        ),
        WebBrowserMenuItem(
          id: 'downloads',
          icon: FushiIcons.download,
          label: t.web_browser_menu_downloads,
          onSelected: () => _openDataPage(WebBrowserDataPage.downloads),
        ),
      ]),
      WebBrowserMenuItems(<WebBrowserMenuItem>[
        WebBrowserMenuItem(
          id: 'forward',
          icon: FushiIcons.forward,
          label: t.web_browser_forward,
          enabled: tab?.canGoForward ?? false,
          onSelected: _goForward,
        ),
        WebBrowserMenuItem(
          id: 'find',
          icon: FushiIcons.findInPage,
          label: t.web_browser_find_hint,
          enabled: hasPage,
          onSelected: _openFind,
        ),
        WebBrowserMenuItem(
          id: 'share',
          icon: FushiIcons.share,
          label: t.share,
          enabled: hasPage,
          onSelected: () => unawaited(shareTabUrl(tab!)),
        ),
        WebBrowserMenuItem(
          id: 'copy-link',
          icon: FushiIcons.copy,
          label: t.web_browser_link_copy,
          enabled: hasPage,
          onSelected: () => unawaited(copyTabUrl(tab!)),
        ),
        WebBrowserMenuItem(
          id: 'open-external',
          icon: FushiIcons.openInNew,
          label: t.web_browser_menu_open_external,
          enabled: hasPage,
          onSelected: () => unawaited(openTabInSystemBrowser(tab!)),
        ),
        WebBrowserMenuItem(
          id: 'site-add',
          icon: FushiIcons.bookmarkAdd,
          label: t.web_browser_site_add,
          enabled: hasPage,
          onSelected: () => unawaited(_addCurrentSite()),
        ),
        if (webBrowserDesktopModeSupported())
          WebBrowserMenuItem(
            id: 'desktop-site',
            icon: FushiIcons.laptop,
            label: t.web_browser_menu_desktop_site,
            selected: tab?.desktopMode ?? false,
            enabled: tab != null,
            onSelected: () => tab?.update(desktopMode: !(tab.desktopMode)),
          ),
      ]),
      if (tab != null)
        WebBrowserMenuWidget(
          id: 'text-size',
          height: 56,
          builder: (BuildContext _) => WebBrowserTextZoomRow(
            value: tab.textZoom,
            onChanged: _setTextZoom,
          ),
        ),
      if (layout != WebBrowserShellLayout.bottomBar)
        WebBrowserMenuWidget(
          id: 'tab-style',
          height: 84,
          builder: (BuildContext _) => WebBrowserTabStyleSegments(
            value: _tabStyle,
            onChanged: (WebBrowserTabStyle s) => unawaited(_setTabStyle(s)),
          ),
        ),
      WebBrowserMenuItems(<WebBrowserMenuItem>[
        for (final WebBrowserAction a in featureMenu)
          WebBrowserMenuItem(
            id: 'feature-${a.id}',
            icon: a.icon,
            label: a.label,
            selected: a.selected,
            enabled: a.onPressed != null,
            onSelected: a.onPressed ?? () {},
          ),
      ]),
      WebBrowserMenuItems(<WebBrowserMenuItem>[
        WebBrowserMenuItem(
          id: 'settings',
          icon: FushiIcons.settings,
          label: t.web_browser_menu_settings,
          onSelected: () => unawaited(_openSettings()),
        ),
        WebBrowserMenuItem(
          id: 'exit',
          icon: FushiIcons.exitToApp,
          label: t.web_browser_exit,
          onSelected: _exitBrowser,
        ),
      ]),
    ];
  }

  /// 测试钩子：标签区域的右键菜单只认鼠标次键（[ContextMenuTrigger]），集成测试
  /// 禁止坐标点击，经它在标签 [globalPosition] 处弹同一份菜单。
  @visibleForTesting
  void debugShowTabContextMenu(WebBrowserTab tab, Offset globalPosition) =>
      _showTabContextMenu(tab, globalPosition);

  /// 标签区域右键 / 长按菜单。
  void _showTabContextMenu(WebBrowserTab tab, Offset position) {
    final bool wide =
        webBrowserChromeLayout(size: MediaQuery.sizeOf(context)) ==
        WebBrowserChromeLayout.top;
    unawaited(
      showWebBrowserMenu(
        context: context,
        globalPosition: position,
        sections: <WebBrowserMenuSection>[
          if (wide)
            WebBrowserMenuItems(<WebBrowserMenuItem>[
              if (_tabStyle == WebBrowserTabStyle.sidebar)
                WebBrowserMenuItem(
                  id: 'use-top',
                  icon: FushiIcons.tab,
                  label: t.web_browser_tab_style_use_top,
                  onSelected: () =>
                      unawaited(_setTabStyle(WebBrowserTabStyle.topStrip)),
                )
              else
                WebBrowserMenuItem(
                  id: 'use-sidebar',
                  icon: FushiIcons.sidebar,
                  label: t.web_browser_tab_style_use_sidebar,
                  onSelected: () =>
                      unawaited(_setTabStyle(WebBrowserTabStyle.sidebar)),
                ),
            ]),
          WebBrowserMenuItems(<WebBrowserMenuItem>[
            WebBrowserMenuItem(
              id: 'tab-close',
              icon: FushiIcons.close,
              label: t.web_browser_tab_close,
              onSelected: () => closeTab(tab),
            ),
            WebBrowserMenuItem(
              id: 'tab-close-others',
              icon: FushiIcons.deleteSweep,
              label: t.web_browser_tab_close_others,
              enabled: _tabs.length > 1,
              onSelected: () => _tabs.closeOtherTabs(tab),
            ),
            WebBrowserMenuItem(
              id: 'tab-reopen',
              icon: FushiIcons.undo,
              label: t.web_browser_tab_reopen_closed,
              onSelected: () => unawaited(_reopenClosedTab()),
            ),
          ]),
          WebBrowserMenuItems(<WebBrowserMenuItem>[
            WebBrowserMenuItem(
              id: 'tab-copy-link',
              icon: FushiIcons.copy,
              label: t.web_browser_link_copy,
              enabled: tab.url != null,
              onSelected: () => unawaited(copyTabUrl(tab)),
            ),
          ]),
        ],
      ),
    );
  }

  WebBrowserTabCallbacks get _tabCallbacks => WebBrowserTabCallbacks(
    isActive: isActive,
    onSelect: (WebBrowserTab tab) {
      _tabs.activate(tab);
      if (_drawerOpen) setState(() => _drawerOpen = false);
    },
    onClose: closeTab,
    onNewTab: _newTab,
    onNewIncognitoTab: webBrowserIncognitoSupported()
        ? () => _newTab(incognito: true)
        : null,
    onContextMenu: _showTabContextMenu,
    onReorder: _tabs.reorder,
  );

  // ── 构建：chrome ─────────────────────────────────────────────────────

  /// 横向标签栏底色（与 [WebBrowserTabStrip] 自身一致；进标题行时整行同色）。
  Color _tabStripColor(BuildContext context) => isGlassDesign(context)
      ? appleColorsOf(context).groupedBackground
      : Theme.of(context).colorScheme.surface;

  /// 桌面自绘标题栏下，宽屏横向标签栏直接占标题栏那一行（Chrome / Edge 式），
  /// 不再在空着的标题行下面另起一行。网页全屏、工具栏收成迷你条时退回原排法
  /// （标题行仍是整条拖动区）。
  bool _tabStripInCaption(
    BuildContext context,
    WebBrowserShellLayout layout,
    Size size,
  ) {
    if (!FushiDesktopTitleBar.isEnabled) return false;
    if (layout != WebBrowserShellLayout.topStrip) return false;
    if (_tabs.activeTab?.fullscreen ?? false) return false;
    if (_collapseAllowed(layout, size) && _collapse.collapsed) return false;
    return MediaQuery.paddingOf(context).top > 0;
  }

  Color _barColor(BuildContext context) => isGlassDesign(context)
      ? appleColorsOf(context).secondaryGroupedBackground
      : Theme.of(context).colorScheme.surfaceContainer;

  Widget _addressBarFor(
    BuildContext context, {
    required bool reloadInside,
    required WebBrowserSuggestionsDirection direction,
  }) {
    final WebBrowserTab? tab = _tabs.activeTab;
    return WebBrowserAddressBar(
      key: _addressBar,
      url: tab?.url,
      focusNode: _addressFocus,
      suggestions: _suggestions,
      onSubmitted: _submitAddress,
      onOpenSuggestion: _openSuggestion,
      bookmarked: _bookmarked,
      onToggleBookmark: tab?.url != null && !(tab?.incognito ?? true)
          ? () => unawaited(_toggleBookmark())
          : null,
      onReload: reloadInside && tab?.url != null ? _reload : null,
      incognito: tab?.incognito ?? false,
      insecure: tab?.error?.kind == WebBrowserLoadErrorKind.certificate,
      direction: direction,
    );
  }

  Widget _iconButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool selected = false,
  }) => FushiIconButton(
    key: key,
    icon: icon,
    tooltip: tooltip,
    selected: selected,
    onTap: onTap,
  );

  /// 动作按钮 + 「⋯」：在 [budget] 宽度里能平铺几颗就平铺几颗。
  List<Widget> _actionButtons(
    BuildContext context, {
    required WebBrowserShellLayout layout,
    required double budget,
    Widget? beforeMenu,
    double beforeMenuWidth = 0,
  }) {
    final List<FushiToolbarItem> items = _toolbarItems(layout);
    final int visible = _toolbarFit.visibleFor(
      groups: <List<FushiToolbarItem>>[items],
      budget: budget - beforeMenuWidth,
      pinnedMenu: true,
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
    return <Widget>[
      for (final List<FushiToolbarItem> g in split.groups)
        for (final FushiToolbarItem item in g)
          _iconButton(
            key: item.key ?? ValueKey<String>(item.label),
            icon: item.icon,
            tooltip: item.label,
            selected: item.selected,
            onTap: item.onPressed,
          ),
      ?beforeMenu,
      Builder(
        builder: (BuildContext anchor) => _iconButton(
          key: const ValueKey<String>('web-browser-more'),
          icon: FushiIcons.more,
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          onTap: () => unawaited(
            showWebBrowserMenu(
              context: context,
              anchor: anchor,
              sections: _menuSections(layout: layout, overflow: split.overflow),
            ),
          ),
        ),
      ),
    ];
  }

  /// 宽窗口顶栏（48dp）：[侧边栏开关] 后退 刷新 | 地址栏 | 动作 ⋯。
  Widget _buildTopBar(
    BuildContext context,
    WebBrowserShellLayout layout, {
    required bool overlaySidebar,
    required bool compactHeight,
  }) {
    final WebBrowserTab? tab = _tabs.activeTab;
    final bool sidebar = layout == WebBrowserShellLayout.sidebar;
    final bool sidebarShown = overlaySidebar ? _drawerOpen : _sidebarOpen;
    final List<Widget> leading = <Widget>[
      _iconButton(
        key: const ValueKey<String>('web-browser-exit'),
        icon: FushiIcons.exitToApp,
        tooltip: t.web_browser_exit,
        onTap: _exitBrowser,
      ),
      if (sidebar)
        _iconButton(
          key: const ValueKey<String>('web-browser-sidebar-toggle'),
          icon: FushiIcons.sidebar,
          tooltip: t.web_browser_sidebar_toggle,
          selected: sidebarShown,
          onTap: () => _toggleSidebar(overlaySidebar),
        ),
      _iconButton(
        key: const ValueKey<String>('web-browser-back'),
        icon: FushiIcons.back,
        tooltip: t.back,
        onTap: _backOrLeave,
      ),
      if (!compactHeight)
        _iconButton(
          key: const ValueKey<String>('web-browser-reload'),
          icon: FushiIcons.refresh,
          tooltip: t.refresh,
          onTap: tab?.url != null ? _reload : null,
        ),
    ];
    return Container(
      key: const ValueKey<String>('web-browser-toolbar'),
      height: kWebBrowserTopBarHeight,
      color: _barColor(context),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double slot = fushiTopBarActionSlotWidth(context);
          final double addressMin = compactHeight ? 200 : 280;
          final double budget =
              box.maxWidth - leading.length * slot - addressMin - 16;
          return Row(
            children: <Widget>[
              ...leading,
              const SizedBox(width: 8),
              Expanded(
                child: _addressBarFor(
                  context,
                  reloadInside: compactHeight,
                  direction: WebBrowserSuggestionsDirection.down,
                ),
              ),
              const SizedBox(width: 8),
              ..._actionButtons(context, layout: layout, budget: budget),
            ],
          );
        },
      ),
    );
  }

  Widget _tabCountButton(BuildContext context) {
    final int count = _tabs.length;
    final ThemeData theme = Theme.of(context);
    final Color fg = isGlassDesign(context)
        ? appleColorsOf(context).label
        : theme.colorScheme.onSurface;
    return FushiTooltip(
      message: t.web_browser_tab_count(count: count),
      child: Semantics(
        button: true,
        label: t.web_browser_tab_count(count: count),
        excludeSemantics: true,
        child: FushiPressScale(
          child: InkResponse(
            key: const ValueKey<String>('web-browser-tab-count'),
            radius: 24,
            onTap: () => unawaited(_openGrid()),
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: fg, width: 1.8),
                    borderRadius: FushiBorderRadius.chip,
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 竖屏底栏：后退 | 地址栏（刷新在内）| 查词等动作 | 标签数 | ⋯。
  Widget _buildBottomBar(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: (DragEndDetails d) {
        if ((d.primaryVelocity ?? 0) > 200 &&
            webBrowserCollapseOnScroll(_prefs)) {
          setState(
            () => _collapse = const WebBrowserCollapseState(collapsed: true),
          );
        }
      },
      child: Container(
        key: const ValueKey<String>('web-browser-toolbar'),
        color: _barColor(context),
        padding: withBottomSafeInset(
          context,
          const EdgeInsets.fromLTRB(4, 6, 4, 6),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double slot = fushiTopBarActionSlotWidth(context);
            final double budget = box.maxWidth - slot - 180 - 8;
            return Row(
              children: <Widget>[
                _iconButton(
                  key: const ValueKey<String>('web-browser-back'),
                  icon: FushiIcons.back,
                  tooltip: t.back,
                  onTap: _backOrLeave,
                ),
                Expanded(
                  child: _addressBarFor(
                    context,
                    reloadInside: true,
                    direction: WebBrowserSuggestionsDirection.up,
                  ),
                ),
                const SizedBox(width: 4),
                ..._actionButtons(
                  context,
                  layout: WebBrowserShellLayout.bottomBar,
                  budget: budget,
                  beforeMenu: _tabCountButton(context),
                  beforeMenuWidth: slot,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 收起后的小地址条（26dp，只剩「🔒 域名」）：点一下或往回划展开。
  Widget _buildMiniBar(BuildContext context) {
    final Uri? url = _tabs.activeTab?.url;
    final ThemeData theme = Theme.of(context);
    void expand() =>
        setState(() => _collapse = const WebBrowserCollapseState());
    return Semantics(
      button: true,
      label: t.web_browser_toolbar_expand,
      child: GestureDetector(
        key: const ValueKey<String>('web-browser-mini-bar'),
        behavior: HitTestBehavior.opaque,
        onTap: expand,
        onVerticalDragEnd: (DragEndDetails _) => expand(),
        child: Container(
          height: kWebBrowserMiniBarHeight,
          color: isGlassDesign(context)
              ? appleColorsOf(context).groupedBackground
              : theme.colorScheme.surface,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(
                url?.scheme == 'https' ? FushiIcons.lock : FushiIcons.info,
                size: 12,
              ),
              const SizedBox(width: 4),
              Text(
                url?.host ?? t.web_browser_tab_new,
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _progressLine(BuildContext context) {
    final WebBrowserTab? tab = _tabs.activeTab;
    final bool loading = tab?.loading ?? false;
    return SizedBox(
      height: 2,
      child: AnimatedOpacity(
        opacity: loading ? 1 : 0,
        duration: fushiMotionDuration(context, FushiMotion.short),
        child: FushiLinearProgressIndicator(
          key: const ValueKey<String>('web-browser-progress'),
          value: loading ? tab!.progress : 1,
          minHeight: 2,
          backgroundColor: Colors.transparent,
        ),
      ),
    );
  }

  // ── 构建：内容 ───────────────────────────────────────────────────────

  Widget _buildStartView(BuildContext context, WebBrowserTab tab) {
    final List<WebBrowserSite> sites = _loadWebBrowserSites(_appModel);
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      key: ValueKey<String>('web-browser-start-${tab.id}'),
      color: isGlassDesign(context)
          ? appleColorsOf(context).groupedBackground
          : theme.colorScheme.surface,
      child: FushiEntranceScope(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisExtent: 116,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          itemCount: sites.length,
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int i) => _WebBrowserSiteTile(
              site: sites[i],
              onOpen: () => webBrowserSiteOpensInPlayer(sites[i])
                  ? unawaited(
                      openInWebVideoPlayer(
                        context,
                        url: sites[i].url,
                        title: sites[i].name,
                        repo: VideoBookRepository(_appModel.database),
                      ),
                    )
                  : _navigate(sites[i].url, tab: tab),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(BuildContext context, WebBrowserTab tab) {
    return ListenableBuilder(
      listenable: tab,
      builder: (BuildContext context, Widget? _) {
        // 没有地址的页画起始页——除了 window.open 开出的新窗口：它带 windowId，
        // Android 发起时 request.url 为 null，地址要等页面加载后由 WebView 回填；
        // 这时必须照常建 WebView 接走 windowId，否则平台侧挂着的新窗口没人认领，
        // 弹窗内容丢失、只剩一张空白起始页。
        if (tab.url == null && tab.windowId == null) {
          return _buildStartView(context, tab);
        }
        final WebBrowserLoadError? error = tab.error;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            FushiWebBrowserPage.debugTabViewBuilder?.call(context, tab) ??
                WebBrowserTabView(
                  key: ValueKey<String>(tab.id),
                  tab: tab,
                  host: this,
                  lookupEnabled: _lookupEnabled,
                ),
            if (error != null)
              WebBrowserErrorView(
                error: error,
                onRetry: () => retryTabLoad(tab),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTabs(BuildContext context) {
    final WebBrowserTab? active = _tabs.activeTab;
    final WebBrowserTab? findTab = active != null && active.findOpen
        ? active
        : null;
    final List<Widget> statusBars = <Widget>[
      for (final WebBrowserFeature f in _features)
        if (f.statusBar(context) case final Widget bar)
          KeyedSubtree(
            key: ValueKey<String>('web-browser-status-${f.id}'),
            child: bar,
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (findTab != null)
          WebBrowserFindBar(
            key: ValueKey<String>('web-browser-find-${findTab.id}'),
            tab: findTab,
          ),
        // 功能的进行中状态（可取消）：出现 / 消失走尺寸动画，时长取 FushiMotion。
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: statusBars,
          ),
        ),
        Expanded(
          child: _withSidePanel(
            context,
            active,
            Stack(
              fit: StackFit.expand,
              children: <Widget>[
                for (final WebBrowserTab tab in _tabs.tabs)
                  if (_tabs.isLive(tab) || identical(tab, active))
                    Offstage(
                      key: ValueKey<String>('web-browser-tab-${tab.id}'),
                      offstage: !identical(tab, active),
                      child: TickerMode(
                        enabled: identical(tab, active),
                        child: _buildTabBody(context, tab),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 功能侧栏（[WebBrowserFeature.sidePanel]）：宽（≥ 720dp）排在网页右侧 360dp，
  /// 窄窗口是盖住网页下半部的底部抽屉。网页本体的子树位置恒定（侧栏增删不重挂
  /// WebView，否则平台视图会重载）。全屏看视频时不出侧栏。
  Widget _withSidePanel(
    BuildContext context,
    WebBrowserTab? active,
    Widget pages,
  ) {
    Widget? panel;
    if (active != null && !active.fullscreen) {
      for (final WebBrowserFeature f in _features) {
        panel = f.sidePanel(context, active);
        if (panel != null) break;
      }
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool wide = box.maxWidth >= 720;
        final Duration d = fushiMotionDuration(context, FushiMotion.medium);
        final double panelWidth = wide ? 360 : box.maxWidth;
        final double panelHeight = wide ? box.maxHeight : box.maxHeight * 0.45;
        final bool open = panel != null;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            AnimatedPadding(
              duration: d,
              curve: FushiMotion.standard,
              padding: EdgeInsetsDirectional.only(
                end: wide && open ? panelWidth : 0,
              ),
              child: pages,
            ),
            AnimatedPositionedDirectional(
              duration: d,
              curve: FushiMotion.standard,
              end: wide ? (open ? 0 : -panelWidth) : 0,
              top: wide
                  ? 0
                  : (open ? box.maxHeight - panelHeight : box.maxHeight),
              width: panelWidth,
              height: panelHeight,
              child: AnimatedSwitcher(
                duration: d,
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                child: panel == null
                    ? const SizedBox.shrink()
                    : ClipRRect(
                        key: const ValueKey<String>('web-browser-side-panel'),
                        borderRadius: wide
                            ? BorderRadius.zero
                            : const BorderRadius.vertical(
                                top: Radius.circular(24),
                              ),
                        child: panel,
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSidebar(BuildContext context) => WebBrowserSidebar(
    tabs: _tabs.tabs,
    callbacks: _tabCallbacks,
    store: _store,
    onOpenUrl: (Uri url) {
      setState(() => _drawerOpen = false);
      _navigate(url);
    },
    onOpenPage: _openDataPage,
  );

  Widget _buildWide(
    BuildContext context,
    WebBrowserShellLayout layout,
    Size size,
  ) {
    final WebBrowserTab? tab = _tabs.activeTab;
    final bool fullscreen = tab?.fullscreen ?? false;
    final bool overlaySidebar = webBrowserSidebarOverlays(size: size);
    final bool compactHeight = size.height < kWebBrowserCompactHeight;
    final bool collapsed =
        _collapseAllowed(layout, size) && _collapse.collapsed;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    final bool sidebar = layout == WebBrowserShellLayout.sidebar;
    final bool pushOpen = sidebar && !overlaySidebar && _sidebarOpen;
    final bool drawerOpen = sidebar && overlaySidebar && _drawerOpen;
    final bool inCaption = _tabStripInCaption(context, layout, size);
    final double captionTop = MediaQuery.paddingOf(context).top;
    // 标签栏进了标题行：这一行要盖住标题栏让位高度（32），标签栏本身 36。
    final double stripHeight = inCaption
        ? math.max(kWebBrowserTabStripHeight, captionTop)
        : kWebBrowserTabStripHeight;

    final Widget chrome = fullscreen
        ? const SizedBox(width: double.infinity)
        : collapsed
        ? _buildMiniBar(context)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AnimatedContainer(
                duration: duration,
                curve: FushiMotion.standard,
                height: layout == WebBrowserShellLayout.topStrip
                    ? stripHeight
                    : 0,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.bottomCenter,
                    minHeight: stripHeight,
                    maxHeight: stripHeight,
                    child: _hiddenUnless(
                      layout == WebBrowserShellLayout.topStrip,
                      ColoredBox(
                        color: _tabStripColor(context),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: WebBrowserTabStrip(
                            tabs: _tabs.tabs,
                            callbacks: _tabCallbacks,
                            inCaption: inCaption,
                            captionInsets: inCaption
                                ? FushiDesktopTitleBar.captionReservedInsets(
                                    context,
                                  )
                                : EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _buildTopBar(
                context,
                layout,
                overlaySidebar: overlaySidebar,
                compactHeight: compactHeight,
              ),
            ],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 标题栏让位垫块。标签栏进了标题行时高度归零（那一行由标签栏自己占），
        // 节点本身恒在：增删它会让下面带 WebView 的子树错配重挂。
        if (!fullscreen)
          ColoredBox(
            color: _barColor(context),
            child: SizedBox(
              width: double.infinity,
              height: inCaption ? 0 : captionTop,
            ),
          ),
        ClipRect(
          child: FushiAnimatedSize(
            duration: duration,
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: chrome,
          ),
        ),
        if (!fullscreen) _progressLine(context),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AnimatedContainer(
                duration: duration,
                curve: FushiMotion.standard,
                width: pushOpen && !fullscreen ? kWebBrowserSidebarWidth : 0,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.centerRight,
                    minWidth: kWebBrowserSidebarWidth,
                    maxWidth: kWebBrowserSidebarWidth,
                    child: overlaySidebar
                        ? const SizedBox.shrink()
                        : _hiddenUnless(
                            pushOpen && !fullscreen,
                            _buildSidebar(context),
                          ),
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _buildTabs(context),
                    if (sidebar && overlaySidebar && !fullscreen) ...<Widget>[
                      IgnorePointer(
                        ignoring: !drawerOpen,
                        child: AnimatedOpacity(
                          opacity: drawerOpen ? 1 : 0,
                          duration: duration,
                          child: GestureDetector(
                            key: const ValueKey<String>(
                              'web-browser-sidebar-scrim',
                            ),
                            onTap: () => setState(() => _drawerOpen = false),
                            child: const ColoredBox(color: Color(0x47000000)),
                          ),
                        ),
                      ),
                      AnimatedPositioned(
                        duration: duration,
                        curve: FushiMotion.standard,
                        left: drawerOpen ? 0 : -kWebBrowserSidebarWidth - 16,
                        top: 0,
                        bottom: 0,
                        width: kWebBrowserSidebarWidth,
                        child: Material(
                          elevation: drawerOpen ? 4 : 0,
                          child: _buildSidebar(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 收起中的侧边栏 / 标签栏仍挂在树上（宽高过渡时内容跟着滑出），但收起后不能
  /// 被手柄 / 键盘焦点、读屏、指针摸到。
  Widget _hiddenUnless(bool shown, Widget child) => ExcludeFocus(
    excluding: !shown,
    child: ExcludeSemantics(
      excluding: !shown,
      child: IgnorePointer(ignoring: !shown, child: child),
    ),
  );

  bool _collapseAllowed(WebBrowserShellLayout layout, Size size) =>
      webBrowserToolbarCollapsible(layout: layout, size: size) &&
      webBrowserCollapseOnScroll(_prefs) &&
      !_addressFocus.hasFocus &&
      !_lookup.isOpen;

  /// 软键盘避让（本页不经 Scaffold，得自己做 Scaffold 的 resizeToAvoidBottomInset）：
  /// 整个壳底边让到键盘上方——竖屏底栏（地址栏）随键盘上移不被盖住，网页区域跟着
  /// 变矮（与浏览器 / 旧版 Scaffold 浏览页一致，网页里的输入框也露在键盘上方）。
  /// 键盘盖住了系统导航条，让位后底部安全区不再重复留白。布局形态仍按整窗尺寸判
  /// （[MediaQuery.sizeOf] 不含键盘），弹键盘不会在竖屏 / 宽屏两套壳之间来回切。
  ///
  /// 树形必须恒定：键盘开合时若在「裸 child」与「Padding 包 child」之间切换，父节点
  /// 类型一变整个壳（含各标签页的 InAppWebView）会被卸载重挂，网页随之重载、表单
  /// 输入丢失（Android 真机实测）。所以始终是同一个 Padding + MediaQuery，只改数值。
  Widget _avoidKeyboard(BuildContext context, Widget child) {
    final MediaQueryData media = MediaQuery.of(context);
    final double keyboard = media.viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard > 0 ? keyboard : 0),
      child: MediaQuery(
        data: keyboard > 0
            ? media
                  .removePadding(removeBottom: true)
                  .removeViewInsets(removeBottom: true)
            : media,
        child: child,
      ),
    );
  }

  Widget _buildNarrow(BuildContext context, Size size) {
    final WebBrowserTab? tab = _tabs.activeTab;
    final bool fullscreen = tab?.fullscreen ?? false;
    final bool collapsed =
        _collapseAllowed(WebBrowserShellLayout.bottomBar, size) &&
        _collapse.collapsed;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!fullscreen)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: const SafeArea(bottom: false, child: SizedBox.shrink()),
          ),
        // 必须带 key：网页全屏时这一列首尾的状态栏垫块与底栏同时增删，不带 key 的
        // 中间子节点在 Element.updateChildren 里配不上旧元素，整个网页区会被卸载
        // 重挂——WebView 销毁重建（页面重载），全屏中的网页被拆掉后原生全屏视图
        // 停在 app 上方冻结 / 白屏、退不出来（手机竖屏必现；宽屏布局只增删排在
        // 前面的子节点，自底向上能配上，不受影响）。
        Expanded(
          key: const ValueKey<String>('web-browser-narrow-tabs'),
          child: _buildTabs(context),
        ),
        if (!fullscreen) ...<Widget>[
          if (!collapsed) _progressLine(context),
          ClipRect(
            child: FushiAnimatedSize(
              duration: duration,
              curve: FushiMotion.standard,
              alignment: Alignment.bottomCenter,
              child: collapsed
                  ? Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom,
                      ),
                      child: _buildMiniBar(context),
                    )
                  : _buildBottomBar(context),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final WebBrowserShellLayout layout = webBrowserShellLayout(
      size: size,
      style: _tabStyle,
    );
    final WebBrowserTab? tab = _tabs.activeTab;
    final Color bg = isGlassDesign(context)
        ? appleColorsOf(context).groupedBackground
        : Theme.of(context).colorScheme.surface;
    final Widget body = _avoidKeyboard(
      context,
      layout == WebBrowserShellLayout.bottomBar
          ? _buildNarrow(context, size)
          : _buildWide(context, layout, size),
    );
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    // 标签栏画进了标题行：让标题栏把那一段命中让给标签栏。标签网格盖满整页时
    // 收回，空白标题行照旧能拖窗。
    return FushiTitleBarPassthroughScope(
      enabled: !_gridOpen && _tabStripInCaption(context, layout, size),
      child: PopScope(
        // 系统返回 / 侧滑 / Esc：先关查词弹窗与临时层，再退网页历史，都退到头
        // 才离开浏览页。
        canPop: _backStep == WebBrowserBackStep.leavePage,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) _onBackBlocked();
        },
        child: Focus(
          debugLabel: 'web-browser-shortcuts',
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKeyEvent,
          child: SrsCardLookupHost(
            controller: _lookup,
            // 制卡来源：调用时现读前台标签页（无痕页返回 null，卡片不带来源）。
            cardSource: () {
              final WebBrowserTab? active = _tabs.activeTab;
              final WebBrowserCardSource? source = active == null
                  ? null
                  : webBrowserCardSourceOf(active);
              return source == null
                  ? null
                  : (title: source.title, url: source.url);
            },
            child: Material(
              color: bg,
              child: Semantics(
                label: tab == null || tab.displayTitle.isEmpty
                    ? t.web_browser_title
                    : tab.displayTitle,
                container: true,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    body,
                    IgnorePointer(
                      ignoring: !_gridOpen,
                      child: AnimatedSwitcher(
                        duration: duration,
                        switchInCurve: FushiMotion.enter,
                        switchOutCurve: FushiMotion.exit,
                        transitionBuilder:
                            (Widget child, Animation<double> animation) =>
                                FadeTransition(
                                  opacity: fushiUnitClamped(animation),
                                  child: ScaleTransition(
                                    scale: Tween<double>(
                                      begin: 0.96,
                                      end: 1,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                        child: _gridOpen
                            ? WebBrowserTabGrid(
                                tabs: _tabs.tabs,
                                callbacks: _tabCallbacks,
                                thumbnails: _thumbnails,
                                onDone: () => setState(() => _gridOpen = false),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
