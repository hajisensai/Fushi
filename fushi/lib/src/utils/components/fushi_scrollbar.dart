import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 鼠标在拇指周围多远之内按下仍算抓住拇指（逻辑像素）。
///
/// 拇指只有 [kFushiScrollbarThickness] 粗（BUG-1997：常驻覆盖在列表右侧，粗了会
/// 压住并吞掉最右一列的按钮），Flutter 原生的鼠标命中又只认画出来的那 3px——
/// 稍微按偏就落到轨道上，被当成「点轨道」整页翻一屏。这里只放宽**命中**，
/// 外观不变。
const double kFushiScrollbarGrabSlack = 6.0;

/// 全应用的滚动行为：桌面端给每个纵向 Scrollable 自动包的滚动条换成
/// [_FushiRawScrollbar]（外观仍走全局 `ScrollbarThemeData`，只改鼠标命中）。
class FushiScrollBehavior extends MaterialScrollBehavior {
  const FushiScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final Widget material = super.buildScrollbar(context, child, details);
    // 父类只在桌面端纵向包 Scrollbar；其余情形原样返回，这里跟着它判。
    if (identical(material, child)) return child;
    return _FushiRawScrollbar(controller: details.controller, child: child);
  }
}

/// 外层显式挂在一个 [ScrollController] 上的常驻滚动条（对话框 / 书架等需要
/// 移动端也显示拇指的场景）。
///
/// 外观走全局 `ScrollbarThemeData`（见 `fushiM3eScrollbarTheme`），鼠标命中与
/// [FushiScrollBehavior] 自动包的那条相同。之前这些位置写的是
/// `RawScrollbar(thickness: 3)`：不吃主题，而且桌面端 ScrollBehavior 还会在
/// 内层再自动包一条，两条叠画在同一位置。这里显式关掉子树的自动滚动条，只留
/// 这一条。
class FushiScrollbar extends StatelessWidget {
  const FushiScrollbar({
    required this.controller,
    required this.child,
    super.key,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _FushiRawScrollbar(
      controller: controller,
      thumbVisibility: true,
      // 移动端也能拖拇指（书架长列表靠它快速定位），与原 RawScrollbar 一致。
      interactive: true,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: child,
      ),
    );
  }
}

/// 外观对齐 Material `Scrollbar`（读同一份 `ScrollbarThemeData`），鼠标命中换成
/// [_FushiScrollbarPainter]。
class _FushiRawScrollbar extends RawScrollbar {
  const _FushiRawScrollbar({
    required super.child,
    super.controller,
    super.thumbVisibility,
    super.interactive,
  });

  @override
  RawScrollbarState<_FushiRawScrollbar> createState() =>
      _FushiRawScrollbarState();
}

class _FushiRawScrollbarState extends RawScrollbarState<_FushiRawScrollbar> {
  late final _FushiScrollbarPainter _painter;
  late ScrollbarThemeData _scrollbarTheme;
  late ColorScheme _colorScheme;
  bool _hovered = false;
  bool _dragged = false;

  // 父类在 initState 里建好自己的 painter 并经由这个 getter 使用它画、命中、
  // 拖动；换成子类后三者都走放宽后的命中判定。
  @override
  ScrollbarPainter get scrollbarPainter => _painter;

  Set<WidgetState> get _states => <WidgetState>{
    if (_dragged) WidgetState.dragged,
    if (_hovered) WidgetState.hovered,
  };

  @override
  bool get showScrollbar =>
      widget.thumbVisibility ??
      _scrollbarTheme.thumbVisibility?.resolve(_states) ??
      false;

  @override
  bool get enableGestures =>
      widget.interactive ?? _scrollbarTheme.interactive ?? true;

  @override
  void initState() {
    super.initState();
    _painter = _FushiScrollbarPainter(
      color: const Color(0x00000000),
      fadeoutOpacityAnimation: super.scrollbarPainter.fadeoutOpacityAnimation,
    );
  }

  @override
  void didChangeDependencies() {
    final ThemeData theme = Theme.of(context);
    _colorScheme = theme.colorScheme;
    _scrollbarTheme = ScrollbarTheme.of(context);
    super.didChangeDependencies();
  }

  /// 主题没给拇指色（墨水屏）时的回落，取值同 Material `Scrollbar` 桌面端。
  Color _fallbackThumbColor(Set<WidgetState> states) {
    final Color onSurface = _colorScheme.onSurface;
    final bool dark = _colorScheme.brightness == Brightness.dark;
    if (states.contains(WidgetState.dragged)) {
      return onSurface.withValues(alpha: dark ? 0.75 : 0.6);
    }
    if (states.contains(WidgetState.hovered)) {
      return onSurface.withValues(alpha: dark ? 0.65 : 0.5);
    }
    return onSurface.withValues(alpha: dark ? 0.3 : 0.1);
  }

  @override
  void updateScrollbarPainter() {
    final Set<WidgetState> states = _states;
    final TextDirection textDirection = Directionality.of(context);
    final bool showTrack =
        showScrollbar &&
        (_scrollbarTheme.trackVisibility?.resolve(states) ?? false);
    const Color transparent = Color(0x00000000);
    final double minLength = _scrollbarTheme.minThumbLength ?? 48;
    scrollbarPainter
      ..color =
          _scrollbarTheme.thumbColor?.resolve(states) ??
          _fallbackThumbColor(states)
      ..trackColor = showTrack
          ? _scrollbarTheme.trackColor?.resolve(states) ??
                _colorScheme.onSurface.withValues(alpha: 0.05)
          : transparent
      ..trackBorderColor = showTrack
          ? _scrollbarTheme.trackBorderColor?.resolve(states) ?? transparent
          : transparent
      ..textDirection = textDirection
      ..thickness =
          _scrollbarTheme.thickness?.resolve(states) ?? kFushiScrollbarThickness
      ..radius =
          _scrollbarTheme.radius ??
          const Radius.circular(kFushiScrollbarThickness)
      ..trackRadius = widget.trackRadius
      ..padding = MediaQuery.paddingOf(context).resolve(textDirection)
      ..scrollbarOrientation = widget.scrollbarOrientation
      ..mainAxisMargin = _scrollbarTheme.mainAxisMargin ?? 0
      ..shape = widget.shape
      ..crossAxisMargin = _scrollbarTheme.crossAxisMargin ?? 2
      ..minLength = minLength
      ..minOverscrollLength = minLength
      ..ignorePointer = !enableGestures;
  }

  void _setStates({bool? hovered, bool? dragged}) {
    final bool nextHovered = hovered ?? _hovered;
    final bool nextDragged = dragged ?? _dragged;
    if (nextHovered == _hovered && nextDragged == _dragged) return;
    setState(() {
      _hovered = nextHovered;
      _dragged = nextDragged;
    });
  }

  @override
  void handleHover(PointerHoverEvent event) {
    super.handleHover(event);
    _setStates(
      hovered: isPointerOverScrollbar(
        event.position,
        event.kind,
        forHover: true,
      ),
    );
  }

  @override
  void handleHoverExit(PointerExitEvent event) {
    super.handleHoverExit(event);
    _setStates(hovered: false);
  }

  @override
  void handleThumbPressStart(Offset localPosition) {
    super.handleThumbPressStart(localPosition);
    _setStates(dragged: true);
  }

  @override
  void handleThumbPressEnd(Offset localPosition, Velocity velocity) {
    super.handleThumbPressEnd(localPosition, velocity);
    _setStates(dragged: false);
  }

  @override
  void dispose() {
    // 父类 initState 建的那个 painter 没人再用，单独释放；父类 dispose 经由
    // getter 释放的是 [_painter]。
    super.scrollbarPainter.dispose();
    super.dispose();
  }
}

/// 只改鼠标（及触控笔）的命中，画法与触摸命中全部沿用父类：
///
/// * 拇指：画出来的拇指周围 [kFushiScrollbarGrabSlack] 内按下都算抓住，可直接拖；
/// * 轨道：不再接收点击——原生「点轨道整页翻」在细条上几乎都是按偏误触，表现为
///   一点就乱跳；
/// * 吞点击（[hitTest]）：只在拇指那一截，轨道其余高度让给底下的内容，
///   最右一列按钮照常可点（BUG-1997）。
class _FushiScrollbarPainter extends ScrollbarPainter {
  _FushiScrollbarPainter({
    required super.color,
    required super.fadeoutOpacityAnimation,
  });

  /// 采样步长 ≤ 拇指粗细，保证落在放宽范围内的点一定能采到拇指矩形。
  static const List<double> _offsets = <double>[
    0,
    -kFushiScrollbarGrabSlack / 2,
    kFushiScrollbarGrabSlack / 2,
    -kFushiScrollbarGrabSlack,
    kFushiScrollbarGrabSlack,
  ];

  static bool _isPrecise(PointerDeviceKind kind) => switch (kind) {
    PointerDeviceKind.mouse ||
    PointerDeviceKind.stylus ||
    PointerDeviceKind.invertedStylus ||
    PointerDeviceKind.unknown => true,
    PointerDeviceKind.touch || PointerDeviceKind.trackpad => false,
  };

  bool _nearThumb(Offset position) {
    for (final double dx in _offsets) {
      for (final double dy in _offsets) {
        if (super.hitTestOnlyThumbInteractive(
          position.translate(dx, dy),
          PointerDeviceKind.mouse,
        )) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  bool? hitTest(Offset? position) {
    final bool? base = super.hitTest(position);
    if (base == null || position == null) return base;
    if (ignorePointer || fadeoutOpacityAnimation.value == 0.0) return false;
    return _nearThumb(position);
  }

  @override
  bool hitTestInteractive(
    Offset position,
    PointerDeviceKind kind, {
    bool forHover = false,
  }) {
    // 淡出不可见时父类用放大区判悬停把它唤回来；常驻显示时不会走到。
    if (!_isPrecise(kind) || fadeoutOpacityAnimation.value == 0.0) {
      return super.hitTestInteractive(position, kind, forHover: forHover);
    }
    return _nearThumb(position);
  }

  @override
  bool hitTestOnlyThumbInteractive(Offset position, PointerDeviceKind kind) {
    if (!_isPrecise(kind)) {
      return super.hitTestOnlyThumbInteractive(position, kind);
    }
    return _nearThumb(position);
  }
}
