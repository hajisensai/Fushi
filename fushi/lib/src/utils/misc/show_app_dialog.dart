import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 全应用唯一的对话框入口。玻璃设计系统下对话框本体由主题染成半透明，
/// 背后整屏模糊由 [FushiGlassDialogBackdrop] 在这里统一套上——新代码不要再
/// 裸调 `showDialog`，否则对话框背后不模糊、半透明底直接压在内容上。
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
  return showDialog<T>(
    context: context,
    builder: glassBuilder,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    useRootNavigator: useRootNavigator,
    animationStyle: fushiMd3DialogAnimationStyle,
  );
}
