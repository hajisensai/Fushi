import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/utils.dart';

/// 统一合集 UI v2 Phase C：合集独占一行（Jellyfin/Netflix 行式布局）。
///
/// 头部 = 合集名 + 数量 + 「查看全部」chevron（点击进详情页；携带 [headerFocusId]
/// 成为手柄/键盘焦点目标——书架标签栏「整理」的 down-anchor 依赖该 id）。
/// 主体 = 固定高横向 [ListView.builder]：成员卡由调用方 [itemBuilder] 渲染
/// （视频页复用 `_buildCard`、书架复用书卡/SRT 卡），每张卡套 [itemWidth] 定宽，
/// 左右横移可见相邻集；[initialIndex] 把「继续看」成员滚进初始视野。
///
/// 焦点：行内成员卡各自注册焦点 id，方向键/手柄左右移动由全局几何焦点系统处理
/// （被遮挡的卡在获焦时经 `Scrollable.ensureVisible` 自动横滚入视野——与纵向
/// 网格同级别的既有支持，无自造 traversal）。
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

  @override
  State<CollectionShelfRow> createState() => _CollectionShelfRowState();
}

class _CollectionShelfRowState extends State<CollectionShelfRow> {
  late final ScrollController _controller;

  /// 卡间距（与网格 12 间距一致；offset 计算与 separator 必须同源）。
  static const double _itemGap = 12;

  @override
  void initState() {
    super.initState();
    final int idx = widget.initialIndex.clamp(0, widget.itemCount - 1);
    _controller = ScrollController(
      initialScrollOffset: idx <= 0 ? 0 : idx * (widget.itemWidth + _itemGap),
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
        SizedBox(
          height: widget.rowHeight,
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.itemCount,
            separatorBuilder: (BuildContext _, int __) =>
                const SizedBox(width: _itemGap),
            itemBuilder: (BuildContext context, int i) => SizedBox(
              width: widget.itemWidth,
              child: widget.itemBuilder(context, i),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, HibikiDesignTokens tokens) {
    final Widget header = InkWell(
      canRequestFocus: false,
      borderRadius: tokens.radii.controlRadius,
      onTap: widget.onOpenDetail,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap / 2,
          vertical: tokens.spacing.gap / 2,
        ),
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
            const Spacer(),
            Text(t.collection_view_all, style: tokens.type.metadata),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: tokens.surfaces.onVariant,
            ),
          ],
        ),
      ),
    );
    final HibikiFocusId? focusId = widget.headerFocusId;
    if (focusId != null && HibikiFocusRoot.maybeControllerOf(context) != null) {
      return Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onOpenDetail();
              return null;
            },
          ),
        },
        child: HibikiFocusTarget(id: focusId, child: header),
      );
    }
    return header;
  }
}
