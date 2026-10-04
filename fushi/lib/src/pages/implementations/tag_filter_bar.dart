import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/collections/shelf_sort.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/utils.dart';

/// 书架 / 视频 tab 共享的标签筛选栏：横向 tag chip（点选筛选、长按拖拽重排）+ 末尾
/// 「管理标签」齿轮；可选「批量选择」动作（仅书架多选书需要，[onToggleSelectionMode]
/// 为 null 时不渲染）。两处用同一组件，保证标签栏外观/交互完全一致。
///
/// 筛选状态走共享的 [selectedTagIdsProvider]（与书架联动）；管理标签返回后刷新
/// [allTagsProvider] 并回调 [onTagsChanged]，让调用方刷新各自的 book/video 标签映射。
///
/// [part] 让库页把整栏拆进统一的库页工具行（`LibraryToolbar`，2026-10-04）：
/// [FushiTagFilterBarPart.actions] 出「管理标签（常驻，新建标签入口）+ 批量选择 +
/// 排序」三枚图标（放进搜索行行尾）；[FushiTagFilterBarPart.tags] 只出标签 chip，
/// 没有标签时整段不占高度——不再有只剩两枚孤立图标的第三行和多余分隔线。
class FushiTagFilterBar extends ConsumerStatefulWidget {
  const FushiTagFilterBar({
    required this.tags,
    required this.onToggleFilter,
    required this.onReorder,
    this.part = FushiTagFilterBarPart.full,
    this.selectionMode = false,
    this.pinActions = false,
    this.showTagManagement = true,
    this.onToggleSelectionMode,
    this.sortMode,
    this.sortModeLabel,
    this.onSortModeChanged,
    this.onTagsChanged,
    super.key,
  });

  /// 渲染整栏还是其中一段，见类注释。
  final FushiTagFilterBarPart part;

  /// Keep actions visible while tags scroll on compact library layouts.
  /// [FushiTagFilterBarPart.actions] 下决定图标是否用 44 触控尺寸。
  final bool pinActions;
  final bool showTagManagement;

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
  ConsumerState<FushiTagFilterBar> createState() => _FushiTagFilterBarState();
}

class _FushiTagFilterBarState extends ConsumerState<FushiTagFilterBar> {
  final MenuController _sortMenu = MenuController();

  @override
  Widget build(BuildContext context) {
    final Set<int> selectedIds = ref.watch(selectedTagIdsProvider);
    final t = Translations.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    final bool actionsOnly = widget.part == FushiTagFilterBarPart.actions;
    // 「管理标签」（新建 / 改名 / 删除标签的入口）。整栏 / 标签段形态下有标签才
    // 显示；拆进工具行（actions）后**常驻**——没有任何标签时这里就是唯一的
    // 新建标签入口，key 沿用书架窄屏那枚常驻齿轮的 `library_tag_settings`。
    final Widget tagManage = KeyedSubtree(
      key: const ValueKey<String>('library_tag_settings'),
      child: _tagBarAction(
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
    );
    // 末尾动作：先「管理标签」，再可选「批量选择」。
    final List<Widget> tagActions = <Widget>[
      if (widget.showTagManagement && (actionsOnly || widget.tags.isNotEmpty))
        tagManage,
    ];
    final List<Widget> viewActions = <Widget>[
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

    if (actionsOnly) {
      // 「管理标签 + 批量选择 + 排序」：放进库页工具行行尾，与搜索 / 筛选同一行。
      return FushiToolbar(
        dense: true,
        children: <Widget>[...tagActions, ...viewActions],
      );
    }
    final bool tagsOnly = widget.part == FushiTagFilterBarPart.tags;
    if (tagsOnly && widget.tags.isEmpty) return const SizedBox.shrink();
    // 标签段不再重复「管理标签」：它已常驻在工具行行尾。
    final List<Widget> trailing = tagsOnly
        ? const <Widget>[]
        : <Widget>[...tagActions, ...viewActions];
    // 拆出的标签段不钉住动作：齿轮跟在标签后面滚动。
    final bool pinned = widget.pinActions && !tagsOnly;

    final Widget tags = HorizontalDragScrollable(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // 拆段形态与库页工具行（`LibraryToolbar`，左右 12）左缘对齐。
        padding: EdgeInsets.symmetric(
          horizontal: tagsOnly ? 12 : tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.gap * 0.75,
        ),
        // 非钉住形态：整组动作作为**一个**工具栏项跟在标签后面滚动。
        itemCount: widget.tags.length +
            (pinned || trailing.isEmpty ? 0 : 1),
        separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap * 0.75),
        itemBuilder: (context, index) {
          if (index >= widget.tags.length) {
            return Center(child: FushiToolbar(dense: true, children: trailing));
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
            feedback: FushiReorderDragProxy(
              transparent: true,
              borderRadius: tokens.radii.chipRadius,
              child: _tagFilterChip(
                tag: tag,
                isSelected: true,
                isDimmed: false,
              ),
            ),
            childWhenDragging: Opacity(
              opacity: isEinkTheme(context) ? 1 : 0.3,
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
                final int oldIdx = widget.tags.indexWhere(
                  (t) => t.id == draggedTag.id,
                );
                final int newIdx = widget.tags.indexWhere(
                  (t) => t.id == tag.id,
                );
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
    if (tagsOnly) {
      // 拆段形态：紧跟在库页工具行下面，与内容之间靠留白分隔，不画分隔线。
      return SizedBox(height: tokens.spacing.gap * 5.5, child: tags);
    }
    return Container(
      height: widget.pinActions ? 48 : tokens.spacing.gap * 5.5,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            // eink：30% alpha 分隔线合成抖动灰 → 实心 outline（巡检 PR-3）。
            // Apple：系统 separator（本身带 alpha 的发丝线色）。
            color: isEinkTheme(context)
                ? tokens.surfaces.outline
                : isGlassDesign(context)
                    ? appleColorsOf(context).separator
                    : tokens.surfaces.outline.withValues(alpha: 0.3),
          ),
        ),
      ),
      // 标签多了必须横向拖动才够用，而桌面默认 dragDevices 不含鼠标（拖不动，
      // 只能滚轮）。放开鼠标拖动与区内标签 chip 的 LongPressDraggable 不冲突：
      // 按下即动归滚动、按住不动满 kLongPressTimeout 归拖标签。
      child: widget.pinActions
          ? Row(
              children: <Widget>[
                Expanded(child: tags),
                FushiToolbar(dense: true, children: trailing),
                const SizedBox(width: 12),
              ],
            )
          : tags,
    );
  }

  Widget _tagBarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (widget.pinActions) {
      return FushiIconButtonControl(
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        icon: FushiIcon(icon, size: 20),
        color: selected ? tokens.surfaces.primary : tokens.surfaces.onVariant,
        isSelected: selected,
        onPressed: onTap,
      );
    }
    return FushiIconButton(
      icon: icon,
      tooltip: tooltip,
      size: tokens.spacing.gap * 2.25,
      padding: EdgeInsets.all(tokens.spacing.gap * 0.875),
      // 选中（多选模式开着）交给 Expressive toggle / Apple 强调色玻璃圆钮。
      selected: selected,
      enabledColor: selected ? null : tokens.surfaces.onVariant,
      onTap: onTap,
    );
  }

  /// 「排序方式」三项单选菜单：MenuAnchor + 选中项 autofocus（手柄/键盘打开即落进
  /// 菜单，D-pad 可遍历、A/Enter 选中、B 关闭——与 [GamepadMenuDropdown] 的
  /// polled 路径同款交互，样式走同一组 menu tokens）。
  Widget _sortMenuAction(FushiDesignTokens tokens) {
    final t = Translations.of(context);
    final ShelfSortMode selectedMode = widget.sortMode!;
    // 菜单面板样式交给 FushiMenuAnchor（MD3 走全局 menuTheme，Apple 走玻璃
    // 菜单面板），不再手拼 MenuStyle。
    return FushiMenuAnchor(
      controller: _sortMenu,
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
    FushiDesignTokens tokens,
    ShelfSortMode mode,
    ShelfSortMode selectedMode,
  ) {
    final bool selected = mode == selectedMode;
    // Apple：行样式交给玻璃菜单的 MenuButtonTheme（悬停 / 焦点强调色块 +
    // onAccent 字），选中只靠行尾对勾；MD3 保留选中底 + 主色字。
    final bool glass = isGlassDesign(context);
    final Color? foreground = glass
        ? null
        : selected
            ? tokens.surfaces.primary
            : tokens.surfaces.onSurface;
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
        style: glass
            ? null
            : MenuItemButton.styleFrom(
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
              style: glass
                  ? null
                  : tokens.type.listTitle.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
            ),
            if (selected)
              Padding(
                padding: EdgeInsets.only(left: tokens.spacing.gap),
                child: FushiIcon(Icons.check, size: 20, color: foreground),
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
    return FushiTagChip(
      label: tag.name,
      color: Color(tag.colorValue),
      selected: isSelected,
      dimmed: isDimmed,
      tone: FushiTagChipTone.surface,
      onTap: onTap,
    );
  }
}

/// [FushiTagFilterBar] 渲染哪一段。
enum FushiTagFilterBarPart {
  /// 整栏：标签 chip + 末尾全部动作（独立使用 / 旧调用点）。
  full,

  /// 只出标签 chip；无标签时零高度。
  tags,

  /// 只出「管理标签（常驻）+ 批量选择 + 排序」（放进库页工具行行尾）。
  actions,
}
