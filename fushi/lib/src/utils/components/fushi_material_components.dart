import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// SelectedContent 住在 rendering 层（selection.dart），material 不转出它。
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        LogicalKeyboardKey,
        SystemChannels,
        TextInputAction,
        TextInputFormatter;
import 'package:macos_ui/macos_ui.dart'
    show MacosTextField, MacosIcon, OverlayVisibilityMode;
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/focus/page_scroll_registry.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_gamepad_keyboard.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogHeroIcon, fushiM3eMenuAnimationStyle;
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_page_chrome.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/glass/fushi_native_material.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/system_transparency.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassContainer,
        LiquidRoundedRectangle,
        LiquidRoundedSuperellipse;
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

// ── 「玻璃」设计系统的共享原语 ────────────────────────────────────────────
//
// 共享组件在 [isGlassDesign] 为 true 时换成 `liquid_glass_widgets` 组件族，
// MD3 分支一行不动。下面几个原语给本文件与 settings_shared / adaptive_* 共用。

/// 玻璃组件的形状：按 Fushi 圆角令牌取左上角半径的连续曲率超椭圆。
LiquidRoundedSuperellipse fushiGlassShapeOf(BorderRadius radius) =>
    LiquidRoundedSuperellipse(borderRadius: radius.topLeft.x);

/// 玻璃背衬：把一层玻璃画在 [child] **背后**（Stack 的兄弟层），而不是把
/// [child] 包进玻璃。
///
/// 存在的理由是**结构恒定**：导航栏 / 工具条底下挂着带 GlobalKey 的子树，
/// 若按「是否玻璃」把它们包进 / 拆出 GlassContainer，设计系统或材质一切换，
/// 整棵子树就在同一帧里被重挂（LayoutBuilder 里还会触发 framework 的
/// `_elements.contains(element)` 断言，Mac 调试版红屏）。这里外层永远是同一个
/// Stack、[child] 永远在同一个槽位，切换时只换背景槽里的那一层。
///
/// [enabled] 为 false（MD3）时背景槽是空盒，布局与绘制都与不包时一致
/// （passthrough：[child] 拿到的约束与不包时一字不差）。
class FushiGlassBackdrop extends StatelessWidget {
  const FushiGlassBackdrop({
    required this.child,
    required this.enabled,
    super.key,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.prominent = false,
  });

  final Widget child;
  final bool enabled;
  final BorderRadius borderRadius;

  /// 玻璃着色；null = 主题默认（surfaceContainerHigh 色阶）。
  final Color? tint;

  /// 静态主表面（导航栏、顶栏）在液态档用 premium 渲染。
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: enabled
              ? IgnorePointer(
                  child: GlassContainer(
                    // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
                    useOwnLayer: true,
                    shape: fushiGlassShapeOf(borderRadius),
                    quality: fushiGlassQuality(context, prominent: prominent),
                    settings: tint == null
                        ? null
                        : fushiGlassSettings(context, tint: tint),
                    child: const SizedBox.expand(),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        child,
      ],
    );
  }
}

/// 玻璃设计系统下的按压高亮层：给没有自带交互外观的实色行（设置行、分组
/// 折叠头、可点卡片）一个 iOS 单元格口径的按下反馈——systemFill 灰底（不是
/// MD3 的墨水涟漪）。只旁观指针，不进手势竞技场。
class FushiGlassPressHighlight extends StatefulWidget {
  const FushiGlassPressHighlight({
    required this.child,
    super.key,
    this.borderRadius,
  });

  final Widget child;
  final BorderRadius? borderRadius;

  @override
  State<FushiGlassPressHighlight> createState() =>
      _FushiGlassPressHighlightState();
}

class _FushiGlassPressHighlightState extends State<FushiGlassPressHighlight> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final Color pressedColor = appleColorsOf(context).fill;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedContainer(
        duration: _pressed ? Duration.zero : const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _pressed ? pressedColor : Colors.transparent,
          borderRadius: widget.borderRadius,
        ),
        child: widget.child,
      ),
    );
  }
}

class FushiCard extends StatefulWidget {
  const FushiCard({
    required this.child,
    super.key,
    this.padding,
    this.margin,
    this.color,
    this.borderColor,
    this.borderRadius,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusId,
    this.pressScale = true,
    this.grouped = false,
    this.clipBehavior = Clip.antiAlias,
    this.variant = FushiCardVariant.filled,
    this.tone = FushiCardTone.neutral,
    this.morph,
  });

  /// M3 卡片三类容器（填充 / 抬升 / 描边），默认填充。调用点显式 [color] /
  /// [borderColor] 仍优先。
  final FushiCardVariant variant;

  /// M3E 饱和配色变体：非 neutral 时底色换成对应 container 色块、卡内未显式
  /// 着色的文字与图标换成 onContainer（Apple 落到淡染底，见
  /// [fushiCardToneColors]）。
  final FushiCardTone tone;

  /// 是否做 M3E 交互形变（悬停内侧角 → 12、按下 / 选中 → 16，弹簧驱动）。
  /// null = 分组列表格（[grouped]）开、独立卡片关——M3E 的形变是列表分段的
  /// 语言，独立卡片的反馈是抬升 + 按压回弹。
  final bool? morph;

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final Color? borderColor;
  final BorderRadius? borderRadius;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 可点卡片按下时是否轻微下沉（[FushiPressScale]）。false = 两套设计系统都
  /// 不缩放，只留状态层 / 高亮反馈。
  final bool pressScale;

  /// 这张卡是分组列表里的一格（[FushiGroupedListItem] 等）。Apple 下 inset
  /// grouped 的单元格按下只高亮、不缩放（整组里单独一格缩一下会和上下格错开
  /// 一道缝）；MD3 分段卡不受影响。
  final bool grouped;

  /// 卡片是否把内容裁进自身圆角。封面卡（`shelfCoverCard`，底色透明、封面即
  /// 卡片）传 [Clip.none]：封面框自己裁圆角并画阴影，被卡片裁掉阴影就没了。
  final Clip clipBehavior;

  /// 桌面端鼠标右键（secondary tap）触发，通常映射到与 [onLongPress] 相同的
  /// 上下文菜单。触摸/手柄设备没有 secondary tap，故配线全平台无副作用。
  final VoidCallback? onSecondaryTap;
  final FushiFocusId? focusId;

  @override
  State<FushiCard> createState() => _FushiCardState();
}

class _FushiCardState extends State<FushiCard>
    with SingleTickerProviderStateMixin {
  late final FushiFocusId _fallbackFocusId = FushiFocusId(
    'hibiki-card-${identityHashCode(this)}',
  );

  /// M3E 交互形变 / 抬升的弹簧：0 静止、1 悬停、2 按下 / 选中。只在需要时
  /// 惰性创建（大多数卡片不可点，不该各挂一个 ticker）。
  FushiSpring? _spring;
  bool _hovered = false;
  bool _pressed = false;

  bool get _interactive =>
      widget.onTap != null ||
      widget.onLongPress != null ||
      widget.onSecondaryTap != null;

  bool get _morphEnabled => widget.morph ?? widget.grouped;

  /// 是否需要弹簧驱动的视觉（形变或抬升卡的悬停投影）。
  bool get _animated =>
      _morphEnabled ||
      (widget.variant == FushiCardVariant.elevated && _interactive);

  double get _stateLevel {
    if (_pressed || widget.selected) return 2;
    if (_hovered) return 1;
    return 0;
  }

  FushiSpring _ensureSpring() => _spring ??= FushiSpring(
        vsync: this,
        initial: _stateLevel,
        spring: fushiExpressiveDefaultSpatial,
      );

  void _retarget() {
    if (!mounted || !_animated || !fushiExpressiveMotionEnabled(context)) {
      return;
    }
    _ensureSpring().animateTo(
      _stateLevel,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    _retarget();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
    _retarget();
  }

  @override
  void didUpdateWidget(covariant FushiCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected && _spring != null) {
      // didUpdateWidget 在构建期：弹簧重定向挪到帧后（直接改 controller 会在
      // 构建中把子孙标脏），并补一帧确保回调真的跑。
      SchedulerBinding.instance
        ..addPostFrameCallback((_) => _retarget())
        ..ensureVisualUpdate();
    }
  }

  @override
  void dispose() {
    _spring?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // M3E 内容层卡片（2026-10-05 列表 / 卡片统一为 M3E）：
    // - 填充（默认）= surfaceContainerLow（tokens.surfaces.group）分层、20 圆角、
    //   无描边无阴影；抬升 = 同底 + level1 投影（悬停 level2）；描边 = surface 底
    //   + outlineVariant 1px；
    // - 饱和变体（[FushiCard.tone]）= xxxContainer 色块 + onXxxContainer 前景；
    // - 选中 = secondaryContainer 底（全局唯一的卡片选中口径）。
    final FushiCardColors? toneColors =
        fushiCardToneColors(context, widget.tone);
    final Color baseColor = toneColors?.container ??
        (widget.variant == FushiCardVariant.outlined && !eink
            ? scheme.surface
            : tokens.surfaces.group);
    final Color effectiveColor = widget.color ??
        (widget.selected ? tokens.surfaces.selected : baseColor);
    final Color? foreground = widget.color == null && widget.selected && !eink
        ? scheme.onSecondaryContainer
        : (widget.color == null ? toneColors?.onContainer : null);
    final BorderRadius baseRadius = widget.borderRadius ??
        const BorderRadius.all(Radius.circular(kFushiMd3CardRadius));
    // eink 把所有 surface container 塌缩为背景色（theme_notifier eink scheme），
    // 卡片没有边就与页面融为一体；主题层只给裸 Card 补了描边（CardThemeData），
    // FushiCard 在这里自己补。选中态加粗到 2px——eink 下 selected 填充色同样
    // 塌缩，边宽是唯一可辨的选中信号。
    // 透明描边等于没有描边：不要让它占 1px 笔宽把内容（封面即卡片的封面）
    // 往里挤，造成卡片比卡槽窄 2px。
    final BorderSide side = widget.borderColor != null &&
            widget.borderColor!.a > 0
        ? BorderSide(color: widget.borderColor!)
        : (eink
            ? BorderSide(
                color: tokens.surfaces.outline,
                width: widget.selected ? 2 : 1,
              )
            : widget.variant == FushiCardVariant.outlined
                ? BorderSide(color: scheme.outlineVariant)
                : BorderSide.none);
    Widget content = Padding(
      padding: widget.padding ?? EdgeInsets.all(tokens.spacing.card),
      child: widget.child,
    );
    // 前景层恒在（只换颜色）：按选中 / 配色增删这一层会让卡内子树整棵重挂。
    content = IconTheme.merge(
      data: IconThemeData(color: foreground),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground),
        child: content,
      ),
    );
    final Widget card = isGlassDesign(context)
        ? _buildGlassCard(context, content)
        : ContextMenuTrigger(
            // 右键菜单不再硬绑鼠标次按钮：改由绑定表决定哪个鼠标键唤出（默认仍是右键），
            // 用户把右键绑给页面动作时菜单自动让位。InkWell 只留 tap / longPress。
            onInvoke: contextMenuInvoker(widget.onSecondaryTap),
            child: Padding(
              padding: widget.margin ?? EdgeInsets.zero,
              // 可点的卡片按下即轻微下沉（2026-10 交互重做）：只旁观指针事件，不进
              // 手势竞技场，InkWell 的点击 / 长按语义不变；eink / 减弱动态效果下不包。
              // 分段列表格（grouped + 形变）的按压反馈是形变，不缩放（整组里单独
              // 一格缩一下会和上下格错开一道缝）。
              child: FushiPressScale(
                enabled: widget.pressScale &&
                    !(widget.grouped && _morphEnabled) &&
                    (widget.onTap != null || widget.onLongPress != null),
                child: _buildMd3Surface(
                  context,
                  content: content,
                  color: effectiveColor,
                  baseRadius: baseRadius,
                  side: side,
                  eink: eink,
                  scheme: scheme,
                ),
              ),
            ),
          );
    if (widget.onTap == null) return card;
    if (FushiFocusRoot.maybeControllerOf(context) == null) return card;

    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: widget.focusId ?? _fallbackFocusId,
        child: card,
      ),
    );
  }

  /// MD3（M3E）卡面：底色经状态时长渐变；圆角 / 投影跟随弹簧（形变卡悬停
  /// 内侧角 → 12、按下 / 选中 → 16；抬升卡悬停 level1 → level2）。树结构
  /// 恒定：不论是否形变 / 抬升，都是 AnimatedBuilder → AnimatedContainer →
  /// Material → (InkWell) → content。
  Widget _buildMd3Surface(
    BuildContext context, {
    required Widget content,
    required Color color,
    required BorderRadius baseRadius,
    required BorderSide side,
    required bool eink,
    required ColorScheme scheme,
  }) {
    final bool elevated = widget.variant == FushiCardVariant.elevated && !eink;
    // 弹簧在首次需要时以「当前状态」为初值建好，之后的悬停 / 按下才有过渡。
    if (_animated) _ensureSpring();
    // 动效关（墨水屏 / 减弱动态效果）或未首次交互时直接取状态值，不建弹簧。
    final Animation<double> level =
        _animated && fushiExpressiveMotionEnabled(context)
            ? _spring!.animation
            : AlwaysStoppedAnimation<double>(_animated ? _stateLevel : 0);
    return AnimatedBuilder(
      animation: level,
      builder: (BuildContext context, Widget? _) {
        final double t = level.value;
        final BorderRadius radius =
            _morphEnabled ? fushiM3eMorphRadius(baseRadius, t) : baseRadius;
        // 颜色走状态时长渐变（AnimatedContainer）；圆角 / 投影由弹簧逐帧给值，
        // AnimatedContainer 只在两帧之间补间，弹簧仍是形变节奏的唯一来源。
        return AnimatedContainer(
          duration: einkSafeDuration(context, fushiMd3StateDuration),
          curve: fushiMd3StateCurve,
          decoration: ShapeDecoration(
            color: color,
            shape: RoundedRectangleBorder(borderRadius: radius, side: side),
            shadows: elevated
                ? fushiM3eCardShadow(context, t.clamp(0.0, 1.0))
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: RoundedRectangleBorder(borderRadius: radius),
            clipBehavior: widget.clipBehavior,
            child: !_interactive
                ? content
                : InkWell(
                    onTap: widget.onTap,
                    onLongPress: widget.onLongPress,
                    onHover: _setHovered,
                    onHighlightChanged: _setPressed,
                    // 状态层 / 水波按卡片圆角走：Material 裁剪时与之重合
                    // （像素不变），封面卡不裁剪时靠它保持圆角。
                    borderRadius: radius,
                    // 柔和状态层（悬停 8% / 按下 10% onSurface），水波
                    // 由外层 Material 裁在圆角里；墨水屏交回默认。
                    overlayColor:
                        eink ? null : fushiMd3ContentStateLayer(scheme),
                    child: content,
                  ),
          ),
        );
      },
    );
  }

  /// 玻璃设计系统：Apple 26 的内容层卡片是**实色**而不是玻璃——底色
  /// secondarySystemGroupedBackground（调用点显式 color 优先）、连续曲率圆角
  /// （iOS ≈ 24 / 桌面 12，调用点显式 borderRadius 优先）、无描边无阴影。选中态
  /// 是强调色 1.5px 细描边（不是 MD3 的 tonal 色块）；按下是 systemFill 高亮。
  /// 焦点（外层 Actions + FushiFocusTarget）、右键菜单、按压下沉与 margin 和
  /// MD3 分支同一套，调用点的 key / focusId 不变。
  ///
  /// 点击面是 [FushiAppleRow]（同 MD3 的 InkWell）：没有 FushiFocusRoot 时它
  /// 自己就是 Tab 停靠点（Enter / 手柄 A → onTap，强调色焦点描边）；有焦点根时
  /// 交给外层 FushiFocusTarget，行自身不再取焦点（一卡一个停靠点）。
  Widget _buildGlassCard(BuildContext context, Widget content) {
    final FushiAppleColors apple = appleColorsOf(context);
    final BorderRadius radius = widget.borderRadius ??
        FushiAppleMetrics.of(context).groupBorderRadius;
    final bool interactive =
        widget.onTap != null || widget.onLongPress != null;
    Widget body = content;
    if (interactive) {
      body = FushiAppleRow(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        selected: widget.selected,
        // 卡片选中靠下面的强调色描边，不铺选中底。
        selectedBackground: Colors.transparent,
        focusable: FushiFocusRoot.maybeControllerOf(context) == null,
        borderRadius: radius,
        child: body,
      );
    }
    // 描边层恒在（只换颜色）：按选中态增删这一层会让卡片内容整棵重挂。
    body = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: widget.borderColor ??
              (widget.selected ? apple.accent : Colors.transparent),
          width: widget.borderColor == null ? 1.5 : 1,
        ),
      ),
      child: body,
    );
    return ContextMenuTrigger(
      onInvoke: contextMenuInvoker(widget.onSecondaryTap),
      child: Padding(
        padding: widget.margin ?? EdgeInsets.zero,
        // 分组单元格（[grouped]）只高亮不缩放，见 [FushiCard.grouped]。
        child: FushiPressScale(
          enabled: widget.pressScale &&
              !widget.grouped &&
              (widget.onTap != null || widget.onLongPress != null),
          child: FushiAppleGroupSurface(
            color: widget.color,
            borderRadius: radius,
            clipBehavior: widget.clipBehavior,
            child: body,
          ),
        ),
      ),
    );
  }
}

enum FushiListDensity { standard, compact }

/// 选中态高亮形状：fill = 满宽方角（平铺列表），pill = 内缩圆角（导航列表）。
enum FushiListItemSelectedShape { fill, pill }

class FushiListItem extends StatefulWidget {
  const FushiListItem({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.selectedShape = FushiListItemSelectedShape.fill,
    this.onTap,
    this.minHeight,
    this.density = FushiListDensity.standard,
    this.padding,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
    this.focusId,
    this.autofocus = false,
    this.isThreeLine = false,
  });

  /// 三行列表项（M3 three-line list item）：最小高 88，行首 / 行尾与标题顶对齐，
  /// 副标题默认放宽到两行。与单行（56）/ 双行（72，带副标题）构成三档高度。
  final bool isThreeLine;

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final FushiListItemSelectedShape selectedShape;
  final VoidCallback? onTap;
  final double? minHeight;
  final FushiListDensity density;
  final EdgeInsetsGeometry? padding;

  /// 标题最多几行，默认 1。
  ///
  /// BUG-1184 调查记录：曾把默认值改成 2（因为列表项承载的正是书名、视频名、词典名
  /// 这类长文本，单行 ellipsis 在窄屏上只看得到开头几个字）。**该改动已回退**：
  /// 本组件自身行高虽只有 minHeight 下限，但相当多调用点把它放在固定高度的容器里
  /// （golden `list_tile_narrow` 即在 150×80 的盒子里复现出 overflow 红条），窄容器
  /// 里标题一换行就会撑破父容器。所以放宽必须逐调用点显式进行——只在父容器高度自由
  /// 的地方传 `titleMaxLines: 2`，而不是改默认值连带影响每一个既有调用点。
  ///
  /// null = 不限行数：只给父容器高度自由、且截断会丢掉**唯一区分信息**的调用点
  /// （发现页同系列书名只在末尾差一个卷号，两行 ellipsis 恰好把卷号切掉）。
  final int? titleMaxLines;
  final int subtitleMaxLines;
  final FushiFocusId? focusId;

  /// 本行开屏即拿到键盘焦点（等价于框架 `ListTile.autofocus`）。
  ///
  /// BUG-1425：把裸 `ListTile` 收口到本组件时，唯一没有对应物的就是 `autofocus`。
  /// 焦点驱动纪律下它不是装饰——「打开对话框即落在正确的那一行，回车直接确认」
  /// （texthooker 窗口选择器的 BUG-1049 行为）全靠它。只在 [onTap] 非空、真正建出
  /// [InkWell] 焦点节点时有意义。
  final bool autofocus;

  @override
  State<FushiListItem> createState() => _FushiListItemState();
}

class _FushiListItemState extends State<FushiListItem> {
  late final FushiFocusId _fallbackFocusId = FushiFocusId(
    'hibiki-list-item-${identityHashCode(this)}',
  );

  /// 按下中：M3E 列表行按下 / 选中时高亮块形变到 corner-large（16）。
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    // MD3 列表行（2026-10-04 卡片 / 列表统一）：选中 = secondaryContainer 底 +
    // onSecondaryContainer 前景，字重不变（选中信号是底色块，不是粗体彩字）。
    // 墨水屏 secondaryContainer 塌缩成背景色，保留原来的 primary 前景 + 加粗 +
    // 实描边（见下）三重信号，可读性不倒退。
    final Color color =
        widget.selected ? tokens.surfaces.selected : Colors.transparent;
    final Color selectedForeground =
        eink ? tokens.surfaces.primary : scheme.onSecondaryContainer;
    final bool boldSelected = widget.selected && eink;
    final Color primaryForeground =
        widget.selected ? selectedForeground : tokens.surfaces.onSurface;
    final Color secondaryForeground =
        widget.selected ? selectedForeground : tokens.surfaces.onVariant;
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      color: primaryForeground,
      fontWeight:
          boldSelected ? FontWeight.w700 : tokens.type.listTitle.fontWeight,
    );
    // 副标题 bodyMedium（MD3 列表规格；原来的 bodySmall 在两行列表里偏小）。
    final TextStyle subtitleStyle = (Theme.of(context).textTheme.bodyMedium ??
            tokens.type.listSubtitle)
        .copyWith(
      color: secondaryForeground,
      fontWeight: boldSelected ? FontWeight.w600 : null,
    );
    final TextStyle metadataStyle = tokens.type.metadata.copyWith(
      color: secondaryForeground,
      fontWeight:
          boldSelected ? FontWeight.w700 : tokens.type.metadata.fontWeight,
    );
    // 最小高 56，带副标题的两行行 72（MD3 one-line / two-line list item）。
    final double resolvedMinHeight = widget.minHeight ??
        switch (widget.density) {
          FushiListDensity.standard => widget.isThreeLine
              ? 88
              : widget.subtitle != null
                  ? 72
                  : tokens.density.listMinHeight,
          FushiListDensity.compact => tokens.density.compactListMinHeight,
        };

    // 对话框面板里的行一律按圆角高亮排（MD3 规范的对话框选择列表），选中
    // 不再是顶到两边的整行色块。
    final bool pill = widget.selectedShape == FushiListItemSelectedShape.pill ||
        FushiDialogScope.of(context);
    // 状态层 / 选中底一律是内缩的 12 圆角块（不顶到容器边）：pill（导航 /
    // 对话框）内缩 8，平铺列表内缩 4——平铺行默认内边距同步减 4，文字起点仍在
    // 容器边 16 处，与分隔线、分组标题对齐。
    final double inset = pill ? tokens.spacing.gap : kFushiMd3RowInset;
    // M3E 列表行形变：静止 / 悬停 12（corner-medium），按下 / 选中 16
    // （corner-large）；墨水屏不形变。
    final BorderRadius highlightRadius = BorderRadius.all(
      Radius.circular(
        (widget.selected || _pressed) && !eink
            ? FushiM3eShape.listActive
            : kFushiMd3RowRadius,
      ),
    );
    final double horizontalPadding = pill
        ? tokens.spacing.rowHorizontal
        : tokens.spacing.rowHorizontal - inset;
    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: resolvedMinHeight),
      child: Padding(
        padding: widget.padding ??
            EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: tokens.spacing.rowVertical,
            ),
        child: Row(
          crossAxisAlignment: widget.isThreeLine
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: <Widget>[
            if (widget.leading != null) ...<Widget>[
              // 行首图标 24、单色、无底（MD3 list leading icon）；要 M3E 形状底的
              // 调用点传 [FushiListLeadingIcon]。
              IconTheme.merge(
                data: IconThemeData(color: secondaryForeground, size: 24),
                child: widget.leading!,
              ),
              SizedBox(width: tokens.spacing.gap * 2),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  DefaultTextStyle.merge(
                    style: titleStyle,
                    maxLines: widget.titleMaxLines,
                    // 不限行时不能带 ellipsis：TextPainter 在 maxLines 为 null
                    // 时把省略号作用于**第一行**，「不限行」反而退化成单行。
                    overflow: widget.titleMaxLines == null
                        ? null
                        : TextOverflow.ellipsis,
                    child: widget.title,
                  ),
                  if (widget.subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
                      child: DefaultTextStyle.merge(
                        style: subtitleStyle,
                        maxLines: widget.isThreeLine
                            ? math.max(2, widget.subtitleMaxLines)
                            : widget.subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        child: widget.subtitle!,
                      ),
                    ),
                ],
              ),
            ),
            if (widget.trailing != null) ...<Widget>[
              SizedBox(width: tokens.spacing.gap + 4),
              DefaultTextStyle.merge(
                style: metadataStyle,
                child: IconTheme.merge(
                  data: IconThemeData(color: secondaryForeground),
                  child: widget.trailing!,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (isGlassDesign(context)) {
      return _wrapFocus(context, _buildGlassTile(context, pill));
    }
    // **两态都画边框**，未选中时透明：BoxDecoration 的 border 会把子节点向内挤
    // 1px，只在选中时给边框会让同一行选中后比未选中高 2px（功能选择卡片在列表里
    // 逐行错位）。几何恒定，颜色才是唯一的选中信号。
    //
    // 非 eink 下选中边也保持透明：secondaryContainer 填充已经把选中态说清楚了，
    // 再叠一圈细边只是填充之上的第二条线。eink 下选中填充塌缩成背景色，边是唯一
    // 信号，那里保留并换成实描边色。
    final BoxBorder border = Border.all(
      color: widget.selected && eink
          ? tokens.surfaces.outline
          : Colors.transparent,
    );
    final Widget material = AnimatedContainer(
      duration: einkSafeDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      margin: EdgeInsets.symmetric(horizontal: inset),
      decoration: BoxDecoration(
        color: color,
        borderRadius: highlightRadius,
        border: border,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: widget.onTap == null
            ? content
            : InkWell(
                onTap: widget.onTap,
                autofocus: widget.autofocus,
                onHighlightChanged: _setPressed,
                borderRadius: highlightRadius,
                // 柔和状态层（悬停 8% / 按下 10% onSurface）；墨水屏交回默认。
                overlayColor: eink ? null : fushiMd3ContentStateLayer(scheme),
                child: content,
              ),
      ),
    );
    return _wrapFocus(context, material);
  }

  /// 焦点包装：MD3 与玻璃两条分支共用同一套（Actions 在 FushiFocusTarget 之上，
  /// Enter / 手柄 A → [ActivateIntent] → onTap），focusId 与 key 不随设计系统变。
  Widget _wrapFocus(BuildContext context, Widget material) {
    if (widget.onTap == null) return material;

    final FushiFocusId effectiveFocusId = widget.focusId ?? _fallbackFocusId;
    final Widget target = Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: effectiveFocusId,
        // MD3 下 autofocus 落在 InkWell 上；玻璃行没有 InkWell，由焦点目标
        // 自己开屏取焦（Enter 同样经上面的 Actions 激活）。
        autofocus: widget.autofocus && isGlassDesign(context),
        child: material,
      ),
    );
    if (FushiFocusRoot.maybeControllerOf(context) == null) return material;
    return target;
  }

  /// 玻璃设计系统：iOS inset grouped 的**实色行**（[FushiAppleRow]，不是玻璃）。
  /// 最小高 44（桌面 38；compact 密度再收 4）、左右 16、标题 17 label /
  /// 副标题 15 secondaryLabel（桌面 15 / 13）、行首图标强调色、行尾附件
  /// secondaryLabel；悬停 = tertiaryFill、按下 = systemFill。选中按列表性质
  /// 分两种（与设置侧栏 / 菜单同一口径）：
  /// - 导航型（[FushiListItemSelectedShape.pill]，不在对话框里）= 强调色实底 +
  ///   onAccent 图标 / 文字，圆角桌面 8 / 移动 12；
  /// - 选择型（平铺列表、对话框里的单选）= 不铺底、不加粗，行尾强调色对勾
  ///   （调用点没给 trailing 时自动补 [FushiAppleCheckmark]，给了就把它染成
  ///   强调色）。
  /// 标题行数、minHeight、padding 等调用点契约与 MD3 同。
  ///
  /// 焦点：有 FushiFocusRoot 时由 [_wrapFocus] 的焦点目标负责 Tab / Enter，行
  /// 自身不再是停靠点（一行一个停靠点）；没有焦点根时行自己可 Tab、Enter 激活。
  Widget _buildGlassTile(BuildContext context, bool pill) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final bool compact = widget.density == FushiListDensity.compact;
    final bool inDialog = FushiDialogScope.of(context);
    final bool navSelected = widget.selected && pill && !inDialog;
    final bool checkSelected = widget.selected && !navSelected;
    // 导航型选中行上的前景一律 onAccent（强调色实底上的反色）。
    final Color? navForeground = navSelected ? apple.onAccent : null;
    final TextStyle titleStyle = metrics.titleStyle(context).copyWith(
          fontSize: compact ? metrics.titleSize - 2 : null,
          color: navForeground,
        );
    final TextStyle subtitleStyle = metrics.subtitleStyle(context).copyWith(
          fontSize: compact ? metrics.subtitleSize - 2 : null,
          color: navForeground?.withValues(alpha: 0.8),
        );
    final Widget? trailing = widget.trailing ??
        (checkSelected ? const FushiAppleCheckmark() : null);
    final double minHeight = widget.minHeight ??
        (widget.isThreeLine
            ? metrics.rowMinHeight + 20
            : compact
                ? metrics.rowMinHeight - 4
                : metrics.rowMinHeight);
    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: widget.padding ??
            EdgeInsets.symmetric(
              horizontal: metrics.rowHorizontal,
              vertical: compact ? metrics.rowVertical - 2 : metrics.rowVertical,
            ),
        child: Row(
          children: <Widget>[
            if (widget.leading != null) ...<Widget>[
              IconTheme.merge(
                data: IconThemeData(
                  color: navForeground ?? apple.accent,
                  size: metrics.leadingIconSize,
                ),
                child: widget.leading!,
              ),
              SizedBox(width: metrics.leadingGap),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  DefaultTextStyle.merge(
                    style: titleStyle,
                    maxLines: widget.titleMaxLines,
                    // 不限行时不能带 ellipsis（同 MD3 分支的说明）。
                    overflow: widget.titleMaxLines == null
                        ? null
                        : TextOverflow.ellipsis,
                    child: widget.title,
                  ),
                  if (widget.subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: DefaultTextStyle.merge(
                        style: subtitleStyle,
                        maxLines: widget.subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        child: widget.subtitle!,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 8),
              DefaultTextStyle.merge(
                style: subtitleStyle,
                child: IconTheme.merge(
                  data: IconThemeData(
                    color: navForeground ??
                        (checkSelected ? apple.accent : apple.secondaryLabel),
                  ),
                  child: trailing,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final BorderRadius radius = pill || inDialog
        ? BorderRadius.circular(metrics.desktop ? 8 : 12)
        : BorderRadius.zero;
    return Padding(
      padding: pill
          ? EdgeInsets.symmetric(horizontal: tokens.spacing.gap)
          : EdgeInsets.zero,
      child: FushiAppleRow(
        onTap: widget.onTap,
        selected: widget.selected,
        // 选择型选中不铺底（透明），悬停 / 按下照常反馈；导航型铺强调色实底。
        selectedBackground: navSelected ? apple.accent : Colors.transparent,
        focusable: FushiFocusRoot.maybeControllerOf(context) == null,
        autofocus: widget.autofocus,
        borderRadius: radius,
        child: content,
      ),
    );
  }
}

class FushiSearchField extends StatelessWidget {
  const FushiSearchField({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    required this.onSubmitted,
    super.key,
    this.fieldKey,
    this.clearButtonKey,
    this.focusId,
    this.onClear,
    this.size = FushiSearchFieldSize.regular,
    this.trailing = const <Widget>[],
    this.leading,
    this.autofocus = false,
  });

  /// 替换前置放大镜的控件（M3E search bar 的 leading：返回箭头 / 菜单钮）。
  /// 为空时是放大镜。会被包进 [FushiSearchLeading]，两套设计系统都仍认得出
  /// 这是搜索框（胶囊形态不丢）。
  final Widget? leading;

  /// 挂载后自动取焦点（搜索页 / 搜索视图打开即可输入）。
  final bool autofocus;

  final Key? fieldKey;
  final Key? clearButtonKey;

  /// 尺寸档：[FushiSearchFieldSize.regular] 是工具条 / 行内搜索胶囊（MD3 40、
  /// Apple 36）；[FushiSearchFieldSize.large] 是页面顶部的独立搜索栏——MD3 按
  /// M3 SearchBar（56 高全圆角、24 前置图标、48 触控的尾部动作、bodyLarge），
  /// Apple 没有 56 的搜索栏，仍是 iOS 搜索胶囊（36），不拉伸。
  final FushiSearchFieldSize size;

  /// 尾部动作（排在清除 / 软键盘按钮之后），例如直达管理页的圆钮。large 档
  /// MD3 下每个动作给 48×48 触控区。
  final List<Widget> trailing;
  final FushiFocusId? focusId;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onClear;

  /// 搜索框尾部按钮（清除 + 软键盘 / 粘贴），MD3 与 Apple 两条分支共用。
  List<Widget> _trailing(
    BuildContext context,
    TextEditingValue value, {
    bool large = false,
  }) {
    // large 档（MD3 SearchBar）：24 图标 + 12 内边距 = 48 触控区。
    final double iconSize =
        large ? kFushiSearchFieldLargeIconSize : kFushiSearchFieldIconSize;
    final EdgeInsets padding =
        large ? const EdgeInsets.all(12) : const EdgeInsets.all(4);
    final Widget? inputSuffix = _hibikiTextFieldInputSuffix(
      context: context,
      controller: controller,
      onChanged: onChanged,
      iconSize: iconSize,
      padding: padding,
    );
    return <Widget>[
      if (onClear != null && value.text.isNotEmpty)
        FushiIconButton(
          key: clearButtonKey,
          icon: Icons.close,
          tooltip: t.clear,
          size: iconSize,
          padding: padding,
          onTap: () {
            onClear?.call();
            if (focusNode.canRequestFocus) {
              focusNode.requestFocus();
            }
          },
        ),
      if (inputSuffix != null) inputSuffix,
      for (final Widget action in trailing)
        large
            ? ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Center(widthFactor: 1, child: action),
              )
            : action,
    ];
  }

  /// 提交的收尾：清 composing，移动端再收起软键盘（BUG-2686）。
  ///
  /// 焦点刻意**不**交出去：unfocus 之后 [FushiFocusRoot] 的被动修复会把焦点
  /// 还给登记过的搜索框（BUG-2620），移动端键盘随之再弹一次。所以只收键盘、
  /// 不交焦点——再点一下框（EditableText.requestKeyboard）键盘就回来。
  ///
  /// 收键盘必须排在 EditableText 自己的收尾**之后**：提交动作带 shouldUnfocus，
  /// 而焦点还在，它会在 onSubmitted 之后排一个 microtask 重建输入连接并 show
  /// （flutter#84240 的「开发者把焦点留住了就重置键盘」）。在这里同步 hide 会被
  /// 那次 show 覆盖——实测日志就是 hide → clearClient → setClient → show。
  /// 所以收键盘排到下一帧的后帧回调：帧总在 microtask 队列排空之后才开始，顺序
  /// 是确定的，不是靠等时间。后帧回调本身不调度帧，必须显式 scheduleFrame，否则
  /// 没有别的 setState 时它永远不跑。桌面端没有要收的软键盘，维持原样。
  void _finishSubmit() {
    controller.clearComposing();
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!focusNode.hasFocus) return;
        unawaited(
            SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      })
      ..scheduleFrame();
  }

  /// MD3 large 档 = M3 SearchBar：56 高、28 圆角全胶囊、surfaceContainerHigh
  /// 填充、无描边；前置放大镜 24、尾部动作 48 触控区、bodyLarge 正文竖直居中。
  /// 聚焦不画 2px 主色描边（那是文本框的语言，SearchBar 没有），改用状态层：
  /// 悬停 8% / 聚焦 10% onSurface 叠在填充上，键盘焦点照样看得见。
  /// 墨水屏：无填充、1px onSurface 实线描边（聚焦 2px），不靠灰阶状态层。
  Widget _buildMd3Large(BuildContext context, TextEditingValue value) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final List<Widget> trailing = _trailing(context, value, large: true);
    final BorderRadius radius =
        BorderRadius.circular(kFushiSearchFieldLargeHeight / 2);
    OutlineInputBorder border(BorderSide side) =>
        OutlineInputBorder(borderRadius: radius, borderSide: side);
    final BorderSide resting =
        eink ? BorderSide(color: cs.onSurface) : BorderSide.none;
    final Color base = cs.surfaceContainerHigh;
    final TextStyle text = (theme.textTheme.bodyLarge ?? const TextStyle())
        .copyWith(
      color: cs.onSurface,
      height: 1.25,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return SizedBox(
      height: kFushiSearchFieldLargeHeight,
      child: TextField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        style: text,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          hintStyle: text.copyWith(color: cs.onSurfaceVariant),
          filled: !eink,
          fillColor: eink
              ? null
              : WidgetStateColor.resolveWith((Set<WidgetState> states) {
                  if (states.contains(WidgetState.focused)) {
                    return Color.alphaBlend(
                      cs.onSurface.withValues(alpha: 0.10),
                      base,
                    );
                  }
                  if (states.contains(WidgetState.hovered)) {
                    return Color.alphaBlend(
                      cs.onSurface.withValues(alpha: 0.08),
                      base,
                    );
                  }
                  return base;
                }),
          hoverColor: Colors.transparent,
          border: border(resting),
          enabledBorder: border(resting),
          focusedBorder: border(
            eink ? BorderSide(color: cs.onSurface, width: 2) : BorderSide.none,
          ),
          prefixIcon: leading == null
              ? const Padding(
                  padding: EdgeInsetsDirectional.only(start: 16, end: 12),
                  child: FushiIcon(
                    Icons.search,
                    size: kFushiSearchFieldLargeIconSize,
                  ),
                )
              : Padding(
                  // 48 触控的 leading 钮：4 + 48 + 4，与尾部动作对称。
                  padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
                  child: FushiSearchLeading(child: leading!),
                ),
          prefixIconColor: cs.onSurfaceVariant,
          // 图标槽给满 56：InputDecorator 的容器高取图标槽与正文的较大者，
          // 只给 48 时容器是 48、贴在 56 盒子顶上，正文比胶囊中线高 4px。
          prefixIconConstraints: const BoxConstraints(
            minHeight: kFushiSearchFieldLargeHeight,
          ),
          suffixIcon: trailing.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsetsDirectional.only(end: 4),
                  child:
                      Row(mainAxisSize: MainAxisSize.min, children: trailing),
                ),
          suffixIconColor: cs.onSurfaceVariant,
          suffixIconConstraints: const BoxConstraints(
            minHeight: kFushiSearchFieldLargeHeight,
          ),
          contentPadding: const EdgeInsetsDirectional.only(end: 16),
        ),
        textInputAction: TextInputAction.search,
        onEditingComplete: _finishSubmit,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget searchBar;
    if (isGlassDesign(context)) {
      // Apple 设计系统：内容层的搜索框是 systemFill 实色胶囊（UISearchBar 的
      // searchTextField，高 36），不是玻璃——玻璃只给浮在内容上的导航层。
      // 走 FushiTextFieldControl 的 Apple 分支（前缀放大镜 → 胶囊形态），与
      // 其它 Apple 输入框同一实现。fieldKey / 清除键 key / 焦点节点与 MD3 分支
      // 同一套；提交收尾与 MD3 一致（onEditingComplete 不交焦点）；物理回车的
      // 提交兜底在下面的 Focus 层，两条分支共用。
      searchBar = ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final List<Widget> trailing = _trailing(context, value);
          // 用户 2026-10-04「所有组件都要往液态玻璃靠」：搜索框是 iOS 26 的
          // 玻璃搜索胶囊。胶囊形态（玻璃 bezel、深色下的静止底与细描边、
          // 聚焦内环、降低透明度时回落实色）全由 FushiTextFieldControl 认出
          // 前缀放大镜后给出，与库页搜索框同一实现——以前这里外包一层自己的
          // GlassContainer、再把输入框填充压成近乎透明，聚焦光圈的 BoxShadow
          // 会透过那层填充把整枚胶囊染成灰 / 白块。large 档在 Apple 下同为
          // 36 的 iOS 搜索胶囊（Apple 没有 56 的搜索栏）。
          return FushiTextFieldControl(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            decoration: InputDecoration(
              hintText: hintText,
              prefixIcon: leading == null
                  ? const FushiIcon(
                      Icons.search,
                      size: kFushiSearchFieldIconSize,
                    )
                  : FushiSearchLeading(child: leading!),
              suffixIcon: trailing.isEmpty
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: trailing),
            ),
            textInputAction: TextInputAction.search,
            onEditingComplete: _finishSubmit,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          );
        },
      );
    } else if (isMacosPlatform(context)) {
      // macOS-native: MacosTextField maps the search field faithfully —
      // search-icon prefix, native clear button (clearButtonMode), and it keeps
      // onSubmitted (MacosSearchField drops it, which would break enter-to-search).
      searchBar = MacosTextField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        placeholder: hintText,
        prefix: Padding(
          padding: const EdgeInsets.only(left: 6, right: 2),
          child: leading ?? const MacosIcon(CupertinoIcons.search),
        ),
        clearButtonMode: OverlayVisibilityMode.editing,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      );
    } else {
      searchBar = ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          if (size == FushiSearchFieldSize.large) {
            return _buildMd3Large(context, value);
          }
          final List<Widget> trailing = _trailing(context, value);
          // MD3（2026-10-04 输入框统一）：与库页搜索同一枚填充胶囊——
          // fushiMd3FieldDecoration 认出前缀放大镜后给全圆角、surfaceContainerHigh
          // 填充、静止无描边、聚焦 2px 主色（墨水屏保留描边）。内边距收回 40 高
          // 的工具条尺度（helper 的搜索默认内边距是给更高的独立搜索框的）。
          final InputDecoration decoration = fushiMd3FieldDecoration(
            context,
            InputDecoration(
              isDense: true,
              hintText: hintText,
              // 占位符与正文同字号、只换颜色（M3 规格；与 BUG-2973 对
              // FushiTextField 的修法同一口径）：小一号的占位符在竖直居中的
              // 单行里按基线对齐，会比正文偏下。
              hintStyle: tokens.type.listTitle.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              prefixIcon: leading == null
                  ? const FushiIcon(
                      Icons.search,
                      size: kFushiSearchFieldIconSize,
                    )
                  : FushiSearchLeading(child: leading!),
              suffixIcon: trailing.isEmpty
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: trailing,
                    ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
          )!
              .copyWith(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 4,
            ),
          );
          return SizedBox(
            height: kFushiSearchFieldHeight,
            child: TextField(
              key: fieldKey,
              controller: controller,
              focusNode: focusNode,
              style: tokens.type.listTitle,
              textAlignVertical: TextAlignVertical.center,
              decoration: decoration,
              // 搜索框的提交动作必须显式声明：不声明时软键盘/IME 给的是
              // 「完成」，而 `TextInputAction.done` 的默认收尾是 unfocus——焦点
              // 一掉，[FushiFocusRoot] 的修复链又会把它以编程方式还回来，桌面端
              // 的 EditableText 对非点击获得的焦点整段选中，于是按下回车的观感
              // 就是「文字被全选、什么也没搜」（BUG-2620）。
              textInputAction: TextInputAction.search,
              // 给了 onEditingComplete 就不会走默认的 unfocus 收尾，焦点留在
              // 框里；onSubmitted 仍照常触发。composing 要自己清，移动端的软
              // 键盘也要自己收（见 [_finishSubmit]）。
              onEditingComplete: _finishSubmit,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
            ),
          );
        },
      );
    }
    // 物理回车的兜底：提交动作本该由平台 text-input 桥转成 onSubmitted，但那条
    // 路要穿过 engine 的输入插件，桌面端一旦没走到，按回车就是「什么也没发生」，
    // 用户只能靠改动输入再等防抖才搜得出来（BUG-2620）。键事件这一层是确定性的，
    // 直接在这里认领裸回车并调 onSubmitted，handled 同时挡住重复提交。
    //
    // 两种情况必须放行：带修饰键的回车（不是提交语义），以及 IME 组字期间的回车
    // ——那一下是确认候选词，抢走它等于日文/中文输入法在搜索框里没法选词。
    final Widget submittable = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) {
          return KeyEventResult.ignored;
        }
        if (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        if (!focusNode.hasFocus) return KeyEventResult.ignored;
        if (controller.value.composing.isValid) return KeyEventResult.ignored;
        onSubmitted(controller.text);
        // 有的移动端输入法把「搜索」键发成回车键事件而不是 editor action，
        // 走到这里的提交同样要收键盘。
        _finishSubmit();
        return KeyEventResult.handled;
      },
      child: searchBar,
    );
    if (focusId == null) return submittable;
    if (FushiFocusRoot.maybeControllerOf(context) == null) return submittable;
    return FushiFocusRegistration(
      id: focusId!,
      focusNode: focusNode,
      child: submittable,
    );
  }
}

/// 搜索框统一形态（2026-09，2026-10-04 改填充胶囊）：与三大媒体库页（书架 / 视频库 /
/// 游戏库）的工具条搜索框对齐——MD3 固定 40 高、填充全胶囊（静止无描边）、18px
/// 图标 + `isDense`；Apple 是高 36 的 systemFill 实色胶囊。
/// 此前 [FushiSearchField] 用的是 MD3 搜索条形态（高填充容器色、圆角 12、高约 56），
/// 导致同一导航里「发现」页与「全部视频」页两种外观，且比同行的筛选按钮更高。
///
/// 常量定义放在类之后：`md3_design_system_static_test` 用 `class FushiSearchField`
/// 这个字面量当上一段切片的终点，插在类前会把这段注释卷进它的扫描面。
const double kFushiSearchFieldHeight = 40;

/// [FushiSearchField] 的尺寸档，见 [FushiSearchField.size]。
enum FushiSearchFieldSize { regular, large }

/// MD3 large 档（M3 SearchBar）的高度；Apple 下 large 仍是 36 的 iOS 搜索胶囊。
const double kFushiSearchFieldLargeHeight = 56;

/// MD3 large 档的前置 / 尾部图标尺寸（M3 SearchBar 24dp）。
const double kFushiSearchFieldLargeIconSize = 24;

/// 搜索框内前缀/后缀图标尺寸。[FushiIconButton] 默认 24px 图标 + `spacing.gap` 内边距
/// 合计约 40 高，正好撑破 [kFushiSearchFieldHeight] 的内容区，故 trailing 按钮必须同时
/// 收窄 size 与 padding。
const double kFushiSearchFieldIconSize = 18;

class FushiTextField extends StatefulWidget {
  const FushiTextField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.hintText,
    this.labelText,
    this.suffixText,
    this.keyboardType = TextInputType.text,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.suffixIcon,
    this.prefixIcon,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.textAlignVertical,
    this.style,
    this.contentPadding,
    this.focusId,
    this.variant = FushiTextFieldVariant.filled,
    this.size,
    this.helperText,
    this.errorText,
    this.maxLength,
    this.enabled,
    this.clearable = false,
    this.onClear,
    this.showObscureToggle = true,
    this.inputFormatters,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool readOnly;
  final bool obscureText;
  final String? hintText;
  final String? labelText;
  final String? suffixText;
  final TextInputType keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffixIcon;
  final Widget? prefixIcon;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final TextStyle? style;
  final EdgeInsetsGeometry? contentPadding;
  final FushiFocusId? focusId;

  /// M3E 文本框两类：filled（默认，填充底、静止无描边）/ outlined（透明底 +
  /// 1px outline 描边，标题骑在描边线上）。Apple 设计系统只有一种实色输入框，
  /// 两类同形。
  final FushiTextFieldVariant variant;

  /// 尺寸档（单行最小高度 40 / 48 / 56）；为空时按内容自然高度（历史行为）。
  final FushiInputSize? size;

  /// 帮助文本 / 错误文本（错误优先，错误态描边换 error 色）。
  final String? helperText;
  final String? errorText;

  /// 最大字数；给了就在右下角显示计数。
  final int? maxLength;
  final bool? enabled;

  /// 有内容时在尾部给清空钮（需要 [controller]）。清空后调 [onChanged] 与
  /// [onClear]。
  final bool clearable;
  final VoidCallback? onClear;

  /// [obscureText] 为真时在尾部给显隐切换钮（M3E 密码框）。
  final bool showObscureToggle;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<FushiTextField> createState() => _FushiTextFieldState();
}

class _FushiTextFieldState extends State<FushiTextField> {
  late final FocusNode _ownedFocusNode = FocusNode(
    debugLabel: widget.hintText ?? widget.labelText ?? 'hibiki-text-field',
  );

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _ownedFocusNode;

  /// 密码显隐：true = 遮挡（初值跟 [FushiTextField.obscureText]）。
  late bool _obscured = widget.obscureText;

  @override
  void didUpdateWidget(FushiTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obscureText != widget.obscureText) {
      _obscured = widget.obscureText;
    }
  }

  @override
  void dispose() {
    _ownedFocusNode.dispose();
    super.dispose();
  }

  /// 尾部动作：调用方给的 suffixIcon 优先；否则 清空钮 / 密码显隐 / 输入辅助
  /// （软键盘 / 粘贴）按需排成一行。
  Widget? _buildSuffix(BuildContext context) {
    if (widget.suffixIcon != null) return widget.suffixIcon;
    final TextEditingController? controller = widget.controller;
    final bool editable = !widget.readOnly && (widget.enabled ?? true);
    // 尺寸档下尾部钮收成紧凑尺寸（20 + 6 = 32），否则 48 的标准触控区会把
    // small（40）档撑高。
    final bool compact = widget.size != null;
    final double? iconSize = compact ? 20 : null;
    final EdgeInsets? padding = compact ? const EdgeInsets.all(6) : null;
    final Widget? assist = _hibikiTextFieldInputSuffix(
      context: context,
      controller: editable ? controller : null,
      onChanged: widget.onChanged,
      iconSize: iconSize,
      padding: padding,
    );
    final bool toggle = widget.obscureText && widget.showObscureToggle;
    final bool clear = widget.clearable && editable && controller != null;
    if (!toggle && !clear) return assist;
    Widget row(bool hasText) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (clear && hasText)
              FushiIconButton(
                icon: Icons.cancel_outlined,
                tooltip: t.clear,
                size: iconSize,
                padding: padding,
                onTap: () {
                  controller.clear();
                  widget.onChanged?.call('');
                  widget.onClear?.call();
                },
              ),
            if (toggle)
              FushiIconButton(
                icon: _obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                tooltip: _obscured
                    ? t.text_field_password_show
                    : t.text_field_password_hide,
                size: iconSize,
                padding: padding,
                onTap: () => setState(() => _obscured = !_obscured),
              ),
            if (assist != null) assist,
          ],
        );
    if (!clear) return row(false);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? _) =>
          row(value.text.isNotEmpty),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool glass = isGlassDesign(context);
    final Widget? effectiveSuffix = _buildSuffix(context);
    final FushiInputSize? size = widget.size;
    final bool singleLine = !widget.expands && (widget.maxLines ?? 2) == 1;
    final TextStyle? style = widget.style ?? (glass ? null : tokens.type.listTitle);
    // 尺寸档的单行：竖直内边距 = (档高 − 行高) / 2，正文与占位符（同字号，
    // BUG-2973）恰好居中。InputDecoration.constraints 的最小高度只会把多出来
    // 的高度加在正文下方，不能用它居中。
    double? sizedVertical;
    if (size != null && singleLine && !glass) {
      final ThemeData theme = Theme.of(context);
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: 'Hg',
          style: (theme.textTheme.bodyLarge ?? const TextStyle()).merge(style),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      sizedVertical = math.max(
        0,
        (fushiInputSizeHeight(size) - painter.height) / 2,
      );
      painter.dispose();
    }
    // 2026-10-04 输入框统一：两套设计系统都走 FushiTextFormFieldControl。
    // - MD3：经 fushiMd3FieldDecoration 得到 surfaceContainerHigh 柔和填充、
    //   圆角 12、静止无描边、聚焦 2px 主色（以前这里自带常驻灰描边方框）；
    // - Apple：内容层的实色输入框（tertiaryFill、圆角 10、标签在框上方），
    //   不再是液态玻璃 GlassTextField；字号 / 占位色交给 Apple 默认，所以
    //   token 字体只在 MD3 下给。
    // 两条路都是 TextFormField 语义（initialValue / Form 校验照旧）。
    final Widget textField = FushiTextFormFieldControl(
      controller: widget.controller,
      initialValue: widget.initialValue,
      focusNode: _effectiveFocusNode,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText && _obscured,
      enabled: widget.enabled,
      maxLength: widget.maxLength,
      inputFormatters: widget.inputFormatters,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      maxLines: widget.expands ? null : widget.maxLines,
      minLines: widget.minLines,
      expands: widget.expands,
      textAlignVertical: widget.textAlignVertical ??
          (size != null && singleLine ? TextAlignVertical.center : null),
      style: style,
      decoration: InputDecoration(
        hintText: widget.hintText,
        labelText: widget.labelText,
        suffixText: widget.suffixText,
        helperText: widget.helperText,
        errorText: widget.errorText,
        border: widget.variant == FushiTextFieldVariant.outlined
            ? const FushiOutlinedFieldBorder()
            : null,
        // 尺寸档：单行给最小高度（文字由 textAlignVertical 居中），多行只给
        // 下限，仍随内容长高（自适应高度）。
        // 尺寸档走 dense 布局：非 dense 的 InputDecorator 自带 48 的最小
        // 交互高度，small 档会被撑到 48。
        isDense: size != null ? true : null,
        constraints: size == null
            ? null
            : BoxConstraints(minHeight: fushiInputSizeHeight(size)),
        // 图标槽给满档高：InputDecorator 的容器高取图标槽与正文的较大者，
        // 槽比档高矮时容器贴在盒子顶上，正文偏离中线（同 FushiSearchField
        // large 档的处理）。
        suffixIconConstraints: size == null || !singleLine
            ? null
            : BoxConstraints(
                minWidth: 40,
                minHeight: fushiInputSizeHeight(size),
              ),
        prefixIconConstraints: size == null || !singleLine
            ? null
            : BoxConstraints(
                minWidth: 40,
                minHeight: fushiInputSizeHeight(size),
              ),
        // 占位符与正文同一字号 / 行高（M3 规格：placeholder 只换颜色）。
        // BUG-2973：此前用更小的 listSubtitle，InputDecorator 把占位符的首行
        // 基线对齐到正文首行基线，两种行高的 ascent 差让占位符整体下沉——
        // 多行占位符在框里偏下 5px、下边距只剩上边距的一半。
        hintStyle: glass
            ? null
            : (widget.style ?? tokens.type.listTitle).copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        labelStyle: glass ? null : tokens.type.metadata,
        floatingLabelStyle: glass ? null : tokens.type.sectionLabel,
        contentPadding: widget.contentPadding ??
            (glass
                ? null
                : EdgeInsets.symmetric(
                    horizontal: tokens.spacing.rowHorizontal,
                    vertical: sizedVertical ?? tokens.spacing.rowVertical,
                  )),
        suffixIcon: effectiveSuffix,
        prefixIcon: widget.prefixIcon,
      ),
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
    );
    if (widget.focusId == null) return textField;
    if (FushiFocusRoot.maybeControllerOf(context) == null) return textField;
    return FushiFocusRegistration(
      id: widget.focusId!,
      focusNode: _effectiveFocusNode,
      child: textField,
    );
  }
}

/// [FushiTextField] 的 M3E 两类：filled（填充底）/ outlined（描边）。
enum FushiTextFieldVariant { filled, outlined }

/// 输入框尺寸档（单行最小高度）：small 40 / medium 48 / large 56（M3 文本框
/// 默认 56；工具条 / 对话框里的紧凑输入用 40 / 48）。
enum FushiInputSize { small, medium, large }

/// [FushiInputSize] 的单行最小高度。
double fushiInputSizeHeight(FushiInputSize size) => switch (size) {
  FushiInputSize.small => 40,
  FushiInputSize.medium => 48,
  FushiInputSize.large => 56,
};

/// The input-assist suffix icon for a text field. On desktop (no system IME) it
/// opens the on-screen [showGamepadKeyboard]; on mobile it offers one-tap
/// clipboard paste (the system IME types, but paste otherwise needs a
/// long-press). [onChanged] is forwarded so a programmatic edit (on-screen
/// keyboard input or paste) still updates reactive fields — Flutter does not
/// fire `onChanged` on programmatic controller mutations.
/// [iconSize] / [padding] 为空时保持 [FushiIconButton] 的默认尺寸（[FushiTextField]
/// 等常规输入框沿用原样）；[FushiSearchField] 传紧凑值，否则默认按钮会撑破 40 高的
/// 搜索框内容区。
Widget? _hibikiTextFieldInputSuffix({
  required BuildContext context,
  required TextEditingController? controller,
  ValueChanged<String>? onChanged,
  double? iconSize,
  EdgeInsets? padding,
}) {
  if (controller == null) return null;
  final TargetPlatform platform = Theme.of(context).platform;
  final bool isDesktop = platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux ||
      platform == TargetPlatform.macOS;
  if (isDesktop) {
    return FushiIconButton(
      icon: Icons.keyboard_outlined,
      tooltip: t.on_screen_keyboard,
      size: iconSize,
      padding: padding,
      onTap: () =>
          showGamepadKeyboard(context, controller, onChanged: onChanged),
    );
  }
  return FushiIconButton(
    icon: Icons.content_paste_outlined,
    tooltip: t.paste,
    size: iconSize,
    padding: padding,
    onTap: () async {
      if (await gamepadKeyboardPaste(controller)) {
        onChanged?.call(controller.text);
      }
    },
  );
}

class FushiSelectableChip extends StatelessWidget {
  const FushiSelectableChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
    this.avatar,
    this.leadingIcon,
    this.tooltip,
    this.focusId,
    this.allowLabelOverflow = false,
    this.iconOnly = false,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? avatar;
  final IconData? leadingIcon;
  final String? tooltip;
  final FushiFocusId? focusId;

  /// 仅图标模式（TODO-640）：置 true 时 chip 只渲染 [leadingIcon]、不显示文字标签，
  /// 把横排「图标 + 文字」压成紧凑「纯图标」（解决顶栏挤不下 / 显示不全）。文字说明
  /// 通过 hover / 长按 [Tooltip] 呈现：未显式传 [tooltip] 时回退用 [label] 作 tooltip，
  /// 保证图标语义可读。需要 [leadingIcon] 非空（否则退化为普通文字 chip）。

  /// 默认 false：标签单行 + 省略号（标签筛选条等密集横排，宽度受限时优先省略）。
  /// 置 true：标签不省略、按固有宽度完整渲染（横滑分类条等空间充裕、标签必须可读的
  /// 场景，如视频设置顶部分类条 TODO-556）。Material [ChoiceChip] 给 label 的约束
  /// 上界由 chip 自身布局推导（即便在横向无界滚动里也是有限值），故单纯靠无界宽度无法
  /// 避免省略；改 [Text.overflow] 为 visible + softWrap:false 才能让 chip 随固有宽度撑开。
  final bool allowLabelOverflow;

  /// 见构造器：仅图标模式（TODO-640），需 [leadingIcon] 非空才生效。
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    // E-ink：容器色双双塌缩到页面底色/前景，于是选中态既没有填充差异、边框还
    // 变成了底色——选中的 chip 比未选中的更没有边，是个负信号。反色填充是墨水
    // 屏上唯一稳定可辨的选中通道（与 segmentedButtonTheme / chipTheme 的处理
    // 同源）。
    // MD3（2026-10-04 chip 统一）：全胶囊、未选中 surfaceContainerHigh 柔和填充
    // 无描边，选中 secondaryContainer + 对勾（MD3 filter chip），与全胶囊按钮、
    // 填充输入框同一语言。
    final Color selectedFill =
        eink ? colors.onSurface : colors.secondaryContainer;
    final Color foreground = selected
        ? (eink ? colors.surface : colors.onSecondaryContainer)
        : tokens.surfaces.onSurface;
    // 仅图标模式（TODO-640）：图标当作 chip 的 label（不再放进 avatar + 文字），
    // chip 收成正方裸图标；需 leadingIcon 非空才生效，否则退化为普通文字 chip。
    final bool effectiveIconOnly = iconOnly && leadingIcon != null;
    final Widget? effectiveAvatar = effectiveIconOnly
        ? null
        : (avatar ??
            (leadingIcon == null
                ? null
                : FushiIcon(leadingIcon, size: 18, color: foreground)));
    final Widget labelWidget = effectiveIconOnly
        ? FushiIcon(leadingIcon, size: 18, color: foreground)
        : Text(
            label,
            maxLines: 1,
            softWrap: !allowLabelOverflow,
            overflow: allowLabelOverflow
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          );
    if (isGlassDesign(context)) {
      // Apple 设计系统：chip 是液态玻璃胶囊——未选中透明玻璃 + label 字，选中
      // 强调色着色玻璃 + 反色字（降低透明度时回落实色），与 FushiChoiceChip
      // 同一枚（fushiAppleChip）。外层已由 FushiFocusTarget 接管焦点时 chip 不再自带
      // 焦点节点。tooltip 规则与 MD3 分支相同。
      final bool wrapped =
          focusId != null && FushiFocusRoot.maybeControllerOf(context) != null;
      final Widget appleChip = fushiAppleChip(
        context,
        label: effectiveIconOnly
            ? FushiIcon(leadingIcon, size: 16)
            : Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        avatar: effectiveIconOnly
            ? null
            : (avatar ?? (leadingIcon == null ? null : FushiIcon(leadingIcon))),
        selected: selected,
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        tooltip: tooltip ?? (effectiveIconOnly ? label : null),
        focusable: !wrapped,
      );
      return _wrapChipFocus(
        context,
        Semantics(selected: selected, child: appleChip),
      );
    }
    final ChoiceChip chip = ChoiceChip(
      avatar: effectiveAvatar,
      label: labelWidget,
      // 仅图标模式下 label 是 Icon，去掉 ChoiceChip 默认 label padding 让图标居中收紧。
      labelPadding: effectiveIconOnly ? EdgeInsets.zero : null,
      selected: selected,
      // MD3 filter chip 的选中信号是对勾；仅图标模式没有位置放它。
      showCheckmark: !effectiveIconOnly,
      checkmarkColor: foreground,
      selectedColor: selectedFill,
      backgroundColor: eink ? Colors.transparent : colors.surfaceContainerHigh,
      labelStyle: tokens.type.controlLabel.copyWith(color: foreground),
      side: eink
          ? BorderSide(
              color: selected ? colors.outline : colors.outlineVariant,
            )
          : BorderSide.none,
      shape: const StadiumBorder(),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: onSelected,
    );
    // 仅图标模式默认用 label 作 tooltip（图标语义靠 hover / 长按文字说明），
    // 显式 tooltip 优先。普通模式仍按传入 tooltip（null 则不包 Tooltip）。
    final String? effectiveTooltip =
        tooltip ?? (effectiveIconOnly ? label : null);
    final Widget withTooltip = effectiveTooltip == null
        ? chip
        : Tooltip(message: effectiveTooltip, child: chip);
    return _wrapChipFocus(context, withTooltip);
  }

  Widget _wrapChipFocus(BuildContext context, Widget withTooltip) {
    if (focusId == null) return withTooltip;
    if (FushiFocusRoot.maybeControllerOf(context) == null) return withTooltip;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onSelected?.call(!selected);
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: focusId!,
        enabled: onSelected != null,
        child: withTooltip,
      ),
    );
  }
}

class FushiActionChip extends StatelessWidget {
  const FushiActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
    this.focusId,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (isGlassDesign(context)) {
      // Apple：与 FushiSelectableChip 同一枚玻璃胶囊（fushiAppleChip），图标单色
      // 强调色——动作 chip 的「可点」信号落在图标上，不靠彩色底。
      final bool wrapped =
          focusId != null && FushiFocusRoot.maybeControllerOf(context) != null;
      return _wrapFocus(
        context,
        fushiAppleChip(
          context,
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          avatar: FushiIcon(icon),
          iconTheme: IconThemeData(color: appleColorsOf(context).accent),
          onTap: onPressed,
          focusable: !wrapped,
        ),
      );
    }
    final bool eink = isEinkTheme(context);
    // MD3（2026-10-04 chip 统一）：tonal 胶囊——surfaceContainerHigh 填充、无
    // 描边、高 32，与 FushiSelectableChip 未选中态同一观感；墨水屏填充是抖动
    // 灰，保留描边。
    final OutlinedButton button = OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.primary,
        backgroundColor: eink ? null : colors.surfaceContainerHigh,
        side: eink ? BorderSide(color: colors.outlineVariant) : BorderSide.none,
        shape: const StadiumBorder(),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: FushiIcon(icon, size: 18),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.controlLabel,
      ),
    );
    return _wrapFocus(context, button);
  }

  Widget _wrapFocus(BuildContext context, Widget button) {
    if (focusId == null) return button;
    if (FushiFocusRoot.maybeControllerOf(context) == null) return button;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: focusId!,
        child: button,
      ),
    );
  }
}

enum FushiTagChipTone { filled, surface }

class FushiTagChip extends StatefulWidget {
  const FushiTagChip({
    required this.label,
    super.key,
    this.color,
    this.selected = false,
    this.dimmed = false,
    this.tone = FushiTagChipTone.filled,
    this.onTap,
    this.onDeleted,
    this.focusId,
    this.status,
  });

  final String label;
  final Color? color;
  final bool selected;
  final bool dimmed;
  final FushiTagChipTone tone;

  /// 语义状态（成功 / 警告 / 错误）：色相取 [fushiStatusColor]（MD3 harmonize
  /// 绿 / 橙 + error、Apple 系统色、墨水屏 onSurface）。设了就覆盖 [color] /
  /// [tone] 的配色：MD3 状态色 14% 淡底 + 状态色字，Apple 纯展示标签同样淡底 +
  /// 状态色字、可交互标签只在前置圆点上体现，墨水屏页面底 + 描边。
  final FushiStatusTone? status;
  final VoidCallback? onTap;
  final VoidCallback? onDeleted;
  final FushiFocusId? focusId;

  @override
  State<FushiTagChip> createState() => _FushiTagChipState();
}

class _FushiTagChipState extends State<FushiTagChip> {
  /// Stable derived id so a tappable chip is a gamepad/keyboard focus target by
  /// default — Stateful (not Stateless) so identityHashCode is stable across
  /// rebuilds. Mirrors FushiCard / FushiListItem.
  late final FushiFocusId _fallbackFocusId =
      FushiFocusId('hibiki-tag-chip-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    // eink：这里的每一档 alpha（0.44 / 0.88 / 0.2 / 0.12 / 0.4）在墨水屏上都是
    // 抖动灰，而 overlay 底又塌成页面底色——未选中的 surface chip 整个消失。
    // 一律实心：selected 反色（chipTheme 同款），未选中页面底色 + 描边，dimmed
    // 只保留文字不加透明。
    final bool eink = isEinkTheme(context);
    final Color tagColor = widget.color ?? colors.primary;
    if (isGlassDesign(context)) {
      return _wrapFocus(context, _buildGlass(context));
    }
    final Color baseColor = widget.color ??
        (widget.selected ? colors.primaryContainer : tokens.surfaces.overlay);
    final Color? statusColor = widget.status == null
        ? null
        : fushiStatusColor(context, widget.status!);
    final Color toneBackground = switch (widget.tone) {
      FushiTagChipTone.filled => eink
          ? baseColor
          : widget.dimmed
              ? baseColor.withValues(alpha: 0.44)
              : baseColor.withValues(alpha: widget.color == null ? 1 : 0.88),
      FushiTagChipTone.surface => eink
          ? (widget.selected ? colors.onSurface : colors.surface)
          : widget.selected
              ? tagColor.withValues(alpha: widget.dimmed ? 0.12 : 0.2)
              : tokens.surfaces.search
                  .withValues(alpha: widget.dimmed ? 0.44 : 1),
    };
    final Color background = statusColor == null
        ? toneBackground
        : eink
            ? colors.surface
            : statusColor.withValues(alpha: widget.dimmed ? 0.08 : 0.14);
    final Color toneForeground = switch (widget.tone) {
      FushiTagChipTone.filled => _foregroundFor(toneBackground),
      FushiTagChipTone.surface => eink
          ? (widget.selected ? colors.surface : colors.onSurface)
          : widget.dimmed
              ? colors.onSurface.withValues(alpha: 0.4)
              : colors.onSurface,
    };
    final Color foreground = statusColor == null
        ? toneForeground
        : widget.dimmed && !eink
            ? statusColor.withValues(alpha: 0.6)
            : statusColor;
    final BoxBorder? border = statusColor != null
        ? (widget.selected || eink
            ? Border.all(color: eink ? colors.outline : statusColor)
            : null)
        : widget.selected
            ? Border.all(
                color: widget.tone == FushiTagChipTone.surface
                    ? tagColor
                    : colors.primary,
              )
            : eink && widget.tone == FushiTagChipTone.surface
                ? Border.all(color: colors.outline)
                : null;
    final Text labelText = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: tokens.type.metadata.copyWith(
        color: foreground,
        fontWeight: FontWeight.w500,
      ),
    );
    // 可交互（点选 / 删除）的标签是全胶囊 chip；纯展示标签是圆角 6 的小标签
    // （MD3 小组件圆角），两者一眼分得开（2026-10-04 chip / 标签统一）。
    final BorderRadius radius =
        widget.onTap != null || widget.onDeleted != null
            ? _pillRadius
            : tokens.radii.chipRadius;
    final List<Widget> contentChildren = <Widget>[
      if (statusColor == null &&
          widget.tone == FushiTagChipTone.surface &&
          widget.color != null) ...<Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
          child: const SizedBox(width: 10, height: 10),
        ),
        SizedBox(width: tokens.spacing.gap * 0.625),
      ],
      Flexible(child: labelText),
      if (widget.onDeleted != null) ...<Widget>[
        SizedBox(width: tokens.spacing.gap * 0.375),
        InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onDeleted,
          child: FushiIcon(
            Icons.close,
            size: 14,
            color: foreground,
          ),
        ),
      ],
    ];
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: contentChildren,
    );
    final Widget chip = AnimatedContainer(
      duration: einkSafeDuration(context, fushiMd3StateDuration),
      curve: fushiMd3StateCurve,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: border,
      ),
      child: content,
    );
    final Widget surface = widget.onTap == null
        ? chip
        : Material(
            type: MaterialType.transparency,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: widget.onTap,
              child: chip,
            ),
          );
    return _wrapFocus(context, surface);
  }

  /// MD3 可交互标签的全胶囊（2026-10-04 chip 统一，与胶囊按钮 / 筛选 chip 同一
  /// 语言）。
  static const BorderRadius _pillRadius = BorderRadius.all(
    Radius.circular(999),
  );

  /// Apple 设计系统：可交互标签与 FushiChoiceChip 同一枚液态玻璃胶囊
  /// （fushiAppleChip）：未选中透明玻璃，选中强调色着色玻璃；纯展示标签是
  /// 矮一号的实色灰胶囊。标签色
  /// 只体现在前面那颗圆点上，不再整块着色。纯展示标签不进焦点链；外层已由
  /// FushiFocusTarget 接管焦点时 chip 不再自带焦点节点。
  Widget _buildGlass(BuildContext context) {
    final bool interactive = widget.onTap != null || widget.onDeleted != null;
    final bool wrapped =
        interactive && FushiFocusRoot.maybeControllerOf(context) != null;
    final Color? statusColor = widget.status == null
        ? null
        : fushiStatusColor(context, widget.status!);
    final Color? dotColor = statusColor ?? widget.color;
    final Widget? dot = dotColor == null
        ? null
        : DecoratedBox(
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
            child: const SizedBox(width: 8, height: 8),
          );
    if (!interactive) {
      // 纯展示标签：矮一号的胶囊（高约 22、左右 8、12 号 w500
      // secondaryLabel 字），与可交互 chip 区分开。不铺 systemFill 灰底
      // （用户 2026-10-04「很多地方有底色」：元信息胶囊不是内容卡），只留一圈
      // 发丝分隔线描边；选中换 label 色描边。语义状态标签换成状态色 15% 淡底
      // + 状态色字（iOS 状态徽标），不再加圆点。
      final FushiAppleColors apple = appleColorsOf(context);
      final Widget tag = Container(
        constraints: const BoxConstraints(minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: statusColor?.withValues(alpha: 0.15),
          border: statusColor != null
              ? null
              : Border.all(
                  color: widget.selected ? apple.secondaryLabel : apple.separator,
                  width: 0.8,
                ),
          borderRadius: _pillRadius,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (dot != null && statusColor == null) ...<Widget>[
              SizedBox.square(dimension: 6, child: dot),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (Theme.of(context).textTheme.labelMedium ??
                        const TextStyle())
                    .copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: statusColor ??
                      (widget.selected ? apple.label : apple.secondaryLabel),
                ),
              ),
            ),
          ],
        ),
      );
      return widget.dimmed ? Opacity(opacity: 0.45, child: tag) : tag;
    }
    final Widget chip = fushiAppleChip(
      context,
      label: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      avatar: dot,
      selected: widget.selected,
      onTap: widget.onTap,
      onDeleted: widget.onDeleted,
      focusable: !wrapped,
    );
    // dimmed 是「这条标签当前不参与筛选」：整枚减淡，形状与颜色不变。
    return widget.dimmed ? Opacity(opacity: 0.45, child: chip) : chip;
  }

  Widget _wrapFocus(BuildContext context, Widget surface) {
    if (widget.onTap == null && widget.onDeleted == null) return surface;
    // Outside a FushiFocusRoot stay a bare tappable chip (zero overhead).
    if (FushiFocusRoot.maybeControllerOf(context) == null) return surface;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) {
            if (intent.button != GamepadButton.x || widget.onDeleted == null) {
              return false;
            }
            widget.onDeleted!();
            return true;
          },
        ),
      },
      child: FushiFocusTarget(
        id: widget.focusId ?? _fallbackFocusId,
        child: surface,
      ),
    );
  }

  static Color _foregroundFor(Color background) {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black;
  }
}

class FushiBadge extends StatelessWidget {
  const FushiBadge({
    required this.icon,
    super.key,
    this.background,
    this.foreground,
    this.size = 14,
    this.padding,
  });

  final IconData icon;
  final Color? background;
  final Color? foreground;
  final double size;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (isGlassDesign(context)) {
      // Apple：内容层的实色小徽章（tertiaryFill 灰底、同尺寸同圆角），图标单色
      // secondaryLabel——不是着色玻璃，也不是彩色底块。调用方显式给的底色 /
      // 前景色照用。
      final FushiAppleColors apple = appleColorsOf(context);
      return Container(
        padding: padding ?? EdgeInsets.all(tokens.spacing.gap / 2),
        decoration: BoxDecoration(
          // Apple 默认不垫 systemFill 底（SF Symbol 单色直接上屏）。
          color: background ?? Colors.transparent,
          borderRadius: tokens.radii.chipRadius,
        ),
        child: FushiIcon(
          icon,
          size: size,
          color: foreground ?? apple.secondaryLabel,
        ),
      );
    }
    return Container(
      padding: padding ?? EdgeInsets.all(tokens.spacing.gap / 2),
      decoration: BoxDecoration(
        color: background ?? colors.primaryContainer,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: FushiIcon(
        icon,
        size: size,
        color: foreground ?? colors.onPrimaryContainer,
      ),
    );
  }
}

/// 窗口高度低于此值时 MD3 对话框头部收紧（见 [FushiModalSheetFrame]）。
const double _kMd3DialogHeaderCompactHeight = 480;

class FushiModalSheetFrame extends StatelessWidget {
  const FushiModalSheetFrame({
    required this.body,
    super.key,
    this.title,
    this.subtitle,
    this.leadingIcon,
    this.footer,
    this.maxHeightFactor,
    this.bodyPadding,
    this.footerPadding,
    this.scrollable = false,
  });

  final Widget body;
  final String? title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Widget? footer;
  final double? maxHeightFactor;
  final EdgeInsetsGeometry? bodyPadding;
  final EdgeInsetsGeometry? footerPadding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool glassDesign = isGlassDesign(context);
    // 放在对话框面板里（FushiDialogFrame 包了 [FushiDialogScope]）时按对话框
    // 规范排：底部动作区不再压分隔线；底部区包 [FushiDialogActionScope]，
    // Apple 下取消类文字按钮画成系统灰胶囊。作底部 sheet 用时维持原样。
    final bool inDialog = FushiDialogScope.of(context);
    // Apple 不画 leadingIcon、MD3 对话框里没标题时也不画，只剩图标时就没有头部。
    final bool hasHeader = (glassDesign || inDialog)
        ? (title != null || subtitle != null)
        : _hasHeader;
    final List<Widget> children = <Widget>[
      if (hasHeader) _buildHeader(context, tokens, colors),
      _buildBody(tokens),
      if (footer != null) ...<Widget>[
        // 弹层统一（2026-10-04）：MD3 sheet 底部动作区不压分隔线（墨水屏保留，
        // 它靠线分区），四周 24、动作靠右（MD3 规范）；Apple 维持细分隔线。
        if (inDialog || (!glassDesign && !isEinkTheme(context)))
          const SizedBox.shrink()
        else if (glassDesign)
          const FushiDividerControl(height: 1)
        else
          Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
        Padding(
          padding: footerPadding ??
              (inDialog || glassDesign
                  ? EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      0,
                      tokens.spacing.page,
                      tokens.spacing.page,
                    )
                  : const EdgeInsets.fromLTRB(24, 16, 24, 24)),
          child: FushiDialogActionScope(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: footer!,
            ),
          ),
        ),
      ],
    ];

    final Widget sheet = SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
    final double? heightFactor = maxHeightFactor;
    if (heightFactor == null) return sheet;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * heightFactor,
      ),
      child: sheet,
    );
  }

  bool get _hasHeader =>
      title != null || subtitle != null || leadingIcon != null;

  Widget _buildHeader(
    BuildContext context,
    FushiDesignTokens tokens,
    ColorScheme colors,
  ) {
    if (isGlassDesign(context)) return _buildAppleHeader(context, tokens);
    final bool inDialog = FushiDialogScope.of(context);
    if (inDialog) return _buildMd3DialogHeader(context, tokens, colors);
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null)
          Text(
            title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listTitle.copyWith(fontWeight: FontWeight.w600),
          ),
        if (subtitle != null)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
            child: Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listSubtitle,
            ),
          ),
      ],
    );

    // MD3 sheet 头部左右 24（2026-10-04 弹层统一，MD3 规范内边距）；顶部已有
    // 拖动条的 48 交互区，不再叠 24。
    return Padding(
      padding: EdgeInsets.fromLTRB(24, tokens.spacing.gap, 24, tokens.spacing.gap),
      child: Row(
        children: <Widget>[
          // 2026-10-04：去掉 primaryContainer 彩色底块——几乎所有弹层头部都顶着
          // 一枚彩色方块，用户点名嫌丑。MD3 的 sheet 头部图标是无底单色
          // （onSurfaceVariant），只做标题前的语义提示。
          if (leadingIcon != null) ...<Widget>[
            FushiIcon(
              leadingIcon,
              color: colors.onSurfaceVariant,
              size: 20,
            ),
            SizedBox(width: tokens.spacing.gap + 4),
          ],
          Expanded(child: text),
        ],
      ),
    );
  }

  /// Apple 头部（macOS 26 sheet）：标题 15 / 17 semibold label 靠左，可选
  /// 一行 13 号 secondaryLabel 说明。[leadingIcon] 不画——左上角的彩色图标
  /// 方块是 MD3 的语汇，Apple 的 sheet 只有文字标题。
  Widget _buildAppleHeader(BuildContext context, FushiDesignTokens tokens) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final TextTheme tt = Theme.of(context).textTheme;
    final double pad = compact ? 20 : 24;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, tokens.spacing.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title != null)
            Text(
              title!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: (tt.titleMedium ?? const TextStyle()).copyWith(
                fontSize: compact ? 15 : 17,
                fontWeight: FontWeight.w600,
                height: 1.3,
                letterSpacing: 0,
                color: apple.label,
              ),
            ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                subtitle!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: (tt.bodySmall ?? const TextStyle()).copyWith(
                  fontSize: 13,
                  height: 1.35,
                  color: apple.secondaryLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// MD3 对话框头部：有图标且有标题时按规范把单色图标（24，secondary，无底
  /// 块）居中放在标题上方、标题随之居中；没有标题时不单独画图标（孤零零的
  /// 图标压在左对齐正文上方只是噪音）。标题 22 w600 onSurface，说明 14
  /// onSurfaceVariant，四周 24。
  Widget _buildMd3DialogHeader(
    BuildContext context,
    FushiDesignTokens tokens,
    ColorScheme colors,
  ) {
    final TextTheme tt = Theme.of(context).textTheme;
    // 矮窗口（桌面小窗 / 横屏手机）里规范头部（24 内边距 + 两行 22 号标题 +
    // 图标）能吃掉近百像素，把正文挤到放不下自身控件而溢出。矮于阈值时收紧
    // 内边距、标题只留一行、不画居中图标，把高度让回正文。
    final bool compactHeight =
        MediaQuery.sizeOf(context).height < _kMd3DialogHeaderCompactHeight;
    final bool hero = !compactHeight && leadingIcon != null && title != null;
    final CrossAxisAlignment align =
        hero ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final TextAlign textAlign = hero ? TextAlign.center : TextAlign.start;
    return Padding(
      padding: compactHeight
          ? const EdgeInsets.fromLTRB(24, 16, 24, 8)
          : const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Column(
        crossAxisAlignment: align,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (hero) ...<Widget>[
            // M3E：图标 hero 带形状库装饰底（9 瓣饼干 + secondaryContainer）。
            FushiDialogHeroIcon(icon: leadingIcon, size: 56),
            const SizedBox(height: 16),
          ],
          if (title != null)
            Text(
              title!,
              maxLines: compactHeight ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
              style: (tt.headlineSmall ?? const TextStyle()).copyWith(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                height: 1.27,
                color: colors.onSurface,
              ),
            ),
          if (subtitle != null)
            Padding(
              padding: EdgeInsets.only(top: title != null ? 8 : 0),
              child: Text(
                subtitle!,
                maxLines: compactHeight ? 1 : 3,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: (tt.bodyMedium ?? const TextStyle()).copyWith(
                  fontSize: 14,
                  height: 1.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(FushiDesignTokens tokens) {
    final Widget padded = Padding(
      padding: bodyPadding ?? EdgeInsets.zero,
      child: body,
    );
    // The body is always [Flexible] so it is bounded by the sheet's height
    // constraint rather than overflowing the Column. The only difference is who
    // provides the scroll viewport: with [scrollable] the frame wraps it in a
    // SingleChildScrollView; without it the caller supplies its own scroller
    // (ListView/SingleChildScrollView) which then scrolls within the bound.
    // Returning a non-flexible body here let a caller-scroller take its full
    // intrinsic height and overflow on short screens (HBK-AUDIT, switch dialog).
    return Flexible(
      child: scrollable ? SingleChildScrollView(child: padded) : padded,
    );
  }
}

/// 一个可以在窄屏上被折进溢出菜单的 AppBar 动作。
///
/// [label] 既是宽屏 [IconButton] 的 tooltip，也是窄屏菜单项的文案——同一句话，
/// 不需要为「折叠版」另造 i18n key。[onPressed] 为 null 时该项禁用（菜单项同样
/// 置灰），语义与 [IconButton.onPressed] 一致。
class FushiAppBarAction {
  const FushiAppBarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// 窄屏下把次要 AppBar 动作折进「更多」溢出菜单，把宽度让回给标题。
///
/// BUG-1184：合集详情、网格详情、texthooker 这些页面的 AppBar 各挂了 4~5 个动作。
/// Material 的 AppBar 先满足 actions 的固有宽度，再把剩下的给 title——320dp 上
/// 5 个动作 + 返回键就吃掉约 296px，标题只剩二十几像素，合集名/书名彻底看不见
/// （不报错，就是没了）。动作数量本身是合理的，错的是「无论屏多窄都全部平铺」。
///
/// [alwaysVisible] 放最高频、必须一眼可点的动作（如排序）；[collapsible] 里的
/// 在宽屏逐个平铺，窄屏收进一个 [PopupMenuButton]。折叠后动作一个都没少，只是
/// 多一次点击——比标题消失划算得多。
///
/// BUG-1186：判「窄」必须用**这条 AppBar 实际拿到的约束宽**，不是 `MediaQuery`
/// 的整窗宽。页面嵌进分栏 / 受限宽容器 / 对话框时，整窗很宽而本行很窄，按整窗判
/// 定就永远不折叠，标题照样被挤没——与 [FushiToolScaffold] 里 BUG-1184 修掉的
/// 是同一类错误（那边已改用 [LayoutBuilder] 的局部约束）。
///
/// [availableWidth] 故意做成必填、且不提供「取不到就退回整窗宽」的默认值：有默认
/// 值就等于给这个 bug 留了一条随时能走回去的路。调用点把该 AppBar 包进
/// [LayoutBuilder]（或包住整个 [Scaffold]——appBar 与 Scaffold 同宽）后把
/// `constraints.maxWidth` 传进来即可。
///
/// 注意这里比的是**逻辑像素**：动作按钮的固有宽（[IconButton] 48）也是逻辑像素，
/// 「几个按钮塞得下」纯粹是逻辑坐标系里的几何问题，不需要像
/// [windowSizeClassReal] 那样按 UI 缩放还原真实物理宽。
List<Widget> narrowAwareAppBarActions({
  required double availableWidth,
  required List<FushiAppBarAction> collapsible,
  List<Widget> alwaysVisible = const <Widget>[],
  double narrowWidth = 480,
}) {
  final bool narrow = availableWidth.isFinite && availableWidth < narrowWidth;
  if (!narrow || collapsible.length < 2) {
    return <Widget>[
      ...alwaysVisible,
      for (final FushiAppBarAction action in collapsible)
        IconButton(
          tooltip: action.label,
          icon: FushiIcon(action.icon),
          onPressed: action.onPressed,
        ),
    ];
  }
  return <Widget>[
    ...alwaysVisible,
    // 共享菜单路由（M3E 面板 / Apple 菜单），不再裸用 PopupMenuButton。
    FushiPopupMenuButton<int>(
      tooltip: t.common_more_actions,
      icon: const FushiIcon(Icons.more_vert),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        for (int i = 0; i < collapsible.length; i++)
          FushiPopupMenuItem<int>(
            value: i,
            enabled: collapsible[i].onPressed != null,
            icon: collapsible[i].icon,
            label: collapsible[i].label,
          ),
      ],
      onSelected: (int index) => collapsible[index].onPressed?.call(),
    ),
  ];
}

class FushiDialogFrame extends StatelessWidget {
  const FushiDialogFrame({
    required this.child,
    super.key,
    this.maxWidth = 420,
    this.maxHeightFactor = 0.82,
    this.insetPadding,
    this.padding = EdgeInsets.zero,
    this.scrollable = true,
    this.appleLiquidGlass = false,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeightFactor;

  /// Apple 设计系统下面板用真·液态玻璃（厚档 + premium 渲染，见
  /// [FushiAppleDialogPanel.liquidGlass]），而不是默认的近实色面板。只给内容
  /// 本身就是「浮在页面上的预览」、文字不多的对话框（右键详情）用；系统降低
  /// 透明度时自动回落实色。MD3 不受影响。
  final bool appleLiquidGlass;

  /// 对话框与屏幕边缘的留白。null = 按屏宽自适应（见 [_resolveInsetPadding]）。
  ///
  /// BUG-1184：此前默认硬编码 `horizontal: 40`。窄屏上这 80px 是纯损失——320dp 的
  /// 手机上对话框正文只剩 240px，再扣掉 [FushiModalSheetFrame] 的头部内边距和
  /// 52px 的图标徽标，标题只剩约 144px，于是几乎所有对话框标题都被省略成「…」。
  /// 40 这个值只对宽屏合理（且宽屏本来就被 [maxWidth] 420 兜住，边距几乎不起作用），
  /// 真正需要它自适应的恰恰是窄屏。少数已经手动传 `tokens.spacing.card` 绕开该默认
  /// 值的调用点即是佐证——现在默认值自己就做对了，不必每处再记得覆盖。
  final EdgeInsets? insetPadding;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  /// 屏幕越窄，边距越小：320dp 上取 16（与卡片内边距同级），随屏宽线性放大到宽屏
  /// 的 40 为止。用比例而非断点，避免在某个宽度上突然跳变。
  EdgeInsets _resolveInsetPadding(double screenWidth) {
    if (insetPadding != null) return insetPadding!;
    final double horizontal =
        screenWidth.isFinite ? (screenWidth * 0.05).clamp(16.0, 40.0) : 40.0;
    return EdgeInsets.symmetric(horizontal: horizontal, vertical: 24);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Size screenSize = MediaQuery.sizeOf(context);
    final double screenHeight = screenSize.height;
    final Widget padded = Padding(
      padding: padding,
      child: child,
    );
    final Widget body = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        maxHeight: screenHeight * maxHeightFactor,
      ),
      child: scrollable ? SingleChildScrollView(child: padded) : padded,
    );
    if (isGlassDesign(context)) {
      // Apple 设计系统：Dialog 只剩布局职责（insetPadding、键盘避让、语义），
      // 自身完全透明无阴影；表面是 macOS 26 sheet 式的实色面板（圆角 24、
      // 柔和大阴影，见 [FushiAppleDialogPanel]），面板内是菜单式列表选中。
      return Dialog(
        clipBehavior: Clip.none,
        insetPadding: _resolveInsetPadding(screenSize.width),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        child: FushiAppleDialogPanel(
          radius: 24,
          liquidGlass: appleLiquidGlass,
          child: body,
        ),
      );
    }
    // MD3：surfaceContainerHigh 面板（主题给）、圆角 28、无 tint；墨水屏下
    // 补一圈实描边（面板与背景同为白，边是唯一的边界）。毛玻璃：Dialog 自己
    // 的底色与 tint 让位，表面交给 FushiGlassSurface 画。面板内包
    // [FushiDialogScope]，列表行改用圆角选中高亮。
    final bool glass = glassMaterialOf(context) != FushiGlassMaterial.off;
    final bool eink = isEinkTheme(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: _resolveInsetPadding(screenSize.width),
      shape: RoundedRectangleBorder(
        borderRadius: tokens.radii.dialogRadius,
        side: eink
            ? BorderSide(color: Theme.of(context).colorScheme.outline)
            : BorderSide.none,
      ),
      backgroundColor: glass ? Colors.transparent : null,
      surfaceTintColor: Colors.transparent,
      child: FushiDialogScope(
        child: glass
            ? FushiGlassSurface(
                borderRadius: tokens.radii.dialogRadius,
                child: body,
              )
            : body,
      ),
    );
  }
}

enum FushiColorSwatchShape { block, dot }

class FushiColorSwatch extends StatelessWidget {
  const FushiColorSwatch({
    required this.color,
    super.key,
    this.size = 20,
    this.width,
    this.height,
    this.shape = FushiColorSwatchShape.block,
    this.selected = false,
    this.onTap,
    this.label,
    this.textColor,
    this.borderColor,
    this.overlay,
  });

  final Color color;
  final double size;
  final double? width;
  final double? height;
  final FushiColorSwatchShape shape;
  final bool selected;
  final VoidCallback? onTap;
  final String? label;
  final Color? textColor;
  final Color? borderColor;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isDot = shape == FushiColorSwatchShape.dot;
    final double resolvedWidth = width ?? size;
    final double resolvedHeight = height ?? size;
    final BorderRadius inkRadius = isDot
        ? BorderRadius.circular(resolvedHeight / 2)
        : tokens.radii.chipRadius;
    final BorderSide borderSide = BorderSide(
      color: selected ? colors.primary : borderColor ?? colors.outlineVariant,
      width: selected ? 3 : 1,
    );
    final Color foreground = _swatchForegroundFor(color);
    final Widget? swatchOverlay =
        selected ? FushiIcon(Icons.check, color: foreground, size: 20) : overlay;
    final Widget swatch = SizedBox(
      width: resolvedWidth,
      height: resolvedHeight,
      child: AnimatedContainer(
        duration: fushiMd3StateDuration,
        curve: fushiMd3StateCurve,
        decoration: BoxDecoration(
          color: color,
          shape: isDot ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: isDot ? null : tokens.radii.chipRadius,
          border: Border.fromBorderSide(borderSide),
        ),
        child: swatchOverlay == null
            ? null
            : Center(
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 20),
                  child: swatchOverlay,
                ),
              ),
      ),
    );
    return _buildSwatchInteractive(
      context,
      visual: swatch,
      inkRadius: inkRadius,
      selected: selected,
      onTap: onTap,
      label: label,
      textColor: textColor,
    );
  }
}

/// Shared interactive wrapper for swatch widgets: InkWell ripple + a single
/// gamepad/keyboard focus stop + selection semantics + optional caption label.
///
/// [visual] is the bare painted swatch (it owns its own size/shape/border).
/// [inkRadius] clips the ripple. Factored out of [FushiColorSwatch] so
/// [FushiSchemeSwatch] inherits the EXACT focus-stop behaviour: under a
/// [FushiFocusRoot] the directional controller navigates ONLY between
/// registered FushiFocusTargets — a bare InkWell makes its own (unregistered)
/// Focus node, so gamepad/keyboard navigation skips the whole swatch row (the
/// theme picker was unreachable: "到不了主题的位置"). We register each swatch as a
/// single focus stop (A/Enter activates onTap), keeping the InkWell for
/// mouse/touch ripple but barring it from grabbing a competing focus node.
/// Off-root (mobile touch) the InkWell is unchanged.
Widget _buildSwatchInteractive(
  BuildContext context, {
  required Widget visual,
  required BorderRadius inkRadius,
  required bool selected,
  required VoidCallback? onTap,
  VoidCallback? onLongPress,
  String? label,
  Color? textColor,
}) {
  final Widget interactiveSwatch;
  if (onTap == null) {
    interactiveSwatch = visual;
  } else {
    final bool underFocusRoot =
        FushiFocusRoot.maybeControllerOf(context) != null;
    final Widget inkSwatch = Material(
      color: Colors.transparent,
      borderRadius: inkRadius,
      child: InkWell(
        borderRadius: inkRadius,
        onTap: onTap,
        // TODO-928: 长按是鼠标/触摸语义；手柄/焦点路径走下面的
        // FushiActivatableFocusTarget（只有 onTap），长按在那里不生效，符合现状无障碍。
        onLongPress: onLongPress,
        canRequestFocus: !underFocusRoot,
        child: visual,
      ),
    );
    interactiveSwatch = underFocusRoot
        ? FushiActivatableFocusTarget(
            focusIdPrefix: 'color-swatch',
            onTap: onTap,
            child: inkSwatch,
          )
        : inkSwatch;
  }
  final Widget semanticSwatch = Semantics(
    button: onTap != null,
    selected: selected,
    child: interactiveSwatch,
  );
  if (label == null) return semanticSwatch;
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      semanticSwatch,
      SizedBox(height: tokens.spacing.gap / 2),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.metadata.copyWith(
          color: textColor ?? tokens.surfaces.onSurface,
        ),
      ),
    ],
  );
}

/// Registers [child] as a single gamepad/keyboard focus stop whose A/Enter
/// ([ActivateIntent]) fires [onTap]. The [Actions] sits ABOVE the
/// [FushiFocusTarget] on purpose: the gamepad A path dispatches the intent at
/// the focused node's context (gamepad_service `_dispatchButton`), which finds
/// an Actions handler only by walking UP — so a handler placed *inside*
/// FushiFocusTarget (as [FushiFocusable] does) would never fire. Use this for
/// a discrete tap target whose own visual (e.g. an InkWell with
/// `canRequestFocus: false`) must stay mouse/touch-tappable without grabbing a
/// competing, unregistered focus node. Only meaningful under a [FushiFocusRoot].
class FushiActivatableFocusTarget extends StatefulWidget {
  const FushiActivatableFocusTarget({
    required this.onTap,
    required this.child,
    super.key,
    this.focusIdPrefix = 'tap-stop',
  });

  final VoidCallback onTap;
  final Widget child;
  final String focusIdPrefix;

  @override
  State<FushiActivatableFocusTarget> createState() =>
      _FushiActivatableFocusTargetState();
}

class _FushiActivatableFocusTargetState
    extends State<FushiActivatableFocusTarget> {
  late final FushiFocusId _focusId = FushiFocusId(
    '${widget.focusIdPrefix}-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: _focusId,
        child: widget.child,
      ),
    );
  }
}

Color _swatchForegroundFor(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

/// The four colours a [FushiSchemeSwatch] previews for a generated
/// [ColorScheme], in the order the swatch paints them:
/// `[text, background, button, menu]` =
/// `[onSurface, surface, primary, surfaceContainerHigh]`.
///
/// This answers "what does this theme actually look like?" the way a user
/// reads a UI: the **text colour** sitting on the **page background** (top-left
/// triangle, shown as a 「文」glyph) and the **button/accent colour** dropped on
/// a **popup-menu surface** (bottom-right triangle, shown as a dot). Surface vs
/// surfaceContainerHigh also keeps light/dark presets that share one seed
/// distinct (their backgrounds differ), and makes the three dark presets
/// readable apart at a glance instead of three near-identical dark circles.
List<Color> fushiSchemeSwatchColors(ColorScheme scheme) => <Color>[
      scheme.onSurface,
      scheme.surface,
      scheme.primary,
      scheme.surfaceContainerHigh,
    ];

/// A rounded-square swatch split on the diagonal to preview the four real
/// generated scheme colours instead of a single seed colour. The top-left
/// triangle paints the **page background** with the **text colour** as a 「文」
/// glyph (text-on-background contrast); the bottom-right triangle paints the
/// **popup-menu surface** with the **button/accent colour** as a dot
/// (button-on-menu). Used by the theme picker so each swatch accurately
/// predicts the applied theme; a single-colour seed swatch could not (e.g.
/// light/dark presets share one seed, the three dark presets look identical).
/// Single-colour swatches (tag colour, custom-colour preview) keep using
/// [FushiColorSwatch].
class FushiSchemeSwatch extends StatelessWidget {
  const FushiSchemeSwatch({
    required this.colors,
    super.key,
    this.size = 48,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.overlay,
    this.borderColor,
  }) : assert(colors.length == 4, 'scheme swatch needs exactly 4 colours');

  /// `[text, background, button, menu]` — see [fushiSchemeSwatchColors].
  final List<Color> colors;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  /// TODO-928: 长按动作（鼠标/触摸语义）。自定义 swatch 用它「长按进编辑页」，
  /// 而单击统一为「切换主题」。手柄/焦点路径无长按（见 [_buildSwatchInteractive]），
  /// 故焦点用户的编辑入口另由可达的「编辑」图标按钮提供，不靠此回调。
  final VoidCallback? onLongPress;

  /// Centred badge icon for non-preset swatches (system = auto, custom = palette).
  final Widget? overlay;
  // TODO-1320: 主题卡片一律不带 caption 文字（无 label/textColor）——系统/预设/自定义
  // 所有 swatch 统一只显示完整对角预览、无底部多余文字。带文字标签的单色 swatch 仍走
  // FushiColorSwatch（它保留 label/textColor）。
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color textRole = colors[0];
    final Color backgroundRole = colors[1];
    final Color buttonRole = colors[2];
    final Color menuRole = colors[3];
    // 选中强调色：Apple 设计系统走 Apple 强调色，MD3 走 primary。
    final Color accent = isGlassDesign(context)
        ? appleColorsOf(context).accent
        : cs.primary;
    final Color onAccent = appleOnAccent(accent);
    final double radius = size * 0.24;
    // 微缩界面预览（用户 2026-10-04：主题图标重新设计）：页面底 + 顶栏（菜单面）
    // + 两条文字线（文字色）+ 强调色胶囊按钮，一眼看出「这套主题长什么样」，
    // 取代旧的对角分色 + 「文」字。色板之外隔 2px 留缝再套选中环（macOS 外观
    // 缩略图式），选中徽标在右上角；系统 / 自定义的提示图标在右下角。
    final Widget preview = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(size),
          painter: SchemeMiniUiPainter(
            textColor: textRole,
            backgroundColor: backgroundRole,
            buttonColor: buttonRole,
            barColor: menuRole,
          ),
        ),
      ),
    );
    Widget cornerBadge(Widget icon, Color bg, Color fg, double d) => Container(
      width: d,
      height: d,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: backgroundRole, width: 1.5),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: fg, size: d * 0.62),
        child: icon,
      ),
    );
    const double ring = 2;
    const double gap = 2;
    final Widget visual = SizedBox(
      width: size + 2 * (ring + gap),
      height: size + 2 * (ring + gap),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: AnimatedContainer(
              duration: fushiMd3StateDuration,
              curve: fushiMd3StateCurve,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius + ring + gap),
                border: Border.all(
                  color: selected ? accent : Colors.transparent,
                  width: ring,
                ),
              ),
            ),
          ),
          Positioned(
            left: ring + gap,
            top: ring + gap,
            width: size,
            height: size,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                  color: borderColor ?? cs.outlineVariant.withValues(alpha: 0.6),
                  width: 0.5,
                ),
              ),
              child: preview,
            ),
          ),
          if (overlay != null)
            Positioned(
              right: ring + gap + size * 0.06,
              bottom: ring + gap + size * 0.06,
              child: cornerBadge(
                overlay!,
                menuRole,
                _swatchForegroundFor(menuRole),
                size * 0.34,
              ),
            ),
          if (selected)
            Positioned(
              right: 0,
              top: 0,
              child: cornerBadge(
                const FushiIcon(Icons.check_rounded),
                accent,
                onAccent,
                size * 0.36,
              ),
            ),
        ],
      ),
    );
    return _buildSwatchInteractive(
      context,
      visual: visual,
      inkRadius: BorderRadius.circular(radius + ring + gap),
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// Paints the diagonal scheme preview: the canvas is split corner-to-corner
/// (top-right -> bottom-left) into a top-left triangle filled with
/// [backgroundColor] (carrying a [textColor] 「文」 glyph) and a bottom-right
/// triangle filled with [menuColor] (carrying a [buttonColor] dot). This mirrors
/// how a user reads a theme: text on the page vs a button on a popup menu.
@visibleForTesting
class SchemeDiagonalPainter extends CustomPainter {
  const SchemeDiagonalPainter({
    required this.textColor,
    required this.backgroundColor,
    required this.buttonColor,
    required this.menuColor,
    required this.showGlyph,
    required this.textDirection,
  });

  final Color textColor;
  final Color backgroundColor;
  final Color buttonColor;
  final Color menuColor;
  final bool showGlyph;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..style = PaintingStyle.fill;
    // Top-left triangle = page background (the card decoration already fills it,
    // but paint it explicitly so the painter is self-contained / testable).
    paint.color = backgroundColor;
    final Path topLeft = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(topLeft, paint);
    // Bottom-right triangle = popup-menu surface.
    paint.color = menuColor;
    final Path bottomRight = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(bottomRight, paint);

    // Button/accent dot in the bottom-right triangle's centroid.
    final double dotRadius = size.shortestSide * 0.13;
    final Offset dotCenter = Offset(size.width * 0.68, size.height * 0.68);
    paint.color = buttonColor;
    canvas.drawCircle(dotCenter, dotRadius, paint);

    if (!showGlyph) return;
    // 「文」 glyph in the top-left triangle, in the text role, to show the real
    // text-on-background contrast of this theme.
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: '文',
        style: TextStyle(
          color: textColor,
          fontSize: size.shortestSide * 0.34,
          height: 1,
        ),
      ),
      textDirection: textDirection,
    )..layout();
    tp.paint(
      canvas,
      Offset(
          size.width * 0.30 - tp.width / 2, size.height * 0.30 - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(SchemeDiagonalPainter oldDelegate) =>
      oldDelegate.textColor != textColor ||
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.buttonColor != buttonColor ||
      oldDelegate.menuColor != menuColor ||
      oldDelegate.showGlyph != showGlyph ||
      oldDelegate.textDirection != textDirection;
}

class FushiPreviewSwitch extends StatelessWidget {
  const FushiPreviewSwitch({
    required this.trackColor,
    required this.thumbColor,
    super.key,
  });

  final Color trackColor;
  final Color thumbColor;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      // 纯预览：与设置页 Apple 开关同一枚 [FushiAppleSwitch]，恒为开；
      // onChanged 为 null = 纯展示（不吃手势、不进焦点遍历）。
      return FushiAppleSwitch(
        value: true,
        onChanged: null,
        activeTrackColor: trackColor,
        activeThumbColor: thumbColor,
      );
    }
    return Switch(
      value: true,
      onChanged: null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: WidgetStatePropertyAll<Color>(thumbColor),
      trackColor: WidgetStatePropertyAll<Color>(trackColor),
    );
  }
}

class FushiPageHeader extends StatelessWidget {
  const FushiPageHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.padding,
    this.compact = false,
  }) : titleWidget = null;

  /// 用任意组件占据页头主位。适合把分段导航直接放进页头动作同一行，避免再渲染
  /// 一个重复标题；自定义标题与 [subtitle] 互斥。
  const FushiPageHeader.customTitle({
    required Widget title,
    super.key,
    this.leading,
    this.actions = const <Widget>[],
    this.padding,
    this.compact = false,
  })  : title = null,
        titleWidget = title,
        subtitle = null,
        bottom = null;

  /// 推出来的独立页（不在首页外壳里）的页头：标题 + 自动返回键。
  ///
  /// 返回键是 [FushiRouteBackButton]：Apple 设计系统下是 44 的圆形玻璃钮
  /// （SF chevron），MD3 下是 `arrow_back` 图标按钮（48 命中盒）；[onBack]
  /// 为 null 时 `Navigator.maybePop`，当前路由不能返回时不出现。标题走页头
  /// 自己的大标题字阶（Apple 粗体收字距）。用来替代各页手写的
  /// 「返回键 + titleLarge」Row。
  FushiPageHeader.route({
    required String this.title,
    super.key,
    this.subtitle,
    this.actions = const <Widget>[],
    this.bottom,
    this.padding,
    VoidCallback? onBack,
    Key? backButtonKey,
  })  : titleWidget = null,
        compact = false,
        leading = FushiRouteBackButton(key: backButtonKey, onPressed: onBack);

  final String? title;
  final Widget? titleWidget;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final EdgeInsetsGeometry? padding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // TODO-667 / BUG-2402: 顶部留白按「页头主位是什么」先分两类，标题类再分三档。
    // - 页头主位是嵌入的分段 tab 行（[titleWidget] 非空）：顶距恒 0，与窗口宽度
    //   无关，理由见下方 [resolvedTop] 处的注释。
    // 以下三档只适用于纯文字大标题（[title]）：
    // - [compact] 模式（上方已有 AppBar，由 [FushiPageScaffold] 传入）顶距最小，
    //   只留一个 gap，标题紧贴 AppBar 下沿。
    // - 非 compact 但窗口是手机竖屏 / 窄窗（[WindowSizeClass.compact]，宽 < 600）：
    //   页头本身就是顶部锚点，外层 [SafeArea] 已让出状态栏 / 刘海，再叠
    //   `page + 8` 会让标题离顶部空出一行（用户反馈「和摄像头差一行」）。
    //   收到普通 `page`，保留必要呼吸又不顶到摄像头。
    // - 非 compact 的中 / 宽窗（桌面 / 平板，宽 >= 600）：窗口顶部无系统栏遮挡、
    //   内容区另有左右留白，`page + 8` 的标题区呼吸感合适。
    // BUG-401: classify on the real physical width. FushiPageHeader renders
    // inside FushiAppUiScale, so MediaQuery.sizeOf here is the inflated
    // logical width; multiply by the net app UI scale to recover the real
    // viewport width before applying the compact breakpoint.
    final bool narrowWindow = windowSizeClassReal(
          MediaQuery.sizeOf(context).width,
          FushiAppUiScale.of(context),
        ) ==
        WindowSizeClass.compact;
    // Embedded tabs already own a touch-height row, so the header is a seam
    // between the shell chrome and those tabs, not a title band. Whatever sits
    // above it already yields the space that seam needs -- SafeArea for the
    // status bar / notch on phones, FushiDesktopTitleBar's real 32px caption row
    // on desktop -- and the tabs carry their own 13px of centring slack inside
    // the 46px MD3 TabBar. A title margin here is therefore a second, redundant
    // one at every window size, which is why this arm ignores [narrowWindow].
    // 首页外壳顶部的大标题条（[FushiShellLargeTitleBar]）已经画了同名页面名
    // （如查词页的「查词」）：这里不再重复画标题，只留动作行，顶距同嵌入页签
    // 一样归 0——外壳的标题条就是它上面的那段呼吸。
    final bool shellShowsTitle = titleWidget == null &&
        !compact &&
        title != null &&
        FushiShellTitleScope.maybeTitleOf(context) == title;
    final double resolvedTop = titleWidget != null || shellShowsTitle
        ? 0
        : compact
            ? tokens.spacing.gap
            : (narrowWindow ? tokens.spacing.page : tokens.spacing.page + 8);
    final EdgeInsetsGeometry resolvedPadding = padding ??
        EdgeInsets.fromLTRB(
          tokens.spacing.page,
          resolvedTop,
          tokens.spacing.page,
          bottom == null ? tokens.spacing.gap + 4 : tokens.spacing.gap,
        );
    final String? resolvedSubtitle =
        subtitle == null || subtitle!.trim().isEmpty ? null : subtitle;
    // 2026-10-05「全部用浮动工具栏统一」：Material（M3 Expressive）下页头不再
    // 是一条平铺的文字行，而是浮在内容上的几颗分离胶囊——返回键一枚圆胶囊、
    // 标题一枚标题胶囊（titleLarge 加粗）、动作收进一枚按钮组胶囊（见
    // [_FushiPageHeaderRow]）。Apple 设计系统保持既有玻璃形态。
    final bool floatingChrome = !isGlassDesign(context);
    final Widget? floatingTitle =
        floatingChrome && titleWidget == null && !shellShowsTitle
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiPageChromeTitle(
              title: Text(title!),
              subtitle:
                  resolvedSubtitle == null ? null : Text(resolvedSubtitle),
            ),
          )
        : null;
    final Widget resolvedTitle = titleWidget ??
        floatingTitle ??
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (!shellShowsTitle)
              Text(
                title!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                // 玻璃设计系统：GlassLargeTitle 的大标题观感（更重、略收字距）。
                style: isGlassDesign(context)
                    ? tokens.type.pageTitle.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      )
                    : tokens.type.pageTitle,
              ),
            if (resolvedSubtitle != null)
              Padding(
                padding: EdgeInsets.only(
                  top: shellShowsTitle ? 0 : tokens.spacing.gap / 2,
                ),
                child: Text(
                  resolvedSubtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listSubtitle,
                ),
              ),
          ],
        );

    // 2026-10-04「顶部标签栏做成全宽」：在首页外壳里、主位是分区页签（或标题
    // 已由外壳大标题条画出）时，动作交给外壳大标题条右侧（iOS 26 / macOS 26
    // 的大标题行工具栏胶囊、MD3 top app bar 的 actions 位），页签独占一整行。
    // 有 leading（返回键）的页头不收：返回键与动作同属一条导航行。
    final FushiShellActionsSlot? shellActions = actions.isNotEmpty &&
            leading == null &&
            (titleWidget != null || shellShowsTitle)
        ? FushiShellTitleScope.maybeActionsSlotOf(context)
        : null;

    return Padding(
      padding: resolvedPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _FushiPageHeaderRow(
            tokens: tokens,
            leading: floatingChrome ? fushiFloatingLeading(leading) : leading,
            title: resolvedTitle,
            actionItems: actions,
            floatingActions: floatingChrome,
            shellActions: shellActions,
            // 只有 customTitle（标题位是分段导航等自报宽度的组件）才启用
            // 「左边摆不下就把动作收进 ⋯ 菜单」；纯文字标题自身可省略号收缩，
            // 维持既有行为。
            collapseWhenCramped: titleWidget != null,
          ),
          if (bottom != null)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap + 4),
              child: bottom!,
            ),
        ],
      ),
    );
  }
}

/// 页头下发给标题位组件的「自报自然宽」通道。
///
/// 动因（2026-08-13 手机顶栏显示不全）：页头一行同时放分段导航（标题位）和一排
/// 动作按钮，两边都想要宽度；窄屏上动作区按自然宽优先拿，分段条被挤到只剩一小截。
/// 「动作何时该收进 ⋯ 菜单」的正确判据是**标题位的自然宽 + 动作自然宽 > 行宽**，
/// 而标题位是任意 widget，页头无法自行估宽——由标题位里的分段条（自然宽是纯
/// build 期可算量）经本作用域上报。没有上报（纯文字标题等）就永不收纳。
///
/// 上报发生在子组件 build 期，回调内部经 post-frame 才 setState，且同值去重——
/// 估宽只依赖标签/字号/缩放，不依赖布局结果，不会形成布局反馈振荡。
class FushiHeaderCrampScope extends InheritedWidget {
  const FushiHeaderCrampScope({
    required this.reportTitleNaturalWidth,
    required super.child,
    super.key,
  });

  /// 标题位组件在 build 期上报自己的自然宽（逻辑像素）。
  final void Function(double width) reportTitleNaturalWidth;

  /// 静态查找（不建立依赖：回调每次 build 重建，依赖会造成无谓的子树重建）。
  static FushiHeaderCrampScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FushiHeaderCrampScope>();

  @override
  bool updateShouldNotify(FushiHeaderCrampScope oldWidget) => false;
}

/// TODO-1126 / BUG-541: [FushiPageHeader] 的标题 + 动作行。
///
/// 根因：旧实现（7ce19740c + 3df631aaf）标题 [Expanded](flex:1) 与动作区
/// [Flexible](flex:1) **均分**剩余宽，动作格恒占页头右半幅（与图标实际总宽无关），
/// 再套 [Align](centerRight) 把按钮推到右半幅右缘才勉强靠右。窄窗时 4 个图标自然宽
/// 超过右半幅视口，内层 [SingleChildScrollView](reverse:true) 把最左侧 [Icons.add]
/// 裁到视口外（用户看到像个「-」）。
///
/// 修法：标题 [Expanded]（tight）吃满剩余，动作区作为**非弹性**子项按自身自然宽落在
/// 页头最右侧——不再与标题 flex 均分，宽窗行为零变化。用 [LayoutBuilder] 拿到整行可用
/// 宽，给动作区套 [ConstrainedBox]（maxWidth = 整行宽 − 动作前 gap，title 允许被压到
/// 0）：放得下时约束不触发、动作区取自然宽、所有图标可见且靠右；仅当动作总宽超过该
/// 上界（极端窄窗，如 master-detail 208px 左栏）时约束触发，内层横向
/// [SingleChildScrollView] 收缩 + 可横滚兜底，消除 RenderFlex overflow，滚动起始边在
/// 左、最左侧动作（回归态被裁的 [Icons.add]）默认可见。三个 home tab（视频/书架/词典）
/// 页头均无 leading + actions 并存，故不必为 leading 额外预留。
class _FushiPageHeaderRow extends StatefulWidget {
  const _FushiPageHeaderRow({
    required this.tokens,
    required this.title,
    required this.leading,
    required this.actionItems,
    required this.collapseWhenCramped,
    this.floatingActions = false,
    this.shellActions,
  });

  final FushiDesignTokens tokens;

  /// Material（M3E）下把动作行装进一枚悬浮按钮组胶囊。
  final bool floatingActions;
  final Widget title;
  final Widget? leading;
  final List<Widget> actionItems;

  /// 非 null：动作登记到外壳大标题条（见 [FushiShellActionsSlot]），本行不画。
  final FushiShellActionsSlot? shellActions;

  /// true（customTitle 模式）时，若标题位上报的自然宽 + 动作自然宽超过行宽，
  /// 把可收纳的动作（[FushiIconButton]）折进一个 ⋯ 菜单，把宽度还给标题位。
  final bool collapseWhenCramped;

  @override
  State<_FushiPageHeaderRow> createState() => _FushiPageHeaderRowState();
}

class _FushiPageHeaderRowState extends State<_FushiPageHeaderRow> {
  FushiDesignTokens get tokens => widget.tokens;

  /// 标题位（经 [FushiHeaderCrampScope]）最近一次上报的自然宽；null = 从未上报
  /// （纯文字标题等），永不收纳。
  double? _titleNaturalWidth;

  void _onTitleWidthReported(double width) {
    if (_titleNaturalWidth == width) return;
    // 上报发生在子组件 build 期，不能同帧 setState；post-frame 再落。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _titleNaturalWidth == width) return;
      setState(() => _titleNaturalWidth = width);
    });
  }

  /// 动作区自然宽估算，见 [_estimateHeaderActionsWidth]。
  double _estimateActionsWidth(List<Widget> items) =>
      _estimateHeaderActionsWidth(tokens, items);

  Widget _buildActionRow(List<Widget> items) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      // 动作之间也居中：同一行里可能混着纯图标键（40~48 高）和带标签的药丸
      // （更高），顶对齐会让图标浮在药丸文字上方。
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (int index = 0; index < items.length; index++) ...<Widget>[
          if (index > 0) SizedBox(width: tokens.spacing.gap / 2),
          items[index],
        ],
      ],
    );
  }

  Widget _buildOverflowMenuButton(List<FushiIconButton> collapsed) =>
      _headerOverflowMenuButton(collapsed);

  /// 当前登记着动作的外壳槽（换槽 / 不再需要时先撤回旧登记）。
  FushiShellActionsSlot? _claimedSlot;

  void _syncShellClaim(FushiShellActionsSlot? slot) {
    if (!identical(_claimedSlot, slot)) {
      _claimedSlot?.release(this);
      _claimedSlot = slot;
    }
    if (slot == null) return;
    // 可见 = 没被保活外壳停帧（TickerMode）且不在 IndexedStack 的隐藏子区里
    // （[Visibility]，IndexedStack 不停帧）。两者都建立依赖，变化时本页头重建、
    // 重新登记。
    slot.claim(
      this,
      visible: TickerMode.valuesOf(context).enabled && Visibility.of(context),
      actions: FushiShellHeaderActions(actions: widget.actionItems),
    );
  }

  @override
  void dispose() {
    _claimedSlot?.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double leadingGap = tokens.spacing.gap + 4;
    final double actionsGap = tokens.spacing.gap;
    final Widget? leading = widget.leading;
    final FushiShellActionsSlot? shellActions = widget.shellActions;
    _syncShellClaim(shellActions);
    // 动作交给外壳时本行只剩标题位（分区页签独占整行）。
    final List<Widget> actionItems =
        shellActions == null ? widget.actionItems : const <Widget>[];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget titleChild = Expanded(
          child: FushiHeaderCrampScope(
            reportTitleNaturalWidth: _onTitleWidthReported,
            child: widget.title,
          ),
        );

        final List<Widget> children = <Widget>[];
        if (leading != null) {
          children.add(
            Padding(
              // 方向性内边距：RTL（ar / he）下 [Row] 会把 leading 排到行尾（视觉右
              // 侧），此时「leading 与标题之间的空隙」在它的**左**边。写死物理 right
              // 会让空隙跑到屏幕边缘那侧，返回键直接贴上标题。以前只有两个页面显式
              // 传 leading，现在脚手架默认给每个可返回页插一个，这条必须是 directional。
              // 只留水平间距；垂直位置由整行的 [CrossAxisAlignment.center] 决定
              // （见下方 Row 处注释），不再用常数凑。
              padding: EdgeInsetsDirectional.only(end: leadingGap),
              child: leading,
            ),
          );
        }
        children.add(titleChild);
        if (actionItems.isNotEmpty) {
          // 动作区可用宽上界：整行宽减去动作前 gap，**再减去留给标题的保底宽**。
          // leading（含右 gap）作为非弹性子项另行占位，不计入此上界——它在 Row 里已被
          // 独立扣除；这里只需保证「gap + 动作区」不超过整行宽即可避免 overflow。
          //
          // BUG-1184：原先只保证不 overflow，标题作为 [Expanded] 被允许压到 0。窄屏上
          // 4~5 个动作按钮就能把标题吃干净——不报错，但页面标题（合集名、书名）彻底
          // 消失，用户只看到一排图标。动作区本就套着横向滚动视图，被限宽后是「滚动」
          // 而不是「丢失」；标题被压到 0 才是真的丢失。所以保底给标题留几个字的宽度，
          // 超出的动作让它滚。保底值随文字缩放走，并且不超过行宽的三分之一，免得动作
          // 很少时反而挤到按钮。
          final double titleFloor = constraints.maxWidth.isFinite
              ? math.min(
                  96.0 * MediaQuery.textScalerOf(context).scale(1),
                  constraints.maxWidth / 3,
                )
              : 0.0;
          final double maxActionsWidth = constraints.maxWidth.isFinite
              ? (constraints.maxWidth - actionsGap - titleFloor)
                  .clamp(0.0, double.infinity)
              : double.infinity;
          // 带 label 的动作是否展开成药丸：按**页头本地可用宽**（而非整窗宽）判定，经
          // UI 缩放还原真实宽后仅 expanded（≥840）才展开。桌面带导航栏 / 分栏时整窗
          // ≥840 但本地宽更窄，若按整窗判定会误展开、把 [Expanded] 标题挤到贴按钮/折行
          // （用户反馈「已经重叠了还没降级成无字」）。经 [FushiHeaderLabelScope] 下发。
          final bool expandLabels = constraints.maxWidth.isFinite &&
              windowSizeClassReal(
                    constraints.maxWidth,
                    FushiAppUiScale.of(context),
                  ) ==
                  WindowSizeClass.expanded;

          // 2026-08-13 手机顶栏显示不全：标题位是分段导航时（customTitle），
          // 「标题自然宽 + 动作自然宽」超过行宽才把可收纳动作折进 ⋯ 菜单——
          // 摆得下就一个不收（用户定案：仅在左边位置不够时才变）。宽窗药丸
          // 形态（expandLabels）永不收纳。可收纳 <2 个时收了也省不出宽度，
          // 维持原样让滚动兜底。
          List<Widget> resolvedItems = actionItems;
          if (widget.collapseWhenCramped &&
              !expandLabels &&
              _titleNaturalWidth != null &&
              constraints.maxWidth.isFinite) {
            final double needed = _titleNaturalWidth! +
                actionsGap +
                _estimateActionsWidth(actionItems) +
                (widget.floatingActions ? 8 : 0);
            final List<FushiIconButton> collapsible = actionItems
                .whereType<FushiIconButton>()
                .where((FushiIconButton b) => b.onTap != null)
                .toList(growable: false);
            if (needed > constraints.maxWidth && collapsible.length >= 2) {
              resolvedItems = <Widget>[
                for (final Widget item in actionItems)
                  if (item is! FushiIconButton || item.onTap == null) item,
                _buildOverflowMenuButton(collapsible),
              ];
            }
          }

          children
            ..add(SizedBox(width: actionsGap))
            ..add(
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxActionsWidth),
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: FushiHeaderLabelScope(
                      expandLabels: expandLabels,
                      child: widget.floatingActions
                          ? fushiFloatingHeaderActionGroups(
                              resolvedItems,
                              _buildActionRow,
                            )
                          : _buildActionRow(resolvedItems),
                    ),
                  ),
                ),
              ),
            );
        }

        // BUG-2033: 前导键 / 动作键与标题**垂直居中**对齐，不再按 start 顶对齐。
        //
        // 旧实现顶对齐 + 给 leading 写死 `top: gap / 2`，是拿一个常数去凑
        // 「48 高的 BackButton 图标中心（距顶 24）」和「pageTitle 行盒中心
        // （22 × 1.27 / 2 ≈ 14）」的差，凑出来仍差 ~14px：箭头恒比标题低一截
        // （用户报「左上角文字和返回箭头没对齐」）。动作区同理（图标中心 20~24
        // vs 标题中心 14）。这个差随字号档位、文字缩放、按钮尺寸变化，任何常数
        // 都只在一种组合下正确。
        //
        // 居中是唯一不含常数的判据：Row 把两侧按各自实际高度居中，字号、
        // textScaler、按钮尺寸怎么变都成立。标题带副标题 / 折行时，前导键落在
        // 整个标题块的中心（ListTile / AppBar 两行标题的既有做法）。
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: children,
        );
      },
    );
  }
}

/// 页头动作区自然宽估算（图标形态）：[FushiIconButton] = 图标 + 内边距；其它
/// widget 给一个按钮级的保守值。只在非展开标签（<840）的窄行场景使用。
double _estimateHeaderActionsWidth(
  FushiDesignTokens tokens,
  List<Widget> items,
) {
  double total = 0;
  for (int index = 0; index < items.length; index++) {
    if (index > 0) total += tokens.spacing.gap / 2;
    final Widget item = items[index];
    if (item is FushiIconButton) {
      final double icon = item.size ?? 24.0;
      final EdgeInsets padding =
          item.padding ?? EdgeInsets.all(tokens.spacing.gap);
      total += icon + padding.horizontal;
    } else {
      total += 48.0;
    }
  }
  return total;
}

/// 页头动作里自带一枚按钮胶囊的「文字动作」（图标 + 文字的 outlined / text /
/// filled / split 按钮）。它们本身就是胶囊，再包进按钮组胶囊就是「胶囊包胶囊」
/// （2026-10-06 用户截图：游戏库「开始串流」）。
bool fushiIsStandaloneHeaderAction(Widget item) =>
    item is FushiOutlinedButton ||
    item is FushiTextButton ||
    item is FushiFilledButton ||
    item is FushiSplitButton;

/// M3E 悬浮页头的动作区：连续的图标动作收进一枚按钮组胶囊
/// （[FushiPageChromeCapsule]，56 高），文字动作（[fushiIsStandaloneHeaderAction]）
/// 不进组胶囊，自身渲染成一枚同高的 tonal 胶囊按钮（[FushiFloatingTextAction]），
/// 与按钮组并排、间距 8。原顺序保留：动作被切成「图标段 / 文字动作」交替的几段。
Widget fushiFloatingHeaderActionGroups(
  List<Widget> items,
  Widget Function(List<Widget> icons) iconGroup,
) {
  final List<Widget> segments = <Widget>[];
  List<Widget> run = <Widget>[];
  void flushRun() {
    if (run.isEmpty) return;
    segments.add(FushiPageChromeCapsule(child: iconGroup(run)));
    run = <Widget>[];
  }

  for (final Widget item in items) {
    if (fushiIsStandaloneHeaderAction(item)) {
      flushRun();
      segments.add(FushiFloatingTextAction(child: item));
    } else {
      run.add(item);
    }
  }
  flushRun();
  if (segments.length == 1) return segments.single;
  return Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      for (int i = 0; i < segments.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(width: 8),
        segments[i],
      ],
    ],
  );
}

/// 悬浮页头里的文字动作：把 outlined / text / filled 按钮统一成 M3E 悬浮
/// tonal 胶囊按钮——secondaryContainer 底、无描边、与按钮组胶囊同高
/// （[kFushiPageChromeExtent]）、带悬浮投影。经按钮主题下发，调用方的按钮
/// 组件（key / 焦点 / 语义 / 菜单锚点）原样保留；调用方显式给的 style 仍优先。
class FushiFloatingTextAction extends StatelessWidget {
  const FushiFloatingTextAction({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final ButtonStyle floating = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(
        Size(kFushiPageChromeExtent, kFushiPageChromeExtent),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 20),
      ),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? cs.onSurface.withValues(alpha: 0.12)
            : cs.secondaryContainer,
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? cs.onSurface.withValues(alpha: 0.38)
            : cs.onSecondaryContainer,
      ),
      iconColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? cs.onSurface.withValues(alpha: 0.38)
            : cs.onSecondaryContainer,
      ),
      side: WidgetStatePropertyAll<BorderSide?>(
        eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      elevation: WidgetStatePropertyAll<double>(eink ? 0 : 3),
      shadowColor: WidgetStatePropertyAll<Color>(cs.shadow),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    );
    ButtonStyle over(ButtonStyle? base) =>
        floating.merge(base ?? const ButtonStyle());
    return Theme(
      data: theme.copyWith(
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: over(theme.outlinedButtonTheme.style),
        ),
        textButtonTheme: TextButtonThemeData(
          style: over(theme.textButtonTheme.style),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: over(theme.filledButtonTheme.style),
        ),
      ),
      child: child,
    );
  }
}

/// ⋯ 溢出按钮：菜单项由被收纳的 [FushiIconButton] 的图标 + 文案（label 优先、
/// 回退 tooltip）就地派生，动作行为共享同一个 onTap，不复制第二份实现。
Widget _headerOverflowMenuButton(List<FushiIconButton> collapsed) {
  return Builder(
    builder: (BuildContext anchorContext) => FushiIconButton(
      icon: Icons.more_vert,
      tooltip: t.common_more_actions,
      onTap: () => _showHeaderOverflowMenu(anchorContext, collapsed),
    ),
  );
}

Future<void> _showHeaderOverflowMenu(
  BuildContext anchorContext,
  List<FushiIconButton> collapsed,
) async {
  final RenderBox button = anchorContext.findRenderObject()! as RenderBox;
  final RenderBox overlay = Navigator.of(anchorContext)
      .overlay!
      .context
      .findRenderObject()! as RenderBox;
  final RelativeRect position = RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    ),
    Offset.zero & overlay.size,
  );
  final FushiIconButton? choice = await showFushiMenu<FushiIconButton>(
    context: anchorContext,
    position: position,
    items: <PopupMenuEntry<FushiIconButton>>[
      for (final FushiIconButton action in collapsed)
        PopupMenuItem<FushiIconButton>(
          value: action,
          enabled: action.enabled && action.onTap != null,
          child: Row(
            children: <Widget>[
              FushiIcon(action.icon, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(action.label ?? action.tooltip)),
            ],
          ),
        ),
    ],
  );
  await choice?.onTap?.call();
}

/// 外壳大标题条右侧的页头动作（页头登记进 [FushiShellActionsSlot] 的就是它）。
///
/// 两套设计系统都是标题行右侧的一排图标：Apple 由 [FushiToolbar] 收进一枚
/// 液态玻璃胶囊（iOS 26 / macOS 26 大标题行工具栏），MD3 是 top app bar 的
/// actions 位（无底一排图标按钮）。一律纯图标（文案是 tooltip）——标题行上
/// 放图标 + 文字的药丸会把大标题挤没。外壳给的宽放不下时，可收纳的
/// [FushiIconButton] 折进 ⋯ 菜单（与页头同一套菜单），再不够才横向滚动兜底。
class FushiShellHeaderActions extends StatelessWidget {
  const FushiShellHeaderActions({required this.actions, super.key});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        List<Widget> items = actions;
        final List<FushiIconButton> collapsible = actions
            .whereType<FushiIconButton>()
            .where((FushiIconButton b) => b.onTap != null)
            .toList(growable: false);
        // +16：Apple 工具栏胶囊两端的内边距与 MD3 按钮间距的余量。
        if (constraints.maxWidth.isFinite &&
            collapsible.length >= 2 &&
            _estimateHeaderActionsWidth(tokens, actions) + 16 >
                constraints.maxWidth) {
          items = <Widget>[
            for (final Widget item in actions)
              if (item is! FushiIconButton || item.onTap == null) item,
            _headerOverflowMenuButton(collapsible),
          ];
        }
        // MD3（M3E）：图标动作收进一枚悬浮按钮组胶囊，与页头 / 顶栏同一形态；
        // 带文字的动作自身就是一枚同高胶囊按钮，排在组旁（见
        // [fushiFloatingHeaderActionGroups]），不再被包进组胶囊。
        final Widget toolbar = isGlassDesign(context)
            ? FushiToolbar(children: items)
            : fushiFloatingHeaderActionGroups(
                items,
                (List<Widget> icons) => FushiToolbar(children: icons),
              );
        return FushiHeaderLabelScope(
          expandLabels: false,
          child: HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: toolbar,
            ),
          ),
        );
      },
    );
  }
}

/// 底部安全区（iOS home indicator / Android 手势条）的高度。
///
/// [FushiPageScaffold] / [FushiToolScaffold] 的 body 外层 `SafeArea` 是
/// `bottom: false`——底部 inset **不扣 viewport**，让内容能一直画到屏幕最底（否则那条
/// 34pt 就是一条谁也用不了的底色空白，滚动内容在切线处被拦腰截断，BUG-2440）。代价是
/// body 自己得把这段补进滚动 padding，不然末项静止时被手势条压住。
///
/// 取 `padding` 而不是 `viewPadding`：键盘弹出时 `padding.bottom` 归零（那段已被
/// `viewInsets` 接管），跟着归零才不会在键盘上方多顶一块空白；桌面与无手势条的设备上
/// 本来就是 0，本函数与整套改动一并成为空操作。
double bottomSafeInsetOf(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom;

/// 把底部安全区补进 [base] 的下边（**相加**，不是取 max）。
///
/// 这里与 BUG-383「逐边 max、不相加」的口径**故意不同**，因为语义不同：那边两个值描述
/// 的是同一段「离屏幕边缘的距离」（控件 margin vs 系统 inset），取大的即可；这里 [base]
/// 是内容与内容之间的呼吸位（卡片间距 / 页边距），系统 inset 是被手势条吃掉的不可用区，
/// 两段各自成立——只取 max 会让末项贴着手势条，视觉上比别的项少一截间距。
EdgeInsets withBottomSafeInset(BuildContext context, EdgeInsets base) =>
    base.copyWith(bottom: base.bottom + bottomSafeInsetOf(context));

class FushiPageScaffold extends StatefulWidget {
  const FushiPageScaffold({
    required this.title,
    required this.body,
    super.key,
    this.subtitle,
    this.actions = const <Widget>[],
    this.leading,
    this.automaticallyImplyLeading = true,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.headerBottom,
    this.bottomNavigationBar,
    this.headerCompact,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? leading;

  /// Whether a route back button is inserted when [leading] is null.
  ///
  /// The button is rendered inside [FushiPageHeader], beside the title. Older
  /// versions put it in a separate, otherwise-empty [AppBar], which wasted a
  /// full row and left the title visually detached from its navigation action.
  final bool automaticallyImplyLeading;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? headerBottom;
  final Widget? bottomNavigationBar;
  final bool? headerCompact;

  @override
  State<FushiPageScaffold> createState() => _FushiPageScaffoldState();
}

class _FushiPageScaffoldState extends State<FushiPageScaffold> {
  // Owns a PrimaryScrollController so a [body] built from a primary ScrollView
  // (CustomScrollView/ListView with no explicit controller) attaches here. The
  // gamepad LB/RB page-scroll fallback reaches it via
  // PrimaryScrollController.maybeOf even on pure-display pages with no focus
  // geometry (e.g. reading statistics), where D-pad edge takeover can't help.
  final ScrollController _scrollController = ScrollController();

  /// M3E 悬浮页头「内容往下滚收起、往回滚出现」（Apple 设计系统不喂通知，
  /// 页头恒在）。
  final FushiScrollAwayController _chrome = FushiScrollAwayController();

  @override
  void initState() {
    super.initState();
    // Register as the active page scroll controller so the gamepad LB/RB
    // page-scroll fallback can reach this page's body even when focus rests on
    // the top-level fallback node (a pure-display page with nothing focusable),
    // which is an ancestor of this controller and thus invisible to
    // PrimaryScrollController.maybeOf.
    PageScrollRegistry.push(_scrollController);
  }

  @override
  void dispose() {
    PageScrollRegistry.pop(_scrollController);
    _scrollController.dispose();
    _chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget? effectiveLeading = widget.leading ??
        (widget.automaticallyImplyLeading ? _defaultLeading(context) : null);
    final bool floatingChrome = !isGlassDesign(context);
    return PrimaryScrollController(
      controller: _scrollController,
      // Inherit on EVERY platform. The default is mobile-only, which would
      // leave the body's primary ScrollView UNATTACHED on desktop (and, worse,
      // shadow this controller with PrimaryScrollController.none) — but the
      // gamepad LB/RB page-scroll fallback that reaches this controller is a
      // desktop feature. All-platform inherit makes the body scroll reachable
      // everywhere.
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: Scaffold(
        backgroundColor: tokens.surfaces.page,
        floatingActionButton: widget.floatingActionButton,
        floatingActionButtonLocation: widget.floatingActionButtonLocation,
        bottomNavigationBar: widget.bottomNavigationBar,
        body: SafeArea(
          // bottom:false —— 底部安全区（iOS home indicator / Android 手势条）**不在这里
          // 扣**，交给 body 自己按 [bottomSafeInsetOf] 加进内容 padding（BUG-2440）。
          // SafeArea 扣底是把 viewport 硬切在手势条之上：那条 34pt 变成一条谁也用不了的
          // 底色空白，滚动内容在切线处被拦腰截断（卡片边框、文字切一半），怎么滚都进不去；
          // 更糟的是它同时 removePadding 把 padding.bottom 清零，让 body 里**已经写好**的
          // `+ mediaPadding.bottom` 集体变成死代码（settings 三处渲染器都中招）。
          // 让内容滚过安全区、只在滚动 padding 里补偿，才是这两条诉求（不留空白 + 末项
          // 不被压）唯一同时成立的形态。与 BUG-383 / BUG-1783 同一范式：拿掉 SafeArea、
          // 改走显式 inset，逐边取值不相加。
          bottom: false,
          // stretch (not start) so every page body receives a tight full-width
          // constraint. Under start the cross axis stays loose, and any body
          // that shrink-wraps its width (e.g. a vertical SingleChildScrollView
          // like FushiLogPanel) collapses into a tall, content-width column on
          // the left instead of filling the page. The header left-aligns its
          // own content internally, so it is unaffected by stretch.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 结构恒定：两套设计系统都挂着收起外壳与滚动监听，Apple 下只是
              // 不喂通知（页头恒显示）。
              FushiScrollAwayChrome(
                controller: _chrome,
                enabled: floatingChrome,
                child: FushiPageHeader(
                  title: widget.title,
                  subtitle: widget.subtitle,
                  leading: effectiveLeading,
                  actions: widget.actions,
                  bottom: widget.headerBottom,
                  compact: widget.headerCompact ?? effectiveLeading != null,
                ),
              ),
              Expanded(
                child: NotificationListener<Notification>(
                  onNotification: (Notification notification) =>
                      floatingChrome &&
                      _chrome.handleNotification(notification),
                  child: widget.body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 页头默认返回键（[leading] 为 null 且当前路由可 pop 时插入）。
  ///
  /// 命中盒必须撑到 [kMinInteractiveDimension]（48）：被它取代的
  /// `Scaffold.appBar` 自动 [BackButton] 本就是 48×48 的 [IconButton]，而
  /// [FushiIconButton] 在 `padding: EdgeInsets.zero` + 无 constraints 下只有图标
  /// 本体那么大（24×24）——手机触屏上就成了「点不中的返回箭头」，也与
  /// 本脚手架**显式**传入的 [BackButton]（aidoku 源浏览 / 新手引导）不是
  /// 同一命中口径。图标视觉尺寸不变，只把 InkWell 命中盒撑开。
  ///
  /// 与 [FushiToolScaffold] 同名方法看着一样但**不能合并**：那边整条工具条
  /// 只有 44 高，它在外层用 `SizedBox.square(40)` 自己撑命中盒，塞不下 48。
  ///
  /// [Navigator.maybeOf]：脚手架被用在没有 Navigator 的场景（裸组件测试 /
  /// 嵌入式外壳）时只是没有返回键，不该整页抛异常。
  Widget? _defaultLeading(BuildContext context) {
    final NavigatorState? navigator = Navigator.maybeOf(context);
    if (navigator == null || !navigator.canPop()) return null;
    return FushiIconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: Icons.arrow_back,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onTap: () => Navigator.of(context).maybePop(),
    );
  }
}

class FushiToolScaffold extends StatelessWidget {
  const FushiToolScaffold({
    required this.title,
    required this.body,
    super.key,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.bottomNavigationBar,
    this.backgroundColor,
  }) : titleWidget = null;

  const FushiToolScaffold.customTitle({
    required Widget title,
    required this.body,
    super.key,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.bottomNavigationBar,
    this.backgroundColor,
  })  : title = null,
        titleWidget = title;

  final String? title;
  final Widget? titleWidget;
  final Widget body;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final Widget? bottomNavigationBar;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget? effectiveLeading = leading ?? _defaultLeading(context);

    return Scaffold(
      backgroundColor: backgroundColor ?? tokens.surfaces.page,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        // 与 [FushiPageScaffold] 同一口径（BUG-2440）：底部 inset 不扣 viewport。
        // 本脚手架的底部动作条走 [Scaffold.bottomNavigationBar]（在这层 SafeArea 之外、
        // 各自已套 SafeArea），不受影响；body 的滚动内容按 [withBottomSafeInset] 补偿。
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.gap,
                4,
                tokens.spacing.gap,
                2,
              ),
              // 玻璃设计系统：工具条是一条胶囊玻璃（GlassAppBar 观感）。背衬恒在、
              // 只换背景槽（见 [FushiGlassBackdrop]），切设计系统时工具条里带
              // GlobalKey 的动作（溢出菜单等）不被重挂。
              child: FushiGlassBackdrop(
                enabled: isGlassDesign(context),
                borderRadius: const BorderRadius.all(Radius.circular(22)),
                prominent: true,
                child: SizedBox(
                  // MD3（M3E 悬浮工具条）：返回键 / 标题 / 动作各是一枚 48 高的
                  // 悬浮胶囊，行高 52；Apple 保持 44 的玻璃胶囊条。
                  height: isGlassDesign(context) ? 44 : 52,
                  // BUG-1184：动作区上界原先取 `MediaQuery.sizeOf(context).width * 0.48`
                  // ——**整窗宽**。这个脚手架并不总是占满窗口（嵌在分栏/对话框/受限宽面板
                  // 里时更常见），此时 0.48×整窗可以超过本行的真实可用宽，Row 直接右溢出。
                  // 与 [_FushiPageHeaderRow] 同一类错误，那边已按本地约束修过；这里改用
                  // LayoutBuilder 的局部约束，并同样给标题留保底宽，超出的动作横向滚动。
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                      final double gapHalf = tokens.spacing.gap / 2;
                      final bool floating = !isGlassDesign(context);
                      final double leadingExtent =
                          floating ? kFushiPageChromeExtent : 40;
                      final double leadingWidth = effectiveLeading != null
                          ? leadingExtent + gapHalf
                          : 0;
                      final double titleFloor = constraints.maxWidth.isFinite
                          ? math.min(
                              96.0 * MediaQuery.textScalerOf(context).scale(1),
                              constraints.maxWidth / 3,
                            )
                          : 0.0;
                      final double maxActionsWidth =
                          constraints.maxWidth.isFinite
                              ? (constraints.maxWidth -
                                      leadingWidth -
                                      gapHalf -
                                      titleFloor)
                                  .clamp(0.0, double.infinity)
                              : double.infinity;
                      return Row(
                        children: <Widget>[
                          if (effectiveLeading != null) ...<Widget>[
                            SizedBox.square(
                              dimension: leadingExtent,
                              child: floating
                                  ? FushiPageChromeCircle(
                                      child: effectiveLeading,
                                    )
                                  : effectiveLeading,
                            ),
                            SizedBox(width: gapHalf),
                          ],
                          Expanded(
                            child: floating
                                ? Align(
                                    alignment:
                                        AlignmentDirectional.centerStart,
                                    child: FushiPageChromeTitle(
                                      title: _buildTitle(tokens),
                                    ),
                                  )
                                : _buildTitle(tokens),
                          ),
                          if (actions.isNotEmpty) ...<Widget>[
                            SizedBox(width: gapHalf),
                            ConstrainedBox(
                              constraints:
                                  BoxConstraints(maxWidth: maxActionsWidth),
                              child: HorizontalDragScrollable(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  reverse: true,
                                  child: floating
                                      ? FushiPageChromeCapsule(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: actions,
                                          ),
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: actions,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (bottom != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.gap,
                  0,
                  tokens.spacing.gap,
                  tokens.spacing.gap / 2,
                ),
                child: bottom!,
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget? _defaultLeading(BuildContext context) {
    if (!Navigator.of(context).canPop()) return null;
    return FushiIconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: Icons.arrow_back,
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).maybePop(),
    );
  }

  Widget _buildTitle(FushiDesignTokens tokens) {
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      color: tokens.surfaces.onSurface,
    );
    final Widget? customTitle = titleWidget;
    if (customTitle != null) {
      return DefaultTextStyle.merge(
        style: titleStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: customTitle,
      );
    }
    return Text(
      title!,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );
  }
}

class FushiTransientScaffold extends StatelessWidget {
  const FushiTransientScaffold({
    required this.body,
    super.key,
    this.backgroundColor,
    this.safeArea = true,
  });

  final Widget body;
  final Color? backgroundColor;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget content = safeArea ? SafeArea(child: body) : body;
    return Scaffold(
      backgroundColor: backgroundColor ?? tokens.surfaces.page,
      body: content,
    );
  }
}

class FushiOverlayScaffold extends StatelessWidget {
  const FushiOverlayScaffold({
    required this.body,
    super.key,
    this.safeArea = true,
  });

  final Widget body;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final Widget content = safeArea ? SafeArea(child: body) : body;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: content,
    );
  }
}

class FushiFilePickerRow extends StatelessWidget {
  const FushiFilePickerRow({
    required this.title,
    required this.icon,
    super.key,
    this.subtitle,
    this.actions = const <Widget>[],
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color foreground = enabled
        ? tokens.surfaces.onVariant
        : tokens.surfaces.onVariant.withValues(alpha: 0.38);
    return FushiListItem(
      onTap: enabled ? onTap : null,
      minHeight: 60,
      leading: FushiIcon(icon, size: 22, color: foreground),
      title: Text(title),
      subtitle: subtitle == null || subtitle!.isEmpty ? null : Text(subtitle!),
      trailing: actions.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: actions,
            ),
    );
  }
}

class FushiOverflowMenu<T> extends StatefulWidget {
  const FushiOverflowMenu({
    required this.items,
    required this.onSelected,
    super.key,
    this.icon = Icons.more_vert,
    this.iconWidget,
    this.child,
    this.tooltip,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.splashRadius,
  });

  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final IconData icon;
  final Widget? iconWidget;
  final Widget? child;
  final String? tooltip;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final double? splashRadius;

  @override
  State<FushiOverflowMenu<T>> createState() => _FushiOverflowMenuState<T>();
}

class _FushiOverflowMenuState<T> extends State<FushiOverflowMenu<T>> {
  final GlobalKey<PopupMenuButtonState<T>> _menuKey =
      GlobalKey<PopupMenuButtonState<T>>();
  late final FushiFocusId _fallbackFocusId =
      FushiFocusId('hibiki-overflow-menu-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 两套设计系统同一个弹出菜单组件：[FushiPopupMenuButton] 在 MD3 下就是
    // PopupMenuButton，Apple 下走 showFushiMenu 的 macOS / iOS 菜单路由（与
    // 全 app 其它弹出菜单同一套行、同一块面板）。MD3 面板：surfaceContainer、
    // 圆角 12、轻阴影、无 tint，宽 200–320。
    final PopupMenuButton<T> menu = FushiPopupMenuButton<T>(
      key: _menuKey,
      tooltip: widget.tooltip,
      icon: widget.child == null
          ? widget.iconWidget ?? FushiIcon(widget.icon, size: widget.iconSize)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: tokens.radii.menuRadius,
        side: isEinkTheme(context)
            ? BorderSide(color: cs.outline)
            : BorderSide.none,
      ),
      color: Theme.of(context).popupMenuTheme.color ?? cs.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
      padding: widget.padding,
      splashRadius: widget.splashRadius,
      position: PopupMenuPosition.under,
      popUpAnimationStyle: fushiM3eMenuAnimationStyle,
      onSelected: widget.onSelected,
      itemBuilder: (BuildContext context) => widget.items,
      child: widget.child,
    );
    if (FushiFocusRoot.maybeControllerOf(context) == null) return menu;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _menuKey.currentState?.showButtonMenu();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: _fallbackFocusId,
        child: menu,
      ),
    );
  }
}

/// 带结构化文案的菜单项。MD3 下行是圆角内缩高亮（左右各内缩 6、圆角 8，
/// 悬停 / 焦点 secondaryContainer），行高 44、14 号 onSurface 文字、20 号
/// onSurfaceVariant 图标、选中行尾对勾；Apple 下 showFushiMenu 按
/// [FushiMenuItemData] 的字段直接画 macOS / iOS 菜单行，不用 child。
class FushiPopupMenuItem<T> extends PopupMenuItem<T>
    implements FushiMenuItemData {
  FushiPopupMenuItem({
    required this.label,
    required T value,
    super.key,
    this.icon,
    this.color,
    this.selected = false,
    bool enabled = true,
  }) : super(
          value: value,
          enabled: enabled,
          height: 44,
          padding: EdgeInsets.zero,
          child: _FushiPopupMenuItemContent(
            label: label,
            icon: icon,
            color: color,
            selected: selected,
          ),
        );

  @override
  final String label;
  @override
  final IconData? icon;
  @override
  final Color? color;
  @override
  final bool selected;

  @override
  PopupMenuItemState<T, FushiPopupMenuItem<T>> createState() =>
      _FushiPopupMenuItemState<T>();
}

class _FushiPopupMenuItemState<T>
    extends PopupMenuItemState<T, FushiPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    const BorderRadius radius = BorderRadius.all(Radius.circular(12));
    // M3E 菜单（2026-10-05 浮层统一）：选中项常驻 secondaryContainer 圆角块
    // （内缩、不横贯容器），其上的悬停 / 焦点 / 按下叠 onSurface 状态层。
    final bool selected = widget.selected && !isEinkTheme(context);
    final Color hover = selected
        ? cs.onSecondaryContainer.withValues(alpha: 0.08)
        : cs.secondaryContainer;
    // 与 PopupMenuItemState.build 同一套语义 / 焦点 / 点击（handleTap：先
    // onTap 再带值关菜单），只把整行高亮换成内缩的圆角块。
    return MergeSemantics(
      child: Semantics(
        enabled: widget.enabled,
        selected: widget.selected,
        button: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.enabled ? handleTap : null,
              canRequestFocus: widget.enabled,
              mouseCursor: widget.mouseCursor,
              borderRadius: radius,
              hoverColor: hover,
              focusColor: selected
                  ? cs.onSecondaryContainer.withValues(alpha: 0.12)
                  : cs.secondaryContainer,
              highlightColor: hover,
              child: Ink(
                decoration: BoxDecoration(
                  color: selected ? cs.secondaryContainer : null,
                  borderRadius: radius,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Opacity(
                    opacity: widget.enabled ? 1 : 0.38,
                    child: buildChild(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FushiPopupMenuItemContent extends StatelessWidget {
  const _FushiPopupMenuItemContent({
    required this.label,
    this.icon,
    this.color,
    this.selected = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final Color foreground = color ?? cs.onSurface;
    final TextStyle textStyle = (tt.bodyMedium ?? const TextStyle()).copyWith(
      fontSize: 14,
      color: foreground,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            FushiIcon(icon, size: 20, color: color ?? cs.onSurfaceVariant),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
          if (selected) ...<Widget>[
            const SizedBox(width: 12),
            FushiIcon(Icons.check, size: 20, color: color ?? cs.primary),
          ],
        ],
      ),
    );
  }
}

class FushiLogPanel extends StatefulWidget {
  const FushiLogPanel({
    required this.log,
    required this.shareAction,
    super.key,
  });

  final String log;
  final ValueChanged<String> shareAction;

  @override
  State<FushiLogPanel> createState() => _FushiLogPanelState();
}

class _FushiLogPanelState extends State<FushiLogPanel> {
  // TODO-762：日志正文从「单个 `TextField`（maxLines:null, expands:true）全量渲染」
  // 改为按行 `ListView.builder` 懒加载。错误/调试日志最大 ~512KB、数万行
  // monospace，旧实现把整段一次性在 UI 线程做 `TextPainter.layout`（无行虚拟化），
  // 首帧 layout 几百 ms~数秒 → 打开「错误日志」卡顿。改为 ListView.builder 后只对
  // 视口内行做 layout，首帧恒定。选区/复制改由 `SelectionArea` 跨行提供。
  //
  // BUG-119 不回归（最高风险点）：旧实现之所以用 TextField，是为了让 EditableText
  // 当唯一滚动器，避免拖拽选区时被祖先 Scrollable 的 bringIntoView「拽回」。这里
  // 保留同一道防线——把 [_LogSelectionScrollController] 接到 ListView 的 controller：
  // 拖拽选区期间，除「指针贴边 + 朝外侧」的合法边缘自动滚动外，一律拦掉程序化
  // `jumpTo`/`animateTo`（选区把视口往光标/extent 拽回的来源），手动滚动不受影响。
  // SelectionArea 套纯 Text（无 EditableText caret）本就没有旧的 caret bringIntoView
  // 来源，此 gate 作为纵深防御守住不变式。守卫 `log_panel_scroll_select_guard_test`。
  late final _LogSelectionScrollController _scrollController =
      _LogSelectionScrollController();

  // BUG-1582 / flutter#119355：拿到 SelectionArea 的 state 以便主动清选区。
  // `SelectionAreaState.selectableRegion` 是公开 getter，不必把 SelectionArea
  // 换成裸 SelectableRegion（那会连带重写 selectionControls / magnifier 的平台
  // 分流，风险远大于收益）。
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();

  // 当前是否真的有选区。只作清理前的短路判据，不参与渲染，故不进 setState。
  bool _hasSelection = false;

  /// BUG-1582：用户主动滚动后丢弃选区。
  ///
  /// 根因在框架（flutter#119355）：`SelectionArea` 套 `Scrollable` 时，选区端点
  /// 所在的行被 `ListView.builder` 回收/detach 后，`_ScrollableSelectionContainerDelegate`
  /// 仍持有指向它的 `currentSelectionEndIndex`；下一次长按走
  /// `handleSelectWord` → `_updateDragLocationsFromGeometries()`（该方法**无条件**
  /// 执行，同文件 `handleSelectAll` 却有 `currentSelectionStartIndex != -1` 守卫）
  /// → 读到 `SelectionGeometry.endSelectionPoint == null` → `!` 抛空断言。
  /// release 下 `assert(geometry.hasSelection)` 不执行，所以只在真机上炸。
  ///
  /// 为什么「清掉」是正解而不是掩盖：本面板的选区**本就是视口内有界的**——
  /// `ListView.builder` 不构造视口外行，`SelectionArea` 拿不到它们的 Selectable，
  /// 这正是「复制全部」存在的理由（见下方 `Positioned` 注释）。用户滚走之后那份
  /// 选区已经不可用，框架只是崩溃而非优雅降级。把它清掉让模型诚实：选区活在
  /// 你划它的那一屏里。
  ///
  /// 边缘自动滚动（拖拽选区拖到视口边缘）必须放行，否则一拖就自毁选区。
  ///
  /// 判据不能只看「指针是否按下」——本面板对**任何主键按下**都置
  /// [_LogSelectionScrollController.pointerSelectionActive]（它服务的是
  /// `logSelectionScrollDecision` 的拽回拦截，故意粗），拖列表滚动同样会置位。
  /// 真正能分开两者的是 [ScrollUpdateNotification.dragDetails]：
  ///
  /// | 场景 | dragDetails | 指针按下 | 处置 |
  /// |---|---|---|---|
  /// | 滚轮 / 键盘滚动 | null | 否 | 清 |
  /// | 用户拖列表滚动 | 非 null | 是 | 清 |
  /// | 拖后惯性滑动 | null | 否 | 清 |
  /// | **拖选区时的边缘自动滚动** | null（animateTo 驱动） | **是** | **放行** |
  ///
  /// 即只有「非拖拽产生的滚动 + 指针仍按着」这一格才是边缘自动滚动。
  void _dropStaleSelectionOnUserScroll(ScrollUpdateNotification notification) {
    if (!_hasSelection) return;
    final bool edgeAutoScrollDuringDragSelect =
        notification.dragDetails == null &&
            _scrollController.pointerSelectionActive;
    if (edgeAutoScrollDuringDragSelect) return;
    _hasSelection = false;
    _selectionAreaKey.currentState?.selectableRegion.clearSelection();
  }

  /// BUG-2715：行集合被**非滚动**原因换掉时丢弃选区（BUG-1582 的补全）。
  ///
  /// 与 BUG-1582 同一个框架不变式（`scrollable.dart` `_updateDragLocationsFromGeometries`
  /// 假定 `currentSelectionStart/EndIndex` 指向的 Selectable 仍持有选区），但 BUG-1582
  /// 只收口了「用户滚动回收端点行」这一个来源。选区端点行离开 `selectables` 的
  /// 来源其实有三个，另两个与滚动无关：
  ///
  /// 1. **日志内容变化**：错误/调试日志页监听日志服务，新条目一来就整段重拼
  ///    （新条目在最前，所有行下移）→ 行 Text 内容变化 → `RenderParagraph.text`
  ///    走 layout 分支，把旧 `_SelectableFragment` 从 registrar `remove()` 掉再注册新的。
  ///    `_removeSelectable` 只把下标减一，选区端点于是指向一个**没有选区**的片段。
  /// 2. **视口变高度**（转屏 / 分屏 / 键盘）：视口变矮后端点行落出 cacheExtent 被回收，
  ///    同样只做下标减一；外层 `StaticSelectionContainerDelegate` 也会因此读到空端点。
  ///
  /// 之后再长按到**命不中任何 Selectable 的位置**（每条错误日志都有的空行——空文本
  /// 的 `RenderParagraph` 不注册片段；行尾空白；列表内边距），
  /// `_handleSelectBoundary` 不改下标就返回，`handleSelectWord` 随即无条件读陈旧下标
  /// → `startSelectionPoint!` / `endSelectionPoint!` 空断言（release 下 assert 不执行，
  /// 直接 Null check operator）。
  ///
  /// 选区只对「划它时屏幕上那批行」有意义：行被换掉，旧选区指的已经不是同一段
  /// 文字；所以在行集合被换掉时清掉选区，让选区状态与渲染快照同步。纯尾部追加
  /// 不换掉任何既有行（见 [logUpdateReplacesRows]），选区与菜单照常保留
  /// （TODO-1380「日志流追加期间菜单保持打开」）。无条件清（不看 [_hasSelection]）：
  /// 桌面单击留下的折叠选区 plainText 为空，同样持有下标。
  void _dropSelectionForReplacedRows() {
    _hasSelection = false;
    _selectionAreaKey.currentState?.selectableRegion.clearSelection();
  }

  // BUG-2715：上一次看到的视口主轴尺寸，用来从 ScrollMetricsNotification 里
  // 只挑出「视口本身变了」这一种（懒加载列表滚动时 maxScrollExtent 估值也会变，
  // 那由 [_dropStaleSelectionOnUserScroll] 管）。
  double? _lastViewportDimension;

  void _dropSelectionOnViewportResize(ScrollMetricsNotification notification) {
    final double viewport = notification.metrics.viewportDimension;
    final double? previous = _lastViewportDimension;
    _lastViewportDimension = viewport;
    if (previous == null || (previous - viewport).abs() < 0.5) return;
    _dropSelectionForReplacedRows();
  }

  // 整段 log 按行预切一次（不在 build 里反复 split），仅 widget.log 变化时重切。
  // ListView.builder 按 [_lines] 索引懒构造每行，只渲染视口内行。
  late List<String> _lines = _splitLines(widget.log);

  static List<String> _splitLines(String log) => log.split('\n');

  // TODO-1380/BUG-694：右键/长按菜单的自持锚点——面板内最近一次 pointer down 的
  // 全局坐标。框架的 SelectableRegionState.contextMenuAnchors 只在首帧用「右键
  // 位置」当锚点（用一次即清空），之后每次 toolbar 重建（选区几何变化 →
  // SelectionOverlay.markNeedsBuild → overlay entry 重建）都退回 glyph 路径，对
  // startSelectionPoint/endSelectionPoint 做空断言；而本面板是懒加载 ListView +
  // 持续追加的日志流，端点所在行可被滚动回收 / 内容更新 detach（框架
  // getSelectionGeometry 明说 detached/off-screen 时端点可为 null）→ 菜单重建
  // 即崩（Null check operator，崩溃栈见 docs/bugs/BUG-694）。菜单只能由面板内
  // 的一次 pointer down（右键 / 长按）召出，外层 Listener 先于 SelectionArea
  // 看到它；自持该坐标让每次重建都锚在召出位置，幂等且完全不依赖选区几何。
  Offset? _lastPointerDownGlobalPosition;

  @override
  void didUpdateWidget(covariant FushiLogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      final List<String> newLines = _splitLines(widget.log);
      // BUG-2715：既有行被换掉时先清选区再换行——此刻旧片段还在 registrar 里，
      // 清得干净。纯尾部追加不动既有行，保留选区。
      if (logUpdateReplacesRows(_lines, newLines)) {
        _dropSelectionForReplacedRows();
      }
      _lines = newLines;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // 「复制全部」不走 SelectionArea：ListView.builder 不构造视口外行，
  // SelectionArea 拿不到视口外行的 Selectable，「全选→复制」只能拿到当前
  // 视口内的几十行（TODO-762 回归，复核 af417805 实测 5000 行只复制到 38 行）。
  // 错误/调试日志页「复制整段去排障」是核心用途，所以「复制全部」直走
  // [widget.log] 全量、绕开 SelectionArea 的视口限制，保证一定拿到整段日志。
  Future<void> _copyAllToClipboard() async {
    // BUG-925：Windows 平台通道偶发把剪贴板 setData 抛成 PlatformException（剪贴板被
    // 其它进程独占 / 通道竞态）。这是「复制全部」的兜底入口，绝不能让一次复制失败把
    // 异常逃逸到 framework 顶层（与崩溃签名混淆）。失败时降级 debugPrint，不打断 UI。
    try {
      await Clipboard.setData(ClipboardData(text: widget.log));
    } catch (e) {
      debugPrint('[FushiLogPanel] copy-all to clipboard failed: $e');
    }
  }

  // 上下文菜单：覆盖框架默认的「复制」（只拿视口选区）语义。保留默认
  // 项里「全选」之外的那些行为不变，但额外提供两个走全量 [widget.log] 的入口：
  // 「复制全部」（复制整段日志）与「分享」（分享整段日志）。拖拽部分视口
  // 选区的默认「复制」仍可用（对可见内容有效）；但「全选语义」必须给全量。
  Widget _buildContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      // 增加「复制全部」入口：复制 widget.log 全量，不受视口限制。
      ContextMenuButtonItem(
        label: t.log_copy_all,
        onPressed: () {
          selectableRegionState.hideToolbar();
          _copyAllToClipboard();
        },
      ),
      ...selectableRegionState.contextMenuButtonItems,
      // 分享也用全量（错误/调试日志「分享整段去排障」是核心用途）。
      ContextMenuButtonItem(
        label: t.share,
        onPressed: () {
          selectableRegionState.hideToolbar();
          if (widget.log.isNotEmpty) widget.shareAction(widget.log);
        },
      ),
    ];
    // BUG-1438（与 BUG-129/261/381/781 同族）：[_lastPointerDownGlobalPosition] 是
    // 真实屏幕坐标，而本 toolbar 由 SelectionOverlay 挂进根 Overlay——后者落在全局
    // FushiAppUiScale 的 FittedBox 缩放画布内，锚点被当画布坐标解读。界面大小≠100%
    // 时工具条会偏到「右键点 × scale」处（离屏幕原点越远偏得越多）。经 Overlay 的
    // RenderBox 沿真实渲染变换链换算，缩放被 render transform 自动吸收；scale=1 时
    // 为单位阵，逐像素等价。
    final Offset rawAnchor = _lastPointerDownGlobalPosition ?? Offset.zero;
    final RenderBox? overlayBox =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final Offset anchor = overlayBox != null && overlayBox.hasSize
        ? overlayBox.globalToLocal(rawAnchor)
        : rawAnchor;
    return AdaptiveTextSelectionToolbar.buttonItems(
      // TODO-1380/BUG-694：锚点自持（[_lastPointerDownGlobalPosition]），不读
      // selectableRegionState.contextMenuAnchors——其 glyph 回退路径对选区端点
      // 空断言，toolbar 重建即崩。null 分支不可达（菜单必由面板内 pointer down
      // 召出），仅作类型收口。
      anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextStyle lineStyle = tokens.type.metadata.copyWith(
      color: tokens.surfaces.onSurface,
      fontFamily: 'monospace',
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: FushiCard(
          padding: EdgeInsets.zero,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Stack(
                children: <Widget>[
                  Listener(
                    onPointerDown: (PointerDownEvent event) {
                      // TODO-1380：先记全局坐标当菜单锚点（右键/长按也走这里，
                      // 见 [_lastPointerDownGlobalPosition]），再做主键判定。
                      _lastPointerDownGlobalPosition = event.position;
                      if (event.buttons & kPrimaryButton == 0) return;
                      _scrollController.beginPointerSelection();
                    },
                    onPointerMove: (PointerMoveEvent event) {
                      // 主键松开（拖拽选区结束）→ 解除拦截，恢复程序化滚动。
                      // TODO-822 后拖拽期间不再追踪指针几何，move 只需观测主键状态。
                      if (event.buttons & kPrimaryButton == 0) {
                        _scrollController.endPointerSelection();
                      }
                    },
                    onPointerUp: (_) => _scrollController.endPointerSelection(),
                    onPointerCancel: (_) =>
                        _scrollController.endPointerSelection(),
                    child: SelectionArea(
                      key: _selectionAreaKey,
                      contextMenuBuilder: _buildContextMenu,
                      // BUG-1582：记住「当前有没有选区」，供
                      // [_dropStaleSelectionOnUserScroll] 短路。不进 setState——
                      // 它不参与渲染，且选区变化本就每帧可发生。
                      onSelectionChanged: (SelectedContent? content) {
                        _hasSelection =
                            content != null && content.plainText.isNotEmpty;
                      },
                      child: NotificationListener<ScrollMetricsNotification>(
                        // BUG-2715：视口变高度（转屏 / 分屏）回收端点行。
                        onNotification:
                            (ScrollMetricsNotification notification) {
                          _dropSelectionOnViewportResize(notification);
                          return false;
                        },
                        child: NotificationListener<ScrollUpdateNotification>(
                          // BUG-1582：挂在 SelectionArea 与 ListView 之间——滚动
                          // 通知自下而上冒泡，这里既拿得到，又不会拦住外层。
                          onNotification:
                              (ScrollUpdateNotification notification) {
                            _dropStaleSelectionOnUserScroll(notification);
                            return false;
                          },
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: EdgeInsets.all(tokens.spacing.card),
                            itemCount: _lines.length,
                            itemBuilder: (BuildContext context, int index) {
                              // TODO-806/TODO-822：单行不换行（softWrap:false）。
                              // 换行会把一行日志拆成多视觉行 → SelectionArea 的单行
                              // 选区命中要对每段 wrap 后的子矩形逐一求交，命中成本随
                              // 行长放大（TODO-806 框选坐标错位、TODO-822 拖拽卡顿的
                              // 放大器）。日志是 monospace，超视口宽的长行在屏幕右侧
                              // 裁切（本列表只纵向滚动、无横向滚动层），看全整段走
                              // 下方常驻「复制全部」（拿 widget.log 未裁剪全量）。
                              //
                              // BUG-925：仅 softWrap:false 时，行 Text 的布局宽度 =
                              // 整行无界单行宽（ListView 只纵向滚动，水平方向没有约束
                              // 收口它）。SelectionArea 对这种无界宽度的 Selectable 做
                              // 命中测试 / getBoxesForSelection 时（单击 / 框选触发），
                              // 会对超出视口的极端横坐标求交，触发越界（与 BUG-413/423
                              // 同族坐标错位）→ 点一下调试日志文字就崩。把每行 Text 的
                              // 布局宽度钉死在视口可用宽度内（ConstrainedBox + ClipRect），
                              // Selectable 的矩形不再越界，同时保留逐行选择能力——超视口
                              // 的长行仍按原设计在右侧裁切（看全整段走「复制全部」）。
                              return ClipRect(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: constraints.maxWidth,
                                  ),
                                  child: Text(
                                    _lines[index],
                                    style: lineStyle,
                                    softWrap: false,
                                    overflow: TextOverflow.clip,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 始终可见的「复制全部」入口：复制 widget.log 全量、绕开
                  // SelectionArea 的视口限制，保证用户一定能拿到整段日志（不会
                  // 退化成只复制视口内的几十行）。
                  Positioned(
                    top: tokens.spacing.card,
                    right: tokens.spacing.card,
                    child: Tooltip(
                      message: t.log_copy_all,
                      // 设计系统分派：MD3 tonal 按压变形；Apple 浮在日志上的玻璃胶囊。
                      child: FushiFilledButton.tonalIcon(
                        onPressed: _copyAllToClipboard,
                        icon: const FushiIcon(Icons.copy_all_outlined, size: 18),
                        label: Text(t.log_copy_all),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// BUG-2715：一次日志更新是否会换掉某个**已有文字**的行（`_lines[i]` 非空且
/// 更新后该下标的文字不同或不复存在）。
///
/// 行 i 的 Text 内容一变，`RenderParagraph` 就把旧的选区片段从 registrar 移除，
/// 选区端点可能随之陈旧（见 [_FushiLogPanelState._dropSelectionForReplacedRows]）。
/// 空行不注册片段、新增行只是 add，都不会让端点陈旧——所以纯尾部追加（含「末尾
/// 空行被填上文字」）返回 false；新条目插在最前（错误 / 调试日志页的真实顺序）、
/// 截断、清空都返回 true。
bool logUpdateReplacesRows(List<String> oldLines, List<String> newLines) {
  for (int i = 0; i < oldLines.length; i++) {
    if (oldLines[i].isEmpty) continue;
    if (i >= newLines.length || newLines[i] != oldLines[i]) return true;
  }
  return false;
}

/// BUG-119 拽回判据的纯函数核心：在拖拽选区期间，决定是否放行一次程序化滚动
/// （`jumpTo` / `animateTo`）。从 [_LogSelectionScrollController._allowProgrammaticScroll]
/// 抽出，便于在 widget 渲染之外单测——把不变式钉死，防止有人把拦截逻辑掏空后
/// 结构守卫仍全绿（复核 ③ 指出旧守卫名存实亡）。
///
/// 规则（TODO-934——按滚动 API 区分边缘自动滚动 vs 键盘拽回）：
/// * 选区拖拽未激活 → 一律放行（非选区期的滚动不受影响）。
/// * 位移可忽略（<=0.5px）→ 放行（无实质滚动）。
/// * 选区拖拽激活 + 有实质位移 + 动画滚动（`animateTo`，[animated]=true）→ 放行：
///   这是 `EdgeDraggingAutoScroller` 的边缘自动滚动（拖到边区继续滚动延伸选区），
///   每帧步长被 SDK 钳在 ≤20px，不是一次跳到底。
/// * 选区拖拽激活 + 有实质位移 + 瞬跳滚动（`jumpTo`，[animated]=false）→ 拦截：
///   纯 SelectionArea + Text 结构下，拖拽框选期间唯一会瞬跳的程序化滚动是
///   `_ScrollableSelectionContainerDelegate._jumpToEdge`（键盘 granular/directional
///   扩展选区把视口往 extent 拽回，BUG-119 同源），拖拽期间一律拦掉。
///
/// TODO-934（调试日志框选拖到边区不响应）的根因修复：
/// BUG-423 当时一刀切「拖拽期一律拦掉程序化滚动」止住了卡死，代价是边缘自动滚动
/// 也被拦——拖到边区不再滚动延伸选区。但 BUG-423 把「Selectable 集合单调膨胀」当
/// 根因其实不准确：`ListView.builder` 离屏行会被回收（其 `Selectable` 从
/// `SelectionContainer` `remove()` 掉），`selectables` 大小被钉在「视口 + cacheExtent」
/// 内有界，不随滚动距离膨胀。真正的卡死放大器是 `softWrap:true` 长行——其
/// `RenderParagraph.getBoxesForSelection` 成本随该行换行成的视觉行数 O(N) 放大，
/// 而边缘自动滚动每帧持续重算选区几何。BUG-423 的 `softWrap:false` + BUG-448 的
/// `ConstrainedBox`+`ClipRect`（把每行布局宽度钉死在视口内）已经把每帧几何成本压成
/// O(视口可见内容)、与滚动距离无关——卡死链路已从根上断掉。因此可以安全恢复边缘
/// 自动滚动：放行 `animateTo`（有界一小步），仅保留拦掉 `jumpTo`（键盘拽回，纵深防御）。
///
/// 手动滚动（applyUserOffset / pointerScroll）不经本判据，不受影响。
bool logSelectionScrollDecision({
  required bool pointerSelectionActive,
  required double delta,
  required bool animated,
}) {
  if (!pointerSelectionActive) return true;
  if (delta.abs() <= 0.5) return true;
  // 动画滚动 = 边缘自动滚动（有界一小步），放行以延伸选区；
  // 瞬跳滚动 = 键盘拽回（_jumpToEdge），拖拽期一律拦。
  return animated;
}

class _LogSelectionScrollController extends ScrollController {
  _LogSelectionScrollController()
      : super(debugLabel: 'hibiki-log-selection-scroll');

  // 拖拽选区是否激活。这是 [logSelectionScrollDecision] 唯一需要的状态——
  // TODO-822 简化判据后不再追踪指针几何 / 手动滚动标志（边缘自动滚动整条拿掉，
  // 不存在按指针位置/方向区分的特殊情况）。
  bool _pointerSelectionActive = false;

  void beginPointerSelection() {
    _pointerSelectionActive = true;
  }

  void endPointerSelection() {
    _pointerSelectionActive = false;
  }

  /// 拖拽选区是否正在进行。面板据此区分「用户主动滚动」与「拖拽选区期间的边缘
  /// 自动滚动」——只有前者才丢弃失效选区（BUG-1582）。
  bool get pointerSelectionActive => _pointerSelectionActive;

  // [animated]=true 表示来自 animateTo（边缘自动滚动），false 表示来自 jumpTo
  // （键盘拽回）。判据据此放行边缘自动滚动、仅拦掉拽回（TODO-934）。
  bool _allowProgrammaticScroll(double targetOffset, {required bool animated}) {
    // 仅当当前确实附着了唯一 ScrollPosition 时才有「当前像素」可比对；否则
    // 无可拦截的拽回，直接放行（纯判据下沉到 [logSelectionScrollDecision]）。
    if (!hasClients || positions.length != 1) return true;
    return logSelectionScrollDecision(
      pointerSelectionActive: _pointerSelectionActive,
      delta: targetOffset - position.pixels,
      animated: animated,
    );
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _LogSelectionScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      controller: this,
    );
  }

  @override
  Future<void> animateTo(
    double offset, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!_allowProgrammaticScroll(offset, animated: true)) {
      return Future<void>.value();
    }
    return super.animateTo(offset, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    if (!_allowProgrammaticScroll(value, animated: false)) return;
    super.jumpTo(value);
  }
}

class _LogSelectionScrollPosition extends ScrollPositionWithSingleContext {
  _LogSelectionScrollPosition({
    required super.physics,
    required super.context,
    required super.oldPosition,
    required super.debugLabel,
    required this.controller,
  });

  final _LogSelectionScrollController controller;

  // 手动滚动（applyUserOffset / pointerScroll）不 override：它们是用户拖滚动条 /
  // 滚轮的入口，本就该照常生效，不经拦截判据。程序化滚动按 API 区分（TODO-934）：
  // animateTo = 边缘自动滚动（EdgeDraggingAutoScroller，放行以拖到边区延伸选区）、
  // jumpTo = 键盘 granular/directional 扩展的 _jumpToEdge 拽回（拖拽期拦掉）。
  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!controller._allowProgrammaticScroll(to, animated: true)) {
      return Future<void>.value();
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    if (!controller._allowProgrammaticScroll(value, animated: false)) return;
    super.jumpTo(value);
  }
}

class FushiEditorPanel extends StatelessWidget {
  const FushiEditorPanel({
    required this.controller,
    super.key,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.page),
      child: FushiCard(
        padding: EdgeInsets.zero,
        child: Stack(
          children: <Widget>[
            TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: tokens.type.listSubtitle.copyWith(
                color: tokens.surfaces.onSurface,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                // 嵌在卡片里的无框输入：不吃全局输入框主题的填充底。
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.all(tokens.spacing.card),
              ),
            ),
            Positioned(
              top: tokens.spacing.gap,
              right: tokens.spacing.gap,
              child: _hibikiTextFieldInputSuffix(
                    context: context,
                    controller: controller,
                  ) ??
                  const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class FushiPopupSurface extends StatelessWidget {
  const FushiPopupSurface({
    required this.child,
    super.key,
    this.color,
    this.padding = EdgeInsets.zero,
    this.elevation = 0,
    this.showBorder = true,
    this.clipBehavior = Clip.antiAlias,
    this.borderOnForeground = true,
    this.borderRadius,
    this.standaloneWindow = false,
  });

  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final double elevation;
  final bool showBorder;
  final Clip clipBehavior;

  /// 这块 surface 是一扇**独立窗口**的整窗面板（悬浮词典、全局查词窗）。
  ///
  /// Apple 设计系统下玻璃只能折射本窗口里自己画的像素，采不到窗口背后其它
  /// app 的画面——独立窗口里的玻璃只会是一块发灰的半透明板。这里改画不透明
  /// 的系统材质面板（调用方底色压成不透明，默认深 #1C1C1E / 浅白），保留 Apple
  /// 圆角与 1px separator 描边。MD3 不受影响。
  final bool standaloneWindow;

  /// Apple 浮层面板的默认圆角（iOS 26 弹出面板 / macOS 26 popover 在 12–16）。
  static const double _appleRadius = 14;

  /// 圆角覆写。默认 null = 走设计令牌的卡片圆角（10）。
  ///
  /// 唯一的现实用途是**贴边的 surface**：查词弹窗的底部 dock 面板铺满屏幕最左到最右
  /// （BUG-2439），此时左右两侧的圆角弧会在屏幕边缘露出背景，看起来就是「没铺满」。
  /// 贴哪条边就把那两个角摊平，别整块改令牌——其余 surface 的圆角是全局一致的。
  final BorderRadius? borderRadius;

  /// BUG-1692：描边画在子节点**之前**还是**之后**。
  ///
  /// 默认 true（Flutter [Material] 的默认值）时，描边走 `CustomPaint.foregroundPainter`，
  /// 在子节点之后绘制，且其 paint bounds 是**整个 surface**。当 surface 里装的是原生
  /// 平台视图（查词浮层的 WebView）时这是致命的：macOS engine 会把「平台视图之上
  /// 的 Flutter 绘制区域」逐 rect 写进 `FlutterMutatorView` 的 `_hitTestIgnoreRegion`，
  /// 落在其中的点 `hitTest:` 直接 return nil，于是**整块 WebView 收不到任何鼠标事件**
  /// ——用户看到的就是「查词框点哪都没反应」。
  ///
  /// 装平台视图的 surface 传 false，把描边挪到子节点之前绘制即可解除。纯 Flutter
  /// 子树无须改动（描边盖在不透明子节点上才需要 foreground）。
  ///
  /// BUG-2166：改成「之前绘制」的代价是**不透明的子节点会把描边整条盖掉**。查词浮层
  /// 的 WebView 铺满顶栏以下的整块 surface 且文档背景不透明，于是四边描边只剩顶栏那
  /// 一小段、以及圆角弧被 [clipBehavior] 裁出 WebView 的那几段还看得见——用户看到的
  /// 就是「查词框没包边」。修法见 [_borderInsetChild]：为 false 时把子节点沿描边内缩
  /// 一圈并按内圈半径再裁一次，描边环永远落在子节点之外，两个 bug 同时成立。
  final bool borderOnForeground;

  /// [BorderSide] 的默认笔宽，也是 [borderOnForeground] 为 false 时子节点内缩的量。
  static const double _borderWidth = 1;

  /// BUG-2166：描边画在子节点之前（[borderOnForeground] = false）时，给子节点让出
  /// 描边所占的那一圈——沿四边内缩 [_borderWidth]，再按**内圈**半径
  /// （`cardRadius - _borderWidth`）裁一次。不这样做，铺满 surface 的不透明子节点
  /// （查词浮层的 WebView）会把描边直边段整条盖住，只在圆角处漏出几段弧。
  ///
  /// 描边走 [BorderSide.strokeAlignInside]（[RoundedRectangleBorder] 的默认），
  /// 占 shape 内侧 `[0, _borderWidth]`，因此内缩一个笔宽即可完全避让。
  ///
  /// 描边仍画在子节点**之前**，BUG-1692 的 macOS 命中测试修复不受影响。
  Widget _borderInsetChild(
    FushiDesignTokens tokens,
    Widget content, {
    BorderRadius? outerRadius,
  }) {
    if (!showBorder || borderOnForeground) return content;
    return Padding(
      padding: const EdgeInsets.all(_borderWidth),
      child: ClipRRect(
        borderRadius: _deflate(outerRadius ?? _outerRadius(tokens)),
        child: content,
      ),
    );
  }

  BorderRadius _outerRadius(FushiDesignTokens tokens) =>
      borderRadius ?? tokens.radii.cardRadius;

  BorderRadius get _appleOuterRadius =>
      borderRadius ?? const BorderRadius.all(Radius.circular(_appleRadius));

  /// 内圈半径 = 外圈逐角减一个笔宽（摊平的角保持摊平，不会被减成负数）。
  static BorderRadius _deflate(BorderRadius outer) {
    Radius shrink(Radius r) => Radius.elliptical(
          math.max(0, r.x - _borderWidth),
          math.max(0, r.y - _borderWidth),
        );
    return BorderRadius.only(
      topLeft: shrink(outer.topLeft),
      topRight: shrink(outer.topRight),
      bottomLeft: shrink(outer.bottomLeft),
      bottomRight: shrink(outer.bottomRight),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 玻璃设计系统：浮层面换成 [GlassContainer]。装平台视图（查词 WebView）的
    // surface（[borderOnForeground] = false，BUG-1692 / BUG-2166）维持原路径：
    // 着色器层压在平台视图上会重新引出 macOS 命中测试被吞的老问题。
    final bool apple = isGlassDesign(context);
    if (apple && standaloneWindow) {
      // 独立窗口（见 [standaloneWindow]）：不透明系统材质面板 + 1px separator。
      // 走与 MD3 相同的 Material + [_borderInsetChild] 骨架，装平台视图
      // （[borderOnForeground] = false）时 BUG-1692 / BUG-2166 的修法照样成立。
      final bool dark =
          Theme.of(context).colorScheme.brightness == Brightness.dark;
      final BorderRadius radius = _appleOuterRadius;
      return Material(
        color: (color ??
                (dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF)))
            .withValues(alpha: 1),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: showBorder
              ? BorderSide(
                  color: appleColorsOf(context).separator,
                  width: _borderWidth,
                )
              : BorderSide.none,
        ),
        clipBehavior: clipBehavior,
        borderOnForeground: borderOnForeground,
        child: _borderInsetChild(
          tokens,
          Padding(padding: padding, child: child),
          outerRadius: radius,
        ),
      );
    }
    if (apple && borderOnForeground) {
      final BorderRadius radius = _appleOuterRadius;
      // Apple 浮层：圆角 14 的玻璃面板 + 1px separator 细描边（iOS 26 弹出
      // 面板 / macOS 26 popover 的发丝边，压在玻璃边缘高光上，浅色背景上也
      // 勾得出轮廓）。描边层恒在、[showBorder] 只换颜色。
      final Widget content = Padding(padding: padding, child: child);
      // 内部仍给一层透明 Material：浮层里常有依赖 Material 祖先的 MD3 子组件
      // （InkWell 等），去掉祖先会在它们身上抛断言。
      return DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: BorderSide(
              color: showBorder
                  ? appleColorsOf(context).separator
                  : Colors.transparent,
              width: _borderWidth,
            ),
          ),
        ),
        child: GlassContainer(
          // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
          useOwnLayer: true,
          shape: fushiGlassShapeOf(radius),
          quality: fushiGlassQuality(context, prominent: true),
          settings:
              color == null ? null : fushiGlassSettings(context, tint: color),
          clipBehavior: clipBehavior,
          child: Material(type: MaterialType.transparency, child: content),
        ),
      );
    }
    // MD3 浮层（2026-10-04）：surfaceContainer 面板 + 一层轻阴影（elevation 2，
    // 无 tint）把浮层从页面上托起来。描边刻意保留为柔和的 outlineVariant 细线：
    // 查词浮层常与页面同色（阅读器主题色灌进来），独立浮窗又直接压在桌面壁纸
    // 上——阴影在透明窗边缘被裁掉，边界只能靠这条线（BUG-2166「查词框没包边」、
    // BUG-818）。墨水屏不要阴影（灰阶抖动）。
    final bool eink = isEinkTheme(context);
    if (apple) {
      // Apple 查词浮层（装平台视图：查词 WebView，[borderOnForeground] = false）。
      // 液态玻璃画在 WebView **背后**（[_ApplePopupGlassBackdrop] 的背景槽），
      // WebView 文档在 Apple 设计系统下透明（popup.css `html.fushi-glass-host`），
      // 于是看到的就是玻璃 + 词条——与浏览器扩展页内弹窗同一观感。玻璃不能压在
      // WebView 之上（BUG-1692 macOS 命中测试被吞），所以描边也画在子节点之前、
      // 子节点内缩一圈（BUG-2166 同一修法）。
      final BorderRadius radius = _appleOuterRadius;
      return _ApplePopupGlassBackdrop(
        enabled: true,
        borderRadius: radius,
        panelColor: _applePanelColor(context),
        child: Material(
          color: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: showBorder
                ? BorderSide(
                    color: appleColorsOf(context).separator,
                    width: _borderWidth,
                  )
                : BorderSide.none,
          ),
          clipBehavior: clipBehavior,
          borderOnForeground: borderOnForeground,
          child: _borderInsetChild(
            tokens,
            Padding(padding: padding, child: child),
            outerRadius: radius,
          ),
        ),
      );
    }
    // MD3 查词浮层（装平台视图、非独立窗）同样是玻璃材质，与浏览器扩展页内弹窗
    // 同一组参数（用户 2026-10-04：「查词框要和浏览器扩展一样有液态玻璃材质」，
    // 扩展在任何主题下都是玻璃）：面板色（主色 5% 淡染）亮 90% / 暗 88% + 20 模糊，
    // 画在 WebView 背后（[_ApplePopupGlassBackdrop] 背景槽），WebView 文档透明
    // （popup.css `html.fushi-glass-host`）。Material 改透明、去掉 elevation 投影
    // ——半透明面上的阴影会透出来把玻璃压脏——轮廓靠 outlineVariant 细线。
    // 墨水屏、独立窗（standaloneWindow：背后是别的 app，BUG-818 要求不透明）照旧实色。
    // 结构恒定：两种情况都挂在同一个 Stack 槽位里，切换时 WebView 不会被拆出重挂；
    // 纯 Flutter 浮层（foreground 描边）不受影响。
    final bool md3Glass = !borderOnForeground && !eink && !standaloneWindow;
    final Widget md3 = Material(
      color: md3Glass ? Colors.transparent : (color ?? tokens.surfaces.card),
      elevation: md3Glass ? 0 : (eink || elevation > 0 ? elevation : 2),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: _outerRadius(tokens),
        side: showBorder
            ? BorderSide(color: tokens.surfaces.outline, width: _borderWidth)
            : BorderSide.none,
      ),
      clipBehavior: clipBehavior,
      borderOnForeground: borderOnForeground,
      child: _borderInsetChild(
        tokens,
        Padding(
          padding: padding,
          child: child,
        ),
      ),
    );
    if (borderOnForeground) return md3;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return _ApplePopupGlassBackdrop(
      enabled: md3Glass,
      md3: true,
      borderRadius: _outerRadius(tokens),
      panelColor: Color.alphaBlend(
        scheme.primary.withValues(alpha: 0.05),
        (color ?? scheme.surfaceContainer).withValues(alpha: 1),
      ),
      child: md3,
    );
  }

  /// Apple 查词面板的材质底色：调用方传主题页面底（`colorScheme.surface` =
  /// systemGroupedBackground，深色是纯黑）或不传时，取浮层惯用的
  /// secondarySystemGroupedBackground（浅白 / 深 #1C1C1E，iOS 26 popover 的
  /// 材质色）；用户手动指定的词典底色（overrideDictionaryColor）原样尊重。
  Color _applePanelColor(BuildContext context) {
    final Color? requested = color;
    if (requested == null ||
        requested == Theme.of(context).colorScheme.surface) {
      return appleColorsOf(context).secondaryGroupedBackground;
    }
    return requested;
  }
}

/// 所有查词浮层层（第一层 / 热槽与每一层嵌套）的 BackdropFilter 共用的背景快照
/// key。等价于在所有浮层的公共祖先挂一个 [BackdropGroup]，但浮层宿主有六处
/// （视频 / 网页视频 / 阅读器 / 查词页 / texthooker / 悬浮歌词），各自的 Stack 里
/// 浮层是 [Positioned] 直接子项，用一个全局 key 让它们无需改宿主结构就进同一组。
/// 只有 Impeller 认这个 key（同 key 的滤镜共用第一次读到的背景，子层模糊的是正文
/// 而不是下面那层查词卡）；Skia 后端忽略它。
final BackdropKey kFushiLookupPopupBackdropKey = BackdropKey();

/// Apple 查词浮层的玻璃背衬（[FushiPopupSurface] 装平台视图时用）。
///
/// 与 [FushiGlassBackdrop] 同一形态（Stack 兄弟层、passthrough、[enabled] 为
/// false 时背景槽是空盒），区别在材质参数：查词面板背后是正文（阅读器 /
/// 视频 / 漫画 / 上一层查词卡），要读得清词条，所以不用控件层那种几乎透明的
/// 薄玻璃，而是「面板底色 亮 90% / 暗 88% + 20 模糊」。
///
/// 逐平台（[fushiPopupBackdropSampleable]）：Windows / Linux 的 WebView 以纹理
/// 合成进 Flutter 场景，采得到背后的正文，是真玻璃；iOS / macOS 背后的正文是
/// 原生平台视图，Android 的阅读器 WebView 走 Hybrid Composition（真 Android
/// View，Flutter 画在它上面的层是独立 overlay surface），都采不到，半透明填充
/// 只会把下面的字原样透出来，所以直接画**不透明**面板 + 发丝描边（iOS / macOS
/// 另有原生系统材质，见 [_buildNativeMaterial]）。降低透明度 / 高对比度 / 墨水屏
/// 同样不透明、零模糊。
class _ApplePopupGlassBackdrop extends StatelessWidget {
  const _ApplePopupGlassBackdrop({
    required this.enabled,
    required this.borderRadius,
    required this.panelColor,
    required this.child,
    this.md3 = false,
  });

  final bool enabled;

  /// MD3 版：Flutter 自己的 [BackdropFilter] 磨砂（不走 liquid_glass 的高光 /
  /// 折射，MD3 没有那套光照语言）。iOS / macOS / Android 背后是原生平台视图、
  /// 采不到，直接画不透明面板色。
  final bool md3;
  final BorderRadius borderRadius;
  final Color panelColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: enabled ? _buildGlass(context) : const SizedBox.shrink(),
        ),
        child,
      ],
    );
  }

  Widget _buildGlass(BuildContext context) {
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final Color opaque = panelColor.withValues(alpha: 1);
    if (fushiGlassOverPlatformView(context) &&
        fushiNativePopupMaterialAvailableOf(context)) {
      return _buildNativeMaterial(context, dark: dark);
    }
    // 查词面板压在**正文文字**上（阅读器 / 视频字幕 / 上一层查词卡），可读性优先：
    // - 采不到背后画面（iOS / macOS 背后是原生 WebView 平台视图；Android 的 WebView
    //   是 Hybrid Composition 原生 View，BackdropFilter 与着色器都采不到，半透明
    //   填充只会把下面的字原样透出来——用户报「Mac 上嵌套查词很透明」）、降低透明度、
    //   高对比度、墨水屏：一律不透明面板；
    // - 能真模糊（Windows / Linux，WebView 以纹理合成进 Flutter 场景）：
    //   面板色 亮 90% / 暗 88% + 20 模糊。这是用户 2026-10-05 认定「刚好」的观感
    //   （从当时截图反推有效 alpha ≈ 0.89；0.66 / 0.72 被嫌太透）。
    //   每一层嵌套查词都用这同一组参数（用户 2026-10-05 拍板「每层都和第一层一样」），
    //   且所有查词层的 BackdropFilter 共用一个 [kFushiLookupPopupBackdropKey]：
    //   Impeller 下同 key 的滤镜共用一张背景快照，子层模糊的是正文而不是下面那层
    //   查词卡（玻璃叠玻璃不会一层比一层实）。Skia 后端（Windows / Linux 默认）忽略
    //   这个 key，那里各层只是参数一致。
    //   MD3 的玻璃材质档恒为 off（[FushiGlassTheme.material] 只在玻璃设计系统下
    //   非 off），所以 MD3 直接问系统「降低透明度」；Apple 问材质档（已扣除它）。
    final bool transparencyAllowed = md3
        ? !SystemTransparency.reduceTransparency.value
        : glassMaterialOf(context) != FushiGlassMaterial.off;
    final bool realBlur = fushiPopupBackdropSampleable(context) &&
        transparencyAllowed &&
        !(MediaQuery.maybeHighContrastOf(context) ?? false) &&
        !isEinkTheme(context);
    final Color fill =
        realBlur ? opaque.withValues(alpha: dark ? 0.88 : 0.9) : opaque;
    // 玻璃设计系统的「毛玻璃」档（frosted）与 MD3 同走 BackdropFilter，才能进同一个
    // 背景快照组；液态玻璃着色器（liquid_glass_widgets）每个 GlassContainer 自带
    // 私有 BackdropGroup，进不了跨层的组。
    if (md3 ||
        (realBlur && glassMaterialOf(context) == FushiGlassMaterial.frosted)) {
      return IgnorePointer(
        child: ClipRRect(
          borderRadius: borderRadius,
          child: realBlur
              ? BackdropFilter(
                  backdropGroupKey: kFushiLookupPopupBackdropKey,
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: ColoredBox(color: fill),
                )
              : ColoredBox(color: opaque),
        ),
      );
    }
    if (!realBlur) {
      // 不走玻璃着色器：它在平台视图上的回落只管「采样为空」的像素，采到的是透明
      // 平台视图区时仍按半透明合成。直接画实色系统材质面板。
      return IgnorePointer(
        child: ClipRRect(
          borderRadius: borderRadius,
          child: ColoredBox(color: opaque),
        ),
      );
    }
    return IgnorePointer(
      child: GlassContainer(
        useOwnLayer: true,
        shape: LiquidRoundedRectangle(borderRadius: borderRadius.topLeft.x),
        quality: fushiGlassQuality(context, prominent: true),
        settings: fushiGlassSettingsOverPlatformView(context, tint: fill)
            .copyWith(blur: 20, platformViewFallbackColor: opaque),
        platformViewBackdrop: fushiGlassOverPlatformView(context),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// iOS / macOS 真模糊：弹窗 WebView 下方垫原生系统材质
  /// （[FushiNativeMaterialBackdrop]：macOS `NSVisualEffectView` `.withinWindow` /
  /// iOS `UIVisualEffectView`），系统合成器在窗口内模糊背后的阅读器 WKWebView
  /// ——Flutter 的 [BackdropFilter] 采不到原生平台视图，这条路采得到。
  ///
  /// - MD3：材质上叠一层面板色（主色 5% 淡染的 surfaceContainer）低 alpha 色层，
  ///   面板仍读作 MD3 的配色；Apple：纯系统材质，只有用户手动指定的词典底色才淡染。
  /// - 投影只画在形状**外侧**（[_PopupOuterShadowPainter]）：画进形状内会被材质
  ///   采样、把模糊整块压暗。它画在原生视图之前（同一 Stack 的更低层），不会给
  ///   平台视图挖 hit-test 忽略区（BUG-1692）。
  Widget _buildNativeMaterial(BuildContext context, {required bool dark}) {
    final Color appleDefault = appleColorsOf(context).secondaryGroupedBackground;
    // 嵌套层与第一层同一材质 / 色层（用户 2026-10-05 拍板）。
    final Color? tint = md3
        ? panelColor.withValues(alpha: dark ? 0.42 : 0.38)
        : (panelColor.withValues(alpha: 1) == appleDefault.withValues(alpha: 1)
            ? null
            : panelColor.withValues(alpha: 0.4));
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: <Widget>[
        IgnorePointer(
          child: CustomPaint(
            painter: _PopupOuterShadowPainter(
              borderRadius: borderRadius,
              color: Colors.black.withValues(alpha: dark ? 0.45 : 0.18),
            ),
          ),
        ),
        FushiNativeMaterialBackdrop(
          dark: dark,
          borderRadius: borderRadius.topLeft.x,
          continuousCorners: !md3,
          tint: tint,
        ),
      ],
    );
  }
}

/// 只画在圆角矩形**外侧**的柔和投影（内侧裁掉）：原生材质会采样它背后的一切，
/// 画进形状内的阴影会被模糊进面板、把材质整体压暗。
class _PopupOuterShadowPainter extends CustomPainter {
  const _PopupOuterShadowPainter({
    required this.borderRadius,
    required this.color,
  });

  final BorderRadius borderRadius;
  final Color color;

  static const double _blurSigma = 12;
  static const double _offsetY = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect shape = borderRadius.toRRect(Offset.zero & size);
    final Rect bounds = (Offset.zero & size).inflate(_blurSigma * 3 + _offsetY);
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(bounds),
        Path()..addRRect(shape),
      ),
    );
    canvas.drawRRect(
      shape.shift(const Offset(0, _offsetY)),
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _blurSigma),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PopupOuterShadowPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius || oldDelegate.color != color;
}

class FushiCompactSearchRow extends StatelessWidget {
  const FushiCompactSearchRow({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onSubmit,
    super.key,
    this.onClose,
    this.fieldKey,
    this.closeButtonKey,
    this.searchButtonKey,
    this.hintLocales,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onClose;
  final Key? fieldKey;
  final Key? closeButtonKey;
  final Key? searchButtonKey;

  /// 希望输入法切到哪种语言（Android `EditorInfo.hintLocales`，API 24+）。
  ///
  /// 由调用方从「查词输入法语言」偏好算出来传进来（`AppModel.lookupImeHintLocales`），组件
  /// **不自己读设置**：这几个组件被大量无 ProviderScope 的 widget 测试直接 pump，
  /// 往 build 路径里加 Riverpod 读取会让整页 build 抛。
  final List<Locale>? hintLocales;

  void _submit() {
    final String query = controller.text.trim();
    if (query.isEmpty) return;
    onSubmit(query);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String closeTooltip =
        MaterialLocalizations.of(context).closeButtonTooltip;
    final Widget? keyboardSuffix = _hibikiTextFieldInputSuffix(
      context: context,
      controller: controller,
    );
    // 与 [FushiSearchField] 同一形态语言：两套设计系统都是全圆角胶囊（MD3 填充
    // 胶囊 surfaceContainerHigh；Apple 是无底胶囊 + 发丝分隔线描边——搜索框是
    // 控件层，不铺 systemFill 灰块；它常压在查词弹窗的平台视图旁，着色器玻璃
    // 会采到黑底，所以这里不用玻璃，只留描边）。
    final bool apple = isGlassDesign(context);
    return FushiCard(
      color: apple ? Colors.transparent : tokens.surfaces.search,
      borderColor: apple ? appleColorsOf(context).separator : null,
      borderRadius: const BorderRadius.all(Radius.circular(22)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 44,
        child: Row(
          children: <Widget>[
            if (onClose != null)
              _CompactSearchIconButton(
                key: closeButtonKey,
                icon: Icons.close,
                tooltip: closeTooltip,
                onPressed: onClose!,
              ),
            Expanded(
              child: TextField(
                key: fieldKey,
                controller: controller,
                focusNode: focusNode,
                style: tokens.type.listTitle,
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: tokens.type.listSubtitle,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  // 嵌在卡片里的无框输入：不吃全局输入框主题的填充底。
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                hintLocales: hintLocales,
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (keyboardSuffix != null) keyboardSuffix,
            _CompactSearchIconButton(
              key: searchButtonKey,
              icon: Icons.search,
              tooltip: MaterialLocalizations.of(context).searchFieldLabel,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactSearchIconButton extends StatelessWidget {
  const _CompactSearchIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      width: 36,
      height: 36,
      child: FushiIconButton(
        icon: icon,
        enabledColor: tokens.surfaces.onVariant,
        size: 20,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onTap: onPressed,
      ),
    );
  }
}

/// [FushiSchemeSwatch] 的微缩界面：页面底色上一条顶栏、两条文字线与一枚
/// 强调色胶囊按钮，比例随色板尺寸缩放。
@visibleForTesting
class SchemeMiniUiPainter extends CustomPainter {
  const SchemeMiniUiPainter({
    required this.textColor,
    required this.backgroundColor,
    required this.buttonColor,
    required this.barColor,
  });

  final Color textColor;
  final Color backgroundColor;
  final Color buttonColor;
  final Color barColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Paint paint = Paint()..isAntiAlias = true;
    canvas.drawRect(Offset.zero & size, paint..color = backgroundColor);
    // 顶栏：菜单 / 卡片面色，带一枚强调色小圆点（导航选中的暗示）。
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h * 0.24), paint..color = barColor);
    canvas.drawCircle(
      Offset(w * 0.16, h * 0.12),
      h * 0.045,
      paint..color = buttonColor,
    );
    RRect line(double top, double width, double height) => RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.12, top, w * width, height),
      Radius.circular(height / 2),
    );
    canvas.drawRRect(
      line(h * 0.36, 0.62, h * 0.075),
      paint..color = textColor.withValues(alpha: 0.9),
    );
    canvas.drawRRect(
      line(h * 0.50, 0.44, h * 0.06),
      paint..color = textColor.withValues(alpha: 0.42),
    );
    // 强调色胶囊按钮。
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.12, h * 0.68, w * 0.42, h * 0.16),
        Radius.circular(h * 0.08),
      ),
      paint..color = buttonColor,
    );
  }

  @override
  bool shouldRepaint(SchemeMiniUiPainter old) =>
      old.textColor != textColor ||
      old.backgroundColor != backgroundColor ||
      old.buttonColor != buttonColor ||
      old.barColor != barColor;
}
