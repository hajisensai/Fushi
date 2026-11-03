import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDbStore;
import 'package:fushi_engine/srs/srs_stats.dart' show SrsStatsData, SrsStreak;
import 'package:fushi_engine/srs/srs_stats_loader.dart'
    show SrsStatsBundle, loadSrsStats;
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatActivityRelativeTime, formatStatChars, formatStatTime;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/platform/widget_snapshot_labels.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/stats/stat_window.dart';

/// 快照里每个封面最多探测的候选数 = 书架上限，封面文件探测只对入选的几条做。
const int _kCoverProbeLimit = kWidgetShelfLimit;

/// 从 app 状态收集 Android 桌面小组件快照，并在数据变化时推给 [publisher]。
///
/// 数据口径尽量与首页 dashboard 一致（同一批 provider / 同一批纯函数）：
/// - 书 / 漫画「继续」：`fushiBooksProvider` + [isDashboardContinueBook]，
///   最近阅读时刻取 `bookLastReadAtProvider`。
/// - 视频「继续」：`VideoBookRepository.listForShelf()` 里有断点且没看完的，
///   进度 [dashboardVideoContinueProgress]，封面 [dashboardVideoCoverPath]。
/// - 今日 / 近 7 天：[loadStatFacts] 的完整日面（阅读 + 视频 + 游戏，与首页
///   「今日」卡同一批行），窗口 [StatWindow]。
/// - 复习：provider 跟制卡去向（`srsMiningTarget` + 复习模块开关）：内置 SRS 取
///   [srsDeckListProvider] 顶层牌组计数 + [loadSrsStats]（按修订号 / 日缓存，只在
///   provider 是 fushi 时才读）；Anki 只带包名，计数由原生侧现读。
/// - 目标 / 隐私 / 词汇：AppModel 的每日目标偏好、小组件隐私偏好、最近制卡与收藏词。
///
/// 触发（都经 [requestRefresh] 去抖 / [refreshNow] 立即）：库内数据变化流、
/// 复习修订号变化、界面语言或模块开关变化（[onContextChanged]）、app 进后台与
/// 回前台。采集与发布全程容错——失败只影响小组件，不影响 app。
class WidgetSnapshotSource {
  WidgetSnapshotSource({
    required WidgetRef ref,
    required bool Function() isActive,
    WidgetSnapshotPublisher? publisher,
    this.debounce = const Duration(seconds: 3),
  }) : _ref = ref,
       _isActive = isActive,
       _publisher = publisher ?? WidgetSnapshotPublisher.instance;

  final WidgetRef _ref;
  final bool Function() _isActive;
  final WidgetSnapshotPublisher _publisher;

  /// 数据变化流的去抖：一次阅读 / 观看会连续写多张表，合并成一次采集。
  final Duration debounce;

  StreamSubscription<void>? _dataSubscription;
  ProviderSubscription<int>? _srsSubscription;
  Timer? _debounceTimer;
  String? _contextSignature;
  bool _started = false;
  bool _running = false;
  bool _rerun = false;

  /// 平台没有小组件时整个类不工作（不订阅、不采集）。
  bool get enabled => _publisher.platformSupported;

  /// app 初始化完成后调一次（不要放 build）。重复调用是 no-op。
  void start() {
    if (!enabled || _started || !_isActive()) return;
    _started = true;
    final AppModel appModel = _ref.read(appProvider);
    _dataSubscription = appModel.database.watchDashboardDataChanges().listen(
      (_) => requestRefresh(),
    );
    _srsSubscription = _ref.listenManual<int>(
      srsRevisionProvider,
      (int? _, int __) => requestRefresh(),
    );
    unawaited(refreshNow());
  }

  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(_dataSubscription?.cancel());
    _dataSubscription = null;
    _srsSubscription?.close();
    _srsSubscription = null;
    _started = false;
  }

  /// 根 build 每次重建都可以调：界面语言、模块开关、复习去向、每日目标、小组件隐私
  /// 或激活配置真的变了才排一次采集。
  void onContextChanged(AppModel appModel) {
    if (!enabled || !_started) return;
    final ModuleVisibility modules = appModel.moduleVisibility;
    final ProfileUiState profile = _ref.read(profileViewModelProvider);
    final String signature = <Object?>[
      LocaleSettings.currentLocale.languageTag,
      for (final ModuleId id in ModuleId.values) modules.isEnabled(id) ? 1 : 0,
      appModel.srsMiningTarget.wire,
      appModel.readingGoalDailyChars,
      appModel.studyGoalDailyMinutes,
      appModel.studyGoalDailyReadingMinutes,
      appModel.studyGoalDailyListeningMinutes,
      appModel.studyGoalDailyVideoMinutes,
      appModel.srsGoalDailyReviews,
      appModel.miningGoalDailyCards,
      appModel.widgetPrivacyHideTitles ? 1 : 0,
      appModel.widgetPrivacyHideDefinitions ? 1 : 0,
      appModel.widgetPrivacyHideProfile ? 1 : 0,
      profile.activeProfile?.id,
      profile.activeProfile?.name,
      profile.profiles.length > 1 ? 1 : 0,
    ].join(',');
    if (signature == _contextSignature) return;
    final bool first = _contextSignature == null;
    _contextSignature = signature;
    if (!first) requestRefresh();
  }

  /// 去抖后采集（数据变化流用）。
  void requestRefresh() {
    if (!enabled || !_started) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      unawaited(refreshNow());
    });
  }

  /// 立即采集并发布（进后台 / 回前台用）。同一时刻只跑一轮，跑的时候又来请求就
  /// 在这一轮结束后补跑一次。
  Future<void> refreshNow() async {
    if (!enabled || !_started) return;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_running) {
      _rerun = true;
      return;
    }
    _running = true;
    try {
      do {
        _rerun = false;
        if (!_isActive()) return;
        try {
          final Map<String, Object?> snapshot = await collect();
          if (!_isActive()) return;
          await _publisher.publish(snapshot);
        } on Object catch (error, stack) {
          debugPrint('WidgetSnapshotSource: collect failed: $error\n$stack');
        }
      } while (_rerun);
    } finally {
      _running = false;
    }
  }

  /// 采集一份完整快照（不发布）。
  @visibleForTesting
  Future<Map<String, Object?>> collect() async {
    final AppModel appModel = _ref.read(appProvider);
    final FushiDatabase db = appModel.database;
    final ModuleVisibility modules = appModel.moduleVisibility;
    final DateTime now = DateTime.now();
    final StatWindow window = StatWindow(now);

    final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
    final List<WidgetMediaInput> media = <WidgetMediaInput>[
      if (modules.isEnabled(ModuleId.books) ||
          modules.isEnabled(ModuleId.manga))
        ...await _collectBooks(appModel),
      if (modules.isEnabled(ModuleId.video)) ...await _collectVideos(db, facts),
    ];

    final WidgetSrsInput srs = await _collectSrs(appModel);
    final WidgetImmersionInput immersion = _collectImmersion(facts, window);
    int minedToday = 0;
    // 制卡数口径同统计页：`mining_statistics` 按 (来源, 统计日) 聚合的计数（行很少）。
    for (final MiningStatisticRow m in await db.getAllMiningStatistics()) {
      if (m.dateKey == window.todayKey) minedToday += m.count;
    }
    final Map<String, String> weekdayLabels = await _weekdayLabels(
      window.lastDayKeys(kWidgetWeekDays),
    );
    final ProfileUiState profile = _ref.read(profileViewModelProvider);

    return buildWidgetSnapshot(
      day: window.todayKey,
      generatedAt: now.millisecondsSinceEpoch,
      labels: buildWidgetLabels(),
      categoryLabels: buildWidgetCategoryLabels(),
      goalLabels: buildWidgetGoalLabels(),
      modules: WidgetModulesInput(
        books: modules.isEnabled(ModuleId.books),
        manga: modules.isEnabled(ModuleId.manga),
        video: modules.isEnabled(ModuleId.video),
        lookup: modules.isEnabled(ModuleId.lookup),
        srs: modules.isEnabled(ModuleId.srs),
        music: modules.isEnabled(ModuleId.music),
        games: modules.isEnabled(ModuleId.games),
      ),
      media: await _withCovers(media, appModel),
      immersion: immersion,
      goals: WidgetGoalsInput(
        totalMinutes: appModel.studyGoalDailyMinutes,
        readingMinutes: appModel.studyGoalDailyReadingMinutes,
        listeningMinutes: appModel.studyGoalDailyListeningMinutes,
        videoMinutes: appModel.studyGoalDailyVideoMinutes,
        reviews: appModel.srsGoalDailyReviews,
        minedCards: appModel.miningGoalDailyCards,
        chars: appModel.readingGoalDailyChars,
        minedToday: minedToday,
      ),
      srs: srs,
      vocab: await _collectVocab(db),
      profileName: profile.activeProfile?.name ?? '',
      multiProfile: profile.profiles.length > 1,
      hideTitles: appModel.widgetPrivacyHideTitles,
      hideDefinitions: appModel.widgetPrivacyHideDefinitions,
      hideProfile: appModel.widgetPrivacyHideProfile,
      formatTime: formatStatTime,
      formatChars: formatStatChars,
      formatCount: _formatCount,
      formatAge: (int epochMs) => formatActivityRelativeTime(epochMs, now),
      weekdayLabel: (String key) => weekdayLabels[key] ?? '',
    );
  }

  /// 沉浸四类按统计日聚合（只认书 / 音乐 / 视频 / 游戏，复习不算沉浸）。毫秒与字数
  /// 只留最近 35 天（月 + 周 + 上周环比都在里面），活跃日保留全部历史给连续天数。
  WidgetImmersionInput _collectImmersion(StatFacts facts, StatWindow window) {
    final String oldestKept = window.lastDayKeys(kWidgetMonthDays).first;
    final Map<String, Map<WidgetImmersionCategory, int>> msByDay =
        <String, Map<WidgetImmersionCategory, int>>{};
    final Map<String, int> charsByDay = <String, int>{};
    final Set<String> activeDays = <String>{};
    for (final StatFact f in facts.daily) {
      final WidgetImmersionCategory? category =
          WidgetImmersionCategory.fromMediaKind(f.mediaKind);
      if (category == null) continue;
      if (f.ms > 0 || f.chars > 0 || f.pages > 0) activeDays.add(f.dateKey);
      if (f.dateKey.compareTo(oldestKept) < 0) continue;
      final Map<WidgetImmersionCategory, int> day = msByDay.putIfAbsent(
        f.dateKey,
        () => <WidgetImmersionCategory, int>{},
      );
      day[category] = (day[category] ?? 0) + f.ms;
      charsByDay[f.dateKey] = (charsByDay[f.dateKey] ?? 0) + f.chars;
    }
    return WidgetImmersionInput(
      msByDay: msByDay,
      charsByDay: charsByDay,
      activeDays: activeDays,
    );
  }

  /// provider 规则（不另设开关，见 docs/agent/android-widgets.md）：制卡去向是 Anki
  /// → `anki`；去向是 Fushi 复习且复习模块开着 → `fushi`；其余 → `none`。
  Future<WidgetSrsInput> _collectSrs(AppModel appModel) async {
    if (appModel.srsMiningTarget == SrsMiningTarget.anki) {
      return WidgetSrsInput(
        provider: WidgetSrsProvider.anki,
        label: t.widget_label_provider_anki,
      );
    }
    if (!_ref.read(srsMiningToReviewProvider)) {
      return const WidgetSrsInput();
    }
    final SrsDeckListData? decks = await _ref.read(srsDeckListProvider.future);
    final _SrsStatsDigest? digest = await _srsStatsDigest();
    return WidgetSrsInput(
      provider: WidgetSrsProvider.fushi,
      label: t.widget_label_provider_fushi,
      newCount: decks?.todayNew ?? 0,
      learnCount: decks?.todayLearn ?? 0,
      reviewCount: decks?.todayReview ?? 0,
      reviewedToday: digest?.reviewedToday ?? 0,
      dueTomorrow: digest?.dueTomorrow ?? 0,
      streakCurrent: digest?.streakCurrent ?? 0,
      streakLongest: digest?.streakLongest ?? 0,
      reviewsByDay: digest?.reviewsByDay ?? const <int>[],
    );
  }

  _SrsStatsDigest? _srsStatsCache;

  /// [loadSrsStats] 要读整库复习日志，较重：按（store 实例、修订号、统计日）缓存，
  /// 只有复习数据真变了或翻日才重算。失败 / store 不可用返回 null（计数当 0）。
  Future<_SrsStatsDigest?> _srsStatsDigest() async {
    try {
      final SrsDbStore? store = await _ref.read(srsStoreProvider.future);
      if (store == null) return null;
      // 评分只 bump 本地写入号、不 bump 修订号（复习页里直接回桌面时也要新数字）。
      final String revision =
          '${_ref.read(srsRevisionProvider)}/${_ref.read(srsLocalWriteProvider)}';
      final String day = StatWindow(DateTime.now()).todayKey;
      final _SrsStatsDigest? cached = _srsStatsCache;
      if (cached != null &&
          identical(cached.store, store) &&
          cached.revision == revision &&
          cached.day == day) {
        return cached;
      }
      final SrsStatsBundle bundle = await loadSrsStats(store);
      final SrsStatsData data = bundle.data;
      final Map<int, int> counts = data.countsByDay();
      final SrsStreak streak = data.streak();
      return _srsStatsCache = _SrsStatsDigest(
        store: store,
        revision: revision,
        day: day,
        reviewedToday: data.todayStats().count,
        dueTomorrow: data.futureDue(2).dueTomorrow,
        streakCurrent: streak.current,
        streakLongest: streak.longest,
        // SRS 的日序号与统计日各有各的日界（SRS 默认凌晨 4 点翻日），这里按「SRS
        // 今天往前数 i 天」取，对齐到小组件的「最近 35 天，最旧 → 今天」。
        reviewsByDay: <int>[
          for (int i = kWidgetMonthDays - 1; i >= 0; i--)
            counts[data.today - i] ?? 0,
        ],
      );
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: srs stats failed: $error');
      return null;
    }
  }

  /// 最近制卡 + 最近收藏词各 [kWidgetVocabLimit] 条（窄查询，不读全表）。
  Future<List<WidgetVocabInput>> _collectVocab(FushiDatabase db) async {
    final List<MinedSentenceRow> mined = await db.getRecentMinedSentences(
      kWidgetVocabLimit,
    );
    final List<FavoriteWordRow> favorites = await db.getRecentFavoriteWords(
      kWidgetVocabLimit,
    );
    return <WidgetVocabInput>[
      for (final MinedSentenceRow m in mined)
        WidgetVocabInput(
          term: m.expression,
          reading: m.reading,
          definition: m.glossary,
          sentence: m.sentence,
          source: m.documentTitle ?? '',
          origin: 'mined',
          createdAt: m.createdAt,
        ),
      for (final FavoriteWordRow f in favorites)
        WidgetVocabInput(
          term: f.expression,
          reading: f.reading,
          definition: f.glossary,
          sentence: f.sentence,
          source: f.title,
          origin: 'favorite',
          createdAt: f.createdAt,
        ),
    ];
  }

  String _formatCount(int count) {
    try {
      return NumberFormat.decimalPattern(
        LocaleSettings.currentLocale.languageTag,
      ).format(count);
    } on Object {
      return '$count';
    }
  }

  /// 在读的书 / 漫画。与首页不同的一点：书合集不做「下一卷」推进，每本在读的
  /// 书各算一条。
  Future<List<WidgetMediaInput>> _collectBooks(AppModel appModel) async {
    final List<MediaItem> books = await _ref.read(
      fushiBooksProvider(JapaneseLanguage.instance).future,
    );
    final Map<String, int> lastReadByUid = await _ref.read(
      bookLastReadAtProvider.future,
    );
    final Map<String, String> uidByKey = await _ref.read(
      epubBookUidByKeyProvider.future,
    );
    final Set<String> completed = await _ref.read(
      completedEpubBookKeysProvider.future,
    );
    final ModuleVisibility modules = appModel.moduleVisibility;
    final List<WidgetMediaInput> result = <WidgetMediaInput>[];
    for (final MediaItem item in books) {
      if (!isDashboardContinueBook(item, completed)) continue;
      final WidgetMediaKind kind = _bookKind(item);
      if (!modules.isEnabled(kind.module)) continue;
      final String bookKey =
          ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
          item.mediaIdentifier;
      result.add(
        WidgetMediaInput(
          kind: kind,
          id: item.mediaIdentifier,
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          subtitle: item.author ?? '',
          progress: item.duration > 0 ? item.position / item.duration : 0,
          recentAt: lastReadByUid[uidByKey[bookKey] ?? bookKey] ?? 0,
        ),
      );
    }
    return result;
  }

  WidgetMediaKind _bookKind(MediaItem item) =>
      item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey
      ? WidgetMediaKind.manga
      : WidgetMediaKind.book;

  /// 在看的视频：有断点且没看完。合集不做「下一集」推进（同书）。
  Future<List<WidgetMediaInput>> _collectVideos(
    FushiDatabase db,
    StatFacts facts,
  ) async {
    final List<VideoBookRow> videos = await VideoBookRepository(
      db,
    ).listForShelf();
    final List<VideoBookRow> watching = <VideoBookRow>[
      for (final VideoBookRow v in videos)
        if (v.lastPositionMs > 0 && v.completedAt == null) v,
    ];
    if (watching.isEmpty) return const <WidgetMediaInput>[];
    final Map<String, int> watchAt = <String, int>{};
    for (final StatFact w in facts.dailyVideos) {
      final String uid = w.mediaKey;
      if (uid.isEmpty) continue;
      if (w.lastActiveMs > (watchAt[uid] ?? 0)) watchAt[uid] = w.lastActiveMs;
    }
    final Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(
      <String>[for (final VideoBookRow v in watching) v.videoPath],
    );
    return <WidgetMediaInput>[
      for (final VideoBookRow v in watching)
        WidgetMediaInput(
          kind: WidgetMediaKind.video,
          id: v.bookUid,
          title: v.title,
          progress:
              dashboardVideoContinueProgress(
                completed: false,
                positionMs: v.lastPositionMs,
                durationMs: specs[v.videoPath]?.durationMs,
                currentEpisode: v.currentEpisode,
                playlistEpisodeCount: playlistEpisodeCount(v.playlistJson),
              ).fraction ??
              0,
          recentAt: watchAt[v.bookUid] ?? v.importedAt ?? 0,
          // 视频封面候选先放在 coverPath，真正是否存在在 [_withCovers] 里探测。
          coverPath: v.coverPath ?? '',
        ),
    ];
  }

  /// 只对会入选的前几条解析封面（视频封面探测是异步 IO，网络盘上 stat 可能很慢，见 BUG-3756）：书走与书架同一条
  /// override → 内嵌封面链，视频走 [dashboardVideoCoverPath]。探测不到真实存在的
  /// 本地文件就给空串。
  Future<List<WidgetMediaInput>> _withCovers(
    List<WidgetMediaInput> media,
    AppModel appModel,
  ) async {
    final List<WidgetMediaInput> top = List<WidgetMediaInput>.of(media)
      ..sort(
        (WidgetMediaInput a, WidgetMediaInput b) =>
            b.recentAt.compareTo(a.recentAt),
      );
    final List<WidgetMediaInput> withCovers = <WidgetMediaInput>[];
    for (final WidgetMediaInput m in top.take(_kCoverProbeLimit)) {
      withCovers.add(
        WidgetMediaInput(
          kind: m.kind,
          id: m.id,
          title: m.title,
          subtitle: m.subtitle,
          progress: m.progress,
          recentAt: m.recentAt,
          coverPath: m.kind == WidgetMediaKind.video
              ? await dashboardVideoCoverPath(
                      collectionCovers: const <String?>[],
                      ownCover: m.coverPath,
                      exists: (String path) => File(path).exists(),
                    ) ??
                    ''
              : _bookCoverPath(appModel, m.id),
        ),
      );
    }
    return withCovers;
  }

  String _bookCoverPath(AppModel appModel, String mediaIdentifier) {
    final List<MediaItem> books =
        _ref.read(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
        const <MediaItem>[];
    MediaItem? item;
    for (final MediaItem b in books) {
      if (b.mediaIdentifier == mediaIdentifier) {
        item = b;
        break;
      }
    }
    if (item == null) return '';
    try {
      final File? override = item
          .getMediaSource(appModel: appModel)
          .resolveOverrideThumbnailFile(appModel: appModel, item: item);
      if (override != null && override.existsSync()) return override.path;
      final String? url = item.imageUrl;
      if (url != null && url.startsWith('file://')) {
        final String path = Uri.parse(url).toFilePath();
        if (File(path).existsSync()) return path;
      }
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: cover probe failed: $error');
    }
    return '';
  }

  static Future<void>? _dateSymbols;

  /// 近 7 天的窄星期标签（英文 M T W…，中文 一 二 三…），随 app 内语言；key = 统计日。
  Future<Map<String, String>> _weekdayLabels(List<String> dateKeys) async {
    final String locale = LocaleSettings.currentLocale.languageTag;
    try {
      await (_dateSymbols ??= initializeDateFormatting());
      DateFormat format;
      try {
        format = DateFormat('EEEEE', locale);
      } on ArgumentError {
        format = DateFormat('EEEEE');
      }
      return <String, String>{
        for (final String key in dateKeys)
          key: format.format(FushiDatabase.statDateKeyToDay(key)),
      };
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: weekday labels failed: $error');
      return const <String, String>{};
    }
  }
}

/// 复习统计摘要的缓存条目（见 [WidgetSnapshotSource._srsStatsDigest]）。
class _SrsStatsDigest {
  const _SrsStatsDigest({
    required this.store,
    required this.revision,
    required this.day,
    required this.reviewedToday,
    required this.dueTomorrow,
    required this.streakCurrent,
    required this.streakLongest,
    required this.reviewsByDay,
  });

  final SrsDbStore store;
  final String revision;
  final String day;
  final int reviewedToday;
  final int dueTomorrow;
  final int streakCurrent;
  final int streakLongest;
  final List<int> reviewsByDay;
}
