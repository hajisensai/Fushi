import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/utils.dart';

/// 书架 / 视频 tab 共享的标签筛选栏：横向 tag chip（点选筛选、长按拖拽重排）+ 末尾
/// 「管理标签」齿轮；可选「批量选择」动作（仅书架多选书需要，[onToggleSelectionMode]
/// 为 null 时不渲染）。两处用同一组件，保证标签栏外观/交互完全一致。
///
/// 筛选状态走共享的 [selectedTagIdsProvider]（与书架联动）；管理标签返回后刷新
/// [allTagsProvider] 并回调 [onTagsChanged]，让调用方刷新各自的 book/video 标签映射。
class HibikiTagFilterBar extends ConsumerStatefulWidget {
  const HibikiTagFilterBar({
    required this.tags,
    required this.onToggleFilter,
    required this.onReorder,
    this.selectionMode = false,
    this.onToggleSelectionMode,
    this.onOrganize,
    this.onOrganizeFocusId,
    this.onTagsChanged,
    super.key,
  });

  final List<BookTagRow> tags;
  final void Function(int tagId) onToggleFilter;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;

  /// 批量选择模式状态；仅当 [onToggleSelectionMode] 非空时该动作才渲染。
  final bool selectionMode;

  /// 切换批量选择模式。为 null（如视频 tab 无批量选择）时不显示批量选择动作。
  final VoidCallback? onToggleSelectionMode;

  /// 「整理」入口：点开进入拖动排序（合集入口在相邻的多选批量栏）。为 null 时不渲染。
  /// TODO-947：把原本散在页头的「编辑排序」(swap_vert) 入口挪到多选按钮旁，与
  /// 「组合成系列」(多选批量栏) 聚成一组整理动作。
  final VoidCallback? onOrganize;

  /// Stable focus id for the「整理」(swap_vert) action, so a directional anchor
  /// can point at it (the shelf anchors "Right from organize -> import icon" and
  /// "Down from organize -> first grid card"). Null keeps the derived fallback id.
  final HibikiFocusId? onOrganizeFocusId;

  /// 管理标签返回后，调用方据此刷新自身的标签映射 provider（book / video）。
  final VoidCallback? onTagsChanged;

  @override
  ConsumerState<HibikiTagFilterBar> createState() => _HibikiTagFilterBarState();
}

class _HibikiTagFilterBarState extends ConsumerState<HibikiTagFilterBar> {
  @override
  Widget build(BuildContext context) {
    final Set<int> selectedIds = ref.watch(selectedTagIdsProvider);
    final t = Translations.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    // 末尾动作：先「管理标签」（有标签才显示），再可选「批量选择」。
    final List<Widget> trailing = <Widget>[
      if (widget.tags.isNotEmpty)
        _tagBarAction(
          icon: Icons.settings_outlined,
          tooltip: t.tag_manage,
          onTap: () {
            Navigator.push(
              context,
              adaptivePageRoute(builder: (_) => const TagManagementPage()),
            ).then((_) {
              ref.invalidate(allTagsProvider);
              widget.onTagsChanged?.call();
            });
          },
        ),
      if (widget.onToggleSelectionMode != null)
        _tagBarAction(
          icon: widget.selectionMode ? Icons.close : Icons.checklist_outlined,
          tooltip: widget.selectionMode
              ? MaterialLocalizations.of(context).closeButtonTooltip
              : t.batch_select,
          selected: widget.selectionMode,
          onTap: widget.onToggleSelectionMode!,
        ),
      // 「整理」入口（拖动排序 + 相邻多选批量栏的「组合成系列」），挂在多选按钮旁。
      if (widget.onOrganize != null && !widget.selectionMode)
        _tagBarAction(
          icon: Icons.swap_vert,
          tooltip: t.shelf_edit_order,
          onTap: widget.onOrganize!,
          focusId: widget.onOrganizeFocusId,
        ),
    ];

    return Container(
      height: tokens.spacing.gap * 5.5,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: tokens.surfaces.outline.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.gap * 0.75,
        ),
        itemCount: widget.tags.length + trailing.length,
        separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap * 0.75),
        itemBuilder: (context, index) {
          if (index >= widget.tags.length) {
            return trailing[index - widget.tags.length];
          }
          final BookTagRow tag = widget.tags[index];
          final bool isSelected = selectedIds.contains(tag.id);
          if (widget.selectionMode) {
            return _tagFilterChip(
              tag: tag,
              isSelected: isSelected,
              isDimmed: false,
              onTap: () => widget.onToggleFilter(tag.id),
            );
          }
          return LongPressDraggable<BookTagRow>(
            data: tag,
            feedback: Material(
              color: Colors.transparent,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: tokens.radii.chipRadius,
              ),
              clipBehavior: Clip.antiAlias,
              child: _tagFilterChip(
                tag: tag,
                isSelected: true,
                isDimmed: false,
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: _tagFilterChip(
                tag: tag,
                isSelected: isSelected,
                isDimmed: false,
              ),
            ),
            child: DragTarget<BookTagRow>(
              onWillAcceptWithDetails: (details) => details.data.id != tag.id,
              onAcceptWithDetails: (details) {
                final BookTagRow draggedTag = details.data;
                final int oldIdx =
                    widget.tags.indexWhere((t) => t.id == draggedTag.id);
                final int newIdx =
                    widget.tags.indexWhere((t) => t.id == tag.id);
                if (oldIdx != -1 && newIdx != -1) {
                  widget.onReorder(oldIdx, newIdx);
                }
              },
              builder: (context, candidateData, rejectedData) {
                return _tagFilterChip(
                  tag: tag,
                  isSelected: isSelected,
                  isDimmed: candidateData.isNotEmpty,
                  onTap: () => widget.onToggleFilter(tag.id),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _tagBarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool selected = false,
    HibikiFocusId? focusId,
  }) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiIconButton(
      icon: icon,
      tooltip: tooltip,
      size: tokens.spacing.gap * 2.25,
      padding: EdgeInsets.all(tokens.spacing.gap * 0.875),
      enabledColor:
          selected ? tokens.surfaces.primary : tokens.surfaces.onVariant,
      onTap: onTap,
      focusId: focusId,
    );
  }

  Widget _tagFilterChip({
    required BookTagRow tag,
    required bool isSelected,
    required bool isDimmed,
    VoidCallback? onTap,
  }) {
    return HibikiTagChip(
      label: tag.name,
      color: Color(tag.colorValue),
      selected: isSelected,
      dimmed: isDimmed,
      tone: HibikiTagChipTone.surface,
      onTap: onTap,
    );
  }
}
