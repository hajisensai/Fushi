import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'package:fushi/src/web_browser/web_browser_prefs.dart';

/// 浏览页 chrome（地址栏 + 工具栏）摆在哪。
enum WebBrowserChromeLayout {
  /// 窄窗口（手机竖屏等）：地址栏与工具栏都收在底部（拇指区），顶部只留状态栏。
  bottom,

  /// 宽窗口（横屏 / 桌面）：地址栏与工具栏并成顶部一行，竖向空间全让给网页。
  top,
}

/// 低于这个窗口宽度时 chrome 收到底部。
const double kWebBrowserChromeTopMinWidth = 600;

/// 只按窗口宽度分，不看平台（用户 2026-10-20：「不要按平台判断，按宽度」）：
/// 宽窗口只留顶部一行，窄窗口只留底部。
WebBrowserChromeLayout webBrowserChromeLayout({required Size size}) =>
    size.width >= kWebBrowserChromeTopMinWidth
    ? WebBrowserChromeLayout.top
    : WebBrowserChromeLayout.bottom;

/// 浏览页整体版式（chrome 位置 × 标签页样式）。
enum WebBrowserShellLayout {
  /// 窄窗口：底栏 + 「标签数」按钮打开全屏标签页网格；不受标签页样式影响。
  bottomBar,

  /// 宽窗口 + 侧边栏样式：顶栏最左是侧边栏开关。
  sidebar,

  /// 宽窗口 + 顶部标签栏样式：地址栏上方一排横向标签。
  topStrip,
}

WebBrowserShellLayout webBrowserShellLayout({
  required Size size,
  required WebBrowserTabStyle style,
}) {
  if (webBrowserChromeLayout(size: size) == WebBrowserChromeLayout.bottom) {
    return WebBrowserShellLayout.bottomBar;
  }
  return switch (style) {
    WebBrowserTabStyle.sidebar => WebBrowserShellLayout.sidebar,
    WebBrowserTabStyle.topStrip => WebBrowserShellLayout.topStrip,
  };
}

/// 侧边栏宽度（设计图 v4）。
const double kWebBrowserSidebarWidth = 260;

/// 顶部标签栏高度。
const double kWebBrowserTabStripHeight = 36;

/// 顶栏高度。
const double kWebBrowserTopBarHeight = 48;

/// 收起后的小地址条高度（v3：26dp）。
const double kWebBrowserMiniBarHeight = 26;

/// 侧边栏挤开网页后，网页至少还要留这么宽；留不够就改成盖在网页上的抽屉。
const double kWebBrowserSidebarPushMinContentWidth = 600;

/// 低于这个高度算「矮窗口」（手机横屏约 390）：工具栏可以随滚动收起。
const double kWebBrowserCompactHeight = 520;

/// 侧边栏是盖在网页上的抽屉（手机横屏 / 窄平板）还是挤开网页（桌面）。
/// 只按窗口尺寸判，不看平台。
bool webBrowserSidebarOverlays({required Size size}) =>
    size.width - kWebBrowserSidebarWidth <
        kWebBrowserSidebarPushMinContentWidth ||
    size.height < kWebBrowserCompactHeight;

/// 这个版式下工具栏能否随网页滚动收起成小地址条：竖屏底栏恒可；宽窗口只在矮
/// 窗口（手机横屏）上可——桌面不做滚动收起，栏一直在（v3）。
bool webBrowserToolbarCollapsible({
  required WebBrowserShellLayout layout,
  required Size size,
}) =>
    layout == WebBrowserShellLayout.bottomBar ||
    size.height < kWebBrowserCompactHeight;

/// 滚动收起的累积阈值（逻辑像素，v3 原型同值）：同方向累计滚过它才翻转状态，
/// 单次抖动不翻。
const double kWebBrowserCollapseScrollThreshold = 24;

/// 滚动收起状态机（纯函数）。[y] 是网页当前纵向滚动位置，[dy] 是这一次的增量
/// （正 = 往下读）；[accumulated] 是上一次返回的累计量。滚回顶部恒展开。
@immutable
class WebBrowserCollapseState {
  const WebBrowserCollapseState({this.collapsed = false, this.accumulated = 0});

  final bool collapsed;
  final double accumulated;

  WebBrowserCollapseState onScroll({required int y, required int dy}) {
    if (y <= 0) return const WebBrowserCollapseState();
    if (dy == 0) return this;
    // 换方向时清零重新累计。
    double acc = accumulated;
    if ((dy > 0 && acc < 0) || (dy < 0 && acc > 0)) acc = 0;
    acc += dy;
    if (acc > kWebBrowserCollapseScrollThreshold) {
      return const WebBrowserCollapseState(collapsed: true);
    }
    if (acc < -kWebBrowserCollapseScrollThreshold) {
      return const WebBrowserCollapseState();
    }
    return WebBrowserCollapseState(collapsed: collapsed, accumulated: acc);
  }

  @override
  bool operator ==(Object other) =>
      other is WebBrowserCollapseState &&
      other.collapsed == collapsed &&
      other.accumulated == accumulated;

  @override
  int get hashCode => Object.hash(collapsed, accumulated);
}

/// 浏览页上按一次「返回」（Android 系统返回 / iOS 侧滑 / 桌面 Esc）该做的那一步。
enum WebBrowserBackStep {
  /// 功能插件吃掉这次返回（关掉查词弹窗等，弹窗栈在本页路由之内）。
  closeLookup,

  /// 退出网页全屏 / 关掉页内查找等浏览器自身的临时层。
  dismissOverlay,

  /// 退一步网页历史。
  webHistoryBack,

  /// 关掉当前标签页、回到打开它的那一页（它是从别的标签页开出来的且没有历史）。
  closeTab,

  /// 离开浏览页（放行路由 pop）。
  leavePage,
}

/// 返回的优先级：功能层（查词弹窗）→ 浏览器临时层（全屏 / 页内查找）→ 网页历史
/// → 关掉由别的标签页打开的子页 → 离开浏览页。弹窗开着时若直接退网页历史
/// （或没有历史时整页 pop），弹窗会留在已经换掉的网页上 / 随浏览页一起被关掉。
WebBrowserBackStep webBrowserBackStep({
  required bool lookupOpen,
  required bool canGoBack,
  bool overlayOpen = false,
  bool openedByOtherTab = false,
}) {
  if (lookupOpen) return WebBrowserBackStep.closeLookup;
  if (overlayOpen) return WebBrowserBackStep.dismissOverlay;
  if (canGoBack) return WebBrowserBackStep.webHistoryBack;
  if (openedByOtherTab) return WebBrowserBackStep.closeTab;
  return WebBrowserBackStep.leavePage;
}

/// 地址栏里把地址拆成「前缀（淡）/ 域名（加粗）/ 其余（淡）」三段（设计图 v4）。
({String prefix, String host, String rest}) webBrowserAddressParts(Uri url) {
  if (url.host.isEmpty) return (prefix: '', host: url.toString(), rest: '');
  final String full = url.toString();
  final int at = full.indexOf(url.host);
  if (at < 0) return (prefix: '', host: full, rest: '');
  return (
    prefix: full.substring(0, at),
    host: url.host,
    rest: full.substring(at + url.host.length),
  );
}
