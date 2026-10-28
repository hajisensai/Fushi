import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 浏览器的可插拔功能（「用 Fushi 播放」、YouTube 字幕查词、阅读模式、
/// 学习统计……）。浏览页只认这个接口：每个功能一个实现类，装配点只有
/// `web_browser_features.dart` 的 [buildWebBrowserFeatures]，浏览页不为某个功能
/// 写特判。
///
/// 生命周期：一个浏览页（含它的全部标签页）一份实例；每个标签页的 WebView 建好 /
/// 每次主框架加载完都回调一次，[tab] 区分是哪一页。
abstract class WebBrowserFeature {
  /// 稳定 id（测试 / 日志用）。
  String get id;

  /// 是否在本平台 / 本合规门下装配；false 时浏览页完全不装它。
  bool get available => true;

  /// 每个新文档开始时注入的脚本（`initialUserScripts`）。
  List<UserScript> userScripts() => const <UserScript>[];

  /// WebView 建好：在这里 `addJavaScriptHandler`。
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {}

  /// 主框架加载完成（`onLoadStop`）。
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {}

  /// 主框架地址变了（`onUpdateVisitedHistory`：含单页应用 pushState 换页，那种换页不触发
  /// [onLoadStop]）。[context] 是标签页自己的，可用来推页面。
  void onUrlChanged(
    BuildContext context,
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) {}

  /// 标签页成为 / 不再是前台标签页（统计计时、暂停注入等用）。
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) {}

  /// 标签页关闭（WebView 即将销毁）。
  void onTabClosed(WebBrowserTab tab) {}

  /// 给当前标签页提供的动作；浏览页按 [WebBrowserAction.placement] 摆进工具栏或
  /// 「⋯」菜单。只在动作对 [tab] 当前页面有意义时返回（例如「用 Fushi 播放」只在
  /// YouTube 观看页）。
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) =>
      const <WebBrowserAction>[];

  /// 功能自身状态变了（开关类动作的 [WebBrowserAction.selected]、某个动作出现 /
  /// 消失、[statusBar] 出现 / 消失），而标签页本身没变：壳监听它重建工具栏 /
  /// 「⋯」菜单 / 状态条。null = 动作只随标签页状态变化。
  Listenable? get actionsChanged => null;

  /// 功能正在进行、需要用户看见并能取消的状态（例如「正在等系统浏览器送回登录」）：
  /// 壳把它排在页面内容上方（查找条下面），出现 / 消失带尺寸动画。null = 没有。
  /// 变化经 [actionsChanged] 通知。用设计系统的横幅组件（`FushiInlineNotice`）。
  Widget? statusBar(BuildContext context) => null;

  /// 功能给前台标签页 [tab] 配的侧栏（例如网页视频的字幕列表）：宽窗口排在网页右侧，
  /// 窄窗口作为底部抽屉盖在网页下半部，出现 / 消失带动画。null = 没有。变化经
  /// [actionsChanged] 通知。
  Widget? sidePanel(BuildContext context, WebBrowserTab tab) => null;

  /// 浏览页销毁。
  void dispose() {}
}

/// [WebBrowserFeature.actionsChanged] 的现成实现：功能内部 `notify()` 一下。
class WebBrowserFeatureNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// 功能动作摆放的位置。
enum WebBrowserActionPlacement {
  /// 顶栏 / 底栏工具栏（宽度不够时按 [WebBrowserAction.priority] 收进「⋯」）。
  toolbar,

  /// 恒在「⋯」菜单里。
  menu,
}

/// 功能贡献的一个动作。
@immutable
class WebBrowserAction {
  const WebBrowserAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.placement = WebBrowserActionPlacement.menu,
    this.priority = 50,
    this.selected = false,
  });

  final String id;
  final IconData icon;
  final String label;

  /// null = 禁用。
  final VoidCallback? onPressed;
  final WebBrowserActionPlacement placement;

  /// 越大越晚被收进「⋯」（0..100；导航类内置动作占 90+）。
  final int priority;

  /// 开关类动作的当前状态。
  final bool selected;
}
