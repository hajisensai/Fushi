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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // Keyboard + gamepad render as plain text chips; TODO-1050b: mouse bindings
    // render as icon chips (middle/right/back/forward small glyph) so the mouse
    // channel is no longer invisible in the list view (was data-only pass-through).
    final List<Widget> chips = <Widget>[
      for (final InputBinding b in bindings.keyboardBindings)
        FushiTagChip(
          label: b.displayLabel,
          tone: FushiTagChipTone.surface,
        ),
      for (final GamepadBinding b in bindings.gamepadBindings)
        FushiTagChip(
          label: GamepadGlyphs.glyphFor(b.button, brand).symbol,
          tone: FushiTagChipTone.surface,
        ),
      for (final MouseBinding b in bindings.mouseBindings)
        _MouseChip(binding: b),
      // 滚轮绑定（Alt+滚轮…）与鼠标按钮同款图标 chip，列表视图里同样可见。
      for (final WheelBinding b in bindings.wheelBindings)
        _InputIconChip(icon: b.icon, label: b.label),
    ];

    // TODO-944: the whole row taps into the SAME assign/edit flow, so unmapped
    // rows (no chips, only the dim "tap to assign" hint) are reachable instead
    // of relying on the tiny trailing edit icon. Routing `onTap` through
    // [FushiListItem] also registers a focus target, making every row — mapped
    // or not — keyboard/gamepad navigable.
    return FushiListItem(
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
      trailing: FushiIconButton(
        icon: Icons.edit_outlined,
        tooltip: t.options_edit,
        onTap: onEdit,
      ),
    );
  }
}

/// TODO-1050b: 鼠标绑定的小图标 chip。展示逻辑本身与通道无关（滚轮绑定也用它），
/// 故实际绘制在 [_InputIconChip]，这里只做「MouseBinding → 图标 + 名称」的薄壳。
class _MouseChip extends StatelessWidget {
  const _MouseChip({required this.binding, this.onDeleted});

  final MouseBinding binding;

  /// TODO-1088: when non-null a trailing delete affordance is shown (edit
  /// dialog); null keeps it a plain read-only chip (list-view display).
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) => _InputIconChip(
        icon: binding.icon,
        label: binding.label,
        onDeleted: onDeleted,
      );
}

/// 「图标 + 名称」的小 chip（FushiTagChip 无 leading icon 位，这里用同款 surface
/// 观感自绘，与文字 chip 并排展示，不改公共组件）。鼠标按钮与滚轮两条通道共用。
class _InputIconChip extends StatelessWidget {
  const _InputIconChip({
    required this.icon,
    required this.label,
    this.onDeleted,
  });

  final IconData icon;
  final String label;

  /// 非空时显示删除按钮（编辑对话框）；null 是只读展示（列表视图）。
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // Apple：与 FushiTagChip 的纯展示标签同一枚 systemFill 灰胶囊（高约 22、
    // 12 号 w500 secondaryLabel 字），和旁边的文字 chip 并排时形状一致。
    final bool glass = isGlassDesign(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color fg = glass ? apple.secondaryLabel : theme.colorScheme.onSurface;
    return Container(
      constraints: glass ? const BoxConstraints(minHeight: 22) : null,
      padding: glass
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
          : EdgeInsets.symmetric(
              horizontal: tokens.spacing.gap * 0.75,
              vertical: tokens.spacing.gap * 0.375,
            ),
      // Apple：纯展示的绑定标签不铺 systemFill 灰底，只留发丝分隔线描边
      // （与 FushiTagChip 纯展示形态一致）。
      decoration: BoxDecoration(
        color: glass ? null : tokens.surfaces.overlay,
        border: glass ? Border.all(color: apple.separator, width: 0.8) : null,
        borderRadius: glass
            ? const BorderRadius.all(Radius.circular(999))
            : tokens.radii.chipRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: glass ? 12 : 14, color: fg),
          SizedBox(width: glass ? 4 : tokens.spacing.gap * 0.375),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: glass
                ? (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  )
                : tokens.type.metadata.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
          ),
          if (onDeleted != null) ...<Widget>[
            SizedBox(width: tokens.spacing.gap * 0.375),
            InkWell(
              onTap: onDeleted,
              customBorder: const CircleBorder(),
              child: FushiIcon(Icons.close, size: 14, color: fg),
            ),
          ],
        ],
      ),
    );
  }
}
