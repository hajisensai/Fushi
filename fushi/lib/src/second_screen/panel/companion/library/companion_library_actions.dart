import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_feed.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Browse's actions on the main screen (Library tab, S5): open an item on
/// top, open a page only the main screen has, and the "Back to <previous>"
/// offer after an open.

/// Lets Browse pages switch the companion to its Now tab after opening
/// something on top (the shell provides it).
class CompanionShowNowScope extends InheritedWidget {
  const CompanionShowNowScope({
    required this.showNow,
    required super.child,
    super.key,
  });

  final VoidCallback showNow;

  /// Read from callbacks (no dependency).
  static VoidCallback? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<CompanionShowNowScope>()?.showNow;

  @override
  bool updateShouldNotify(CompanionShowNowScope oldWidget) =>
      oldWidget.showNow != showNow;
}

/// The item that was open on top before the last open from the companion
/// (`CompanionLibraryOpenResult.previous`), offered as "Back to <title>" on
/// the Now tab for [window] after it was set, until another open replaces it
/// or the user dismisses it.
class CompanionBackToPrevious extends ChangeNotifier {
  CompanionBackToPrevious({this.window = defaultWindow});

  static const Duration defaultWindow = Duration(minutes: 5);

  final Duration window;

  CompanionLibraryItem? _item;
  DateTime? _setAt;
  Timer? _expiry;

  /// The item to go back to; null = no offer.
  CompanionLibraryItem? get item => _item;

  /// When [item] was set.
  DateTime? get setAt => _setAt;

  /// Replaces the offer ([previous] null clears it).
  void set(CompanionLibraryItem? previous) {
    _expiry?.cancel();
    _expiry = null;
    _item = previous;
    _setAt = previous == null ? null : DateTime.now();
    if (previous != null) _expiry = Timer(window, dismiss);
    notifyListeners();
  }

  /// Removes the offer.
  void dismiss() {
    _expiry?.cancel();
    _expiry = null;
    if (_item == null) return;
    _item = null;
    _setAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }
}

final ChangeNotifierProvider<CompanionBackToPrevious>
companionBackToPreviousProvider =
    ChangeNotifierProvider<CompanionBackToPrevious>(
      (Ref ref) => CompanionBackToPrevious(),
    );

void _snack(ScaffoldMessengerState? messenger, String text) =>
    messenger?.showSnackBar(FushiSnackBar(content: Text(text)));

/// Opens [itemRef] (or its [entry]) on the main screen (`library.open`).
/// On success the companion shows its Now tab and offers going back to what
/// was open before; otherwise a snackbar says it failed. Returns whether it
/// opened.
Future<bool> companionLibraryOpen(
  BuildContext context,
  WidgetRef ref, {
  required String itemRef,
  String? entry,
}) async {
  final CompanionPanelSession session = ref.read(companionPanelSessionProvider);
  final CompanionBackToPrevious back = ref.read(
    companionBackToPreviousProvider,
  );
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final VoidCallback? showNow = CompanionShowNowScope.maybeOf(context);
  CompanionLibraryOpenResult result;
  try {
    final Object? reply = await session.request(
      CompanionRequestMethods.libraryOpen,
      <String, Object?>{
        CompanionLibraryArgs.ref: itemRef,
        CompanionLibraryArgs.entry: ?entry,
      },
    );
    result = CompanionLibraryOpenResult.fromJson(
      companionLibraryReplyObject(reply),
    );
  } on CompanionRequestException {
    result = const CompanionLibraryOpenResult(opened: false);
  }
  if (!result.opened) {
    _snack(messenger, t.second_screen_library_browse_open_failed);
    return false;
  }
  back.set(result.previous);
  showNow?.call();
  return true;
}

/// Opens [target] on the main screen (`library.openOnMain`) and says so.
Future<bool> companionLibraryOpenOnMain(
  BuildContext context,
  WidgetRef ref,
  CompanionLibraryMainTarget target,
) async {
  final CompanionPanelSession session = ref.read(companionPanelSessionProvider);
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  bool ok;
  try {
    await session.request(
      CompanionRequestMethods.libraryOpenOnMain,
      <String, Object?>{CompanionLibraryArgs.target: target.wire},
    );
    ok = true;
  } on CompanionRequestException {
    ok = false;
  }
  _snack(
    messenger,
    ok
        ? t.second_screen_library_browse_opened_on_main
        : t.second_screen_library_browse_open_failed,
  );
  return ok;
}

/// "Back to <title>" (Now tab): reopens what was on top before the last
/// open from the companion; hidden when there is nothing to go back to.
class CompanionBackToPreviousBar extends ConsumerWidget {
  const CompanionBackToPreviousBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CompanionBackToPrevious back = ref.watch(
      companionBackToPreviousProvider,
    );
    final CompanionLibraryItem? item = back.item;
    final ThemeData theme = Theme.of(context);
    final Widget child;
    if (item == null) {
      child = const SizedBox(width: double.infinity);
    } else {
      final String label = t.second_screen_library_browse_back_to(
        title: item.title,
      );
      child = Padding(
        key: ValueKey<String>('companion-back-to-${item.ref}'),
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 0),
        child: Row(
          children: <Widget>[
            Expanded(
              child: FushiPressScale(
                child: Semantics(
                  button: true,
                  label: label,
                  excludeSemantics: true,
                  child: FushiFilledButton.tonal(
                    key: const ValueKey<String>('companion-back-to-previous'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      alignment: AlignmentDirectional.centerStart,
                    ),
                    onPressed: () => unawaited(
                      companionLibraryOpen(context, ref, itemRef: item.ref),
                    ),
                    child: Row(
                      children: <Widget>[
                        const FushiIcon(FushiIcons.undo, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            FushiIconButton(
              key: const ValueKey<String>('companion-back-to-dismiss'),
              icon: FushiIcons.close,
              tooltip: t.second_screen_library_browse_back_to_dismiss,
              onTap: back.dismiss,
              padTouchTarget: true,
            ),
          ],
        ),
      );
    }
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: fushiMd3StateCurve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }
}
