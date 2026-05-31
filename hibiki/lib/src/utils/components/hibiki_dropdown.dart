import 'package:flutter/material.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;

/// A single (value, label) choice for [GamepadMenuDropdown].
typedef GamepadDropdownEntry<T> = ({T value, String label});

/// Returns true on platforms where a controller is *polled* (its D-pad arrives
/// as focus traversal, not arrow-key events). A stock Material [DropdownMenu]
/// keeps focus on its field when opened and only navigates via arrow KEY
/// events, so on these platforms a gamepad cannot enter its menu. Android
/// delivers real key events (the engine), so its DropdownMenu works as-is;
/// iOS/macOS callers use a Cupertino sheet.
bool _isPolledGamepadPlatform(BuildContext context) {
  final TargetPlatform p = Theme.of(context).platform;
  return p == TargetPlatform.windows || p == TargetPlatform.linux;
}

/// Inline dropdown a polled gamepad can actually ENTER. On desktop
/// (Windows/Linux) it is built on [MenuAnchor] so the selected entry can
/// [MenuItemButton.autofocus] when the menu opens — the cursor lands INSIDE the
/// menu and D-pad traverses it (the list auto-scrolls to the focused entry via
/// HibikiFocusRing). A selects, B closes the menu (returning focus to the
/// trigger) instead of bubbling to the GamepadService's route-pop. On every
/// other platform it falls back to a stock [DropdownMenu] (Android's engine
/// delivers real key events). Looks like an expand-in-place dropdown.
class GamepadMenuDropdown<T> extends StatefulWidget {
  const GamepadMenuDropdown({
    required this.entries,
    required this.selected,
    required this.onChanged,
    super.key,
    this.enabled = true,
    this.width,
    this.label,
    this.hintText,
  });

  final List<GamepadDropdownEntry<T>> entries;
  final T? selected;
  final ValueChanged<T> onChanged;
  final bool enabled;

  /// Fixed control width. Null lets the dropdown expand to its parent.
  final double? width;

  /// Floating label (Material [DropdownMenu] path only).
  final String? label;
  final String? hintText;

  @override
  State<GamepadMenuDropdown<T>> createState() => _GamepadMenuDropdownState<T>();
}

class _GamepadMenuDropdownState<T> extends State<GamepadMenuDropdown<T>> {
  final MenuController _menu = MenuController();
  final FocusNode _triggerFocus =
      FocusNode(debugLabel: 'gamepadDropdownTrigger');

  @override
  void dispose() {
    _triggerFocus.dispose();
    super.dispose();
  }

  int get _selectedIndex {
    for (int i = 0; i < widget.entries.length; i++) {
      if (widget.entries[i].value == widget.selected) return i;
    }
    return 0;
  }

  String? get _selectedLabel {
    for (final GamepadDropdownEntry<T> e in widget.entries) {
      if (e.value == widget.selected) return e.label;
    }
    return null;
  }

  void _closeAndRefocus() {
    _menu.close();
    _triggerFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isPolledGamepadPlatform(context)) {
      return _buildStockDropdown();
    }
    return _buildMenuAnchor(context);
  }

  Widget _buildStockDropdown() {
    final Widget menu = DropdownMenu<T>(
      // Fill the bounding box (the parent, or the SizedBox below when a fixed
      // width is given) — matches the prior call sites' expandedInsets usage.
      expandedInsets: EdgeInsets.zero,
      initialSelection: widget.selected,
      enabled: widget.enabled,
      label: widget.label == null ? null : Text(widget.label!),
      hintText: widget.hintText,
      dropdownMenuEntries: <DropdownMenuEntry<T>>[
        for (final GamepadDropdownEntry<T> e in widget.entries)
          DropdownMenuEntry<T>(value: e.value, label: e.label),
      ],
      onSelected: widget.enabled
          ? (T? value) {
              if (value != null) widget.onChanged(value);
            }
          : null,
    );
    return widget.width == null
        ? menu
        : SizedBox(width: widget.width, child: menu);
  }

  Widget _buildMenuAnchor(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int sel = _selectedIndex;
    final Widget anchor = MenuAnchor(
      controller: _menu,
      childFocusNode: _triggerFocus,
      style: (widget.width != null && widget.width!.isFinite)
          ? MenuStyle(
              minimumSize: WidgetStatePropertyAll<Size>(Size(widget.width!, 0)),
            )
          : null,
      menuChildren: <Widget>[
        for (int i = 0; i < widget.entries.length; i++)
          Actions(
            // B closes the menu and returns focus to the trigger, instead of
            // bubbling to the GamepadService's route-pop (which would exit the
            // page). Other buttons fall through: A activates the focused entry
            // (→ onPressed), D-pad traverses the entries.
            actions: <Type, Action<Intent>>{
              GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
                onInvoke: (GamepadButtonIntent intent) {
                  if (intent.button == GamepadButton.b) {
                    _closeAndRefocus();
                    return true;
                  }
                  return null;
                },
              ),
            },
            child: MenuItemButton(
              autofocus: i == sel,
              onPressed: () => widget.onChanged(widget.entries[i].value),
              child: Text(widget.entries[i].label),
            ),
          ),
      ],
      builder:
          (BuildContext context, MenuController controller, Widget? child) {
        return OutlinedButton(
          focusNode: _triggerFocus,
          onPressed: widget.enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _selectedLabel ?? widget.hintText ?? widget.label ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        );
      },
    );
    return widget.width == null
        ? anchor
        : SizedBox(width: widget.width, child: anchor);
  }
}

/// A helper for creating a dropdown styled for the application. Gamepad-enterable
/// on desktop (delegates to [GamepadMenuDropdown]); a stock [DropdownMenu]
/// elsewhere.
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
    final List<T> uniqueOptions = widget.options.toSet().toList();
    T? dropdownValue = selectedOption;
    if (!uniqueOptions.contains(dropdownValue)) {
      dropdownValue = uniqueOptions.isNotEmpty ? uniqueOptions.first : null;
    }

    return GamepadMenuDropdown<T>(
      enabled: widget.enabled,
      selected: dropdownValue,
      onChanged: _onSelected,
      entries: <GamepadDropdownEntry<T>>[
        for (final T value in uniqueOptions)
          (value: value, label: widget.generateLabel(value)),
      ],
    );
  }

  void _onSelected(T? value) {
    widget.onChanged(value);

    setState(() {
      selectedOption = value;
    });
  }
}
