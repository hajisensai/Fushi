/// 字段名的「人话」标签：已知字段（Lapis / Fushi 卡片沿用的英文名，见 srs_field_catalog.dart）
/// 显示翻译名 + 小字原名，旁边一个 ⓘ：悬停 / 长按看一句说明，点一下在原地展开完整说明
/// （装什么、在卡面哪里出现、制卡时从哪一项自动填入）。不认识的自定义字段显示原名，
/// ⓘ 里仍给出原名与制卡来源。
///
/// 笔记编辑页的字段标题、可视化模板编辑器的块标题共用这一处。
library;

import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/anki_settings_page.dart'
    show ankiHandlebarLabel;
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 制卡映射（Yomitan 写法的 `{expression} {reading}`）→ 一句人话；空 = 制卡不自动填。
String srsMiningSlotText(String slot) => slot.trim().isEmpty
    ? t.srs_field_info_mining_none
    : t.srs_field_info_mining(
        slot: slot
            .split(RegExp(r'\s+'))
            .where((String s) => s.isNotEmpty)
            .map(ankiHandlebarLabel)
            .join(' + '),
      );

/// 一个字段在界面上的名字与说明。
class SrsFieldHelp {
  const SrsFieldHelp({
    required this.rawName,
    required this.displayName,
    this.description = '',
    this.mining,
  });

  /// 按字段定义取名字 / 说明（用户写的说明优先，其次内置目录）；[miningSlot] 为 null =
  /// 不显示制卡来源（调用方不知道映射）。
  factory SrsFieldHelp.of(SrsFieldDef field, {String? miningSlot}) =>
      SrsFieldHelp(
        rawName: field.name,
        displayName: srsFieldDisplayName(field),
        description: srsFieldDisplayDescription(field),
        mining: miningSlot == null ? null : srsMiningSlotText(miningSlot),
      );

  final String rawName;
  final String displayName;
  final String description;

  /// 「制卡时自动填入：…」一句；null = 不显示。
  final String? mining;

  /// 显示名与原名不同（已知字段）。
  bool get translated => displayName != rawName;

  /// ⓘ 的悬停提示：说明，没有说明时给原名。
  String get tooltip => description.isNotEmpty
      ? description
      : t.srs_field_info_raw_name(name: rawName);
}

/// 字段标题行：显示名（+ 小字原名）+ ⓘ；点 ⓘ 在下方展开说明。[trailing] 放标题行尾部的控件。
class SrsFieldLabel extends StatefulWidget {
  const SrsFieldLabel({
    super.key,
    required this.help,
    this.trailing = const <Widget>[],
    this.style,
  });

  final SrsFieldHelp help;
  final List<Widget> trailing;
  final TextStyle? style;

  @override
  State<SrsFieldLabel> createState() => _SrsFieldLabelState();
}

class _SrsFieldLabelState extends State<SrsFieldLabel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsFieldHelp help = widget.help;
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final TextStyle titleStyle =
        widget.style ?? context.fushiType.labelLarge.copyWith(color: muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(text: help.displayName),
                          if (help.translated)
                            TextSpan(
                              text: '  ${help.rawName}',
                              style: context.fushiType.labelSmall.copyWith(
                                color: muted.withValues(alpha: 0.75),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                        ],
                      ),
                      key: ValueKey<String>('srs-field-label-${help.rawName}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                  FushiIconButton(
                    key: ValueKey<String>('srs-field-help-${help.rawName}'),
                    icon: FushiIcons.info,
                    size: 18,
                    selected: _open,
                    tooltip: help.tooltip,
                    onTap: () => setState(() => _open = !_open),
                  ),
                ],
              ),
            ),
            ...widget.trailing,
          ],
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Container(
                  key: ValueKey<String>('srs-field-help-panel-${help.rawName}'),
                  width: double.infinity,
                  margin: EdgeInsets.only(bottom: tokens.spacing.gap / 2),
                  padding: EdgeInsets.all(tokens.spacing.gap),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: tokens.radii.controlRadius,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: tokens.spacing.gap / 2,
                    children: <Widget>[
                      if (help.description.isNotEmpty)
                        Text(
                          help.description,
                          style: context.fushiType.bodyMedium,
                        ),
                      if (help.mining != null)
                        Text(
                          help.mining!,
                          style: context.fushiType.bodySmall.copyWith(
                            color: muted,
                          ),
                        ),
                      Text(
                        t.srs_field_info_raw_name(name: help.rawName),
                        style: context.fushiType.bodySmall.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
