// AI 管库自动复查（docs/specs/2026-11-22-ai-library-agent-design.md §7 / §7.1）：第一次
// 全库、之后只看新条目，累积够多 / 隔一个月再全库；门不开不发请求；自动路径在流水线
// 之后接着复查。
//
// BUG-5365 回归：全库复查分段（一段一场有界会话，进度逐段落盘、下次续跑）；失败也
// 记账（指数退避、连败熔断，失败后下一次触发不会立刻重跑全库）；单趟 token 上限；
// 旧版 / 空状态照常解析。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/library_curate/library_agent_review.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/media/library_agent/library_map.dart'
    show LibraryMapView;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int hour = 60 * 60 * 1000;
  const int day = 24 * hour;

  group('decideLibraryAgentReview', () {
    test('从没复查过：全库', () {
      expect(
        decideLibraryAgentReview(
          state: const LibraryAgentReviewState(),
          newItems: 0,
          nowMs: 1000,
        ),
        LibraryAgentReviewKind.full,
      );
    });

    test('没有新条目：不跑（哪怕已经隔了一个月）', () {
      expect(
        decideLibraryAgentReview(
          state: const LibraryAgentReviewState(lastReviewAt: 1, lastFullAt: 1),
          newItems: 0,
          nowMs: 100 * day,
        ),
        isNull,
      );
    });

    test('有新条目：增量；累积够多或隔满一个月：全库', () {
      const LibraryAgentReviewState s = LibraryAgentReviewState(
        lastReviewAt: 10 * day,
        lastFullAt: 5 * day,
        itemsSinceFull: 40,
      );
      expect(
        decideLibraryAgentReview(state: s, newItems: 3, nowMs: 11 * day),
        LibraryAgentReviewKind.incremental,
      );
      expect(
        decideLibraryAgentReview(
          state: s,
          newItems: kLibraryAgentReviewFullAfterItems - 40,
          nowMs: 11 * day,
        ),
        LibraryAgentReviewKind.full,
      );
      expect(
        decideLibraryAgentReview(state: s, newItems: 1, nowMs: 35 * day),
        LibraryAgentReviewKind.full,
      );
    });

    test('分段全库复查进行中：接着跑全库（没有新条目也跑）', () {
      expect(
        decideLibraryAgentReview(
          state: const LibraryAgentReviewState(
            lastReviewAt: 1,
            lastFullAt: 1,
            fullStartedAt: 5,
            cursor: LibraryAgentReviewCursor(LibraryMapView.video, 300),
          ),
          newItems: 0,
          nowMs: 6,
        ),
        LibraryAgentReviewKind.full,
      );
    });

    test('请求失败 / 取消 / 中断不算跑完；撞上限（含 token 上限）算跑完', () {
      expect(libraryAgentReviewCompleted(const <String>[]), isTrue);
      expect(
        libraryAgentReviewCompleted(const <String>[AgentStopCode.toolLimit]),
        isTrue,
      );
      expect(
        libraryAgentReviewCompleted(const <String>[AgentStopCode.tokenBudget]),
        isTrue,
      );
      expect(
        libraryAgentReviewCompleted(const <String>[AgentStopCode.llmError]),
        isFalse,
      );
      expect(
        libraryAgentReviewCompleted(const <String>[AgentStopCode.cancelled]),
        isFalse,
      );
    });
  });

  group('LibraryAgentReviewState', () {
    test('空 / 坏 / 旧版状态照常解析（新字段取缺省）', () {
      for (final String raw in <String>['', '  ', 'not json', '[1]']) {
        final LibraryAgentReviewState s = LibraryAgentReviewState.parse(raw);
        expect(s.lastReviewAt, isNull, reason: raw);
        expect(s.fullInProgress, isFalse, reason: raw);
        expect(s.failures, 0, reason: raw);
      }
      // 旧版只存这三个字段。
      final LibraryAgentReviewState old = LibraryAgentReviewState.parse(
        '{"lastReviewAt":10,"lastFullAt":5,"itemsSinceFull":7}',
      );
      expect(
        (old.lastReviewAt, old.lastFullAt, old.itemsSinceFull),
        (10, 5, 7),
      );
      expect(old.fullInProgress, isFalse);
      expect(old.cursor, isNull);
      expect((old.failures, old.retryAt, old.pausedFor), (0, null, null));
      // 认不出的视图名：游标丢掉，留给收尾。
      expect(
        LibraryAgentReviewState.parse(
          '{"fullStartedAt":3,"fullView":"nope","fullOffset":100}',
        ).cursor,
        isNull,
      );
    });

    test('编解码往返', () {
      const LibraryAgentReviewState s = LibraryAgentReviewState(
        lastReviewAt: 10,
        lastFullAt: 5,
        itemsSinceFull: 7,
        fullStartedAt: 20,
        cursor: LibraryAgentReviewCursor(LibraryMapView.games, 200),
        failures: 2,
        retryAt: 99,
        pausedFor: 'p',
      );
      final LibraryAgentReviewState r = LibraryAgentReviewState.parse(
        s.encode(),
      );
      expect(
        (
          r.lastReviewAt,
          r.lastFullAt,
          r.itemsSinceFull,
          r.fullStartedAt,
          r.cursor,
          r.failures,
          r.retryAt,
          r.pausedFor,
        ),
        (
          10,
          5,
          7,
          20,
          const LibraryAgentReviewCursor(LibraryMapView.games, 200),
          2,
          99,
          'p',
        ),
      );
    });

    test('游标按窗口前进、越过视图末尾换下一个视图；走完收尾推水位', () {
      LibraryAgentReviewState s = const LibraryAgentReviewState(
        itemsSinceFull: 9,
      ).startFull(50);
      expect(s.cursor, const LibraryAgentReviewCursor(LibraryMapView.books, 0));
      s = s.advanceCursor(total: kLibraryAgentReviewDomainWindow + 1);
      expect(
        s.cursor,
        const LibraryAgentReviewCursor(
          LibraryMapView.books,
          kLibraryAgentReviewDomainWindow,
        ),
      );
      s = s.advanceCursor(total: kLibraryAgentReviewDomainWindow + 1);
      expect(s.cursor, const LibraryAgentReviewCursor(LibraryMapView.manga, 0));
      s = const LibraryAgentReviewState(
        fullStartedAt: 50,
        cursor: LibraryAgentReviewCursor(LibraryMapView.links, 0),
      ).advanceCursor(total: 3);
      expect(s.cursor, isNull);
      expect(s.fullInProgress, isTrue);
      final LibraryAgentReviewState done = s.finishFull();
      expect(
        (
          done.lastReviewAt,
          done.lastFullAt,
          done.itemsSinceFull,
          done.fullInProgress,
        ),
        (50, 50, 0, false),
      );
    });

    test('退避 1h → 2h → 4h …，封顶一天；连败熔断，换提供商 / 重新打开即恢复', () {
      expect(
        <int>[
          for (int i = 1; i <= 7; i++)
            libraryAgentReviewBackoff(i).inMilliseconds ~/ hour,
        ],
        <int>[1, 2, 4, 8, 16, 24, 24],
      );
      LibraryAgentReviewState s = const LibraryAgentReviewState();
      for (int i = 0; i < kLibraryAgentReviewMaxFailures - 1; i++) {
        s = s.failed(nowMs: 0, providerKey: 'a');
        expect(s.paused, isFalse);
      }
      s = s.failed(nowMs: 0, providerKey: 'a');
      expect(s.paused, isTrue);
      expect(
        libraryAgentReviewBlocked(s, nowMs: 365 * day, providerKey: 'a'),
        isTrue,
        reason: '熔断不随时间自动解除',
      );
      expect(
        libraryAgentReviewBlocked(s, nowMs: 0, providerKey: 'b'),
        isFalse,
        reason: '换了提供商',
      );
      final LibraryAgentReviewState resumed = s.resumed();
      expect(
        (resumed.failures, resumed.retryAt, resumed.pausedFor),
        (0, null, null),
      );
    });
  });

  group('LibraryAgentReviewer', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;
    late List<String> prompts;
    late LibraryAgentReviewSessionResult? Function() result;
    late Map<LibraryMapView, int>? totals;
    late bool assigned;
    late String provider;
    late int now;
    late LibraryAgentReviewer reviewer;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      prompts = <String>[];
      result = () => const LibraryAgentReviewSessionResult();
      totals = null;
      assigned = true;
      provider = 'p1';
      now = 1000 * day;
      reviewer = LibraryAgentReviewer(
        database: db,
        prefs: prefs,
        aiModuleEnabled: () => true,
        agentAssigned: () => assigned,
        providerKey: () => provider,
        runSession: (String prompt) async {
          prompts.add(prompt);
          return result();
        },
        // null = 用真实的 library.map 计数。
        viewTotal: (LibraryMapView v) async =>
            totals?[v] ?? (throw StateError('real totals not injected')),
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
    });
    tearDown(() => db.close());

    /// 用真实 `library.map` 计数的复查器（其余与 [reviewer] 相同）。
    LibraryAgentReviewer realTotals() => LibraryAgentReviewer(
      database: db,
      prefs: prefs,
      aiModuleEnabled: () => true,
      agentAssigned: () => assigned,
      providerKey: () => provider,
      runSession: (String prompt) async {
        prompts.add(prompt);
        return result();
      },
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
    );

    Future<void> addBook(String key, int addedAt) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/m/$key',
          extractDir: '/m/$key',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: addedAt,
          localAddedAt: Value<int>(addedAt),
        ),
      );
    }

    LibraryAgentReviewState state() =>
        LibraryAgentReviewState.parse(prefs.libraryAgentReviewState);

    test('首次全库（真实计数，一段就走完）→ 无新条目不跑 → 新书增量（带水位）', () async {
      reviewer = realTotals();
      await addBook('旧书', now - day);
      await reviewer.review();
      expect(prompts, hasLength(1), reason: '只有书库一段有东西，其余视图为空不开会话');
      expect(prompts.single, contains('view=books offset=0'));
      expect(state().lastFullAt, now);
      expect(state().fullInProgress, isFalse);

      now += day;
      await reviewer.review();
      expect(prompts, hasLength(1), reason: '没有新条目不发请求');

      await addBook('新书', now + 1);
      final int watermark = state().lastReviewAt!;
      now += day;
      await reviewer.review();
      expect(prompts, hasLength(2));
      expect(prompts.last, contains('$watermark'));
      expect(state().itemsSinceFull, 1);
      expect(state().lastReviewAt, now);
    });

    test('全库按视图分段：单趟 token 用满就停，进度落盘，下次从没跑完的段接着来', () async {
      totals = <LibraryMapView, int>{
        LibraryMapView.books: 150,
        LibraryMapView.manga: 0,
        LibraryMapView.video: 1308,
        LibraryMapView.games: 0,
        LibraryMapView.links: 30,
      };
      const int perSession = kLibraryAgentReviewSessionTokens;
      result = () =>
          const LibraryAgentReviewSessionResult(totalTokens: perSession);
      final int started = now;
      await reviewer.review();
      const int perRun =
          (kLibraryAgentReviewRunTokens + perSession - 1) ~/ perSession;
      expect(prompts, hasLength(perRun));
      expect(prompts[0], contains('view=books offset=0'));
      expect(prompts[1], contains('view=books offset=100'));
      expect(prompts[2], contains('view=video offset=0'), reason: '空的漫画库跳过');
      expect(state().fullInProgress, isTrue);
      expect(
        state().cursor,
        const LibraryAgentReviewCursor(LibraryMapView.video, 100),
      );
      expect(state().lastFullAt, isNull, reason: '没走完不推水位');

      // 下一次触发：从 video@100 续跑，不从头再来。
      now += hour;
      prompts.clear();
      result = () => const LibraryAgentReviewSessionResult();
      await reviewer.review();
      expect(prompts.first, contains('view=video offset=100'));
      // video 1308 行 → 0..1300 共 14 段，已跑 1 段；links 一段。
      expect(prompts, hasLength(13 + 1));
      expect(prompts.last, contains('view=links offset=0'));
      expect(state().fullInProgress, isFalse);
      expect(state().lastFullAt, started, reason: '水位推到这趟全库复查开始的时刻');
      expect(state().lastReviewAt, started);
    });

    test('失败不推进、不立即重跑：退避期内的触发不发请求，到点从同一段重来', () async {
      totals = <LibraryMapView, int>{
        LibraryMapView.books: 250,
        LibraryMapView.manga: 0,
        LibraryMapView.video: 0,
        LibraryMapView.games: 0,
        LibraryMapView.links: 0,
      };
      int calls = 0;
      // 第二段失败（llm_error）。
      result = () => ++calls == 2
          ? const LibraryAgentReviewSessionResult(
              stopCodes: <String>[AgentStopCode.llmError],
            )
          : const LibraryAgentReviewSessionResult();
      await reviewer.review();
      expect(prompts, hasLength(2));
      expect(state().failures, 1);
      expect(state().retryAt, now + hour);
      expect(
        state().cursor,
        const LibraryAgentReviewCursor(LibraryMapView.books, 100),
        reason: '第一段的进度保住了',
      );
      expect(state().lastReviewAt, isNull);

      // 自动路径一小时内又触发几次：都不发请求（BUG-5365：以前每次都从头再跑全库）。
      for (int i = 0; i < 3; i++) {
        now += 10 * 60 * 1000;
        await reviewer.review();
      }
      expect(prompts, hasLength(2));

      now += hour;
      await reviewer.review();
      expect(prompts[2], contains('view=books offset=100'));
      expect(prompts, hasLength(4));
      expect(state().failures, 0);
      expect(state().lastFullAt, isNotNull);
    });

    test('连败熔断：之后的触发一律不跑，直到换了提供商', () async {
      totals = <LibraryMapView, int>{
        for (final LibraryMapView v in kLibraryAgentReviewFullViews) v: 10,
      };
      result = () => const LibraryAgentReviewSessionResult(
        stopCodes: <String>[AgentStopCode.llmError],
      );
      for (int i = 0; i < kLibraryAgentReviewMaxFailures; i++) {
        await reviewer.review();
        now += kLibraryAgentReviewMaxBackoff.inMilliseconds;
      }
      expect(prompts, hasLength(kLibraryAgentReviewMaxFailures));
      expect(state().paused, isTrue);

      for (int i = 0; i < 5; i++) {
        now += 7 * day;
        await reviewer.review();
      }
      expect(prompts, hasLength(kLibraryAgentReviewMaxFailures));

      provider = 'p2';
      result = () => const LibraryAgentReviewSessionResult();
      await reviewer.review();
      expect(prompts.length, greaterThan(kLibraryAgentReviewMaxFailures));
      expect(state().paused, isFalse);
      expect(state().lastFullAt, isNotNull);
    });

    test('会话抛异常也按失败记账', () async {
      totals = <LibraryMapView, int>{
        for (final LibraryMapView v in kLibraryAgentReviewFullViews) v: 10,
      };
      result = () => throw StateError('boom');
      await reviewer.review();
      expect(state().failures, 1);
      expect(state().retryAt, isNotNull);
    });

    test('增量复查失败：同样退避，水位不动', () async {
      await prefs.setLibraryAgentReviewState(
        // 旧版状态格式。
        '{"lastReviewAt":${now - day},"lastFullAt":${now - day},"itemsSinceFull":0}',
      );
      await addBook('新书', now - hour);
      result = () => const LibraryAgentReviewSessionResult(
        stopCodes: <String>[AgentStopCode.llmError],
      );
      await reviewer.review();
      expect(prompts, hasLength(1));
      expect(state().lastReviewAt, now - day);
      expect(state().failures, 1);
      await reviewer.review();
      expect(prompts, hasLength(1));
    });

    test('开关关 / 没指派助手：不跑', () async {
      await prefs.setLibraryAgentReviewAuto(false);
      expect(reviewer.enabled, isFalse);
      await reviewer.review();
      await prefs.setLibraryAgentReviewAuto(true);
      assigned = false;
      await reviewer.review();
      expect(prompts, isEmpty);
    });

    test('自动路径：流水线关着也接着复查', () async {
      reviewer = realTotals();
      await addBook('书', now - day);
      installLibraryCurateAutomatic(null);
      registerLibraryAgentAutoReviewer(() => reviewer);
      addTearDown(() => registerLibraryAgentAutoReviewer(null));
      expect(await runAutomaticLibraryCurate(), isNull);
      expect(prompts, hasLength(1));
    });
  });
}
