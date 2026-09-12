import 'package:flutter/widgets.dart';

import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// global scope 的页面滚动动作（六件套）在键盘 / 手柄 / 鼠标三条通道上**共用的**
/// 执行体。三条通道各自只做「按钮 → ShortcutAction」的解析，落地一律走这里，滚动
/// 目标一律经 [FushiFocusScroll.resolveActivePageScrollable]——绝不允许某条通道
/// 私藏一份「只认 PageScrollRegistry」的旧路径，那正是键盘滚不动大半页面的根因。
enum PageScrollRequest {
  lineUp,
  lineDown,
  pageUp,
  pageDown,
  toTop,
  toBottom;

  /// 朝内容末尾（向下）还是朝开头（向上）。
  bool get towardEnd => switch (this) {
        lineDown || pageDown || toBottom => true,
        lineUp || pageUp || toTop => false,
      };
}

/// 单步滚动的 viewport 比例（↑/↓ 一次）。与手柄「列表边缘接管」的 0.8 / 整屏的
/// 0.9 同一量纲，取 0.15 ≈ 一行多一点：高分屏上不会一按就跳走半屏，也不至于
/// 按十下才动一行。
const double kPageScrollLineFraction = 0.15;

/// 整屏滚动的 viewport 比例（PageUp / PageDown、手柄 LB / RB）。留 0.1 重叠让
/// 用户能接上上一屏的末行。
const double kPageScrollPageFraction = 0.9;

/// [action] 是不是页面滚动动作；是则给出请求，否则 null。
PageScrollRequest? pageScrollRequestFor(ShortcutAction? action) {
  switch (action) {
    case ShortcutAction.globalScrollLineUp:
      return PageScrollRequest.lineUp;
    case ShortcutAction.globalScrollLineDown:
      return PageScrollRequest.lineDown;
    case ShortcutAction.globalScrollPageUp:
      return PageScrollRequest.pageUp;
    case ShortcutAction.globalScrollPageDown:
      return PageScrollRequest.pageDown;
    case ShortcutAction.globalScrollToTop:
      return PageScrollRequest.toTop;
    case ShortcutAction.globalScrollToBottom:
      return PageScrollRequest.toBottom;
    default:
      return null;
  }
}

/// 执行一次页面滚动。返回**是否真的滚了**：false 时调用方不得认领这次输入
/// （键盘返回 ignored / 鼠标不 claim），让更外层或框架接手——「解析到但没滚」
/// 若也吞键，纯展示页上到底之后方向键就成了黑洞。
///
/// [focusContext] 是焦点所在的 context（决定阶梯前三级），[navigator] 供第四级
/// 零登记兜底从当前路由子树里找 Scrollable；两者都可空，空了就跳过对应层级。
bool executePageScroll(
  PageScrollRequest request, {
  BuildContext? focusContext,
  NavigatorState? navigator,
}) {
  final ScrollPosition? position = FushiFocusScroll.resolveActivePageScrollable(
    towardEnd: request.towardEnd,
    focusContext: focusContext,
    navigator: navigator,
  );
  if (position == null) return false;
  switch (request) {
    case PageScrollRequest.lineUp:
      return FushiFocusScroll.scrollPositionByViewportFraction(
        position,
        -kPageScrollLineFraction,
      );
    case PageScrollRequest.lineDown:
      return FushiFocusScroll.scrollPositionByViewportFraction(
        position,
        kPageScrollLineFraction,
      );
    case PageScrollRequest.pageUp:
      return FushiFocusScroll.scrollPositionByViewportFraction(
        position,
        -kPageScrollPageFraction,
      );
    case PageScrollRequest.pageDown:
      return FushiFocusScroll.scrollPositionByViewportFraction(
        position,
        kPageScrollPageFraction,
      );
    case PageScrollRequest.toTop:
      return FushiFocusScroll.scrollPositionToEdge(position, toEnd: false);
    case PageScrollRequest.toBottom:
      return FushiFocusScroll.scrollPositionToEdge(position, toEnd: true);
  }
}
