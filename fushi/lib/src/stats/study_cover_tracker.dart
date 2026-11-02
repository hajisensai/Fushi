import 'package:flutter/widgets.dart';

/// 学习面「被盖住」的唯一判据：根 Navigator 上，学习页自己的路由**之上**还压着任何
/// 一条没被豁免的 [ModalRoute]（整页路由、对话框、底部 / 侧边面板、弹出菜单都是）。
///
/// 被盖住 = 用户此刻不在读 / 听，学习计时停表（BUG-2208 的「面板压着正文就停表」）。
///
/// ## 为什么默认停、豁免要显式声明
///
/// 旧实现是反过来的：阅读器只认 [PageRoute]（`appModel.routeObserver`），其余的对话框
/// / 侧板 / 菜单要各入口自己记得包 `_withStudyClockPaused`。结果每加一个会盖住界面的
/// 新功能（悬浮球的 AI 侧板 / 同步 / 切换配置、图片操作单、Kavita 冲突框……）都默认
/// **不**停表，漏一个算一个；漫画 / PDF 阅读器干脆没有这层判据，开着整页 SRS 页也照计。
/// 现在新入口什么都不用做就会停表；真正「属于阅读」的弹层（查词后的制卡操作单、阅读器
/// 的统计侧板）用 [StudyClockTransparentRoute] 声明豁免。
///
/// ## 不在判据里的
///
/// - 非模态的 overlay（查词浮层插在根 Overlay / 页内 Stack、Toast）不是路由，天然不算。
/// - 嵌套 Navigator 里的路由（查词浮层自带的导航层、面板里的子页）：外层宿主要么不是
///   路由（浮层），要么本身已经是盖住学习页的那条路由（面板）。
/// - 学习页**之下**的路由：只看学习页路由在栈里之后的那些。
class StudyCoverTracker extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];
  final Set<Route<dynamic>> _transparent = <Route<dynamic>>{};

  /// [base] 之上有没有压着一条未豁免的模态路由。[base] 不在根栈里（嵌套导航里的页、
  /// 已出栈）时无从判断，返回 false——不因为看不见就把表停死。
  bool covers(Route<dynamic>? base) {
    if (base == null) return false;
    final int index = _stack.indexOf(base);
    if (index < 0) return false;
    for (int i = index + 1; i < _stack.length; i++) {
      final Route<dynamic> route = _stack[i];
      if (route is ModalRoute && !_transparent.contains(route)) return true;
    }
    return false;
  }

  /// 声明 / 撤销 [route] 「属于学习面本身」（盖在上面也照常计时）。
  void setTransparent(Route<dynamic> route, {required bool transparent}) {
    final bool changed = transparent
        ? _transparent.add(route)
        : _transparent.remove(route);
    if (changed) notifyListeners();
  }

  @visibleForTesting
  List<Route<dynamic>> get debugStack =>
      List<Route<dynamic>>.unmodifiable(_stack);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _forget(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _forget(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final int index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (oldRoute != null) _transparent.remove(oldRoute);
    if (newRoute != null) {
      if (index >= 0) {
        _stack[index] = newRoute;
      } else {
        _stack.add(newRoute);
      }
    } else if (index >= 0) {
      _stack.removeAt(index);
    }
    notifyListeners();
  }

  void _forget(Route<dynamic> route) {
    _transparent.remove(route);
    if (_stack.remove(route)) notifyListeners();
  }
}

/// 挂进 `MaterialApp.navigatorObservers` 的唯一实例（`main.dart`）。
final StudyCoverTracker studyCoverTracker = StudyCoverTracker();

/// 学习页订阅「被盖住」变化的小帮手：记住自己的路由，变化时回调 [onChanged]。
///
/// 回调可能在 Navigator 刷新历史的过程中（build / 转场期间）同步触发，里面**不许**
/// `setState`——只做停表 / 起表这类不触发重建的事。
class StudyCoverWatch {
  StudyCoverWatch({required this.onChanged, StudyCoverTracker? tracker})
    : _tracker = tracker ?? studyCoverTracker {
    _tracker.addListener(_handle);
  }

  final StudyCoverTracker _tracker;
  final VoidCallback onChanged;
  Route<dynamic>? _route;
  bool _covered = false;

  /// 当前是否被盖住（上一次通知时的结论）。
  bool get covered => _covered;

  /// 在 `didChangeDependencies` 里用 `ModalRoute.of(context)` 喂进来。
  void attach(Route<dynamic>? route) {
    if (identical(route, _route)) return;
    _route = route;
    _handle();
  }

  void dispose() => _tracker.removeListener(_handle);

  void _handle() {
    final bool next = _tracker.covers(_route);
    if (next == _covered) return;
    _covered = next;
    onChanged();
  }
}

/// 声明「本子树所在的路由属于学习面」：盖在学习页上也不停表。
///
/// 只给确实是阅读一部分的弹层用（查词后的制卡操作单、阅读器的统计侧板）。[enabled]
/// 可随状态切换（侧板原地切到统计页才豁免）。
class StudyClockTransparentRoute extends StatefulWidget {
  const StudyClockTransparentRoute({
    super.key,
    this.enabled = true,
    this.tracker,
    required this.child,
  });

  final bool enabled;
  final StudyCoverTracker? tracker;
  final Widget child;

  @override
  State<StudyClockTransparentRoute> createState() =>
      _StudyClockTransparentRouteState();
}

class _StudyClockTransparentRouteState
    extends State<StudyClockTransparentRoute> {
  ModalRoute<Object?>? _route;
  bool _applied = false;

  StudyCoverTracker get _tracker => widget.tracker ?? studyCoverTracker;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _release();
      _route = route;
    }
    _apply();
  }

  @override
  void didUpdateWidget(StudyClockTransparentRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tracker, widget.tracker)) _release();
    _apply();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _apply() {
    final ModalRoute<Object?>? route = _route;
    if (route == null || _applied == widget.enabled) return;
    _applied = widget.enabled;
    _tracker.setTransparent(route, transparent: widget.enabled);
  }

  void _release() {
    final ModalRoute<Object?>? route = _route;
    if (route == null || !_applied) return;
    _applied = false;
    _tracker.setTransparent(route, transparent: false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
