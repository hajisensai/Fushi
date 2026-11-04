import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart' show FushiCardFields;
import 'package:fushi_core/fushi_core.dart'
    show FavoriteWordRow, FushiDatabase, MiningStatisticRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatChars, formatStatTime;
import 'package:fushi/src/pages/implementations/stat_summary.dart'
    show computeReadingStreak;
import 'package:fushi/src/platform/home_widgets/home_widget_channel.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_continue_feed.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_covers.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_link.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_live_activities.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_sections.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_snapshot.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/stats/stat_window.dart';

/// iOS / macOS 主屏小组件 + Live Activity（macOS 菜单栏播放条）的宿主，挂在 app 根上。
///
/// 快照什么时候重写：首页「继续」重算了 / 首页重新聚合了统计 / 复习数据变了（
/// [srsRevisionProvider]）/ 有声书会话换了书 / app 退到后台（立即写，保证小组件拿到的是
/// 离开时的样子）。前台的变化合并成一次，最多每 [_foregroundDebounce] 写一回。
class HomeWidgetsHost extends ConsumerStatefulWidget {
  const HomeWidgetsHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HomeWidgetsHost> createState() => HomeWidgetsHostState();
}

class HomeWidgetsHostState extends ConsumerState<HomeWidgetsHost>
    with WidgetsBindingObserver {
  /// 深链路由（`runHomeWidgetLink`）找宿主用；同一时刻只有一个根宿主。
  static HomeWidgetsHostState? current;

  static const Duration _foregroundDebounce = Duration(seconds: 8);

  final HomeWidgetChannel _channel = HomeWidgetChannel();
  final HomeWidgetContinueFeed _feed = HomeWidgetContinueFeed.instance;
  bool _started = false;
  Directory? _dir;
  HomeWidgetCoverWriter? _covers;
  HomeWidgetLiveActivities? _live;
  AudiobookSession? _session;
  String? _sessionBookKey;
  Timer? _debounce;
  bool _writing = false;
  bool _dirty = false;

  /// 最近一本有声书（会话没了也保留，「接着听」用）；启动时从上一份快照读回。
  HomeWidgetContinueItem? _lastAudiobook;

  /// SRS 统计投影（大集合要几百毫秒）只在内容指纹变了才重读。
  String? _srsStatsFingerprint;
  ({List<int> learningDueAts, int reviewsNextDay, int? averageMs})?
  _srsStatsCache;

  /// 「接着听」在没有会话时打开哪本：最近那本有声书在首页「继续」里的键。
  String? get lastAudiobookContinueKey {
    final HomeWidgetContinueItem? item = _lastAudiobook;
    return item == null ? null : 'book:${item.id}';
  }

  Future<bool> resumeAudiobook() async =>
      await _live?.resumeAudiobook() ?? false;

  @override
  void initState() {
    super.initState();
    current = this;
  }

  @override
  void dispose() {
    if (identical(current, this)) current = null;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _feed.items.removeListener(_onFeed);
    _feed.dashboardReloads.removeListener(_onFeed);
    _session?.removeListener(_onSession);
    _live?.dispose();
    _channel.setActionHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (HomeWidgetChannel.supported) {
      final bool ready = ref.watch(
        appProvider.select((AppModel m) => m.isInitialised),
      );
      if (ready && !_started) {
        _started = true;
        unawaited(_start());
      }
      ref.listen<int>(srsRevisionProvider, (_, __) => _schedule());
    }
    return widget.child;
  }

  Future<void> _start() async {
    final AppModel app = ref.read(appProvider);
    WidgetsBinding.instance.addObserver(this);
    _channel.setActionHandler(_onAction);
    final String? path = await _channel.containerPath();
    if (!mounted) return;
    if (path != null) {
      _dir = Directory(path);
      _covers = HomeWidgetCoverWriter(_dir!);
      _lastAudiobook = await _readPreviousAudiobook();
    }
    _live = HomeWidgetLiveActivities(appModel: app, channel: _channel)
      ..activityCoverResolver = _activityCover
      ..start();
    _feed.items.addListener(_onFeed);
    _feed.dashboardReloads.addListener(_onFeed);
    _session = app.audiobookSession..addListener(_onSession);
    _schedule(immediate: true);
  }

  // ── 触发 ──────────────────────────────────────────────────────────

  void _onFeed() => _schedule();

  void _onSession() {
    final String? key = _session?.book?.bookKey;
    if (key == _sessionBookKey) return;
    _sessionBookKey = key;
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool background =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    _live?.setBackgrounded(background);
    if (background) _schedule(immediate: true);
  }

  void _schedule({bool immediate = false}) {
    if (_dir == null) return;
    _debounce?.cancel();
    if (immediate) {
      unawaited(_write());
    } else {
      _debounce = Timer(_foregroundDebounce, () => unawaited(_write()));
    }
  }

  Future<bool> _onAction(String action, String? argument) async {
    switch (action) {
      case 'playback':
        return await _live?.handlePlaybackAction(argument) ?? false;
      case 'resumeAudiobook':
        return resumeAudiobook();
    }
    return false;
  }

  // ── 写快照 ────────────────────────────────────────────────────────

  Future<void> _write() async {
    final Directory? dir = _dir;
    final HomeWidgetCoverWriter? covers = _covers;
    if (dir == null || covers == null || !mounted) return;
    if (_writing) {
      _dirty = true;
      return;
    }
    _writing = true;
    try {
      final HomeWidgetSnapshot snapshot = await _buildSnapshot(covers);
      await dir.create(recursive: true);
      final File tmp = File('${dir.path}/snapshot.json.tmp');
      await tmp.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
      await tmp.rename('${dir.path}/snapshot.json');
      await covers.prune(<String>{
        for (final HomeWidgetContinueItem item in snapshot.continueItems)
          ?item.cover,
        ?snapshot.audiobook?.cover,
        ..._activityCovers,
      });
      await _channel.reloadWidgets();
    } on Object catch (e, stack) {
      debugPrint('[home-widgets] snapshot write failed: $e\n$stack');
    } finally {
      _writing = false;
      if (_dirty && mounted) {
        _dirty = false;
        _schedule();
      }
    }
  }

  Future<HomeWidgetSnapshot> _buildSnapshot(
    HomeWidgetCoverWriter covers,
  ) async {
    final AppModel app = ref.read(appProvider);
    final DateTime now = DateTime.now();
    final List<HomeWidgetContinueItem> continueItems = await _continueItems(
      covers,
    );
    final HomeWidgetContinueItem? audiobook = await _audiobookItem(covers);
    return HomeWidgetSnapshot(
      generatedAt: now.millisecondsSinceEpoch,
      labels: _labels(),
      srs: await _guard('srs', () => _srsSection(now)),
      study: await _guard('study', () => _studySection(app.database, now)),
      continueItems: continueItems,
      word: await _guard('word', () => _wordOfDay(app.database, now)),
      audiobook: audiobook,
    );
  }

  /// 单段失败不拖垮整份快照（那段显示空态，其余照常）。
  Future<T?> _guard<T>(String label, Future<T?> Function() body) async {
    try {
      return await body();
    } on Object catch (e) {
      debugPrint('[home-widgets] $label section skipped: $e');
      return null;
    }
  }

  Map<String, String> _labels() => <String, String>{
    'empty': t.home_widget_empty,
    'srs_title': t.home_widget_srs_title,
    'srs_new': t.home_widget_srs_new,
    'srs_learning': t.home_widget_srs_learning,
    'srs_review': t.home_widget_srs_review,
    'study_title': t.home_widget_study_title,
    'streak_unit': t.home_widget_streak_unit,
    'continue_title': t.home_widget_continue_title,
    'continue_empty': t.home_widget_continue_empty,
    'word_title': t.home_widget_word_title,
    'word_empty': t.home_widget_word_empty,
    'heat_title': t.home_widget_heat_title,
    'listen_resume': t.home_widget_listen_resume,
    'listen_empty': t.home_widget_listen_empty,
    'lookup_title': t.home_widget_lookup_title,
    'lookup_hint': t.home_widget_lookup_hint,
    'lookup_camera': t.home_widget_lookup_camera,
    'lookup_clipboard': t.home_widget_lookup_clipboard,
  };

  // ── 继续 ─────────────────────────────────────────────────────────

  Future<List<HomeWidgetContinueItem>> _continueItems(
    HomeWidgetCoverWriter covers,
  ) async {
    final List<HomeWidgetContinueSource> sources =
        _feed.items.value ?? const <HomeWidgetContinueSource>[];
    final List<HomeWidgetContinueItem> out = <HomeWidgetContinueItem>[];
    // 大号最多显示 4 条（1 主 + 3 副）。
    for (final HomeWidgetContinueSource s in sources.take(4)) {
      final ImageProvider? cover = s.cover;
      final String? path = cover == null
          ? null
          : await covers.write(s.coverKey ?? '${s.key}|$cover', cover);
      out.add(
        HomeWidgetContinueItem(
          kind: s.kind,
          id: s.key,
          title: s.title,
          subtitle: s.subtitle,
          progress: s.progress,
          progressLabel: s.progressLabel,
          cover: path,
          url: HomeWidgetContinueLink(s.key).url,
        ),
      );
    }
    return out;
  }

  // ── 接着听 ────────────────────────────────────────────────────────

  Future<HomeWidgetContinueItem?> _audiobookItem(
    HomeWidgetCoverWriter covers,
  ) async {
    final SessionBookInfo? book = _session?.book;
    if (book == null) return _lastAudiobook;
    final String? coverPath = book.coverPath;
    final String? cover = coverPath == null || !File(coverPath).existsSync()
        ? null
        : await covers.write(
            'audiobook|$coverPath',
            FileImage(File(coverPath)),
          );
    final c = _session?.controller;
    final Duration total = c?.totalDuration ?? Duration.zero;
    final double? progress = total > Duration.zero
        ? (c!.globalPosition.inMilliseconds / total.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : null;
    return _lastAudiobook = HomeWidgetContinueItem(
      kind: HomeWidgetItemKind.audiobook,
      id: book.mediaIdentifier,
      title: book.title,
      subtitle: book.author ?? t.section_audiobook,
      progress: progress,
      progressLabel: progress == null
          ? null
          : '${t.section_audiobook} · ${(progress * 100).round()}%',
      cover: cover,
      url: const HomeWidgetResumeAudiobookLink().url,
    );
  }

  Future<HomeWidgetContinueItem?> _readPreviousAudiobook() async {
    try {
      final File file = File('${_dir!.path}/snapshot.json');
      if (!file.existsSync()) return null;
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?>) return null;
      final Object? a = json['audiobook'];
      if (a is! Map<String, Object?>) return null;
      return HomeWidgetContinueItem(
        kind: HomeWidgetItemKind.audiobook,
        id: a['id']! as String,
        title: a['title']! as String,
        subtitle: a['subtitle']! as String,
        progress: (a['progress'] as num?)?.toDouble(),
        progressLabel: a['progressLabel'] as String?,
        cover: a['cover'] as String?,
        url: a['url']! as String,
      );
    } on Object {
      return null;
    }
  }

  final Set<String> _activityCovers = <String>{};

  Future<String?> _activityCover(String? path) async {
    final HomeWidgetCoverWriter? covers = _covers;
    if (covers == null || path == null || !File(path).existsSync()) {
      return null;
    }
    final String? rel = await covers.write(
      'activity|$path',
      FileImage(File(path)),
    );
    if (rel != null) _activityCovers.add(rel);
    return rel;
  }

  // ── 复习 ─────────────────────────────────────────────────────────

  Future<HomeWidgetSrsSection?> _srsSection(DateTime now) async {
    final SrsDeckListData? decks = await ref.read(srsDeckListProvider.future);
    if (decks == null) return null;
    final SrsDbStore? store = await ref.read(srsStoreProvider.future);
    if (store == null) return null;
    final int nowMs = now.millisecondsSinceEpoch;
    final int dueNow = decks.todayNew + decks.todayLearn + decks.todayReview;
    final SrsDayContext day = await store.dayContext();
    final ({List<int> learningDueAts, int reviewsNextDay, int? averageMs})
    stats = decks.totalCards == 0
        ? (learningDueAts: const <int>[], reviewsNextDay: 0, averageMs: null)
        : await _srsStats(store, day, nowMs);
    final List<SrsDueStep> steps = buildSrsDueTimeline(
      nowMs: nowMs,
      dueNow: dueNow,
      learningDueAts: stats.learningDueAts,
      dayIndexOf: day.dayIndexOf,
      reviewsDueNextDay: stats.reviewsNextDay,
    );
    return HomeWidgetSrsSection(
      timeline: <HomeWidgetSrsEntry>[
        for (final SrsDueStep s in steps)
          HomeWidgetSrsEntry(
            at: s.at,
            due: s.due,
            caption: s.due == 0
                ? t.home_widget_srs_caption_done
                : t.home_widget_srs_caption(
                    minutes: estimateSrsMinutes(
                      s.due,
                      averageMsPerCard: stats.averageMs,
                    ),
                  ),
            inline: t.home_widget_srs_inline(count: s.due),
          ),
      ],
      newCount: decks.todayNew,
      learning: decks.todayLearn,
      review: decks.todayReview,
      url: const HomeWidgetReviewLink().url,
    );
  }

  Future<({List<int> learningDueAts, int reviewsNextDay, int? averageMs})>
  _srsStats(SrsDbStore store, SrsDayContext day, int nowMs) async {
    final String fingerprint = store.statsFingerprint;
    final cached = _srsStatsCache;
    if (cached != null && fingerprint == _srsStatsFingerprint) {
      // 指纹没变：只按「现在」剔掉已经过去的学习步。
      return (
        learningDueAts: cached.learningDueAts
            .where((int at) => at > nowMs)
            .toList(),
        reviewsNextDay: cached.reviewsNextDay,
        averageMs: cached.averageMs,
      );
    }
    final SrsStatsBundle bundle = await loadSrsStats(store, day: day);
    final SrsStatsData data = bundle.data;
    final int today = day.dayIndexOf(nowMs);
    final List<int> learning = <int>[];
    int nextDay = 0;
    for (final SrsStatCard card in data.cards) {
      if (card.suspended || card.buried) continue;
      switch (card.state) {
        case SrsStatCardState.learning || SrsStatCardState.relearning:
          final int? at = card.dueAt;
          if (at != null && at > nowMs) learning.add(at);
        case SrsStatCardState.young || SrsStatCardState.mature:
          if (card.dueDay == today + 1) nextDay++;
        case SrsStatCardState.newCard:
          break;
      }
    }
    int totalMs = 0;
    int counted = 0;
    for (final SrsStatReview r in data.reviews) {
      if (r.day < today - 14 || r.durationMs <= 0) continue;
      totalMs += r.durationMs;
      counted++;
    }
    final result = (
      learningDueAts: learning,
      reviewsNextDay: nextDay,
      averageMs: counted == 0 ? null : totalMs ~/ counted,
    );
    _srsStatsFingerprint = fingerprint;
    _srsStatsCache = result;
    return result;
  }

  // ── 学习统计 ──────────────────────────────────────────────────────

  Future<HomeWidgetStudySection?> _studySection(
    FushiDatabase db,
    DateTime now,
  ) async {
    final int profileId = await db.resolveActiveProfileId();
    final StatFacts facts = await loadStatFacts(
      db,
      profileId: profileId,
      includeCounters: true,
    );
    final StatWindow window = StatWindow(now);
    final Map<String, int> msByDay = <String, int>{};
    final Set<String> active = <String>{};
    for (final StatFact f in facts.daily) {
      msByDay[f.dateKey] = (msByDay[f.dateKey] ?? 0) + f.ms;
      if (f.ms > 0 || f.chars > 0) active.add(f.dateKey);
    }
    int weekCards = 0;
    for (final MiningStatisticRow row
        in facts.counters.mining) {
      if (window.inWeek(row.dateKey)) weekCards += row.count;
    }
    final HomeWidgetStudyNumbers n = buildStudyNumbers(
      last112Keys: window.lastDayKeys(112),
      amountOf: (String k) => (
        dateKey: k,
        ms: msByDay[k] ?? 0,
        chars: studyGoalCharsForDay(facts.daily, k),
      ),
      streakOf: (Set<String> keys) => computeReadingStreak(keys, now),
      activeDayKeys: active,
      inWeek: window.inWeek,
      weekCards: weekCards,
    );
    final String todayLine = n.studiedToday
        ? '${t.stat_today} ${formatStatTime(n.todayMs)} · '
              '${formatStatChars(n.todayChars)}'
        : t.home_widget_today_none;
    final int midnightAt = now
        .add(StatWindow.untilNextStatDayBoundary(now))
        .millisecondsSinceEpoch;
    return HomeWidgetStudySection(
      today: HomeWidgetStudyDay(
        streak: n.streak,
        streakCaption: t.home_widget_streak_caption,
        todayLine: todayLine,
        last7: n.last7,
      ),
      tomorrow: HomeWidgetStudyDay(
        streak: n.streakTomorrow,
        streakCaption: t.home_widget_streak_caption,
        todayLine: t.home_widget_today_none,
        last7: n.last7Tomorrow,
      ),
      midnightAt: midnightAt,
      heat: n.heat,
      weekValue: formatStatTime(n.weekMs),
      weekCaption: t.home_widget_week_caption,
      cardsValue: '${n.weekCards}',
      cardsCaption: t.home_widget_cards_caption,
      url: const HomeWidgetStatsLink().url,
    );
  }

  // ── 今日一词 ──────────────────────────────────────────────────────

  Future<HomeWidgetWord?> _wordOfDay(FushiDatabase db, DateTime now) async {
    final String dateKey = StatWindow(now).todayKey;
    final HomeWidgetWord? fromCards = await _wordFromSrsCards(dateKey);
    if (fromCards != null) return fromCards;
    // 没有内置复习卡（制卡只发 Anki）时退到收藏词：它自带读音 / 释义 / 原句 / 出处。
    final List<FavoriteWordRow> favorites = await db.getAllFavoriteWords();
    final List<FavoriteWordRow> usable = favorites
        .where((FavoriteWordRow w) => w.expression.trim().isNotEmpty)
        .toList();
    final int index = dailyRotationIndex(
      dateKey: dateKey,
      count: usable.length,
    );
    if (index < 0) return null;
    final FavoriteWordRow w = usable[index];
    return _word(
      term: w.expression,
      reading: w.reading,
      meaning: w.glossary,
      sentence: w.sentence,
      source: w.title,
    );
  }

  Future<HomeWidgetWord?> _wordFromSrsCards(String dateKey) async {
    final SrsDbStore? store = await ref.read(srsStoreProvider.future);
    if (store == null) return null;
    final notes = await store.listNotes(limit: 300);
    if (notes.isEmpty) return null;
    // 从挑中的那张起往后找，跳过取不到词形的笔记（自定义笔记类型）。
    final int start = dailyRotationIndex(dateKey: dateKey, count: notes.length);
    for (int i = 0; i < math.min(notes.length, 20); i++) {
      final note = notes[(start + i) % notes.length];
      final view = await store.note(note.id);
      final type = view == null ? null : await store.noteType(view.noteTypeId);
      if (view == null || type == null) continue;
      final Map<String, String> fields = <String, String>{
        for (final f in type.fields) f.name: view.field(f.id),
      };
      String? pick(List<String> names) {
        for (final String n in names) {
          final String? v = FushiCardFields.value(fields, n);
          if (v != null && stripCardFieldHtml(v).isNotEmpty) return v;
        }
        return null;
      }

      final String? term = pick(<String>[
        FushiCardFields.term,
        'Word',
        'Front',
      ]);
      if (term == null) continue;
      return _word(
        term: term,
        reading: pick(<String>[FushiCardFields.termReading, 'Reading']),
        meaning:
            pick(<String>['MainDefinition', 'Glossary', 'Meaning', 'Back']) ??
            '',
        sentence: pick(<String>['Sentence']),
        source: pick(<String>[FushiCardFields.source]),
      );
    }
    return null;
  }

  HomeWidgetWord _word({
    required String term,
    required String meaning,
    String? reading,
    String? sentence,
    String? source,
  }) {
    final String plainTerm = stripCardFieldHtml(term);
    String? clean(String? v, {int max = 140}) {
      if (v == null) return null;
      final String s = stripCardFieldHtml(v);
      if (s.isEmpty) return null;
      return s.length > max ? '${s.substring(0, max)}…' : s;
    }

    final String? plainReading = clean(reading, max: 40);
    return HomeWidgetWord(
      term: plainTerm,
      // 读音与词形相同（假名词）就不重复显示。
      reading: plainReading == plainTerm ? null : plainReading,
      meaning: clean(meaning) ?? '',
      sentence: clean(sentence, max: 80),
      source: clean(source, max: 40),
      url: Uri(
        scheme: 'fushi',
        host: 'lookup',
        queryParameters: <String, String>{'word': plainTerm},
      ).toString(),
    );
  }
}
