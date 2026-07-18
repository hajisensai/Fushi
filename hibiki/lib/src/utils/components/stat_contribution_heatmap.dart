import 'package:flutter/material.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';

/// GitHub 式「贡献热力图」的一天格子：日期键 + 当日活动值 + 强度等级。
///
/// [dateKey] 为 null 表示占位格（当前周里今天之后的未来日，不落在窗口内），渲染成
/// 透明/无色，仅用于把最后一列补齐 7 行。真实日 [dateKey] 形如 `2026-06-07`，与
/// DB 统计行同格式（[statDateKey]）。
class StatHeatmapCell {
  const StatHeatmapCell({
    required this.dateKey,
    required this.value,
    required this.level,
  });

  final String? dateKey;
  final int value;

  /// 强度等级 0..4（0 = 无活动；4 = 最活跃）。用于映射到颜色深浅。
  final int level;
}

/// 贡献热力图模型：按「周」分列（[weeks]，每列自上而下 周一..周日 共 7 天），
/// 末列含今天。纯数据，供 [StatContributionHeatmap] 渲染、可单测。
class StatHeatmapModel {
  const StatHeatmapModel({required this.weeks, required this.maxValue});

  /// 列表，每列 7 个 [StatHeatmapCell]（周一在上、周日在下）。
  final List<List<StatHeatmapCell>> weeks;

  /// 窗口内单日最大活动值（0 表示全窗口无活动）。用于等级分桶的分母。
  final int maxValue;
}

/// 纯函数：把「日期键→活动值」映射构造成最近 [weeks] 周的贡献热力图模型。
///
/// - 以 [now] 所在周的周一为末列起点，向前取 [weeks] 列（每列周一..周日）。
/// - 每天的值取自 [valueByDateKey]（缺省 0）。
/// - 今天之后的未来日（末列里 > 今天的格子）为占位格（dateKey=null，level=0）。
/// - 等级：value==0→0；否则按占 [StatHeatmapModel.maxValue] 的比例分 1..4 四档
///   （>0 至少 1 档，满值 4 档），空窗口（maxValue==0）全为 0。
StatHeatmapModel buildStatHeatmap({
  required Map<String, int> valueByDateKey,
  required DateTime now,
  int weeks = 17,
}) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  // 本周周一（DateTime.weekday: 周一=1..周日=7）。
  final DateTime thisMonday =
      today.subtract(Duration(days: today.weekday - DateTime.monday));
  final DateTime firstMonday =
      thisMonday.subtract(Duration(days: (weeks - 1) * 7));

  int maxValue = 0;
  final List<List<({String? dateKey, int value, DateTime day})>> raw =
      <List<({String? dateKey, int value, DateTime day})>>[];
  for (int w = 0; w < weeks; w++) {
    final List<({String? dateKey, int value, DateTime day})> col =
        <({String? dateKey, int value, DateTime day})>[];
    for (int d = 0; d < 7; d++) {
      final DateTime day = firstMonday.add(Duration(days: w * 7 + d));
      if (day.isAfter(today)) {
        col.add((dateKey: null, value: 0, day: day));
        continue;
      }
      final String key = statDateKey(day);
      final int value = valueByDateKey[key] ?? 0;
      if (value > maxValue) maxValue = value;
      col.add((dateKey: key, value: value, day: day));
    }
    raw.add(col);
  }

  int levelOf(int value) {
    if (value <= 0 || maxValue <= 0) return 0;
    // 比例分桶：(0,0.25]→1, (0.25,0.5]→2, (0.5,0.75]→3, (0.75,1]→4。
    final double frac = value / maxValue;
    if (frac > 0.75) return 4;
    if (frac > 0.5) return 3;
    if (frac > 0.25) return 2;
    return 1;
  }

  final List<List<StatHeatmapCell>> cols = <List<StatHeatmapCell>>[
    for (final List<({String? dateKey, int value, DateTime day})> col in raw)
      <StatHeatmapCell>[
        for (final ({String? dateKey, int value, DateTime day}) c in col)
          StatHeatmapCell(
            dateKey: c.dateKey,
            value: c.value,
            level: c.dateKey == null ? 0 : levelOf(c.value),
          ),
      ],
  ];
  return StatHeatmapModel(weeks: cols, maxValue: maxValue);
}

/// GitHub 式贡献热力图组件：自适应可用宽度铺 [StatHeatmapModel.weeks] 列小方格，
/// 颜色由 [baseColor] 按等级 0..4 加深。整块可 [onTap]（打开完整统计页）。
///
/// 用 [CustomPaint]（含 [RepaintBoundary]）一次绘制所有格子，避免上百个 widget 参与
/// 布局/重绘（与阅读设置抽屉色卡缺 RepaintBoundary 卡顿同类考量）。
class StatContributionHeatmap extends StatelessWidget {
  const StatContributionHeatmap({
    required this.model,
    required this.baseColor,
    required this.emptyColor,
    super.key,
    this.onTap,
    this.cell = 12,
    this.spacing = 3,
  });

  final StatHeatmapModel model;
  final Color baseColor;

  /// level 0（无活动）格子的底色（通常取一个很浅的中性色）。
  final Color emptyColor;
  final VoidCallback? onTap;

  /// 单格边长（逻辑像素，自然尺寸）。实际渲染由外层 [FittedBox] 按可用宽度等比
  /// 缩小（不放大），故这是「上限」尺寸。
  final double cell;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final int cols = model.weeks.length;
    if (cols == 0) return const SizedBox.shrink();
    // 固定自然尺寸（不依赖 LayoutBuilder——本组件会被放进 IntrinsicHeight 的概览条
    // 里，而 LayoutBuilder 不支持 intrinsic 测量会抛异常）。宽度不足时由 FittedBox
    // 等比缩小，宽屏保持自然尺寸左对齐。
    final double natW = cols * cell + (cols - 1) * spacing;
    final double natH = 7 * cell + 6 * spacing;
    Widget content = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: natW,
        height: natH,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _HeatmapPainter(
              model: model,
              baseColor: baseColor,
              emptyColor: emptyColor,
              cell: cell,
              spacing: spacing,
            ),
          ),
        ),
      ),
    );
    if (onTap != null) {
      content = InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: content,
      );
    }
    return content;
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.model,
    required this.baseColor,
    required this.emptyColor,
    required this.cell,
    required this.spacing,
  });

  final StatHeatmapModel model;
  final Color baseColor;
  final Color emptyColor;
  final double cell;
  final double spacing;

  /// 等级 0..4 → 颜色。0 用 [emptyColor]；1..4 用 [baseColor] 按不透明度加深。
  Color _colorFor(int level) {
    switch (level) {
      case 0:
        return emptyColor;
      case 1:
        return baseColor.withValues(alpha: 0.35);
      case 2:
        return baseColor.withValues(alpha: 0.55);
      case 3:
        return baseColor.withValues(alpha: 0.78);
      default:
        return baseColor;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..style = PaintingStyle.fill;
    final Radius radius = Radius.circular(cell * 0.25);
    for (int w = 0; w < model.weeks.length; w++) {
      final List<StatHeatmapCell> col = model.weeks[w];
      final double x = w * (cell + spacing);
      for (int d = 0; d < col.length; d++) {
        final StatHeatmapCell c = col[d];
        // 占位格（未来日）不绘制，留白。
        if (c.dateKey == null) continue;
        final double y = d * (cell + spacing);
        paint.color = _colorFor(c.level);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, cell, cell),
            radius,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.model != model ||
      old.baseColor != baseColor ||
      old.emptyColor != emptyColor ||
      old.cell != cell ||
      old.spacing != spacing;
}
