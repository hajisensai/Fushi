import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

enum WindowSizeClass { compact, medium, expanded }

enum DesktopContentKind { readerShelf, dictionary, settings }

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

double? desktopContentMaxWidth(
  WindowSizeClass sizeClass,
  DesktopContentKind kind,
) {
  if (sizeClass == WindowSizeClass.compact) return null;
  return switch (kind) {
    DesktopContentKind.readerShelf => 1280,
    DesktopContentKind.dictionary => 1040,
    DesktopContentKind.settings => 760,
  };
}

EdgeInsets desktopContentPadding(WindowSizeClass sizeClass) {
  return switch (sizeClass) {
    WindowSizeClass.compact => EdgeInsets.zero,
    WindowSizeClass.medium => const EdgeInsets.symmetric(horizontal: 16),
    WindowSizeClass.expanded => const EdgeInsets.symmetric(horizontal: 24),
  };
}

double desktopDialogContentWidth(double availableWidth) {
  return (availableWidth * 0.8).clamp(256.0, 420.0);
}

double readerShelfGridExtentForWidth(double width) {
  if (width >= 1280) return 210;
  if (width >= 960) return 190;
  if (width >= 600) return 180;
  return 150;
}

double readerShelfGridExtentForLayout({
  required double mediaWidth,
  double? contentWidth,
}) {
  return readerShelfGridExtentForWidth(contentWidth ?? mediaWidth);
}

class DesktopContentLayout extends StatelessWidget {
  const DesktopContentLayout({
    required this.kind,
    required this.child,
    super.key,
  });

  final DesktopContentKind kind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final WindowSizeClass sizeClass = windowSizeClassOf(constraints);
        final double? maxWidth = desktopContentMaxWidth(sizeClass, kind);
        final Widget padded = Padding(
          padding: desktopContentPadding(sizeClass),
          child: child,
        );
        if (maxWidth == null) return padded;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: padded,
          ),
        );
      },
    );
  }
}
