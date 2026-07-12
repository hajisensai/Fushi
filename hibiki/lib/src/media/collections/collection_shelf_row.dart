import 'package:flutter/gestures.dart';
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

  @override
  State<CollectionShelfRow> createState() => _CollectionShelfRowState();
}

class _CollectionShelfRowState extends State<CollectionShelfRow> {
  late final ScrollController _controller;

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
        SizedBox(
          height: widget.rowHeight,
          // 桌面默认 MaterialScrollBehavior 的 dragDevices 不含鼠标——横排行用
          // 鼠标左右拖会毫无反应（用户实报）。显式放开 mouse/trackpad/stylus
          // 拖动；触屏行为不变。
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.trackpad,
              },
            ),
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
