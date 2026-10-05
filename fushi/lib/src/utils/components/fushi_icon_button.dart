import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 页头动作按钮「展开文字标签」的作用域开关。
///
/// BUG：`_labelExpanded` 原本只按**整窗**宽（[MediaQuery.sizeOf]）判定，与页头
/// 实际可用宽脱钩。桌面带导航栏 / 分栏时整窗 ≥840 但页头本地宽更窄，窗宽判定仍把
/// 4 个动作展开成药丸，[FushiPageHeader] 里 [Expanded] 的标题被挤到贴着按钮甚至
/// 折成两行（用户反馈「已经重叠了还没降级成无字」）。
///
/// 修法：由 [FushiPageHeader] 的行布局用 [LayoutBuilder] 拿到的**本地可用宽**
/// （经 UI 缩放还原真实宽）判定，仅 [WindowSizeClass.expanded]（真实 ≥840）才展开，
/// 结果经本作用域下发给后代 [FushiIconButton]。域外（无此祖先，独立使用的带 label
/// 按钮）回退整窗判定，行为零变化。
class FushiHeaderLabelScope extends InheritedWidget {
  const FushiHeaderLabelScope({
    required this.expandLabels,
    required super.child,
    this.pillHeight,
    super.key,
  });

  /// 本作用域内的带 [FushiIconButton.label] 按钮是否展开成图标+文字药丸。
  final bool expandLabels;

  /// 展开药丸的最小高；null = 默认 40。M3E 悬浮页头里的文字动作是一颗与
  /// 按钮组胶囊、页签胶囊同高（56）的独立 tonal 胶囊（见
  /// `FushiFloatingTextAction`）。
  final double? pillHeight;

  /// 就近作用域的展开开关；无祖先返回 null（由调用方回退整窗判定）。
  static bool? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiHeaderLabelScope>()
      ?.expandLabels;

  /// 就近作用域给的药丸高；无祖先或未指定为 null。
  static double? pillHeightOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiHeaderLabelScope>()
      ?.pillHeight;

  @override
  bool updateShouldNotify(FushiHeaderLabelScope oldWidget) =>
      expandLabels != oldWidget.expandLabels ||
      pillHeight != oldWidget.pillHeight;
}

/// BUG-1033：纯图标按钮气泡的悬停延迟。
///
/// Material [Tooltip] 的 `waitDuration` 默认是 [Duration.zero]，而 Flutter 的
/// MouseTracker 每帧结束后会用**最后已知的光标位置**重新 hit-test。两者相乘的后果是：
/// 光标一动不动、只要有个带 tooltip 的按钮新出现在它下面，就会立刻冒出气泡——用户没有
/// 做过任何悬停动作。查词弹窗把这点放大成必现：嵌套查词的子弹窗锚成
/// `left = selectionRect.left` / `top = selectionRect.bottom + gap`（见
/// `dictionary_popup_layer.dart` 的 `calcPopupPosition`），左上角紧贴被查词，而顶栏最左端
/// 正是 A−/A+ ——子层一弹出，按钮必然落在用户刚点的那个词正下方，也就是光标停留处，于是
/// 「缩小查词字号」气泡自动盖住父层正文。
///
/// 根因在「零延迟」而非某一个调用点，故修在本组件这唯一出口：给一段悬停延迟，让气泡只对
/// **真实的悬停意图**作出反应。长按触发路径（移动端 [TooltipTriggerMode.longPress]）不看
/// 此值，行为不变。
const Duration kIconButtonTooltipHoverDelay = Duration(milliseconds: 500);

/// A button that can be set as busy. When busy, the icon is faded out when its
/// [onTap] action is on-going and processing, which can be used to
/// indicate when a button cannot be pressed once its click action has been
/// executed and is busy.
class FushiIconButton extends StatefulWidget {
  /// Creates a busy icon button. Default values rely on [IconTheme].
  const FushiIconButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.onTapDown,
    this.busy = false,
    this.enabled = true,
    this.size,
    this.shapeBorder = const CircleBorder(),
    this.backgroundColor,
    this.enabledColor,
    this.disabledColor,
    this.constraints,
    this.padding,
    this.isWideTapArea = false,
    this.focusId,
    this.label,
    this.selected = false,
    super.key,
  });

  /// 切换型按钮的选中态（例如工具栏里「多选模式」开着）。MD3 = secondaryContainer
  /// 方圆角底 + onSecondaryContainer 图标（M3 Expressive toggle icon button）；
  /// Apple = 强调色着色的液态玻璃圆钮 + onAccent 图标（iOS 26 `.glassProminent`）。
  /// 默认 false，存量调用点外观不变。
  final bool selected;

  /// The icon to display within the button.
  final IconData icon;

  /// 可展开文字标签：非空时渲染成「图标 + 文字」的描边药丸按钮（页头动作在宽窗展开
  /// 可读，对齐 Jellyfin 式工具栏），窄窗自动回落为纯图标圆钮，行为与 null 完全一致。
  /// 是否展开由 [_labelExpanded] 决定——[FushiPageHeader] 内经 [FushiHeaderLabelScope]
  /// 按**页头本地可用宽**判定（真实 ≥840 才展开，避免挤压标题）；域外独立使用回退整窗
  /// 宽（非 compact 即展开）。busy / enabled / 焦点注册在两种形态间共享同一路径。
  final String? label;

  /// The size of the icon. By default, this is 24.0.
  final double? size;

  /// Enforces all icons to have a tooltip that explains the purpose of this
  /// icon for accessibility and tutorial purposes.
  final String tooltip;

  /// Whether or not this icon should have busy behaviour, locking the icon
  /// out from being pressed when its [onTap] action is on-going.
  final bool busy;

  /// The action to execute and wait for. Use when the global position is
  /// needed.
  final FutureOr<void> Function(TapDownDetails)? onTapDown;

  /// The action to execute and wait for. While enabled,
  final FutureOr<void> Function()? onTap;

  /// For configuring a custom shaped button. By default, this is a circle.
  final ShapeBorder shapeBorder;

  /// Color of the shape around the icon.
  final Color? backgroundColor;

  /// What color to show for this icon when enabled. If null, this is the
  /// theme's default icon color.
  final Color? enabledColor;

  /// What color to show for this icon when disabled. If null, this is the
  /// theme's unselected widget color.
  final Color? disabledColor;

  /// Whether the icon is clickable upon build of this widget.
  final bool enabled;

  /// Allows overriding of the standard size of the [IconButton] constraints.
  final BoxConstraints? constraints;

  /// Allows overriding of the standard size of the [IconButton] padding.
  final EdgeInsets? padding;

  /// If this button needs to act like an [IconButton] with a wide area.
  final bool isWideTapArea;
  final FushiFocusId? focusId;

  @override
  State<StatefulWidget> createState() => _FushiIconButtonState();
}

class _FushiIconButtonState extends State<FushiIconButton>
    with TickerProviderStateMixin {
  late bool enabled;

  /// M3 Expressive 按压形变：0 = 静止（圆 / 胶囊），1 = 按下（圆角 12）。
  /// fast spatial 弹簧（刚度 1400、阻尼比 0.9），快速连点带速度续上。
  late final FushiSpring _press = FushiSpring(vsync: this);

  /// 选中态形变：0 = 圆，1 = 圆角 14 的方圆形（default spatial 弹簧）。
  late final FushiSpring _select = FushiSpring(
    vsync: this,
    initial: widget.selected ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );

  /// Stable fallback id so an icon button is a gamepad/keyboard focus target by
  /// default (no explicit [focusId] needed). Derived from this State's identity
  /// so it survives rebuilds and stays unique per instance — mirrors FushiCard
  /// / FushiListItem.
  late final FushiFocusId _fallbackFocusId =
      FushiFocusId('hibiki-icon-button-${identityHashCode(this)}');

  /// HBK-AUDIT-151: true while a busy [onTap] action is awaiting completion.
  /// Used so [didUpdateWidget] does not re-enable the button mid-action when
  /// the parent rebuilds during the await.
  bool _busyInFlight = false;

  @override
  void didUpdateWidget(FushiIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // HBK-AUDIT-151: only sync enabled from widget.enabled when not currently
    // mid-busy; otherwise a parent rebuild during the await would clobber the
    // busy lock and re-enable the button before its action finished.
    if (!_busyInFlight) {
      enabled = widget.enabled;
    }
    if (oldWidget.selected != widget.selected) {
      _select.animateTo(
        widget.selected ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _select.dispose();
    super.dispose();
  }

  /// 指针按下 / 抬起驱动按压形变。只认可点的按钮（装饰图标、禁用、busy 中
  /// 不变形）；墨水屏 / 减少动画下直接跳值（形变本身也不渲染）。
  void _setPressed(bool value) {
    if (!mounted) return;
    if (value && _tapHandler == null) return;
    _press.animateTo(value ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context));
  }

  /// 包一层指针监听，把按下 / 抬起喂给 [_press]。用 [Listener] 而不是手势
  /// 识别器：不参与手势竞技场，不影响 InkWell / 父级滚动的判定。
  Widget _trackPress(Widget child) {
    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: child,
    );
  }

  @override
  void initState() {
    super.initState();
    enabled = widget.enabled;
    // 弹簧即刻建好：懒初始化首访若落在 dispose，会在已停用元素上 createTicker
    // 而断言（见 FushiPressMorph 同款修复）。
    _press;
    _select;
  }

  /// 交给底层 [InkWell] / [IconButton] 的点击回调。装饰性图标（[FushiIconButton.onTap]
  /// 为 null）必须给 null：带着一个空转的回调，Material 控件就认为自己 enabled、
  /// 可聚焦——Tab / 手柄方向键会停在一个按了没反应的图标上，还会冒涟漪。
  /// [_focusable] 对装饰图标不登记焦点目标，这里让原生层也同口径。
  VoidCallback? get _tapHandler =>
      enabled && widget.onTap != null ? _handleTap : null;

  /// HBK-AUDIT-151: single busy-guard tap handler shared by both the
  /// [IconButton] (wide tap area) and [InkWell] branches, replacing the two
  /// previously byte-identical inline closures.
  Future<void> _handleTap() async {
    if (widget.busy) {
      if (enabled) {
        enabled = false;
        _busyInFlight = true;
        if (mounted) {
          setState(() {});
        }
        try {
          await widget.onTap?.call();
        } finally {
          enabled = true;
          _busyInFlight = false;
          if (mounted) {
            setState(() {});
          }
        }
      }
    } else {
      await widget.onTap?.call();
    }
  }

  /// MD3 默认图标色：M3 标准图标按钮的 onSurfaceVariant。墨水屏沿用主题
  /// iconTheme（纯黑）——onSurfaceVariant 在灰阶下偏淡。
  Color get enabledColor {
    if (widget.enabledColor != null) return widget.enabledColor!;
    if (isEinkTheme(context)) return Theme.of(context).iconTheme.color!;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  /// MD3 禁用色：onSurface @38%（M3 规格）。旧默认 onSurfaceVariant 现在是
  /// 启用色，沿用会让禁用态与启用态同色；墨水屏保持旧值。
  Color get disabledColor {
    if (widget.disabledColor != null) return widget.disabledColor!;
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (isEinkTheme(context)) return cs.onSurfaceVariant;
    return cs.onSurface.withValues(alpha: 0.38);
  }

  /// 是否展开文字标签。优先取 [FushiHeaderLabelScope]（页头按**本地可用宽**下发的
  /// 权威判定）；域外独立使用时回退整窗宽判定（BUG-401，乘回 UI 缩放还原真实宽），
  /// 非 compact 即展开——保持独立按钮行为不变。
  bool _labelExpanded(BuildContext context) {
    final bool? scoped = FushiHeaderLabelScope.maybeOf(context);
    if (scoped != null) return scoped;
    return windowSizeClassReal(
          MediaQuery.sizeOf(context).width,
          FushiAppUiScale.of(context),
        ) !=
        WindowSizeClass.compact;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final String? label = widget.label;
    if (label != null && _labelExpanded(context)) {
      return _focusable(
        context,
        glass
            ? _buildAppleLabelPill(context, label)
            : _buildLabelPill(context, tokens, label),
      );
    }
    if (widget.isWideTapArea) {
      final Semantics button = Semantics(
        label: widget.tooltip,
        button: true,
        child: FushiIconButtonControl(
          constraints: BoxConstraints(
            maxWidth: tokens.spacing.gap * 6,
            maxHeight: tokens.spacing.gap * 6,
          ),
          icon: FushiIcon(
            widget.icon,
            color: enabled ? enabledColor : disabledColor,
            size: widget.size,
          ),
          onPressed: _tapHandler,
        ),
      );
      return _focusable(context, _withTooltip(button));
    }

    if (glass) {
      return _focusable(
          context, _withTooltip(_buildAppleIcon(context, tokens)));
    }
    return _focusable(
        context, _withTooltip(_buildMaterialIcon(context, tokens)));
  }

  /// MD3（M3 Expressive）标准图标按钮：默认 40 的圆形命中区（8 内边距 + 24
  /// 图标）、无底、onSurfaceVariant 图标；state layer 悬停 8% / 按下 10% /
  /// 焦点 10%。按下由圆弹到圆角 12（fast spatial 弹簧），松手弹回；选中态常驻
  /// 圆角 14 的 secondaryContainer 方圆底（toggle icon button）。调用方给了
  /// 非圆 [FushiIconButton.shapeBorder] 的尊重调用方、不变形；墨水屏 / 减少
  /// 动画下静态（见 [fushiExpressiveMotionEnabled]）。
  Widget _buildMaterialIcon(BuildContext context, FushiDesignTokens tokens) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool round = widget.shapeBorder is CircleBorder;
    final bool morph = round && fushiExpressiveMotionEnabled(context);
    final bool tonalSelected = widget.selected && !eink;
    final Color iconColor = !enabled
        ? disabledColor
        : (widget.enabledColor ??
            (tonalSelected ? cs.onSecondaryContainer : enabledColor));
    final Color stateLayer =
        tonalSelected ? cs.onSecondaryContainer : cs.onSurface;

    Widget buildAt(double press, double select) {
      final ShapeBorder shape;
      if (morph) {
        final double pill = ((1 - select) * (1 - press)).clamp(0.0, 1.0);
        shape = FushiMorphBorder(
          radius: lerpDouble(14, 12, press)!,
          startPill: pill,
          endPill: pill,
        );
      } else if (widget.selected && round) {
        shape = const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)));
      } else {
        shape = widget.shapeBorder;
      }
      final Color fill = widget.backgroundColor ??
          (tonalSelected
              ? cs.secondaryContainer.withValues(
                  alpha: cs.secondaryContainer.a * (morph ? select : 1))
              : Colors.transparent);
      // 底色跟随形状画（默认圆），不再用矩形 ColoredBox 露出方角。
      Widget touchTarget = DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: shape),
        child: Padding(
          padding: widget.padding ?? EdgeInsets.all(tokens.spacing.gap),
          child: FushiIcon(widget.icon, size: widget.size, color: iconColor),
        ),
      );
      if (widget.constraints != null) {
        touchTarget = ConstrainedBox(
          constraints: widget.constraints!,
          child: Center(child: touchTarget),
        );
      }
      return Semantics(
        label: widget.tooltip,
        button: true,
        selected: widget.selected ? true : null,
        child: InkWell(
          enableFeedback: enabled,
          customBorder: shape,
          // M3 图标按钮的 state layer：悬停 8% / 按下 10% / 焦点 10%。
          hoverColor: stateLayer.withValues(alpha: 0.08),
          highlightColor: stateLayer.withValues(alpha: 0.10),
          focusColor: stateLayer.withValues(alpha: 0.10),
          onTap: _tapHandler,
          onTapDown: widget.onTapDown,
          child: touchTarget,
        ),
      );
    }

    if (!morph) return buildAt(0, widget.selected ? 1 : 0);
    return _trackPress(
      AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[
          _press.animation,
          _select.animation,
        ]),
        builder: (BuildContext context, Widget? _) => buildAt(
          _press.value.clamp(0.0, 1.0),
          _select.value.clamp(0.0, 1.0),
        ),
      ),
    );
  }

  /// MD3 带文字的页头动作（M3 Expressive）：无描边的 tonal 胶囊（高 40，
  /// secondaryContainer 填充 + onSecondaryContainer 内容），悬停 / 按下 / 焦点
  /// 叠 8% / 10% / 10% state layer，按下由胶囊弹到圆角 12。墨水屏保留描边、
  /// 不填色——填充色在灰阶下塌掉，描边才是可读的按钮边界。
  Widget _buildLabelPill(
    BuildContext context,
    FushiDesignTokens tokens,
    String label,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool morph = fushiExpressiveMotionEnabled(context);
    final Color contentColor = enabled
        ? (widget.enabledColor ??
            (eink ? enabledColor : cs.onSecondaryContainer))
        : disabledColor;
    final Color fill = widget.backgroundColor ??
        (eink ? Colors.transparent : cs.secondaryContainer);
    final BorderSide side =
        eink ? BorderSide(color: tokens.surfaces.outline) : BorderSide.none;
    final Color stateLayer = eink ? cs.onSurface : cs.onSecondaryContainer;

    Widget buildAt(double press) {
      final OutlinedBorder shape = morph
          ? FushiMorphBorder(
              side: side,
              radius: 12,
              startPill: 1 - press,
              endPill: 1 - press,
            )
          : StadiumBorder(side: side);
      return Semantics(
        label: widget.tooltip,
        button: true,
        child: Material(
          color: fill,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            enableFeedback: enabled,
            customBorder: shape.copyWith(side: BorderSide.none),
            hoverColor: stateLayer.withValues(alpha: 0.08),
            highlightColor: stateLayer.withValues(alpha: 0.10),
            focusColor: stateLayer.withValues(alpha: 0.10),
            onTap: _tapHandler,
            onTapDown: widget.onTapDown,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: FushiHeaderLabelScope.pillHeightOf(context) ?? 40,
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: tokens.spacing.rowHorizontal - 4,
                  end: tokens.spacing.rowHorizontal,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(widget.icon,
                        size: widget.size ?? 20, color: contentColor),
                    SizedBox(width: tokens.spacing.gap),
                    Text(
                      label,
                      style: tokens.type.controlLabel
                          .copyWith(color: contentColor),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (!morph) return buildAt(0);
    return _trackPress(
      AnimatedBuilder(
        animation: _press.animation,
        builder: (BuildContext context, Widget? _) =>
            buildAt(_press.value.clamp(0.0, 1.0)),
      ),
    );
  }

  /// Apple 带文字的动作：无色透明液态玻璃胶囊（iOS 26 `.glass` 按钮；桌面 macOS
  /// 紧凑尺寸高 32、移动高 36），label 色图标与文字，悬停铺 tertiaryFill，
  /// 按下变淡。已经在 [FushiToolbar] 的玻璃组胶囊里时不再自带玻璃（玻璃叠
  /// 玻璃会出两层折射边），只留无底的悬停 / 按下反馈。系统降低透明度时
  /// [fushiGlassSettings] 回落实色。
  Widget _buildAppleLabelPill(BuildContext context, String label) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final bool inGroup = FushiToolbarScope.inGlassGroupOf(context);
    final double height = compact ? 32 : 36;
    final Color contentColor = enabled
        ? (widget.enabledColor ?? apple.label)
        : (widget.disabledColor ?? apple.tertiaryLabel);
    Widget pill = _AppleIconPressable(
      onTap: _tapHandler,
      onTapDown: enabled ? widget.onTapDown : null,
      shape: const StadiumBorder(),
      fill: widget.backgroundColor,
      hoverFill: apple.tertiaryFill,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: compact ? 10 : 12,
            end: compact ? 12 : 14,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(widget.icon,
                  size: widget.size ?? (compact ? 15 : 17),
                  color: contentColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: (Theme.of(context).textTheme.labelLarge ??
                        const TextStyle())
                    .copyWith(
                  color: contentColor,
                  fontSize: compact ? 13 : 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!inGroup) {
      // 无色透明玻璃（Niratan / macOS 26 工具栏按钮：只有高光边，无灰底）。
      pill = GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiClearGlassSettings(context),
        shape: LiquidRoundedSuperellipse(borderRadius: height / 2),
        child: pill,
      );
    }
    return Semantics(label: widget.tooltip, button: true, child: pill);
  }

  /// Apple 纯图标按钮：无底 SF 图标（label 色，桌面 18 / 移动 20），悬停 /
  /// 键盘焦点铺 tertiaryFill 底（形状跟随 [FushiIconButton.shapeBorder]），
  /// 按下变淡，没有 Material 水波。选中态 = 更亮一点的无色透明玻璃圆钮（不着
  /// 强调色，Niratan / macOS 26）；在 [FushiToolbar] 的玻璃组胶囊里改用一枚
  /// 半透明 label 色圆底，避免玻璃叠玻璃。
  Widget _buildAppleIcon(BuildContext context, FushiDesignTokens tokens) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final bool selected = widget.selected;
    final bool inGroup = FushiToolbarScope.inGlassGroupOf(context);
    final Color iconColor = !enabled
        ? (widget.disabledColor ?? apple.tertiaryLabel)
        : (widget.enabledColor ?? apple.label);
    // 选中态不铺强调色（Niratan / macOS 26）：组胶囊里是一枚更亮的透明底，
    // 单独时是更亮的无色透明玻璃圆钮。
    final bool darkMode =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    Widget content = _AppleIconPressable(
      onTap: _tapHandler,
      onTapDown: enabled ? widget.onTapDown : null,
      shape: selected ? const CircleBorder() : widget.shapeBorder,
      fill: selected && inGroup
          ? apple.label.withValues(alpha: darkMode ? 0.16 : 0.1)
          : widget.backgroundColor,
      hoverFill: apple.tertiaryFill,
      child: Padding(
        padding: widget.padding ?? EdgeInsets.all(tokens.spacing.gap),
        child: FushiIcon(
          widget.icon,
          size: widget.size ?? (compact ? 18 : 20),
          color: iconColor,
        ),
      ),
    );
    if (selected && !inGroup) {
      content = GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiClearGlassSettings(context, lighter: true),
        shape: const LiquidOval(),
        child: content,
      );
    }
    if (widget.constraints != null) {
      content = ConstrainedBox(
        constraints: widget.constraints!,
        child: Center(child: content),
      );
    }
    return Semantics(
      label: widget.tooltip,
      button: true,
      selected: selected ? true : null,
      child: content,
    );
  }

  /// 纯图标按钮（无可见文字）用 Material [Tooltip] 包裹，让鼠标悬停 / 长按能弹出
  /// 用途说明——原先 [tooltip] 只喂给 [Semantics.label]（无障碍），屏幕上不可见，
  /// 导致批量操作栏等纯图标按钮「放上去没说明」。带可见文字的药丸形态无需再弹，
  /// 故不走此路径。空 [tooltip] 不包裹，避免弹出空浮层。
  Widget _withTooltip(Widget child) {
    if (widget.tooltip.isEmpty) return child;
    return FushiTooltip(
      message: widget.tooltip,
      waitDuration: kIconButtonTooltipHoverDelay,
      child: child,
    );
  }

  Widget _focusable(BuildContext context, Widget button) {
    // A decorative icon (no onTap) must not pollute the focus traversal order —
    // same rule as FushiCard / FushiListItem with a null onTap.
    if (widget.onTap == null) return button;
    // Outside a FushiFocusRoot (e.g. plain widget tests) stay a bare button —
    // zero overhead and no registration where there is no controller.
    if (FushiFocusRoot.maybeControllerOf(context) == null) return button;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) async {
            if (enabled) await _handleTap();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        // Default to the stable derived id so every actionable icon button is
        // reachable by gamepad/keyboard; an explicit focusId overrides it.
        id: widget.focusId ?? _fallbackFocusId,
        enabled: enabled,
        child: button,
      ),
    );
  }
}

/// Apple 设计系统下图标按钮的按压外壳：悬停 / 键盘焦点铺 [hoverFill]（形状
/// 跟随 [shape]；有实底时叠在实底上），按下内容变淡（UIKit 高亮节奏：立即
/// 变淡、松手缓回），没有 Material 水波。键盘可达与 [InkWell] 同口径：可点时
/// 可聚焦、经 [ActivateIntent] 触发；装饰图标（[onTap] 为 null）不进焦点链。
class _AppleIconPressable extends StatefulWidget {
  const _AppleIconPressable({
    required this.onTap,
    required this.onTapDown,
    required this.shape,
    required this.fill,
    required this.hoverFill,
    required this.child,
  });

  final VoidCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final ShapeBorder shape;
  final Color? fill;
  final Color hoverFill;
  final Widget child;

  @override
  State<_AppleIconPressable> createState() => _AppleIconPressableState();
}

class _AppleIconPressableState extends State<_AppleIconPressable> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  bool get _enabled => widget.onTap != null;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = _enabled;
    final bool highlight = enabled && (_hovered || _focused);
    final Color? fill = widget.fill;
    final Color color = !highlight
        ? (fill ?? Colors.transparent)
        : (fill == null
            ? widget.hoverFill
            : Color.alphaBlend(widget.hoverFill, fill));
    final Widget body = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: ShapeDecoration(color: color, shape: widget.shape),
      child: AnimatedOpacity(
        duration: _pressed ? Duration.zero : const Duration(milliseconds: 180),
        opacity: _pressed ? 0.35 : 1,
        child: widget.child,
      ),
    );
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool value) => setState(() => _hovered = value),
      onShowFocusHighlight: (bool value) => setState(() => _focused = value),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled
            ? (TapDownDetails details) {
                _setPressed(true);
                widget.onTapDown?.call(details);
              }
            : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: widget.onTap,
        child: body,
      ),
    );
  }
}
