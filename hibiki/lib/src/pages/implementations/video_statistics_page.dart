import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/video_stat_aggregates.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 视频统计页：与阅读统计（[ReadingStatisticsPage]）位置对等、形态一致，但数据
/// 完全隔离（视频专用表）。展示观看时长 + 字幕字数 + 完成视频数。
class VideoStatisticsPage extends BasePage {
  const VideoStatisticsPage({super.key});

  @override
  BasePageState<VideoStatisticsPage> createState() =>
      _VideoStatisticsPageState();
}

class _VideoStatisticsPageState extends BasePageState<VideoStatisticsPage> {
  bool _loading = true;
  String? _error;

  VideoStatsAggregate _agg = VideoStatsAggregate();
  bool _hasData = false;

  // 今日每小时观看时长（0-23，毫秒）。
  List<int> _hourlyMs = List.filled(24, 0);

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
      final List<VideoWatchStatisticRow> stats =
          await db.getAllVideoWatchStatistics();
      final List<VideoBookRow> books = await VideoBookRepository(db).listAll();
      final List<DateTime> completed = books
          .map((VideoBookRow b) => b.completedAt)
          .whereType<DateTime>()
          .toList();
      _agg = computeVideoStats(
        stats: stats,
        completed: completed,
        now: DateTime.now(),
      );
      _hasData = stats.isNotEmpty || completed.isNotEmpty;
      await _loadHourlyData();
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    setState(() => _loading = false);
  }

  Future<void> _loadHourlyData() async {
    final db = appModelNoUpdate.database;
    final todayKey = _dateKey(DateTime.now());
    final rows = await db.getVideoHourlyLogsForDate(todayKey);
    _hourlyMs = List.filled(24, 0);
    for (final row in rows) {
      if (row.hour >= 0 && row.hour < 24) {
        _hourlyMs[row.hour] = row.watchTimeMs;
      }
    }
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
    return HibikiPageScaffold(
      title: t.video_statistics,
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.refresh,
          tooltip: t.stat_refresh,
          enabled: !_loading,
          onTap: _syncAndLoad,
        ),
      ],
      body: _loading
          ? buildLoading()
          : _error != null
              ? buildError(error: _error)
              : !_hasData
                  ? Center(
                      child: HibikiPlaceholderMessage(
                        icon: Icons.bar_chart_outlined,
                        message: t.video_stat_no_data,
                      ),
                    )
                  : _buildContent(),
    );
  }

  Widget _buildContent() {
    final tokens = HibikiDesignTokens.of(context);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(child: _buildHourlyChart()),
        SliverToBoxAdapter(child: _buildDailyChart()),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            child: Text(t.video_stat_by_video,
                style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildVideoTile(_agg.byVideo[index]),
            childCount: _agg.byVideo.length,
          ),
        ),
        SliverPadding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card * 2)),
      ],
    );
  }

  Widget _buildSummaryCards() {
    final tokens = HibikiDesignTokens.of(context);

    return Padding(
      padding: EdgeInsets.all(tokens.spacing.card),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _summaryStatPanel(t.stat_today, _agg.todayChars,
                    _agg.todayMs, _agg.todayCompleted),
              ),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Expanded(
                child: _summaryStatPanel(t.stat_this_week, _agg.weekChars,
                    _agg.weekMs, _agg.weekCompleted),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          Row(
            children: [
              Expanded(
                child: _summaryStatPanel(t.stat_this_month, _agg.monthChars,
                    _agg.monthMs, _agg.monthCompleted),
              ),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Expanded(
                child: _summaryStatPanel(t.stat_all_time, _agg.allChars,
                    _agg.allMs, _agg.allCompleted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryStatPanel(String label, int chars, int ms, int completed) {
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = HibikiDesignTokens.of(context);
    return HibikiCard(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
            SizedBox(height: tokens.spacing.gap),
            Text(_formatChars(chars),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    )),
            SizedBox(height: tokens.spacing.gap / 2),
            Text('${t.video_stat_watch_time}: ${_formatTime(ms)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
            SizedBox(height: tokens.spacing.gap / 2),
            Text('${t.video_stat_completed}: $completed',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    )),
          ],
        ),
      ),
    );
  }

  Widget _buildHourlyChart() {
    final tokens = HibikiDesignTokens.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stat_today_hourly,
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          SizedBox(
            height: 140,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatHourlyChartPainter(
                hourlyMs: _hourlyMs,
                barColor: colorScheme.tertiary,
                barRadius: tokens.radii.chipCorner,
                labelColor: colorScheme.onSurfaceVariant,
                labelStyle: tokens.type.metadata.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
        ],
      ),
    );
  }

  Widget _buildDailyChart() {
    final tokens = HibikiDesignTokens.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.stat_last_30_days,
              style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
          SizedBox(
            height: 160,
            child: CustomPaint(
              size: Size.infinite,
              painter: StatBarChartPainter(
                data: _agg.daily,
                barColor: colorScheme.primary,
                barRadius: tokens.radii.chipCorner,
                labelColor: colorScheme.onSurfaceVariant,
                labelStyle: tokens.type.metadata.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoTile(VideoStatBookData video) {
    final maxChars =
        _agg.byVideo.isEmpty ? 1 : _agg.byVideo.first.chars.clamp(1, 1 << 50);
    final fraction = video.chars / maxChars;
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = HibikiDesignTokens.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            video.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: tokens.radii.chipRadius,
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 8,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
              Text(
                '${_formatChars(video.chars)} · ${_formatTime(video.ms)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap / 2),
        ],
      ),
    );
  }
}
