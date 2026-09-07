import 'package:flutter/material.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi_core/fushi_core.dart';

/// 每屏**最少**列数（周数）。见 [StatContributionHeatmap.weeks]。
const int kStatHeatmapMinWeeks = 17;

/// 每屏**最多**列数（周数）= GitHub 式「一年」。见 [StatContributionHeatmap.maxWeeks]。
const int kStatHeatmapMaxWeeks = 53;

/// 单格自然边长（逻辑像素）。见 [StatContributionHeatmap.cell]。
const double kStatHeatmapCell = 12;

/// 单格放大上限（逻辑像素）。见 [StatContributionHeatmap.maxCell]。
const double kStatHeatmapMaxCell = 18;

/// 格间距（逻辑像素）。见 [StatContributionHeatmap.spacing]。
const double kStatHeatmapSpacing = 3;

/// 网格「铺到头」的自然最大宽度（逻辑像素；默认配置下 = 53×18 + 52×3 = 1110）。
///
/// 组件有**两道**天然封顶，宿主再宽也只会在网格右侧空出来：
/// - 列数封顶 [kStatHeatmapMaxWeeks]（一年）——再加列就是大片空周，正是 BUG-1073
///   病灶 1「左边一大片死黑」；
/// - 列数封顶后富余宽度分摊给格子边长，但格子封顶 [kStatHeatmapMaxCell]——再放大
///   就不是热力图而是一排大方块。
///
/// 所以**宿主容器要按本值限宽**，不能让卡片跟着窗口拉满：首页整页 1600 限宽撤掉后，
/// 3840 逻辑宽下热力图卡宽 2244 而网格仍只有 1110，右侧空出 1134px——BUG-1073
/// 症状 3（区块宽度用不满）在超宽屏复发。消费者调本函数，不要各自抄常量。
double statHeatmapMaxGridWidth({
  int maxWeeks = kStatHeatmapMaxWeeks,
  double maxCell = kStatHeatmapMaxCell,
  double spacing = kStatHeatmapSpacing,
}) =>
    maxWeeks * maxCell + (maxWeeks - 1) * spacing;

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

  @override
  bool operator ==(Object other) =>
      other is StatHeatmapCell &&
      other.dateKey == dateKey &&
      other.value == value &&
      other.level == level;

  @override
  int get hashCode => Object.hash(dateKey, value, level);
}

/// 贡献热力图模型：按「周」分列（[weeks]，每列自上而下 周一..周日 共 7 天），
/// 末列含今天。纯数据，供 [StatContributionHeatmap] 渲染、可单测。
class StatHeatmapModel {
  const StatHeatmapModel({required this.weeks, required this.maxValue});

  /// 列表，每列 7 个 [StatHeatmapCell]（周一在上、周日在下）。
  final List<List<StatHeatmapCell>> weeks;

  /// 窗口内单日最大活动值（0 表示全窗口无活动）。用于等级分桶的分母。
  final int maxValue;

  /// 值语义相等（BUG-1917）：[buildStatHeatmap] 每次 build 都造新对象——桌面拖边缩放
  /// 时 [StatContributionHeatmap] 的 LayoutBuilder 每步都重跑——若只比身份，
  /// `_HeatmapPainter.shouldRepaint` 永远为真，RepaintBoundary 的缓存层每步作废，
  /// 一年 364 格 × 2 个圆角矩形全部重画（实测占仪表盘每步 raster 9.7ms 的大头）。
  /// 内容没变就是相等，缓存层自然复用。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! StatHeatmapModel ||
        other.maxValue != maxValue ||
        other.weeks.length != weeks.length) {
      return false;
    }
    for (int w = 0; w < weeks.length; w++) {
      final List<StatHeatmapCell> a = weeks[w];
      final List<StatHeatmapCell> b = other.weeks[w];
      if (a.length != b.length) return false;
      for (int d = 0; d < a.length; d++) {
        if (a[d] != b[d]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        maxValue,
        weeks.length,
        weeks.isEmpty ? null : Object.hashAll(weeks.first),
        weeks.isEmpty ? null : Object.hashAll(weeks.last),
      );
}

/// 纯函数：把「日期键→活动值」映射构造成一段 [weeks] 周的贡献热力图模型。
///
/// - [weekOffset]（单位=周，≥0）把窗口整体向前平移看历史：0 = 末列为本周（含今天）；
///   正值 = 末列往前推 [weekOffset] 周，此时窗口全在过去，无未来占位格。
/// - 以（本周周一 − [weekOffset] 周）为末列起点，向前取 [weeks] 列（每列周一..周日）。
/// - 每天的值取自 [valueByDateKey]（缺省 0）。
/// - 今天之后的未来日（仅 [weekOffset]==0 的末列里 > 今天的格子）为占位格
///   （dateKey=null，level=0）。
/// - 等级：value==0→0；否则按窗口内**活跃日数值的秩**分 1..4 四档
///   （[statHeatmapRankLevel]：>0 至少 1 档，最大值 4 档），空窗口全为 0。
StatHeatmapModel buildStatHeatmap({
  required Map<String, int> valueByDateKey,
  required DateTime now,
  int weeks = kStatHeatmapMinWeeks,
  int weekOffset = 0,
}) {
  final DateTime today = statTodayDay(now);
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
      // 格子是日历日：key 走日历日格式化，不能过 statDateKey——它会按重置时刻前移，
      // 把 0 点合成的日历日当成前一日（重置 = 4 时整张图错位一天）。
      final String key = FushiDatabase.statCalendarDayKeyOf(day);
      final int value = valueByDateKey[key] ?? 0;
      if (value > maxValue) maxValue = value;
      col.add((dateKey: key, value: value, day: day));
    }
    raw.add(col);
  }

  // BUG-2223：档位按活跃日数值的秩（分位数），不按占最大值的比例——后者一天爆量
  // 就把其余所有活跃日压成最浅档，整张图只剩一个深格。
  final List<int> sortedActive = <int>[
    for (final List<({String? dateKey, int value, DateTime day})> col in raw)
      for (final ({String? dateKey, int value, DateTime day}) c in col)
        if (c.dateKey != null && c.value > 0) c.value,
  ]..sort();
  int levelOf(int value) => statHeatmapRankLevel(value, sortedActive);

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

/// 纯函数：热力图档位按**秩**分级（BUG-2223，对齐 Hoshi Android 的分位数着色）。
///
/// [sortedActive] 是窗口内活跃日（value > 0）的数值升序表；[value] ≤ 0 或表空 → 0。
/// 否则取 [value] 的上秩 r = 表中 ≤ value 的个数，level = ⌈r / n × levels⌉ ∈
/// [1, levels]（整数运算，无浮点边界）。单日爆量只占最高档一个名额，不再把其余活跃日
/// 压成最浅档；均匀分布时各档人数接近；同值同档。
int statHeatmapRankLevel(int value, List<int> sortedActive, {int levels = 4}) {
  if (value <= 0 || sortedActive.isEmpty || levels <= 0) return 0;
  int lo = 0;
  int hi = sortedActive.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (sortedActive[mid] <= value) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final int n = sortedActive.length;
  final int level = (lo * levels + n - 1) ~/ n;
  return level < 1 ? 1 : (level > levels ? levels : level);
}

/// 纯函数：以 [weeks] 周为翻页步长，能向前翻到的最深 [buildStatHeatmap] `weekOffset`
/// （单位=周，总是 [weeks] 的整数倍）。返回值 = 「含最早数据那一周」所在页的
/// weekOffset；无数据或数据都落在首屏（第 0 页）时返回 0（此时无需翻页箭头）。
int maxHeatmapPageOffset({
  required Map<String, int> valueByDateKey,
  required DateTime now,
  int weeks = kStatHeatmapMinWeeks,
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
  final DateTime today = statTodayDay(now);
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
    this.emptyBorderColor,
    this.onDaySelected,
    this.weeks = kStatHeatmapMinWeeks,
    this.maxWeeks = kStatHeatmapMaxWeeks,
    this.cell = kStatHeatmapCell,
    this.maxCell = kStatHeatmapMaxCell,
    this.spacing = kStatHeatmapSpacing,
  });

  /// 日期键（`2026-06-07`）→ 当日活动值（视频=观看毫秒 / 阅读=字数）的全量映射。
  final Map<String, int> valueByDateKey;

  /// 「现在」（构造窗口用；末屏末列含今天）。
  final DateTime now;
  final Color baseColor;

  /// level 0（无活动）格子的底色（通常取一个很浅的中性色）。
  final Color emptyColor;

  /// level 0 格子的可选描边。某些深色/自定义主题会把多个 surface 色阶压成近似色，
  /// 此时仅换一个 surface 填充色仍会让空格融进卡片背景；传入 outline role 后，即使
  /// 填充色与背景完全相同，网格轮廓仍然可见。null 保持旧的纯填充行为。
  final Color? emptyBorderColor;

  /// 选中某天时气泡文案的格式化器：入参为 (dateKey, 当日值)，返回完整气泡文本。
  final String Function(String dateKey, int value) valueLabel;

  /// 选中某个真实日（非占位格）时的可选回调：入参为 (dateKey, 当日值)。外层
  /// 据此弹当日明细（首页仪表盘）。再点同格收起、点空白/未来占位格、翻页清除
  /// 选中都**不**触发；null = 只保留气泡行为（其余消费者零变化）。
  final void Function(String dateKey, int value)? onDaySelected;

  /// 每屏**最少**列数（周数），也是窄屏下的翻页步长。宽屏下实际列数按可用宽度
  /// 自适应加宽（见 build 的 LayoutBuilder）——此前固定 17 周 + FittedBox 只缩
  /// 不放，桌面宽窗下卡片右侧大片空白（用户反馈「好空」）；多出来的宽度先用来
  /// 显示更长的历史（加列，到 [maxWeeks] 为止），再用来放大格子（到 [maxCell]）。
  final int weeks;

  /// 每屏**最多**列数（周数），默认 53 = GitHub 式「一年」。宽度自适应加列到此为止：
  /// 此前无上限，4K 全屏（卡内可用宽 ~1700）会铺出 110+ 列（两年多），而实际有数据
  /// 的只有最近几周，其余全是空格子——空格子底色又与卡底几乎同色，观感就是「左边
  /// 一大片死黑」（BUG-1073 病灶 1）。
  final int maxWeeks;

  /// 单格边长（逻辑像素，自然尺寸）。列数已达 [maxWeeks] 后仍有富余宽度时，格子会
  /// 等比放大到 [maxCell] 把宽度吃满（不再右侧留大片空白）；窄到连 [weeks] 列都放不
  /// 下时由外层 [FittedBox] 等比缩小。
  final double cell;

  /// 格子放大上限（逻辑像素）：防止超宽屏把一年的格子撑成大方块。
  final double maxCell;
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

  /// 翻页：[dir] > 0 看更早、< 0 回更近；步长 = 当前屏列数（周），clamp 到
  /// [0, maxOffset]。翻页后清除选中（原选中日已不在视野）。
  void _page(int dir, int maxOffset, int stepWeeks) {
    final int next =
        (_pageOffset + dir * stepWeeks).clamp(0, maxOffset).toInt();
    if (next == _pageOffset) return;
    setState(() {
      _pageOffset = next;
      _selectedDateKey = null;
    });
  }

  /// [cell] 是**本帧实际**格子边长（宽屏下会大于 [StatContributionHeatmap.cell]），
  /// 命中判定必须用它，否则点击位置与绘制错位。
  void _onTapGrid(Offset local, StatHeatmapModel model, double cell) {
    final ({int col, int row})? hit = hitStatHeatmapCell(
      local,
      cell: cell,
      spacing: widget.spacing,
      cols: model.weeks.length,
    );
    String? next;
    if (hit != null) {
      // 占位格（未来日）dateKey 为 null → 视作点空白，收起气泡。
      next = model.weeks[hit.col][hit.row].dateKey;
    }
    final String? prev = _selectedDateKey;
    setState(() {
      // 再点同一格 → 收起。
      _selectedDateKey = (next == prev) ? null : next;
    });
    // 只在「新选中一个真实日」时对外回调（收起/点空白不触发）。
    if (next != null && next != prev) {
      widget.onDaySelected?.call(next, widget.valueByDateKey[next] ?? 0);
    }
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

  Widget _buildHeader(
    ThemeData theme,
    int offset,
    int maxOffset,
    int stepWeeks,
  ) {
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
              () => _page(1, maxOffset, stepWeeks),
              theme.colorScheme.onSurfaceVariant,
              theme.disabledColor,
            ),
            _arrow(
              Icons.chevron_right,
              offset > 0,
              () => _page(-1, maxOffset, stepWeeks),
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
    // 列数按可用宽度自适应（至少 widget.weeks）：宽屏把多出来的宽度用于显示更长
    // 的历史，消掉「固定 17 周 + 只缩不放」在桌面宽窗下的大片空白。旧注释担心的
    // IntrinsicHeight 宿主已不存在（当前唯一消费者是首页 dashboard 的 ListView
    // 区块卡）；若未来要塞回 intrinsic 容器，给上限宽度即可。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double unit = widget.cell + widget.spacing;
        final int fitWeeks = constraints.maxWidth.isFinite
            ? ((constraints.maxWidth + widget.spacing) / unit).floor()
            : widget.weeks;
        // 列数下限 = weeks（窄屏靠 FittedBox 缩），上限 = maxWeeks（配置反过来时
        // 以 weeks 为准，不出现空窗口）。
        final int hardMaxWeeks =
            widget.maxWeeks < widget.weeks ? widget.weeks : widget.maxWeeks;
        int effWeeks = fitWeeks < widget.weeks ? widget.weeks : fitWeeks;
        if (effWeeks > hardMaxWeeks) effWeeks = hardMaxWeeks;
        // 列数封顶后剩下的宽度分摊给格子边长（上限 maxCell），否则 4K 宽窗下右侧
        // 又是一大片空白。未封顶说明宽度刚好用完，保持自然尺寸。
        double effCell = widget.cell;
        if (constraints.maxWidth.isFinite && effWeeks == hardMaxWeeks) {
          final double grown =
              (constraints.maxWidth - (effWeeks - 1) * widget.spacing) /
                  effWeeks;
          if (grown > effCell) {
            effCell = grown > widget.maxCell ? widget.maxCell : grown;
          }
        }

        final int maxOffset = maxHeatmapPageOffset(
          valueByDateKey: widget.valueByDateKey,
          now: widget.now,
          weeks: effWeeks,
        );
        // 数据缩水（如切换来源/删除）后把越界的偏移收回合法范围。
        final int offset = _pageOffset.clamp(0, maxOffset).toInt();
        if (offset != _pageOffset) _pageOffset = offset;

        final StatHeatmapModel model = buildStatHeatmap(
          valueByDateKey: widget.valueByDateKey,
          now: widget.now,
          weeks: effWeeks,
          weekOffset: offset,
        );
        final int cols = model.weeks.length;
        if (cols == 0) return const SizedBox.shrink();

        final double natW = cols * effCell + (cols - 1) * widget.spacing;
        final double natH = 7 * effCell + 6 * widget.spacing;
        final Widget grid = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (TapUpDetails d) =>
              _onTapGrid(d.localPosition, model, effCell),
          child: SizedBox(
            width: natW,
            height: natH,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _HeatmapPainter(
                  model: model,
                  baseColor: widget.baseColor,
                  emptyColor: widget.emptyColor,
                  emptyBorderColor: widget.emptyBorderColor,
                  cell: effCell,
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
            _buildHeader(theme, offset, maxOffset, effWeeks),
            SizedBox(height: widget.spacing * 2),
            // 窄到连最少列数都放不下时仍等比缩小兜底。
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: grid,
            ),
          ],
        );
      },
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.model,
    required this.baseColor,
    required this.emptyColor,
    required this.emptyBorderColor,
    required this.cell,
    required this.spacing,
    required this.selectedDateKey,
    required this.selectedBorderColor,
  });

  final StatHeatmapModel model;
  final Color baseColor;
  final Color emptyColor;
  final Color? emptyBorderColor;
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
    // BUG-1917：一年 364 格若逐格 drawRRect（填充 + 空格描边 ≈ 730 个 Skia op），
    // raster 线程每帧光 op 调用开销就 ~9ms——RepaintBoundary 保留的 picture 每帧
    // 仍逐 op 回放，引擎并不把它缓存成纹理。按等级把格子合成一条 Path 一次画：
    // 5 个等级 + 1 条空格描边 + 选中框 ≤ 7 个 op，几何完全相同。
    final Radius radius = Radius.circular(cell * 0.25);
    final List<Path> byLevel = List<Path>.generate(5, (_) => Path());
    final Path emptyBorderPath = Path();
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
        byLevel[c.level].addRRect(RRect.fromRectAndRadius(rect, radius));
        if (c.level == 0 && emptyBorderColor != null) {
          emptyBorderPath.addRRect(
            RRect.fromRectAndRadius(rect.deflate(0.5), radius),
          );
        }
        if (selectedDateKey != null && c.dateKey == selectedDateKey) {
          selectedRect = rect;
        }
      }
    }
    final Paint paint = Paint()..style = PaintingStyle.fill;
    for (int level = 0; level < byLevel.length; level++) {
      paint.color = _colorFor(level);
      canvas.drawPath(byLevel[level], paint);
    }
    if (emptyBorderColor != null) {
      canvas.drawPath(
        emptyBorderPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = emptyBorderColor!,
      );
    }
    // 选中格描边画在最后，避免被相邻格覆盖。
    if (selectedRect != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(selectedRect.inflate(0.5), radius),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = selectedBorderColor,
      );
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.model != model ||
      old.baseColor != baseColor ||
      old.emptyColor != emptyColor ||
      old.emptyBorderColor != emptyBorderColor ||
      old.cell != cell ||
      old.spacing != spacing ||
      old.selectedDateKey != selectedDateKey ||
      old.selectedBorderColor != selectedBorderColor;
}
