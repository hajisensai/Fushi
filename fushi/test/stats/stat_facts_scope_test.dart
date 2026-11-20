import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:test/test.dart';

// m5（路线图 #3722）：loadStatFacts 的按域 / 按媒体范围只把「读哪些行」下推进 SQL，
// 切片结果必须与「全量读再按 statFactBelongsToBook 切」逐条相同——尤其 legacy 无身份
// 行的标题回退（唯一同名反查 / 同名歧义 / 调用方没给标题）不能少算。

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

String _factKey(StatFact f) =>
    '${f.mediaKind}|${f.mediaKey}|${f.title}|${f.format}|${f.dateKey}|'
    '${f.hour}|${f.ms}|${f.chars}|${f.pages}|${f.lastActiveMs}';

List<String> _keys(Iterable<StatFact> facts) =>
    facts.map(_factKey).toList()..sort();

String _counterKey(LookupMiningCounterRow c) =>
    '${c.bookKey}|${c.title}|${c.sourceType}|${c.dateKey}|'
    '${c.lookupCount}|${c.mineCount}';

String _sessionKey(StudySession s) =>
    '${s.mediaKind}|${s.mediaKey}|${s.startAt}|${s.endAt}|${s.durationMs}|'
    '${s.chars}|${s.segmentUids.join(',')}';

int _seq = 0;

Future<void> _segment(
  FushiDatabase db, {
  required String kind,
  required String key,
  required String title,
  String dateKey = '2026-11-01',
  int ms = 60000,
}) async {
  final int start = 1000000 + (_seq++) * 10000000;
  await db.upsertStudySegment(
    StudySegmentsCompanion.insert(
      uid: 'seg_$_seq',
      deviceId: 'dev',
      mediaKind: kind,
      mediaKey: key,
      title: title,
      startAt: start,
      endAt: start + ms,
      dateKey: dateKey,
      hour: 9,
      durationMs: Value(ms),
      chars: Value(ms ~/ 100),
      updatedAt: start,
    ),
  );
}

Future<void> _book(FushiDatabase db, String key, String title) => db
    .into(db.epubBooks)
    .insert(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: title,
        epubPath: '$key.epub',
        extractDir: key,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: _seq++,
      ),
    );

Future<void> _legacyRead(FushiDatabase db, String title, String dateKey) => db
    .into(db.readingStatistics)
    .insert(
      ReadingStatisticsCompanion.insert(
        title: title,
        dateKey: dateKey,
        charactersRead: 321,
        readingTimeMs: 4321,
        lastStatisticModified: _seq++,
      ),
    );

Future<void> _legacyWatch(
  FushiDatabase db,
  String title,
  String? uid,
  String dateKey,
) => db
    .into(db.videoWatchStatistics)
    .insert(
      VideoWatchStatisticsCompanion.insert(
        title: title,
        bookUid: Value(uid),
        dateKey: dateKey,
        subtitleChars: 55,
        watchTimeMs: 5555,
        lastModified: _seq++,
      ),
    );

Future<void> _counter(
  FushiDatabase db, {
  required String bookKey,
  required String title,
  required String dateKey,
  String source = 'book',
}) => db
    .into(db.lookupMiningCounters)
    .insert(
      LookupMiningCountersCompanion.insert(
        bookKey: Value(bookKey),
        title: Value(title),
        sourceType: source,
        dateKey: dateKey,
        lookupCount: const Value(3),
        mineCount: const Value(1),
      ),
    );

/// 摘要器同口径的计数切片（`summarizeReaderBookStats` 的判据）。
bool _counterBelongs(LookupMiningCounterRow c, String key, String? title) =>
    c.bookKey.isNotEmpty
    ? c.bookKey == key
    : (title != null && title.isNotEmpty && c.title == title);

Future<FushiDatabase> _seeded() async {
  final FushiDatabase db = await _openDb();
  // 书：b1「唯一」；b2 / b3 同名「双子」（legacy 歧义）；b4 别的书。
  await _book(db, 'b1', '唯一');
  await _book(db, 'b2', '双子');
  await _book(db, 'b3', '双子');
  await _book(db, 'b4', '别的');
  for (final String k in <String>['b1', 'b2', 'b3', 'b4']) {
    await _segment(db, kind: kActivityMediaBook, key: k, title: 'seg-$k');
  }
  // 无身份段：按标题回退。
  await _segment(db, kind: kActivityMediaBook, key: '', title: '唯一');
  await _segment(db, kind: kActivityMediaBook, key: '', title: '双子');
  // legacy 阅读行：唯一同名反查到 b1；双子歧义只能按标题回退；查不到的书。
  await _legacyRead(db, '唯一', '2025-01-01');
  await _legacyRead(db, '双子', '2025-01-02');
  await _legacyRead(db, '别的', '2025-01-03');
  await _legacyRead(db, '已删的书', '2025-01-04');
  // 视频：v1 有身份段与 legacy 行；legacy 无 uid 行按标题回退；v2 别的视频。
  await _segment(db, kind: kActivityMediaVideo, key: 'v1', title: '番剧');
  await _segment(db, kind: kActivityMediaVideo, key: 'v2', title: '别的番');
  await _segment(db, kind: kActivityMediaVideo, key: '', title: '番剧');
  await _legacyWatch(db, '番剧', 'v1', '2025-02-01');
  await _legacyWatch(db, '番剧', null, '2025-02-02');
  await _legacyWatch(db, '番剧', '', '2025-02-03');
  await _legacyWatch(db, '别的番', 'v2', '2025-02-04');
  // 游戏段与会话（域 / 媒体范围都不该带进来，也不该影响视频会话）。
  await _segment(db, kind: kActivityMediaGame, key: 'g1', title: '游戏');
  // 计数：有身份 / 无身份按标题回退 / 别的书。
  await _counter(db, bookKey: 'b1', title: '唯一', dateKey: '2026-11-01');
  await _counter(db, bookKey: '', title: '唯一', dateKey: '2026-11-02');
  await _counter(db, bookKey: '', title: '双子', dateKey: '2026-11-03');
  await _counter(db, bookKey: 'b4', title: '别的', dateKey: '2026-11-04');
  await _counter(
    db,
    bookKey: 'v1',
    title: '番剧',
    dateKey: '2026-11-05',
    source: 'video',
  );
  await _counter(
    db,
    bookKey: '',
    title: '番剧',
    dateKey: '2026-11-06',
    source: 'video',
  );
  return db;
}

Future<void> _expectMediaParity(
  FushiDatabase db, {
  required String kind,
  required String key,
  required String? title,
}) async {
  final StatFacts full = await loadStatFacts(
    db,
    activityLimit: 0,
    includeCounters: true,
  );
  final StatFacts scoped = await loadStatFacts(
    db,
    activityLimit: 0,
    includeCounters: true,
    scope: StatFactsScope.media(mediaKind: kind, mediaKey: key, title: title),
  );
  bool ofKind(StatFact f) => f.mediaKind == kind;
  bool mine(StatFact f) =>
      ofKind(f) && statFactBelongsToBook(f, bookKey: key, title: title);
  final List<String> expected = _keys(full.daily.where(mine));
  expect(expected, isNotEmpty, reason: '用例要真的命中行');
  expect(
    _keys(scoped.daily.where(mine)),
    expected,
    reason: '$kind/$key/$title 日面切片与全量一致',
  );
  expect(
    _keys(scoped.hourly.where(mine)),
    _keys(full.hourly.where(mine)),
    reason: '小时面切片与全量一致',
  );
  expect(
    scoped.counters.lookupCounters
        .where((LookupMiningCounterRow c) => _counterBelongs(c, key, title))
        .map(_counterKey)
        .toList()
      ..sort(),
    full.counters.lookupCounters
        .where((LookupMiningCounterRow c) => _counterBelongs(c, key, title))
        .map(_counterKey)
        .toList()
      ..sort(),
    reason: '本媒体计数与全量一致',
  );
}

void main() {
  group('StatFactsScope.media 与全量读再切逐条一致', () {
    test('唯一书名：legacy 行经唯一同名反查归本书', () async {
      final FushiDatabase db = await _seeded();
      await _expectMediaParity(
        db,
        kind: kActivityMediaBook,
        key: 'b1',
        title: '唯一',
      );
    });

    test('同名歧义：legacy 行与无身份段按标题回退', () async {
      final FushiDatabase db = await _seeded();
      await _expectMediaParity(
        db,
        kind: kActivityMediaBook,
        key: 'b2',
        title: '双子',
      );
    });

    test('调用方没给标题：唯一同名反查的 legacy 行仍归本书', () async {
      final FushiDatabase db = await _seeded();
      final StatFacts scoped = await loadStatFacts(
        db,
        activityLimit: 0,
        scope: const StatFactsScope.media(
          mediaKind: kActivityMediaBook,
          mediaKey: 'b1',
        ),
      );
      expect(
        scoped.dailyBooksFor(bookKey: 'b1').map((StatFact f) => f.dateKey),
        contains('2025-01-01'),
      );
      await _expectMediaParity(
        db,
        kind: kActivityMediaBook,
        key: 'b1',
        title: null,
      );
    });

    test('视频：legacy 无 uid（NULL / 空串）行按标题回退', () async {
      final FushiDatabase db = await _seeded();
      await _expectMediaParity(
        db,
        kind: kActivityMediaVideo,
        key: 'v1',
        title: '番剧',
      );
    });

    test('单媒体范围不读别的书、别的域与收藏', () async {
      final FushiDatabase db = await _seeded();
      final StatFacts scoped = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
        scope: const StatFactsScope.media(
          mediaKind: kActivityMediaBook,
          mediaKey: 'b1',
          title: '唯一',
        ),
      );
      expect(scoped.daily.where((StatFact f) => !f.isBook), isEmpty);
      expect(scoped.daily.where((StatFact f) => f.mediaKey == 'b4'), isEmpty);
      expect(scoped.recentGameSessions, isEmpty);
      expect(scoped.counters.favoriteSentences, isEmpty);
    });
  });

  test('StatFactsScope.domain(video)：观看页用到的切片与全量一致', () async {
    final FushiDatabase db = await _seeded();
    final StatFacts full = await loadStatFacts(
      db,
      activityLimit: 0,
      includeCounters: true,
    );
    final StatFacts scoped = await loadStatFacts(
      db,
      activityLimit: 0,
      includeCounters: true,
      scope: const StatFactsScope.domain(kActivityMediaVideo),
    );
    expect(_keys(scoped.dailyVideos), _keys(full.dailyVideos));
    expect(scoped.dailyVideos, isNotEmpty);
    expect(scoped.daily.where((StatFact f) => !f.isVideo), isEmpty);
    expect(
      _keys(scoped.hourly.where((StatFact f) => f.isVideo)),
      _keys(full.hourly.where((StatFact f) => f.isVideo)),
    );
    List<String> videoSessions(StatFacts f) => f.sessions
        .where((StudySession s) => s.isVideo)
        .map(_sessionKey)
        .toList();
    expect(videoSessions(scoped), videoSessions(full));
    expect(
      scoped.counters.lookupCounters.map(_counterKey).toList()..sort(),
      full.counters.lookupCounters.map(_counterKey).toList()..sort(),
      reason: '域范围不收窄计数面（总览 = 各域之和）',
    );
  });

  // 拍板台 design-nmv-stats-main-isolate 第 3 条：阅读 / 游戏页签与观看同形，只读本域。
  for (final (String kind, bool Function(StatFact) inDomain) domain
      in <(String, bool Function(StatFact))>[
        (kActivityMediaBook, (StatFact f) => f.isBook),
        (kActivityMediaGame, (StatFact f) => f.isGame),
      ]) {
    test('StatFactsScope.domain(${domain.$1})：页签用到的切片与全量一致', () async {
      final FushiDatabase db = await _seeded();
      await _segment(db, kind: kActivityMediaGame, key: 'g2', title: '游戏二');
      final StatFacts full = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
      );
      final StatFacts scoped = await loadStatFacts(
        db,
        activityLimit: 0,
        includeCounters: true,
        scope: StatFactsScope.domain(domain.$1),
      );
      expect(
        _keys(scoped.daily.where(domain.$2)),
        _keys(full.daily.where(domain.$2)),
      );
      expect(scoped.daily.where(domain.$2), isNotEmpty);
      expect(scoped.daily.where((StatFact f) => !domain.$2(f)), isEmpty);
      expect(
        _keys(scoped.hourly.where(domain.$2)),
        _keys(full.hourly.where(domain.$2)),
      );
      List<String> sessions(StatFacts f) => f.sessions
          .where((StudySession s) => s.mediaKind == domain.$1)
          .map(_sessionKey)
          .toList();
      expect(sessions(scoped), sessions(full));
      expect(
        scoped.counters.lookupCounters.map(_counterKey).toList()..sort(),
        full.counters.lookupCounters.map(_counterKey).toList()..sort(),
        reason: '域范围不收窄计数面（总览 = 各域之和）',
      );
    });
  }

  test('StatFactsScope.since：日面 / 小时面 = 全量里统计日 ≥ 起点的那些', () async {
    final FushiDatabase db = await _seeded();
    await _segment(
      db,
      kind: kActivityMediaBook,
      key: 'b1',
      title: 'seg-b1',
      dateKey: '2026-11-10',
    );
    await _segment(
      db,
      kind: kActivityMediaVideo,
      key: 'v1',
      title: '番剧',
      dateKey: '2026-11-12',
    );
    final StatFacts full = await loadStatFacts(db, activityLimit: 0);
    const String from = '2026-11-10';
    final StatFacts since = await loadStatFacts(
      db,
      activityLimit: 0,
      scope: const StatFactsScope.since(from),
    );
    bool inWindow(StatFact f) => f.dateKey.compareTo(from) >= 0;
    expect(_keys(since.daily), _keys(full.daily.where(inWindow)));
    expect(since.daily, hasLength(2));
    expect(_keys(since.hourly), _keys(full.hourly.where(inWindow)));
    expect(
      full.daily.where((StatFact f) => !inWindow(f)),
      isNotEmpty,
      reason: '种子里有起点之前的段与 legacy 行，范围确实下推了',
    );
  });
}
