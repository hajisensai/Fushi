part of '../adaptive_navigation.dart';

/// 镂空脊缺口的起始边留白（缺口从这里一直开到侧栏内缘）。
const double _kRailNotchStart = 12;

/// 缺口比当前项指示器槽上下各多出的高度。
const double _kRailNotchBleed = 4;

/// 缺口与内容区交界处的内凹圆角半径。
const double _kRailNotchFillet = 24;

/// 镂空脊下内容区（舞台）起始边的圆角半径。
const double _kRailStageRadius = 44;

/// 色脊悬浮色块的圆角半径。
const double _kRailSpineRadius = 40;

/// 重设计侧栏（镂空脊 / 色脊）的样式与配色：由 [_MaterialNavCluster] 的纵向
/// 分支解析一次，经 [_RailLookScope] 交给各目的地与菜单钮。null（Apple 设计
/// 系统 / 墨水屏）= 原悬浮面板。
@immutable
class _RailLook {
  const _RailLook({required this.style, required this.accent});

  static _RailLook? resolve(BuildContext context) {
    if (!shellRedesignActive(context)) return null;
    return _RailLook(
      style: shellThemeOf(context).railStyle,
      accent: shellAccentOf(context),
    );
  }

  final ShellRailStyle style;
  final ShellAccentColors accent;

  bool get notch => style == ShellRailStyle.notch;

  /// 色块上未选中的图标 / 文字。
  Color get foreground => accent.onContainer.withValues(alpha: 0.82);

  /// 展开态选中行的底：镂空脊由缺口本身表达选中，不再填色；色脊是一层浅罩。
  Color get rowFill =>
      notch ? Colors.transparent : accent.onContainer.withValues(alpha: 0.12);

  /// 展开态选中行的标签色：镂空脊的选中行落在缺口里（页面底色上），色脊的
  /// 落在色块上。
  Color get selectedLabel => notch ? accent.strong : accent.onContainer;

  @override
  bool operator ==(Object other) =>
      other is _RailLook &&
      other.style == style &&
      other.accent.indicator == accent.indicator &&
      other.accent.onIndicator == accent.onIndicator &&
      other.accent.strong == accent.strong &&
      other.accent.container == accent.container &&
      other.accent.onContainer == accent.onContainer;

  @override
  int get hashCode => Object.hash(
    style,
    accent.indicator,
    accent.onIndicator,
    accent.strong,
    accent.container,
    accent.onContainer,
  );
}

class _RailLookScope extends InheritedWidget {
  const _RailLookScope({required this.look, required super.child});

  final _RailLook? look;

  static _RailLook? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RailLookScope>()?.look;

  @override
  bool updateShouldNotify(_RailLookScope oldWidget) => oldWidget.look != look;
}

/// 镂空脊的色块面：铺满侧栏占位宽，当前项处挖出一个开向内容区的缺口。缺口
/// 不是「再盖一层页面底色」，而是色块这里不画——页面背景（含形状背景）从
/// 缺口里原样露出来。缺口的位置取滑动指示器当帧的矩形（[_SlidingIndicatorScopeState]
/// 的液态墨滴），所以换页时缺口与墨滴同一条弹簧。
class _RailNotchSurface extends StatefulWidget {
  const _RailNotchSurface({
    required this.color,
    required this.child,
    this.topBleed = 0,
  });

  final Color color;

  /// 色块向上多画出的高度：桌面自绘标题行浮在页面上、侧栏内容让在它下面，
  /// 色块本身要一直铺到窗口上沿。
  final double topBleed;
  final Widget child;

  @override
  State<_RailNotchSurface> createState() => _RailNotchSurfaceState();
}

class _RailNotchHost extends InheritedWidget {
  const _RailNotchHost({required this.state, required super.child});

  final _RailNotchSurfaceState state;

  static _RailNotchSurfaceState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RailNotchHost>()?.state;

  @override
  bool updateShouldNotify(_RailNotchHost oldWidget) =>
      !identical(oldWidget.state, state);
}

class _RailNotchSurfaceState extends State<_RailNotchSurface> {
  /// 侧栏目的地列表的滚动控制器：滚动时缺口跟着当前项走。
  final ScrollController scroll = ScrollController();

  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final GlobalKey _paintKey = GlobalKey(debugLabel: 'rail-notch-surface');
  _SlidingIndicatorScopeState? _slider;

  @override
  void initState() {
    super.initState();
    scroll.addListener(_tick);
  }

  void _tick() => _repaint.value++;

  /// 目的地列表里的滑动指示器向这里登记 / 注销（null）。
  void attach(_SlidingIndicatorScopeState? slider) {
    if (identical(_slider, slider)) return;
    _slider?._progress.animation.removeListener(_tick);
    _slider = slider;
    slider?._progress.animation.addListener(_tick);
    _tick();
  }

  void detach(_SlidingIndicatorScopeState slider) {
    if (!identical(_slider, slider)) return;
    // 滑块正在销毁，它的动画不必再摘监听。
    _slider = null;
  }

  /// 缺口在色块面坐标里的上下沿；没有当前项 / 还没布局时 null。
  ({double top, double bottom})? _notchExtent(RenderBox surface) {
    final _SlidingIndicatorScopeState? slider = _slider;
    if (slider == null || !slider.mounted) return null;
    final RenderObject? scope = slider.context.findRenderObject();
    if (scope is! RenderBox || !scope.attached || !scope.hasSize) return null;
    final Rect? rect = slider._currentRect(scope);
    if (rect == null) return null;
    final Rect local = MatrixUtils.transformRect(
      scope.getTransformTo(surface),
      rect,
    );
    double top = local.top - _kRailNotchBleed;
    double bottom = local.bottom + _kRailNotchBleed;
    // 当前项滚出列表可视区时，缺口随之被可视区上下沿截住。
    // 不用 `scroll.position`：侧栏列表被整棵换掉的那一帧（页头有无切换让
    // Column 子节点错位重建），旧 Scrollable 要到帧末 finalizeTree 才卸载，
    // 绘制时控制器上同时挂着新旧两个 position，取单数会直接抛。
    for (final ScrollPosition position in scroll.positions) {
      final BuildContext viewportContext = position.context.storageContext;
      if (!viewportContext.mounted) continue;
      final RenderObject? viewport = viewportContext.findRenderObject();
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
        continue;
      }
      final Rect view = MatrixUtils.transformRect(
        viewport.getTransformTo(surface),
        Offset.zero & viewport.size,
      );
      top = math.max(top, view.top);
      bottom = math.min(bottom, view.bottom);
      break;
    }
    if (bottom - top < 8) return null;
    return (top: top, bottom: bottom);
  }

  @override
  void dispose() {
    _slider?._progress.animation.removeListener(_tick);
    scroll.removeListener(_tick);
    scroll.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _RailNotchHost(
      state: this,
      child: CustomPaint(
        key: _paintKey,
        painter: _RailNotchPainter(
          host: this,
          color: widget.color,
          topBleed: widget.topBleed,
          rtl: Directionality.of(context) == TextDirection.rtl,
        ),
        child: widget.child,
      ),
    );
  }
}

class _RailNotchPainter extends CustomPainter {
  _RailNotchPainter({
    required this.host,
    required this.color,
    required this.topBleed,
    required this.rtl,
  }) : super(repaint: host._repaint);

  final _RailNotchSurfaceState host;
  final Color color;
  final double topBleed;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderObject? surface = host._paintKey.currentContext
        ?.findRenderObject();
    final ({double top, double bottom})? notch = surface is RenderBox
        ? host._notchExtent(surface)
        : null;
    Path body = Path()
      ..addRect(Rect.fromLTRB(0, -topBleed, size.width, size.height));
    if (notch != null) {
      body = Path.combine(
        PathOperation.difference,
        body,
        _notchPath(notch.top, notch.bottom, size.width),
      );
    }
    canvas.save();
    if (rtl) {
      // 缺口只用到上下沿，水平方向按起始边镜像即可。
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(body, Paint()..color = color);
    canvas.restore();
  }

  /// 缺口：左端半圆、右端开到色块内缘 [width]，上下各带一个内凹圆角，与内容
  /// 区连成一体。
  static Path _notchPath(double top, double bottom, double width) {
    final double radius = math.min((bottom - top) / 2, 32);
    const double f = _kRailNotchFillet;
    return Path()
      ..addRRect(
        RRect.fromLTRBAndCorners(
          _kRailNotchStart,
          top,
          width + 1,
          bottom,
          topLeft: Radius.circular(radius),
          bottomLeft: Radius.circular(radius),
        ),
      )
      ..moveTo(width, top - f)
      ..arcToPoint(Offset(width - f, top), radius: const Radius.circular(f))
      ..lineTo(width, top)
      ..close()
      ..moveTo(width - f, bottom)
      ..arcToPoint(Offset(width, bottom + f), radius: const Radius.circular(f))
      ..lineTo(width, bottom)
      ..close();
  }

  @override
  bool shouldRepaint(_RailNotchPainter oldDelegate) => true;
}

/// 镂空脊下包在内容区外：在内容区起始边的上下两角补上侧栏色，让内容区读成
/// 一块左侧大圆角的「舞台」。其它侧栏样式 / Apple 设计系统 / 墨水屏原样返回
/// [child]。
/// 侧栏色块是否一直铺到窗口上沿（镂空脊）：是的话首页外壳不在外层吃掉顶部
/// 安全区，改由侧栏内容与内容区各自让开。
bool navRailBleedsToTop(BuildContext context) =>
    !isGlassDesign(context) && (_RailLook.resolve(context)?.notch ?? false);

class NavRailStage extends StatelessWidget {
  const NavRailStage({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return child;
    final _RailLook? look = _RailLook.resolve(context);
    if (look == null || !look.notch) return child;
    // 画在内容之上：页头底板、滚到角上的卡片都是内容自己画的，楔形垫在下面
    // 会被它们盖成直角，舞台左上角就和侧栏断开了。
    return CustomPaint(
      foregroundPainter: _RailStageCornerPainter(
        color: look.accent.container,
        shape: shellShape(
          context,
          const BorderRadiusDirectional.horizontal(
            start: Radius.circular(_kRailStageRadius),
          ),
        ),
        textDirection: Directionality.of(context),
      ),
      child: child,
    );
  }
}

class _RailStageCornerPainter extends CustomPainter {
  const _RailStageCornerPainter({
    required this.color,
    required this.shape,
    required this.textDirection,
  });

  final Color color;
  final OutlinedBorder shape;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    // 只在起始边一条窄带里做差集：带宽盖住圆角即可。
    const double band = _kRailStageRadius * kShellSmoothRadiusScale + 8;
    final Rect strip = textDirection == TextDirection.rtl
        ? Rect.fromLTWH(size.width - band, 0, band, size.height)
        : Rect.fromLTWH(0, 0, band, size.height);
    final Path corners = Path.combine(
      PathOperation.difference,
      Path()..addRect(strip),
      shape.getOuterPath(Offset.zero & size, textDirection: textDirection),
    );
    canvas.drawPath(corners, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RailStageCornerPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.shape != shape ||
      oldDelegate.textDirection != textDirection;
}
