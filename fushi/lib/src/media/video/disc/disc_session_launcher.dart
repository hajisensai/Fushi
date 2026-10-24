import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/video/bluray_java_runtime.dart';
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookRepository;

/// The "原盘默认进入菜单" setting as seen from [context]. Detail pages are plain
/// StatefulWidgets whose widget tests run without a ProviderScope; there the
/// default (on) applies. Reads once, registers no rebuild dependency.
bool discOpenMenuByDefaultOf(BuildContext context) {
  final InheritedElement? element = context
      .getElementForInheritedWidgetOfExactType<UncontrolledProviderScope>();
  final Widget? scope = element?.widget;
  if (scope is! UncontrolledProviderScope) return true;
  return scope.container.read(appProvider).videoDiscOpenMenuByDefault;
}

/// The platform the disc-menu capability rule is evaluated for.
DiscMenuPlatform currentDiscMenuPlatform() {
  if (Platform.isAndroid) return DiscMenuPlatform.android;
  if (Platform.isIOS) return DiscMenuPlatform.ios;
  if (Platform.isMacOS) return DiscMenuPlatform.macos;
  if (Platform.isLinux) return DiscMenuPlatform.linux;
  return DiscMenuPlatform.windows;
}

/// Whether this build can install the optional BD-J component itself (the
/// session then offers it); see [resolveDiscMenuAvailability].
bool currentBdjComponentInstallable() => BlurayJavaRuntimeManager().canInstall;

/// Probes [disc] on this device. Runs one small index read; never starts Java.
Future<DiscMenuUnavailableReason?> probeLocalDiscMenu(DiscRef disc) =>
    probeDiscMenuAvailability(
      rootPath: disc.rootPath,
      platform: currentDiscMenuPlatform(),
      bdjComponentInstallable: currentBdjComponentInstallable(),
    );

/// The user-facing explanation for [reason] (shown as the primary button's
/// subtitle and as a toast when a menu entry is used anyway).
String discMenuUnavailableText(DiscMenuUnavailableReason reason) =>
    switch (reason) {
      DiscMenuUnavailableReason.remote => t.video_disc_menu_unavailable_remote,
      DiscMenuUnavailableReason.mobileBdj =>
        t.video_disc_menu_unavailable_mobile_bdj,
      DiscMenuUnavailableReason.missingBdjComponent =>
        t.video_disc_menu_unavailable_missing_bdj,
    };

/// Opens the authored menu of [book]'s disc as an immersive disc session.
///
/// Every library surface goes through here (collection card menu, collection
/// detail, standalone work detail, related works), so none of them can forget
/// the disc entry again. [cover] / [origin] feed the launch animation.
Future<void> openDiscSession({
  required BuildContext context,
  required VideoBookRepository repo,
  required VideoBookRow book,
  int? collectionId,
  ImageProvider? cover,
  Rect? origin,
}) {
  return Navigator.push<void>(
    context,
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoFushiPage.neutralized(
        bookUid: book.bookUid,
        repo: repo,
        playlistCollectionId: collectionId,
        openBlurayMenu: true,
        discLaunchCover: cover,
        discLaunchOrigin: origin,
      ),
    ),
  );
}

/// Disc chooser for multi-disc sets, sorted like [collectDiscRefs]. Returns
/// null when cancelled.
Future<DiscRef?> showDiscPicker({
  required BuildContext context,
  required List<DiscRef> discs,
  DiscRef? selected,
}) {
  return showFushiChoiceDialog<DiscRef>(
    context: context,
    title: t.video_disc_choose_disc,
    icon: FushiIcons.toc,
    selected: selected,
    options: <FushiChoiceOption<DiscRef>>[
      for (final DiscRef disc in discs)
        FushiChoiceOption<DiscRef>(
          value: disc,
          label: disc.label,
          icon: FushiIcons.toc,
        ),
    ],
  );
}

/// Card-menu / chooser entry: one disc opens directly, several ask which one.
Future<void> openDiscSessionWithPicker({
  required BuildContext context,
  required VideoBookRepository repo,
  required List<DiscRef> discs,
  int? collectionId,
  ImageProvider? cover,
}) async {
  if (discs.isEmpty) return;
  final DiscRef? disc = discs.length == 1
      ? discs.single
      : await showDiscPicker(
          context: context,
          discs: discs,
          selected: preferredDisc(discs),
        );
  if (disc == null || !context.mounted) return;
  final DiscMenuUnavailableReason? reason = await probeLocalDiscMenu(disc);
  if (!context.mounted) return;
  if (reason != null) {
    FushiToast.show(
      msg: discMenuUnavailableText(reason),
      severity: ToastSeverity.warning,
    );
    return;
  }
  unawaited(
    openDiscSession(
      context: context,
      repo: repo,
      book: disc.book,
      collectionId: collectionId,
      cover: cover,
    ),
  );
}
