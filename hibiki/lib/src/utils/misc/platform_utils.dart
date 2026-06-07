import 'dart:io' show Platform;

import 'package:flutter/material.dart';

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

/// Windows/Linux 桌面用 MD3 的钳制滚动（去掉 iOS 风格回弹）；macOS（Cupertino
/// 平台，刻意不动）与移动端保持原有可回弹物理。始终保留 AlwaysScrollable 外层，
/// 使短内容也可滚动 / 触发下拉刷新等行为。
ScrollPhysics desktopAwareScrollPhysics() {
  final bool md3Desktop = Platform.isWindows || Platform.isLinux;
  return md3Desktop
      ? const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics())
      : const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics());
}

enum WindowSizeClass { compact, medium, expanded }

enum DesktopContentKind { readerShelf, dictionary, settings }

enum SupportingPaneSide { start, end }

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
    DesktopContentKind.settings => 960,
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

double supportingPaneWidthForLayout(double width) {
  return (width * 0.3).clamp(280.0, 360.0);
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

class MaterialSupportingPaneLayout extends StatelessWidget {
  const MaterialSupportingPaneLayout({
    required this.primary,
    required this.supporting,
    super.key,
    this.supportingSide = SupportingPaneSide.end,
    this.minSplitWidth = 840,
    this.supportingWidth,
    this.dividerColor,
  });

  final Widget primary;
  final Widget supporting;
  final SupportingPaneSide supportingSide;
  final double minSplitWidth;
  final double? supportingWidth;
  final Color? dividerColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < minSplitWidth) return primary;

        final double resolvedSupportingWidth = supportingWidth ??
            supportingPaneWidthForLayout(constraints.maxWidth);
        final Color resolvedDividerColor =
            dividerColor ?? Theme.of(context).dividerColor;
        final Widget divider = VerticalDivider(
          width: 1,
          thickness: 1,
          color: resolvedDividerColor,
        );
        final Widget fixedSupporting = SizedBox(
          width: resolvedSupportingWidth,
          child: supporting,
        );
        final Widget flexiblePrimary = Expanded(child: primary);

        return Row(
          // stretch (not the Row default center) so each pane gets a tight,
          // full-height constraint. Under center the panes receive a LOOSE
          // height, so a detail pane built from an own-scrolling
          // SingleChildScrollView shrink-wraps to its content and is then
          // vertically centered — a short settings page (e.g. the audiobook
          // destination with only a couple of desktop-visible toggles) floated
          // to the middle instead of hugging the top. A tight height makes the
          // scroll view fill the pane, so its content stays top-aligned.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: supportingSide == SupportingPaneSide.start
              ? <Widget>[fixedSupporting, divider, flexiblePrimary]
              : <Widget>[flexiblePrimary, divider, fixedSupporting],
        );
      },
    );
  }
}
