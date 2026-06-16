import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_dropdown.dart';
import 'package:hibiki/src/utils/components/hibiki_focusable.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/hibiki_option_selection_page.dart';

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.text, {super.key, this.padding});
  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: HibikiDesignTokens.of(context).type.sectionLabel,
      ),
    );
  }
}

const kSettingsSegmentedStyle = ButtonStyle(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// An [AdaptiveSettingsPickerRow] with more options than this renders as a
/// chevron navigation row that pushes a bounded full-page selector instead of
/// an inline overlay dropdown / action sheet — the overlay's anchored height
/// would otherwise run a long list (app languages, dozens of Anki decks) off
/// the screen edge. Short option sets keep the inline control.
const int kSettingsPickerInlineLimit = 8;

class AdaptiveSettingsScaffold extends StatelessWidget {
  const AdaptiveSettingsScaffold({
    required this.title,
    required this.children,
    super.key,
    this.actions,
    this.padding,
  });

  final Widget title;
  final List<Widget> children;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final EdgeInsetsGeometry listPadding = padding ??
        EdgeInsets.fromLTRB(
          cupertino ? 12 : 16,
          cupertino ? 10 : 8,
          cupertino ? 12 : 16,
          8 + mediaPadding.bottom,
        );

    if (cupertino) {
      return CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
          context,
        ),
        child: CustomScrollView(
          slivers: <Widget>[
            CupertinoSliverNavigationBar(
              largeTitle: title,
              trailing: actions != null && actions!.isNotEmpty
                  ? Row(mainAxisSize: MainAxisSize.min, children: actions!)
                  : null,
            ),
            SliverPadding(
              padding: listPadding,
              sliver: SliverList(
                delegate: SliverChildListDelegate(children),
              ),
            ),
          ],
        ),
      );
    }

    return HibikiToolScaffold.customTitle(
      title: title,
      actions: actions ?? const <Widget>[],
      body: ListView(
        padding: listPadding,
        children: children,
      ),
    );
  }
}

enum SettingsSectionTitlePlacement { outside, inside }

class AdaptiveSettingsSurface extends StatelessWidget {
  const AdaptiveSettingsSurface({
    required this.child,
    super.key,
    this.title,
    this.color,
    this.contentPadding = EdgeInsets.zero,
  });

  final Widget child;
  final String? title;
  final Color? color;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null && title!.isNotEmpty)
          _buildContainedTitle(context, tokens, cupertino),
        Padding(
          padding: contentPadding,
          child: child,
        ),
      ],
    );

    if (cupertino) {
      return ClipRRect(
        borderRadius: tokens.radii.groupRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground
                .resolveFrom(context),
            borderRadius: tokens.radii.groupRadius,
          ),
          child: content,
        ),
      );
    }

    return HibikiCard(
      padding: EdgeInsets.zero,
      borderRadius: tokens.radii.groupRadius,
      color: color ?? tokens.surfaces.group,
      child: content,
    );
  }

  Widget _buildContainedTitle(
    BuildContext context,
    HibikiDesignTokens tokens,
    bool cupertino,
  ) {
    if (cupertino) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(
          title!.toUpperCase(),
          style: tokens.type.metadata.copyWith(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return SettingsSectionHeader(
      title!,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    );
  }
}

class AdaptiveSettingsSection extends StatelessWidget {
  const AdaptiveSettingsSection({
    required this.children,
    super.key,
    this.title,
    this.titlePlacement = SettingsSectionTitlePlacement.outside,
    this.surfaceColor,
  });

  final String? title;
  final List<Widget> children;
  final SettingsSectionTitlePlacement titlePlacement;
  final Color? surfaceColor;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool titleInside =
        titlePlacement == SettingsSectionTitlePlacement.inside;
    final List<Widget> rows = _withDividers(context, children);
    final Widget group = AdaptiveSettingsSurface(
      title: titleInside ? title : null,
      color: surfaceColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: cupertino ? 14 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!titleInside && title != null && title!.isNotEmpty)
            cupertino
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Text(
                      title!.toUpperCase(),
                      style: tokens.type.metadata.copyWith(
                        color:
                            CupertinoColors.secondaryLabel.resolveFrom(context),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : SettingsSectionHeader(
                    title!,
                    padding: const EdgeInsets.only(bottom: 6),
                  ),
          group,
        ],
      ),
    );
  }

  List<Widget> _withDividers(BuildContext context, List<Widget> rows) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color dividerColor = cupertino
        ? CupertinoColors.separator.resolveFrom(context)
        : Theme.of(context).colorScheme.outlineVariant;
    final List<Widget> result = <Widget>[];
    for (int i = 0; i < rows.length; i++) {
      if (i > 0) {
        result.add(Divider(
          height: 1,
          thickness: 0.5,
          indent: cupertino ? 16 : 0,
          color: dividerColor,
        ));
      }
      result.add(rows[i]);
    }
    return result;
  }
}

class AdaptiveSettingsRow extends StatelessWidget {
  const AdaptiveSettingsRow({
    required this.title,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.trailing,
    this.onTap,
    this.controlBelow = false,
    this.trailingFlexible = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showIcon;

  /// CONTRACT: [trailing] must be self-sizing. With [controlBelow] false it is
  /// placed as a NON-flex child of a Row that also has an `Expanded` label, so
  /// RenderFlex measures it with UNBOUNDED main-axis width. A trailing whose
  /// top-level layout demands width (a bare `Expanded`/`Flexible(tight)`, or a
  /// `DropdownMenu(expandedInsets: …)` without a bounding `SizedBox`) throws
  /// "RenderFlex children have non-zero flex but incoming width constraints are
  /// unbounded". Bound such controls (e.g. `SizedBox(width: …)`, as
  /// [AdaptiveSettingsPickerRow] does), set [trailingFlexible] for a control
  /// that should shrink-and-scroll, or pass them via [controlBelow] instead.
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool controlBelow;

  /// When true (and [controlBelow] is false), [trailing] is hosted as a
  /// `Flexible(fit: loose)` child of the inline Row instead of a non-flex one,
  /// so it receives BOUNDED main-axis constraints. Use this for an intrinsically
  /// wide control wrapped in a horizontal scroll view (e.g. a `SegmentedButton`
  /// in [AdaptiveSettingsSegmentedRow]): with bounded width the scroll view
  /// actually scrolls instead of overflowing the row. Self-sizing controls
  /// (switches, steppers) must leave this false so the label stays greedy.
  final bool trailingFlexible;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Widget content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: cupertino ? 16 : 12,
        vertical: controlBelow ? 10 : 8,
      ),
      child:
          controlBelow ? _buildColumnLayout(context) : _buildRowLayout(context),
    );

    if (onTap == null) return content;
    final bool hasFocusRoot =
        HibikiFocusRoot.maybeControllerOf(context) != null;
    if (!hasFocusRoot) {
      return cupertino
          // Cupertino has no InkWell; HibikiFocusable keeps the row reachable by
          // directional focus navigation (gamepad/keyboard) instead of a bare,
          // unfocusable GestureDetector.
          ? HibikiFocusable(
              onTap: onTap,
              borderRadius: BorderRadius.zero,
              child: content,
            )
          : InkWell(
              onTap: onTap,
              child: content,
            );
    }
    final Widget tappable = cupertino
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: content,
          )
        : InkWell(
            onTap: onTap,
            child: content,
          );
    return _SettingsRowFocusTarget(
      onTap: onTap!,
      child: tappable,
    );
  }

  Widget _buildRowLayout(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: isCupertinoPlatform(context) ? 46 : 48,
      ),
      child: Row(
        children: [
          if (showIcon && icon != null) ...[
            _SettingsIcon(icon: icon!),
            const SizedBox(width: 12),
          ],
          Expanded(child: _SettingsLabel(title: title, subtitle: subtitle)),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            // A flexible trailing receives bounded width so an inner horizontal
            // scroll view scrolls instead of overflowing (see [trailingFlexible]).
            if (trailingFlexible)
              Flexible(fit: FlexFit.loose, child: trailing!)
            else
              trailing!,
          ],
        ],
      ),
    );
  }

  Widget _buildColumnLayout(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: isCupertinoPlatform(context) ? 58 : 60,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showIcon && icon != null) ...[
                _SettingsIcon(icon: icon!),
                const SizedBox(width: 12),
              ],
              Expanded(child: _SettingsLabel(title: title, subtitle: subtitle)),
            ],
          ),
          if (trailing != null) ...[
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: trailing!),
          ],
        ],
      ),
    );
  }
}

class _SettingsRowFocusTarget extends StatefulWidget {
  const _SettingsRowFocusTarget({
    required this.onTap,
    required this.child,
  });

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_SettingsRowFocusTarget> createState() =>
      _SettingsRowFocusTargetState();
}

class _SettingsRowFocusTargetState extends State<_SettingsRowFocusTarget> {
  late final HibikiFocusId _focusId = HibikiFocusId(
    'settings-row-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: _focusId,
        child: widget.child,
      ),
    );
  }
}

class AdaptiveSettingsSwitchRow extends StatelessWidget {
  const AdaptiveSettingsSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: adaptiveSwitch(
        context: context,
        value: value,
        onChanged: onChanged,
      ),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

class AdaptiveSettingsSwitchActionRow extends StatelessWidget {
  const AdaptiveSettingsSwitchActionRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.body,
    this.actions = const <Widget>[],
    this.panel,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? body;
  final List<Widget> actions;
  final Widget? panel;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    final Widget switchControl = adaptiveSwitch(
      context: context,
      value: value,
      onChanged: onChanged,
    );
    final bool stacked = controlBelow || body != null || panel != null;
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: stacked,
      trailing: stacked
          ? _buildStackedTrailing(switchControl)
          : _buildInlineTrailing(switchControl),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }

  Widget _buildInlineTrailing(Widget switchControl) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._spacedActions(),
        if (actions.isNotEmpty) const SizedBox(width: 6),
        switchControl,
      ],
    );
  }

  Widget _buildStackedTrailing(Widget switchControl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (body != null) Expanded(child: body!) else const Spacer(),
            ..._spacedActions(),
            if (actions.isNotEmpty) const SizedBox(width: 6),
            switchControl,
          ],
        ),
        if (panel != null) ...[
          const SizedBox(height: 8),
          panel!,
        ],
      ],
    );
  }

  List<Widget> _spacedActions() {
    final List<Widget> spaced = <Widget>[];
    for (int i = 0; i < actions.length; i++) {
      spaced.add(Padding(
        padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
        child: actions[i],
      ));
    }
    return spaced;
  }
}

class AdaptiveSettingsSegmentedRow<T extends Object> extends StatelessWidget {
  const AdaptiveSettingsSegmentedRow({
    required this.title,
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.controlBelow = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// A segmented strip is an intrinsically WIDE, multi-option control. Hosted
  /// inline ([controlBelow] false) it shares the row with an `Expanded` label,
  /// and RenderFlex splits the width by flex (≈50/50) — so a strip wider than
  /// its share is clipped/scrolled and trailing segments fall off the right
  /// edge (the reported 设计系统/深色模式 bug, BUG-008). Default is therefore
  /// [controlBelow] true: the strip gets its own full-width row below the
  /// label, showing every segment and scrolling only when the pane is genuinely
  /// narrower than the strip. Pass `controlBelow: false` only for a short strip
  /// that must sit inline next to a short label.
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    // A segmented row is a discrete-valued control: register it as a SINGLE
    // gamepad/keyboard focus stop (like the stepper/slider rows) so geometric
    // focus navigation can land on it, and D-pad Left/Right steps the segment
    // in place (clamped at the ends, no wrap). Without this wrapper the row
    // carries no HibikiFocusTarget (its
    // AdaptiveSettingsRow has no onTap), so it is invisible to directional
    // navigation — the cursor skips the whole layout section.
    final int currentIndex =
        segments.indexWhere((ButtonSegment<T> s) => s.value == selected);
    void selectAt(int index) {
      if (segments.isEmpty) return;
      final int clamped = index.clamp(0, segments.length - 1);
      final T value = segments[clamped].value;
      if (value != selected) onChanged(value);
    }

    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: controlBelow,
      // The segmented strip is intrinsically wide and wrapped in a horizontal
      // scroll view; host it as a flexible (bounded-width) trailing so it
      // shrink-and-scrolls on narrow panes instead of overflowing the row.
      trailingFlexible: true,
      trailing: _GamepadAdjustableValue(
        focusIdPrefix: 'settings-segmented',
        onIncrement: () => selectAt(currentIndex + 1),
        onDecrement: () => selectAt(currentIndex - 1),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: adaptiveSegmentedButton<T>(
            context: context,
            segments: segments,
            selected: <T>{selected},
            onSelectionChanged: (Set<T> values) {
              if (values.isEmpty) return;
              onChanged(values.first);
            },
            style: kSettingsSegmentedStyle,
          ),
        ),
      ),
    );
  }
}

/// Registers a STANDALONE [adaptiveSegmentedButton] (one NOT hosted by an
/// [AdaptiveSettingsSegmentedRow] — e.g. a segmented selector inside a dialog
/// header) as a single gamepad/keyboard focus stop, with D-pad Left/Right
/// cycling the selection in place. Without this the segmented strip is a cluster
/// of native buttons that the directional [HibikiFocusController] — which walks
/// only registered targets — skips entirely. Pass the already-built segmented
/// button (or its scroll wrapper) as [child]; it is excluded from inner focus
/// traversal so this is the one stop, while staying mouse/touch-tappable.
class HibikiAdjustableSegmented<T extends Object> extends StatelessWidget {
  const HibikiAdjustableSegmented({
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.child,
    super.key,
    this.focusIdPrefix = 'segmented',
  });

  /// The segment values in display order; [selected] must be one of them.
  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final Widget child;
  final String focusIdPrefix;

  @override
  Widget build(BuildContext context) {
    final int currentIndex = values.indexOf(selected);
    void selectAt(int index) {
      if (values.isEmpty) return;
      final int clamped = index.clamp(0, values.length - 1);
      final T value = values[clamped];
      if (value != selected) onChanged(value);
    }

    return _GamepadAdjustableValue(
      focusIdPrefix: focusIdPrefix,
      onIncrement: () => selectAt(currentIndex + 1),
      onDecrement: () => selectAt(currentIndex - 1),
      child: child,
    );
  }
}

class AdaptiveSettingsPickerOption<T> {
  const AdaptiveSettingsPickerOption({
    required this.value,
    required this.label,
  });

  final T value;
  final String label;
}

class AdaptiveSettingsPickerRow<T> extends StatelessWidget {
  const AdaptiveSettingsPickerRow({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.placeholder,
    this.materialWidth,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<AdaptiveSettingsPickerOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final String? placeholder;
  final double? materialWidth;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    if (options.length > kSettingsPickerInlineLimit) {
      return _buildFullPageRow(context);
    }
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controlBelow: cupertino ? false : controlBelow,
      trailing: cupertino
          ? _buildCupertinoTrailing(context)
          : _buildMaterialDropdown(context),
      onTap: cupertino ? () => _showCupertinoPicker(context) : null,
    );
  }

  /// Long option sets route to a bounded full-page selector
  /// ([HibikiOptionSelectionPage]) instead of an anchored overlay that could
  /// overflow the screen. The chosen entry is reported through [onChanged];
  /// backing out (null result) leaves the selection unchanged. Index-keyed so
  /// the page never needs `==`/hashCode on [T].
  Widget _buildFullPageRow(BuildContext context) {
    return AdaptiveSettingsNavigationRow(
      title: title,
      subtitle: _selectedLabel ?? placeholder,
      icon: icon,
      showIcon: icon != null,
      onTap: () async {
        final int? index = await pickOption<int>(
          context,
          title: title,
          selected: _selectedIndex,
          options: <HibikiOptionSelectionOption<int>>[
            for (int i = 0; i < options.length; i++)
              HibikiOptionSelectionOption<int>(
                value: i,
                label: options[i].label,
              ),
          ],
        );
        if (index != null) onChanged(options[index].value);
      },
    );
  }

  Widget _buildMaterialDropdown(BuildContext context) {
    // GamepadMenuDropdown renders a stock DropdownMenu on Android (engine
    // delivers real key events) and a gamepad-enterable MenuAnchor on desktop
    // (a polled gamepad's D-pad is focus-traversal, not arrow keys, so it can't
    // enter a stock DropdownMenu's menu). Index-keyed so the Android path stays
    // DropdownMenu<int> — entries map option index → label.
    Widget buildDropdown(double width) {
      return GamepadMenuDropdown<int>(
        width: width,
        label: title,
        hintText: placeholder,
        selected: _selectedIndex,
        onChanged: (int index) => onChanged(options[index].value),
        entries: <GamepadDropdownEntry<int>>[
          for (int i = 0; i < options.length; i++)
            (value: i, label: options[i].label),
        ],
      );
    }

    if (controlBelow || materialWidth == double.infinity) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final double requestedWidth =
              materialWidth == null || materialWidth == double.infinity
                  ? constraints.maxWidth
                  : materialWidth!;
          return buildDropdown(requestedWidth.isFinite ? requestedWidth : 240);
        },
      );
    }

    return buildDropdown(materialWidth ?? 220);
  }

  Widget _buildCupertinoTrailing(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color labelColor = CupertinoColors.secondaryLabel.resolveFrom(
      context,
    );
    final Color chevronColor = CupertinoColors.tertiaryLabel.resolveFrom(
      context,
    );
    final String label = _selectedLabel ?? placeholder ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.42,
          ),
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: tokens.type.metadata.copyWith(color: labelColor),
          ),
        ),
        const SizedBox(width: 6),
        Icon(
          CupertinoIcons.chevron_down,
          size: 16,
          color: chevronColor,
        ),
      ],
    );
  }

  Future<void> _showCupertinoPicker(BuildContext context) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return CupertinoActionSheet(
          title: Text(title),
          message: subtitle == null ? null : Text(subtitle!),
          actions: [
            for (final option in options)
              CupertinoActionSheetAction(
                isDefaultAction: option.value == selected,
                onPressed: () {
                  Navigator.pop(sheetContext);
                  onChanged(option.value);
                },
                child: Text(option.label),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        );
      },
    );
  }

  String? get _selectedLabel {
    for (final option in options) {
      if (option.value == selected) return option.label;
    }
    return null;
  }

  int? get _selectedIndex {
    for (int i = 0; i < options.length; i++) {
      if (options[i].value == selected) return i;
    }
    return null;
  }
}

class AdaptiveSettingsTextField extends StatefulWidget {
  const AdaptiveSettingsTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.initialValue,
    this.hintText,
    this.labelText,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.suffixIcon,
    this.focusId,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? initialValue;
  final String? hintText;
  final String? labelText;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffixIcon;

  /// Explicit geometric-focus id; when null a stable per-instance fallback is
  /// used so the field is always a directional-navigation anchor (see below).
  final HibikiFocusId? focusId;

  @override
  State<AdaptiveSettingsTextField> createState() =>
      _AdaptiveSettingsTextFieldState();
}

class _AdaptiveSettingsTextFieldState extends State<AdaptiveSettingsTextField> {
  // A settings text field MUST register with the directional focus controller,
  // otherwise it is invisible to geometric navigation: when an arrow key escapes
  // the focused (single-line) field, [HibikiFocusController.move] cannot locate
  // the active entry and dead-reckons to the FIRST registered row — which can
  // sit ABOVE the field, so Down jumps up (BUG-048). [HibikiTextField] only
  // registers when given a focusId, so we always supply one. The id is owned by
  // the State (stable across rebuilds), mirroring [_SettingsRowFocusTarget].
  late final HibikiFocusId _fallbackFocusId =
      HibikiFocusId('settings-textfield-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    return HibikiTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      initialValue: widget.initialValue,
      hintText: widget.hintText,
      labelText: widget.labelText,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      suffixIcon: widget.suffixIcon,
      focusId: widget.focusId ?? _fallbackFocusId,
    );
  }
}

class AdaptiveSettingsStepperRow extends StatelessWidget {
  const AdaptiveSettingsStepperRow({
    required this.title,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final double value;
  final double step;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: _KeyboardStepper(
        value: value,
        step: step,
        min: min,
        max: max,
        format: format,
        onChanged: onChanged,
      ),
    );
  }
}

class _AdjustUpIntent extends Intent {
  const _AdjustUpIntent();
}

class _AdjustDownIntent extends Intent {
  const _AdjustDownIntent();
}

/// Wraps a value control (stepper / slider / seek bar) as a SINGLE keyboard &
/// gamepad focus stop whose Left/Right adjust the value in place instead of
/// moving focus. The control's own descendants are removed from focus traversal
/// ([ExcludeFocus]) so this wrapper is the one stop; they stay mouse-clickable.
///
/// Up/Down deliberately do NOT adjust the value — they fall through so the user
/// can move focus to the next/previous row. Binding Up/Down to adjust would trap
/// vertical navigation and silently change the focused control's value while the
/// user is only trying to scroll past it.
///
/// On desktop/Apple the gamepad D-pad arrives as a [GamepadButtonIntent] (not
/// arrow keys): Left/Right adjust + consume (return true) so focus does NOT
/// move; Up/Down (and others) are NOT consumed (return false) so the press
/// falls through to directional focus traversal between rows. On Android the
/// engine delivers the D-pad as arrow keys, handled by the [Shortcuts] below —
/// which mirror that contract: only Left/Right are bound.
class _GamepadAdjustableValue extends StatefulWidget {
  const _GamepadAdjustableValue({
    required this.focusIdPrefix,
    required this.onIncrement,
    required this.onDecrement,
    required this.child,
  });

  final String focusIdPrefix;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final Widget child;

  @override
  State<_GamepadAdjustableValue> createState() =>
      _GamepadAdjustableValueState();
}

class _GamepadAdjustableValueState extends State<_GamepadAdjustableValue> {
  late final HibikiFocusId _focusId =
      HibikiFocusId('${widget.focusIdPrefix}-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        _AdjustUpIntent: CallbackAction<_AdjustUpIntent>(onInvoke: (_) {
          widget.onIncrement();
          return null;
        }),
        _AdjustDownIntent: CallbackAction<_AdjustDownIntent>(onInvoke: (_) {
          widget.onDecrement();
          return null;
        }),
        // Only ENABLED for D-pad Left/Right (adjust + consume). For any other
        // button this Action reports disabled, so Actions.maybeInvoke keeps
        // walking up and the press still reaches the page (Y focuses search,
        // LT/RT switch tabs, D-pad up/down move focus between rows). Flutter
        // stops at the first ENABLED action regardless of its return value, so
        // a CallbackAction returning false here would wrongly swallow them.
        GamepadButtonIntent: _GamepadAdjustAction(
          onIncrement: widget.onIncrement,
          onDecrement: widget.onDecrement,
        ),
      },
      child: Shortcuts(
        // Left/Right only — Up/Down are left unbound so they bubble to
        // directional focus traversal (move between rows). See class doc.
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowRight): _AdjustUpIntent(),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _AdjustDownIntent(),
        },
        child: HibikiFocusTarget(
          id: _focusId,
          child: ExcludeFocus(child: widget.child),
        ),
      ),
    );
  }
}

/// D-pad adjust Action for [_GamepadAdjustableValue], ENABLED only for D-pad
/// Left/Right. For every other [GamepadButtonIntent] it reports disabled so the
/// intent keeps bubbling to the page (Y / LT / RT / D-pad up-down) instead of
/// being consumed on the value row — Flutter stops at the first ENABLED action,
/// not the first that returns true.
class _GamepadAdjustAction extends Action<GamepadButtonIntent> {
  _GamepadAdjustAction({required this.onIncrement, required this.onDecrement});

  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  bool isEnabled(GamepadButtonIntent intent) =>
      intent.button == GamepadButton.dpadLeft ||
      intent.button == GamepadButton.dpadRight;

  @override
  Object? invoke(GamepadButtonIntent intent) {
    if (intent.button == GamepadButton.dpadRight) {
      onIncrement();
    } else if (intent.button == GamepadButton.dpadLeft) {
      onDecrement();
    }
    return true;
  }
}

/// The +/- controls of a stepper row, wrapped as a SINGLE keyboard/gamepad
/// focus stop. Tab lands here once (not once per button), and Left/Right
/// (D-pad or arrow keys) adjust the value in place (Right increment, Left
/// decrement) instead of leaking into directional focus traversal; Up/Down stay
/// free for row-to-row navigation. The inner buttons stay
/// mouse-clickable but are removed from focus traversal so they never become
/// separate, value-less tab stops.
///
/// The focus highlight comes from the app-wide [HibikiFocusRing] (drawn around
/// whichever widget holds primary focus in keyboard/gamepad mode), so no local
/// border is reserved here — the control's layout is unchanged.
class _KeyboardStepper extends StatelessWidget {
  const _KeyboardStepper({
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  final double value;
  final double step;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  void _increment() => onChanged((value + step).clamp(min, max));

  void _decrement() => onChanged((value - step).clamp(min, max));

  @override
  Widget build(BuildContext context) {
    final double clampedUp = (value + step).clamp(min, max);
    final double clampedDown = (value - step).clamp(min, max);
    // Expose a single "adjustable" node so screen readers (TalkBack / VoiceOver
    // / Narrator) can raise and lower the value via the platform increment /
    // decrement actions — the keyboard arrow shortcuts below are invisible to
    // assistive tech, and the +/- buttons are no longer separate focus stops.
    // excludeSemantics collapses the inner buttons/label into this one node.
    return _GamepadAdjustableValue(
      focusIdPrefix: 'settings-stepper',
      onIncrement: _increment,
      onDecrement: _decrement,
      child: Semantics(
        container: true,
        slider: true,
        value: format(value),
        increasedValue: format(clampedUp),
        decreasedValue: format(clampedDown),
        onIncrease: value < max ? _increment : null,
        onDecrease: value > min ? _decrement : null,
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SettingsStepButton(
              icon: Icons.remove,
              onPressed: _decrement,
              tooltip: t.decrease,
            ),
            SizedBox(
              width: 46,
              child: Text(
                format(value),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            _SettingsStepButton(
              icon: Icons.add,
              onPressed: _increment,
              tooltip: t.increase,
            ),
          ],
        ),
      ),
    );
  }
}

/// The slider equivalent of [_KeyboardStepper]: a single keyboard/gamepad focus
/// stop whose Left/Right (D-pad or arrow keys) nudge the slider by one step,
/// while the slider stays draggable by mouse/touch. Up/Down are left free for
/// row-to-row focus navigation.
class _KeyboardSlider extends StatelessWidget {
  const _KeyboardSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.step,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double? step;

  /// One D-pad/arrow nudge: an explicit [step], else one division, else 1/20 of
  /// the range (a sensible default for continuous sliders).
  double get _step =>
      step ?? (divisions != null ? (max - min) / divisions! : (max - min) / 20);

  void _adjust(double delta) {
    final double next = (value + delta).clamp(min, max);
    onChanged(next);
    onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    return _GamepadAdjustableValue(
      focusIdPrefix: 'settings-slider',
      onIncrement: () => _adjust(_step),
      onDecrement: () => _adjust(-_step),
      child: Semantics(
        container: true,
        slider: true,
        onIncrease: value < max ? () => _adjust(_step) : null,
        onDecrease: value > min ? () => _adjust(-_step) : null,
        excludeSemantics: true,
        child: adaptiveSlider(
          context: context,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
    );
  }
}

/// A gamepad/keyboard-adjustable slider for BARE slider sites that are not full
/// settings rows (audio seek bars, playback speed). Same single-focus-stop +
/// D-pad Left/Right (and arrows) nudge-by-[step] behaviour as a slider row,
/// while drag still works for mouse/touch. [step] is the per-press increment
/// (e.g. 5000ms for a seek bar); falls back to one division / 1/20 range.
Widget gamepadSeekableSlider({
  required double value,
  required double max,
  required ValueChanged<double> onChanged,
  double min = 0,
  int? divisions,
  String? label,
  ValueChanged<double>? onChangeEnd,
  double? step,
}) {
  return _KeyboardSlider(
    value: value,
    min: min,
    max: max,
    divisions: divisions,
    label: label,
    onChanged: onChanged,
    onChangeEnd: onChangeEnd,
    step: step,
  );
}

class AdaptiveSettingsSliderRow extends StatelessWidget {
  const AdaptiveSettingsSliderRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.step,
    this.readout,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Optional explicit gamepad/keyboard nudge step (overrides the
  /// division/default-based step) — for sliders whose natural increment differs
  /// from one division.
  final double? step;

  /// Optional live value readout appended to the displayed title as
  /// `Title (readout)` — fine-grained steps are pointless without a visible
  /// readout. Kept separate from [title] so the bare title remains the row's
  /// stable identity for focus-driven coverage tests and finders.
  final String? readout;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: readout == null ? title : '$title ($readout)',
      subtitle: subtitle,
      icon: icon,
      controlBelow: true,
      trailing: _KeyboardSlider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
        step: step,
      ),
    );
  }
}

class AdaptiveSettingsNavigationRow extends StatelessWidget {
  const AdaptiveSettingsNavigationRow({
    required this.title,
    required this.onTap,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color color = cupertino
        ? CupertinoColors.tertiaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon && icon != null,
      onTap: onTap,
      trailing: Icon(
        cupertino ? CupertinoIcons.chevron_right : Icons.chevron_right,
        size: cupertino ? 18 : 20,
        color: color,
      ),
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle? titleStyle = cupertino
        ? tokens.type.listTitle
        : Theme.of(context).textTheme.bodyMedium;
    final Color subtitleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(title, style: titleStyle, overflow: TextOverflow.ellipsis),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: subtitleColor),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
      ],
    );
  }
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (!cupertino) {
      return HibikiBadge(
        icon: icon,
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
        padding: const EdgeInsets.all(6),
        size: 18,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: tokens.radii.controlRadius,
      ),
      child: SizedBox(
        width: 28,
        height: 28,
        child: Icon(
          icon,
          size: 18,
          color: scheme.onPrimary,
        ),
      ),
    );
  }
}

class _SettingsStepButton extends StatelessWidget {
  const _SettingsStepButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    if (isCupertinoPlatform(context)) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 30,
        onPressed: onPressed,
        child: Icon(icon, size: 18),
      );
    }
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}
