import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/mining/galgame_scrape_controller.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';
import 'package:hibiki/src/pages/implementations/games_library_page.dart'
    show formatGalgameDate, galgamePlayStatusLabel;
import 'package:hibiki/src/pages/implementations/stat_charts.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:hibiki/utils.dart';

/// galgame 详情页（契约 §4.2）：头部常驻 + 统计 / 简介 / 编辑三个 tab。
///
/// 由游戏库页长按/右键菜单 push 进来（卡片点击仍是启动游戏）。数据全部走
/// [GalgameRepository]：条目本身读缓存，会话流水与每日聚合按需查 DB。
/// 启动按钮不自带启动逻辑——[onLaunch] 由库页传入，复用那边带再入守卫的
/// `_launchGame`，避免两处各写一套 helper 确认 / 注入流程。
class GalgameDetailPage extends ConsumerStatefulWidget {
  const GalgameDetailPage({
    required this.gameId,
    super.key,
    this.initialTab = 0,
    this.onLaunch,
  });

  /// `galgames.id`。
  final String gameId;

  /// 初始 tab（0=统计 / 1=简介 / 2=编辑）。库页「刮削元数据」直接落编辑 tab。
  final int initialTab;

  /// 启动游戏（null = 不显示启动按钮，如非 Windows 或独立打开）。
  final VoidCallback? onLaunch;

  @override
  ConsumerState<GalgameDetailPage> createState() => _GalgameDetailPageState();
}

class _GalgameDetailPageState extends ConsumerState<GalgameDetailPage>
    with SingleTickerProviderStateMixin {
  late final AppModel _appModel = ref.read(appProvider);
  late final GalgameRepository _repo = _appModel.galgameRepo;
  late final TabController _tabs = TabController(
    length: 3,
    vsync: this,
    initialIndex: widget.initialTab.clamp(0, 2),
  );

  GalgameEntry? _game;
  List<GalgameSessionRow> _sessions = const <GalgameSessionRow>[];
  List<GalgameSourceRow> _sources = const <GalgameSourceRow>[];

  /// 柱状图当前展示的月份（取该月 1 号 0 点）。
  late DateTime _month = _firstOfMonth(DateTime.now());

  /// 当前月每日秒数（dateKey → 秒）。
  Map<String, int> _daily = const <String, int>{};

  /// 今日秒数（与 [_month] 无关，单独查一天）。
  int _todaySeconds = 0;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  static DateTime _firstOfMonth(DateTime value) =>
      DateTime(value.year, value.month);

  Future<void> _load() async {
    final GalgameEntry? game = _repo.byId(widget.gameId) ??
        (await _repo.load())
            .where((GalgameEntry g) => g.id == widget.gameId)
            .firstOrNull;
    if (game == null) {
      if (!mounted) return;
      setState(() {
        _game = null;
        _loading = false;
      });
      return;
    }
    final List<GalgameSessionRow> sessions = await _repo.sessions(game.id);
    final List<GalgameSourceRow> sources = await _repo.sourcesOf(game.id);
    final Map<String, int> daily = await _loadMonth(game.id, _month);
    final String todayKey = formatGalgameDate(DateTime.now());
    final Map<String, int> today = await _repo.dailySeconds(
      game.id,
      fromDateKey: todayKey,
      toDateKey: todayKey,
    );
    if (!mounted) return;
    setState(() {
      _game = game;
      _sessions = sessions;
      _sources = sources;
      _daily = daily;
      _todaySeconds = today[todayKey] ?? 0;
      _loading = false;
    });
  }

  Future<Map<String, int>> _loadMonth(String gameId, DateTime month) {
    final DateTime last = DateTime(month.year, month.month + 1, 0);
    return _repo.dailySeconds(
      gameId,
      fromDateKey: formatGalgameDate(month),
      toDateKey: formatGalgameDate(last),
    );
  }

  /// 翻月：[delta] = ±1。不允许翻到未来（当月是上界）。
  Future<void> _shiftMonth(int delta) async {
    final GalgameEntry? game = _game;
    if (game == null) return;
    final DateTime next = DateTime(_month.year, _month.month + delta);
    if (next.isAfter(_firstOfMonth(DateTime.now()))) return;
    final Map<String, int> daily = await _loadMonth(game.id, next);
    if (!mounted) return;
    setState(() {
      _month = next;
      _daily = daily;
    });
  }

  Future<void> _deleteSession(GalgameSessionRow row) async {
    await _repo.deleteSession(row.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final GalgameEntry? game = _game;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (game == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(t.game_detail_missing)),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          game.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: <Widget>[
          _buildHeader(context, game),
          TabBar(
            controller: _tabs,
            tabs: <Widget>[
              Tab(text: t.game_detail_tab_stats),
              Tab(text: t.game_detail_tab_summary),
              Tab(text: t.game_detail_tab_edit),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _buildStatsTab(context, game),
                _buildSummaryTab(context, game),
                _GalgameEditTab(
                  game: game,
                  repo: _repo,
                  onSaved: _load,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 头部常驻：封面大图 + 显示名 / 开发商 / 评分 / 状态 / 标签 chips + 外链 + 启动。
  Widget _buildHeader(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final List<String> tags = game.tags;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            height: 128,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _buildCover(game, colors),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  game.displayName,
                  style: theme.textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  <String>[
                    if (game.developer != null) game.developer!,
                    galgamePlayStatusLabel(game.playStatus),
                    if (game.effectiveReleaseDate != null)
                      game.effectiveReleaseDate!,
                  ].join('  ·  '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    if (game.siteScore != null)
                      _scoreChip(theme, Icons.public,
                          '${t.game_site_score} ${game.siteScore!.toStringAsFixed(1)}'),
                    if (game.userRating != null)
                      _scoreChip(theme, Icons.star,
                          '${t.game_user_rating} ${game.userRating!.toStringAsFixed(1)}'),
                    for (final GalgameSourceRow row in _sources)
                      if (_externalUrl(row) != null)
                        TextButton.icon(
                          onPressed: () =>
                              unawaited(_openUrl(_externalUrl(row)!)),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: Text(
                            GalgameMetadataSource.fromKey(row.source)?.label ??
                                row.source,
                          ),
                        ),
                    if (widget.onLaunch != null)
                      FilledButton.icon(
                        onPressed: widget.onLaunch,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(t.game_launch),
                      ),
                  ],
                ),
                if (tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final String tag in tags.take(12))
                        Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreChip(ThemeData theme, IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }

  String? _externalUrl(GalgameSourceRow row) {
    final GalgameMetadataSource? source =
        GalgameMetadataSource.fromKey(row.source);
    final String? id = row.externalId;
    if (source == null || id == null || id.isEmpty) return null;
    return GalgameScrapeController.instance.externalUrl(source, id);
  }

  Future<void> _openUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _buildCover(GalgameEntry game, ColorScheme colors) {
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            _defaultCover(colors),
      );
    }
    return _defaultCover(colors);
  }

  Widget _defaultCover(ColorScheme colors) => Container(
        color: colors.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.videogame_asset,
            size: 40, color: colors.onSurfaceVariant),
      );

  // ── 统计 tab ───────────────────────────────────────────────────────────

  /// 四个 KPI + 按月每日柱状图 + 会话流水（可删单条）。
  Widget _buildStatsTab(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        Row(
          children: <Widget>[
            _kpi(theme, t.game_stat_total_time,
                formatStatTime(game.totalPlaySeconds * 1000)),
            _kpi(theme, t.game_stat_sessions, '${game.sessionCount}'),
            _kpi(
                theme, t.game_stat_today, formatStatTime(_todaySeconds * 1000)),
            _kpi(
              theme,
              t.game_stat_last_played,
              game.lastPlayedMs <= 0
                  ? t.games_never_played
                  : formatGalgameDate(
                      DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${t.game_stat_daily}  ${_month.year}-${_month.month.toString().padLeft(2, '0')}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: t.game_stat_prev_month,
              icon: const Icon(Icons.chevron_left),
              onPressed: () => unawaited(_shiftMonth(-1)),
            ),
            IconButton(
              tooltip: t.game_stat_next_month,
              icon: const Icon(Icons.chevron_right),
              onPressed: _month.isBefore(_firstOfMonth(DateTime.now()))
                  ? () => unawaited(_shiftMonth(1))
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 160,
          child: CustomPaint(
            size: Size.infinite,
            painter: StatBarChartPainter(
              data: buildGalgameMonthChartData(_month, _daily),
              barColor: theme.colorScheme.primary,
              barRadius: HibikiDesignTokens.of(context).radii.chipCorner,
              labelColor: theme.colorScheme.onSurfaceVariant,
              labelStyle: HibikiDesignTokens.of(context).type.metadata.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              // 游玩时长用 ms 值 + 时长纵轴（与视频统计同款）。
              valueOf: statMsValue,
              labelFormatter: formatStatDurationAxis,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(t.game_stat_session_list, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_sessions.isEmpty)
          Text(
            t.game_stat_no_sessions,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else
          for (final GalgameSessionRow row in _sessions)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(formatGalgameSessionRange(row)),
              subtitle: Text(formatStatTime(row.durationSeconds * 1000)),
              trailing: IconButton(
                tooltip: t.game_stat_delete_session,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => unawaited(_deleteSession(row)),
              ),
            ),
      ],
    );
  }

  Widget _kpi(ThemeData theme, String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ── 简介 tab ───────────────────────────────────────────────────────────

  Widget _buildSummaryTab(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    final GalgameMetadataDraft meta = game.metadata;
    final String? summary = meta.summary;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: <Widget>[
        Text(
          summary ?? t.game_summary_none,
          style: theme.textTheme.bodyMedium,
        ),
        if (meta.aliases.isNotEmpty)
          _summarySection(
              theme, t.game_summary_aliases, meta.aliases.join('、')),
        if (meta.allTitles.isNotEmpty)
          _summarySection(
              theme, t.game_summary_all_titles, meta.allTitles.join('\n')),
        if (game.effectiveReleaseDate != null)
          _summarySection(
              theme, t.game_summary_release_date, game.effectiveReleaseDate!),
        if (meta.averageHours != null)
          _summarySection(theme, t.game_summary_average_hours,
              '${meta.averageHours!.toStringAsFixed(1)} h'),
        if (game.customData.userReview != null)
          _summarySection(
              theme, t.game_edit_user_review, game.customData.userReview!),
      ],
    );
  }

  Widget _summarySection(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// 纯函数：把某月的每日秒数映射铺成柱状图数据点（缺省天为 0，保证整月都有柱位）。
/// 值落 [StatDayData.ms]（秒 × 1000），与视频统计同款走时长纵轴。
List<StatDayData> buildGalgameMonthChartData(
  DateTime month,
  Map<String, int> secondsByDay,
) {
  final int days = DateTime(month.year, month.month + 1, 0).day;
  return <StatDayData>[
    for (int d = 1; d <= days; d++)
      () {
        final String key =
            formatGalgameDate(DateTime(month.year, month.month, d));
        return StatDayData(dateKey: key)..ms = (secondsByDay[key] ?? 0) * 1000;
      }(),
  ];
}

/// 一条会话的时间范围文案：`2026-07-24 21:03 → 22:41`。
String formatGalgameSessionRange(GalgameSessionRow row) {
  final DateTime start = DateTime.fromMillisecondsSinceEpoch(row.startMs);
  final DateTime end = DateTime.fromMillisecondsSinceEpoch(row.endMs);
  String hm(DateTime v) =>
      '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
  return '${formatGalgameDate(start)} ${hm(start)} → ${hm(end)}';
}

/// 编辑 tab：改显示名 / 简介 / 标签 / 开发商 / 日期 / NSFW / 我的评分 / 我的评价，
/// 改 exe 路径与工作目录，以及「刮削元数据」入口。
///
/// 全部用户输入落 `customDataJson`（覆盖层，契约 §1.3）；exe / workdir / 发行日
/// 是 `galgames` 自己的列。保存是一次整行 upsert。
class _GalgameEditTab extends StatefulWidget {
  const _GalgameEditTab({
    required this.game,
    required this.repo,
    required this.onSaved,
  });

  final GalgameEntry game;
  final GalgameRepository repo;
  final Future<void> Function() onSaved;

  @override
  State<_GalgameEditTab> createState() => _GalgameEditTabState();
}

class _GalgameEditTabState extends State<_GalgameEditTab> {
  late final TextEditingController _name =
      TextEditingController(text: widget.game.customData.name ?? '');
  late final TextEditingController _summary =
      TextEditingController(text: widget.game.customData.summary ?? '');
  late final TextEditingController _tags =
      TextEditingController(text: widget.game.customData.tags.join(', '));
  late final TextEditingController _developer =
      TextEditingController(text: widget.game.customData.developer ?? '');
  late final TextEditingController _releaseDate =
      TextEditingController(text: widget.game.releaseDate ?? '');
  late final TextEditingController _rating = TextEditingController(
      text: widget.game.customData.userRating?.toString() ?? '');
  late final TextEditingController _review =
      TextEditingController(text: widget.game.customData.userReview ?? '');
  late final TextEditingController _exePath =
      TextEditingController(text: widget.game.exePath);
  late final TextEditingController _workdir =
      TextEditingController(text: widget.game.workdir);
  late bool _nsfw = widget.game.customData.nsfw ?? false;

  bool _scraping = false;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _summary,
      _tags,
      _developer,
      _releaseDate,
      _rating,
      _review,
      _exePath,
      _workdir,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 保存：组装覆盖层 + 整行 upsert。日期格式不合法直接拒绝（该列要拿去排序）。
  Future<void> _save() async {
    final String rawDate = _releaseDate.text.trim();
    final String? date = rawDate.isEmpty ? null : draftDate(rawDate);
    if (rawDate.isNotEmpty && date == null) {
      HibikiToast.show(msg: t.game_edit_invalid_date);
      return;
    }
    final GalgameEntry game = widget.game;
    final GalgameCustomData custom = GalgameCustomData(
      name: _trimmedOrNull(_name.text),
      coverSource: game.customData.coverSource,
      aliases: game.customData.aliases,
      summary: _trimmedOrNull(_summary.text),
      tags: parseGalgameTagInput(_tags.text),
      developer: _trimmedOrNull(_developer.text),
      nsfw: _nsfw ? true : null,
      userRating: parseGalgameRating(_rating.text),
      userReview: _trimmedOrNull(_review.text),
    );
    final GalgameEntry next = GalgameEntry(
      id: game.id,
      name: game.name,
      exePath: _exePath.text.trim(),
      workdir: _workdir.text.trim(),
      coverPath: game.coverPath,
      addedAt: game.addedAt,
      playStatus: game.playStatus,
      primarySource: game.primarySource,
      releaseDate: date,
      customData: custom,
      metadata: game.metadata,
      sortOrder: game.sortOrder,
    );
    await widget.repo.updateEntry(next);
    await widget.onSaved();
    if (!mounted) return;
    HibikiToast.show(msg: t.game_edit_saved);
  }

  /// 刮削：输入标题或源 ID → 搜索 → 多结果让用户选 → 取详情 → 落库。
  Future<void> _scrape() async {
    if (_scraping) return; // 再入守卫：一次刮削含多次网络往返。
    final String? query = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _ScrapeQueryDialog(
        initial: _name.text.trim().isEmpty
            ? widget.game.displayName
            : _name.text.trim(),
      ),
    );
    if (query == null || query.isEmpty) return;
    _scraping = true;
    setState(() {});
    try {
      final GalgameScrapeSearchResult result =
          await GalgameScrapeController.instance.search(query);
      if (!mounted) return;
      if (result.isEmpty) {
        HibikiToast.show(msg: t.game_scrape_no_result);
        return;
      }
      SourceCandidate? picked = result.candidates.length == 1
          ? result.candidates.first
          : await showDialog<SourceCandidate>(
              context: context,
              builder: (BuildContext ctx) =>
                  _SourcePickerDialog(candidates: result.candidates),
            );
      if (picked == null || !mounted) return;
      final GalgameMetadataDraft? draft = await GalgameScrapeController.instance
          .fetchById(picked.source, picked.externalId);
      if (!mounted) return;
      if (draft == null) {
        HibikiToast.show(msg: t.game_scrape_no_result);
        return;
      }
      // 多个源都有快照时主显示源记 mixed（契约 §1.1）。
      final List<GalgameSourceRow> existing =
          await widget.repo.sourcesOf(widget.game.id);
      final Set<String> sources = <String>{
        for (final GalgameSourceRow row in existing) row.source,
        picked.source.key,
      };
      await widget.repo.saveScrapeResult(
        gameId: widget.game.id,
        source: picked.source,
        draft: draft,
        primarySource:
            sources.length > 1 ? kGalgamePrimarySourceMixed : picked.source.key,
      );
      await widget.onSaved();
      if (!mounted) return;
      HibikiToast.show(msg: t.game_scrape_applied);
    } on GalgameMetadataException catch (e) {
      if (!mounted) return;
      HibikiToast.show(msg: '${t.game_scrape_failed}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      HibikiToast.show(msg: '${t.game_scrape_failed}: $e');
    } finally {
      _scraping = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _scraping ? null : () => unawaited(_scrape()),
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text(t.games_scrape),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => unawaited(_save()),
                icon: const Icon(Icons.save_outlined),
                label: Text(t.game_edit_save),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _field('name', _name, t.game_edit_display_name),
        _field('summary', _summary, t.game_edit_summary, maxLines: 4),
        _field('tags', _tags, t.game_edit_tags),
        _field('developer', _developer, t.game_edit_developer),
        _field('releaseDate', _releaseDate, t.game_edit_release_date),
        _field('rating', _rating, t.game_edit_user_rating),
        _field('review', _review, t.game_edit_user_review, maxLines: 3),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.game_edit_nsfw),
          value: _nsfw,
          onChanged: (bool v) => setState(() => _nsfw = v),
        ),
        _field('exePath', _exePath, t.game_edit_exe_path),
        _field('workdir', _workdir, t.game_edit_workdir),
      ],
    );
  }

  /// 一个带稳定 key 的编辑字段。key 形如 `galgame-edit-exePath`，供集成/widget
  /// 测试定位——按标签文案定位会随 17 语言翻译漂移。
  Widget _field(
    String fieldKey,
    TextEditingController controller,
    String label, {
    int maxLines = 1,
  }) {
    return Padding(
      key: ValueKey<String>('galgame-edit-$fieldKey'),
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

String? _trimmedOrNull(String raw) {
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 纯函数：把「逗号分隔标签」输入框解析成去重保序的标签表（半角/全角逗号都认）。
List<String> parseGalgameTagInput(String raw) {
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final String part in raw.split(RegExp(r'[,，、]'))) {
    final String tag = part.trim();
    if (tag.isNotEmpty && seen.add(tag)) {
      out.add(tag);
    }
  }
  return out;
}

/// 纯函数：解析「我的评分」输入。空 / 非数字 → null；越界 clamp 到 0-10。
double? parseGalgameRating(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final double? value = double.tryParse(trimmed);
  if (value == null || !value.isFinite) return null;
  return value.clamp(0, 10).toDouble();
}

/// 刮削关键词输入框（标题或源 ID）。
class _ScrapeQueryDialog extends StatefulWidget {
  const _ScrapeQueryDialog({required this.initial});

  final String initial;

  @override
  State<_ScrapeQueryDialog> createState() => _ScrapeQueryDialogState();
}

class _ScrapeQueryDialogState extends State<_ScrapeQueryDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.game_scrape_title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: t.game_scrape_query),
        onSubmitted: (String v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(t.dialog_ok),
        ),
      ],
    );
  }
}

/// 多结果候选列表（契约 §2.5）：选中后由调用方 `fetchById` 补全。
class _SourcePickerDialog extends StatelessWidget {
  const _SourcePickerDialog({required this.candidates});

  final List<SourceCandidate> candidates;

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text(t.game_scrape_pick),
      children: <Widget>[
        for (final SourceCandidate c in candidates)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(c),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  c.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  <String>[
                    c.source.label,
                    c.externalId,
                    if (c.releaseDate != null) c.releaseDate!,
                  ].join('  ·  '),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
