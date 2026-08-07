import 'package:flutter/material.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/focus/hibiki_focus_target.dart';
import 'package:fushi/src/media/collections/collection_drag.dart';
import 'package:fushi/utils.dart';

/// 统一合集 UI v2 Phase C：合集独占一行（Jellyfin/Netflix 行式布局）。
///
/// 头部 = 合集名 + 数量 + 「查看全部」chevron（点击进详情页；携带 [headerFocusId]
/// 成为手柄/键盘焦点目标——书架标签栏「整理」的 down-anchor 依赖该 id）。
/// 主体 = 固定高横向 [ListView.builder]：成员卡由调用方 [itemBuilder] 渲染
/// （视频页复用 `_buildCard`、书架复用书卡/SRT 卡），每张卡套 [itemWidth] 定宽，
/// 左右横移可见相邻集；[initialIndex] 把「继续看」成员滚进初始视野。
///
/// 焦点：行内成员卡各自注册焦点 id，方向键/手柄左右移动由全局几何焦点系统处理
/// （被遮挡的卡在获焦时经 `HibikiFocusScroll.ensureVisible` 自动横滚入视野——
/// 与纵向网格同级别的既有支持，无自造 traversal）。
class CollectionShelfRow extends StatefulWidget {
  const CollectionShelfRow({
    required this.title,
    required this.countLabel,
    required this.itemCount,
    required this.itemWidth,
    required this.rowHeight,
    required this.itemBuilder,
    required this.onOpenDetail,
    this.headerFocusId,
    this.initialIndex = 0,
    this.itemGap = 12,
    this.collapsed = false,
    this.onToggleCollapsed,
    this.selectionCheckbox,
    this.onToggleSelected,
    this.onTagDropped,
    this.onMediaDropped,
    this.tags,
    this.onContextMenu,
    super.key,
  });

  /// 合集名（行头主文本）。
  final String title;

  /// 数量文本（如「12 集」/「5 项」，调用方用现有 i18n key 格式化）。
  final String countLabel;

  final int itemCount;

  /// 每张成员卡的固定宽（视频页对齐网格 cell 宽；书架对齐网格列宽断点）。
  final double itemWidth;

  /// 行主体高（= 成员卡完整高，含标题 footer）。
  final double rowHeight;

  /// 渲染第 i 个成员卡（交互/焦点/选择态由调用方的卡自带）。
  final IndexedWidgetBuilder itemBuilder;

  /// 行头点击 → 合集详情页。
  final VoidCallback onOpenDetail;

  /// 行头的手柄/键盘焦点 id（书架侧沿用 `reader-shelf-collection-<id>` 保持
  /// 既有方向锚点语义）。null 或无焦点根时行头保持纯点击。
  final HibikiFocusId? headerFocusId;

  /// 初始横滚定位到的成员下标（视频行 = 继续看成员；书架行 v1 恒 0）。
  final int initialIndex;

  /// 卡间距。视频卡（无自带内边距）默认 12 对齐网格间距；书卡自带 12px 内边距
  /// 时传 0，使行内视觉间距与散书网格一致。
  final double itemGap;

  /// 折叠态：true 时不建横向成员列表，行只剩行头（行头照常可点进详情）。
  final bool collapsed;

  /// 行头折叠开关（行头标题左侧旋转 chevron）。null 时不显示开关（行恒展开）。
  /// 调用方负责持久化（`collapsed_collection_ids` 偏好，书架/视频页共用）。
  final VoidCallback? onToggleCollapsed;

  /// 多选态：行头前缀勾选框（选=选中整个合集）。非 null 时替代折叠 chevron 显示在
  /// 行头最左，并隐藏「查看全部」尾随件（多选态下行头点击走 [onToggleSelected] 整选，
  /// 不再导航进详情）。null（默认）= 非多选态，行头维持点击进详情，零破坏。
  final Widget? selectionCheckbox;

  /// 多选态：切换整合集选中（选/取消）。非 null 时行头点击/焦点激活走它，替代
  /// [onOpenDetail]。null（默认）时行头点击维持进详情。
  final VoidCallback? onToggleSelected;

  /// 把标签拖到**行头**上 = 给整个合集打标签（与书/视频卡的 [BookDragTarget] 拖放
  /// 手势一致；成员卡区各成员卡自带书级 drop target，与行头区不重叠）。null（默认）时
  /// 行头不接收拖放。合集详情页 AppBar 的打标签按钮是另一条等价入口。
  final void Function(BookTagRow tag)? onTagDropped;

  /// 把**媒体卡**拖到行头 = 把该条目加入本合集（与 [onTagDropped] 的标签拖放并存，
  /// 靠 payload 泛型分流：`MediaRef` 走这里、`BookTagRow` 走 [onTagDropped]，
  /// 两个 DragTarget 互不误接）。null（默认）时行头不接收卡片拖放。
  final void Function(MediaRef ref)? onMediaDropped;

  /// 该合集已打的标签（行头下方展示 chip 列，与书/视频卡的标签列同形）。null/空时
  /// 不占位。调用方 `ref.watch(collectionTagMapProvider)` 后传该合集的列表；打标签
  /// 后失效该 provider 即刷新。
  final List<BookTagRow>? tags;

  /// 行头长按 / 桌面右键 → 合集上下文菜单（统一三库页合集菜单：打开/重命名/
  /// 标签/删除，见 `showCollectionContextDialog`）。多选态（[selectionCheckbox]
  /// 非 null）自动压制——与单卡多选态禁长按菜单同一纪律。null = 行头无菜单。
  final VoidCallback? onContextMenu;

  @override
  State<CollectionShelfRow> createState() => _CollectionShelfRowState();
}

class _CollectionShelfRowState extends State<CollectionShelfRow> {
  late final ScrollController _controller;

  /// 行头正被标签拖放悬停（画高亮边框反馈）。仅 [CollectionShelfRow.onTagDropped]
  /// 非 null 时有意义。
  bool _tagHovering = false;

  @override
  void initState() {
    super.initState();
    final int idx = widget.initialIndex.clamp(0, widget.itemCount - 1);
    // offset 计算与 separator 必须同源（widget.itemGap）。
    _controller = ScrollController(
      initialScrollOffset:
          idx <= 0 ? 0 : idx * (widget.itemWidth + widget.itemGap),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildHeader(context, tokens),
        // 行头下方展示该合集已打的标签 chip（折叠态也显示——折叠时仍看得到有哪些
        // 标签）。与书/视频卡的标签列同形；空则不占位。
        _buildTagChips(context, tokens),
        // 折叠态不建成员列表（行只剩行头）；展开时照常。控制器跨折叠切换存活
        //（ListView 重建时重新 attach，无 clients 期间安全）。
        if (!widget.collapsed)
          SizedBox(
            height: widget.rowHeight,
            // 桌面默认 MaterialScrollBehavior 的 dragDevices 不含鼠标——横排行用
            // 鼠标左右拖会毫无反应（用户实报）。共享件统一放开 mouse/trackpad/
            // stylus 拖动；触屏行为不变。
            child: HorizontalDragScrollable(
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                physics: desktopAwareScrollPhysics(),
                itemCount: widget.itemCount,
                separatorBuilder: (BuildContext _, int __) =>
                    SizedBox(width: widget.itemGap),
                itemBuilder: (BuildContext context, int i) => SizedBox(
                  width: widget.itemWidth,
                  child: widget.itemBuilder(context, i),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 合集已打标签的 chip 列（行头下方）。与合集详情页 `_buildTagChips` 视觉一致
  /// （[HibikiTagChip] + Wrap）；[CollectionShelfRow.tags] 空则不占位。
  Widget _buildTagChips(BuildContext context, HibikiDesignTokens tokens) {
    final List<BookTagRow>? tags = widget.tags;
    if (tags == null || tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap / 2,
        0,
        tokens.spacing.gap / 2,
        tokens.spacing.gap / 2,
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final BookTagRow tag in tags)
            HibikiTagChip(
              label: tag.name,
              color: Color(tag.colorValue),
              tone: HibikiTagChipTone.surface,
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, HibikiDesignTokens tokens) {
    // 多选态：行头点击整选合集（onToggleSelected），替代进详情（onOpenDetail）。
    final Widget? selectionCheckbox = widget.selectionCheckbox;
    final bool selectionMode = selectionCheckbox != null;
    final VoidCallback headerTap =
        widget.onToggleSelected ?? widget.onOpenDetail;
    // 行头长按/右键 = 合集上下文菜单（多选态压制，行头点击专注整选）。
    final VoidCallback? contextMenu =
        selectionMode ? null : widget.onContextMenu;
    final Widget header = InkWell(
      canRequestFocus: false,
      borderRadius: tokens.radii.controlRadius,
      onTap: headerTap,
      onLongPress: contextMenu,
      onSecondaryTap: contextMenu,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap / 2,
          vertical: tokens.spacing.gap / 2,
        ),
        child: Row(
          children: <Widget>[
            // 多选态：行头最左挂整选勾选框（选=选中整个合集），替代折叠 chevron。
            if (selectionCheckbox != null)
              Padding(
                padding: EdgeInsets.only(right: tokens.spacing.gap / 2),
                child: selectionCheckbox,
              )
            // 折叠开关：标题左侧旋转 chevron（展开朝下、折叠朝右）。紧凑尺寸不
            // 抬高行头；ExcludeFocus——手柄/键盘焦点仍落整行头（Enter=进详情），
            // 折叠是鼠标/触屏轻交互，不进焦点遍历序。
            else if (widget.onToggleCollapsed != null)
              ExcludeFocus(
                child: IconButton(
                  onPressed: widget.onToggleCollapsed,
                  tooltip: widget.collapsed
                      ? t.collection_expand
                      : t.collection_collapse,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 32, height: 32),
                  icon: AnimatedRotation(
                    turns: widget.collapsed ? -0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 20,
                      color: tokens.surfaces.onVariant,
                    ),
                  ),
                ),
              ),
            // Expanded（tight）吃满剩余宽，尾随「查看全部+chevron」才真正贴最右
            //（旧写法 Flexible(loose)+Spacer 按 flex 份额均分，标题短时尾随件
            // 停在行中间——用户实报）。
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.listTitle.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  Text(widget.countLabel, style: tokens.type.metadata),
                ],
              ),
            ),
            // 多选态隐藏「查看全部」尾随件（行头点击整选而非导航）。
            if (!selectionMode) ...<Widget>[
              Text(t.collection_view_all, style: tokens.type.metadata),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: tokens.surfaces.onVariant,
              ),
            ],
          ],
        ),
      ),
    );
    final HibikiFocusId? focusId = widget.headerFocusId;
    Widget result = header;
    if (focusId != null && HibikiFocusRoot.maybeControllerOf(context) != null) {
      result = Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              headerTap();
              return null;
            },
          ),
        },
        child: HibikiFocusTarget(id: focusId, child: header),
      );
    }
    // 把标签拖到行头 = 给整个合集打标签。DragTarget 包在最外层（含焦点包裹），
    // 整个行头区域都是 drop 区；仅拖拽时接收 [BookTagRow]，普通点击/焦点不受影响。
    final void Function(BookTagRow tag)? onTagDropped = widget.onTagDropped;
    if (onTagDropped != null) {
      result = _wrapTagDropTarget(context, tokens, result, onTagDropped);
    }
    // 把媒体卡拖到行头 = 加入本合集。与上面的标签 DragTarget 嵌套并存，靠 payload
    // 泛型分流（`MediaRef` vs `BookTagRow`），无运行时判别分支。
    final void Function(MediaRef ref)? onMediaDropped = widget.onMediaDropped;
    if (onMediaDropped != null) {
      result = CollectionDropTarget(
        onMediaDropped: onMediaDropped,
        alignment: AlignmentDirectional.centerEnd,
        borderRadius: tokens.radii.controlRadius,
        child: result,
      );
    }
    return result;
  }

  /// 用 [DragTarget] 包住行头 [child]：拖入标签时画高亮边框反馈，落下时回调
  /// [onTagDropped]（给整个合集打标签）。与 `BookDragTarget` 的书级拖放视觉同源，
  /// 但适配行头形状（末端小图标而非居中大图标）。
  Widget _wrapTagDropTarget(
    BuildContext context,
    HibikiDesignTokens tokens,
    Widget child,
    void Function(BookTagRow tag) onTagDropped,
  ) {
    final Color hoverColor = tokens.surfaces.primary;
    // eink：半透明高亮罩在墨水屏合成抖动灰，且 primary 已塌缩——去掉填充色，
    // 只留实心描边 + 图标作拖放悬停反馈。
    final bool eink = isEinkTheme(context);
    return DragTarget<BookTagRow>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (DragTargetDetails<BookTagRow> details) {
        setState(() => _tagHovering = false);
        onTagDropped(details.data);
      },
      onMove: (_) {
        if (!_tagHovering) setState(() => _tagHovering = true);
      },
      onLeave: (_) {
        if (_tagHovering) setState(() => _tagHovering = false);
      },
      builder: (
        BuildContext context,
        List<BookTagRow?> candidateData,
        List<dynamic> rejectedData,
      ) {
        return Stack(
          children: <Widget>[
            child,
            if (_tagHovering)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: eink ? null : hoverColor.withValues(alpha: 0.18),
                      borderRadius: tokens.radii.controlRadius,
                      border: Border.all(
                        color: hoverColor,
                        width: tokens.spacing.gap / 4,
                      ),
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: tokens.spacing.gap,
                        ),
                        child: Icon(
                          Icons.new_label_outlined,
                          color: hoverColor,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 统一「散卡网格」与「合集横排行」的卡片尺寸（用户实报：合集卡比散卡大一截）。
/// 以 [targetWidth]（合集卡目标宽）为基准算响应式列数（floor→卡只会比目标更宽不
/// 会更窄），返回列数 + 两处共用的**实际卡宽**：网格 FixedCrossAxisCount 的 cell
/// 宽与行内 SizedBox 宽取同一值，散卡与合集成员卡逐像素同尺寸。
({int columns, double cardWidth}) unifiedShelfCardLayout({
  required double availableWidth,
  required double targetWidth,
  double spacing = 12,
}) {
  if (availableWidth <= 0 || targetWidth <= 0) {
    return (columns: 1, cardWidth: targetWidth > 0 ? targetWidth : 1);
  }
  final int columns = ((availableWidth + spacing) / (targetWidth + spacing))
      .floor()
      .clamp(1, 1 << 10);
  final double cardWidth = (availableWidth - (columns - 1) * spacing) / columns;
  return (columns: columns, cardWidth: cardWidth);
}
