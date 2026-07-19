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

/// 纯函数：把「日期键→活动值」映射构造成一段 [weeks] 周的贡献热力图模型。
///
/// - [weekOffset]（单位=周，≥0）把窗口整体向前平移看历史：0 = 末列为本周（含今天）；
///   正值 = 末列往前推 [weekOffset] 周，此时窗口全在过去，无未来占位格。
/// - 以（本周周一 − [weekOffset] 周）为末列起点，向前取 [weeks] 列（每列周一..周日）。
/// - 每天的值取自 [valueByDateKey]（缺省 0）。
/// - 今天之后的未来日（仅 [weekOffset]==0 的末列里 > 今天的格子）为占位格
///   （dateKey=null，level=0）。
/// - 等级：value==0→0；否则按占 [StatHeatmapModel.maxValue] 的比例分 1..4 四档
///   （>0 至少 1 档，满值 4 档），空窗口（maxValue==0）全为 0。
StatHeatmapModel buildStatHeatmap({
  required Map<String, int> valueByDateKey,
  required DateTime now,
  int weeks = 17,
  int weekOffset = 0,
}) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  // 本周周一（DateTime.weekday: 周一=1..周日=7）。
  final DateTime thisMonday =
      today.subtract(Duration(days: today.weekday - DateTime.monday));
  // 窗口末列的周一：翻页时整体向前平移 weekOffset 周。
  final DateTime anchorMonday =
      thisMonday.subtract(Duration(days: weekOffset * 7));
  final DateTime firstMonday =
      anchorMonday.subtract(Duration(days: (weeks - 1) * 7));

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

/// 纯函数：以 [weeks] 周为翻页步长，能向前翻到的最深 [buildStatHeatmap] `weekOffset`
/// （单位=周，总是 [weeks] 的整数倍）。返回值 = 「含最早数据那一周」所在页的
/// weekOffset；无数据或数据都落在首屏（第 0 页）时返回 0（此时无需翻页箭头）。
int maxHeatmapPageOffset({
  required Map<String, int> valueByDateKey,
  required DateTime now,
  int weeks = 17,
}) {
  if (valueByDateKey.isEmpty || weeks <= 0) return 0;
  String? minKey;
  for (final String k in valueByDateKey.keys) {
    if (minKey == null || k.compareTo(minKey) < 0) minKey = k;
  }
  final DateTime? earliest = DateTime.tryParse(minKey!);
  if (earliest == null) return 0;
  final DateTime earliestDay =
      DateTime(earliest.year, earliest.month, earliest.day);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime thisMonday =
      today.subtract(Duration(days: today.weekday - DateTime.monday));
  final DateTime earliestMonday = earliestDay
      .subtract(Duration(days: earliestDay.weekday - DateTime.monday));
  if (!earliestMonday.isBefore(thisMonday)) return 0;
  // 用小时/168 四舍五入求周数，规避 DST 让 inDays 少算 1 天。
  final int weeksBack =
      (thisMonday.difference(earliestMonday).inHours + 84) ~/ 168;
  final int pages = weeksBack ~/ weeks;
  return pages * weeks;
}

/// 纯函数：把热力图局部坐标 [local]（自然坐标系，未经 [FittedBox] 缩放）反算成
/// 命中的 (列, 行)。落在格子间隙或越界时返回 null；行固定 0..6（周一..周日）。
({int col, int row})? hitStatHeatmapCell(
  Offset local, {
  required double cell,
  required double spacing,
  required int cols,
}) {
  if (local.dx < 0 || local.dy < 0) return null;
  final double step = cell + spacing;
  final int col = local.dx ~/ step;
  final int row = local.dy ~/ step;
  if (col < 0 || col >= cols || row < 0 || row >= 7) return null;
  // 落在格子内部而非右/下侧间隙。
  if (local.dx - col * step > cell) return null;
  if (local.dy - row * step > cell) return null;
  return (col: col, row: row);
}

/// GitHub 式贡献热力图组件：自适应可用宽度铺 [weeks] 列小方格，颜色由 [baseColor]
/// 按等级 0..4 加深。
///
/// 交互（无整块打开统计页的 onTap——打开统计移到外层可点标题）：
/// - **翻页**：数据超出首屏（[maxHeatmapPageOffset] > 0）时，顶部行右侧出现 ←/→
///   箭头，←=看更早一屏、→=回到更近一屏，到边界自动禁用。
/// - **每日数值**：点某天格子在顶部行左侧弹气泡显示当天日期+数值（[valueLabel]
///   由外层给格式化器：视频=观看时长 / 阅读=字数）；再点同格或点空白收起。
///
/// 用 [CustomPaint]（含 [RepaintBoundary]）一次绘制所有格子，避免上百个 widget 参与
/// 布局/重绘（与阅读设置抽屉色卡缺 RepaintBoundary 卡顿同类考量）。
class StatContributionHeatmap extends StatefulWidget {
  const StatContributionHeatmap({
    required this.valueByDateKey,
    required this.now,
    required this.baseColor,
    required this.emptyColor,
    required this.valueLabel,
    super.key,
    this.weeks = 17,
    this.cell = 12,
    this.spacing = 3,
  });

  /// 日期键（`2026-06-07`）→ 当日活动值（视频=观看毫秒 / 阅读=字数）的全量映射。
  final Map<String, int> valueByDateKey;

  /// 「现在」（构造窗口用；末屏末列含今天）。
  final DateTime now;
  final Color baseColor;

  /// level 0（无活动）格子的底色（通常取一个很浅的中性色）。
  final Color emptyColor;

  /// 选中某天时气泡文案的格式化器：入参为 (dateKey, 当日值)，返回完整气泡文本。
  final String Function(String dateKey, int value) valueLabel;

  /// 每屏列数（周数），也是翻页步长。
  final int weeks;

  /// 单格边长（逻辑像素，自然尺寸）。实际渲染由外层 [FittedBox] 按可用宽度等比
  /// 缩小（不放大），故这是「上限」尺寸。
  final double cell;
  final double spacing;

  @override
  State<StatContributionHeatmap> createState() =>
      _StatContributionHeatmapState();
}

class _StatContributionHeatmapState extends State<StatContributionHeatmap> {
  /// 当前翻页偏移（单位=周，0=最近一屏；每翻一页 ± [StatContributionHeatmap.weeks]）。
  int _pageOffset = 0;

  /// 当前选中格子的日期键（null=未选中，不显示气泡）。
  String? _selectedDateKey;

  static const double _headerHeight = 22;

  /// 翻页：[dir] > 0 看更早、< 0 回更近；步长 = weeks 周，clamp 到 [0, maxOffset]。
  /// 翻页后清除选中（原选中日已不在视野）。
  void _page(int dir, int maxOffset) {
    final int next =
        (_pageOffset + dir * widget.weeks).clamp(0, maxOffset).toInt();
    if (next == _pageOffset) return;
    setState(() {
      _pageOffset = next;
      _selectedDateKey = null;
    });
  }

  void _onTapGrid(Offset local, StatHeatmapModel model) {
    final ({int col, int row})? hit = hitStatHeatmapCell(
      local,
      cell: widget.cell,
      spacing: widget.spacing,
      cols: model.weeks.length,
    );
    String? next;
    if (hit != null) {
      // 占位格（未来日）dateKey 为 null → 视作点空白，收起气泡。
      next = model.weeks[hit.col][hit.row].dateKey;
    }
    setState(() {
      // 再点同一格 → 收起。
      _selectedDateKey = (next == _selectedDateKey) ? null : next;
    });
  }

  Widget _arrow(
    IconData icon,
    bool enabled,
    VoidCallback onTap,
    Color activeColor,
    Color disabledColor,
  ) {
    return SizedBox(
      width: 26,
      height: _headerHeight,
      child: InkResponse(
        radius: 16,
        onTap: enabled ? onTap : null,
        child: Icon(
          icon,
          size: 18,
          color: enabled ? activeColor : disabledColor,
        ),
      ),
    );
  }

  Widget _bubbleChip(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, int offset, int maxOffset) {
    final bool showArrows = maxOffset > 0;
    final String? sel = _selectedDateKey;
    final String? bubble = sel == null
        ? null
        : widget.valueLabel(sel, widget.valueByDateKey[sel] ?? 0);
    return SizedBox(
      height: _headerHeight,
      child: Row(
        children: <Widget>[
          Expanded(
            child: bubble == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: _bubbleChip(theme, bubble),
                  ),
          ),
          if (showArrows) ...<Widget>[
            _arrow(
              Icons.chevron_left,
              offset < maxOffset,
              () => _page(1, maxOffset),
              theme.colorScheme.onSurfaceVariant,
              theme.disabledColor,
            ),
            _arrow(
              Icons.chevron_right,
              offset > 0,
              () => _page(-1, maxOffset),
              theme.colorScheme.onSurfaceVariant,
              theme.disabledColor,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int maxOffset = maxHeatmapPageOffset(
      valueByDateKey: widget.valueByDateKey,
      now: widget.now,
      weeks: widget.weeks,
    );
    // 数据缩水（如切换来源/删除）后把越界的偏移收回合法范围。
    final int offset = _pageOffset.clamp(0, maxOffset).toInt();
    if (offset != _pageOffset) _pageOffset = offset;

    final StatHeatmapModel model = buildStatHeatmap(
      valueByDateKey: widget.valueByDateKey,
      now: widget.now,
      weeks: widget.weeks,
      weekOffset: offset,
    );
    final int cols = model.weeks.length;
    if (cols == 0) return const SizedBox.shrink();

    // 固定自然尺寸（不依赖 LayoutBuilder——本组件会被放进 IntrinsicHeight 的概览条
    // 里，而 LayoutBuilder 不支持 intrinsic 测量会抛异常）。宽度不足时由 FittedBox
    // 等比缩小，宽屏保持自然尺寸左对齐。
    final double natW = cols * widget.cell + (cols - 1) * widget.spacing;
    final double natH = 7 * widget.cell + 6 * widget.spacing;
    final Widget grid = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (TapUpDetails d) => _onTapGrid(d.localPosition, model),
      child: SizedBox(
        width: natW,
        height: natH,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _HeatmapPainter(
              model: model,
              baseColor: widget.baseColor,
              emptyColor: widget.emptyColor,
              cell: widget.cell,
              spacing: widget.spacing,
              selectedDateKey: _selectedDateKey,
              selectedBorderColor: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildHeader(theme, offset, maxOffset),
        SizedBox(height: widget.spacing * 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: grid,
        ),
      ],
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.model,
    required this.baseColor,
    required this.emptyColor,
    required this.cell,
    required this.spacing,
    required this.selectedDateKey,
    required this.selectedBorderColor,
  });

  final StatHeatmapModel model;
  final Color baseColor;
  final Color emptyColor;
  final double cell;
  final double spacing;
  final String? selectedDateKey;
  final Color selectedBorderColor;

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
    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = selectedBorderColor;
    final Radius radius = Radius.circular(cell * 0.25);
    Rect? selectedRect;
    for (int w = 0; w < model.weeks.length; w++) {
      final List<StatHeatmapCell> col = model.weeks[w];
      final double x = w * (cell + spacing);
      for (int d = 0; d < col.length; d++) {
        final StatHeatmapCell c = col[d];
        // 占位格（未来日）不绘制，留白。
        if (c.dateKey == null) continue;
        final double y = d * (cell + spacing);
        final Rect rect = Rect.fromLTWH(x, y, cell, cell);
        paint.color = _colorFor(c.level);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
        if (selectedDateKey != null && c.dateKey == selectedDateKey) {
          selectedRect = rect;
        }
      }
    }
    // 选中格描边画在最后，避免被相邻格覆盖。
    if (selectedRect != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(selectedRect.inflate(0.5), radius),
        border,
      );
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.model != model ||
      old.baseColor != baseColor ||
      old.emptyColor != emptyColor ||
      old.cell != cell ||
      old.spacing != spacing ||
      old.selectedDateKey != selectedDateKey ||
      old.selectedBorderColor != selectedBorderColor;
}
