// GENERATED-NOTE: extracted from shortcut_settings_page.dart (shortcut
// settings refactor). Behaviour-preserving: bodies verbatim except the
// label helpers now come from the public extensions in
// `shortcuts/shortcut_labels.dart` (`action.label` / `binding.label` /
// `binding.icon`).
part of '../shortcut_settings_page.dart';

// ---------------------------------------------------------------------------
// Row for a single action
// ---------------------------------------------------------------------------

/// 一个动作一行（2026-10 重设计）：动作名 + 当前输入设备的键帽胶囊（多条并排）+
/// 恢复默认 / 添加 / 完整编辑。点整行 = 原地录制（替换该通道的绑定），「+」=
/// 追加一条；撞键在行内展开冲突条。
class _ActionTile extends StatefulWidget {
  const _ActionTile({
    required this.action,
    required this.bindings,
    required this.device,
    required this.brand,
    required this.readOnly,
    required this.modified,
    required this.recording,
    required this.conflictFor,
    required this.onEdit,
    required this.onAdd,
    required this.onRemove,
    required this.onReset,
    required this.onResolve,
    required this.onCancel,
    super.key,
    this.warning,
    this.pending,
    this.recorder,
    this.onOpenEditor,
  });

  final ShortcutAction action;
  final ShortcutBindingSet bindings;
  final ShortcutInputDevice device;

  /// Display brand for gamepad chips (TODO-1113); display-only, never affects
  /// binding serialization.
  final GamepadBrand brand;
  final bool readOnly;
  final bool modified;
  final bool recording;
  final String? warning;
  final _PendingConflict? pending;
  final Widget? recorder;
  final ShortcutAction? Function(Object binding) conflictFor;

  /// 整行点按：原地录制（TODO-944：未映射行同一入口，整行可点可聚焦）。
  final VoidCallback onEdit;
  final VoidCallback onAdd;
  final ValueChanged<Object> onRemove;
  final VoidCallback onReset;
  final VoidCallback? onOpenEditor;
  final ValueChanged<_InlineConflictChoice> onResolve;
  final VoidCallback onCancel;

  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool _hovered = false;

  Widget _subtitle(BuildContext context, List<Widget> chips) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final _ActionTile w = widget;
    final _PendingConflict? pending = w.pending;
    if (w.recorder != null) return w.recorder!;
    if (pending != null) {
      final List<Object> current = shortcutBindingsInChannel(
        w.bindings,
        shortcutBindingChannel(pending.binding),
      );
      return _ConflictStrip(
        pending: pending,
        brand: w.brand,
        canSwap: pending.replace &&
            current.length == 1 &&
            current.single != pending.binding,
        onResolve: w.onResolve,
        onCancel: w.onCancel,
      );
    }
    if (w.readOnly) return Text(t.shortcut_read_only);
    if (chips.isEmpty) {
      return Text(t.shortcut_tap_to_assign);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: tokens.spacing.gap / 2,
          runSpacing: tokens.spacing.gap / 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: chips,
        ),
        if (w.warning != null)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
            child: Text(
              w.warning!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
      ],
    );
  }

  Widget _trailing(BuildContext context, Duration motion) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final _ActionTile w = widget;
    if (w.readOnly) {
      return FushiIcon(
        Icons.lock_outline_rounded,
        size: 18,
        color: tokens.surfaces.onVariant,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedSwitcher(
          duration: motion,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              ScaleTransition(scale: animation, child: child),
          child: w.modified
              ? FushiIconButton(
                  key: ValueKey<String>('shortcut-reset-${w.action.name}'),
                  icon: Icons.restart_alt_rounded,
                  tooltip: t.shortcut_reset_defaults,
                  onTap: w.onReset,
                )
              : const SizedBox.shrink(),
        ),
        FushiIconButton(
          key: ValueKey<String>('shortcut-add-${w.action.name}'),
          icon: Icons.add_rounded,
          tooltip: t.shortcut_add_binding,
          onTap: w.onAdd,
        ),
        if (w.onOpenEditor != null)
          FushiIconButton(
            key: ValueKey<String>('shortcut-editor-${w.action.name}'),
            icon: Icons.tune_rounded,
            tooltip: t.shortcut_edit_all_inputs,
            onTap: w.onOpenEditor,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final _ActionTile w = widget;
    final ShortcutAction action = w.action;
    final TargetPlatform platform = Theme.of(context).platform;
    final bool touch =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    // 只列当前输入设备的绑定：键盘、手柄、鼠标（含滚轮）三套不再挤在一行里。
    final List<Object> shown = shortcutBindingsForDevice(w.bindings, w.device);
    // 小 × 只在悬停时出现（触屏没有悬停，常显），免得一屏都是删除钮。
    final bool showRemove = !w.readOnly && (_hovered || touch);
    final List<Widget> chips = <Widget>[
      for (final Object b in shown)
        _BindingKeycap(
          key: ValueKey<String>(
            'keycap-${action.name}-${shortcutBindingLabel(b, w.brand)}',
          ),
          binding: b,
          brand: w.brand,
          conflictWith: w.conflictFor(b),
          onRemove: showRemove ? () => w.onRemove(b) : null,
        ),
    ];
    final String state = w.recorder != null
        ? 'recording'
        : w.pending != null
            ? 'conflict'
            : 'chips';
    final Duration motion = fushiMotionDuration(context, FushiMotion.short);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: FushiListItem(
        onTap: w.readOnly ? null : w.onEdit,
        focusId: _rowFocusId(action),
        selected: w.recording || w.pending != null,
        subtitleMaxLines: 6,
        title: Row(
          children: <Widget>[
            Flexible(child: Text(action.label)),
            if (w.modified) ...<Widget>[
              SizedBox(width: tokens.spacing.gap / 2),
              const _ModifiedDot(),
            ],
          ],
        ),
        subtitle: AnimatedSize(
          duration: motion,
          curve: FushiMotion.standard,
          alignment: Alignment.topLeft,
          child: AnimatedSwitcher(
            duration: motion,
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: Alignment.topLeft,
              children: <Widget>[...previous, if (current != null) current],
            ),
            child: KeyedSubtree(
              key: ValueKey<String>(state),
              child: Padding(
                padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
                child: _subtitle(context, chips),
              ),
            ),
          ),
        ),
        trailing: _trailing(context, motion),
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
