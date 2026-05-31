import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_motion_tokens.dart';

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  if (isCupertinoPlatform(context)) {
    return showCupertinoDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
  }
  return showDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    animationStyle: hibikiMd3DialogAnimationStyle,
  );
}
