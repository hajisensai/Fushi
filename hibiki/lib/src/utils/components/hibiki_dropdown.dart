import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// A single (value, label) choice for [GamepadMenuDropdown].
typedef GamepadDropdownEntry<T> = ({T value, String label});

/// Fraction of the screen height a dropdown menu may occupy. Caps both the
/// stock Android [DropdownMenu] and the polled-platform [MenuAnchor] so a long
/// option list scrolls within the viewport instead of overflowing off-screen.
const double _kMenuMaxHeightFactor = 0.6;

/// Returns true on platforms where a controller is *polled* (its D-pad arrives
/// as focus traversal, not arrow-key events). A stock Material [DropdownMenu]
/// keeps focus on its field when opened and only navigates via arrow KEY
/// events, so on these platforms a gamepad cannot enter its menu. Only Android
/// delivers controllers as real engine key events, so its DropdownMenu works
/// as-is; every other platform — Windows, Linux, iOS, macOS — is polled and
/// takes the gamepad-enterable [MenuAnchor] path, so all controls answer the
/// same navigation intents instead of relying on a DropdownMenu silently
/// consuming arrow keys. The polled set mirrors
/// `GamepadService.needsGamepadPoller` (host-keyed); this is Theme-keyed so
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
    this.focusId,
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
  final HibikiFocusId? focusId;

  @override
  State<GamepadMenuDropdown<T>> createState() => _GamepadMenuDropdownState<T>();
}

class _GamepadMenuDropdownState<T> extends State<GamepadMenuDropdown<T>> {
  final MenuController _menu = MenuController();
  final FocusNode _triggerFocus =
      FocusNode(debugLabel: 'gamepadDropdownTrigger');
  late final HibikiFocusId _fallbackFocusId = HibikiFocusId(
    'gamepad-dropdown-${identityHashCode(this)}',
  );

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
      return _buildStockDropdown(context);
    }
    return _buildMenuAnchor(context);
  }

  Widget _buildStockDropdown(BuildContext context) {
    // Cap the menu height to a fraction of the screen so a long list (e.g. the
    // 17 app languages, dozens of Anki decks) scrolls WITHIN the viewport
    // instead of running its bottom entries off the screen edge — unreachable
    // because the overlay is anchored, not scrolled. Mirrors the polled-platform
    // MenuAnchor cap in [_menuAnchor]; the stock DropdownMenu has no implicit
    // bound, so it must be set explicitly.
    final double menuHeight =
        MediaQuery.sizeOf(context).height * _kMenuMaxHeightFactor;
    final Widget menu = DropdownMenu<T>(
      // Fill the bounding box (the parent, or the SizedBox below when a fixed
      // width is given) — matches the prior call sites' expandedInsets usage.
      expandedInsets: EdgeInsets.zero,
      menuHeight: menuHeight,
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
        final Widget anchor = _focusableAnchor(
          context,
          _menuAnchor(context, menuWidth),
        );
        return fixedWidth == null
            ? anchor
            : SizedBox(width: fixedWidth, child: anchor);
      },
    );
  }

  Widget _focusableAnchor(BuildContext context, Widget anchor) {
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return anchor;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.enabled) {
              _menu.isOpen ? _menu.close() : _menu.open();
            }
            return null;
          },
        ),
      },
      child: HibikiFocusRegistration(
        id: widget.focusId ?? _fallbackFocusId,
        focusNode: _triggerFocus,
        enabled: widget.enabled,
        child: anchor,
      ),
    );
  }

  Widget _menuAnchor(BuildContext context, double? menuWidth) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final int sel = _selectedIndex;
    // Cap the menu height so a long list (e.g. many decks) scrolls instead of
    // covering the whole screen, matching the stock DropdownMenu. The
    // gamepad-focused entry is scrolled into view by HibikiFocusRing.
    final double maxHeight =
        MediaQuery.sizeOf(context).height * _kMenuMaxHeightFactor;
    return MenuAnchor(
      controller: _menu,
      childFocusNode: _triggerFocus,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(tokens.surfaces.overlay),
        surfaceTintColor:
            const WidgetStatePropertyAll<Color>(Colors.transparent),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: tokens.radii.menuRadius),
        ),
        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        ),
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
          _menuItem(context, tokens, i, sel, menuWidth),
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
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
            shape:
                RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _selectedLabel ?? widget.hintText ?? widget.label ?? '',
                  maxLines: 2,
                  softWrap: true,
                  style: tokens.type.listTitle,
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                color: tokens.surfaces.onVariant,
              ),
            ],
          ),
        );
      },
    );
  }

  /// One menu entry. The selected entry gets the MD3 "selected" state — a
  /// full-row tokenized selected background plus a trailing check, so it reads
  /// as active before the gamepad focus ring lands on it.
  Widget _menuItem(
    BuildContext context,
    HibikiDesignTokens tokens,
    int i,
    int sel,
    double? menuWidth,
  ) {
    final bool selected = i == sel;
    final GamepadDropdownEntry<T> entry = widget.entries[i];
    final Color foreground =
        selected ? tokens.surfaces.primary : tokens.surfaces.onSurface;
    final Widget text = Text(
      entry.label,
      maxLines: 2,
      softWrap: true,
      style: tokens.type.listTitle.copyWith(
        color: foreground,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    // Flex (Expanded) needs a bounded width; only the pinned-width menu hands
    // the item finite constraints. The unbounded fallback uses a min-size row
    // so a flex child can never assert against infinite width.
    final Widget label = menuWidth == null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              text,
              if (selected)
                Padding(
                  padding: EdgeInsets.only(left: tokens.spacing.gap),
                  child: Icon(Icons.check, size: 20, color: foreground),
                ),
            ],
          )
        : Row(
            children: <Widget>[
              Expanded(child: text),
              if (selected) Icon(Icons.check, size: 20, color: foreground),
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
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
          ),
          alignment: Alignment.centerLeft,
          backgroundColor: selected ? tokens.surfaces.selected : null,
          foregroundColor: foreground,
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
    this.focusId,
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
  final HibikiFocusId? focusId;

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
      focusId: widget.focusId,
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
