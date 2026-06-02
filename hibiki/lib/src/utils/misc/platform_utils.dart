import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

// Architecture decision: platform branching uses runtime Platform.is* checks
// centralized in this file, not Dart conditional imports.
// Conditional imports (if (dart.library.io)) only distinguish web vs native,
// which this app does not target. For platform-specific behavior beyond simple
// boolean checks, use the service abstractions in package:hibiki_platform with
// implementations under lib/src/platform/{android,ios,desktop}/.

bool get isDesktopPlatform =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

bool get isMobilePlatform => Platform.isAndroid || Platform.isIOS;

bool get isAndroidPlatform => Platform.isAndroid;

bool get isIOSPlatform => Platform.isIOS;

bool get supportsNativeAudio =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

bool get supportsFloatingOverlay => Platform.isAndroid;

bool get isWindowsPlatform => Platform.isWindows;

/// 桌面端用 MD3 的钳制滚动（去掉 iOS 风格回弹），其它平台保持原有可回弹物理。
/// 始终保留 AlwaysScrollable 外层，使短内容也可滚动 / 触发下拉刷新等行为。
ScrollPhysics desktopAwareScrollPhysics() {
  return isDesktopPlatform
      ? const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())
      : const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics());
}

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
