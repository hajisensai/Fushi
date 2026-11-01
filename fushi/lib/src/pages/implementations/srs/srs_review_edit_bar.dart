/// 复习时编辑的底栏编辑键（反馈 cbzyXZlK-t / yrXhexdOaR）：答案面评分按钮上方一排纯图标键——加粗 / 高亮 /
/// 清除格式（作用于卡面上选中的文字所在的字段，见 srs_review_edit.dart）、字段 AI 改写、编辑整条笔记。
///
/// 键不取焦点（`canRequestFocus: false`）：点它们时卡面的选区（原生 SelectionArea 的焦点）不会被清掉。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_rich_format.dart' show kSrsHighlightDefault;
import 'package:fushi/src/srs/srs_review_edit.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class SrsReviewEditBar extends StatelessWidget {
  const SrsReviewEditBar({
    super.key,
    required this.hasSelection,
    required this.enabled,
    required this.onFormat,
    required this.onEditNote,
    this.onAi,
  });

  /// 卡面上选中了文字（格式键据此可按）。
  final bool hasSelection;

  /// 整排可按（忙碌中 = false）。
  final bool enabled;
  final void Function(SrsQuickFormat format) onFormat;

  /// 字段 AI 改写；null = AI 模块关着 / 没有可改写的字段（不显示这个键）。
  final VoidCallback? onAi;
  final VoidCallback onEditNote;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool format = enabled && hasSelection;
    int step = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);
    return FushiEntranceScope(
      child: Semantics(
        container: true,
        label: t.srs_review_edit_bar,
        child: Wrap(
          key: const ValueKey<String>('srs-review-edit-bar'),
          alignment: WrapAlignment.center,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap / 2,
          children: <Widget>[
            stagger(
              _EditKey(
                key: const ValueKey<String>('srs-review-edit-bold'),
                tooltip: hasSelection
                    ? t.srs_review_edit_bold
                    : t.srs_review_edit_select_hint,
                enabled: format,
                onTap: () => onFormat(SrsQuickFormat.bold),
                child: const FushiIcon(FushiIcons.bold, size: 22),
              ),
            ),
            stagger(
              _EditKey(
                key: const ValueKey<String>('srs-review-edit-highlight'),
                tooltip: hasSelection
                    ? t.srs_review_edit_highlight
                    : t.srs_review_edit_select_hint,
                enabled: format,
                onTap: () => onFormat(SrsQuickFormat.highlight),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: const Color(
                      kSrsHighlightDefault,
                    ).withValues(alpha: format ? 1 : 0.4),
                    borderRadius: tokens.radii.chipRadius,
                  ),
                  child: const Text(
                    'H',
                    style: TextStyle(
                      color: Color(0xFF000000),
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ),
            stagger(
              _EditKey(
                key: const ValueKey<String>('srs-review-edit-clear'),
                tooltip: hasSelection
                    ? t.srs_review_edit_clear
                    : t.srs_review_edit_select_hint,
                enabled: format,
                onTap: () => onFormat(SrsQuickFormat.clear),
                child: const Text(
                  'T',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.lineThrough,
                    decorationThickness: 2,
                    height: 1.2,
                  ),
                ),
              ),
            ),
            if (onAi != null)
              stagger(
                _EditKey(
                  key: const ValueKey<String>('srs-review-edit-ai'),
                  tooltip: t.srs_note_field_ai,
                  enabled: enabled,
                  onTap: onAi!,
                  child: const FushiIcon(FushiIcons.aiAssistant, size: 22),
                ),
              ),
            stagger(
              _EditKey(
                key: const ValueKey<String>('srs-review-edit-note'),
                tooltip: t.srs_review_edit_note,
                enabled: enabled,
                onTap: onEditNote,
                child: const FushiIcon(FushiIcons.edit, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 选区同时出现在几个字段里（或 AI 改写没有选区）时选一个字段；[fields] = (字段 id, 显示名)。
/// 取消返回 null。
Future<String?> showSrsReviewFieldPicker(
  BuildContext context, {
  required String title,
  required List<(String, String)> fields,
}) => showAppDialog<String>(
  context: context,
  builder: (BuildContext dialogContext) {
    int step = 0;
    return FushiAlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: FushiEntranceScope(
            child: Column(
              key: const ValueKey<String>('srs-review-field-picker'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (String id, String label) in fields)
                  FushiStaggeredEntrance(
                    index: step++,
                    child: FushiListItem(
                      key: ValueKey<String>('srs-review-field-$id'),
                      title: Text(label),
                      onTap: () => Navigator.of(dialogContext).pop(id),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    );
  },
);

/// 一个编辑键：48dp 命中区、文字只进 tooltip 与 Semantics、不取焦点。
class _EditKey extends StatelessWidget {
  const _EditKey({
    super.key,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color fg = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.38);
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        excludeSemantics: true,
        child: FushiPressScale(
          enabled: enabled,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: enabled ? onTap : null,
              canRequestFocus: false,
              borderRadius: tokens.radii.controlRadius,
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tokens.surfaces.search,
                  borderRadius: tokens.radii.controlRadius,
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: fg),
                  child: DefaultTextStyle.merge(
                    style: context.fushiType.titleMedium.copyWith(color: fg),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
