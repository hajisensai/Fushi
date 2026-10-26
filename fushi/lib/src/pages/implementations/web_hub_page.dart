import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiShellInlineTitle, kFushiFloatingChromeGap;
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

/// 「浏览器」模块的顶层页：子页页签占各子页页头的标题位（与库页壳同一形态），子页按
/// 访问惰性构建、保活。
///
/// 只有一个子页可用时（如 macOS / Linux 只有浏览器扩展）不画页签，子页画自己的标题。
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

  void _select(WebHubSection value) {
    if (value == _section) return;
    setState(() {
      _section = value;
      _visited.add(value);
    });
  }

  String _label(WebHubSection section) => switch (section) {
    WebHubSection.browse => t.web_hub_browse,
    WebHubSection.browserExtension => t.nav_browser_extension,
  };

  /// 页头主位：与视频库 / 浏览页同一套门头——外壳页面名的标题胶囊（宽窗 M3E，
  /// [FushiShellInlineTitle]）+ 贴合内容宽的悬浮页签胶囊（2026-10-20 用户截图：
  /// 整宽轨道页签下面多出一截空底、也没有「浏览器」标题，和其它库页不一致）。
  Widget? _navigation(BuildContext context) {
    if (_sections.length < 2) return null;
    final Widget tabs = LibrarySectionTabs<WebHubSection>(
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
    final String? shellTitle = FushiShellInlineTitle.of(context)
        ? FushiShellTitleScope.maybeTitleOf(context)
        : null;
    if (shellTitle == null || shellTitle.isEmpty) return tabs;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Row(
        children: <Widget>[
          ConstrainedBox(
            // 与 FushiFloatingChromeBar 同口径：标题胶囊限到行宽 1/3，超长名省略。
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth.isFinite
                  ? constraints.maxWidth / 3
                  : double.infinity,
            ),
            child: KeyedSubtree(
              key: const ValueKey<String>('web-hub-shell-title'),
              child: FushiPageChromeTitle(title: Text(shellTitle)),
            ),
          ),
          const SizedBox(width: kFushiFloatingChromeGap),
          Expanded(child: tabs),
        ],
      ),
    );
  }

  Widget _buildSection(WebHubSection section, Widget? navigation) =>
      switch (section) {
        WebHubSection.browse => FushiWebBrowserHomePage(
          key: const ValueKey<String>('web-hub-browse'),
          navigation: navigation,
        ),
        WebHubSection.browserExtension => BrowserExtensionPage(
          key: const ValueKey<String>('web-hub-browser-extension'),
          navigation: navigation,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = _navigation(context);
    return Stack(
      children: <Widget>[
        for (final WebHubSection section in _sections)
          if (_visited.contains(section))
            Offstage(
              offstage: section != _section,
              child: SectionVisibilityScope(
                visible: section == _section,
                child: TickerMode(
                  enabled: section == _section,
                  // 切子页走共享轴转场的同一套时长（墨水屏 / 减弱动态效果下归零）。
                  child: AnimatedOpacity(
                    opacity: section == _section ? 1 : 0,
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    curve: FushiMotion.standard,
                    child: _buildSection(section, navigation),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
