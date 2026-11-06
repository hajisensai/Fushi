import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 浏览页（壳）提供给每个标签页 WebView（`WebBrowserTabView`）的能力。
/// 壳实现，标签页只调这些，不直接碰标签列表 / 布局。
abstract interface class WebBrowserTabHost {
  WebBrowserStore get store;

  /// 已过合规门 / 平台门的功能（见 `buildWebBrowserFeatures`）。
  List<WebBrowserFeature> get features;

  /// 开新标签页。[windowId] 来自 `onCreateWindow`，新标签页的 WebView 必须用它
  /// 创建；[activate] 为 false = 后台打开（链接菜单「在后台标签页打开」）。
  WebBrowserTab openTab(
    Uri? url, {
    String? openerId,
    int? windowId,
    bool incognito = false,
    bool activate = true,
  });

  /// 关闭标签页（网页 `window.close()` / 用户关）。
  void closeTab(WebBrowserTab tab);

  bool isActive(WebBrowserTab tab);

  /// 网页内容纵向滚动（正 = 往下读）。壳据此收起 / 展开工具栏。
  void onContentScrolled(WebBrowserTab tab, {required int y, required int dy});

  /// 网页要求进入 / 退出全屏（视频）：壳隐藏 / 恢复全部 chrome 与系统栏。
  void onFullscreenChanged(WebBrowserTab tab, {required bool fullscreen});
}
