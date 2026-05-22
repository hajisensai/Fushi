import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

class ReadingStatisticsPage extends BasePage {
  const ReadingStatisticsPage({super.key});

  @override
  BasePageState<ReadingStatisticsPage> createState() =>
      _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends BasePageState<ReadingStatisticsPage> {
  bool _loading = true;
  String? _error;

  List<ReadingStatisticRow> _allStats = [];

  // 聚合数据
  int _todayChars = 0;
  int _todayMs = 0;
  int _weekChars = 0;
  int _weekMs = 0;
  int _monthChars = 0;
  int _monthMs = 0;
  int _allChars = 0;
  int _allMs = 0;

  // 每日数据（最近 30 天）
  List<_DayData> _dailyData = [];

  // 今日每小时数据（0-23）
  List<int> _hourlyMs = List.filled(24, 0);

  // 按书聚合
  List<_BookData> _bookData = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAndLoad());
  }

  Future<void> _syncAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    try {
      final db = appModelNoUpdate.database;
      _allStats = await db.getAllReadingStatistics();
      _computeAggregates();
      await _loadHourlyData();
    } catch (e, stack) {
      ErrorLogService.instance.log('ReadingStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    setState(() => _loading = false);
  }

  Future<void> _loadHourlyData() async {
    final db = appModelNoUpdate.database;
    final todayKey = _dateKey(DateTime.now());
    final rows = await db.getHourlyLogsForDate(todayKey);
    _hourlyMs = List.filled(24, 0);
    for (final row in rows) {
      if (row.hour >= 0 && row.hour < 24) {
        _hourlyMs[row.hour] = row.readingTimeMs;
      }
    }
  }

  void _computeAggregates() {
    final now = DateTime.now();
    final todayKey = _dateKey(now);
    final weekAgoKey = _dateKey(now.subtract(const Duration(days: 7)));
    final monthAgoKey = _dateKey(now.subtract(const Duration(days: 30)));

    _todayChars = 0;
    _todayMs = 0;
    _weekChars = 0;
    _weekMs = 0;
    _monthChars = 0;
    _monthMs = 0;
    _allChars = 0;
    _allMs = 0;

    final dailyMap = <String, _DayData>{};
    final bookMap = <String, _BookData>{};

    for (final s in _allStats) {
      _allChars += s.charactersRead;
      _allMs += s.readingTimeMs;

      if (s.dateKey == todayKey) {
        _todayChars += s.charactersRead;
        _todayMs += s.readingTimeMs;
      }
      if (s.dateKey.compareTo(weekAgoKey) >= 0) {
        _weekChars += s.charactersRead;
        _weekMs += s.readingTimeMs;
      }
      if (s.dateKey.compareTo(monthAgoKey) >= 0) {
        _monthChars += s.charactersRead;
        _monthMs += s.readingTimeMs;
      }

      // 每日
      final day =
          dailyMap.putIfAbsent(s.dateKey, () => _DayData(dateKey: s.dateKey));
      day.chars += s.charactersRead;
      day.ms += s.readingTimeMs;

      // 按书
      final book =
          bookMap.putIfAbsent(s.title, () => _BookData(title: s.title));
      book.chars += s.charactersRead;
      book.ms += s.readingTimeMs;
    }

    // 最近 30 天，按日期排序
    final thirtyDaysAgo = now.subtract(const Duration(days: 29));
    _dailyData = [];
    for (int i = 0; i < 30; i++) {
      final d = thirtyDaysAgo.add(Duration(days: i));
      final key = _dateKey(d);
      _dailyData.add(dailyMap[key] ?? _DayData(dateKey: key));
    }

    _bookData = bookMap.values.toList()
      ..sort((a, b) => b.chars.compareTo(a.chars));
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _formatTime(int ms) {
    final totalMin = ms ~/ 60000;
    if (totalMin < 60) return t.stat_format_minutes(n: totalMin);
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return t.stat_format_hours_minutes(h: h, m: m);
  }

  static String _formatChars(int chars) {
    if (chars >= 10000) {
      return t.stat_format_chars_wan(n: (chars / 10000).toStringAsFixed(1));
    }
    return t.stat_format_chars(n: chars);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.reading_statistics),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t.stat_refresh,
            onPressed: _loading ? null : _syncAndLoad,
          ),
        ],
      ),
      body: _loading
          ? buildLoading()
          : _error != null
              ? buildError(error: _error)
              : _allStats.isEmpty
                  ? Center(
                      child: HibikiPlaceholderMessage(
                        icon: Icons.bar_chart,
                        message: t.stat_no_data,
                      ),
                    )
                  : _buildContent(),
    );
  }

  Widget _buildContent() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(child: _buildHourlyChart()),
        SliverToBoxAdapter(child: _buildDailyChart()),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(t.stat_by_book,
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildBookTile(_bookData[index]),
            childCount: _bookData.length,
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
  }

  Widget _buildSummaryCards() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                  child: _summaryCard(t.stat_today, _todayChars, _todayMs)),
              const SizedBox(width: 12),
              Expanded(
                  child: _summaryCard(t.stat_this_week, _weekChars, _weekMs)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child:
                      _summaryCard(t.stat_this_month, _monthChars, _monthMs)),
              const SizedBox(width: 12),
              Expanded(child: _summaryCard(t.stat_all_time, _allChars, _allMs)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(String label, int chars, int ms) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
            const SizedBox(height: 8),
            Text(_formatChars(chars),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    )),
            const SizedBox(height: 4),
            Text(_formatTime(ms),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
          ],
        ),
      ),
    );
  }

  Widget _buildHourlyChart() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stat_today_hourly,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: CustomPaint(
              size: Size.infinite,
              painter: _HourlyChartPainter(
                hourlyMs: _hourlyMs,
                barColor: Theme.of(context).colorScheme.tertiary,
                labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildDailyChart() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stat_last_30_days,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: CustomPaint(
              size: Size.infinite,
              painter: _BarChartPainter(
                data: _dailyData,
                barColor: Theme.of(context).colorScheme.primary,
                labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookTile(_BookData book) {
    final maxChars =
        _bookData.isEmpty ? 1 : _bookData.first.chars.clamp(1, 1 << 50);
    final fraction = book.chars / maxChars;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 8,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(colorScheme.primary),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_formatChars(book.chars)} · ${_formatTime(book.ms)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _DayData {
  _DayData({required this.dateKey});
  final String dateKey;
  int chars = 0;
  int ms = 0;
}

class _BookData {
  _BookData({required this.title});
  final String title;
  int chars = 0;
  int ms = 0;
}

class _HourlyChartPainter extends CustomPainter {
  _HourlyChartPainter({
    required this.hourlyMs,
    required this.barColor,
    required this.labelColor,
  });

  final List<int> hourlyMs;
  final Color barColor;
  final Color labelColor;

  static String _formatMs(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes >= 60) return '${minutes ~/ 60}h';
    return '${minutes}m';
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (hourlyMs.isEmpty) return;

    final maxMs = hourlyMs.fold<int>(0, (prev, ms) => ms > prev ? ms : prev);
    if (maxMs == 0) return;

    const bottomPadding = 20.0;
    const leftPadding = 32.0;
    final chartHeight = size.height - bottomPadding;
    final chartWidth = size.width - leftPadding;
    final step = chartWidth / 24;
    final barWidth = step * 0.7;
    final gap = step * 0.15;

    final paint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final gridPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    final labelStyle = TextStyle(fontSize: 9, color: labelColor);

    canvas.drawLine(
      const Offset(leftPadding, 0),
      Offset(leftPadding, chartHeight),
      axisPaint,
    );
    canvas.drawLine(
      Offset(leftPadding, chartHeight),
      Offset(size.width, chartHeight),
      axisPaint,
    );

    const int yTicks = 4;
    for (int i = 0; i <= yTicks; i++) {
      final value = (maxMs * i / yTicks).round();
      final y = chartHeight - (chartHeight * i / yTicks);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: _formatMs(value), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < 24; i++) {
      final x = leftPadding + i * step + gap;
      final barHeight = (hourlyMs[i] / maxMs) * chartHeight;

      if (hourlyMs[i] > 0) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, chartHeight - barHeight, barWidth, barHeight),
          const Radius.circular(2),
        );
        canvas.drawRRect(rect, paint);
      }

      if (i % 3 == 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: i.toString().padLeft(2, '0'),
            style: labelStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(x + barWidth / 2 - tp.width / 2, chartHeight + 4),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HourlyChartPainter oldDelegate) =>
      !listEquals(hourlyMs, oldDelegate.hourlyMs);
}

class _BarChartPainter extends CustomPainter {
  _BarChartPainter({
    required this.data,
    required this.barColor,
    required this.labelColor,
  });

  final List<_DayData> data;
  final Color barColor;
  final Color labelColor;

  static String _formatChars(int chars) {
    if (chars >= 10000) return '${(chars / 10000).toStringAsFixed(1)}万';
    if (chars >= 1000) return '${(chars / 1000).toStringAsFixed(1)}k';
    return chars.toString();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final maxChars =
        data.fold<int>(0, (prev, d) => d.chars > prev ? d.chars : prev);
    if (maxChars == 0) return;

    const bottomPadding = 20.0;
    const leftPadding = 36.0;
    final chartHeight = size.height - bottomPadding;
    final chartWidth = size.width - leftPadding;
    final barWidth = (chartWidth / data.length) * 0.7;
    final gap = (chartWidth / data.length) * 0.3;
    final step = chartWidth / data.length;

    final paint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;
    final axisPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final gridPaint = Paint()
      ..color = labelColor.withValues(alpha: 0.16)
      ..strokeWidth = 1;

    final labelStyle = TextStyle(fontSize: 9, color: labelColor);

    canvas.drawLine(
      const Offset(leftPadding, 0),
      Offset(leftPadding, chartHeight),
      axisPaint,
    );
    canvas.drawLine(
      Offset(leftPadding, chartHeight),
      Offset(size.width, chartHeight),
      axisPaint,
    );

    const int yTicks = 4;
    for (int i = 0; i <= yTicks; i++) {
      final value = (maxChars * i / yTicks).round();
      final y = chartHeight - (chartHeight * i / yTicks);
      canvas.drawLine(Offset(leftPadding, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: _formatChars(value), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPadding - tp.width - 4, y - tp.height / 2));
    }

    for (int i = 0; i < data.length; i++) {
      final d = data[i];
      final x = leftPadding + i * step + gap / 2;
      final barHeight = (d.chars / maxChars) * chartHeight;

      if (d.chars > 0) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, chartHeight - barHeight, barWidth, barHeight),
          const Radius.circular(2),
        );
        canvas.drawRRect(rect, paint);
      }

      if (i % 5 == 0 || i == data.length - 1) {
        final tp = TextPainter(
          text: TextSpan(
            text: d.dateKey.substring(5), // MM-DD
            style: labelStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(x + barWidth / 2 - tp.width / 2, chartHeight + 4),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter oldDelegate) =>
      !listEquals(data, oldDelegate.data) ||
      barColor != oldDelegate.barColor ||
      labelColor != oldDelegate.labelColor;
}
