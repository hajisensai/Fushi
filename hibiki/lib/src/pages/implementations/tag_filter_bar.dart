import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/collections/shelf_sort.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_management_page.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:hibiki/src/shortcuts/input_binding.dart' show GamepadButton;
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
    this.sortMode,
    this.sortModeLabel,
    this.onSortModeChanged,
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

  /// 「排序方式」菜单（排序交互重设计层次 A）当前选中模式。三个 sort 参数同 null /
  /// 同非 null；null 时不渲染排序动作。
  final ShelfSortMode? sortMode;

  /// 模式 → 菜单项文案（recent 两页语义不同：书架=最近阅读、视频=最近观看）。
  final String Function(ShelfSortMode mode)? sortModeLabel;

  /// 用户选中新排序方式（页面负责 setState + 偏好持久化）。
  final ValueChanged<ShelfSortMode>? onSortModeChanged;

  /// 管理标签返回后，调用方据此刷新自身的标签映射 provider（book / video）。
  final VoidCallback? onTagsChanged;

  @override
  ConsumerState<HibikiTagFilterBar> createState() => _HibikiTagFilterBarState();
}

class _HibikiTagFilterBarState extends ConsumerState<HibikiTagFilterBar> {
  final MenuController _sortMenu = MenuController();

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
              adaptivePageRoute(
                context: context,
                builder: (_) => const TagManagementPage(),
              ),
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
      // 「排序方式」菜单（原「整理」swap_vert 的位置；整理页已整体删除）。
      if (widget.sortMode != null &&
          widget.sortModeLabel != null &&
          widget.onSortModeChanged != null &&
          !widget.selectionMode)
        _sortMenuAction(tokens),
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
    );
  }

  /// 「排序方式」三项单选菜单：MenuAnchor + 选中项 autofocus（手柄/键盘打开即落进
  /// 菜单，D-pad 可遍历、A/Enter 选中、B 关闭——与 [GamepadMenuDropdown] 的
  /// polled 路径同款交互，样式走同一组 menu tokens）。
  Widget _sortMenuAction(HibikiDesignTokens tokens) {
    final t = Translations.of(context);
    final ShelfSortMode selectedMode = widget.sortMode!;
    return MenuAnchor(
      controller: _sortMenu,
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
      ),
      menuChildren: <Widget>[
        for (final ShelfSortMode mode in ShelfSortMode.values)
          _sortMenuItem(tokens, mode, selectedMode),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return _tagBarAction(
          icon: Icons.sort,
          tooltip: t.sort_by,
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
        );
      },
    );
  }

  Widget _sortMenuItem(
    HibikiDesignTokens tokens,
    ShelfSortMode mode,
    ShelfSortMode selectedMode,
  ) {
    final bool selected = mode == selectedMode;
    final Color foreground =
        selected ? tokens.surfaces.primary : tokens.surfaces.onSurface;
    return Actions(
      // B 只关菜单（焦点回归标签栏），不冒泡成 GamepadService 的整页返回。
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) {
            if (intent.button == GamepadButton.b) {
              _sortMenu.close();
              return true;
            }
            return null;
          },
        ),
      },
      child: MenuItemButton(
        autofocus: selected,
        onPressed: () {
          _sortMenu.close();
          widget.onSortModeChanged!(mode);
        },
        style: MenuItemButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
          ),
          alignment: Alignment.centerLeft,
          backgroundColor: selected ? tokens.surfaces.selected : null,
          foregroundColor: foreground,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              widget.sortModeLabel!(mode),
              style: tokens.type.listTitle.copyWith(
                color: foreground,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (selected)
              Padding(
                padding: EdgeInsets.only(left: tokens.spacing.gap),
                child: Icon(Icons.check, size: 20, color: foreground),
              ),
          ],
        ),
      ),
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
