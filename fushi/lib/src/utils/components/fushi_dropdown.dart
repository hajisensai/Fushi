import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_control_metrics.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

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
/// to the focused entry via FushiFocusRing). A selects, B closes the menu
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
    this.entrySubtitle,
    this.inline = false,
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
  final FushiFocusId? focusId;

  /// Optional per-entry subtitle (a second, muted line under the label inside
  /// the open menu — e.g. a latest-line preview for text threads). Returning
  /// null/empty for a value keeps that row single-line. The closed trigger
  /// still shows only the label.
  final String? Function(T value)? entrySubtitle;

  /// 与搜索框 / 筛选胶囊同排的行内用法：MD3 触发器收成与它们同高
  /// （[fushiInlineControlHeight]），不再是表单下拉的 48+ 高。Apple 路径本来
  /// 就是行内胶囊，不受影响。
  final bool inline;

  @override
  State<GamepadMenuDropdown<T>> createState() => _GamepadMenuDropdownState<T>();
}

class _GamepadMenuDropdownState<T> extends State<GamepadMenuDropdown<T>> {
  final MenuController _menu = MenuController();
  final FocusNode _triggerFocus =
      FocusNode(debugLabel: 'gamepadDropdownTrigger');
  late final FushiFocusId _fallbackFocusId = FushiFocusId(
    'gamepad-dropdown-${identityHashCode(this)}',
  );

  /// Apple 路径的菜单锚（触发器）与打开状态：Apple 下菜单走 [showFushiMenu]
  /// 的路由（从触发器变形展开、统一定位），不用 MenuAnchor。
  final GlobalKey _appleAnchorKey = GlobalKey(
    debugLabel: 'gamepadDropdownAppleAnchor',
  );
  bool _appleMenuOpen = false;

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
    final Widget menu = FushiDropdownMenu<T>(
      // Fill the bounding box (the parent, or the SizedBox below when a fixed
      // width is given) — matches the prior call sites' expandedInsets usage.
      expandedInsets: EdgeInsets.zero,
      menuHeight: menuHeight,
      inputDecorationTheme: widget.inline
          ? InputDecorationThemeData(
              isDense: true,
              constraints: BoxConstraints.tightFor(
                height: fushiInlineControlHeight(context),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            )
          : null,
      initialSelection: widget.selected,
      enabled: widget.enabled,
      label: widget.label == null ? null : Text(widget.label!),
      hintText: widget.hintText,
      dropdownMenuEntries: <DropdownMenuEntry<T>>[
        for (final GamepadDropdownEntry<T> e in widget.entries)
          DropdownMenuEntry<T>(
            value: e.value,
            label: e.label,
            labelWidget: _entryLabelWidget(context, e),
          ),
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

  /// Two-line label for the stock [DropdownMenu] path when a subtitle exists;
  /// null falls back to the plain `label` string rendering.
  Widget? _entryLabelWidget(BuildContext context, GamepadDropdownEntry<T> e) {
    final String? subtitle = widget.entrySubtitle?.call(e.value);
    if (subtitle == null || subtitle.isEmpty) return null;
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(e.label, maxLines: 2, softWrap: true),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
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
          isGlassDesign(context)
              ? _appleMenuTrigger(context)
              : _menuAnchor(context, menuWidth),
        );
        return fixedWidth == null
            ? anchor
            : SizedBox(width: fixedWidth, child: anchor);
      },
    );
  }

  Widget _focusableAnchor(BuildContext context, Widget anchor) {
    if (FushiFocusRoot.maybeControllerOf(context) == null) return anchor;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.enabled) {
              if (isGlassDesign(context)) {
                _openAppleMenu();
              } else {
                _menu.isOpen ? _menu.close() : _menu.open();
              }
            }
            return null;
          },
        ),
      },
      child: FushiFocusRegistration(
        id: widget.focusId ?? _fallbackFocusId,
        focusNode: _triggerFocus,
        enabled: widget.enabled,
        child: anchor,
      ),
    );
  }

  /// Apple 路径：触发器原样（[_trigger]），点开推 [showFushiMenu] 的菜单
  /// 路由——触发器下方 6px、至少与触发器同宽、从触发器变形展开；焦点落在
  /// 当前项，方向键 / 手柄 D-pad 在项间移动，A / Enter 选中，B / Esc 关闭并
  /// 把焦点还给触发器。
  Widget _appleMenuTrigger(BuildContext context) {
    return KeyedSubtree(
      key: _appleAnchorKey,
      child: _trigger(
        context,
        FushiDesignTokens.of(context),
        widget.enabled ? _openAppleMenu : null,
      ),
    );
  }

  Future<void> _openAppleMenu() async {
    final BuildContext? anchor = _appleAnchorKey.currentContext;
    final RenderObject? box = anchor?.findRenderObject();
    if (_appleMenuOpen ||
        anchor == null ||
        box is! RenderBox ||
        !box.hasSize ||
        widget.entries.isEmpty) {
      return;
    }
    int selected = -1;
    for (int i = 0; i < widget.entries.length; i++) {
      if (widget.entries[i].value == widget.selected) {
        selected = i;
        break;
      }
    }
    final double width = box.size.width;
    _appleMenuOpen = true;
    final int? picked = await showFushiMenu<int>(
      context: context,
      positionBuilder: fushiMenuAnchorPosition(anchor),
      initialValue: selected >= 0 ? selected : null,
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: width > 320 ? width : 320,
        maxHeight: MediaQuery.sizeOf(context).height * _kMenuMaxHeightFactor,
      ),
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < widget.entries.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: _appleEntryLabel(context, widget.entries[i]),
          ),
      ],
    );
    _appleMenuOpen = false;
    if (!mounted || picked == null || picked >= widget.entries.length) return;
    widget.onChanged(widget.entries[picked].value);
  }

  /// Apple 菜单行的文案：标题（菜单行统一给字号 / 颜色）+ 可选的次行灰字。
  Widget _appleEntryLabel(BuildContext context, GamepadDropdownEntry<T> e) {
    final String? subtitle = widget.entrySubtitle?.call(e.value);
    if (subtitle == null || subtitle.isEmpty) {
      return Text(e.label, maxLines: 2, softWrap: true);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(e.label, maxLines: 2, softWrap: true),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fushiAppleCompact(context) ? 11 : 13,
            color: appleColorsOf(context).secondaryLabel,
          ),
        ),
      ],
    );
  }

  Widget _menuAnchor(BuildContext context, double? menuWidth) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final int sel = _selectedIndex;
    // Cap the menu height so a long list (e.g. many decks) scrolls instead of
    // covering the whole screen, matching the stock DropdownMenu. The
    // gamepad-focused entry is scrolled into view by FushiFocusRing.
    final double maxHeight =
        MediaQuery.sizeOf(context).height * _kMenuMaxHeightFactor;
    return FushiMenuAnchor(
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
        return _trigger(
          context,
          tokens,
          widget.enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
        );
      },
    );
  }

  /// 收起态触发器，与库页筛选胶囊 `LibraryFilterChip` 同一套语言：无描边的
  /// 填充底 + 尾部展开箭头。给了固定 [GamepadMenuDropdown.width] 的是行内
  /// 下拉，画成全胶囊；撑满父级的（表单 / 设置行）画成输入框式填充字段，
  /// 与 `fushiMd3FieldDecoration` / Apple 文本框同圆角，和并排的输入框对齐。
  /// 墨水屏保留描边方框（填充色在灰阶下塌掉，描边才是可读的边界）。
  Widget _trigger(
    BuildContext context,
    FushiDesignTokens tokens,
    VoidCallback? onPressed,
  ) {
    // 行内用法（与搜索框同排）同样画成全胶囊，并钉成行内控件高度。
    final bool capsule = widget.width != null || widget.inline;
    final double? inlineHeight =
        widget.inline ? fushiInlineControlHeight(context) : null;
    final String text = _selectedLabel ?? widget.hintText ?? widget.label ?? '';
    if (isEinkTheme(context)) {
      return FushiOutlinedButton(
        focusNode: _triggerFocus,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
            vertical: tokens.spacing.rowVertical,
          ),
          shape: RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                softWrap: true,
                style: tokens.type.listTitle,
              ),
            ),
            FushiIcon(
              Icons.arrow_drop_down,
              color: tokens.surfaces.onVariant,
            ),
          ],
        ),
      );
    }
    if (isGlassDesign(context)) {
      // iOS / macOS 26 的 pop-up button（Niratan「Klee ⌃⌄」）：控件层，无色
      // 透明液态玻璃 bezel（不是 systemFill 灰块），label 色文字、上下双箭头，
      // 悬停 / 按下由 FushiPlainButton 给；降低透明度时玻璃回落实色。
      final FushiAppleColors apple = appleColorsOf(context);
      final bool compact = fushiAppleCompact(context);
      final bool enabled = onPressed != null;
      final double minHeight = inlineHeight ?? (compact ? 34 : 44);
      final double radius = capsule ? minHeight / 2 : 10;
      // 深色下无色透明玻璃（黑 14%）压在纯黑分组底上是隐形的，只剩文字和
      // 箭头飘着：静止态自绘 tertiarySystemFill + 0.5px 低 alpha 细描边给出
      // 轮廓（与玻璃搜索胶囊同一口径）；浅色玻璃本身是白雾面 + 投影，不叠。
      final bool dark =
          Theme.of(context).colorScheme.brightness == Brightness.dark;
      return fushiClearGlassBezel(
        context,
        radius: radius,
        child: FushiPlainButton(
          focusNode: _triggerFocus,
          onPressed: onPressed,
          borderRadius: BorderRadius.circular(radius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: dark ? apple.tertiaryFill : null,
              borderRadius: BorderRadius.circular(radius),
              border: dark
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                      width: 0.5,
                    )
                  : null,
            ),
            child: ConstrainedBox(
            constraints: inlineHeight != null
                ? BoxConstraints.tightFor(height: inlineHeight)
                : BoxConstraints(minHeight: minHeight),
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: capsule ? 14 : 12,
                  end: 10,
                  top: inlineHeight != null ? 0 : 6,
                  bottom: inlineHeight != null ? 0 : 6,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        text,
                        maxLines: inlineHeight != null ? 1 : 2,
                        softWrap: true,
                        overflow: inlineHeight != null
                            ? TextOverflow.ellipsis
                            : null,
                        style: tokens.type.listTitle.copyWith(color: apple.label),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      CupertinoIcons.chevron_up_chevron_down,
                      size: 13,
                      color: apple.secondaryLabel,
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
        ),
      );
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget md3 = FushiOutlinedButton(
      focusNode: _triggerFocus,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        minimumSize: Size(0, inlineHeight ?? (capsule ? 40 : 48)),
        // 行内：钉成 [fushiInlineControlHeight]（40），与同排搜索胶囊等高——
        // 否则 listTitle 字号 + rowVertical 内边距会把它撑到 48。
        maximumSize: inlineHeight == null
            ? null
            : Size(double.infinity, inlineHeight),
        tapTargetSize: inlineHeight == null
            ? null
            : MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsetsDirectional.only(
          start: 16,
          end: 12,
          top: inlineHeight != null ? 0 : tokens.spacing.rowVertical,
          bottom: inlineHeight != null ? 0 : tokens.spacing.rowVertical,
        ),
        backgroundColor: cs.surfaceContainerHigh,
        disabledBackgroundColor: cs.onSurface.withValues(alpha: 0.04),
        foregroundColor: cs.onSurface,
        side: BorderSide.none,
        shape: capsule
            ? const StadiumBorder()
            : RoundedRectangleBorder(borderRadius: tokens.radii.controlRadius),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              maxLines: inlineHeight != null ? 1 : 2,
              softWrap: true,
              overflow: inlineHeight != null ? TextOverflow.ellipsis : null,
              style: tokens.type.listTitle,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.expand_more_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
    return inlineHeight == null
        ? md3
        : SizedBox(height: inlineHeight, child: md3);
  }

  /// One menu entry. The selected entry gets the MD3 "selected" state — a
  /// full-row tokenized selected background plus a trailing check, so it reads
  /// as active before the gamepad focus ring lands on it.
  Widget _menuItem(
    BuildContext context,
    FushiDesignTokens tokens,
    int i,
    int sel,
    double? menuWidth,
  ) {
    final bool selected = i == sel;
    final GamepadDropdownEntry<T> entry = widget.entries[i];
    final Color foreground =
        selected ? tokens.surfaces.primary : tokens.surfaces.onSurface;
    final Widget title = Text(
      entry.label,
      maxLines: 2,
      softWrap: true,
      style: tokens.type.listTitle.copyWith(
        color: foreground,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    final String? subtitle = widget.entrySubtitle?.call(entry.value);
    final Widget text = (subtitle == null || subtitle.isEmpty)
        ? title
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              title,
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata.copyWith(
                  color: tokens.surfaces.onVariant,
                ),
              ),
            ],
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
                  child: FushiIcon(Icons.check, size: 20, color: foreground),
                ),
            ],
          )
        : Row(
            children: <Widget>[
              Expanded(child: text),
              if (selected) FushiIcon(Icons.check, size: 20, color: foreground),
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
class FushiDropdown<T> extends StatefulWidget {
  /// Define a dropdown with options and an action to do when the selected
  /// option is changed.
  const FushiDropdown({
    required this.options,
    required this.initialOption,
    required this.generateLabel,
    required this.onChanged,
    this.enabled = true,
    this.focusId,
    this.inline = false,
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
  final FushiFocusId? focusId;

  /// 见 [GamepadMenuDropdown.inline]。
  final bool inline;

  @override
  State<FushiDropdown<T>> createState() => _FushiDropdownState<T>();
}

class _FushiDropdownState<T> extends State<FushiDropdown<T>> {
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
      inline: widget.inline,
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
