import 'package:flutter/material.dart';

/// A helper for creating a [DropdownMenu] styled for the application.
class HibikiDropdown<T> extends StatefulWidget {
  /// Define a dropdown with options and an action to do when the selected
  /// option is changed.
  const HibikiDropdown({
    required this.options,
    required this.initialOption,
    required this.generateLabel,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  /// List of options that are available to pick from.
  final List<T> options;

  /// An option that will appear as default when this dropdown appears for the
  /// first time. Must be an option available in [options].
  final T initialOption;

  /// A function that converts a [T] to a usable label.
  final String Function(T) generateLabel;

  /// A callback that will occur when a new option has been selected.
  final Function(T?) onChanged;

  /// Whether the button allows changing the option or not.
  final bool enabled;

  @override
  State<HibikiDropdown<T>> createState() => _HibikiDropdownState<T>();
}

class _HibikiDropdownState<T> extends State<HibikiDropdown<T>> {
  late T? selectedOption;

  @override
  void initState() {
    selectedOption = widget.initialOption;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final uniqueOptions = widget.options.toSet().toList();
    T? dropdownValue = selectedOption;
    if (!uniqueOptions.contains(dropdownValue)) {
      dropdownValue = uniqueOptions.isNotEmpty ? uniqueOptions.first : null;
    }

    return DropdownMenu<T>(
      expandedInsets: EdgeInsets.zero,
      initialSelection: dropdownValue,
      enabled: widget.enabled,
      dropdownMenuEntries: uniqueOptions.map((value) {
        final String text = widget.generateLabel(value);
        return DropdownMenuEntry<T>(value: value, label: text);
      }).toList(),
      onSelected: widget.enabled ? _onSelected : null,
    );
  }

  void _onSelected(T? value) {
    widget.onChanged(value);

    setState(() {
      selectedOption = value;
    });
  }
}
