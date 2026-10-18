import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/pages/implementations/video_web_sites_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 「浏览器」模块（[ModuleId.web]）的子页（顺序即页签顺序）。
///
/// 2026-10-19 用户拍板：app 内直接浏览网站（Netflix / YouTube 等站点在原生播放器页
/// 里看）取代「装浏览器扩展」成为主路径，浏览器扩展降为本模块的次级子页。
enum WebHubSection {
  /// 通用 app 内浏览器（[FushiWebBrowserPage]）：五端都有，网页上查词；漫画站上的
  /// 「用 Fushi 阅读本章」由页内自己按在线漫画源合规门控。
  browse,

  /// 网页视频站点（[VideoWebSitesPage]），仅 Windows（[webVideoSitesAvailable]）。
  videoSites,

  /// 浏览器扩展安装与连接状态（[BrowserExtensionPage]），仅桌面。
  browserExtension,
}

/// 本平台上 [section] 是否存在。平台判据各自只写一处：视频站点问
/// [webVideoSitesAvailable]，浏览器扩展问 [browserExtensionSupportedOn]。
bool webHubSectionAvailable(WebHubSection section) => switch (section) {
  WebHubSection.browse => true,
  WebHubSection.videoSites => webVideoSitesAvailable(),
  WebHubSection.browserExtension => browserExtensionSupportedOn(
    isDesktop: DesktopLookupService.isDesktop,
  ),
};

/// 「浏览器」模块的顶层页：子页页签占各子页页头的标题位（与库页壳同一形态），子页按
/// 访问惰性构建、保活。
///
/// 只有一个子页可用时（如 macOS / Linux 只有浏览器扩展）不画页签，子页画自己的标题。
class WebHubPage extends StatefulWidget {
  const WebHubPage({required this.videoRepo, super.key});

  /// 站点里看过的每一集落成流媒体书时用的视频库仓库。
  final VideoBookRepository videoRepo;

  @override
  State<WebHubPage> createState() => _WebHubPageState();
}

class _WebHubPageState extends State<WebHubPage> {
  late final List<WebHubSection> _sections = <WebHubSection>[
    for (final WebHubSection section in WebHubSection.values)
      if (webHubSectionAvailable(section)) section,
  ];

  /// null = 本平台一个子页都没有（漫画 / 通用浏览子页接入前的移动端）。
  late WebHubSection? _section = _sections.firstOrNull;
  late final Set<WebHubSection> _visited = <WebHubSection>{?_section};

  void _select(WebHubSection value) {
    if (value == _section) return;
    setState(() {
      _section = value;
      _visited.add(value);
    });
  }

  String _label(WebHubSection section) => switch (section) {
    WebHubSection.browse => t.web_hub_browse,
    WebHubSection.videoSites => t.web_hub_video_sites,
    WebHubSection.browserExtension => t.nav_browser_extension,
  };

  Widget? _navigation() {
    if (_sections.length < 2) return null;
    return LibrarySectionTabs<WebHubSection>(
      key: const ValueKey<String>('web-hub-sections'),
      tabs: <LibrarySectionTab<WebHubSection>>[
        for (final WebHubSection section in _sections)
          LibrarySectionTab<WebHubSection>(
            value: section,
            label: _label(section),
          ),
      ],
      selected: _section!,
      onChanged: _select,
      focusIdPrefix: 'web-hub-tab',
    );
  }

  Widget _buildSection(WebHubSection section, Widget? navigation) =>
      switch (section) {
        WebHubSection.browse => FushiWebBrowserPage(
          key: const ValueKey<String>('web-hub-browse'),
          navigation: navigation,
        ),
        WebHubSection.videoSites => VideoWebSitesPage(
          key: const ValueKey<String>('web-hub-video-sites'),
          repo: widget.videoRepo,
          navigation: navigation ?? Text(_label(section)),
        ),
        WebHubSection.browserExtension => BrowserExtensionPage(
          key: const ValueKey<String>('web-hub-browser-extension'),
          navigation: navigation,
        ),
      };

  @override
  Widget build(BuildContext context) {
    if (_section == null) {
      return Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiPageHeader(title: t.nav_web),
            Expanded(child: Center(child: Text(t.web_hub_empty))),
          ],
        ),
      );
    }
    final Widget? navigation = _navigation();
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
