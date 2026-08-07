import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/galgame_scrape_dialog.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart'
    show formatGalgameDate, galgamePlayStatusLabel;
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show allTagsProvider, filteredGameIdsProvider, gameTagMapProvider;
import 'package:fushi/src/pages/implementations/tag_picker_page.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/pages/hibiki_page_placeholders.dart';
import 'package:fushi/utils.dart';

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
    with
        SingleTickerProviderStateMixin,
        FushiPagePlaceholders<GalgameDetailPage> {
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

  /// 折线图时间窗口天数（含当天）。7D / 30D 两档（契约 §4）。
  int _rangeDays = 7;

  /// 当前时间窗口的每日秒数（dateKey → 秒）。
  Map<String, int> _dailyRange = const <String, int>{};

  /// 今日秒数（与 [_rangeDays] 无关，单独查一天）。
  int _todaySeconds = 0;

  /// 头部标签区本地选中集合（选中态 filled primary，对齐 ReinaManager）。
  final Set<String> _selectedTags = <String>{};

  /// 头部标签区是否展开（超过 [_kTagLimit] 时折叠，展开显示全部）。
  bool _tagsExpanded = false;

  /// 折叠前展示的标签上限（契约 §2）。
  static const int _kTagLimit = 40;

  /// 本游戏挂的共享用户标签，与 bgm/vndb 元数据标签分开。
  List<BookTagRow> _userTags = const <BookTagRow>[];

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
    final List<BookTagRow> userTags =
        await _appModel.database.getTagsForGame(game.id);
    final Map<String, int> daily = await _loadRange(game.id, _rangeDays);
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
      _userTags = userTags;
      _dailyRange = daily;
      _todaySeconds = today[todayKey] ?? 0;
      _loading = false;
    });
  }

  /// 查最近 [days] 天（含当天）的每日秒数。
  Future<Map<String, int>> _loadRange(String gameId, int days) {
    final DateTime today = DateTime.now();
    final DateTime start = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: days - 1));
    return _repo.dailySeconds(
      gameId,
      fromDateKey: formatGalgameDate(start),
      toDateKey: formatGalgameDate(today),
    );
  }

  /// 切换折线图时间窗口（7D / 30D）。
  Future<void> _setRange(int days) async {
    final GalgameEntry? game = _game;
    if (game == null || days == _rangeDays) return;
    final Map<String, int> daily = await _loadRange(game.id, days);
    if (!mounted) return;
    setState(() {
      _rangeDays = days;
      _dailyRange = daily;
    });
  }

  /// 头部标签点击：本地选中态切换（对齐 ReinaManager 的可选标签）。
  void _toggleTag(String tag) {
    setState(() {
      if (!_selectedTags.remove(tag)) _selectedTags.add(tag);
    });
  }

  Future<void> _deleteSession(GalgameSessionRow row) async {
    await _repo.deleteSession(row.id);
    await _load();
  }

  /// 「加入合集」：mediaType=[MediaKind.game]、entryKey=`galgames.id`（本机局域
  /// 身份），与库页卡片菜单同一 DAO 路径。
  Future<void> _addToCollection(GalgameEntry game) async {
    await showAddToCollectionDialog(
      context: context,
      database: _appModel.database,
      mediaType: MediaKind.game,
      entryKey: game.id,
      defaultNewName: game.displayName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final GalgameEntry? game = _game;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: buildLoading(),
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
        actions: <Widget>[
          // 「加入合集」：与库页卡片菜单同一入口语义（mediaType='game'，entryKey=
          // galgames.id），落库同走 addToCollection DAO；库页返回后 _reload 刷新分组。
          IconButton(
            tooltip: t.add_to_collection,
            icon: const Icon(Icons.collections_bookmark_outlined),
            onPressed: () => unawaited(_addToCollection(game)),
          ),
        ],
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

  /// 头部常驻（契约 §2）：封面居左 + 右侧富信息列（元信息网格 / 评分行 / 标签区）。
  /// 窄屏降级成封面在上、信息在下的单列。
  Widget _buildHeader(BuildContext context, GalgameEntry game) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget cover = _coverBlock(context, game);
    final Widget info = _infoColumn(context, game);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.rowHorizontal,
        tokens.spacing.rowVertical,
        tokens.spacing.rowHorizontal,
        tokens.spacing.gap,
      ),
      child: LayoutBuilder(
        builder: (BuildContext ctx, BoxConstraints c) {
          if (c.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(child: cover),
                SizedBox(height: tokens.spacing.card),
                info,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              cover,
              const SizedBox(width: 24),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
  }

  /// 封面块：max 宽 160 / max 高 260 / 圆角 / 大阴影（契约 §2）。
  Widget _coverBlock(BuildContext context, GalgameEntry game) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 160, maxHeight: 260),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: FushiBorderRadius.card,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: _buildCover(context, game),
      ),
    );
  }

  /// 右侧信息列：标题 + 状态 chip + 元信息网格 + 评分行 + 启动 + 标签区。
  Widget _infoColumn(BuildContext context, GalgameEntry game) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          game.displayName,
          style: theme.textTheme.headlineSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        FushiTagChip(
          label: galgamePlayStatusLabel(game.playStatus),
          selected: true,
        ),
        const SizedBox(height: 12),
        _metaGrid(context, game),
        const SizedBox(height: 8),
        _scoreRow(context, game),
        if (widget.onLaunch != null) ...<Widget>[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: widget.onLaunch,
              icon: const Icon(Icons.play_arrow),
              label: Text(t.game_launch),
            ),
          ),
        ],
        _tagsSection(context, game),
      ],
    );
  }

  Widget _userTagsCell(BuildContext context, GalgameEntry game) {
    return _metaCell(
      context,
      t.game_user_tags_title,
      Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final BookTagRow tag in _userTags)
            FushiTagChip(
              label: tag.name,
              color: Color(tag.colorValue),
              tone: FushiTagChipTone.surface,
            ),
          FushiActionChip(
            label: t.tag_manage,
            icon: Icons.sell_outlined,
            onPressed: () => unawaited(_editUserTags(game)),
          ),
        ],
      ),
    );
  }

  Future<void> _editUserTags(GalgameEntry game) async {
    await Navigator.push(
      context,
      adaptivePageRoute(
        context: context,
        builder: (_) => TagPickerPage(
          media: MediaRef(kind: MediaKind.game, entryKey: game.id),
        ),
      ),
    );
    if (!mounted) return;
    final List<BookTagRow> tags =
        await _appModel.database.getTagsForGame(game.id);
    if (!mounted) return;
    setState(() => _userTags = tags);
    ref.invalidate(allTagsProvider);
    ref.invalidate(gameTagMapProvider);
    ref.invalidate(filteredGameIdsProvider);
  }

  /// 元信息网格：每项「粗体 label + 下方 value」，flex-wrap（契约 §2）。
  Widget _metaGrid(BuildContext context, GalgameEntry game) {
    final GalgameMetadataDraft meta = game.metadata;
    final List<Widget> cells = <Widget>[
      if (_sources.isNotEmpty)
        _metaCell(context, t.game_meta_source, _sourceChips(context)),
      if (game.developer != null)
        _metaCell(
          context,
          t.game_edit_developer,
          FushiTagChip(label: game.developer!),
        ),
      if (game.effectiveReleaseDate != null)
        _metaTextCell(
            context, t.game_summary_release_date, game.effectiveReleaseDate!),
      _metaTextCell(
          context, t.game_meta_added, formatGalgameDate(game.addedAt)),
      if (meta.averageHours != null)
        _metaTextCell(context, t.game_summary_average_hours,
            '${meta.averageHours!.toStringAsFixed(1)} h'),
      if (meta.rank != null)
        _metaTextCell(context, t.game_meta_ranking, '#${meta.rank}'),
      _userTagsCell(context, game),
    ];
    return Wrap(runSpacing: 4, children: cells);
  }

  /// 一个「粗体 label + 值 widget」的网格单元。
  Widget _metaCell(BuildContext context, String label, Widget value) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 24, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: tokens.type.metadata.copyWith(
              fontWeight: FontWeight.w700,
              color: tokens.surfaces.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          value,
        ],
      ),
    );
  }

  /// 文本值的网格单元。
  Widget _metaTextCell(BuildContext context, String label, String value) {
    final ThemeData theme = Theme.of(context);
    return _metaCell(
      context,
      label,
      Text(value, style: theme.textTheme.bodyMedium),
    );
  }

  /// 数据来源 chips：可点者用 [FushiActionChip] 开外链，无链回落展示 chip。
  Widget _sourceChips(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final GalgameSourceRow row in _sources)
          () {
            final String label =
                GalgameMetadataSource.fromKey(row.source)?.label ?? row.source;
            final String? url = _externalUrl(row);
            if (url == null) return FushiTagChip(label: label);
            return FushiActionChip(
              label: label,
              icon: Icons.open_in_new,
              onPressed: () => unawaited(_openUrl(url)),
            );
          }(),
      ],
    );
  }

  /// 评分行：`站点 X.X`（默认）+ `我的 X.X`（primary 选中态）两个 chip。
  Widget _scoreRow(BuildContext context, GalgameEntry game) {
    final List<Widget> chips = <Widget>[
      if (game.siteScore != null)
        FushiTagChip(
          label: '${t.game_site_score} ${game.siteScore!.toStringAsFixed(1)}',
        ),
      if (game.userRating != null)
        FushiTagChip(
          label: '${t.game_user_rating} ${game.userRating!.toStringAsFixed(1)}',
          selected: true,
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 4, children: chips);
  }

  /// 标签区（契约 §2）：标题行（"游戏标签" + 选中计数 + 清空）+ flex-wrap 标签
  /// chips（选中态 filled primary），上限 [_kTagLimit] + 展开/折叠。
  Widget _tagsSection(BuildContext context, GalgameEntry game) {
    final List<String> tags = game.tags;
    if (tags.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final bool overflowing = tags.length > _kTagLimit;
    final List<String> shown =
        (overflowing && !_tagsExpanded) ? tags.sublist(0, _kTagLimit) : tags;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                _selectedTags.isEmpty
                    ? t.game_tags_title
                    : '${t.game_tags_title} · ${_selectedTags.length}',
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              if (_selectedTags.isNotEmpty)
                FushiActionChip(
                  label: t.game_tags_clear,
                  icon: Icons.clear,
                  onPressed: () => setState(_selectedTags.clear),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: <Widget>[
              for (final String tag in shown)
                FushiTagChip(
                  label: tag,
                  tone: FushiTagChipTone.surface,
                  selected: _selectedTags.contains(tag),
                  onTap: () => _toggleTag(tag),
                ),
            ],
          ),
          if (overflowing)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _tagsExpanded = !_tagsExpanded),
                icon:
                    Icon(_tagsExpanded ? Icons.expand_less : Icons.expand_more),
                label: Text(_tagsExpanded
                    ? t.collection_collapse
                    : '${t.collection_expand} +${tags.length - _kTagLimit}'),
              ),
            ),
        ],
      ),
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

  /// 封面：有 coverPath 且文件存在则经 [ShelfFileCover] 降采样加载（BUG-959 同类，
  /// 裸 Image.file 整帧解码包装图撑爆 ImageCache），否则共享占位件
  /// [ShelfCoverPlaceholder]（保持原 overlay 底色 + 手柄图标 40）。
  Widget _buildCover(BuildContext context, GalgameEntry game) {
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: Icons.videogame_asset,
      iconSize: 40,
      backgroundColor: FushiDesignTokens.of(context).surfaces.overlay,
    );
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ShelfFileCover(path: cover, placeholder: placeholder);
    }
    return placeholder;
  }

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
                  ? t.game_never_played
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
                t.game_stat_daily,
                style: theme.textTheme.titleMedium,
              ),
            ),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 7, label: Text('7D')),
                ButtonSegment<int>(value: 30, label: Text('30D')),
              ],
              selected: <int>{_rangeDays},
              onSelectionChanged: (Set<int> s) => unawaited(_setRange(s.first)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildDailyLineChart(context, theme),
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
            FushiListItem(
              density: FushiListDensity.compact,
              padding: EdgeInsets.zero,
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

  /// 每日游玩时长折线图（契约 §4）：线色主题色、Y 轴时长、X 轴日期、双向淡网格。
  /// 复用 [StatLineChartPainter]（阅读/视频统计同款自绘），不引图表库。
  Widget _buildDailyLineChart(BuildContext context, ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = theme.colorScheme;
    final List<StatDayData> points =
        buildGalgameRangeChartData(DateTime.now(), _rangeDays, _dailyRange);
    final List<double> values = <double>[
      for (final StatDayData d in points) d.ms.toDouble(),
    ];
    final List<String> labels = <String>[
      for (final StatDayData d in points) statDayLabel(d),
    ];
    return SizedBox(
      height: 280,
      child: CustomPaint(
        size: Size.infinite,
        painter: StatLineChartPainter(
          series: <StatLineSeries>[
            StatLineSeries(values: values, color: colors.primary),
          ],
          xLabels: labels,
          anomalies: const <bool>[],
          anomalyColor: colors.primary,
          labelColor: colors.onSurfaceVariant,
          labelStyle: tokens.type.metadata.copyWith(
            color: colors.onSurfaceVariant,
          ),
          // 纵轴是游玩时长（ms → "Xh Ym" / "Xm"），与视频统计同款。
          labelFormatter: formatGalgameDurationAxis,
          // 7 天档标签每天都显，30 天档抽稀到每 5 天。
          labelEvery: _rangeDays <= 7 ? 1 : 5,
        ),
      ),
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

/// 纯函数：把最近 [days] 天（以 [end] 当天为最后一天，含当天）的每日秒数铺成折线
/// 图数据点（缺省天为 0，保证整段区间都有点位）。值落 [StatDayData.ms]（秒 ×
/// 1000），与视频统计同款走时长纵轴。返回顺序按日期升序（旧 → 新）。
List<StatDayData> buildGalgameRangeChartData(
  DateTime end,
  int days,
  Map<String, int> secondsByDay,
) {
  final DateTime endDay = DateTime(end.year, end.month, end.day);
  return <StatDayData>[
    for (int i = days - 1; i >= 0; i--)
      () {
        final String key =
            formatGalgameDate(endDay.subtract(Duration(days: i)));
        return StatDayData(dateKey: key)..ms = (secondsByDay[key] ?? 0) * 1000;
      }(),
  ];
}

/// 把折线图纵轴的时长值（毫秒，double）格式化为标签（"Xh Ym" / "Xm" / "Xs"）。
/// 顶层 tear-off 而非闭包，保 [StatLineChartPainter.shouldRepaint] 的函数相等稳定。
String formatGalgameDurationAxis(double ms) =>
    formatStatDurationAxis(ms.round());

/// 一条会话的时间范围文案：`2026-07-24 21:03 → 22:41`。
/// 委托 [FushiTimeFormat]（G5 收敛：起点 = dateHourMinute，终点 = hourMinute）。
String formatGalgameSessionRange(GalgameSessionRow row) {
  final DateTime start = DateTime.fromMillisecondsSinceEpoch(row.startMs);
  final DateTime end = DateTime.fromMillisecondsSinceEpoch(row.endMs);
  return '${FushiTimeFormat.dateHourMinute(start)} → '
      '${FushiTimeFormat.hourMinute(end)}';
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
  late final TextEditingController _launchArgs =
      TextEditingController(text: widget.game.launchArgs);
  late bool _nsfw = widget.game.customData.nsfw ?? false;

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
      _launchArgs,
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
      FushiToast.show(
        msg: t.game_edit_invalid_date,
        severity: ToastSeverity.error,
      );
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
      // 这里是**逐字段重建**而非 copyWith：新增列必须在本列表里显式带上，漏一个就会
      // 每次保存静默清空该字段。改 GalgameEntry 字段时务必同步这里（有回归测试守着）。
      launchArgs: _launchArgs.text.trim(),
      // 编辑 Tab 不提供超分档位输入框（它在库页/详情页别处设），但这里必须原样透传：
      // 逐字段重建漏掉它 = 用户每次在编辑页保存都静默把超分设置清回默认。
      upscalingMode: game.upscalingMode,
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
    FushiToast.show(msg: t.game_edit_saved, severity: ToastSeverity.success);
  }

  /// 刮削：打开统一刮削弹窗（与库页卡菜单「刮削元数据」同一个入口，
  /// [showGalgameScrapeDialog]）。搜索/候选/落库/封面全部在弹窗内闭环；
  /// 预填词取编辑框里的名字（用户可能刚改过），空则退回当前显示名。
  Future<void> _scrape() async {
    final bool applied = await showGalgameScrapeDialog(
      context: context,
      game: widget.game,
      repo: widget.repo,
      initialQuery: _name.text.trim().isEmpty
          ? widget.game.displayName
          : _name.text.trim(),
    );
    if (!applied || !mounted) return;
    await widget.onSaved();
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
                // 再入守卫在统一弹窗内（每行「使用」行内转圈），按钮无需禁用态。
                onPressed: () => unawaited(_scrape()),
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text(t.game_scrape),
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
        AdaptiveSettingsSwitchRow(
          title: t.game_edit_nsfw,
          value: _nsfw,
          onChanged: (bool v) => setState(() => _nsfw = v),
        ),
        _field('exePath', _exePath, t.game_edit_exe_path),
        _field('workdir', _workdir, t.game_edit_workdir),
        _field(
          'launchArgs',
          _launchArgs,
          t.game_edit_launch_args,
          helperText: t.game_edit_launch_args_hint,
        ),
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
    String? helperText,
  }) {
    return Padding(
      key: ValueKey<String>('galgame-edit-$fieldKey'),
      padding: const EdgeInsets.only(top: 12),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
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

// （旧 `_ScrapeQueryDialog` / `_SourcePickerDialog` 已被统一刮削弹窗
// `showGalgameScrapeDialog` 取代：单弹窗内搜索 + 带缩略图候选 + 行内应用。）
