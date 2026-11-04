import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryDownloadQueue, DiscoveryDownloadStatus, DiscoveryDownloadTask;
import 'package:fushi_engine/media/torrent/torrent_backend.dart'
    show TorrentSnapshot;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDbStore;
import 'package:fushi_engine/srs/srs_stats.dart' show SrsStatsData, SrsStreak;
import 'package:fushi_engine/srs/srs_stats_loader.dart'
    show SrsStatsBundle, loadSrsStats;
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart'
    show AudiobookPlayerController;
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show SessionBookInfo;
import 'package:fushi/src/media/music/music_history.dart' show MusicRecentTrack;
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart'
    show MusicPlayerEngine;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatActivityRelativeTime, formatStatChars, formatStatTime;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_cover_cache.dart';
import 'package:fushi/src/platform/widget_progress.dart';
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/platform/widget_snapshot_labels.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart'
    show ServerContinueCandidate, ServerContinueSource;
import 'package:fushi/src/utils/misc/dashboard_server_continue_feed.dart'
    show ServerContinueFeed;
import 'package:fushi/src/utils/misc/dashboard_server_continue_gates.dart'
    show serverContinueGates;
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart'
    show audiobookshelfTabServers;
import 'package:fushi/src/media/video/media_server/media_server_config.dart'
    show MediaServerConfig;
import 'package:fushi/src/media/media_source.dart';

/// 快照里每个封面最多探测的候选数 = 书架上限，封面文件探测只对入选的几条做。
const int _kCoverProbeLimit = kWidgetShelfLimit;

/// 从 app 状态收集桌面小组件快照（Android / iOS / macOS 同一份），并在数据变化时推给 [publisher]。
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
/// - 正在播放：音乐引擎 / 有声书会话的实时状态（没有就退回最近播放的一首歌，
///   `playing=false`）。曲目或播放 / 暂停变化走 [_onPlaybackChanged] **立即**重发，
///   不经去抖；进度不触发发布（原生侧按 `positionMs + (now - updatedAt)` 外推）。
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
  AppModel? _playbackModel;

  /// 最近一次采集 / 重发的完整快照；播放变化时只替换其中的 `nowPlaying` 立即重发。
  Map<String, Object?>? _lastSnapshot;
  String? _playbackKeyLast;
  bool _nowPlayingRunning = false;
  bool _nowPlayingRerun = false;
  ProviderSubscription<int>? _srsSubscription;
  Timer? _debounceTimer;

  // ---- Downloads widget: light republish loop (see [_scheduleDownloadsTick]) ----
  StreamSubscription<void>? _downloadsSubscription;
  StreamSubscription<void>? _serverFeedSubscription;
  DiscoveryDownloadQueue? _downloadQueue;
  Timer? _downloadsTimer;
  DateTime? _downloadsPublishedAt;
  final WidgetCoverCache _coverCache = WidgetCoverCache();
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
    appModel.musicSession.addListener(_onPlaybackChanged);
    appModel.audiobookSession.addListener(_onPlaybackChanged);
    _playbackModel = appModel;
    _playbackKeyLast = _playbackKey(appModel);
    _startProgressFeeds(appModel);
    unawaited(refreshNow());
  }

  /// Downloads: the durable job table and the direct-link queue say "something
  /// changed" (never a per-byte stream: ticks are throttled to one per 5 s and only
  /// run while a task is running). On deck: the dashboard's own server feed says a
  /// fetch finished; the widget sends no request of its own.
  void _startProgressFeeds(AppModel appModel) {
    _downloadsSubscription = appModel.database.watchVideoDownloadJobs().listen(
      (_) => _onDownloadsSignal(),
    );
    if (StoreRestrictedCapability.downloads.isAvailable) {
      _downloadQueue = appModel.discoveryDownloadQueue
        ..addListener(_onDownloadsSignal);
    }
    _serverFeedSubscription = ServerContinueFeed.of(
      appModel.database,
    ).updates.listen((_) => requestRefresh());
  }

  void dispose() {
    final AppModel? model = _playbackModel;
    if (model != null) {
      model.musicSession.removeListener(_onPlaybackChanged);
      model.audiobookSession.removeListener(_onPlaybackChanged);
    }
    _playbackModel = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _downloadsTimer?.cancel();
    _downloadsTimer = null;
    unawaited(_downloadsSubscription?.cancel());
    _downloadsSubscription = null;
    unawaited(_serverFeedSubscription?.cancel());
    _serverFeedSubscription = null;
    _downloadQueue?.removeListener(_onDownloadsSignal);
    _downloadQueue = null;
    _lastSnapshot = null;
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
          _lastSnapshot = snapshot;
          _downloadsPublishedAt = DateTime.now();
          await _publisher.publish(snapshot);
          _afterPublish(snapshot);
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
        ...await _collectBooks(appModel, facts, window),
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

    final Map<String, Object?> snapshot = buildWidgetSnapshot(
      day: window.todayKey,
      generatedAt: now.millisecondsSinceEpoch,
      labels: buildWidgetLabels(),
      categoryLabels: buildWidgetCategoryLabels(),
      goalLabels: buildWidgetGoalLabels(),
      modules: _modulesInput(modules),
      nowPlaying: await _collectNowPlaying(appModel),
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
      formatTimeLeft: (int ms) =>
          t.widget_label_time_left(time: formatStatTime(ms)),
      downloads: await _collectDownloads(appModel),
      onDeck: await _collectOnDeck(appModel),
    );
    _lastSnapshot = snapshot;
    return snapshot;
  }

  WidgetModulesInput _modulesInput(ModuleVisibility modules) =>
      WidgetModulesInput(
        books: modules.isEnabled(ModuleId.books),
        manga: modules.isEnabled(ModuleId.manga),
        video: modules.isEnabled(ModuleId.video),
        lookup: modules.isEnabled(ModuleId.lookup),
        srs: modules.isEnabled(ModuleId.srs),
        music: modules.isEnabled(ModuleId.music),
        games: modules.isEnabled(ModuleId.games),
      );

  // ── 正在播放 ────────────────────────────────────────────────────────────

  /// 当前「谁在出声」。优先级：正在播的音乐 > 正在播的有声书 > 暂停着的音乐 / 有声书
  /// （音乐在前：它与有声书互斥，同时有会话时音乐是后认领的）> 无（退回最近播放）。
  _LivePlayback? _livePlayback(AppModel appModel) {
    final MusicPlayerEngine engine = appModel.musicSession.engine;
    final AudiobookPlayerController? book =
        appModel.audiobookSession.controller;
    final MusicPlayItem? track = engine.current;
    if (track != null && engine.isPlaying) {
      return _LivePlayback.music(track, true);
    }
    if (book != null && book.isPlaying) {
      return _LivePlayback.audiobook(book, true);
    }
    if (track != null) return _LivePlayback.music(track, false);
    if (book != null && appModel.audiobookSession.book != null) {
      return _LivePlayback.audiobook(book, false);
    }
    return null;
  }

  /// 触发立即重发的最小身份：种类 + 曲目 / 书 + 播放态 + 能否跳曲。进度不在里面。
  String _playbackKey(AppModel appModel) {
    final _LivePlayback? live = _livePlayback(appModel);
    if (live == null) return 'idle';
    if (live.track != null) {
      final MusicPlayerEngine engine = appModel.musicSession.engine;
      return 'music|${live.track!.trackUid}|${live.playing}|${engine.queue.length > 1}';
    }
    return 'audiobook|${appModel.audiobookSession.book?.bookKey}|${live.playing}';
  }

  void _onPlaybackChanged() {
    final AppModel? model = _playbackModel;
    if (!enabled || !_started || model == null || !_isActive()) return;
    final String key = _playbackKey(model);
    if (key == _playbackKeyLast) return;
    _playbackKeyLast = key;
    unawaited(_publishNowPlaying());
  }

  /// 只替换 `nowPlaying` 并立即发布（绕过 [debounce]）。还没有完整快照时走一次完整采集。
  Future<void> _publishNowPlaying() async {
    if (_nowPlayingRunning) {
      _nowPlayingRerun = true;
      return;
    }
    _nowPlayingRunning = true;
    try {
      do {
        _nowPlayingRerun = false;
        final Map<String, Object?>? base = _lastSnapshot;
        if (base == null) {
          await refreshNow();
          return;
        }
        if (!_isActive()) return;
        final AppModel appModel = _ref.read(appProvider);
        final WidgetNowPlayingInput? input = await _collectNowPlaying(appModel);
        if (!_isActive()) return;
        final Map<String, Object?> next = <String, Object?>{
          ...base,
          'generatedAt': DateTime.now().millisecondsSinceEpoch,
          'nowPlaying': buildWidgetNowPlaying(
            input,
            _modulesInput(appModel.moduleVisibility),
          ),
        };
        _lastSnapshot = next;
        await _publisher.publish(next);
      } while (_nowPlayingRerun);
    } on Object catch (error, stack) {
      debugPrint('WidgetSnapshotSource: nowPlaying failed: $error\n$stack');
    } finally {
      _nowPlayingRunning = false;
    }
  }

  Future<WidgetNowPlayingInput?> _collectNowPlaying(AppModel appModel) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final _LivePlayback? live = _livePlayback(appModel);
    try {
      if (live != null && live.track != null) {
        final MusicPlayerEngine engine = appModel.musicSession.engine;
        final MusicPlayItem item = live.track!;
        return WidgetNowPlayingInput(
          kind: WidgetNowPlayingKind.music,
          title: item.title,
          subtitle: item.artist ?? '',
          coverPath: await _widgetCoverFile(item.coverPath),
          positionMs: engine.position.inMilliseconds,
          durationMs: engine.duration?.inMilliseconds ?? item.durationMs ?? 0,
          playing: live.playing,
          updatedAt: now,
          link: kWidgetMusicPlayerLink,
          canSkipTrack: engine.queue.length > 1,
        );
      }
      if (live != null && live.book != null) {
        final SessionBookInfo? info = appModel.audiobookSession.book;
        if (info != null) {
          final AudiobookPlayerController controller = live.book!;
          return WidgetNowPlayingInput(
            kind: WidgetNowPlayingKind.audiobook,
            title: info.title,
            subtitle: info.author ?? '',
            coverPath: await _widgetCoverFile(info.coverPath),
            positionMs: controller.globalPosition.inMilliseconds,
            durationMs: controller.totalDuration.inMilliseconds,
            playing: live.playing,
            updatedAt: now,
            link: WidgetContinueLink(
              kind: WidgetMediaKind.book,
              id: info.mediaIdentifier,
            ).toUri(),
            canSkipTrack: true,
            skipSeconds: appModel.audiobookSession.skipActionSeconds(),
          );
        }
      }
      // 没有活动会话：显示最近播放的一首歌（暂停态，按钮点按会拉起 app）。
      final List<MusicRecentTrack> recent = await appModel.musicSession
          .recentTracks(limit: 1);
      if (recent.isEmpty) return null;
      final MusicPlayItem item = recent.first.item;
      return WidgetNowPlayingInput(
        kind: WidgetNowPlayingKind.music,
        title: item.title,
        subtitle: item.artist ?? '',
        coverPath: await _widgetCoverFile(item.coverPath),
        durationMs: item.durationMs ?? 0,
        updatedAt: now,
        link: kWidgetMusicPlayerLink,
      );
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: nowPlaying collect failed: $error');
      return null;
    }
  }

  /// 小组件能直接解码的本地封面文件。本地文件原样用（原生侧自己降采样）；http(s)
  /// 封面（媒体服务器 / 在线音源）下载到缓存目录一次，按 URL 哈希命名。拿不到给空串。
  Future<String> _widgetCoverFile(String? cover) async {
    if (cover == null || cover.isEmpty) return '';
    try {
      if (cover.startsWith('http://') || cover.startsWith('https://')) {
        final Directory dir = Directory(
          '${(await getTemporaryDirectory()).path}/widget_now_playing',
        );
        final File file = File(
          '${dir.path}/${sha1.convert(cover.codeUnits).toString()}.img',
        );
        if (await file.exists() && await file.length() > 0) return file.path;
        // 走应用统一出口（BUG-1498）：公网音源封面经用户代理，局域网媒体服务器
        // 由 isDirectProxyTarget 闸门判 DIRECT，行为与裸 client 等价。
        final HttpClient client = createAppHttpClient(
          connectionTimeout: const Duration(seconds: 5),
        );
        try {
          final HttpClientRequest request = await client
              .getUrl(Uri.parse(cover))
              .timeout(const Duration(seconds: 6));
          final HttpClientResponse response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          if (response.statusCode != 200 ||
              response.contentLength > _kCoverMaxBytes) {
            await response.drain<void>();
            return '';
          }
          final BytesBuilder bytes = BytesBuilder(copy: false);
          await for (final List<int> chunk in response.timeout(
            const Duration(seconds: 8),
          )) {
            bytes.add(chunk);
            if (bytes.length > _kCoverMaxBytes) return '';
          }
          await dir.create(recursive: true);
          // 只留最近几张，避免换曲不断堆文件。
          final List<File> old = <File>[
            await for (final FileSystemEntity e in dir.list())
              if (e is File) e,
          ];
          if (old.length >= 8) {
            for (final File f in old) {
              await f.delete();
            }
          }
          await file.writeAsBytes(bytes.takeBytes(), flush: true);
          return file.path;
        } finally {
          client.close(force: true);
        }
      }
      final String path = cover.startsWith('file://')
          ? Uri.parse(cover).toFilePath()
          : cover;
      return await File(path).exists() ? path : '';
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: now playing cover failed: $error');
      return '';
    }
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

  // ---------------------------------------------------------------------------
  // Downloads widget
  // ---------------------------------------------------------------------------

  void _onDownloadsSignal() {
    if (!enabled || !_started) return;
    _scheduleDownloadsTick();
  }

  /// After a full publish: keep the light loop going only while a task runs.
  void _afterPublish(Map<String, Object?> snapshot) {
    final Object? block = snapshot['downloads'];
    if (block is Map<String, Object?> &&
        ((block['running'] as int?) ?? 0) > 0) {
      _scheduleDownloadsTick();
    }
  }

  /// At most one pending timer, firing at most every
  /// [kWidgetDownloadsPublishInterval] since the last publish. No timer exists
  /// while idle: a tick re-arms itself only when it saw a running task.
  void _scheduleDownloadsTick() {
    if (_downloadsTimer != null) return;
    final Duration delay =
        widgetDownloadsPublishDelay(
          lastPublishedAt: _downloadsPublishedAt,
          now: DateTime.now(),
        ) ??
        Duration.zero;
    _downloadsTimer = Timer(delay, () {
      _downloadsTimer = null;
      unawaited(_downloadsTick());
    });
  }

  /// Rebuilds only the `downloads` block of the last full snapshot (no stats /
  /// vocab / SRS re-collection) and republishes it.
  Future<void> _downloadsTick() async {
    if (!enabled || !_started || !_isActive()) return;
    final Map<String, Object?>? base = _lastSnapshot;
    if (base == null) {
      unawaited(refreshNow());
      return;
    }
    // A full refresh in flight publishes the downloads block itself.
    if (_running) return;
    try {
      final WidgetDownloadsInput input = await _collectDownloads(
        _ref.read(appProvider),
      );
      if (!_isActive()) return;
      final Map<String, Object?> next = <String, Object?>{
        ...base,
        'generatedAt': DateTime.now().millisecondsSinceEpoch,
        'downloads': buildWidgetDownloadsJson(input),
      };
      _lastSnapshot = next;
      _downloadsPublishedAt = DateTime.now();
      await _publisher.publish(next);
      if (input.hasActive) _scheduleDownloadsTick();
    } on Object catch (error) {
      debugPrint('WidgetSnapshotSource: downloads tick failed: $error');
    }
  }

  /// Unfinished tasks of the download center that have a local, cheap source:
  /// durable video/torrent jobs (live progress + speed from the torrent backend
  /// for the active ones) and the direct-link queue. Manga catalog downloads,
  /// remote-host and transcription tasks are not included.
  Future<WidgetDownloadsInput> _collectDownloads(AppModel appModel) async {
    if (!StoreRestrictedCapability.downloads.isAvailable ||
        !appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
      return const WidgetDownloadsInput(enabled: false);
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int failureCutoff =
        now - kWidgetDownloadsFailureMaxAge.inMilliseconds;
    final List<WidgetDownloadTaskInput> tasks = <WidgetDownloadTaskInput>[];

    final List<VideoDownloadJobRow> jobs = await appModel.database
        .getVideoDownloadJobs();
    final List<VideoDownloadJobRow> active = <VideoDownloadJobRow>[
      for (final VideoDownloadJobRow j in jobs)
        if (j.lifecycle == VideoDownloadJobLifecycle.active) j,
    ];
    Map<String, TorrentSnapshot> snapshots = const <String, TorrentSnapshot>{};
    if (active.isNotEmpty) {
      try {
        snapshots =
            await appModel.videoDownloadPipelineService
                ?.loadTaskSnapshots(active)
                .timeout(const Duration(seconds: 4)) ??
            snapshots;
      } on Object catch (error) {
        // Live numbers are decoration: fall back to the durable stage progress.
        debugPrint('WidgetSnapshotSource: torrent snapshots failed: $error');
      }
    }
    for (final VideoDownloadJobRow job in jobs) {
      final TorrentSnapshot? snap = snapshots[job.jobId];
      final WidgetDownloadState? state = widgetDownloadStateForJob(
        lifecycle: job.lifecycle,
        backendState: snap?.state,
      );
      if (state == null) continue;
      if (state == WidgetDownloadState.failed &&
          job.updatedAt < failureCutoff) {
        continue;
      }
      tasks.add(
        WidgetDownloadTaskInput(
          id: job.jobId,
          title: job.title,
          state: state,
          progress: snap?.progress ?? job.stageProgress,
          downRateBps: snap?.downRateBps ?? 0,
          createdAt: job.createdAt,
        ),
      );
    }

    for (final DiscoveryDownloadTask task
        in appModel.discoveryDownloadQueue.tasks) {
      final WidgetDownloadState? state = switch (task.status) {
        DiscoveryDownloadStatus.running => WidgetDownloadState.active,
        DiscoveryDownloadStatus.queued ||
        DiscoveryDownloadStatus.waitingRetry => WidgetDownloadState.queued,
        DiscoveryDownloadStatus.failed =>
          task.createdAt < failureCutoff ? null : WidgetDownloadState.failed,
        DiscoveryDownloadStatus.done ||
        DiscoveryDownloadStatus.cancelled => null,
      };
      if (state == null) continue;
      final int? total = task.totalBytes;
      tasks.add(
        WidgetDownloadTaskInput(
          id: 'direct:${task.taskId}',
          title: task.item.title,
          state: state,
          progress: total != null && total > 0
              ? task.receivedBytes / total
              : null,
          createdAt: task.createdAt,
        ),
      );
    }
    return WidgetDownloadsInput(tasks: tasks);
  }

  // ---------------------------------------------------------------------------
  // On deck widget
  // ---------------------------------------------------------------------------

  /// In-progress items of the user's media servers, taken from the **dashboard's
  /// own** [ServerContinueFeed] cache (the same Jellyfin / Emby / Plex /
  /// Audiobookshelf fetch Home > Continue does, behind the same opt-in gates):
  /// the widget issues no server request. Until Home has loaded once in this
  /// process the cache is empty and the list is empty too.
  Future<WidgetOnDeckInput> _collectOnDeck(AppModel appModel) async {
    final ModuleVisibility modules = appModel.moduleVisibility;
    final ({bool mediaServers, bool audiobookshelf, String signature}) gates =
        serverContinueGates(
          prefs: appModel.isPreferencesReady ? appModel.prefsRepo : null,
          visibility: appModel.moduleVisibility,
        );
    bool hasMedia = false;
    if (modules.isEnabled(ModuleId.video)) {
      try {
        final List<MediaServerConfig> configs = await SyncRepository(
          appModel.database,
        ).getMediaServers();
        hasMedia = configs.isNotEmpty;
      } on Object catch (error) {
        debugPrint('WidgetSnapshotSource: media server configs failed: $error');
      }
    }
    final bool hasAbs =
        modules.isEnabled(ModuleId.books) &&
        audiobookshelfTabServers(
          appModel.prefsRepo.discoveryAudiobookshelfServers,
        ).isNotEmpty;
    if (!hasMedia && !hasAbs) return const WidgetOnDeckInput();
    final bool media = hasMedia && gates.mediaServers;
    final bool abs = hasAbs && gates.audiobookshelf;
    if (!media && !abs) {
      return const WidgetOnDeckInput(state: WidgetOnDeckState.off);
    }
    final List<ServerContinueCandidate> candidates =
        <ServerContinueCandidate>[
          for (final ServerContinueCandidate c in ServerContinueFeed.of(
            appModel.database,
          ).current)
            if (c.source == ServerContinueSource.mediaServer ? media : abs) c,
        ]..sort(
          (ServerContinueCandidate a, ServerContinueCandidate b) =>
              b.recentMs.compareTo(a.recentMs),
        );
    final List<ServerContinueCandidate> top = candidates
        .take(kWidgetOnDeckLimit)
        .toList();
    // Covers are local files; slow servers only cost the cover (time-boxed).
    final Map<String, String> covers = await _coverCache.resolve(top);
    return WidgetOnDeckInput(
      state: WidgetOnDeckState.ok,
      items: <WidgetOnDeckItemInput>[
        for (final ServerContinueCandidate c in top)
          WidgetOnDeckItemInput(
            source: c.source == ServerContinueSource.mediaServer
                ? WidgetServerSource.mediaServer
                : WidgetServerSource.audiobookshelf,
            serverId: c.serverId,
            serverName: c.serverName,
            itemId: c.itemId,
            title: c.title,
            collectionName: c.collectionName,
            recentMs: c.recentMs,
            progress: c.progress,
            coverPath: covers[c.key] ?? '',
          ),
      ],
    );
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
  Future<List<WidgetMediaInput>> _collectBooks(
    AppModel appModel,
    StatFacts facts,
    StatWindow window,
  ) async {
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
    // Reading-speed samples: non-manga book days of the last
    // [kWidgetSpeedWindowDays] stat days that logged both time and characters.
    final String sinceKey = window.lastDayKeys(kWidgetSpeedWindowDays).first;
    final List<WidgetSpeedSample> speedSamples = <WidgetSpeedSample>[
      for (final StatFact f in facts.daily)
        if (f.isBook &&
            !f.isManga &&
            f.ms > 0 &&
            f.chars > 0 &&
            f.dateKey.compareTo(sinceKey) >= 0)
          WidgetSpeedSample(
            mediaKey: f.mediaKey,
            dateKey: f.dateKey,
            ms: f.ms,
            chars: f.chars,
          ),
    ];
    for (final MediaItem item in books) {
      if (!isDashboardContinueBook(item, completed)) continue;
      final WidgetMediaKind kind = _bookKind(item);
      if (!modules.isEnabled(kind.module)) continue;
      final String bookKey =
          ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
          item.mediaIdentifier;
      // `MediaItem.position / duration` are in characters only for text books whose
      // chapter sizes are known (`ReaderFushiSource._bookToMediaItem` sets
      // `sourceMetadata` exactly then); otherwise they are pages / chapters and no
      // time-left estimate is made (never guessed).
      final int? remainingMs =
          kind == WidgetMediaKind.book &&
              item.sourceMetadata != null &&
              item.duration > 1
          ? widgetRemainingReadingMs(
              totalChars: item.duration,
              positionChars: item.position,
              charsPerMs: computeWidgetReadingSpeeds(
                speedSamples,
                bookKey: bookKey,
                sinceDateKey: sinceKey,
              ).best,
            )
          : null;
      result.add(
        WidgetMediaInput(
          kind: kind,
          id: item.mediaIdentifier,
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          subtitle: item.author ?? '',
          progress: item.duration > 0 ? item.position / item.duration : 0,
          recentAt: lastReadByUid[uidByKey[bookKey] ?? bookKey] ?? 0,
          remainingMs: remainingMs,
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
          // Real playback time: duration - position of the single file. Playlists
          // (several episodes in one row) have no whole-playlist duration: omitted.
          remainingMs: playlistEpisodeCount(v.playlistJson) >= 2
              ? null
              : widgetRemainingPlaybackMs(
                  durationMs: specs[v.videoPath]?.durationMs,
                  positionMs: v.lastPositionMs,
                ),
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
          remainingMs: m.remainingMs,
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

/// 下载封面的体积上限（字节）。
const int _kCoverMaxBytes = 4 * 1024 * 1024;

/// 此刻活动的播放会话（音乐曲目 或 有声书控制器）。
class _LivePlayback {
  const _LivePlayback.music(this.track, this.playing) : book = null;
  const _LivePlayback.audiobook(this.book, this.playing) : track = null;

  final MusicPlayItem? track;
  final AudiobookPlayerController? book;
  final bool playing;
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
