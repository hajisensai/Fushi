import 'package:flutter/material.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;

/// A single (value, label) choice for [GamepadMenuDropdown].
typedef GamepadDropdownEntry<T> = ({T value, String label});

/// Returns true on platforms where a controller is *polled* (its D-pad arrives
/// as focus traversal, not arrow-key events). A stock Material [DropdownMenu]
/// keeps focus on its field when opened and only navigates via arrow KEY
/// events, so on these platforms a gamepad cannot enter its menu. Only Android
/// delivers controllers as real engine key events, so its DropdownMenu works
/// as-is; every other platform — Windows, Linux, iOS, macOS — is polled and
/// takes the gamepad-enterable [MenuAnchor] path, so all controls answer the
/// same navigation intents instead of relying on a DropdownMenu silently
/// consuming arrow keys. The polled set mirrors
/// `GamepadService.isSupportedPlatform` (host-keyed); this is Theme-keyed so
/// widget tests can simulate the platform.
bool _isPolledGamepadPlatform(BuildContext context) {
  return Theme.of(context).platform != TargetPlatform.android;
}

/// Inline dropdown a polled gamepad can actually ENTER. On every polled
/// platform (Windows, Linux, iOS, macOS) it is built on [MenuAnchor] so the
/// selected entry can [MenuItemButton.autofocus] when the menu opens — the
/// cursor lands INSIDE the menu and D-pad traverses it (the list auto-scrolls
/// to the focused entry via HibikiFocusRing). A selects, B closes the menu
/// (returning focus to the trigger) instead of bubbling to the GamepadService's
/// route-pop. Only on Android does it fall back to a stock [DropdownMenu] (the
/// engine delivers real key events there). Looks like an expand-in-place
/// dropdown.
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
    // MD3 Exposed Dropdown: the menu width equals the trigger width. Measure
    // the width the parent allotted us (the trigger fills it) so the menu can
    // be pinned to the same value. An explicit finite width wins; otherwise we
    // fill — and pin the menu to — the parent's width.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double? fixedWidth =
            (widget.width != null && widget.width!.isFinite)
                ? widget.width
                : null;
        final double? menuWidth = fixedWidth ??
            (constraints.maxWidth.isFinite ? constraints.maxWidth : null);
        final Widget anchor = _menuAnchor(context, menuWidth);
        return fixedWidth == null
            ? anchor
            : SizedBox(width: fixedWidth, child: anchor);
      },
    );
  }

  Widget _menuAnchor(BuildContext context, double? menuWidth) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final int sel = _selectedIndex;
    // Cap the menu height so a long list (e.g. many decks) scrolls instead of
    // covering the whole screen, matching the stock DropdownMenu. The
    // gamepad-focused entry is scrolled into view by HibikiFocusRing.
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.6;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _triggerFocus,
      style: MenuStyle(
        // Pin the menu panel width to the trigger width (min == max → the menu
        // matches the anchor). A null width (unbounded parent) keeps content
        // sizing, the prior behavior.
        minimumSize: menuWidth == null
            ? null
            : WidgetStatePropertyAll<Size>(Size(menuWidth, 0)),
        maximumSize: WidgetStatePropertyAll<Size>(
          Size(menuWidth ?? double.infinity, maxHeight),
        ),
      ),
      menuChildren: <Widget>[
        for (int i = 0; i < widget.entries.length; i++)
          _menuItem(context, colors, i, sel, menuWidth),
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
  }

  /// One menu entry. The selected entry gets the MD3 "selected" state — a
  /// full-row [ColorScheme.secondaryContainer] background plus a trailing check
  /// — so it reads as active before the gamepad focus ring lands on it. Items
  /// are 48dp tall with 12dp side padding and fill the (pinned) menu width.
  Widget _menuItem(
    BuildContext context,
    ColorScheme colors,
    int i,
    int sel,
    double? menuWidth,
  ) {
    final bool selected = i == sel;
    final GamepadDropdownEntry<T> entry = widget.entries[i];
    final Widget text = Text(entry.label, overflow: TextOverflow.ellipsis);
    // Flex (Expanded) needs a bounded width; only the pinned-width menu hands
    // the item finite constraints. The unbounded fallback uses a min-size row
    // so a flex child can never assert against infinite width.
    final Widget label = menuWidth == null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              text,
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.check, size: 20),
                ),
            ],
          )
        : Row(
            children: <Widget>[
              Expanded(child: text),
              if (selected) const Icon(Icons.check, size: 20),
            ],
          );
    return Actions(
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
        autofocus: selected,
        onPressed: () => widget.onChanged(entry.value),
        style: MenuItemButton.styleFrom(
          minimumSize: Size(menuWidth ?? 0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          backgroundColor: selected ? colors.secondaryContainer : null,
          foregroundColor: selected ? colors.onSecondaryContainer : null,
        ),
        child: label,
      ),
    );
  }
}

/// A helper for creating a dropdown styled for the application. Delegates to
/// [GamepadMenuDropdown]: a gamepad-enterable [MenuAnchor] on every polled
/// platform (Windows/Linux/iOS/macOS) and a stock [DropdownMenu] on Android.
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
