import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeVisibleExtent, fushiRevealBelowFloatingChrome;

/// 设置页内的分组锚点登记 + 滚动高亮（scroll spy）。
///
/// 页壳（settings kit 的 SettingsKitScaffold）持有一个 spy 并经
/// [SettingsSectionSpyScope] 下发；页内每个**带标题的分组**（共享组件
/// `AdaptiveSettingsSection` / `SettingsSectionHeader` 在构建时自动包一层
/// [SettingsSectionAnchor]）挂载即登记、卸载即注销。schema 详情页与各手写设置
/// 正文（Anki、同步、互联、存储……）因此不用逐页声明分组表，只要用共享分组组件
/// 就自动出现在分组跳转条里。
///
/// 分组顺序按**真实几何位置**排（不是构建顺序），每帧布局后重算一次。
class SettingsSectionSpy extends ChangeNotifier {
  SettingsSectionSpy({this.activationOffset = 72});

  /// 分组顶边越过视口顶 + 这个偏移即算「当前分组」。
  final double activationOffset;

  final Map<String, _SettingsSectionAnchorState> _anchors =
      <String, _SettingsSectionAnchorState>{};
  List<(String, String)> _sections = const <(String, String)>[];
  ScrollController? _controller;
  String? _activeId;
  bool _orderScheduled = false;
  bool _disposed = false;

  /// 当前活跃分组 id（无分组 / 都在视口下方时为 null）。
  String? get activeId => _activeId;

  /// 页内全部已挂载分组 (id, 标题)，按位置从上到下。
  List<(String, String)> get sections => _sections;

  void attach(ScrollController controller) {
    if (identical(_controller, controller)) return;
    _controller?.removeListener(_recomputeActive);
    _controller = controller..addListener(_recomputeActive);
  }

  void _register(_SettingsSectionAnchorState anchor) {
    _anchors[anchor.id] = anchor;
    _scheduleOrder();
  }

  void _unregister(_SettingsSectionAnchorState anchor) {
    if (identical(_anchors[anchor.id], anchor)) _anchors.remove(anchor.id);
    _scheduleOrder();
  }

  /// 标题变化（运行期文案）也要重排。
  void _touched() => _scheduleOrder();

  void _scheduleOrder() {
    if (_orderScheduled || _disposed) return;
    _orderScheduled = true;
    // 登记发生在 build / mount 期间，此时还没有几何；排到这一帧布局之后再算，
    // 并主动要一帧（静止页面上 addPostFrameCallback 本身不会调度帧）。
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      _orderScheduled = false;
      if (_disposed) return;
      _recomputeOrder();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  double? _topOf(_SettingsSectionAnchorState anchor) {
    if (!anchor.mounted) return null;
    final RenderObject? box = anchor.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final ScrollableState? scrollable = Scrollable.maybeOf(anchor.context);
    final RenderObject? viewport = scrollable?.context.findRenderObject();
    if (viewport is! RenderBox) return null;
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  void _recomputeOrder() {
    final List<(double, _SettingsSectionAnchorState)> placed =
        <(double, _SettingsSectionAnchorState)>[];
    for (final _SettingsSectionAnchorState anchor in _anchors.values) {
      final double? top = _topOf(anchor);
      if (top != null) placed.add((top, anchor));
    }
    placed.sort(
      (
        (double, _SettingsSectionAnchorState) a,
        (double, _SettingsSectionAnchorState) b,
      ) => a.$1.compareTo(b.$1),
    );
    final List<(String, String)> next = <(String, String)>[
      for (final (double _, _SettingsSectionAnchorState anchor) in placed)
        (anchor.id, anchor.widget.title),
    ];
    final bool changed =
        next.length != _sections.length ||
        <int>[
          for (int i = 0; i < next.length; i++) i,
        ].any((int i) => next[i] != _sections[i]);
    if (changed) {
      _sections = List<(String, String)>.unmodifiable(next);
      notifyListeners();
    }
    _recomputeActive();
  }

  void _recomputeActive() {
    if (_disposed) return;
    String? active;
    for (final (String id, String _) in _sections) {
      final _SettingsSectionAnchorState? anchor = _anchors[id];
      if (anchor == null) continue;
      final double? top = _topOf(anchor);
      if (top == null) continue;
      // 浮动工具区盖着视口顶的那一段：「到顶」判据跟着工具区可见下沿下移。
      final double chrome = anchor.mounted
          ? FushiFloatingChromeVisibleExtent.valueOf(anchor.context)
          : 0;
      if (top <= activationOffset + chrome) {
        active = id;
      } else {
        break;
      }
    }
    // 滚到底时最后一个分组可能永远到不了顶，此时把它记为当前。
    final ScrollController? controller = _controller;
    if (controller != null &&
        controller.hasClients &&
        _sections.isNotEmpty &&
        controller.positions.first.pixels > 0 &&
        controller.positions.first.extentAfter < 1) {
      active = _sections.last.$1;
    }
    if (active != _activeId) {
      _activeId = active;
      notifyListeners();
    }
  }

  /// 把分组 [id] 滚到视口顶 / 浮动工具区可见下沿之下（经 [FushiFocusScroll]；eink / 减弱动态效果下
  /// 由调用方传零时长）。
  void jumpTo(String id, {required Duration duration}) {
    final _SettingsSectionAnchorState? anchor = _anchors[id];
    if (anchor == null || !anchor.mounted) return;
    // 在浮动工具区下：落到工具区可见下沿之下，而不是被胶囊挡住的视口顶。
    if (!fushiRevealBelowFloatingChrome(anchor.context, duration: duration)) {
      FushiFocusScroll.ensureVisible(
        anchor.context,
        alignment: 0,
        duration: duration,
      );
    }
    _activeId = id;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_recomputeActive);
    super.dispose();
  }
}

/// 把 [spy] 下发给页内分组组件。
class SettingsSectionSpyScope extends InheritedWidget {
  const SettingsSectionSpyScope({
    required this.spy,
    required super.child,
    super.key,
  });

  final SettingsSectionSpy spy;

  static SettingsSectionSpy? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SettingsSectionSpyScope>()?.spy;

  @override
  bool updateShouldNotify(SettingsSectionSpyScope oldWidget) =>
      !identical(spy, oldWidget.spy);
}

/// 标记「已在某个分组锚点之内」：嵌套的分组（分组卡里的小标题）不再单独登记。
class _SettingsSectionAnchorMarker extends InheritedWidget {
  const _SettingsSectionAnchorMarker({required super.child});

  @override
  bool updateShouldNotify(_SettingsSectionAnchorMarker oldWidget) => false;
}

/// 分组锚点：有 [SettingsSectionSpyScope]、标题非空且不在另一个锚点之内时登记
/// 到 spy；否则原样返回 [child]（不影响任何非设置页的使用）。
class SettingsSectionAnchor extends StatelessWidget {
  const SettingsSectionAnchor({
    required this.title,
    required this.child,
    super.key,
  });

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final String? label = title?.trim();
    if (label == null || label.isEmpty) return child;
    final SettingsSectionSpy? spy = SettingsSectionSpyScope.maybeOf(context);
    if (spy == null) return child;
    if (context.getInheritedWidgetOfExactType<_SettingsSectionAnchorMarker>() !=
        null) {
      return child;
    }
    return _SettingsSectionAnchor(spy: spy, title: label, child: child);
  }
}

class _SettingsSectionAnchor extends StatefulWidget {
  const _SettingsSectionAnchor({
    required this.spy,
    required this.title,
    required this.child,
  });

  final SettingsSectionSpy spy;
  final String title;
  final Widget child;

  @override
  State<_SettingsSectionAnchor> createState() => _SettingsSectionAnchorState();
}

class _SettingsSectionAnchorState extends State<_SettingsSectionAnchor> {
  late final String id = 'settings-section-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    widget.spy._register(this);
  }

  @override
  void didUpdateWidget(_SettingsSectionAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.spy, widget.spy)) {
      oldWidget.spy._unregister(this);
      widget.spy._register(this);
    } else if (oldWidget.title != widget.title) {
      widget.spy._touched();
    }
  }

  @override
  void dispose() {
    widget.spy._unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsSectionAnchorMarker(child: widget.child);
  }
}
