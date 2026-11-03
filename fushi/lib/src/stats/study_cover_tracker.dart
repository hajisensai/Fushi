import 'package:flutter/foundation.dart';
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
/// 的统计侧板）在路由构造时带上 [StudyClockTransparentSettings] 声明豁免。
///
/// ## 不在判据里的
///
/// - 非模态的 overlay（查词浮层插在根 Overlay / 页内 Stack、Toast）不是路由，天然不算。
/// - 嵌套 Navigator 里的路由（查词浮层自带的导航层、面板里的子页）：外层宿主要么不是
///   路由（浮层），要么本身已经是盖住学习页的那条路由（面板）。
/// - 学习页**之下**的路由：只看学习页路由在栈里之后的那些。
class StudyCoverTracker extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];

  /// 豁免随状态切换的路由（[StudyClockTransparentSettings.when]）订阅的开关。
  final Map<Route<dynamic>, ValueListenable<bool>> _switches =
      <Route<dynamic>, ValueListenable<bool>>{};

  /// [base] 之上有没有压着一条未豁免的模态路由。[base] 不在根栈里（嵌套导航里的页、
  /// 已出栈）时无从判断，返回 false——不因为看不见就把表停死。
  bool covers(Route<dynamic>? base) {
    if (base == null) return false;
    final int index = _stack.indexOf(base);
    if (index < 0) return false;
    for (int i = index + 1; i < _stack.length; i++) {
      final Route<dynamic> route = _stack[i];
      if (route is ModalRoute && !isStudyClockTransparent(route)) return true;
    }
    return false;
  }

  @visibleForTesting
  List<Route<dynamic>> get debugStack =>
      List<Route<dynamic>>.unmodifiable(_stack);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _subscribe(route);
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
    if (oldRoute != null) _unsubscribe(oldRoute);
    if (newRoute != null) {
      if (index >= 0) {
        _stack[index] = newRoute;
      } else {
        _stack.add(newRoute);
      }
      _subscribe(newRoute);
    } else if (index >= 0) {
      _stack.removeAt(index);
    }
    notifyListeners();
  }

  void _forget(Route<dynamic> route) {
    _unsubscribe(route);
    if (_stack.remove(route)) notifyListeners();
  }

  void _subscribe(Route<dynamic> route) {
    final RouteSettings settings = route.settings;
    if (settings is! StudyClockTransparentSettings) return;
    final ValueListenable<bool>? when = settings.when;
    if (when == null || _switches.containsKey(route)) return;
    _switches[route] = when;
    when.addListener(notifyListeners);
  }

  void _unsubscribe(Route<dynamic> route) {
    _switches.remove(route)?.removeListener(notifyListeners);
  }
}

/// 路由**构造时**就声明「属于学习面」（盖在学习页上也不停表）的 [RouteSettings]。
///
/// 只给确实是阅读一部分的弹层用（查词后的制卡操作单 / 高级制卡、阅读器的统计侧板）。
/// 豁免必须随路由一起诞生：[StudyCoverTracker.didPush] 当帧就看得到它，不会先判成
/// 「被盖住」停一次表（封段 + 写库）、等内容建好再补登记起表。弹层入口经
/// `showAppDialog(studyClockTransparent:)` / `adaptiveModalSheet(studyClockTransparent:)`
/// / `showReaderSideSheet(studyClockTransparentWhen:)` 带上它，不自己拼。
class StudyClockTransparentSettings extends RouteSettings {
  /// 整条路由始终豁免。
  const StudyClockTransparentSettings({super.name}) : when = null;

  /// 豁免随 [when] 切换（侧板原地切到统计页才豁免）。[when] 的变化由调用方在事件
  /// 处理里改，不在 build 期间改——观察器据此同步通知学习页停 / 起表。
  const StudyClockTransparentSettings.when(
    ValueListenable<bool> this.when, {
    super.name,
  });

  final ValueListenable<bool>? when;

  bool get transparent => when?.value ?? true;
}

/// [route] 是否声明了「属于学习面」（见 [StudyClockTransparentSettings]）。
bool isStudyClockTransparent(Route<dynamic> route) {
  final RouteSettings settings = route.settings;
  return settings is StudyClockTransparentSettings && settings.transparent;
}

/// 给弹层入口用：要豁免就带上标记，不豁免返回 null（入口照旧用默认 settings）。
RouteSettings? studyClockRouteSettings({
  bool transparent = false,
  ValueListenable<bool>? transparentWhen,
}) {
  if (transparentWhen != null) {
    return StudyClockTransparentSettings.when(transparentWhen);
  }
  return transparent ? const StudyClockTransparentSettings() : null;
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
