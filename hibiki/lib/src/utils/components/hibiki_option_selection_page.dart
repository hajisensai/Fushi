import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// Option count above which [HibikiOptionSelectionPage] shows a search field by
/// default (when `searchable` is left null).
const int kOptionSelectionSearchThreshold = 12;

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
  bool? searchable,
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
        searchable: searchable,
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
class HibikiOptionSelectionPage<T> extends StatefulWidget {
  const HibikiOptionSelectionPage({
    required this.title,
    required this.options,
    required this.selected,
    super.key,
    this.searchable,
  });

  final String title;
  final List<HibikiOptionSelectionOption<T>> options;
  final T? selected;

  /// Null lets the page show a search field automatically once the option
  /// count exceeds [kOptionSelectionSearchThreshold].
  final bool? searchable;

  @override
  State<HibikiOptionSelectionPage<T>> createState() =>
      _HibikiOptionSelectionPageState<T>();
}

class _HibikiOptionSelectionPageState<T>
    extends State<HibikiOptionSelectionPage<T>> {
  final TextEditingController _searchController = TextEditingController();
  late List<HibikiOptionSelectionOption<T>> _filtered = widget.options;

  bool get _searchable =>
      widget.searchable ??
      widget.options.length > kOptionSelectionSearchThreshold;

  void _onSearch(String query) {
    final String q = query.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? widget.options
          : widget.options
              .where((HibikiOptionSelectionOption<T> o) =>
                  o.label.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // Single-choice list: the selected entry shows a trailing check, every
    // other entry is a plain tappable row. No navigation chevron — tapping an
    // option pops this page with its value, it does not drill into a subpage,
    // so a `chevron_right` would falsely imply a deeper level.
    final List<Widget> rows = _filtered.map((HibikiOptionSelectionOption<T> o) {
      final bool selected = o.value == widget.selected;
      return AdaptiveSettingsRow(
        title: o.label,
        trailing: selected ? Icon(Icons.check, color: scheme.primary) : null,
        onTap: selected ? null : () => Navigator.pop(context, o.value),
      );
    }).toList();

    return AdaptiveSettingsScaffold(
      title: Text(widget.title),
      children: <Widget>[
        if (_searchable)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: HibikiTextField(
              controller: _searchController,
              hintText: t.search,
              onChanged: _onSearch,
              contentPadding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.rowHorizontal,
                vertical: tokens.spacing.rowVertical,
              ),
            ),
          ),
        AdaptiveSettingsSection(children: rows),
      ],
    );
  }
}
