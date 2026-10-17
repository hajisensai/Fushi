import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 全应用唯一的对话框入口。玻璃设计系统下对话框本体由主题染成半透明，
/// 背后整屏模糊由 [FushiGlassDialogBackdrop] 在这里统一套上——新代码不要再
/// 裸调 `showDialog`，否则对话框背后不模糊、半透明底直接压在内容上。
///
/// Material 设计系统（M3 Expressive）下推 [FushiDialogRoute]：弹簧缩放 + 淡入
/// 进场、快速缩回淡出，遮罩统一 scrim@32%（[fushiModalScrimColor]）；焦点在
/// 对话框内闭环，Esc / 点遮罩关闭，关闭后焦点回到打开前的节点（路由出栈时
/// 下层作用域恢复）。墨水屏与「减弱动态效果」下无动画。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
}) {
  Widget glassBuilder(BuildContext dialogContext) =>
      FushiGlassDialogBackdrop(child: builder(dialogContext));
  if (isCupertinoPlatform(context)) {
    return showCupertinoDialog<T>(
      context: context,
      builder: glassBuilder,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
    );
  }
  assert(debugCheckHasMaterialLocalizations(context));
  final NavigatorState navigator = Navigator.of(
    context,
    rootNavigator: useRootNavigator,
  );
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: navigator.context,
  );
  return navigator.push<T>(
    FushiDialogRoute<T>(
      context: context,
      builder: glassBuilder,
      themes: themes,
      barrierColor:
          barrierColor ??
          DialogTheme.of(context).barrierColor ??
          fushiModalScrimColor(context),
      barrierDismissible: barrierDismissible,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      animationStyle: fushiM3eDialogAnimationStyle,
      reduceMotion: !fushiMotionEnabled(context),
    ),
  );
}
