import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart'
    show MacosSwitch, MacosSlider, PushButton, ControlSize;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart'
    show FushiAppleColors, appleColorsOf;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton, FushiTextButton;
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart'
    show FushiExpressiveLoadingIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show
        FushiAppleProgressRing,
        FushiCircularProgressIndicator,
        fushiAppleActivityIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSegmentedButton, FushiSlider, FushiSwitch;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedSuperellipse;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

Widget adaptiveDialogAction({
  required BuildContext context,
  required VoidCallback? onPressed,
  required Widget child,
  bool isDestructiveAction = false,
  bool isDefaultAction = false,
}) {
  // Apple 设计系统（偏好值 glass）：对话框动作是实色胶囊（自带焦点环 +
  // Enter → ActivateIntent）。默认动作 = 强调色实底；破坏性 = 系统灰胶囊 +
  // destructive 红字（iOS / macOS 的破坏性按钮从不铺粉色 / 红色底）；其余 =
  // 系统灰胶囊（取消类）。
  if (isGlassDesign(context)) {
    if (isDestructiveAction) {
      return FushiFilledButton.tonal(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          foregroundColor: appleColorsOf(context).destructive,
        ),
        child: child,
      );
    }
    if (isDefaultAction) {
      return FushiFilledButton(onPressed: onPressed, child: child);
    }
    return FushiFilledButton.tonal(onPressed: onPressed, child: child);
  }
  // macOS-native: PushButton is the standard dialog button. Default action =
  // filled primary; destructive = error-tinted; everything else = secondary
  // (the grey Cancel-style button). Checked before isCupertinoPlatform (macOS
  // auto answers true there as the legacy fallback).
  if (isMacosPlatform(context)) {
    if (isDestructiveAction) {
      return PushButton(
        controlSize: ControlSize.large,
        color: Theme.of(context).colorScheme.error,
        onPressed: onPressed,
        child: child,
      );
    }
    return PushButton(
      controlSize: ControlSize.large,
      secondary: !isDefaultAction,
      onPressed: onPressed,
      child: child,
    );
  }
  if (isCupertinoPlatform(context)) {
    return CupertinoDialogAction(
      onPressed: onPressed,
      isDestructiveAction: isDestructiveAction,
      isDefaultAction: isDefaultAction,
      child: child,
    );
  }
  // M3 Expressive（2026-10-05 浮层统一）：主操作 filled、破坏性 error 实底
  // filled、其余 text；全部走 Fushi* 按钮，按下有 M3E 形状变形回弹。
  if (isDestructiveAction) {
    final cs = Theme.of(context).colorScheme;
    return FushiFilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: cs.error,
        foregroundColor: cs.onError,
      ),
      child: child,
    );
  }
  if (isDefaultAction) {
    return FushiFilledButton(
      onPressed: onPressed,
      child: child,
    );
  }
  return FushiTextButton(
    onPressed: onPressed,
    child: child,
  );
}

Widget adaptiveSwitch({
  required BuildContext context,
  required bool value,
  required ValueChanged<bool>? onChanged,
  Color? activeColor,
}) {
  if (isGlassDesign(context)) {
    // Apple 设计系统：委托给 FushiSwitch 的 Apple 开关（与 FushiSwitch 调用点
    // 同一个观感：强调色轨 + onAccent 圆钮、关态 systemFill 灰轨）。禁用态由它
    // 自己表达（不可点、不可聚焦、半透明），与 MD3 Switch(onChanged: null) 同语义。
    return FushiSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: activeColor,
    );
  }
  // macOS-native: MacosSwitch is a clean drop-in (nullable onChanged handles the
  // disabled state, activeColor maps 1:1). Checked BEFORE isCupertinoPlatform
  // because under `auto` macOS still answers true there as the legacy fallback.
  if (isMacosPlatform(context)) {
    // Let MacosSwitch use the system accent for its active track — that's the
    // native macOS look, more correct than forcing the app's activeColor (which
    // is a Material/Cupertino Color, not macos_ui's MacosColor anyway).
    return MacosSwitch(
      value: value,
      onChanged: onChanged,
    );
  }
  if (isCupertinoPlatform(context)) {
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: activeColor ?? CupertinoTheme.of(context).primaryColor,
    );
  }
  return Switch(
    value: value,
    onChanged: onChanged,
    activeColor: activeColor,
  );
}

Widget adaptiveSlider({
  required BuildContext context,
  required double value,
  required ValueChanged<double>? onChanged,
  double min = 0.0,
  double max = 1.0,
  int? divisions,
  String? label,
  Color? thumbColor,
  ValueChanged<double>? onChangeStart,
  ValueChanged<double>? onChangeEnd,
}) {
  if (isGlassDesign(context)) {
    // Apple 设计系统：委托给 FushiSlider 的 Apple 滑块（细轨 + 白色圆钮，方向键
    // 与语义增减齐全），与 FushiSlider 调用点同一个观感。
    return FushiSlider(
      value: value,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      thumbColor: thumbColor,
    );
  }
  // macOS-native: MacosSlider has no onChangeEnd/onChangeStart/divisions, so a
  // thin wrapper re-creates the commit-on-drag-end contract the settings sliders
  // rely on (e.g. app UI scale). Only when interactive — a null onChanged means
  // disabled, which MacosSlider can't express (its onChanged is non-nullable),
  // so we fall through to the Cupertino disabled slider for that case.
  if (isMacosPlatform(context) && onChanged != null) {
    return _MacosSliderWithDragCallbacks(
      value: value.clamp(min, max).toDouble(),
      min: min,
      max: max,
      divisions: divisions,
      color: Theme.of(context).colorScheme.primary,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
    );
  }
  if (isCupertinoPlatform(context)) {
    return CupertinoSlider(
      value: value,
      onChanged: onChanged,
      min: min,
      max: max,
      divisions: divisions,
      thumbColor: thumbColor ?? CupertinoColors.white,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
    );
  }
  final Widget slider = Slider(
    value: value,
    onChanged: onChanged,
    min: min,
    max: max,
    divisions: divisions,
    label: label,
    thumbColor: thumbColor,
    onChangeStart: onChangeStart,
    onChangeEnd: onChangeEnd,
  );
  // 值指示器水平钳制根因修复（见 slider_value_indicator_scale_test.dart）：
  // Material Slider 的 getHorizontalShift 用 parentBox.localToGlobal(center)（GLOBAL/
  // view 坐标，含 Transform.scale 的 ×s）与 sizeWithOverflow(= MediaQuery.sizeOf) 比较，
  // SDK 假定两者同空间。FushiAppUiScale 把树放大 s 倍、却把 MediaQuery.size 缩成 view/s，
  // 两空间差 s²，钳制甩飞气泡。这里把 Slider 看到的 screenSize 还原回 GLOBAL/view 空间
  // (= size * scale)，与 localToGlobal 同空间，钳制即正确归零。scale==1.0 为 no-op。
  // 只改 size（保留 textScaler 等），且 Slider 布局宽度来自父约束、不依赖 MediaQuery.size，
  // 故仅影响值指示器钳制这一条买路。
  final double uiScale = FushiAppUiScale.of(context);
  if (uiScale == FushiAppUiScale.defaultScale) return slider;
  final MediaQueryData mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(size: mq.size * uiScale),
    child: slider,
  );
}

/// [value] 非空时画**确定**进度（0..1）；为空时是原本的不确定动画。两个平台分支都
/// 认这个值，避免「Material 显进度、Cupertino 一直转」的静默分歧。
///
/// eink 下不确定态改成一枚静止的沙漏：转圈是永不停歇的动画，墨水屏上等于那一小块
/// 持续局部刷新（闪烁 + 残影）；确定进度照常画环（一次一格、不连续重绘）。
Widget adaptiveIndicator({
  required BuildContext context,
  Color? color,
  double? strokeWidth,
  double? value,
}) {
  if (value == null && isEinkTheme(context)) {
    // 这是全局 helper：不少调用点把它包在 14~20 px 的 tight SizedBox 里（Anki
    // 配置行、字幕重匹配、阅读器快捷设置……），父约束会把 36 压到 16 而 24 px 的
    // 字形不缩，裁成残缺一角。FittedBox.scaleDown 让沙漏随容器缩、无约束时不放大。
    return SizedBox(
      width: 36,
      height: 36,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: FushiIcon(
          Icons.hourglass_top,
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
  if (isGlassDesign(context)) {
    // Apple 设计系统：不确定态是 iOS / macOS 的菊花（系统灰，常规半径 10）；
    // 确定进度是细圆环（强调色进度 + systemFill 底环、圆头）。都不是玻璃——
    // 进度指示是内容，不是浮层控件。36 的默认外框：调用点常把它塞进 14~20 的
    // tight SizedBox，紧约束下跟着缩、无约束时不放大。
    if (value == null) {
      return fushiAppleActivityIndicator(
        context,
        color: color,
        radius: strokeWidth != null ? strokeWidth * 2.5 : null,
      );
    }
    final FushiAppleColors apple = appleColorsOf(context);
    return SizedBox.square(
      dimension: 36,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: FushiAppleProgressRing(
            value: value.clamp(0.0, 1.0),
            color: color ?? apple.accent,
            trackColor: apple.fill,
            strokeWidth: strokeWidth ?? 3,
          ),
        ),
      ),
    );
  }
  if (isCupertinoPlatform(context)) {
    final double radius = strokeWidth != null ? strokeWidth * 2.5 : 10.0;
    if (value != null) {
      return CupertinoActivityIndicator.partiallyRevealed(
        color: color,
        radius: radius,
        progress: value.clamp(0.0, 1.0),
      );
    }
    return CupertinoActivityIndicator(color: color, radius: radius);
  }
  // MD3：Material 3 Expressive。不定态是 LoadingIndicator（主色形状连续变形 +
  // 旋转），确定态是波浪进度环；都放进与 M3 2024 版原控件相同的 40 外框，
  // 紧约束下等比缩小、无约束时不放大。
  if (value == null) {
    return SizedBox.square(
      dimension: 40,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: FushiExpressiveLoadingIndicator(size: 40, color: color),
        ),
      ),
    );
  }
  return FushiCircularProgressIndicator(
    color: color,
    strokeWidth: strokeWidth ?? 4.0,
    value: value,
  );
}

/// 全应用唯一的底部弹层入口（同一 API 按设计系统 / 宽度自适应）：
/// - Apple：iOS 26 悬浮玻璃 sheet（移动）/ macOS 26 顶部垂下的 sheet（桌面）；
/// - Material（M3 Expressive）窄屏（< 600）：上两角 28 的底部弹层，自绘拖动条
///   （48 交互区 + 32×4 横条）、弹簧进出、软键盘弹出时整体抬升、高度封顶 92%
///   屏高（不压进状态栏）；[expandable] 时两档高度——先停在半屏（55%），拖动条
///   上拉 / 点按展开到 92%，下拉收回 / 关闭。拖动条之外的内容区照常滚动，
///   滚动与拖拽互不抢手势；
/// - Material 宽屏（≥ 600）：改为居中浮动面板（圆角 28、最宽 640、最高 86%），
///   与对话框同一条弹簧缩放进出、同一 scrim；内容外包 [FushiDialogScope]，
///   [FushiModalSheetFrame] 随之按对话框规范排版。
/// 两种形态都是模态路由：Esc / 手柄 B / 点遮罩关闭，关闭后焦点回到打开前。
Future<T?> adaptiveModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool showDragHandle = true,
  bool useSafeArea = false,
  bool expandable = false,
}) {
  if (isCupertinoPlatform(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: builder,
    );
  }
  final bool noMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final AnimationStyle sheetMotion = noMotion
      ? AnimationStyle.noAnimation
      : fushiM3eSheetAnimationStyle;
  if (isGlassDesign(context)) {
    final TargetPlatform platform = Theme.of(context).platform;
    final bool desktop =
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
    if (desktop) {
      // macOS 26 sheet：从窗口顶部正中垂下的实色面板（宽 480–640、圆角 18、
      // 大半径柔和阴影），不是底部抽屉。走 RawDialogRoute：Esc（DismissIntent）
      // 关闭、点遮罩关闭、独立焦点作用域、pop 返回值与底部弹层一致。
      return showGeneralDialog<T>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        barrierColor: Colors.black.withValues(alpha: 0.18),
        transitionDuration: noMotion
            ? Duration.zero
            : const Duration(milliseconds: 260),
        pageBuilder:
            (
              BuildContext sheetContext,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
            ) => _AppleDesktopSheet(child: builder(sheetContext)),
        transitionBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              final Animation<double> curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.08),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              );
            },
      );
    }
    // iOS 26 sheet：四周内缩的悬浮液态玻璃面板（左右下留 8、圆角 34），拖动条
    // 上拉到 large（≈92% 屏高）时贴边、玻璃转为实色 secondaryGroupedBackground，
    // 下拉回到 medium / 关闭。BottomSheet 只剩路由 / 拖拽关闭职责，自身透明。
    // 不用库的 GlassModalSheet：它按固定 detent 高度排版（短确认框也会被撑到
    // 45%），且自带路由，Esc / 焦点作用域 / isScrollControlled 语义都要重接。
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      constraints: const BoxConstraints(),
      barrierColor: Colors.black.withValues(alpha: 0.2),
      sheetAnimationStyle: sheetMotion,
      builder: (BuildContext sheetContext) => _LiquidSheetBody(
        showDragHandle: showDragHandle,
        child: builder(sheetContext),
      ),
    );
  }
  final bool frosted = glassMaterialOf(context) != FushiGlassMaterial.off;
  if (MediaQuery.sizeOf(context).width >= kFushiSheetWideBreakpoint) {
    final NavigatorState navigator = Navigator.of(context);
    return navigator.push<T>(
      FushiDialogRoute<T>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: fushiModalScrimColor(context),
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        reduceMotion: noMotion || !fushiMotionEnabled(context),
        builder: (BuildContext sheetContext) => FushiM3eFloatingSheet(
          frosted: frosted,
          child: builder(sheetContext),
        ),
      ),
    );
  }
  if (frosted) {
    // 毛玻璃：BottomSheet 自己的底色让位，表面交给 FushiGlassSurface。拖动条
    // 由 BottomSheet 画在 child 之外，底色透明后会悬在未模糊的内容上，所以这里
    // 关掉它、在玻璃里按 M3 同一几何（48 高交互区 + 32x4 横条）自己画。
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      sheetAnimationStyle: sheetMotion,
      builder: (BuildContext sheetContext) => _GlassSheetBody(
        showDragHandle: showDragHandle,
        child: FushiM3eSheetBody(
          showDragHandle: false,
          expandable: false,
          child: builder(sheetContext),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    // 拖动条由 [FushiM3eSheetBody] 自绘（同 M3 几何），两档高度要接它的手势。
    showDragHandle: false,
    sheetAnimationStyle: sheetMotion,
    builder: (BuildContext sheetContext) => FushiM3eSheetBody(
      showDragHandle: showDragHandle,
      expandable: expandable,
      child: builder(sheetContext),
    ),
  );
}

/// Apple 设计系统的移动端底部弹层（iOS 26 sheet）。
///
/// - medium（默认）：四周内缩的悬浮液态玻璃面板——左右与底部留 8、圆角 34
///   （贴着屏幕圆角的观感），高度随内容（受路由的 isScrollControlled 约束）；
/// - large：拖动条上拉切过去，面板贴边（左右下 0、上两角保留 34），高 ≈92%
///   屏高，玻璃转为实色 secondaryGroupedBackground（iOS 全高 sheet 不透底）；
/// - 拖动条 36×5 tertiaryLabel；在拖动条上下拉：large → medium，medium →
///   关闭（与 BottomSheet 自身的整块下拉关闭并存）。
/// 系统降低透明度（材质 off）时 medium 也是实色；系统关闭动画时切换无过渡。
/// 内容外包一层透明 Material，弹层里依赖 Material 祖先的子组件照常工作。
class _LiquidSheetBody extends StatefulWidget {
  const _LiquidSheetBody({required this.showDragHandle, required this.child});

  final bool showDragHandle;
  final Widget child;

  @override
  State<_LiquidSheetBody> createState() => _LiquidSheetBodyState();
}

class _LiquidSheetBodyState extends State<_LiquidSheetBody> {
  static const double _margin = 8;
  static const double _radius = 34;
  static const double _largeFraction = 0.92;

  bool _large = false;
  double _dragDy = 0;

  void _onDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;
    final double dy = _dragDy;
    _dragDy = 0;
    if (dy < -40 || velocity < -600) {
      if (!_large) setState(() => _large = true);
    } else if (dy > 40 || velocity > 600) {
      if (_large) {
        setState(() => _large = false);
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final MediaQueryData media = MediaQuery.of(context);
    final bool noMotion = media.disableAnimations;
    final bool solid =
        _large || glassMaterialOf(context) == FushiGlassMaterial.off;
    final double margin = _large ? 0 : _margin;
    final BorderRadius radius = _large
        ? const BorderRadius.vertical(top: Radius.circular(_radius))
        : const BorderRadius.all(Radius.circular(_radius));

    Widget content = Material(
      type: MaterialType.transparency,
      child: widget.child,
    );
    if (widget.showDragHandle) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (DragUpdateDetails d) =>
                _dragDy += d.primaryDelta ?? 0,
            onVerticalDragEnd: _onDragEnd,
            onTap: () => setState(() => _large = !_large),
            child: SizedBox(
              height: 22,
              child: Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: apple.tertiaryLabel,
                    borderRadius: const BorderRadius.all(Radius.circular(2.5)),
                  ),
                ),
              ),
            ),
          ),
          Flexible(child: content),
        ],
      );
    }
    if (_large) {
      content = SizedBox(
        height: media.size.height * _largeFraction,
        child: content,
      );
    }

    final Widget panel = solid
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: apple.secondaryGroupedBackground,
              borderRadius: radius,
            ),
            child: ClipRRect(borderRadius: radius, child: content),
          )
        : GlassContainer(
            // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
            useOwnLayer: true,
            shape: LiquidRoundedSuperellipse(borderRadius: _radius),
            quality: fushiGlassQuality(context, prominent: true),
            settings: fushiGlassSettings(context),
            clipBehavior: Clip.antiAlias,
            child: content,
          );

    return AnimatedPadding(
      duration: noMotion ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.fromLTRB(margin, 0, margin, margin),
      child: panel,
    );
  }
}

/// Apple 设计系统的桌面弹层（macOS 26 sheet）：贴窗口顶部正中、宽 480–640、
/// 圆角 18、实色面板（深 #2C2C2E / 浅白）+ 大半径柔和阴影，最高 85% 窗口高。
/// 内容外包透明 Material（依赖 Material 祖先的子组件照常工作）。
class _AppleDesktopSheet extends StatelessWidget {
  const _AppleDesktopSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Size size = MediaQuery.sizeOf(context);
    const BorderRadius radius = BorderRadius.all(Radius.circular(18));
    final double width = (size.width - 32).clamp(0, 640).toDouble();
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: width < 480 ? width : 480,
              maxWidth: width,
              maxHeight: size.height * 0.85,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF2C2C2E) : Colors.white,
                borderRadius: radius,
                border: Border.all(
                  color: dark
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.black.withValues(alpha: 0.08),
                  width: 0.5,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.5 : 0.22),
                    blurRadius: 40,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: Material(
                  type: MaterialType.transparency,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassSheetBody extends StatelessWidget {
  const _GlassSheetBody({required this.showDragHandle, required this.child});

  final bool showDragHandle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiGlassSurface(
      borderRadius: FushiBorderRadius.sheet,
      // M3 底部弹层的色阶（BottomSheet 默认底色 surfaceContainerLow）。
      baseColor: FushiDesignTokens.of(context).surfaces.group,
      child: showDragHandle
          ? Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: kMinInteractiveDimension),
                  child: child,
                ),
                SizedBox(
                  height: kMinInteractiveDimension,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : child,
    );
  }
}

Widget adaptiveSegmentedButton<T extends Object>({
  required BuildContext context,
  required List<ButtonSegment<T>> segments,
  required Set<T> selected,
  required ValueChanged<Set<T>> onSelectionChanged,
  ButtonStyle? style,
}) {
  if (isGlassDesign(context)) {
    // Apple 设计系统：委托给 FushiSegmentedButton 的 iOS 分段（systemFill 灰轨 +
    // 白色滑块），与 FushiSegmentedButton 调用点同一个观感。有界宽下撑满（沿用
    // 以前玻璃分段的布局），无界宽（横向滚动的分段条宿主）按内容取宽。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return FushiSegmentedButton<T>(
          segments: segments,
          selected: selected,
          onSelectionChanged: onSelectionChanged,
          emptySelectionAllowed: selected.isEmpty,
          showSelectedIcon: false,
          expandedInsets:
              constraints.maxWidth.isFinite ? EdgeInsets.zero : null,
          style: style,
        );
      },
    );
  }
  if (isCupertinoPlatform(context)) {
    final T groupValue = selected.first;
    return CupertinoSlidingSegmentedControl<T>(
      groupValue: groupValue,
      onValueChanged: (v) {
        if (v != null) onSelectionChanged({v});
      },
      children: {
        for (final seg in segments)
          seg.value: seg.label ?? seg.icon ?? Text('$seg'),
      },
    );
  }
  return SegmentedButton<T>(
    showSelectedIcon: false,
    segments: segments,
    selected: selected,
    onSelectionChanged: onSelectionChanged,
    style: style,
  );
}

Route<T> adaptivePageRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  if (isCupertinoPlatform(context)) {
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      fullscreenDialog: fullscreenDialog,
    );
  }
  return MaterialPageRoute<T>(
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}

/// Wraps [MacosSlider] (which only exposes a continuous [onChanged]) to restore
/// the [Slider]/[CupertinoSlider] drag-boundary callbacks the settings sliders
/// depend on. The raw [Listener] sees the pointer down/up regardless of the
/// slider's internal pan recognizer, so commit-on-drag-end keeps working without
/// re-introducing the scaled-tree slider regression. Maps Material `divisions`
/// to MacosSlider's `discrete`/`splits`.
class _MacosSliderWithDragCallbacks extends StatefulWidget {
  const _MacosSliderWithDragCallbacks({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.color,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final Color color;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_MacosSliderWithDragCallbacks> createState() =>
      _MacosSliderWithDragCallbacksState();
}

class _MacosSliderWithDragCallbacksState
    extends State<_MacosSliderWithDragCallbacks> {
  late double _latest = widget.value;

  @override
  void didUpdateWidget(_MacosSliderWithDragCallbacks oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Track externally-driven value changes between drags so a pointer-up that
    // fires without an intervening onChanged still commits the current value.
    if (oldWidget.value != widget.value) _latest = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final int? divisions = widget.divisions;
    return Listener(
      onPointerDown: (_) => widget.onChangeStart?.call(_latest),
      onPointerUp: (_) => widget.onChangeEnd?.call(_latest),
      onPointerCancel: (_) => widget.onChangeEnd?.call(_latest),
      child: MacosSlider(
        value: _latest.clamp(widget.min, widget.max).toDouble(),
        min: widget.min,
        max: widget.max,
        discrete: divisions != null,
        splits: (divisions != null && divisions >= 2) ? divisions : 15,
        color: widget.color,
        onChanged: (double next) {
          _latest = next;
          widget.onChanged(next);
        },
      ),
    );
  }
}
