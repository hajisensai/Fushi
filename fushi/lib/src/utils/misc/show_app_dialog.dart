import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/stats/study_cover_tracker.dart'
    show studyClockRouteSettings;
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
///
/// [studyClockTransparent]：这个对话框属于学习面本身（查词后的制卡流程），盖在
/// 阅读器 / 漫画 / PDF / 浏览器上也不停学习计时。豁免随路由构造一起带上
/// （`StudyClockTransparentSettings`），推路由当帧就生效（BUG-3994）。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
  bool studyClockTransparent = false,
}) {
  final RouteSettings? routeSettings = studyClockRouteSettings(
    transparent: studyClockTransparent,
  );
  Widget glassBuilder(BuildContext dialogContext) =>
      FushiGlassDialogBackdrop(child: builder(dialogContext));
  if (isCupertinoPlatform(context)) {
    return showCupertinoDialog<T>(
      context: context,
      builder: glassBuilder,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
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
      settings: routeSettings,
    ),
  );
}

/// 关掉 [context] 所在的那个对话框路由，带回 [result]。
///
/// `Navigator.of(context).pop(result)` 弹的是导航器**栈顶**路由，不一定是自己：对话框
/// 里 `await` 一个异步动作期间，别处在同一个导航器上叠出了新对话框（例如制卡链路里
/// 「笔记类型未适配视频」的降级提示），动作回来后的 pop 就会把结果塞给那个新对话框——
/// 结果类型对不上直接抛，两个对话框都关不掉（反馈 -EruTk-rWo）。异步动作结束后关闭
/// 自身的对话框一律用这个。
void popAppDialog<T>(BuildContext context, [T? result]) {
  final ModalRoute<Object?>? route = ModalRoute.of(context);
  if (route == null) {
    Navigator.of(context).pop<T>(result);
    return;
  }
  if (!route.isActive) return;
  final NavigatorState navigator = route.navigator!;
  if (route.isCurrent) {
    navigator.pop<T>(result);
  } else {
    navigator.removeRoute<Object?>(route, result);
  }
}
