/// 组合编辑页与作品「作品配置」共用的设置树节点件（拍板台 design-combo-node-split 阶段 6）：
/// 节点名、来源层名、「继承 / 单独设置」状态胶囊、可展开看生效值的叶子行。
///
/// MD3 与 Apple 两套：颜色按 Cupertino / 玻璃 / Material 三种外观取（与配置管理页的行内按钮
/// 同一口径），按压缩放 [FushiPressScale]，展开收起 [AnimatedSize]（时长取
/// [fushiMotionDuration]，减弱动态效果时瞬间到位）。
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/profile/combo/combo_migration_report_dialog.dart'
    show comboLeafLabel;
import 'package:fushi/src/profile/combo/combo_repository.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

export 'package:fushi/src/profile/combo/combo_migration_report_dialog.dart'
    show comboLeafLabel;

/// 子组节点 id → 界面名；叶子走 [comboLeafLabel]。不认识的 id 原样显示。
String comboGroupLabel(String nodeId) => switch (nodeId) {
  FushiComboNode.mining => t.profile_combo_group_mining,
  FushiComboNode.appearance => t.profile_combo_group_appearance,
  FushiComboNode.input => t.profile_combo_group_input,
  FushiComboNode.srs => t.profile_combo_group_srs,
  _ => nodeId,
};

/// 绑定层的界面名（「作品」「媒体类型」「语言」）。
String comboLayerLabel(ComboScope scope) => switch (scope) {
  ComboScope.work => t.profile_combo_layer_work,
  ComboScope.mediaType => t.profile_combo_layer_media_type,
  ComboScope.language => t.profile_combo_layer_language,
  ComboScope.defaults => '',
};

/// 一个生效值的显示形：偏好值带类型前缀（`s:` / `b:` / `i:` / `d:`，见 PrefCodec）时去掉前缀，
/// 过长的截断。
String comboValuePreview(String raw) {
  String v = raw;
  if (v.length > 2 && v[1] == ':' && 'sbidl'.contains(v[0])) {
    v = v.substring(2);
  }
  const int max = 80;
  return v.length <= max ? v : '${v.substring(0, max)}…';
}

/// 「继承」/「单独设置」状态胶囊。
class ComboStateChip extends StatelessWidget {
  const ComboStateChip({required this.split, super.key});

  final bool split;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final bool glass = !cupertino && isGlassDesign(context);
    final Color accent = cupertino
        ? CupertinoTheme.of(context).primaryColor
        : glass
        ? appleColorsOf(context).accent
        : Theme.of(context).colorScheme.primary;
    final Color muted = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : glass
        ? appleColorsOf(context).secondaryLabel
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final Color fg = split ? accent : muted;
    final TextStyle base = cupertino
        ? CupertinoTheme.of(context).textTheme.textStyle
        : Theme.of(context).textTheme.labelMedium ?? const TextStyle();
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: split ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        split ? t.profile_combo_state_split : t.profile_combo_state_inherited,
        style: base.copyWith(fontSize: 12, color: fg),
      ),
    );
  }
}

/// 一行叶子：名字 + 说明（来源 / 不可拆的原因）+ 状态胶囊 + 动作；点行展开看这组键的生效值。
class ComboLeafTile extends StatefulWidget {
  const ComboLeafTile({
    required this.leafId,
    required this.split,
    required this.values,
    super.key,
    this.subtitle,
    this.showState = true,
    this.actionLabel,
    this.onAction,
    this.trailingExtra,
  });

  final String leafId;
  final bool split;

  /// 这个叶子那组键的生效值（展开时列出）。
  final Map<SettingKey, String> values;
  final String? subtitle;

  /// 默认组合没有继承 / 拆分可言，不显示状态胶囊。
  final bool showState;

  /// 行尾动作（「单独设置」/「恢复继承」）；null = 没有动作。
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailingExtra;

  @override
  State<ComboLeafTile> createState() => _ComboLeafTileState();
}

class _ComboLeafTileState extends State<ComboLeafTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool cupertino = isCupertinoPlatform(context);
    final Color muted = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final List<MapEntry<SettingKey, String>> entries =
        widget.values.entries.toList()..sort(
          (MapEntry<SettingKey, String> a, MapEntry<SettingKey, String> b) =>
              a.key.compareTo(b.key),
        );
    final String? action = widget.actionLabel;
    return FushiPressScale(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AdaptiveSettingsRow(
            key: ValueKey<String>('combo_leaf_${widget.leafId}'),
            title: comboLeafLabel(widget.leafId),
            subtitle: widget.subtitle,
            animateSubtitle: true,
            onTap: () => setState(() => _expanded = !_expanded),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.showState) ComboStateChip(split: widget.split),
                ?widget.trailingExtra,
                if (action != null) ...<Widget>[
                  SizedBox(width: tokens.spacing.gap / 2),
                  FushiTextButton(
                    key: ValueKey<String>('combo_action_${widget.leafId}'),
                    onPressed: widget.onAction,
                    child: Text(action),
                  ),
                ],
              ],
            ),
          ),
          AnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.rowHorizontal,
                      0,
                      tokens.spacing.rowHorizontal,
                      tokens.spacing.gap,
                    ),
                    child: _ComboLeafValues(entries: entries, color: muted),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ComboLeafValues extends StatelessWidget {
  const _ComboLeafValues({required this.entries, required this.color});

  final List<MapEntry<SettingKey, String>> entries;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      fontSize: 12,
      height: 1.35,
      color: color,
      fontFamily: 'monospace',
    );
    if (entries.isEmpty) {
      return Text(t.profile_combo_value_unset, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.profile_combo_value_count(count: entries.length),
          style: style.copyWith(fontFamily: null),
        ),
        for (final MapEntry<SettingKey, String> e in entries)
          Text(
            '${e.key.key} = ${comboValuePreview(e.value)}',
            style: style,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }
}
