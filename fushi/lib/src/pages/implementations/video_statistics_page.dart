import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/video_stat_aggregates.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 视频统计页：与阅读统计（[ReadingStatisticsPage]）位置对等、形态一致，但数据
/// 完全隔离（视频专用表）。展示观看时长 + 完成视频数 + 制卡/收藏计数（不再展示
/// 字幕字数：字数仍在 DB 里采集，只是统计页不再呈现）。
class VideoStatisticsPage extends BasePage {
  const VideoStatisticsPage({super.key, this.embedded = false});

  /// true = 作为统计中心的一个 tab 嵌入（不套 FushiPageScaffold，动作行内联）。
  final bool embedded;

  @override
  BasePageState<VideoStatisticsPage> createState() =>
      _VideoStatisticsPageState();
}

class _VideoStatisticsPageState extends BasePageState<VideoStatisticsPage> {
  bool _loading = true;
  String? _error;

  VideoStatsAggregate _agg = VideoStatsAggregate();
  bool _hasData = false;

  /// **本轮加载时**的统计窗口：聚合（[computeVideoStats]）与时段卡谓词同一个
  /// （BUG-2219）；跨午夜由 [_midnightReload] 整页重聚合。
  StatWindow _window = StatWindow(DateTime.now());
  Timer? _midnightReload;

  /// 观看域日面事实行（loadStatFacts 的 dailyVideos 切片）：时段明细 sheet 的
  /// 数据源（阶段 1——此前这份数据聚合完即丢，时段明细要 per-video × per-day）。
  List<StatFact> _videoFacts = <StatFact>[];

  /// 观看域会话流（`StatFacts.sessions` 的视频切片，按结束时刻倒序）。
  List<StudySession> _sessions = <StudySession>[];

  /// 合集归属映射（书架同源）：按视频 tile 显示所属合集名用。
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'video|<bookUid>' → 折叠归属的主 collectionId。
  /// - [_libraryUidsByTitle]：库表 title→uid 集合（歧义否决与合集名回退共用，
  ///   一套政策：同名多 uid 谁也不许猜）。
  Map<int, String> _collectionNamesById = <int, String>{};
  Map<String, int> _primaryCollectionByEntry = <String, int>{};
  Map<String, Set<String>> _libraryUidsByTitle = <String, Set<String>>{};

  // 制卡 / 收藏计数（来源 'video'），按今日/本周/本月/全部分桶。
  StatActivityBuckets _mined = StatActivityBuckets();
  StatActivityBuckets _favorited = StatActivityBuckets();
  StatActivityBuckets _favoritedSentences = StatActivityBuckets();

  // 查词计数（来源 'video'）分桶（TODO-1204）。
  StatActivityBuckets _lookup = StatActivityBuckets();

  // 今日每小时观看时长（0-23，毫秒）。
  List<int> _hourlyMs = List.filled(24, 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAndLoad());
  }

  @override
  void dispose() {
    _midnightReload?.cancel();
    super.dispose();
  }

  /// 到下一个本地午夜整页重聚合（每次加载重新排一次；页面已卸载则不动）。
  void _armMidnightReload(DateTime now) {
    _midnightReload?.cancel();
    _midnightReload = Timer(StatWindow.untilNextStatDayBoundary(now), () {
      if (mounted) unawaited(_loadFromDatabase());
    });
  }

  /// 统计中心把三页塞进 TabBarView（无 keepAlive，离屏即 unmount），
  /// 「点开 tab → DB 还在查 → 切走」是一秒可复现的常规操作：首帧 postFrameCallback
  /// 与多次 await 之后的两处 setState 都必须过 mounted 门，否则 debug 断言
  /// `setState() called after dispose()`、release 打在已置空的 _element 上。
  Future<void> _syncAndLoad() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    try {
      // 成功路径清错误态（review4-5）：删除/清空直接调本方法（不经 _syncAndLoad
      // 的重置），上一轮失败的 _error 不清会让本轮成功的数据被错误画面挡住。
      _error = null;
      final db = appModelNoUpdate.database;
      // v92：观看事实只走统一事实面（legacy `video_watch_statistics` 日行 +
      // `study_segments` 段，由 loadStatFacts 归一），本页不再直接读表。
      // activityLimit 0：统计页不需要活动流行。
      final StatFacts facts = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
      );
      final List<StatFact> stats = facts.dailyVideos.toList();
      _videoFacts = stats;
      _sessions = facts.sessions.where((StudySession s) => s.isVideo).toList();
      final List<VideoBookRow> books = await VideoBookRepository(db).listAll();
      final List<DateTime> completed = books
          .map((VideoBookRow b) => b.completedAt)
          .whereType<DateTime>()
          .toList();
      // 合集归属（书架同源）：title→bookUid→'video|bookUid'→合集名，喂 per-video
      // tile。同一份 title→uids 事实同时喂歧义否决与合集名回退（review3-10：两个
      // 消费方一套政策——同名多 uid 的 title 谁也不许猜）。
      _libraryUidsByTitle = <String, Set<String>>{};
      for (final VideoBookRow b in books) {
        _libraryUidsByTitle
            .putIfAbsent(b.title, () => <String>{})
            .add(b.bookUid);
      }
      _collectionNamesById = <int, String>{
        for (final MediaCollectionRow c in await db.getAllMediaCollections())
          c.id: c.name,
      };
      _primaryCollectionByEntry = await db.getPrimaryCollectionIdByEntry();
      final DateTime now = DateTime.now();
      _window = StatWindow(now);
      _armMidnightReload(now);
      // 计数面（查词 / 制卡 / 收藏）与事实面同一次加载：总览 tab 的跨域数字必须
      // 恰好等于阅读 tab 与本 tab 之和，各页各查一遍就会在口径漂移时静默对不上。
      final StatCounterFacts counterFacts = facts.counters;
      final List<FavoriteWordRow> favs = counterFacts.favoriteWordsFor(
        StatSourceKind.video,
      );
      // 查词/制卡 per-video 计数。
      final List<LookupMiningCounterRow> counters = counterFacts
          .lookupCountersFor(StatSourceKind.video);
      // v76：观看 / 计数 / 收藏三个行宇宙进同一次身份分组，tile 自带全部数字
      // （吸收判据全局一致，绝不各分各的再拼——那是计数在同名 tile 间游走的根因）。
      // 库表级同名判定（≥2 个 uid 共享一个 title）喂给吸收否决：与迁移回填的
      // 唯一匹配判据同源，行宇宙判据单独用会误吸混合遗留（review-2）。已知限制
      // （review3-6）：歧义不粘——同名视频之一被移出库且没留下任何带身份统计行
      // 后，「曾经同名」这一事实没有任何观察者能复原，遗留行会按 unique-title
      // 判据归并给幸存者；粘化需要新增持久面，成本与收益不成比例，不做。
      _agg = computeVideoStats(
        stats: stats,
        completed: completed,
        now: now,
        counters: counters,
        favorites: favs,
        ambiguousTitles: <String>{
          for (final MapEntry<String, Set<String>> e
              in _libraryUidsByTitle.entries)
            if (e.value.length >= 2) e.key,
        },
      );
      _favorited = bucketActivityByDateKey(
        counterFacts.favoriteWordEvents(source: StatSourceKind.video),
        now,
      );
      _mined = bucketActivityByDateKey(
        counterFacts.minedEvents(source: StatSourceKind.video),
        now,
      );
      _lookup = bucketActivityByDateKey(
        counterFacts.lookupEvents(source: StatSourceKind.video),
        now,
      );
      // 视频来源收藏语句（source==video）。BUG-893 的读取端回退此前只修了阅读侧：
      // 本页旧判据是 `dateKey != null`，写入端补 dateKey 之前存下的视频收藏一条不
      // 计——现在与阅读侧同一个判据（[StatCounterFacts.favoriteSentenceEvents]），
      // 顺带让总览的跨域和恒等于两个域 tab 之和。
      final List<FavoriteSentence> videoFavSentences = counterFacts
          .favoriteSentences
          .where(
            (FavoriteSentence s) => s.source == kFavoriteSentenceSourceVideo,
          )
          .toList();
      _favoritedSentences = bucketActivityByDateKey(
        counterFacts.favoriteSentenceEvents(source: StatSourceKind.video),
        now,
      );
      // counters 也算有数据（review4-6）：只在视频域查过词（无观看/收藏/制卡）
      // 时，查词分桶明明有数却显示空状态。
      _hasData =
          stats.isNotEmpty ||
          completed.isNotEmpty ||
          favs.isNotEmpty ||
          counterFacts.minedEvents(source: StatSourceKind.video).isNotEmpty ||
          counters.isNotEmpty ||
          videoFavSentences.isNotEmpty;
      _loadHourlyData(facts);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoStatisticsPage.load', e, stack);
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 今日按小时观看时长：从事实面的小时面取 video 行**累加**。v92 起同一小时
  /// 会同时有 legacy 小时行与多条段，旧实现按行赋值（`=`）会让后来的行覆盖前面
  /// 的，只能用 `+=`。
  void _loadHourlyData(StatFacts facts) {
    final String todayKey = _window.todayKey;
    _hourlyMs = List.filled(24, 0);
    for (final StatFact f in facts.hourly) {
      if (!f.isVideo || f.dateKey != todayKey) continue;
      if (f.hour >= 0 && f.hour < 24) {
        _hourlyMs[f.hour] += f.ms;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 四个 tab 的动作行逐颗同形（用户 2026-09-10「所有界面都要统一」）：
    // 目标 → 刷新 → 清空全部统计。目标是**跨域的每日学习目标**（同一份表单、同一个
    // 持久化值），本页此前没有入口，切到这个 tab 目标按钮就凭空消失。
    final List<Widget> actions = <Widget>[
      FushiIconButton(
        icon: Icons.flag_outlined,
        tooltip: t.stat_goal_set,
        enabled: !_loading,
        onTap: _editGoals,
      ),
      FushiIconButton(
        icon: Icons.refresh,
        tooltip: t.stat_refresh,
        enabled: !_loading,
        onTap: _syncAndLoad,
      ),
      FushiIconButton(
        icon: Icons.delete_sweep_outlined,
        tooltip: t.stat_clear_all,
        enabled: !_loading,
        onTap: _confirmAndClearAll,
      ),
    ];
    final Widget body = buildStatPageBody(
      loading: _loading,
      error: _error,
      isEmpty: !_hasData,
      loadingBuilder: () =>
          buildLoading(size: 25, color: theme.colorScheme.primary),
      errorBuilder: (String error) => buildError(error: error),
      emptyMessage: t.video_stat_no_data,
      contentBuilder: _buildContent,
    );
    if (widget.embedded) return buildEmbeddedStatTab(context, actions, body);
    return FushiPageScaffold(
      title: t.video_statistics,
      actions: actions,
      body: body,
    );
  }

  Widget _buildContent() {
    final tokens = FushiDesignTokens.of(context);

    // 骨架与阅读 / 游戏 tab 同形：时段卡 → 每日图 → 最近会话 → 「分析」折叠 → 按视频。
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildSummaryCards()),
        SliverToBoxAdapter(
          child: buildStatDailyDurationChartSection(context, _agg.daily),
        ),
        SliverToBoxAdapter(
          child: buildStatSessionSection(
            context,
            sessions: _sessions,
            titleOf: (StudySession s) => s.title,
            collectionOf: _sessionCollectionName,
            onDelete: _deleteSession,
            onEdit: _editSession,
            onClearAll: _clearSessions,
          ),
        ),
        SliverToBoxAdapter(
          child: StatAnalysisFold(
            children: <Widget>[
              buildStatHourlyChartSection(context, _hourlyMs),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + tokens.spacing.gap,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            child: Text(
              t.video_stat_by_video,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildVideoTile(_agg.byVideo[index]),
            childCount: _agg.byVideo.length,
          ),
        ),
        buildStatTailSliver(context),
      ],
    );
  }

  Widget _buildSummaryCards() {
    // 时段谓词与聚合同一个窗口（BUG-2219），跨午夜靠 [_midnightReload] 重聚合。
    final StatWindow w = _window;
    return buildStatPeriodSummaryGrid(context, <StatPeriodSummary>[
      _periodSummary(
        t.stat_today,
        _agg.todayMs,
        _agg.todayChars,
        _agg.todayCompleted,
        _lookup.today,
        _mined.today,
        _favorited.today,
        _favoritedSentences.today,
        contains: w.isToday,
      ),
      _periodSummary(
        t.stat_this_week,
        _agg.weekMs,
        _agg.weekChars,
        _agg.weekCompleted,
        _lookup.week,
        _mined.week,
        _favorited.week,
        _favoritedSentences.week,
        contains: w.inWeek,
      ),
      _periodSummary(
        t.stat_this_month,
        _agg.monthMs,
        _agg.monthChars,
        _agg.monthCompleted,
        _lookup.month,
        _mined.month,
        _favorited.month,
        _favoritedSentences.month,
        contains: w.inMonth,
      ),
      _periodSummary(
        t.stat_all_time,
        _agg.allMs,
        _agg.allChars,
        _agg.allCompleted,
        _lookup.all,
        _mined.all,
        _favorited.all,
        _favoritedSentences.all,
        contains: (String _) => true,
      ),
    ]);
  }

  StatPeriodSummary _periodSummary(
    String label,
    int ms,
    int chars,
    int completed,
    int lookup,
    int mined,
    int favorited,
    int favoritedSentences, {
    required bool Function(String dateKey) contains,
  }) {
    return StatPeriodSummary(
      label: label,
      primaryValue: formatStatTime(ms),
      onTap: () => unawaited(_showPeriodDetail(label, contains)),
      lines: <StatSummaryLine>[
        // 字数打头，与另外三个 tab 的卡逐行同形（用户 2026-09-10「所有界面都要统一」）：
        // 本页此前把字幕字数只画进「按视频」列表，四张同形卡横过去时只有观看少一行。
        StatSummaryLine(value: formatStatChars(chars)),
        StatSummaryLine(label: t.video_stat_completed, value: '$completed'),
        StatSummaryLine(label: t.stat_lookup, value: '$lookup'),
        StatSummaryLine(label: t.stat_mined, value: '$mined'),
        StatSummaryLine(label: t.stat_favorited, value: '$favorited'),
        StatSummaryLine(
          label: t.stat_favorited_sentence,
          value: '$favoritedSentences',
        ),
      ],
    );
  }

  /// 时段卡 → 时段明细 sheet（阶段 1 统一组件；本页是视频统计，明细只吃观看域
  /// 切片 [_videoFacts]）。条目点击直达播放（合集成员带 playlistCollectionId，
  /// 与首页续播同口径）。
  Future<void> _showPeriodDetail(
    String label,
    bool Function(String dateKey) contains,
  ) async {
    // 身份在库集合：明细行可能是已删视频的历史统计，点它不该假装能播。
    final Set<String> libraryUids = <String>{
      for (final Set<String> uids in _libraryUidsByTitle.values) ...uids,
    };
    final FushiDatabase db = appModelNoUpdate.database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: label,
      contains: contains,
      facts: _videoFacts,
      resolvers: StatPeriodDetailResolvers(
        titleOf: (StatFact f) => f.title,
        collectionOf: (StatFact f) => f.mediaKey.isEmpty
            ? null
            : statCollectionName(
                MediaKind.video.compositeKey(f.mediaKey),
                _primaryCollectionByEntry,
                _collectionNamesById,
              ),
        onEntryTap: (String mediaKind, String mediaKey) async {
          if (mediaKey.isEmpty || !libraryUids.contains(mediaKey)) return;
          await openLocalVideoBook(
            context: context,
            repo: VideoBookRepository(db),
            bookUid: mediaKey,
            playlistCollectionId:
                _primaryCollectionByEntry[MediaKind.video.compositeKey(
                  mediaKey,
                )],
          );
        },
        onEntryDelete: (StatPeriodEntryTarget t) =>
            deleteStatPeriodEntry(db, t),
      ),
    );
    // 删过就从 DB 重新聚合：页面上的时段卡 / 排行都得跟着变。
    if (deleted && mounted) await _loadFromDatabase();
  }

  /// 长按 / 右键某个视频那一行 → 确认 → 删除该视频的纯统计并写 video 墓碑防复活，
  /// 再从 DB 重新聚合刷新（TODO-1204 后续）。
  ///
  /// v76：身份感知删除——只删本 tile 展示的行：该 uid 的行 + 本 tile 吸收过的
  /// 删一次会话：段写零（同步安全），再从 DB 重新聚合。
  Future<void> _deleteSession(StudySession s) async {
    await deleteStudySession(appModelNoUpdate.database, s);
    if (mounted) await _loadFromDatabase();
  }

  /// 目标编辑：与阅读 tab、总览 tab 同一份表单、同一个持久化目标（每日学习目标是
  /// **跨域**的一个值，不是每个域各一份）。
  Future<void> _editGoals() async {
    final bool saved = await showStatGoalEditDialog(context, appModelNoUpdate);
    if (saved && mounted) setState(() {});
  }

  /// 改一次会话（日期 / 字数）：走会话编辑的唯一入口（先在 StudyClock 上退役 uid
  /// 再写库），再整页重聚合——改完日期的会话要重新按 gap 归并、重新排序。
  Future<void> _editSession(StudySession s, StudySessionEdit edit) async {
    await applyStudySessionEdit(appModelNoUpdate.database, s, edit);
    if (mounted) await _loadFromDatabase();
  }

  /// 清除这一批会话记录（防呆确认已在按钮里做掉）：只清会话事实，收藏 / 制卡历史 /
  /// 查词计数一个都不动（与逐条删同一边界）。
  Future<void> _clearSessions(List<StudySession> batch) async {
    await deleteStudySessions(appModelNoUpdate.database, batch);
    if (mounted) await _loadFromDatabase();
  }

  /// 点按视频 tile → 这部视频的会话列表 sheet。
  Future<void> _showVideoSessions(VideoStatBookData video) async {
    final String? uid = video.bookUid;
    if (uid == null) return;
    final bool deleted = await showStatSessionsSheet(
      context,
      title: video.title,
      sessions: _sessions.where((StudySession s) => s.mediaKey == uid).toList(),
      titleOf: (StudySession s) => s.title,
      collectionOf: _sessionCollectionName,
      onDelete: (StudySession s) =>
          deleteStudySession(appModelNoUpdate.database, s),
      onEdit: (StudySession s, StudySessionEdit edit) =>
          applyStudySessionEdit(appModelNoUpdate.database, s, edit),
      onClearAll: (List<StudySession> batch) =>
          deleteStudySessions(appModelNoUpdate.database, batch),
    );
    if (deleted && mounted) await _loadFromDatabase();
  }

  /// 同 title 无身份遗留行（[VideoStatBookData.absorbedUnattributed]，与展示层
  /// 是同一次身份分组给出的同一个判据）。同名另一视频的 per-uid 行不再连坐。
  Future<void> _confirmAndDeleteVideo(VideoStatBookData video) async {
    final bool confirmed = await confirmDeleteStatistics(context, video.title);
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.deleteVideoStatisticsForIdentity(
      title: video.title,
      bookUid: video.bookUid,
      includeUnattributed: video.absorbedUnattributed,
    );
    if (!mounted) return;
    await _loadFromDatabase();
  }

  /// TODO-1322：点顶栏「清空统计」→ 危险操作确认 → 清空**全部视频统计**（观看时长 /
  /// 字幕字数 / 时段日志 / 查词 / 制卡计数；不动收藏 / 制卡历史 / 视频），再从 DB 重新聚合刷新。
  Future<void> _confirmAndClearAll() async {
    final bool confirmed = await confirmClearAllStatistics(
      context,
      t.stat_clear_all_video_message,
    );
    if (!confirmed || !mounted) return;
    await appModelNoUpdate.database.clearAllVideoStatistics();
    if (!mounted) return;
    await _loadFromDatabase();
  }

  /// 按视频 tile 的所属合集名（书架同款「主合集」折叠归属，无则 null）。只认
  /// tile 自带的 bookUid（v76 身份分组）：无身份 tile 存在的意义就是「归属不可
  /// 判」——身份解析拒绝归属的东西，合集名不许再按库表回退猜一个（review4-4：
  /// 行宇宙歧义被否决的 orphan tile，库表恰好只剩一个 uid 时会被贴上那个视频的
  /// 合集名）。
  String? _collectionNameForVideo(VideoStatBookData video) {
    final String? bookUid = video.bookUid;
    if (bookUid == null) return null;
    return statCollectionName(
      MediaKind.video.compositeKey(bookUid),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  /// 会话行的所属合集名（BUG-2417：合集里段 title 是分集名，行上得写清是哪部
  /// 作品）。会话自带 bookUid 身份（段 mediaKey），走与 [_collectionNameForVideo]
  /// 同一 'video|<bookUid>' 键契约。
  String? _sessionCollectionName(StudySession s) => s.mediaKey.isEmpty
      ? null
      : statCollectionName(
          MediaKind.video.compositeKey(s.mediaKey),
          _primaryCollectionByEntry,
          _collectionNamesById,
        );

  /// 「按视频」一行（游戏页同款 [buildStatMediaRow]）：会话数 / 查词 · 制卡 · 收藏，
  /// 右侧观看时长；点按进该视频的会话 sheet（无身份遗留组没有会话），长按 / 右键删
  /// 该视频统计。
  Widget _buildVideoTile(VideoStatBookData video) {
    // v76：查词/制卡/收藏数由 computeVideoStats 的同一次身份分组挂在 tile 上，
    // 这里只读——不做任何第二次归并（两套判据 = 计数在同名 tile 间游走）。
    final String? uid = video.bookUid;
    final int sessionCount = uid == null
        ? 0
        : _sessions.where((StudySession s) => s.mediaKey == uid).length;
    return buildStatMediaRow(
      context,
      icon: Icons.movie,
      title: video.title,
      collectionName: _collectionNameForVideo(video),
      meta: t.stat_sessions_count(n: sessionCount),
      meta2:
          '${t.stat_lookup}: ${video.lookups} · ${t.stat_mined}: ${video.mines} · ${t.stat_favorited}: ${video.favorites}',
      trailing: formatStatTime(video.ms),
      onTap: uid == null ? null : () => unawaited(_showVideoSessions(video)),
      onDelete: () => unawaited(_confirmAndDeleteVideo(video)),
    );
  }
}
