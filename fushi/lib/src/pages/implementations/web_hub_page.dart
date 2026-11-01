import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeController,
        FushiFloatingChromeInset,
        FushiFloatingChromeOverlay,
        FushiFloatingChromeScope,
        FushiShellInlineTitle;
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/utils.dart';

/// 「浏览器」模块（[ModuleId.web]）的子页（顺序即页签顺序）。
///
/// 2026-10-19 用户拍板：app 内直接浏览网站（Netflix / YouTube 等站点在原生播放器页
/// 里看）取代「装浏览器扩展」成为主路径，浏览器扩展降为本模块的次级子页。
///
/// 2026-10-26 用户：「这个站点和视频站点有什么关系？有必要分开吗？」——原「视频站点」
/// 子页并进通用浏览的站点表：站点可标成「用播放页打开」，浏览页里也有「用 Fushi 播放」
/// 按钮（Windows），见 `web_browser_site_launch.dart`。
enum WebHubSection {
  /// 通用 app 内浏览器：模块页里是入口（[FushiWebBrowserHomePage]，地址栏 + 站点），
  /// 打开网址推全屏浏览页（[FushiWebBrowserPage]），标了「用播放页打开」的站点在
  /// Windows 上进视频播放页。五端都有，网页上查词；漫画站上的「用 Fushi 阅读本章」
  /// 由浏览页自己按在线漫画源合规门控。
  browse,

  /// 浏览器扩展安装与连接状态（[BrowserExtensionPage]），仅桌面。
  browserExtension,
}

/// 本平台上 [section] 是否存在。浏览器扩展问 [browserExtensionSupportedOn]。
bool webHubSectionAvailable(WebHubSection section) => switch (section) {
  WebHubSection.browse => true,
  WebHubSection.browserExtension => browserExtensionSupportedOn(
    isDesktop: DesktopLookupService.isDesktop,
  ),
};

/// 「浏览器」模块的顶层页：与视频 / 书架 / 游戏 / 音乐库页同一套外壳——
/// 「标题胶囊 + 子页页签胶囊」这一行由本页的 [FushiFloatingChromeBar] 统一画
/// （标题胶囊按 [FushiShellInlineTitle] / [FushiShellTitleScope] 自动出），
/// 叠在子页上、随滚动收放；子页只画正文、从这一行下方开始（消费
/// [FushiFloatingChromeInset]），切页签时这颗胶囊位置大小恒定（2026-11-01 用户
/// 截图：两个子页各自把页签摆进自己的页头，切页签胶囊会跳，也没有模块标题）。
///
/// 子页按访问惰性构建、保活。只有一个子页可用时（如 macOS / Linux 只有浏览器
/// 扩展、手机只有网页）不画页签，这一行只剩外壳给的标题胶囊（宽窗 M3E）；
/// 窄窗 M3E 模块名已在底部导航上，整行为空；Apple 由首页外壳的大标题行画模块名。
class WebHubPage extends StatefulWidget {
  const WebHubPage({super.key});

  @override
  State<WebHubPage> createState() => _WebHubPageState();
}

class _WebHubPageState extends State<WebHubPage> {
  late final List<WebHubSection> _sections = <WebHubSection>[
    for (final WebHubSection section in WebHubSection.values)
      if (webHubSectionAvailable(section)) section,
  ];

  /// 通用浏览子页五端都有（[webHubSectionAvailable] 恒为 true），所以至少有一个子页。
  late WebHubSection _section = _sections.first;
  late final Set<WebHubSection> _visited = <WebHubSection>{_section};

  /// 工具栏行的显隐（滚动驱动，与库页同一套规则）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 工具栏行右侧的动作组槽。两个子页目前都没有页头动作，槽恒为空；保留它是
  /// 为了与库页壳同构（[FushiFloatingChromeBar] 必填），也不让子树误把动作登记
  /// 进首页外壳的槽。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  @override
  void dispose() {
    _chrome.dispose();
    _actionsSlot.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    // 保活的离屏子页（TickerMode 关着）发来的通知不算。
    if (!fushiNotificationFromVisibleSubtree(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  void _select(WebHubSection value) {
    if (value == _section) return;
    // 换了子页，新页面从顶部开始：工具栏回来。
    _chrome.resetToTop();
    setState(() {
      _section = value;
      _visited.add(value);
    });
  }

  String _label(WebHubSection section) => switch (section) {
    WebHubSection.browse => t.web_hub_browse,
    WebHubSection.browserExtension => t.nav_browser_extension,
  };

  /// 子页页签胶囊（贴合内容宽的悬浮胶囊）；只有一个子页时不画。
  Widget _tabs() {
    if (_sections.length < 2) return const SizedBox.shrink();
    return LibrarySectionTabs<WebHubSection>(
      key: const ValueKey<String>('web-hub-sections'),
      tabs: <LibrarySectionTab<WebHubSection>>[
        for (final WebHubSection section in _sections)
          LibrarySectionTab<WebHubSection>(
            value: section,
            label: _label(section),
            orderId: section.name,
          ),
      ],
      selected: _section,
      onChanged: _select,
      focusIdPrefix: 'web-hub-tab',
      floating: true,
      // 反馈 ndQ5eXLcqp：长按 / 右键页签栏自定义顶部页签顺序。
      orderKey: 'web',
    );
  }

  /// 工具栏行：既没有页签、外壳也不把标题交给本行时（窄窗 M3E / Apple 的单子页）
  /// 整行为空，不占高度。
  Widget _chromeBar(BuildContext context) {
    final String? shellTitle = FushiShellInlineTitle.of(context)
        ? FushiShellTitleScope.maybeTitleOf(context)
        : null;
    final bool hasTitle = shellTitle != null && shellTitle.isNotEmpty;
    if (_sections.length < 2 && !hasTitle) return const SizedBox.shrink();
    return FushiFloatingChromeBar(tabs: _tabs(), slot: _actionsSlot);
  }

  Widget _buildSection(WebHubSection section) => switch (section) {
    WebHubSection.browse => const FushiWebBrowserHomePage(
      key: ValueKey<String>('web-hub-browse'),
      hostedByHub: true,
    ),
    WebHubSection.browserExtension => const BrowserExtensionPage(
      key: ValueKey<String>('web-hub-browser-extension'),
      hostedByHub: true,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return FushiShellTitleScope(
      // 保留外壳给本 tab 的页面名，只把动作槽换成本页自己的。
      title: FushiShellTitleScope.maybeTitleOf(context),
      actionsSlot: _actionsSlot,
      child: FushiFloatingChromeScope(
        controller: _chrome,
        // 工具栏叠在子页上，收起只滑出画面、不改子页视口高度。
        child: FushiFloatingChromeOverlay(
          chrome: _chromeBar(context),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Stack(
              children: <Widget>[
                for (final WebHubSection section in _sections)
                  if (_visited.contains(section))
                    Offstage(
                      offstage: section != _section,
                      child: SectionVisibilityScope(
                        visible: section == _section,
                        child: TickerMode(
                          enabled: section == _section,
                          // 切子页走共享轴转场的同一套时长（墨水屏 / 减弱动态
                          // 效果下归零）。
                          child: AnimatedOpacity(
                            opacity: section == _section ? 1 : 0,
                            duration: fushiMotionDuration(
                              context,
                              FushiMotion.medium,
                            ),
                            curve: FushiMotion.standard,
                            child: _buildSection(section),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
