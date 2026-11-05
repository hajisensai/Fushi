// 内存采样探针（[PreviousExitLog.startMemorySampling]）：采样窗口里出了几帧、此刻用户看得见哪些页面。
//
// BUG-4075：同一台 Android 停在 SRS 页 / 小说统计页不动，native malloc 以约 10 MB/s 匀速上涨直到
// Scudo OOM，SRS 账本证明那几分钟 SRS 零活动。匀速上涨的形态像「每帧泄漏」，但采样里没有两样证据：
// ① 停着不动时是否仍在持续出帧（有东西在逐帧重绘）；② 当时停在哪一页（根导航的路由大多是匿名
// MaterialPageRoute，首页各 tab 也不是路由）。本探针补这两样：
//
// - `frames=N`：上次采样以来 [SchedulerBinding] 跑过的帧数（持久帧回调计数，O(1)）；
// - `page=[A>B]`：沿元素树找类型名以 `Page` 结尾的 widget，跳过 `TickerMode(enabled: false)` 的子树
//   ——被盖住的路由、IndexedStack 里没显示的 tab 都在那种子树里，它们的动画不跑、不会逐帧画。
//   顺序 = 树中先序（外层在前，栈顶路由在后）。

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// `page=[…]` 最多列几个页面（取最后几个：最靠里 / 最靠栈顶的那些）。
const int kUiActivityMaxPages = 4;

/// 一次走树最多访问的元素数：超过就停（取证不能反过来卡 UI 线程）。
const int kUiActivityMaxElements = 200000;

/// 采样窗口帧计数 + 可见页面。全进程一份，[install] 在生产启动时调一次。
abstract final class UiActivityProbe {
  static int _frames = 0;
  static bool _installed = false;

  /// 挂上持久帧回调（幂等）。持久帧回调没有注销接口，所以只在生产启动时装一次。
  static void install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addPersistentFrameCallback((Duration _) {
      _frames++;
    });
  }

  /// 测试收尾：清零计数。
  @visibleForTesting
  static void resetFrames() => _frames = 0;

  /// 取走窗口帧数并清零，附上此刻可见页面：`frames=123 page=[HomePage>SrsHomePage]`。
  static String? probe() {
    final int frames = _frames;
    _frames = 0;
    final List<String> pages = visiblePageNames(
      WidgetsBinding.instance.rootElement,
    );
    final StringBuffer b = StringBuffer();
    if (_installed) b.write('frames=$frames');
    if (pages.isNotEmpty) {
      if (b.isNotEmpty) b.write(' ');
      b.write('page=[${pages.join('>')}]');
    }
    return b.isEmpty ? null : b.toString();
  }
}

/// 从 [root] 先序走元素树，收集类型名以 `Page` 结尾的 widget（相邻重复只记一次），跳过
/// `TickerMode(enabled: false)` 的子树；只返回最后 [maxPages] 个。[root] 为空返回空表。
@visibleForTesting
List<String> visiblePageNames(
  Element? root, {
  int maxPages = kUiActivityMaxPages,
  int maxElements = kUiActivityMaxElements,
}) {
  if (root == null) return const <String>[];
  final List<String> pages = <String>[];
  int visited = 0;
  void visit(Element element) {
    if (visited >= maxElements) return;
    visited++;
    final Widget widget = element.widget;
    if (widget is TickerMode && !widget.enabled) return;
    final String full = widget.runtimeType.toString();
    final int generic = full.indexOf('<');
    final String name = generic < 0 ? full : full.substring(0, generic);
    if (name.endsWith('Page') && (pages.isEmpty || pages.last != name)) {
      pages.add(name);
    }
    element.visitChildElements(visit);
  }

  visit(root);
  return pages.length <= maxPages
      ? pages
      : pages.sublist(pages.length - maxPages);
}
