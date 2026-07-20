// GENERATED-NOTE: extracted from shortcut_settings_page.dart (shortcut
// settings refactor). Behaviour-preserving: bodies verbatim except the
// label helpers now come from the public extensions in
// `shortcuts/shortcut_labels.dart` (`action.label` / `binding.label` /
// `binding.icon`).
part of '../shortcut_settings_page.dart';

// ---------------------------------------------------------------------------
// Row for a single action
// ---------------------------------------------------------------------------

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.action,
    required this.bindings,
    required this.brand,
    required this.onEdit,
  });

  final ShortcutAction action;
  final ShortcutBindingSet bindings;

  /// Display brand for gamepad chips (TODO-1113); display-only, never affects
  /// binding serialization.
  final GamepadBrand brand;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // Keyboard + gamepad render as plain text chips; TODO-1050b: mouse bindings
    // render as icon chips (middle/right/back/forward small glyph) so the mouse
    // channel is no longer invisible in the list view (was data-only pass-through).
    final List<Widget> chips = <Widget>[
      for (final InputBinding b in bindings.keyboardBindings)
        HibikiTagChip(
          label: b.displayLabel,
          tone: HibikiTagChipTone.surface,
        ),
      for (final GamepadBinding b in bindings.gamepadBindings)
        HibikiTagChip(
          label: GamepadGlyphs.glyphFor(b.button, brand).symbol,
          tone: HibikiTagChipTone.surface,
        ),
      for (final MouseBinding b in bindings.mouseBindings)
        _MouseChip(binding: b),
    ];

    // TODO-944: the whole row taps into the SAME assign/edit flow, so unmapped
    // rows (no chips, only the dim "tap to assign" hint) are reachable instead
    // of relying on the tiny trailing edit icon. Routing `onTap` through
    // [HibikiListItem] also registers a focus target, making every row — mapped
    // or not — keyboard/gamepad navigable.
    return HibikiListItem(
      onTap: onEdit,
      title: Text(action.label),
      subtitle: chips.isEmpty
          ? Text(
              t.shortcut_tap_to_assign,
            )
          : Wrap(
              spacing: tokens.spacing.gap / 2,
              runSpacing: tokens.spacing.gap / 2,
              children: chips,
            ),
      trailing: HibikiIconButton(
        icon: Icons.edit_outlined,
        tooltip: t.options_edit,
        onTap: onEdit,
      ),
    );
  }
}

/// TODO-1050b: 鼠标绑定的小图标 chip（HibikiTagChip 无 leading icon 位，这里用同款
/// surface 观感自绘一个「图标 + 名称」的小 chip，与文字 chip 并排展示，不改公共组件）。
class _MouseChip extends StatelessWidget {
  const _MouseChip({required this.binding, this.onDeleted});

  final MouseBinding binding;

  /// TODO-1088: when non-null a trailing delete affordance is shown (edit
  /// dialog); null keeps it a plain read-only chip (list-view display).
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color fg = theme.colorScheme.onSurface;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap * 0.75,
        vertical: tokens.spacing.gap * 0.375,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaces.overlay,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(binding.icon, size: 14, color: fg),
          SizedBox(width: tokens.spacing.gap * 0.375),
          Text(
            binding.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onDeleted != null) ...<Widget>[
            SizedBox(width: tokens.spacing.gap * 0.375),
            InkWell(
              onTap: onDeleted,
              customBorder: const CircleBorder(),
              child: Icon(Icons.close, size: 14, color: fg),
            ),
          ],
        ],
      ),
    );
  }
}
