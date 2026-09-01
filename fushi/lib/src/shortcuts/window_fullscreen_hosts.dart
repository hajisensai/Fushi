import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:fushi/src/shortcuts/global_navigation.dart';

/// 「窗口级全屏」的宿主声明表。
///
/// 窗口全屏是**窗口级**能力（整个 HWND / NSWindow 变全屏），不是页面级的：小说、
/// 漫画、视频三个模块渲染在同一个 Flutter 视图、同一个原生窗口里。所以「只在内容
/// 模块里能全屏」这条产品规则，改变不了 native 侧怎么全屏，它只能限定 **Dart 侧什么
/// 时候允许进入全屏**。
///
/// 判据不能写成「当前路由名 == 阅读器 / 漫画 / 视频」那种 if 阶梯——那是把页面清单
/// 硬编码进快捷键层，新增内容页必然漏改。改为**由内容页面自己声明**：页面在子树里包
/// 一层 [WindowFullscreenHost]，挂载即登记、卸载即注销。快捷键层只问一个布尔量
/// [hasVisibleHost]，不认识任何具体页面。
///
/// 登记的是页面所在的 [ModalRoute]，可见性判据是 [ModalRoute.isCurrent]——「宿主还在
/// 栈里」不等于「宿主在最上面」：从阅读器 push 设置页后，阅读器的 route 仍然 active
/// 但不再 current，此时按全屏键**不该**生效（用户看到的是设置页，不是内容）。
///
/// route 为 null（页面没被 push 成路由，如 widget 测试直接 pumpWidget 的宿主）视为
/// 可见：此时它就是当前 UI，没有「被别的整页盖住」这回事。
class WindowFullscreenHosts {
  WindowFullscreenHosts._();

  /// token（[WindowFullscreenHost] 的 State 实例）→ 它所在的路由（可为 null）。
  ///
  /// 用 Map 而非 Set 是因为同一个 token 的路由会随 didChangeDependencies 重算，
  /// 必须**覆盖**而不是堆积第二条登记。
  static final Map<Object, ModalRoute<dynamic>?> _hosts =
      <Object, ModalRoute<dynamic>?>{};

  /// 登记 / 更新一个宿主。同一 [token] 重复调用即更新它的路由。
  static void register(Object token, ModalRoute<dynamic>? route) {
    _hosts[token] = route;
  }

  static void unregister(Object token) {
    _hosts.remove(token);
  }

  /// 当前是否有**可见**的全屏宿主（栈顶那层就是内容模块）。
  static bool get hasVisibleHost => _hosts.values.any(
        (ModalRoute<dynamic>? route) => route == null || route.isCurrent,
      );

  @visibleForTesting
  static int get debugHostCount => _hosts.length;

  @visibleForTesting
  static void debugReset() => _hosts.clear();
}

/// 声明「本子树是窗口全屏的合法宿主」。
///
/// 包在内容页（小说 / 漫画 / 视频）的页面子树外层即可；除登记外零行为、零布局影响，
/// 直接透传 [child]。
class WindowFullscreenHost extends StatefulWidget {
  const WindowFullscreenHost({super.key, required this.child});

  final Widget child;

  @override
  State<WindowFullscreenHost> createState() => _WindowFullscreenHostState();
}

class _WindowFullscreenHostState extends State<WindowFullscreenHost> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 在 didChangeDependencies 而非 initState 里取路由：ModalRoute.of 建立的是
    // inherited 依赖，路由变化（如页面被 pushReplacement 到新 route）会重跑这里，
    // 登记随之更新；initState 里读一次会把旧 route 永久钉死。
    WindowFullscreenHosts.register(this, ModalRoute.of(context));
  }

  @override
  void dispose() {
    WindowFullscreenHosts.unregister(this);
    _releaseWindowFullscreenIfNoHostLeft();
    super.dispose();
  }

  /// 最后一个宿主离场时归还窗口全屏。
  ///
  /// 这是「全屏只属于内容模块」的另一半：进入被门在宿主内（见
  /// [WindowFullscreenHosts]），离场就必须还回去，否则退回首页会留下一个全屏窗口，
  /// 而首页的全屏键已经被门掉——用户没有任何出口。Esc 阶梯（
  /// [exitWindowFullscreenForBack]）覆盖的是「人主动退全屏」，这里覆盖的是「页面以
  /// 别的方式没了」（返回按钮、换书、被替换掉）。归还走的是同一个
  /// [exitWindowFullscreenIfActive]：它先读真值，非全屏时一次 channel 都不打。
  ///
  /// **判定必须推到帧末**，不能在 dispose 里当场做：`pushReplacement` 换集 / 换章时，
  /// 旧页 dispose 与新页挂载发生在同一帧内，dispose 这一刻注册表恰好是空的。当场判
  /// 就会在每次换集时把全屏闪掉一次（BUG-839 那条「连播全屏不被换集打断」正是这个
  /// 场景）。帧末才是稳定态：那时新宿主已经登记完毕。
  void _releaseWindowFullscreenIfNoHostLeft() {
    if (!desktopWindowFullscreenSupported) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (WindowFullscreenHosts.hasVisibleHost) return;
      unawaited(exitWindowFullscreenIfActive());
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
