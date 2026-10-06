import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/collections/shelf_sort.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

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
    this.viewOptionsTitle,
    this.viewOptions = const <LibraryViewOption>[],
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

  /// 「显示」单选组的小标题（书架：「合集显示」）；与 [viewOptions] 同时非空时，
  /// 排序按钮升级成「排序与显示」菜单，排序项下面接这一组。
  final String? viewOptionsTitle;

  /// 「显示」单选组（书架：合集整行展开 / 单个格子）。空 = 纯排序菜单（视频库等）。
  final List<LibraryViewOption> viewOptions;

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
        icon: FushiIcons.settingsGear,
        tooltip: t.tag_manage,
        onTap: () => _openTagManagement(context),
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
          icon: widget.selectionMode ? FushiIcons.close : FushiIcons.checklist,
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

    // 拆段形态（库页标签栏）：行首一枚「管理」chip（新建 / 改名 / 改色 / 合并 /
    // 排序的入口），有筛选时行尾一枚「清除」chip。
    final List<Widget> leadingChips = <Widget>[
      if (tagsOnly && widget.showTagManagement)
        _TagBarActionChip(
          key: const ValueKey<String>('library_tag_manage_chip'),
          icon: FushiIcons.settings,
          label: t.tag_manage,
          onTap: () => _openTagManagement(context),
        ),
    ];
    final List<Widget> trailingChips = <Widget>[
      if (tagsOnly && selectedIds.isNotEmpty)
        _TagBarActionChip(
          key: const ValueKey<String>('library_tag_clear_chip'),
          icon: FushiIcons.filterOff,
          label: t.tag_clear_filter,
          onTap: () => ref.read(selectedTagIdsProvider.notifier).state = <int>{},
        ),
    ];
    final int lead = leadingChips.length;
    final Widget tags = HorizontalDragScrollable(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // 拆段形态与库页工具行（`LibraryToolbar`，左右取页边）左缘对齐。
        padding: EdgeInsets.symmetric(
          horizontal:
              tagsOnly ? tokens.spacing.page : tokens.spacing.rowHorizontal,
          vertical: tokens.spacing.gap * 0.75,
        ),
        // 非钉住形态：整组动作作为**一个**工具栏项跟在标签后面滚动。
        itemCount: lead +
            widget.tags.length +
            trailingChips.length +
            (pinned || trailing.isEmpty ? 0 : 1),
        separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.gap * 0.75),
        itemBuilder: (context, rawIndex) {
          if (rawIndex < lead) return Center(child: leadingChips[rawIndex]);
          final int index = rawIndex - lead;
          if (index >= widget.tags.length) {
            final int extra = index - widget.tags.length;
            if (extra < trailingChips.length) {
              return Center(child: trailingChips[extra]);
            }
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
      // M3E 标签 chip 高 36 + 上下各 gap*0.75 的留白。
      return SizedBox(height: 36 + tokens.spacing.gap * 1.5, child: tags);
    }
    return Container(
      height: widget.pinActions ? 48 : 36 + tokens.spacing.gap * 1.5,
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

  /// 打开标签管理页；返回后刷新标签池与调用方的标签映射。
  void _openTagManagement(BuildContext context) {
    Navigator.push(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => const TagManagementPage(),
      ),
    ).then((_) {
      if (!mounted) return;
      ref.invalidate(allTagsProvider);
      widget.onTagsChanged?.call();
    });
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
    final String? viewTitle = widget.viewOptionsTitle;
    final bool hasView = viewTitle != null && widget.viewOptions.isNotEmpty;
    // 菜单面板样式交给 FushiMenuAnchor（MD3 走全局 menuTheme，Apple 走玻璃
    // 菜单面板），不再手拼 MenuStyle。有「显示」组时升级成「排序与显示」：
    // 两组各带小标题、中间分隔（Files / 照片的 View options 同形）。
    return FushiMenuAnchor(
      controller: _sortMenu,
      menuChildren: <Widget>[
        if (hasView) _menuSectionLabel(tokens, t.sort_by),
        for (final ShelfSortMode mode in ShelfSortMode.values)
          _choiceMenuItem(
            tokens,
            label: widget.sortModeLabel!(mode),
            selected: mode == selectedMode,
            onPressed: () => widget.onSortModeChanged!(mode),
          ),
        if (hasView) ...<Widget>[
          const FushiDivider(),
          _menuSectionLabel(tokens, viewTitle),
          for (final LibraryViewOption option in widget.viewOptions)
            _choiceMenuItem(
              tokens,
              key: option.key,
              label: option.label,
              icon: option.icon,
              selected: option.selected,
              // 排序组已有 autofocus 落点（选中的排序项），这组不抢。
              autofocus: false,
              onPressed: option.onSelected,
            ),
        ],
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return _tagBarAction(
          icon: hasView ? FushiIcons.settings : FushiIcons.sort,
          tooltip: hasView ? t.shelf_sort_and_view : t.sort_by,
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
        );
      },
    );
  }

  /// 菜单里一组单选项的小标题（不可聚焦，方向键直接跳过）。
  Widget _menuSectionLabel(FushiDesignTokens tokens, String text) {
    return ExcludeFocus(
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          tokens.spacing.rowHorizontal,
          tokens.spacing.gap,
          tokens.spacing.rowHorizontal,
          tokens.spacing.gap / 2,
        ),
        child: Text(text, style: tokens.type.sectionLabel),
      ),
    );
  }

  Widget _choiceMenuItem(
    FushiDesignTokens tokens, {
    required String label,
    required bool selected,
    required VoidCallback onPressed,
    Key? key,
    IconData? icon,
    bool? autofocus,
  }) {
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
        key: key,
        autofocus: autofocus ?? selected,
        onPressed: () {
          _sortMenu.close();
          onPressed();
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
            if (icon != null)
              Padding(
                padding: EdgeInsetsDirectional.only(end: tokens.spacing.gap),
                child: FushiIcon(icon, size: 20, color: foreground),
              ),
            Text(
              label,
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
                child: FushiIcon(FushiIcons.check, size: 20, color: foreground),
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
    // M3E 彩色 filter chip（选中饱和标签色 + 勾号、胶囊→圆角方弹簧形变）；Apple
    // 下它委托给 FushiTagChip( 玻璃胶囊 + 色点 )。
    return FushiTagToggleChip(
      label: tag.name,
      color: Color(tag.colorValue),
      state: isSelected ? TagCheckState.all : TagCheckState.none,
      dimmed: isDimmed,
      onTap: onTap,
    );
  }
}

/// 标签栏首尾的动作 chip（「管理」「清除」）：M3E 是 secondaryContainer 色块的
/// 圆角方 chip（与彩色标签 chip 一眼区分），Apple 是玻璃胶囊。
class _TagBarActionChip extends StatelessWidget {
  const _TagBarActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return FushiTagChip(label: label, onTap: onTap);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color fill = eink ? scheme.surface : scheme.secondaryContainer;
    final Color fg = eink ? scheme.onSurface : scheme.onSecondaryContainer;
    final OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      side: eink ? BorderSide(color: scheme.outline) : BorderSide.none,
    );
    return FushiPressScale(
      scale: 0.94,
      child: Material(
        color: fill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 14, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiIcon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: (Theme.of(context).textTheme.labelLarge ??
                            const TextStyle())
                        .copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「排序与显示」菜单「显示」组里的一个单选项（[FushiTagFilterBar.viewOptions]）。
@immutable
class LibraryViewOption {
  const LibraryViewOption({
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
    this.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  /// 行首图标（如横排行 / 网格），null = 纯文字。
  final IconData? icon;

  /// 挂在菜单项上的 key（测试按它点选）。
  final Key? key;
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
