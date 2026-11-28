import 'package:fushi/src/utils/components/fushi_pill_segmented_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/stats/study_cover_tracker.dart'
    show studyClockRouteSettings;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_popup_origin.dart';
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
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show fushiAppleOverlayShadows;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleMacScale, fushiAppleUsesMacMetrics;
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
    return FushiFilledButton(onPressed: onPressed, child: child);
  }
  return FushiTextButton(onPressed: onPressed, child: child);
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
  // Material（M3E）：走 FushiSwitch，否则绕过 Expressive 开关（关态叉号、
  // 圆钮尺寸）和设计系统分派，与其它 FushiSwitch 调用点观感不一致。
  return FushiSwitch(
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
///
/// [isDismissible] 为 false 时**点遮罩与下拉（整块下拉 / 拖动条下拉）都不再
/// 关闭**，与桌面 `showAppDialog(barrierDismissible: false)` 同一语义：用于关掉
/// 就会中断长任务的弹层（设备端转录，反馈 NrRPRDTprI）。Esc / 手柄 B / 系统
/// 返回与弹层内的按钮仍照常关闭——那些是明确的关闭意图，不是误触。
///
/// [studyClockTransparent]：弹层属于学习面本身（高级制卡），盖在学习页上也不停
/// 学习计时；豁免随路由构造带上，推路由当帧生效（BUG-3994）。
Future<T?> adaptiveModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool showDragHandle = true,
  bool useSafeArea = false,
  bool expandable = false,
  bool isDismissible = true,
  bool studyClockTransparent = false,
  ThemeData? md3Theme,
  bool? useRootNavigator,
}) {
  // [md3Theme]：MD3 弹层整体（面板底色 + 内容）换一套主题——导入流程里的弹层
  // 跟随模块色系（见 importToneThemeOrNull）。只作用于下面的 Material 分支；
  // Apple / 液态玻璃分支不受影响。
  //
  // [useRootNavigator]：null = 各形态原有的默认（Cupertino 弹层 / 桌面玻璃 sheet 在
  // root navigator 上，Material 底部 sheet 与宽屏浮动 sheet 在最近的 navigator 上）。
  // true = 一律开在 root navigator 上——调用方的 context 可能在一条 root 路由**下面**
  // 的页面里（视频页开着整页的字幕工作台时起面板），开在最近的 navigator 上会被那条
  // 整页路由挡住。
  final ThemeData? sheetTheme = md3Theme;
  // 弹层承接来源组件的配色（色块卡等，见 fushi_popup_origin.dart）：context 在
  // 色块里时由主题捕获带进路由；经页面 State 转弹时按点按来源补包一层。
  final FushiPopupOrigin? origin = fushiPopupOriginFor(context);
  final WidgetBuilder sourceBuilder = builder;
  builder = (BuildContext sheetContext) {
    final Widget sheet = sourceBuilder(sheetContext);
    return origin == null ? sheet : origin.wrap(sheet);
  };
  Widget themed(Widget child) =>
      sheetTheme == null ? child : Theme(data: sheetTheme, child: child);
  // showCupertinoModalPopup / showGeneralDialog 不捕获 InheritedTheme（Material
  // 路由会）：这两条路径补上，色块里弹出的弹层才拿得到色块的局部主题。
  CapturedThemes captureFor(bool rootNavigator) => InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: rootNavigator).context,
  );

  final RouteSettings? routeSettings = studyClockRouteSettings(
    transparent: studyClockTransparent,
  );
  final bool noMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final AnimationStyle sheetMotion = noMotion
      ? AnimationStyle.noAnimation
      : fushiM3eSheetAnimationStyle;
  if (isGlassDesign(context)) {
    // 宽屏 = macOS 浮动 sheet；窄屏（含桌面窄窗）= iOS 底部 sheet。判据唯一
    // 一处（[fushiAppleUsesMacMetrics]）。
    if (fushiAppleUsesMacMetrics(context)) {
      // macOS 27 sheet：窗口正中的浮动实色面板（宽 480–640、圆角 20、大半径
      // 很淡的投影），淡入 + 轻微放大，不是底部抽屉也不再从顶部垂下。走 RawDialogRoute：Esc（DismissIntent）
      // 关闭、点遮罩关闭、独立焦点作用域、pop 返回值与底部弹层一致。
      final CapturedThemes themes = captureFor(useRootNavigator ?? true);
      return showGeneralDialog<T>(
        context: context,
        useRootNavigator: useRootNavigator ?? true,
        barrierDismissible: isDismissible,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        barrierColor: Colors.black.withValues(alpha: 0.18),
        routeSettings: routeSettings,
        transitionDuration: noMotion
            ? Duration.zero
            : const Duration(milliseconds: 260),
        pageBuilder:
            (
              BuildContext sheetContext,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
            ) => themes.wrap(_AppleDesktopSheet(child: builder(sheetContext))),
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
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
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
      useRootNavigator: useRootNavigator ?? false,
      routeSettings: routeSettings,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      constraints: const BoxConstraints(),
      barrierColor: Colors.black.withValues(alpha: 0.2),
      sheetAnimationStyle: sheetMotion,
      isDismissible: isDismissible,
      enableDrag: isDismissible,
      builder: (BuildContext sheetContext) => _LiquidSheetBody(
        showDragHandle: showDragHandle,
        dragToDismiss: isDismissible,
        child: builder(sheetContext),
      ),
    );
  }
  final bool frosted = glassMaterialOf(context) != FushiGlassMaterial.off;
  if (MediaQuery.sizeOf(context).width >= kFushiSheetWideBreakpoint) {
    final NavigatorState navigator = Navigator.of(
      context,
      rootNavigator: useRootNavigator ?? false,
    );
    return navigator.push<T>(
      FushiDialogRoute<T>(
        context: context,
        themes: InheritedTheme.capture(from: context, to: navigator.context),
        barrierColor: fushiModalScrimColor(context),
        barrierDismissible: isDismissible,
        traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
        reduceMotion: noMotion || !fushiMotionEnabled(context),
        settings: routeSettings,
        builder: (BuildContext sheetContext) => themed(
          FushiM3eFloatingSheet(frosted: frosted, child: builder(sheetContext)),
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
      useRootNavigator: useRootNavigator ?? false,
      routeSettings: routeSettings,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      sheetAnimationStyle: sheetMotion,
      isDismissible: isDismissible,
      enableDrag: isDismissible,
      builder: (BuildContext sheetContext) => themed(
        _GlassSheetBody(
          showDragHandle: showDragHandle,
          child: FushiM3eSheetBody(
            showDragHandle: false,
            expandable: false,
            dragToDismiss: isDismissible,
            child: builder(sheetContext),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator ?? false,
    routeSettings: routeSettings,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    // 拖动条由 [FushiM3eSheetBody] 自绘（同 M3 几何），两档高度要接它的手势。
    showDragHandle: false,
    backgroundColor: sheetTheme?.colorScheme.surfaceContainerLow,
    sheetAnimationStyle: sheetMotion,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    builder: (BuildContext sheetContext) => themed(
      FushiM3eSheetBody(
        showDragHandle: showDragHandle,
        expandable: expandable,
        dragToDismiss: isDismissible,
        child: builder(sheetContext),
      ),
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
  const _LiquidSheetBody({
    required this.showDragHandle,
    required this.child,
    this.dragToDismiss = true,
  });

  final bool showDragHandle;
  final Widget child;

  /// 拖动条在 medium 档下拉是否关闭弹层（[adaptiveModalSheet] 的 isDismissible）。
  final bool dragToDismiss;

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
      } else if (widget.dragToDismiss) {
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

/// Apple 设计系统的宽屏弹层（macOS 27 sheet）：窗口正中浮动、宽 480–640、
/// 圆角 20、实色面板（深 #2C2C2E / 浅白）+ 大半径很淡的投影，最高 85% 窗口高。
/// 内容外包透明 Material（依赖 Material 祖先的子组件照常工作）。
class _AppleDesktopSheet extends StatelessWidget {
  const _AppleDesktopSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Size size = MediaQuery.sizeOf(context);
    // macOS 档放大系数（Windows / Linux 宽窗放大，Mac 1.0）：面板宽与圆角
    // 随控件一起放大，内容不被挤窄。
    final double k = fushiAppleMacScale(context);
    final BorderRadius radius = BorderRadius.all(Radius.circular(20 * k));
    final double width = (size.width - 48).clamp(0, 640 * k).toDouble();
    return SafeArea(
      child: Align(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: width < 480 * k ? width : 480 * k,
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
                boxShadow: fushiAppleOverlayShadows(dark: dark),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: Material(type: MaterialType.transparency, child: child),
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
                        borderRadius: const BorderRadius.all(
                          Radius.circular(2),
                        ),
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

/// [adaptiveSegmentedButton] 在当前上下文里是否渲染 MD3 胶囊分段
/// （[FushiPillSegmentedButton]）。分段条估宽（`SegmentedStripMetrics.of`）按同一
/// 判据选几何，两处不得各写一份分支条件。
///
/// 非 Apple 设计一律胶囊分段——包括 Cupertino 设计系统但 Apple 设计不生效
/// （墨水屏）的情况：那里以前是原生 `CupertinoSlidingSegmentedControl`，各段
/// 等宽、不走 `fushiSegmentWidths`，最长段先被截断（BUG-4205）。
bool adaptiveSegmentedUsesPill(BuildContext context) => !isGlassDesign(context);

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
    // expandedInsets = fill when the width is bounded, content width when it
    // is not (both Apple forms decide this from their own constraints and
    // still answer intrinsic size queries; no LayoutBuilder here, BUG-4642).
    return FushiSegmentedButton<T>(
      segments: segments,
      selected: selected,
      onSelectionChanged: onSelectionChanged,
      emptySelectionAllowed: selected.isEmpty,
      showSelectedIcon: false,
      expandedInsets: EdgeInsets.zero,
      style: style,
    );
  }
  // Material（M3E）：胶囊轨道 + 选中胶囊，与浏览页二级页签同一形态
  // （2026-10-09 用户「深色模式三图标分段与浏览页胶囊页签风格不一致」）。
  // 墨水屏（含 Cupertino 设计系统下）也走这里：胶囊分段自带墨水屏配色。
  assert(adaptiveSegmentedUsesPill(context));
  return FushiPillSegmentedButton<T>(
    segments: segments,
    selected: selected,
    onSelectionChanged: onSelectionChanged,
    // 同 Apple 分支：调用方给空选中（状态还没读到、不能假装选了哪项）时放行空选，
    // 否则 SegmentedButton 的断言直接把宿主打崩。
    emptySelectionAllowed: selected.isEmpty,
    style: style,
  );
}

Route<T> adaptivePageRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  // Apple（玻璃）设计系统的 Cupertino 推入转场由主题层 pageTransitionsTheme 给
  // （[FushiCupertinoPageTransitionsBuilder] 外套页面背景层），这里必须走
  // MaterialPageRoute 查主题：CupertinoPageRoute 自己画转场、不读主题，推进来的
  // 页就垫不上用户的背景图片（设置子页始终白底），也不认系统「减弱动态效果」。
  return MaterialPageRoute<T>(
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}
