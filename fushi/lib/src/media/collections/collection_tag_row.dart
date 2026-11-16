import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show BookTagRow;

/// 合集标签行：已挂标签 chip（点按 = 编辑）+ 可选的小号 tonal「编辑标签」（key
/// `collection_detail_edit_tags`）。合集海报 hero 的页脚用它画已挂标签（「编辑
/// 标签」那时在动作行里，[showEditButton] = false）。
class CollectionTagRow extends StatelessWidget {
  const CollectionTagRow({
    required this.tags,
    this.onEditTags,
    this.showEditButton = true,
    super.key,
  });

  final List<BookTagRow> tags;
  final VoidCallback? onEditTags;

  /// 行尾画不画「编辑标签」按钮（动作行里已有同一入口时不画）。
  final bool showEditButton;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VoidCallback? onEditTags = this.onEditTags;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap,
      children: <Widget>[
        for (final BookTagRow tag in tags)
          FushiTagToggleChip(
            label: tag.name,
            color: Color(tag.colorValue),
            state: TagCheckState.all,
            onTap: onEditTags,
          ),
        if (showEditButton && onEditTags != null)
          FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('collection_detail_edit_tags'),
            onPressed: onEditTags,
            size: FushiButtonSize.xs,
            icon: const FushiIcon(FushiIcons.tag),
            label: Text(t.collection_detail_edit_tags),
          ),
      ],
    );
  }
}
