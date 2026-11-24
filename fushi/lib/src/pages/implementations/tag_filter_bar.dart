import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/media/collections/shelf_sort.dart';
import 'package:fushi/src/media/tags/tag_chip_draggable.dart';
import 'package:fushi/src/media/tags/tag_chips.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart'
    show LibraryAppleFilterRowScope;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_divider.dart';
import 'package:fushi/src/utils/components/fushi_header_menu_anchor.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_popup_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleMacScale, fushiAppleUsesMacMetrics;
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 书架 / 视频 tab 共享的标签筛选栏：横向 tag chip（点选筛选、拖拽重排：鼠标按住即拖、触屏长按拖）+ 末尾
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
    this.filterOptionsTitle,
    this.filterOptions = const <LibraryViewOption>[],
    this.filterActive = false,
    this.tagsInMenu = false,
    this.inlineTags = false,
    this.onTagsChanged,
    this.sortMenuController,
    this.leadingChips = const <Widget>[],
    this.onAiOrganize,
    this.extraSections = const <LibraryViewSection>[],
    this.onOpenViewSheet,
    super.key,
  });

  /// 排序（与筛选）组之后追加的单选组（库页「每行数量」，2026-11-07）。
  final List<LibraryViewSection> extraSections;

  /// 非 null 时排序按钮不开锚定菜单、改调它（窄窗打开「排序与显示」底部抽屉，
  /// 见 [showLibraryViewSheet]）。调用方按 [libraryViewOptionsUseSheet] 决定传不传。
  final VoidCallback? onOpenViewSheet;

  /// [FushiTagFilterBarPart.tags] 行首的额外 chip（库页生效中的筛选条件，带 ✕；
  /// 2026-10-14）。非空时即使没有标签也出这一行；与标签之间画一道竖分隔。
  final List<Widget> leadingChips;

  /// 「AI 整理」（spec docs/specs/2026-10-20-ai-library-organize-design.md §10.1）。
  /// null = 不显示：调用方按 AI 模块门（`isAiModuleEnabled`）决定传不传。
  final VoidCallback? onAiOrganize;

  /// 外部持有的排序菜单控制器（[FushiTagFilterBarPart.sortMenuAnchor] 用：页头
  /// 里的排序按钮经它打开本组件画的菜单）。null 时自建。
  final FushiHeaderMenuController? sortMenuController;

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

  /// 「筛选」单选组的小标题（书架 / 漫画库：「阅读状态」）。与 [filterOptions]
  /// 同时非空时，这组单选项排在排序项后面（2026-10-10 用户：「阅读
  /// 状态下拉框放在排序那」——工具行不再单独占一枚下拉 chip）。
  final String? filterOptionsTitle;

  /// 「筛选」单选组（含「全部」项）；空 = 菜单里没有筛选组。
  final List<LibraryViewOption> filterOptions;

  /// [filterOptions] 当前不是「全部」：排序按钮右上角亮一枚主色圆点，列表被筛过
  /// 一眼可见（筛选收进菜单后，工具行上不再有激活态 chip 提示）。
  final bool filterActive;

  /// 把标签筛选并进「排序」菜单（多选组，选中即生效、菜单不关）：窄屏库页顶部
  /// 只留「页签 / 搜索」两行，标签 chip 不再单独占一行（2026-10-10）。有标签选中
  /// 时排序按钮同样亮圆点。
  final bool tagsInMenu;

  /// [FushiTagFilterBarPart.tags] 嵌进库页工具行搜索框右边那段（宽屏）：不留页边、
  /// 不重复「管理标签」chip（齿轮已常驻行尾），高度与搜索框同高。
  final bool inlineTags;

  /// 管理标签返回后，调用方据此刷新自身的标签映射 provider（book / video）。
  final VoidCallback? onTagsChanged;

  @override
  ConsumerState<FushiTagFilterBar> createState() => _FushiTagFilterBarState();
}

/// 嵌进工具行的标签段上下留白（[FushiTagFilterBar.inlineTags]）。
const double _inlineTagPad = 4;

class _FushiTagFilterBarState extends ConsumerState<FushiTagFilterBar> {
  final MenuController _ownSortMenu = MenuController();

  /// 标签条横滚的控制器：交给 [HorizontalDragScrollable] 让鼠标横滚与 chip 的
  /// 长按重排用同一个起拖门槛（BUG-5174）。
  final ScrollController _tagScrollController = ScrollController();

  /// Apple「筛选」pull-down 的菜单（排序与筛选拆成两个下拉，方案 A 第 9 / 10 项）。
  final MenuController _filterMenu = MenuController();

  /// 最近一次登记标签节的侧栏宿主（撤回用）。
  AppleSidebarLibraryHost? _tagHost;

  @override
  void deactivate() {
    // 卸下（换 tab 父节点 / 整页销毁）时撤回侧栏标签节；重新挂上会重建、再登记。
    _tagHost?.publishTags(this, null);
    super.deactivate();
  }

  @override
  void dispose() {
    _tagHost?.publishTags(this, null);
    _tagScrollController.dispose();
    super.dispose();
  }

  /// macOS 档侧栏是否承载标签节（方案 A 第 8 项）：Apple 设计系统 + 宽窗侧栏
  /// 形态 + macOS 度量。此时内容区不画标签 chip、菜单里不放标签、工具行不放
  /// 「管理标签」齿轮——它们都在侧栏「标签」节里。
  bool _sidebarHostsTags(BuildContext context) {
    if (!isGlassDesign(context)) return false;
    final AppleSidebarLibraryHost? host = AppleSidebarLibraryScope.maybeOf(
      context,
    );
    return host != null &&
        host.sidebarMode &&
        fushiAppleUsesMacMetrics(context);
  }

  /// 工具行（[FushiTagFilterBarPart.actions]）把标签节登记进侧栏：所在 tab 可见
  /// 且侧栏承载标签时登记，否则撤回。
  void _publishSidebarTags(
    BuildContext context, {
    required bool hosts,
    required Set<int> selectedIds,
  }) {
    final AppleSidebarLibraryHost? host = AppleSidebarLibraryScope.peek(
      context,
    );
    if (_tagHost != host) _tagHost?.publishTags(this, null);
    _tagHost = host;
    if (host == null) return;
    if (!hosts || !SectionVisibility.of(context)) {
      host.publishTags(this, null);
      return;
    }
    final t = Translations.of(context);
    host.publishTags(this, <AppleSidebarLibraryRow>[
      AppleSidebarLibraryRow.header(id: 'tags', label: t.tag_label),
      for (final BookTagRow tag in widget.tags)
        AppleSidebarLibraryRow(
          id: 'tag-${tag.id}',
          label: tag.name,
          icon: FushiIcons.tag,
          tint: Color(tag.colorValue),
          selected: selectedIds.contains(tag.id),
          onTap: () => widget.onToggleFilter(tag.id),
        ),
      if (widget.showTagManagement)
        AppleSidebarLibraryRow(
          id: 'tags-manage',
          label: '${t.tag_manage}…',
          icon: FushiIcons.settingsGear,
          selected: false,
          onTap: () => _openTagManagement(context),
        ),
    ]);
  }

  MenuController get _sortMenu =>
      widget.sortMenuController?.menu ?? _ownSortMenu;

  @override
  Widget build(BuildContext context) {
    final Set<int> selectedIds = ref.watch(selectedTagIdsProvider);
    final t = Translations.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    if (widget.part == FushiTagFilterBarPart.sortMenuAnchor) {
      return _sortMenuAnchor(tokens, selectedIds);
    }
    final bool actionsOnly = widget.part == FushiTagFilterBarPart.actions;
    final bool sidebarTags = _sidebarHostsTags(context);
    if (widget.part == FushiTagFilterBarPart.appleFilterRow) {
      return _appleFilterRow(tokens, selectedIds);
    }
    // iOS 档标题下那一行（[FushiTagFilterBarPart.appleFilterRow]）挂着时，
    // 「筛选」与「管理标签」都在那一行里，行尾不再重复。
    final bool filterRowShown =
        actionsOnly && LibraryAppleFilterRowScope.activeOf(context);
    if (actionsOnly && isGlassDesign(context)) {
      _publishSidebarTags(
        context,
        hosts: sidebarTags,
        selectedIds: selectedIds,
      );
    }
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
      if (widget.showTagManagement &&
          !sidebarTags &&
          !filterRowShown &&
          (actionsOnly || widget.tags.isNotEmpty))
        tagManage,
    ];
    final List<Widget> viewActions = <Widget>[
      if (widget.onAiOrganize != null && !widget.selectionMode)
        KeyedSubtree(
          key: const ValueKey<String>('library_ai_organize'),
          child: _tagBarAction(
            icon: FushiIcons.aiAssistant,
            tooltip: t.library_organize_action,
            onTap: widget.onAiOrganize!,
          ),
        ),
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
          !widget.selectionMode) ...<Widget>[
        // Apple：排序 / 筛选拆成两个中性灰 pull-down（方案 A 第 9 / 10 项）。
        if (isGlassDesign(context)) ...<Widget>[
          _appleSortPullDown(tokens, selectedIds),
          if (!filterRowShown)
            ?_appleFilterPullDown(
              tokens,
              selectedIds,
              // 侧栏承载标签（macOS 档）时菜单里不放标签。
              tagsInMenu: !sidebarTags,
            ),
        ] else
          _sortMenuAction(tokens, selectedIds),
      ],
    ];

    if (actionsOnly) {
      // 「管理标签 + 批量选择 + 排序」：放进库页工具行行尾，与搜索 / 筛选同一行。
      return FushiToolbar(
        dense: true,
        children: <Widget>[...tagActions, ...viewActions],
      );
    }
    final bool tagsOnly = widget.part == FushiTagFilterBarPart.tags;
    if (tagsOnly && widget.tags.isEmpty && widget.leadingChips.isEmpty) {
      return const SizedBox.shrink();
    }
    // macOS 档侧栏承载标签节：内容区不再重复画标签 chip（筛选条件 chip 照常）。
    if (tagsOnly && sidebarTags && widget.leadingChips.isEmpty) {
      return const SizedBox.shrink();
    }
    // 标签段不再重复「管理标签」：它已常驻在工具行行尾。
    final List<Widget> trailing = tagsOnly
        ? const <Widget>[]
        : <Widget>[...tagActions, ...viewActions];
    // 拆出的标签段不钉住动作：齿轮跟在标签后面滚动。
    final bool pinned = widget.pinActions && !tagsOnly;

    // 拆段形态（库页标签栏）：不再有行首「管理标签」大 chip——它与工具行行尾常驻
    // 的「管理标签」齿轮（`library_tag_settings`）是同一个入口，重复（2026-10-09
    // 用户拍板砍掉大的）。有筛选时行尾一枚「清除」chip。
    // 行首可选的「生效中筛选条件」chip（库页筛选面板的结果），与标签之间一道
    // 竖分隔把两类条件分开。
    final List<Widget> leadingChips = <Widget>[
      if (tagsOnly) ...widget.leadingChips,
      if (tagsOnly && widget.leadingChips.isNotEmpty && widget.tags.isNotEmpty)
        SizedBox(
          height: 20,
          child: VerticalDivider(
            width: 1,
            thickness: 1,
            color: tokens.surfaces.outline,
          ),
        ),
    ];
    final List<Widget> trailingChips = <Widget>[
      if (tagsOnly && selectedIds.isNotEmpty)
        FushiTagActionChip(
          key: const ValueKey<String>('library_tag_clear_chip'),
          icon: FushiIcons.filterOff,
          label: t.tag_clear_filter,
          onTap: () =>
              ref.read(selectedTagIdsProvider.notifier).state = <int>{},
        ),
    ];
    final int lead = leadingChips.length;
    final Widget tags = HorizontalDragScrollable(
      mouseDragController: _tagScrollController,
      child: ListView.separated(
        controller: _tagScrollController,
        scrollDirection: Axis.horizontal,
        // 拆段形态与库页工具行（`LibraryToolbar`，左右取页边）左缘对齐。
        padding: EdgeInsets.symmetric(
          horizontal: widget.inlineTags
              ? 0
              : tagsOnly
              ? tokens.spacing.page
              : tokens.spacing.rowHorizontal,
          vertical: widget.inlineTags
              ? _inlineTagPad
              : tokens.spacing.gap * 0.75,
        ),
        // 非钉住形态：整组动作作为**一个**工具栏项跟在标签后面滚动。
        itemCount:
            lead +
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
          final Widget dragFeedback = FushiReorderDragProxy(
            transparent: true,
            borderRadius: tokens.radii.chipRadius,
            child: _tagFilterChip(tag: tag, isSelected: true, isDimmed: false),
          );
          // BUG-4899 / BUG-5066 / BUG-5174：chip 本身长按起拖（鼠标与触屏一致），
          // 按下就拖归标签条横滚、不动松开归单击筛选；长按与鼠标横滚共用一个
          // 容忍手抖的门槛；落点是 chip 上的 DragTarget。
          return FushiTagChipDraggable<BookTagRow>(
            key: ValueKey<String>('library_tag_draggable_${tag.id}'),
            data: tag,
            feedback: dragFeedback,
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
      // 嵌进工具行（宽屏）：chip 36 + 上下各 4，与并排的搜索框中线对齐。
      if (widget.inlineTags) {
        return SizedBox(height: 36 + _inlineTagPad * 2, child: tags);
      }
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
      // 只能 Shift+滚轮）。HorizontalDragScrollable 放开鼠标拖动：鼠标 / 触屏
      // 按下就拖归横滚（含 chip 上），长按 chip 后拖归重排标签。
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
    openLibraryTagManagement(
      context,
      ref: ref,
      onTagsChanged: widget.onTagsChanged,
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
  Widget _sortMenuAction(FushiDesignTokens tokens, Set<int> selectedTagIds) {
    final t = Translations.of(context);
    final String? filterTitle = widget.filterOptionsTitle;
    final bool hasFilter =
        filterTitle != null && widget.filterOptions.isNotEmpty;
    final bool hasTags = widget.tagsInMenu && widget.tags.isNotEmpty;
    final bool grouped =
        hasFilter || hasTags || widget.extraSections.isNotEmpty;
    // 筛选生效（阅读状态不是「全部」/ 菜单里的标签有选中）：按钮亮圆点。
    final bool filtered =
        widget.filterActive || (hasTags && selectedTagIds.isNotEmpty);
    // 菜单面板样式交给 FushiMenuAnchor（MD3 走全局 menuTheme，Apple 走玻璃
    // 菜单面板），不再手拼 MenuStyle。有「筛选 / 标签」组时升级成「排序与筛选」菜单：各组带小标题、组间分隔。
    return FushiMenuAnchor(
      controller: _sortMenu,
      menuChildren: _sortMenuChildren(tokens, selectedTagIds),
      builder: (BuildContext context, MenuController controller, Widget? _) {
        final String tooltip = hasFilter || hasTags
            ? t.library_sort_filter
            : grouped
            ? t.library_sort_view
            : t.sort_by;
        return LibraryFilterBadge(
          key: const ValueKey<String>('library_sort_menu_button'),
          active: filtered,
          child: _tagBarAction(
            icon: grouped ? FushiIcons.settings : FushiIcons.sort,
            tooltip: filtered
                ? '$tooltip · ${t.library_filter_active}'
                : tooltip,
            onTap:
                widget.onOpenViewSheet ??
                () =>
                    controller.isOpen ? controller.close() : controller.open(),
          ),
        );
      },
    );
  }

  /// Apple「排序」pull-down：当前排序方式作按钮文案（pop-up button 显示当前
  /// 值），菜单 = 排序方式 + 显示类附加组（每行数量等）。中性灰、无强调色。
  Widget _appleSortPullDown(FushiDesignTokens tokens, Set<int> selectedIds) {
    final t = Translations.of(context);
    return _applePullDown(
      key: const ValueKey<String>('library_sort_menu_button'),
      controller: _sortMenu,
      label: widget.sortModeLabel!(widget.sortMode!),
      semanticLabel: t.sort_by,
      active: false,
      menuChildren: <Widget>[
        _menuSectionLabel(tokens, t.sort_by),
        ..._sortChoiceItems(tokens),
        ..._extraSectionItems(tokens),
      ],
    );
  }

  /// Apple「筛选」pull-down：阅读 / 观看状态等单选组 + 标签多选组（侧栏承载标签
  /// 时不放）。生效时按钮写「筛选 · 条件」并加深一档灰（Apple 下拉不带强调色）。
  /// 没有任何筛选维度时不画。
  Widget? _appleFilterPullDown(
    FushiDesignTokens tokens,
    Set<int> selectedIds, {
    required bool tagsInMenu,
  }) {
    final t = Translations.of(context);
    final String? filterTitle = widget.filterOptionsTitle;
    final bool hasFilter =
        filterTitle != null && widget.filterOptions.isNotEmpty;
    final bool hasTags = tagsInMenu && widget.tags.isNotEmpty;
    if (!hasFilter && !hasTags) return null;
    final List<String> active = <String>[
      if (hasFilter && widget.filterActive)
        for (final LibraryViewOption option in widget.filterOptions)
          if (option.selected) option.label,
      if (hasTags)
        for (final BookTagRow tag in widget.tags)
          if (selectedIds.contains(tag.id)) tag.name,
    ];
    final String title = t.shelf_toolbar_filters;
    final String more = active.length > 1 ? ' +${active.length - 1}' : '';
    return _applePullDown(
      key: const ValueKey<String>('library_filter_menu_button'),
      controller: _filterMenu,
      label: active.isEmpty ? title : '$title · ${active.first}$more',
      semanticLabel: active.isEmpty
          ? title
          : '$title · ${t.library_filter_active}',
      active: active.isNotEmpty,
      menuChildren: <Widget>[
        if (hasFilter) ...<Widget>[
          _menuSectionLabel(tokens, filterTitle),
          ..._filterChoiceItems(
            tokens,
            menu: _filterMenu,
            autofocusFirst: true,
          ),
        ],
        if (hasTags) ...<Widget>[
          if (hasFilter) const FushiDivider(),
          ..._tagChoiceItems(tokens, selectedIds, menu: _filterMenu),
        ],
      ],
    );
  }

  /// iOS 档标题下的筛选行：「筛选」pull-down（只放状态类单选组，标签都在本行
  /// 胶囊里，不在菜单里重复）+ 标签胶囊 + 末尾「管理标签…」。横向滑动，左右
  /// 取页边；没有任何筛选维度也没有标签管理时零高度。
  Widget _appleFilterRow(FushiDesignTokens tokens, Set<int> selectedIds) {
    final t = Translations.of(context);
    final Widget? filter = _appleFilterPullDown(
      tokens,
      selectedIds,
      tagsInMenu: false,
    );
    final List<Widget> items = <Widget>[
      ?filter,
      for (final BookTagRow tag in widget.tags)
        _AppleTagCapsule(
          key: ValueKey<String>('library_tag_capsule_${tag.id}'),
          label: tag.name,
          color: Color(tag.colorValue),
          selected: selectedIds.contains(tag.id),
          onTap: () => widget.onToggleFilter(tag.id),
          onLongPress: widget.showTagManagement
              ? () => _openTagManagement(context)
              : null,
        ),
      if (widget.showTagManagement)
        _AppleTagCapsule(
          key: const ValueKey<String>('library_tag_settings'),
          label: '${t.tag_manage}…',
          icon: FushiIcons.tag,
          selected: false,
          onTap: () => _openTagManagement(context),
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: FushiApplePopUpButtonFace.defaultHeightOf(context) + 8,
      child: HorizontalDragScrollable(
        mouseDragController: _tagScrollController,
        child: ListView.separated(
          key: const ValueKey<String>('library_apple_filter_row'),
          controller: _tagScrollController,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.page,
            vertical: 4,
          ),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (BuildContext context, int i) => Center(child: items[i]),
        ),
      ),
    );
  }

  /// 一个 Apple pull-down：公共 pop-up 按钮外观（iOS 灰胶囊 / macOS pop-up
  /// button）+ 玻璃菜单面板（[FushiMenuAnchor]）。
  Widget _applePullDown({
    required Key key,
    required MenuController controller,
    required String label,
    required String semanticLabel,
    required bool active,
    required List<Widget> menuChildren,
  }) {
    final double height = FushiApplePopUpButtonFace.defaultHeightOf(context);
    return FushiMenuAnchor(
      controller: controller,
      menuChildren: menuChildren,
      builder: (BuildContext context, MenuController menu, Widget? _) =>
          FushiPlainButton(
            key: key,
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            borderRadius: FushiApplePopUpButtonFace.radiusOf(context, height),
            fill: FushiApplePopUpButtonFace.fillOf(context),
            semanticLabel: semanticLabel,
            child: FushiApplePopUpButtonFace(
              label: label,
              active: active,
              height: height,
              maxLabelWidth: 180,
              paintFill: false,
            ),
          ),
    );
  }

  /// 排序菜单的常驻锚点（[FushiTagFilterBarPart.sortMenuAnchor]），弹出位置
  /// 跟着触发控件（[FushiHeaderMenuController]）。排序参数不全 / 没给外部
  /// 控制器时不画（页头也不会出排序按钮）。
  Widget _sortMenuAnchor(FushiDesignTokens tokens, Set<int> selectedTagIds) {
    final FushiHeaderMenuController? controller = widget.sortMenuController;
    if (controller == null ||
        widget.sortMode == null ||
        widget.sortModeLabel == null ||
        widget.onSortModeChanged == null) {
      return const SizedBox.shrink();
    }
    return FushiHeaderMenuAnchor(
      controller: controller,
      menuChildren: _sortMenuChildren(tokens, selectedTagIds),
    );
  }

  /// 「排序方式」（+ 筛选 / 标签组）菜单项：工具行按钮上的菜单与单行页头的
  /// 常驻锚点共用。
  List<Widget> _sortMenuChildren(
    FushiDesignTokens tokens,
    Set<int> selectedTagIds,
  ) {
    final t = Translations.of(context);
    final String? filterTitle = widget.filterOptionsTitle;
    final bool hasFilter =
        filterTitle != null && widget.filterOptions.isNotEmpty;
    final bool hasTags = widget.tagsInMenu && widget.tags.isNotEmpty;
    final bool grouped =
        hasFilter || hasTags || widget.extraSections.isNotEmpty;
    return <Widget>[
      if (grouped) _menuSectionLabel(tokens, t.sort_by),
      ..._sortChoiceItems(tokens),
      if (hasFilter) ...<Widget>[
        const FushiDivider(),
        _menuSectionLabel(tokens, filterTitle),
        ..._filterChoiceItems(tokens),
      ],
      ..._extraSectionItems(tokens),
      if (hasTags) ...<Widget>[
        const FushiDivider(),
        ..._tagChoiceItems(tokens, selectedTagIds),
      ],
    ];
  }

  /// 「排序方式」单选项。
  List<Widget> _sortChoiceItems(FushiDesignTokens tokens) {
    final ShelfSortMode selectedMode = widget.sortMode!;
    return <Widget>[
      for (final ShelfSortMode mode in ShelfSortMode.values)
        _choiceMenuItem(
          tokens,
          label: widget.sortModeLabel!(mode),
          selected: mode == selectedMode,
          onPressed: () => widget.onSortModeChanged!(mode),
        ),
    ];
  }

  /// 筛选单选组的选项（小标题由调用方给）。[autofocusFirst]：本组就是菜单的
  /// 第一组时选中项接 autofocus 落点（否则排序组已有落点，这组不抢）。
  List<Widget> _filterChoiceItems(
    FushiDesignTokens tokens, {
    MenuController? menu,
    bool autofocusFirst = false,
  }) => <Widget>[
    for (final LibraryViewOption option in widget.filterOptions)
      _choiceMenuItem(
        tokens,
        key: option.key,
        label: option.label,
        icon: option.icon,
        selected: option.selected,
        autofocus: autofocusFirst ? null : false,
        menu: menu,
        onPressed: option.onSelected,
      ),
  ];

  /// 附加组（每行数量等），每组前一道分隔 + 小标题。
  List<Widget> _extraSectionItems(FushiDesignTokens tokens) => <Widget>[
    for (final LibraryViewSection section in widget.extraSections) ...<Widget>[
      const FushiDivider(),
      _menuSectionLabel(tokens, section.title),
      for (final LibraryViewOption option in section.options)
        _choiceMenuItem(
          tokens,
          key: option.key,
          label: option.label,
          icon: option.icon,
          selected: option.selected,
          autofocus: false,
          onPressed: option.onSelected,
        ),
    ],
  ];

  /// 标签多选组（小标题 + 各标签 + 有选中时「清除筛选」）。多选：点一个标签只
  /// 切换它，菜单不关，可以连选几个。
  List<Widget> _tagChoiceItems(
    FushiDesignTokens tokens,
    Set<int> selectedTagIds, {
    MenuController? menu,
  }) {
    final t = Translations.of(context);
    return <Widget>[
      _menuSectionLabel(tokens, t.tag_label),
      for (final BookTagRow tag in widget.tags)
        _choiceMenuItem(
          tokens,
          key: ValueKey<String>('library_menu_tag_${tag.id}'),
          label: tag.name,
          selected: selectedTagIds.contains(tag.id),
          dotColor: Color(tag.colorValue),
          autofocus: false,
          keepOpen: true,
          menu: menu,
          onPressed: () => widget.onToggleFilter(tag.id),
        ),
      if (selectedTagIds.isNotEmpty)
        _choiceMenuItem(
          tokens,
          key: const ValueKey<String>('library_menu_tag_clear'),
          label: t.tag_clear_filter,
          icon: FushiIcons.filterOff,
          selected: false,
          autofocus: false,
          menu: menu,
          onPressed: () =>
              ref.read(selectedTagIdsProvider.notifier).state = <int>{},
        ),
    ];
  }

  /// 菜单里一组单选项的小标题（不可聚焦，方向键直接跳过）。
  Widget _menuSectionLabel(FushiDesignTokens tokens, String text) {
    // Apple：iOS / macOS 菜单的分组小标题（与行文字左对齐）。
    if (isGlassDesign(context)) return FushiAppleMenuSectionHeader(text);
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
    Color? dotColor,
    bool? autofocus,
    bool keepOpen = false,
    MenuController? menu,
  }) {
    final MenuController owner = menu ?? _sortMenu;
    // Apple：行样式交给玻璃菜单的 MenuButtonTheme；iOS 27 / macOS 菜单行 =
    // [✓ 列][图标 / 色点][文字]。MD3 保留选中底 + 主色字 + 行尾对勾。
    final bool glass = isGlassDesign(context);
    final Widget? appleGlyph = !glass
        ? null
        : icon != null
        // 宽屏 macOS 菜单不画行内图标（标签色点是数据，保留）。
        ? (fushiAppleCompact(context) ? null : FushiIcon(icon))
        : dotColor != null
        ? DecoratedBox(
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            child: const SizedBox.square(dimension: 8),
          )
        : null;
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
              owner.close();
              return true;
            }
            return null;
          },
        ),
      },
      child: MenuItemButton(
        key: key,
        autofocus: autofocus ?? selected,
        closeOnActivate: !keepOpen,
        onPressed: () {
          if (!keepOpen) owner.close();
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
        leadingIcon: glass ? FushiAppleMenuCheck(checked: selected) : null,
        child: glass
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (appleGlyph != null) ...<Widget>[
                    appleGlyph,
                    SizedBox(
                      width: fushiAppleCompact(context)
                          ? 6 * fushiAppleMacScale(context)
                          : 12,
                    ),
                  ],
                  Text(label),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null)
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: tokens.spacing.gap,
                      ),
                      child: FushiIcon(icon, size: 20, color: foreground),
                    )
                  else if (dotColor != null)
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        end: tokens.spacing.gap,
                      ),
                      child: SizedBox.square(
                        dimension: 20,
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: dotColor,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox.square(dimension: 10),
                          ),
                        ),
                      ),
                    ),
                  Text(
                    label,
                    style: glass
                        ? null
                        : tokens.type.listTitle.copyWith(
                            color: foreground,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                  ),
                  if (selected)
                    Padding(
                      padding: EdgeInsets.only(left: tokens.spacing.gap),
                      child: FushiIcon(
                        FushiIcons.check,
                        size: 20,
                        color: foreground,
                      ),
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
      // 库页标签段压在页头吸顶面上（设计稿 V3）：未选中态半透明底，与页头同色调。
      overlay: widget.part == FushiTagFilterBarPart.tags,
    );
  }
}

/// 「排序与筛选」菜单里一组单选项里的一项（[FushiTagFilterBar.filterOptions]）。
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

/// 「排序与显示」里的一组单选项（菜单里一段 / 窄窗抽屉里一组 chip）。
@immutable
class LibraryViewSection {
  const LibraryViewSection({required this.title, required this.options});

  final String title;
  final List<LibraryViewOption> options;
}

/// [FushiTagFilterBar] 渲染哪一段。
enum FushiTagFilterBarPart {
  /// 整栏：标签 chip + 末尾全部动作（独立使用 / 旧调用点）。
  full,

  /// 只出标签 chip；无标签时零高度。
  tags,

  /// 只出「管理标签（常驻）+ 批量选择 + 排序」（放进库页工具行行尾）。
  actions,

  /// 只出「排序（与筛选）」菜单的常驻锚点（库页单行页头，2026-10-14）：
  /// 排序按钮挪进页头动作后可能被收进「⋯」，菜单不能挂在按钮上——锚点经
  /// [FushiPageHeader.menuAnchor] 铺满页头动作组（动作被外壳浮动工具栏代放时
  /// 随那枚胶囊走），按钮（或 ⋯ 菜单里的那一项）经
  /// [FushiTagFilterBar.sortMenuController] 打开它，菜单从触发控件下沿弹出
  /// （BUG-4715）。按钮由
  /// [libraryHeaderTagActions] 生成。
  sortMenuAnchor,

  /// Apple iOS 档（方案 A 第 8 项）：库页工具行下面一行——「筛选」pull-down
  /// 后面跟一排可横滑的标签胶囊（按标签颜色、选中反白；长按任一枚或末尾
  /// 「管理标签…」进标签管理）。由 `LibraryToolbar.appleFilterRow` 挂；挂着
  /// 它时工具行行尾（[actions]）不再出「筛选」与「管理标签」齿轮。
  appleFilterRow,
}

/// 库页单行页头里的「批量选择 / 排序 / 管理标签 / 管理合集」动作（2026-10-14）。
///
/// 都是 [FushiIconButton]，由页头按 [FushiIconButton.overflowPriority] 放不下时
/// 逐颗收进「⋯」；激活中的批量选择（[selectionMode]）是选中态、恒外露。排序
/// 按钮只打开 [sortMenu]（菜单由 [FushiTagFilterBarPart.sortMenuAnchor] 的常驻
/// 锚点画），[sortFilterActive] 时亮圆点。[sortMenu] 为 null / 批量选择中不出
/// 排序。key 沿用旧工具行的 `library_tag_settings` / `library_sort_menu_button`。
List<FushiIconButton> libraryHeaderTagActions(
  BuildContext context, {
  required WidgetRef ref,
  FushiHeaderMenuController? sortMenu,
  bool sortGrouped = false,
  bool sortFilterActive = false,
  bool selectionMode = false,
  VoidCallback? onToggleSelectionMode,
  bool showTagManagement = true,
  VoidCallback? onTagsChanged,
  VoidCallback? onManageCollections,
  int selectionPriority = 30,
  int sortPriority = 20,
  int tagManagePriority = 10,
  int collectionManagePriority = 9,
  String? sortTooltipOverride,
  VoidCallback? onOpenViewSheet,
}) {
  final t = Translations.of(context);
  final String sortTooltip =
      sortTooltipOverride ?? (sortGrouped ? t.library_sort_filter : t.sort_by);
  final FushiHeaderMenuController? menu = sortMenu;
  return <FushiIconButton>[
    if (onToggleSelectionMode != null)
      FushiIconButton(
        key: const ValueKey<String>('library_select_toggle'),
        icon: selectionMode ? FushiIcons.close : FushiIcons.checklist,
        tooltip: selectionMode
            ? MaterialLocalizations.of(context).closeButtonTooltip
            : t.batch_select,
        selected: selectionMode,
        overflowPriority: selectionPriority,
        onTap: onToggleSelectionMode,
      ),
    if (menu != null && !selectionMode)
      FushiIconButton(
        key: const ValueKey<String>('library_sort_menu_button'),
        icon: sortGrouped ? FushiIcons.settings : FushiIcons.sort,
        tooltip: sortFilterActive
            ? '$sortTooltip · ${t.library_filter_active}'
            : sortTooltip,
        badge: sortFilterActive,
        overflowPriority: sortPriority,
        // 窄窗：「排序与显示」底部抽屉（[showLibraryViewSheet]）；宽窗：锚定菜单，
        // 从本按钮（被收进 ⋯ 时从 ⋯）下沿弹出。
        onTap: onOpenViewSheet ?? menu.toggle,
      ),
    if (showTagManagement)
      FushiIconButton(
        key: const ValueKey<String>('library_tag_settings'),
        icon: FushiIcons.settingsGear,
        tooltip: t.tag_manage,
        overflowPriority: tagManagePriority,
        onTap: () => openLibraryTagManagement(
          context,
          ref: ref,
          onTagsChanged: onTagsChanged,
        ),
      ),
    // 「管理合集」与「管理标签」对等（[CollectionManagementPage]），由库页传入
    // 本域的打开方式；null = 该页不提供。
    if (onManageCollections != null)
      FushiIconButton(
        key: const ValueKey<String>('library_collection_manage'),
        icon: FushiIcons.collection,
        tooltip: t.collection_manage_title,
        overflowPriority: collectionManagePriority,
        onTap: onManageCollections,
      ),
  ];
}

/// 打开标签管理页；返回后刷新标签池与调用方的标签映射（[onTagsChanged]）。
Future<void> openLibraryTagManagement(
  BuildContext context, {
  required WidgetRef ref,
  VoidCallback? onTagsChanged,
}) async {
  await Navigator.push(
    context,
    adaptivePageRoute(
      context: context,
      builder: (_) => const TagManagementPage(),
    ),
  );
  if (!context.mounted) return;
  ref.invalidate(allTagsProvider);
  onTagsChanged?.call();
}

/// 库页「排序」按钮右上角的筛选标记：[active] 时一枚主色小圆点弹簧放大出现，
/// 取消筛选时缩回消失（时长走 [fushiMotionDuration]，墨水屏 / 减弱动态效果下
/// 直接切换）。圆点不接命中，点击照常落到按钮上。
class LibraryFilterBadge extends StatelessWidget {
  const LibraryFilterBadge({
    required this.active,
    required this.child,
    super.key,
  });

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 墨水屏：primary 塌成前景色，圆点照样可见（实心黑点）。
    final Color dot = isEinkTheme(context) ? colors.onSurface : colors.primary;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        PositionedDirectional(
          top: 4,
          end: 4,
          child: IgnorePointer(
            child: AnimatedScale(
              key: const ValueKey<String>('library_filter_badge_dot'),
              scale: active ? 1 : 0,
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: active ? FushiMotion.release : FushiMotion.exit,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 1.5),
                ),
                child: const SizedBox.square(dimension: 9),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Apple iOS 档筛选行里的一枚标签胶囊（Finder / 照片标签式）：未选中 = 标签色
/// 15% 底 + 标签色圆点 + label 色字；选中反白 = 标签色实底 + 白字。只在 Apple
/// 外壳里出现（M3E 的标签 chip 是 [FushiTagChip]）。
class _AppleTagCapsule extends StatelessWidget {
  const _AppleTagCapsule({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.icon,
    this.onLongPress,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 标签颜色；null = 中性（「管理标签…」）。
  final Color? color;
  final IconData? icon;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final double height = FushiApplePopUpButtonFace.defaultHeightOf(context);
    final BorderRadius radius = BorderRadius.circular(height / 2);
    final Color? tint = color;
    final Color fill = tint == null
        ? apple.tertiaryFill
        : selected
        ? tint
        : tint.withValues(alpha: 0.16);
    final Color foreground = selected && tint != null
        ? Colors.white
        : apple.label;
    final double fontSize = fushiAppleCompact(context)
        ? 13 * fushiAppleMacScale(context)
        : 15;
    // 图标 / 色点与文字的间距取间距令牌（与标签胶囊之间的间隔同源）。
    final double iconGap = FushiDesignTokens.of(context).spacing.gap * 0.75;
    return FushiPressScale(
      child: FushiPlainButton(
        onPressed: onTap,
        onLongPress: onLongPress,
        borderRadius: radius,
        fill: fill,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: fushiMotionDuration(context, FushiMotion.short),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: fill, borderRadius: radius),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                FushiIcon(icon!, size: fontSize, color: apple.secondaryLabel),
                SizedBox(width: iconGap),
              ] else if (tint != null && !selected) ...<Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tint,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 8),
                ),
                SizedBox(width: iconGap),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: appleTextStyle(
                    context,
                    size: fontSize,
                    weight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
