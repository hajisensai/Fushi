import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// One selectable (value, label) entry for [HibikiOptionSelectionPage].
class HibikiOptionSelectionOption<T> {
  const HibikiOptionSelectionOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// Pushes a [HibikiOptionSelectionPage] and resolves to the chosen value, or
/// null when the user backs out without picking.
Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<HibikiOptionSelectionOption<T>> options,
  required T? selected,
}) {
  return Navigator.of(context).push<T>(
    // Adaptive route so iOS/macOS get the Cupertino transition + swipe-back
    // gesture (the page body already adapts via AdaptiveSettingsScaffold).
    adaptivePageRoute<T>(
      context: context,
      builder: (_) => HibikiOptionSelectionPage<T>(
        title: title,
        options: options,
        selected: selected,
      ),
    ),
  );
}

/// A bounded, full-page single-choice list. Replaces anchored overlay dropdowns
/// (DropdownMenu / MenuAnchor / CupertinoActionSheet) for option sets large
/// enough to overflow the screen: the page is a normal scrollable
/// [AdaptiveSettingsScaffold], so every entry is reachable and the last option
/// can never be clipped off the bottom. The selected entry shows a trailing
/// check; tapping any other entry pops the page with that entry's value.
class HibikiOptionSelectionPage<T> extends StatelessWidget {
  const HibikiOptionSelectionPage({
    required this.title,
    required this.options,
    required this.selected,
    super.key,
  });

  final String title;
  final List<HibikiOptionSelectionOption<T>> options;
  final T? selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // Single-choice list: the selected entry shows a trailing check, every
    // other entry is a plain tappable row. No navigation chevron — tapping an
    // option pops this page with its value, it does not drill into a subpage,
    // so a `chevron_right` would falsely imply a deeper level.
    final List<Widget> rows = options.map((HibikiOptionSelectionOption<T> o) {
      final bool isSelected = o.value == selected;
      return AdaptiveSettingsRow(
        title: o.label,
        trailing: isSelected ? Icon(Icons.check, color: scheme.primary) : null,
        onTap: isSelected ? null : () => Navigator.pop(context, o.value),
      );
    }).toList();

    return AdaptiveSettingsScaffold(
      title: Text(title),
      children: <Widget>[
        AdaptiveSettingsSection(children: rows),
      ],
    );
  }
}
