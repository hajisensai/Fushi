/// 保活分区（顶层 tab / 库页视图）的可见性：焦点与系统返回的参与资格。
///
/// 保活分区用 [Offstage] + [TickerMode] 藏起来，但这两者都不管焦点与返回：
/// - 藏起来的分区里的焦点节点仍在焦点树上，Tab / 方向键遍历会落进看不见的按钮；
/// - 藏起来的分区里的 [PopScope] 仍登记在同一个路由上——书架在「发现」视图背后
///   停在多选模式时，`canPop: false` 照样拦住返回键，回调还会在看不见的地方退出
///   多选（HBK-AUDIT-017）。
///
/// 统一裁剪点：宿主用 [SectionVisibilityScope] 包每个保活分区（与 `offstage:`
/// 同一个判据），分区内会拦返回的地方用 [SectionPopScope] 代替裸 [PopScope]。
/// 可见性沿祖先链取与：外层 tab 隐藏时，里面「当前」视图同样不可见。
library;

import 'package:flutter/widgets.dart';

/// 当前子树是否处在可见分区里（自身与所有祖先分区都可见）。
class SectionVisibility extends InheritedWidget {
  const SectionVisibility._({required this.visible, required super.child});

  /// 自身与所有祖先分区是否都可见。
  final bool visible;

  /// 子树是否可见；不在任何分区里时恒为 true。
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SectionVisibility>()
          ?.visible ??
      true;

  @override
  bool updateShouldNotify(SectionVisibility oldWidget) =>
      visible != oldWidget.visible;
}

/// 包一个保活分区：向子树发布（与祖先取与后的）可见性，并按**有效可见性**
/// 排除焦点——外层 tab 隐藏时，里面本地「当前」的视图同样拿不到焦点、收不到
/// 按键（HBK-AUDIT-017 残留：只按本层 [visible] 排除时，外层隐藏、内层当前的
/// 子树仍 hasFocus 且吃键）。
///
/// 由隐转显的那次同步调用里（尚未重建）向分区内 requestFocus 会被这里吞掉；
/// 需要「切过去就聚焦」的宿主要在分区重建之后再请求焦点（后帧，或像查词 tab
/// 那样由非保活页自己在挂载后消费请求）。
class SectionVisibilityScope extends StatelessWidget {
  const SectionVisibilityScope({
    required this.visible,
    required this.child,
    super.key,
  });

  /// 本分区是否为当前分区（与宿主 `Offstage.offstage` 取反同一个判据）。
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool effective = visible && SectionVisibility.of(context);
    return SectionVisibility._(
      visible: effective,
      child: ExcludeFocus(excluding: !effective, child: child),
    );
  }
}

/// 只在所在分区可见时参与系统返回的 [PopScope]。
///
/// [intercepting] 为 true 且分区可见时拦下返回（`canPop: false`）并调
/// [onIntercept]；分区隐藏时既不拦返回、也不调回调——看不见的页面不能吃掉
/// 用户的返回键，也不能在背后改自己的状态。
///
/// 拦着返回就意味着这个分区**不在模块根**（多选模式等页内状态），同一份判据
/// 顺带报给 [ModuleRootScope]：首页外壳据此不让横滑切模块。
class SectionPopScope extends StatelessWidget {
  const SectionPopScope({
    required this.intercepting,
    required this.onIntercept,
    required this.child,
    super.key,
  });

  final bool intercepting;
  final VoidCallback onIntercept;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool active = intercepting && SectionVisibility.of(context);
    return ModuleRootAwayReporter(
      away: active,
      child: PopScope<Object?>(
        canPop: !active,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (didPop || !active) return;
          onIntercept();
        },
        child: child,
      ),
    );
  }
}

/// 首页外壳的「模块根」登记表：tab 内容里此刻**离开了根状态**的部件（多选模式、
/// 嵌套栈钻进了一层……）在这里登记，外壳在用户横滑时据此判断能不能切模块。
///
/// 判据刻意与系统返回同源：一个页内状态如果要接系统返回（返回先退出多选 / 退回
/// 上一层），它就不是模块根——横滑切走会把用户正在做的事（选了一半的条目、钻进
/// 去的服务器目录）留在看不见的地方。登记方只有两类，都已经在处理返回：
/// [SectionPopScope] 与嵌套 Navigator 的宿主（`media_server_browse_page.dart`）。
///
/// 只在手势那一刻读，不驱动重建，所以是普通对象而不是 [ChangeNotifier]。
class ModuleRootTracker {
  final Set<Object> _away = <Object>{};

  /// 当前可见 tab 是否停在模块根（没有任何部件登记「离开根」）。
  bool get atRoot => _away.isEmpty;

  /// [owner] 报告自己此刻是否让页面离开了根状态。
  void report(Object owner, {required bool away}) {
    if (away) {
      _away.add(owner);
    } else {
      _away.remove(owner);
    }
  }

  /// [owner] 卸载：撤回登记。
  void remove(Object owner) => _away.remove(owner);
}

/// 向子树下发 [ModuleRootTracker]。只有首页外壳挂它；不在外壳里（推出来的路由、
/// 组件测试）时登记方自动 no-op。
class ModuleRootScope extends InheritedWidget {
  const ModuleRootScope({
    required this.tracker,
    required super.child,
    super.key,
  });

  final ModuleRootTracker tracker;

  /// 不建立依赖：登记表本身不变，登记方也不需要随它重建。
  static ModuleRootTracker? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ModuleRootScope>()?.tracker;

  @override
  bool updateShouldNotify(ModuleRootScope oldWidget) =>
      tracker != oldWidget.tracker;
}

/// 把「本部件此刻让页面离开了模块根」报给最近的 [ModuleRootScope]。
///
/// [away] 由调用方按**有效可见性**算好（隐藏分区里的多选不算，与 [SectionPopScope]
/// 拦返回的判据相同）；卸载时自动撤回。
class ModuleRootAwayReporter extends StatefulWidget {
  const ModuleRootAwayReporter({
    required this.away,
    required this.child,
    super.key,
  });

  final bool away;
  final Widget child;

  @override
  State<ModuleRootAwayReporter> createState() => _ModuleRootAwayReporterState();
}

class _ModuleRootAwayReporterState extends State<ModuleRootAwayReporter> {
  ModuleRootTracker? _tracker;

  void _sync() {
    final ModuleRootTracker? next = ModuleRootScope.maybeOf(context);
    if (!identical(next, _tracker)) {
      _tracker?.remove(this);
      _tracker = next;
    }
    _tracker?.report(this, away: widget.away);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ModuleRootAwayReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.away != widget.away) _sync();
  }

  @override
  void dispose() {
    _tracker?.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
