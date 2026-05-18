import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

enum WindowSizeClass { compact, medium, expanded }

WindowSizeClass windowSizeClassOf(BoxConstraints constraints) {
  final double w = constraints.maxWidth;
  if (w >= 840) return WindowSizeClass.expanded;
  if (w >= 600) return WindowSizeClass.medium;
  return WindowSizeClass.compact;
}

WindowSizeClass windowSizeClassFromContext(BuildContext context) {
  final double w = MediaQuery.sizeOf(context).width;
  if (w >= 840) return WindowSizeClass.expanded;
  if (w >= 600) return WindowSizeClass.medium;
  return WindowSizeClass.compact;
}
