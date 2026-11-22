// AI 管库自动复查（docs/specs/2026-11-22-ai-library-agent-design.md §7）：第一次全库、
// 之后只看新条目，累积够多 / 隔一个月再全库；会话没跑完不推进水位；门不开不发请求；
// 自动路径在流水线之后接着复查。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/library_curate/library_agent_review.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int day = 24 * 60 * 60 * 1000;

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

    test('状态推进与编解码', () {
      const LibraryAgentReviewState s = LibraryAgentReviewState(
        lastReviewAt: 10,
        lastFullAt: 5,
        itemsSinceFull: 7,
      );
      final LibraryAgentReviewState inc = advanceLibraryAgentReview(
        s,
        kind: LibraryAgentReviewKind.incremental,
        newItems: 3,
        startedAtMs: 20,
      );
      expect(
        (inc.lastReviewAt, inc.lastFullAt, inc.itemsSinceFull),
        (20, 5, 10),
      );
      final LibraryAgentReviewState full = LibraryAgentReviewState.parse(
        advanceLibraryAgentReview(
          inc,
          kind: LibraryAgentReviewKind.full,
          newItems: 3,
          startedAtMs: 30,
        ).encode(),
      );
      expect(
        (full.lastReviewAt, full.lastFullAt, full.itemsSinceFull),
        (30, 30, 0),
      );
      expect(LibraryAgentReviewState.parse('not json').lastReviewAt, isNull);
    });

    test('请求失败 / 取消 / 中断不算跑完；撞上限算跑完', () {
      expect(libraryAgentReviewCompleted(const <String>[]), isTrue);
      expect(
        libraryAgentReviewCompleted(const <String>[AgentStopCode.toolLimit]),
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

  group('LibraryAgentReviewer', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;
    late List<String> prompts;
    late List<String>? Function() stops;
    late bool assigned;
    late int now;
    late LibraryAgentReviewer reviewer;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      prompts = <String>[];
      stops = () => const <String>[];
      assigned = true;
      now = 1000 * day;
      reviewer = LibraryAgentReviewer(
        database: db,
        prefs: prefs,
        aiModuleEnabled: () => true,
        agentAssigned: () => assigned,
        runSession: (String prompt) async {
          prompts.add(prompt);
          return stops();
        },
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
    });
    tearDown(() => db.close());

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

    test('首次全库 → 无新条目不跑 → 新书增量（带水位）', () async {
      await reviewer.review();
      expect(prompts, hasLength(1));
      expect(state().lastFullAt, now);

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

    test('会话请求失败不推进水位，下次重来', () async {
      stops = () => const <String>[AgentStopCode.llmError];
      await reviewer.review();
      expect(state().lastReviewAt, isNull);
      stops = () => const <String>[];
      await reviewer.review();
      expect(prompts, hasLength(2));
      expect(state().lastReviewAt, isNotNull);
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
      installLibraryCurateAutomatic(null);
      registerLibraryAgentAutoReviewer(() => reviewer);
      addTearDown(() => registerLibraryAgentAutoReviewer(null));
      expect(await runAutomaticLibraryCurate(), isNull);
      expect(prompts, hasLength(1));
    });
  });
}
