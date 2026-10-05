import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

export 'package:fluttertoast/fluttertoast.dart' show Toast, ToastGravity;
// 语义与调色板住在 toast_severity.dart（视频页 OSD 也用，见该文件头注释），
// 这里再导出一次，让既有 `import fushi_toast.dart` 的调用点无需改 import。
export 'package:fushi/src/utils/misc/toast_severity.dart';

/// Global navigator key used by the toast overlay.
/// Must be assigned to the MaterialApp's navigatorKey.
GlobalKey<NavigatorState>? _toastNavigatorKey;

/// 全局短时通知。有主 app 的 navigator overlay 时（桌面与移动）自绘
/// [_FushiToastView]；没有 overlay 的独立弹窗 Activity 降级为原生 Fluttertoast。
abstract final class FushiToast {
  /// Assign the app's navigator key so toasts can find the overlay.
  static set navigatorKey(GlobalKey<NavigatorState> key) =>
      _toastNavigatorKey = key;

  /// [severity] 决定前置图标与图标的语义色（见 [ToastSeverity]）；底色恒为主题的
  /// 浮条色，不再整块铺饱和色。显式传 [backgroundColor] / [textColor] 仍然优先
  /// ——少数调用点（如 tag chip 透传自身颜色）不是语义着色。
  static void show({
    required String msg,
    Toast toastLength = Toast.LENGTH_SHORT,
    ToastGravity gravity = ToastGravity.BOTTOM,
    Color? backgroundColor,
    Color? textColor,
    ToastSeverity severity = ToastSeverity.neutral,
  }) {
    final ({Color background, Color foreground, IconData icon})? palette =
        toastSeverityPalette(severity);
    final int durationMs = toastLength == Toast.LENGTH_LONG ? 3500 : 2000;
    final OverlayState? overlay = _toastNavigatorKey?.currentState?.overlay;
    if (overlay == null) {
      // 原生 toast 只做无 overlay 时的兜底：它不跟主题、画不了图标，只能用固定
      // 语义色板整块着色（此时颜色是唯一的语义通道）。
      if (Platform.isAndroid || Platform.isIOS) {
        Fluttertoast.showToast(
          msg: msg,
          toastLength: toastLength,
          gravity: gravity,
          backgroundColor: backgroundColor ?? palette?.background,
          textColor: textColor ?? palette?.foreground,
        );
      }
      return;
    }
    // 调用点自带颜色就照它的颜色画、不配语义图标；否则底色交给主题，语义只
    // 落在前置图标上。
    final bool customColors = backgroundColor != null || textColor != null;
    _insertToastEntry(
      overlay: overlay,
      durationMs: durationMs,
      builder: (BuildContext context) => _FushiToastView(
        msg: msg,
        icon: customColors ? null : palette?.icon,
        severity: customColors ? ToastSeverity.neutral : severity,
        backgroundColor: backgroundColor,
        textColor: textColor,
      ),
    );
  }

  /// TODO-1325 #6: 制卡结果 toast。挂在 dictionary_page_mixin 的 onMine 回调之后：
  /// 按 [status] 配图标与语义色（added 成功 / duplicate 警示 / failed 错误 /
  /// pending 信息）。有 navigator overlay（主 app，桌面与移动）时走自绘 overlay
  /// （会顶替上一条，让 pending → 结果自然过渡）；无 overlay 的独立弹窗 Activity
  /// 降级为原生着色 toast（无图标但仍着色，绝不静默）。
  static void showMine({
    required String msg,
    required MineToastStatus status,
  }) {
    final overlay = _toastNavigatorKey?.currentState?.overlay;
    if (overlay != null) {
      _showMineOverlay(overlay: overlay, msg: msg, status: status);
      return;
    }
    // pending 是过渡态（只有能被结果 toast 顶替时才有意义）。无 overlay 的降级路径
    // 用的是会排队的原生 toast，若也弹 pending 会把「制卡中…」卡在结果之前，故跳过。
    if (status == MineToastStatus.pending) return;
    final palette = mineToastPalette(status);
    show(
      msg: msg,
      backgroundColor: palette.background,
      textColor: palette.foreground,
    );
  }

  static void _showMineOverlay({
    required OverlayState overlay,
    required String msg,
    required MineToastStatus status,
  }) {
    // pending 停留更久（等制卡结果覆盖它），结果 toast 用短时长。
    _insertToastEntry(
      overlay: overlay,
      durationMs: status == MineToastStatus.pending ? 4000 : 2400,
      builder: (BuildContext context) => _FushiToastView(
        msg: msg,
        icon: mineToastPalette(status).icon,
        severity: mineToastSeverity(status),
      ),
    );
  }

  static void _insertToastEntry({
    required OverlayState overlay,
    required int durationMs,
    required WidgetBuilder builder,
  }) {
    _dismissTimer?.cancel();
    // 被新 toast 顶替时旧条立即撤（pending → 结果要无缝衔接，不叠两条）。
    _currentEntry?.remove();
    _currentEntry = null;

    final _FushiToastHandle handle = _FushiToastHandle();
    final entry = OverlayEntry(
      builder: (BuildContext context) => _FushiToastExitScope(
        handle: handle,
        child: builder(context),
      ),
    );
    _currentEntry = entry;
    overlay.insert(entry);

    void remove() {
      if (_currentEntry != entry) return;
      entry.remove();
      _currentEntry = null;
    }

    // 到时先播退场（M3E：淡出 + 轻微下沉缩小），播完再摘 overlay；视图已不在
    // （被顶替 / 宿主卸载）就直接摘。
    _dismissTimer = Timer(Duration(milliseconds: durationMs), () {
      final Future<void> Function()? dismiss = handle.dismiss;
      if (dismiss == null) {
        remove();
        return;
      }
      dismiss().whenComplete(remove);
    });
  }

  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;
}

/// overlay 条目与条目里 [_FushiToastView] 之间的退场握手：视图挂载后把自己的
/// 退场动画登记进来，到时由计时器调用。
class _FushiToastHandle {
  Future<void> Function()? dismiss;
}

/// 把 [_FushiToastHandle] 交给条目里的 [_FushiToastView]（视图由调用方 builder
/// 构造，构造时拿不到条目）。
class _FushiToastExitScope extends InheritedWidget {
  const _FushiToastExitScope({required this.handle, required super.child});

  final _FushiToastHandle handle;

  static _FushiToastHandle? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_FushiToastExitScope>()?.handle;

  @override
  bool updateShouldNotify(_FushiToastExitScope oldWidget) =>
      handle != oldWidget.handle;
}

/// 自绘 toast 距底边的距离：桌面沿用 50；移动端让出系统手势条与底部导航栏
/// （原生 toast 在 Android 上也落在导航栏上方）。
double _toastBottomOffset(BuildContext context) {
  if (Platform.isAndroid || Platform.isIOS) {
    return MediaQuery.viewPaddingOf(context).bottom + 96;
  }
  return 50;
}

/// MD3 下语义图标的颜色。浮条是 inverseSurface（与页面明暗相反），所以语义色
/// 按浮条自身明暗取 MD3 基线色阶：深底取 tone 80、浅底取 tone 40，保证图标在
/// 浮条上对比达标；info 用 inversePrimary（MD3 在 inverse 表面上的强调色槽位）。
/// 墨水屏一律前景色——灰阶下颜色塌掉，靠图标形状区分。
Color? _md3SeverityColor(
  BuildContext context,
  ToastSeverity severity,
  Color surface,
  Color foreground,
) {
  if (isEinkTheme(context)) return foreground;
  final bool darkSurface =
      ThemeData.estimateBrightnessForColor(surface) == Brightness.dark;
  switch (severity) {
    case ToastSeverity.neutral:
      return null;
    case ToastSeverity.info:
      return Theme.of(context).colorScheme.inversePrimary;
    case ToastSeverity.success:
      return darkSurface ? const Color(0xFF7DDC8C) : const Color(0xFF1E6B30);
    case ToastSeverity.warning:
      return darkSurface ? const Color(0xFFFFB870) : const Color(0xFF8F4A00);
    case ToastSeverity.error:
      return darkSurface ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A);
  }
}

/// Apple 下语义图标的颜色：iOS 系统色（单色强调色主题下 info 就是黑 / 白）。
Color? _appleSeverityColor(FushiAppleColors apple, ToastSeverity severity) {
  switch (severity) {
    case ToastSeverity.neutral:
      return null;
    case ToastSeverity.info:
      return apple.accent;
    case ToastSeverity.success:
      return apple.success;
    case ToastSeverity.warning:
      return apple.warning;
    case ToastSeverity.error:
      return apple.destructive;
  }
}

/// Apple toast 胶囊的圆角：单行高 48 时正好是全胶囊，多行退成圆角块（与
/// Apple 版 SnackBar 同一形态）。
const Radius _kAppleToastCorner = Radius.circular(24);

/// M3E toast 浮条的圆角：单行 48 高时 24 = 全胶囊，与提示条（snackBarTheme）
/// 同一副反色浮层（见 fushi_m3e_misc_themes.dart）。
const Radius _kMd3ToastCorner = Radius.circular(24);

/// 进场时长与曲线：M3E expressive fast spatial 弹簧的 cubic 近似（≈350ms、带过冲）。
const Duration _kToastEnterDuration = Duration(milliseconds: 350);
const Duration _kToastExitDuration = Duration(milliseconds: 150);
const Curve _kToastSpatialCurve = Cubic(0.42, 1.67, 0.21, 0.90);

/// 应用内 toast 的唯一渲染器（中性 / 语义 / 制卡共用，同类通知一副长相）。
///
/// - MD3：inverseSurface 浮条，圆角 14、轻阴影（elevation 3 档，墨水屏改细边），
///   文字 onInverseSurface；严重度只体现在前置图标颜色上，不整块着色。
/// - Apple：iOS 26 HUD 胶囊——深色 #2C2C2E / 浅色白 @92% + 背景模糊，15 号字，
///   单色 SF 图标，与 Apple 版 SnackBar 同一视觉。
///
/// 位置恒为底部居中（全部调用点都是 BOTTOM），淡入 + 轻微上浮。
class _FushiToastView extends StatefulWidget {
  const _FushiToastView({
    required this.msg,
    required this.icon,
    required this.severity,
    this.backgroundColor,
    this.textColor,
  });

  final String msg;
  final IconData? icon;
  final ToastSeverity severity;
  final Color? backgroundColor;
  final Color? textColor;

  @override
  State<_FushiToastView> createState() => _FushiToastViewState();
}

class _FushiToastViewState extends State<_FushiToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // M3E 进场：淡入（effects，不过冲）+ 自下浮起并从 0.86 弹到 1（spatial，
    // 带过冲的 expressive fast spatial 曲线）；退场反向走更短的 150ms。
    _controller = AnimationController(
      vsync: this,
      duration: _kToastEnterDuration,
      reverseDuration: _kToastExitDuration,
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.45, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );
    _slide = Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero)
        .animate(CurvedAnimation(
      parent: _controller,
      curve: _kToastSpatialCurve,
      reverseCurve: Curves.easeIn,
    ));
    _scale = Tween<double>(begin: 0.86, end: 1).animate(CurvedAnimation(
      parent: _controller,
      curve: _kToastSpatialCurve,
      reverseCurve: Curves.easeIn,
    ));
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 墨水屏 / 减弱动态效果：不做进退场（连续重绘 = 残影），直接落到终态。
    if (!fushiMotionEnabled(context)) _controller.value = 1;
    _FushiToastExitScope.maybeOf(context)?.dismiss = dismiss;
  }

  /// 退场动画；播完（或无动效时立即）完成。
  Future<void> dismiss() {
    if (!mounted || !fushiMotionEnabled(context)) return Future<void>.value();
    return _controller.reverse().orCancel.catchError((Object _) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget body =
        isGlassDesign(context) ? _buildApple(context) : _buildMaterial(context);
    return Positioned(
      bottom: _toastBottomOffset(context),
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _slide,
              child: ScaleTransition(
                scale: _scale,
                child: Material(type: MaterialType.transparency, child: body),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content({
    required Color foreground,
    required Color? iconColor,
    required TextStyle textStyle,
    required double iconSize,
    required double gap,
  }) {
    final IconData? icon = widget.icon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          FushiIcon(icon, color: iconColor ?? foreground, size: iconSize),
          SizedBox(width: gap),
        ],
        Flexible(
          child: Text(
            widget.msg,
            textAlign: icon == null ? TextAlign.center : TextAlign.start,
            style: textStyle.copyWith(color: foreground),
          ),
        ),
      ],
    );
  }

  Widget _buildMaterial(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final Color surface = widget.backgroundColor ?? cs.inverseSurface;
    final Color foreground = widget.textColor ?? cs.onInverseSurface;
    final Color? semantic =
        _md3SeverityColor(context, widget.severity, surface, foreground);
    final IconData? icon = widget.icon;
    // M3E：反色全胶囊（单行 48 高时圆角 24 = 半高），语义图标落在同色 20% 的圆形
    // 色块里（图标本身仍是语义色）；多行退成 24 圆角块。
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              shape: const CircleBorder(),
              color: eink
                  ? Colors.transparent
                  : (semantic ?? foreground).withValues(alpha: 0.2),
            ),
            child: FushiIcon(icon, color: semantic ?? foreground, size: 20),
          ),
          const SizedBox(width: 12),
        ],
        Flexible(
          child: Text(
            widget.msg,
            textAlign: icon == null ? TextAlign.center : TextAlign.start,
            style: tokens.type.controlLabel.copyWith(color: foreground),
          ),
        ),
      ],
    );
    return Container(
      constraints: const BoxConstraints(minHeight: 48, maxWidth: 440),
      padding: EdgeInsetsDirectional.only(
        start: icon != null ? 8 : 24,
        end: 24,
        top: 8,
        bottom: 8,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.all(_kMd3ToastCorner),
        // 墨水屏不画阴影（灰阶抖动成脏边），改一圈前景色细边界定浮条。
        border: eink ? Border.all(color: foreground) : null,
        boxShadow: eink
            ? null
            : <BoxShadow>[
                // M3 elevation level 3。
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.18),
                  blurRadius: 8,
                  spreadRadius: 3,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.24),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
      ),
      child: content,
    );
  }

  Widget _buildApple(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final bool dark = theme.colorScheme.brightness == Brightness.dark;
    // 系统「降低透明度」/ 增强对比度下（材质 off）不模糊、实色铺满。
    final bool translucent = glassMaterialOf(context) != FushiGlassMaterial.off;
    final Color fill = widget.backgroundColor ??
        (dark ? const Color(0xFF2C2C2E) : Colors.white)
            .withValues(alpha: translucent ? 0.92 : 1);
    final Color foreground = widget.textColor ?? apple.label;
    final Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48, maxWidth: 480),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: widget.icon != null ? 16 : 20,
          end: 20,
          top: 12,
          bottom: 12,
        ),
        child: _content(
          foreground: foreground,
          iconColor: _appleSeverityColor(apple, widget.severity),
          textStyle: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            height: 1.25,
          ),
          iconSize: 18,
          gap: 10,
        ),
      ),
    );
    return DecoratedBox(
      // 柔和大半径投影只画在胶囊外圈，把 HUD 从内容上托起来。
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(_kAppleToastCorner),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.40 : 0.14),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(_kAppleToastCorner),
        child: translucent
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: ColoredBox(color: fill, child: content),
              )
            : ColoredBox(color: fill, child: content),
      ),
    );
  }
}
