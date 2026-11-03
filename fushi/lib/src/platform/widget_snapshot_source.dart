import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeNavItemFor;
import 'package:fushi/src/pages/implementations/home_srs_panel.dart'
    show homeSrsPanelVisibleProvider;
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatChars, formatStatTime;
import 'package:fushi/src/pages/implementations/stat_summary.dart'
    show computeReadingStreak;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
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
/// - 复习：[srsDeckListProvider] 顶层牌组的新卡 + 学习中 + 到期之和（首页复习条
///   显示的三个数之和），可见性 [homeSrsPanelVisibleProvider]。
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

  /// 根 build 每次重建都可以调：界面语言或模块开关真的变了才排一次采集。
  void onContextChanged(AppModel appModel) {
    if (!enabled || !_started) return;
    final ModuleVisibility modules = appModel.moduleVisibility;
    final String signature = [
      LocaleSettings.currentLocale.languageTag,
      for (final ModuleId id in ModuleId.values) modules.isEnabled(id) ? 1 : 0,
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

    final bool srsEnabled;
    int srsDue = 0;
    if (_ref.read(srsModuleEnabledProvider)) {
      final SrsDeckListData? decks = await _ref.read(
        srsDeckListProvider.future,
      );
      srsEnabled = _ref.read(homeSrsPanelVisibleProvider);
      if (decks != null) {
        srsDue = decks.todayNew + decks.todayLearn + decks.todayReview;
      }
    } else {
      srsEnabled = false;
    }

    final List<String> weekKeys = window.lastDayKeys(kWidgetWeekDays);
    final Map<String, int> msByDay = <String, int>{};
    int todayMs = 0;
    int todayChars = 0;
    int weekChars = 0;
    for (final StatFact f in facts.daily) {
      if (f.dateKey == window.todayKey) {
        todayMs += f.ms;
        todayChars += f.chars;
      }
      if (weekKeys.contains(f.dateKey)) {
        msByDay[f.dateKey] = (msByDay[f.dateKey] ?? 0) + f.ms;
        weekChars += f.chars;
      }
    }
    // 连续天数口径与阅读统计页一致：只看阅读域（书 + 漫画）的活跃日。
    final Set<String> activeReadingDays = <String>{
      for (final StatFact f in facts.dailyBooks)
        if (f.ms > 0 || f.chars > 0 || f.pages > 0) f.dateKey,
    };

    return buildWidgetSnapshot(
      day: window.todayKey,
      labels: _labels(),
      moduleBooks: modules.isEnabled(ModuleId.books),
      moduleManga: modules.isEnabled(ModuleId.manga),
      moduleVideo: modules.isEnabled(ModuleId.video),
      moduleLookup: modules.isEnabled(ModuleId.lookup),
      media: await _withCovers(media, appModel),
      today: WidgetTodayInput(
        ms: todayMs,
        chars: todayChars,
        goalChars: appModel.readingGoalDailyChars,
        streak: computeReadingStreak(activeReadingDays, now),
      ),
      week: WidgetWeekInput(
        minutes: <int>[
          for (final String key in weekKeys) (msByDay[key] ?? 0) ~/ 60000,
        ],
        days: await _weekdayLabels(weekKeys),
        totalMs: msByDay.values.fold<int>(0, (int a, int b) => a + b),
        totalChars: weekChars,
      ),
      srsEnabled: srsEnabled,
      srsDue: srsDue,
      formatTime: formatStatTime,
      formatChars: formatStatChars,
    );
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

  WidgetSnapshotLabels _labels() {
    String nav(HomeTab tab) => homeNavItemFor(tab).label;
    return WidgetSnapshotLabels(
      kindBook: nav(HomeTab.books),
      kindManga: nav(HomeTab.manga),
      kindVideo: nav(HomeTab.video),
      resume: t.home_continue,
      today: t.stat_today,
      streak: t.stat_streak,
      srsDue: t.srs_count_review,
      srsOff: t.widget_label_srs_off,
      review: t.home_srs_panel_start,
      srsDone: t.home_srs_panel_done,
      recent: t.widget_label_recent,
      weekly: t.stat_this_week,
      books: nav(HomeTab.books),
      manga: nav(HomeTab.manga),
      video: nav(HomeTab.video),
      lookup: nav(HomeTab.dictionaries),
      openToSetUp: t.widget_label_open_to_set_up,
    );
  }

  static Future<void>? _dateSymbols;

  /// 近 7 天的窄星期标签（英文 M T W…，中文 一 二 三…），随 app 内语言。
  Future<List<String>> _weekdayLabels(List<String> dateKeys) async {
    final String locale = LocaleSettings.currentLocale.languageTag;
    try {
      await (_dateSymbols ??= initializeDateFormatting());
      DateFormat format;
      try {
        format = DateFormat('EEEEE', locale);
      } on ArgumentError {
        format = DateFormat('EEEEE');
      }
      return <String>[
        for (final String key in dateKeys)
          format.format(FushiDatabase.statDateKeyToDay(key)),
      ];
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: weekday labels failed: $error');
      return const <String>[];
    }
  }
}
