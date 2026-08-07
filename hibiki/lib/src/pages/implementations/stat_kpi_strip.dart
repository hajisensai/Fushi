import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// 顶部 KPI 概览的单项数据：图标 + 大数值 + 标签 + 可选环比。
class StatKpiItem {
  const StatKpiItem({
    required this.icon,
    required this.value,
    required this.label,
    this.delta,
    this.deltaUp = true,
  });

  final IconData icon;

  /// 大数值文本（如 `12.3万` / `123小时45分`）。
  final String value;
  final String label;

  /// 可选环比文本（如 `↑12%` / `↓8%`），为空时不渲染。数值下方以小号彩色文字展示，
  /// 让「涨还是跌」一眼可见（本周 vs 上周）。
  final String? delta;

  /// [delta] 表示上涨（true）还是下跌（false），决定颜色：涨=主色、跌=错误色。
  final bool deltaUp;
}

/// 顶部 KPI 概览条（TODO-1253）。
///
/// 根因修复：旧实现把 N 个 KPI 卡片无条件塞进单排 `Row`（每个 `Expanded`），
/// 在手机窄屏下每张卡内宽只剩 ~40px，`12.3万` / `123小时45分` 这类多字数值被
/// `TextOverflow.ellipsis` 截成一个字符 + 省略号——用户「看不到对应的数字」。
/// 桌面端有 1040px 限宽，每卡 ~250px 才没暴露。
///
/// 这里按可用宽度自适应列数：宽屏一排铺开，窄屏回落成每排 2 列（或极窄 1 列），
/// 使每张卡都有足够内宽把数字完整显示。列宽在每一排内经 `Expanded` 均分，视觉与
/// 旧版一致，只是换行。
class StatKpiStrip extends StatelessWidget {
  const StatKpiStrip({
    required this.items,
    super.key,
    this.minTileWidth = 150,
  });

  final List<StatKpiItem> items;

  /// 单张 KPI 卡片保证数字可读的最小宽度。可用宽度不足以放下 `columns` 张这么宽的
  /// 卡片时自动减列（换行）。
  final double minTileWidth;

  /// 给定可用宽度算列数：尽量多列，但每列不得窄于 [minTileWidth]，且不超过卡片数。
  int _columnsFor(double maxWidth) {
    if (items.isEmpty) return 1;
    final int fit = (maxWidth / minTileWidth).floor();
    return fit.clamp(1, items.length);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = _columnsFor(constraints.maxWidth);
        final List<Widget> rows = <Widget>[];
        for (int start = 0; start < items.length; start += columns) {
          final int end =
              (start + columns) < items.length ? start + columns : items.length;
          final List<Widget> cells = <Widget>[];
          for (int i = start; i < end; i++) {
            if (i > start) cells.add(SizedBox(width: gap));
            cells.add(Expanded(child: _tile(context, items[i])));
          }
          // 末排不足 columns 时补占位保持列宽对齐（不画卡片）。
          for (int pad = end - start; pad < columns; pad++) {
            cells.add(SizedBox(width: gap));
            cells.add(const Expanded(child: SizedBox.shrink()));
          }
          if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
          rows.add(IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: cells,
            ),
          ));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }

  Widget _tile(BuildContext context, StatKpiItem item) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(item.icon, size: 18, color: scheme.primary),
          SizedBox(height: tokens.spacing.gap),
          // 数值优先完整显示：宽度不够时 scaleDown 缩小字号，而不是 ellipsis 截没
          // （TODO-1253 手机窄屏「看不到数字」的兜底；正常宽度不缩放）。
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              item.value,
              maxLines: 1,
              softWrap: false,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          if (item.delta != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap / 2),
            // 环比小字：涨=主色、跌=错误色，箭头已含在文本里（↑/↓）。数值可能很短，
            // 用 FittedBox scaleDown 兜底避免窄屏截断。
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                item.delta!,
                maxLines: 1,
                softWrap: false,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: item.deltaUp ? scheme.primary : scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
