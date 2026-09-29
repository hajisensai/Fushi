import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// Which edge the novel reader's settings panel docks to, independently of page
/// reading direction (the manga reader's panel is pinned to the right).
const String kReaderSettingsPanelSidePref = 'reader_settings_panel_side';

/// A full-height settings dialog whose header can move it to either screen edge.
/// The same content element survives a side change, preserving edited fields,
/// selected tabs, keyboard focus and scroll position.
Future<T?> showReaderSettingsSideDialog<T>({
  required BuildContext context,
  required PrefStore preferences,
  required WidgetBuilder builder,
}) {
  final ReaderSideSheetSide side =
      preferences.getPref(kReaderSettingsPanelSidePref) == 'left'
      ? ReaderSideSheetSide.left
      : ReaderSideSheetSide.right;
  final ValueNotifier<ReaderSideSheetSide> controller =
      ValueNotifier<ReaderSideSheetSide>(side);
  return showReaderSideSheet<T>(
    context: context,
    side: side,
    sideController: controller,
    builder: (BuildContext context) => _ReaderSettingsSideSession(
      controller: controller,
      preferences: preferences,
      child: Builder(builder: builder),
    ),
  );
}

/// Place beside a settings title. It is hidden outside a settings side dialog.
class ReaderSettingsSideButton extends StatelessWidget {
  const ReaderSettingsSideButton({super.key});

  @override
  Widget build(BuildContext context) {
    final _ReaderSettingsSideScope? scope = context
        .dependOnInheritedWidgetOfExactType<_ReaderSettingsSideScope>();
    if (scope == null) return const SizedBox.shrink();
    final bool isLeft = scope.notifier!.value == ReaderSideSheetSide.left;
    return Semantics(
      identifier: 'hibiki.reader.settings.move_side',
      child: IconButton(
        key: const ValueKey<String>('reader_settings_side_toggle'),
        tooltip: isLeft
            ? t.reader_settings_panel_move_right
            : t.reader_settings_panel_move_left,
        icon: Icon(isLeft ? Icons.last_page : Icons.first_page),
        onPressed: () async {
          final ReaderSideSheetSide next = isLeft
              ? ReaderSideSheetSide.right
              : ReaderSideSheetSide.left;
          scope.notifier!.value = next;
          await scope.preferences.setPref(
            kReaderSettingsPanelSidePref,
            next.name,
          );
        },
      ),
    );
  }
}

class _ReaderSettingsSideScope
    extends InheritedNotifier<ValueNotifier<ReaderSideSheetSide>> {
  const _ReaderSettingsSideScope({
    required ValueNotifier<ReaderSideSheetSide> controller,
    required this.preferences,
    required super.child,
  }) : super(notifier: controller);

  final PrefStore preferences;
}

// The route content owns disposal: Navigator's returned Future finishes before
// the reverse transition, while the panel/listeners remain mounted until then.
class _ReaderSettingsSideSession extends StatefulWidget {
  const _ReaderSettingsSideSession({
    required this.controller,
    required this.preferences,
    required this.child,
  });

  final ValueNotifier<ReaderSideSheetSide> controller;
  final PrefStore preferences;
  final Widget child;

  @override
  State<_ReaderSettingsSideSession> createState() =>
      _ReaderSettingsSideSessionState();
}

class _ReaderSettingsSideSessionState
    extends State<_ReaderSettingsSideSession> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  // Escape is the framework's modal DismissIntent (barrierDismissible). It only
  // failed while the reader page stole focus back on content reloads; the pages'
  // focus predicates now refuse to reclaim while a route sits above them.
  @override
  Widget build(BuildContext context) => _ReaderSettingsSideScope(
    controller: widget.controller,
    preferences: widget.preferences,
    child: widget.child,
  );
}
