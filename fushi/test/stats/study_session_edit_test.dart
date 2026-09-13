import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

// 会话编辑（用户 2026-09-10：「里面的每个会话做成可编辑，日期和字符都能编辑」）的
// 端到端契约。唯一入口是 `applyStudySessionEdit`，本测试从真库出发、经
// `deriveStudySessions` 派生会话、编辑、再读回库：
//  * 改日期 = 整个会话按**日历日之差**平移（段间相对间隔逐毫秒不变），dateKey / hour
//    跟着新 startAt 走，字数一个都不动；
//  * 改字数 = 新总数按各段现有字数比例分摊，总和逐字节守恒；
//  * 空编辑一行都不写；
//  * 游戏会话另有骨架行平移，纯时长会话（一条字数段都没有）改字数时新建一条
//    chars-only 段，且下一次派生必须被同一个骨架**吸收回同一条会话**——这才是这条
//    特例真正要保的东西（新建一条不相交的段只会多出一条 0 分钟的孤儿会话）；
//  * 退役纪律：写库**之前**先让段 uid 在在跑的 StudyClock 上退役，否则时钟下一个
//    tick 会按旧绝对值把刚改完的段原样写回去（「改了又弹回来」）。

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// 落一条真段。[start] / [end] 用本地 DateTime，dateKey / hour 按写入面的口径派生。
Future<void> _putSegment(
  FushiDatabase db,
  String uid, {
  required DateTime start,
  required DateTime end,
  String kind = kActivityMediaBook,
  String key = 'b1',
  int ms = 60000,
  int chars = 0,
  int pages = 0,
  int updatedAt = 1000,
}) =>
    db.upsertStudySegment(StudySegmentsCompanion.insert(
      uid: uid,
      deviceId: 'dev',
      mediaKind: kind,
      mediaKey: key,
      title: 'T',
      startAt: start.millisecondsSinceEpoch,
      endAt: end.millisecondsSinceEpoch,
      dateKey: FushiDatabase.statDateKeyOf(start),
      hour: start.hour,
      durationMs: Value(ms),
      chars: Value(chars),
      pages: Value(pages),
      updatedAt: updatedAt,
    ));

Future<Map<String, StudySegmentRow>> _rowsByUid(FushiDatabase db) async =>
    <String, StudySegmentRow>{
      for (final StudySegmentRow r in await db.getStudySegments()) r.uid: r,
    };

/// 从真库派生会话（页面走的正是这条路：`StatFacts.sessions`）。
Future<List<StudySession>> _sessions(FushiDatabase db) async =>
    deriveStudySessions(
      segments: await db.getStudySegments(),
      gameSessions: await db.getRecentGalgameSessions(),
    );

Future<void> _putGame(FushiDatabase db, String id) => db.upsertGalgame(
      GalgamesCompanion.insert(
        id: id,
        name: 'G',
        exePath: '$id.exe',
        workdir: '.',
        addedAt: 0,
      ),
    );

/// StudyClock 的落库替身（观察退役门有没有真的把写挡掉）。
class _Sink {
  final List<StudySegmentsCompanion> writes = <StudySegmentsCompanion>[];

  Future<void> call(StudySegmentsCompanion row) async => writes.add(row);
}

/// 起一台按 [uid] 记账的时钟，跑满一个 tick 后返回它写出的行。
Future<List<StudySegmentsCompanion>> _tickOnce(
  FushiDatabase db,
  String uid,
) async {
  final _Sink sink = _Sink();
  DateTime now = DateTime(2026, 9, 8, 10);
  final StudyClock clock = StudyClock(
    database: db,
    mediaKind: kActivityMediaBook,
    mediaKey: 'b1',
    title: 'T',
    format: 'epub',
    sink: sink.call,
    deviceId: () async => 'dev',
    now: () => now,
    uidFactory: () => uid,
  );
  addTearDown(clock.stop);
  clock.start();
  now = now.add(const Duration(seconds: 60));
  await clock.flushNow();
  return sink.writes;
}

const int _dayMs = 24 * 60 * 60 * 1000;

void main() {
  setUp(debugClearRetiredStudySegmentUids);
  tearDown(debugClearRetiredStudySegmentUids);

  group('改日期：整个会话按日历日之差平移', () {
    test('跨两段的书会话：两段平移同一个量，段间相对间隔不变，字数不动', () async {
      final FushiDatabase db = await _openDb();
      await _putSegment(
        db,
        'a',
        start: DateTime(2026, 9, 8, 10, 0),
        end: DateTime(2026, 9, 8, 10, 30),
        ms: 30 * 60000,
        chars: 300,
      );
      await _putSegment(
        db,
        'b',
        start: DateTime(2026, 9, 8, 10, 40),
        end: DateTime(2026, 9, 8, 11, 0),
        ms: 20 * 60000,
        chars: 700,
      );
      final Map<String, StudySegmentRow> before = await _rowsByUid(db);
      final StudySession session = (await _sessions(db)).single;
      expect(session.segmentUids, <String>['a', 'b']);
      expect(session.chars, 1000);

      await applyStudySessionEdit(
        db,
        session,
        StudySessionEdit(date: DateTime(2026, 9, 1)),
      );

      final Map<String, StudySegmentRow> after = await _rowsByUid(db);
      const int shift = -7 * _dayMs;
      for (final String uid in <String>['a', 'b']) {
        expect(
          after[uid]!.startAt,
          before[uid]!.startAt + shift,
          reason: '$uid 的起点整体平移七天',
        );
        expect(after[uid]!.endAt, before[uid]!.endAt + shift);
        final DateTime start = DateTime.fromMillisecondsSinceEpoch(
          after[uid]!.startAt,
        );
        expect(after[uid]!.dateKey, FushiDatabase.statDateKeyOf(start));
        expect(after[uid]!.hour, start.hour, reason: '段不跨小时的不变式仍成立');
        expect(after[uid]!.chars, before[uid]!.chars, reason: '只改日期不动字数');
        expect(after[uid]!.durationMs, before[uid]!.durationMs);
      }
      expect(after['a']!.dateKey, '2026-09-01');
      expect(
        after['b']!.startAt - after['a']!.startAt,
        before['b']!.startAt - before['a']!.startAt,
        reason: '段间相对间隔逐毫秒不变（逐段换年月日会打乱它）',
      );
      expect(
        (await _sessions(db)).single.startAt,
        DateTime(2026, 9, 1, 10, 0).millisecondsSinceEpoch,
        reason: '改完仍是同一条会话（gap 关系没变）',
      );
    });

    test('改到未来 / 同一天：同一天时不平移，dateKey 原样', () async {
      final FushiDatabase db = await _openDb();
      await _putSegment(
        db,
        'a',
        start: DateTime(2026, 9, 8, 10, 0),
        end: DateTime(2026, 9, 8, 10, 30),
        chars: 5,
      );
      final StudySession session = (await _sessions(db)).single;
      await applyStudySessionEdit(
        db,
        session,
        StudySessionEdit(date: DateTime(2026, 9, 8, 23, 59)),
      );
      final StudySegmentRow row = (await _rowsByUid(db))['a']!;
      expect(row.startAt, DateTime(2026, 9, 8, 10, 0).millisecondsSinceEpoch);
      expect(row.dateKey, '2026-09-08');
    });
  });

  group('改字数：按各段现有字数比例分摊', () {
    test('(300, 700) 改成总数 500 → (150, 350)，时刻一个都不动', () async {
      final FushiDatabase db = await _openDb();
      await _putSegment(
        db,
        'a',
        start: DateTime(2026, 9, 8, 10, 0),
        end: DateTime(2026, 9, 8, 10, 30),
        chars: 300,
      );
      await _putSegment(
        db,
        'b',
        start: DateTime(2026, 9, 8, 10, 40),
        end: DateTime(2026, 9, 8, 11, 0),
        chars: 700,
      );
      final Map<String, StudySegmentRow> before = await _rowsByUid(db);
      final StudySession session = (await _sessions(db)).single;

      await applyStudySessionEdit(
          db, session, const StudySessionEdit(chars: 500));

      final Map<String, StudySegmentRow> after = await _rowsByUid(db);
      expect(after['a']!.chars, 150);
      expect(after['b']!.chars, 350);
      expect(after['a']!.chars + after['b']!.chars, 500, reason: '总和逐字节守恒');
      for (final String uid in <String>['a', 'b']) {
        expect(after[uid]!.startAt, before[uid]!.startAt);
        expect(after[uid]!.endAt, before[uid]!.endAt);
        expect(after[uid]!.dateKey, before[uid]!.dateKey);
        expect(after[uid]!.hour, before[uid]!.hour);
      }
      expect((await _sessions(db)).single.chars, 500);
    });

    test('同时改日期 + 字数：两件事各自生效，互不干扰', () async {
      final FushiDatabase db = await _openDb();
      await _putSegment(
        db,
        'a',
        start: DateTime(2026, 9, 8, 10, 0),
        end: DateTime(2026, 9, 8, 10, 30),
        chars: 300,
      );
      await _putSegment(
        db,
        'b',
        start: DateTime(2026, 9, 8, 10, 40),
        end: DateTime(2026, 9, 8, 11, 0),
        chars: 700,
      );
      final Map<String, StudySegmentRow> before = await _rowsByUid(db);
      final StudySession session = (await _sessions(db)).single;

      await applyStudySessionEdit(
        db,
        session,
        StudySessionEdit(date: DateTime(2026, 9, 10), chars: 500),
      );

      final Map<String, StudySegmentRow> after = await _rowsByUid(db);
      const int shift = 2 * _dayMs;
      expect(after['a']!.startAt, before['a']!.startAt + shift);
      expect(after['b']!.endAt, before['b']!.endAt + shift);
      expect(after['a']!.dateKey, '2026-09-10');
      expect(after['b']!.dateKey, '2026-09-10');
      expect(after['a']!.chars, 150);
      expect(after['b']!.chars, 350);
    });
  });

  test('edit.isEmpty：一行都不写（连 updatedAt 都不推进）', () async {
    final FushiDatabase db = await _openDb();
    await _putSegment(
      db,
      'a',
      start: DateTime(2026, 9, 8, 10, 0),
      end: DateTime(2026, 9, 8, 10, 30),
      chars: 300,
      updatedAt: 4242,
    );
    final StudySession session = (await _sessions(db)).single;
    expect(const StudySessionEdit().isEmpty, isTrue);

    await applyStudySessionEdit(db, session, const StudySessionEdit());

    final StudySegmentRow row = (await _rowsByUid(db))['a']!;
    expect(row.updatedAt, 4242, reason: '空编辑不许推 LWW 戳（会把空操作同步出去）');
    expect(row.startAt, DateTime(2026, 9, 8, 10, 0).millisecondsSinceEpoch);
    expect(row.chars, 300);
    expect(
      await _tickOnce(db, 'a'),
      isNotEmpty,
      reason: '空编辑也不该退役 uid：什么都没改，时钟没有理由停写这一段',
    );
  });

  // ⚠ 本组里「纯时长游戏会话」的两条现在是**红的**，红在生产代码上，不是测试写错：
  // `applyStudySessionEdit`（lib/src/stats/study_sessions.dart:117）对
  // `db.getStudySegmentsByUids` 的返回值直接 `sort`，而该 DAO 在 uid 集为空时返回
  // `const <StudySegmentRow>[]`（packages/fushi_core/.../database_statistics.part.dart:388）
  // ——不可变列表，`sort` 直接抛 `Unsupported operation: Cannot modify an unmodifiable
  // list`。而「一条字数段都没有」正是纯时长游玩会话的常态，也正是 chars-only 段特例
  // 存在的理由：这条路径现在是 100% 崩的。修法二选一（生产侧）：DAO 空集返回可增长
  // 空列表，或入口先 `List.of(...)` 再排。红着比绿着有用，别把这两条删掉或 skip。
  group('游戏会话', () {
    test('骨架行跟着平移（起止 + dateKey），吸收的字数段同量平移', () async {
      final FushiDatabase db = await _openDb();
      await _putGame(db, 'g1');
      final int gid = await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: DateTime(2026, 9, 8, 20, 0).millisecondsSinceEpoch,
          endMs: DateTime(2026, 9, 8, 21, 0).millisecondsSinceEpoch,
          durationSeconds: 3600,
          dateKey: '2026-09-08',
        ),
      );
      await _putSegment(
        db,
        'h1',
        kind: kActivityMediaGame,
        key: 'g1',
        start: DateTime(2026, 9, 8, 20, 10),
        end: DateTime(2026, 9, 8, 20, 50),
        ms: 0,
        chars: 800,
      );
      final StudySession session = (await _sessions(db)).single;
      expect(session.gameSessionId, gid);
      expect(session.segmentUids, <String>['h1']);

      await applyStudySessionEdit(
        db,
        session,
        StudySessionEdit(date: DateTime(2026, 9, 5)),
      );

      final GalgameSessionRow game =
          (await db.getRecentGalgameSessions()).single;
      expect(
        game.startMs,
        DateTime(2026, 9, 5, 20, 0).millisecondsSinceEpoch,
        reason: '骨架行的游玩时长挂在它自己身上，不跟着平移就与段对不上',
      );
      expect(game.endMs, DateTime(2026, 9, 5, 21, 0).millisecondsSinceEpoch);
      expect(game.dateKey, '2026-09-05');
      final StudySegmentRow row = (await _rowsByUid(db))['h1']!;
      expect(row.startAt, DateTime(2026, 9, 5, 20, 10).millisecondsSinceEpoch);
      expect(row.dateKey, '2026-09-05');
      final StudySession after = (await _sessions(db)).single;
      expect(after.gameSessionId, gid, reason: '平移后骨架仍吸收得住这一段');
      expect(after.chars, 800);
      expect(after.durationMs, 3600 * 1000);
    });

    test('纯时长游戏会话改字数：新建 chars-only 段，下次派生被同一骨架吸收', () async {
      final FushiDatabase db = await _openDb();
      await _putGame(db, 'g1');
      final int gid = await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: DateTime(2026, 9, 8, 20, 0).millisecondsSinceEpoch,
          endMs: DateTime(2026, 9, 8, 21, 0).millisecondsSinceEpoch,
          durationSeconds: 3600,
          dateKey: '2026-09-08',
        ),
      );
      final StudySession session = (await _sessions(db)).single;
      expect(session.segmentUids, isEmpty, reason: '一条字数段都没有：纯时长会话');

      await applyStudySessionEdit(
        db,
        session,
        const StudySessionEdit(chars: 4200),
      );

      final List<StudySegmentRow> rows = await db.getStudySegments();
      expect(rows, hasLength(1), reason: '没有行可写就得新建一条');
      final StudySegmentRow created = rows.single;
      expect(created.mediaKind, kActivityMediaGame);
      expect(created.mediaKey, 'g1');
      expect(created.chars, 4200);
      expect(created.durationMs, 0, reason: '时长只存在于骨架行上（hook 字数段同形）');
      final GalgameSessionRow game =
          (await db.getRecentGalgameSessions()).single;
      expect(
        created.startAt < game.endMs && created.endAt > game.startMs,
        isTrue,
        reason: '新段必须与骨架区间相交，否则吸收不回去',
      );

      // 真正要保的东西：下一次派生仍是**一条**会话，字数落在它身上。
      final List<StudySession> after = await _sessions(db);
      expect(after, hasLength(1), reason: '不许多出一条 0 分钟的孤儿会话');
      expect(after.single.gameSessionId, gid);
      expect(after.single.chars, 4200);
      expect(after.single.durationMs, 3600 * 1000);
    });

    test('纯时长游戏会话只改日期：不凭空造字数段', () async {
      final FushiDatabase db = await _openDb();
      await _putGame(db, 'g1');
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: DateTime(2026, 9, 8, 20, 0).millisecondsSinceEpoch,
          endMs: DateTime(2026, 9, 8, 21, 0).millisecondsSinceEpoch,
          durationSeconds: 3600,
          dateKey: '2026-09-08',
        ),
      );
      final StudySession session = (await _sessions(db)).single;

      await applyStudySessionEdit(
        db,
        session,
        StudySessionEdit(date: DateTime(2026, 9, 5)),
      );

      expect(await db.getStudySegments(), isEmpty);
      expect(
        (await db.getRecentGalgameSessions()).single.startMs,
        DateTime(2026, 9, 5, 20, 0).millisecondsSinceEpoch,
      );
    });
  });

  group('退役纪律（写库之前先退役，否则时钟把旧值原样写回来）', () {
    test('改完之后，按同一 uid 记账的时钟一笔都不再写', () async {
      final FushiDatabase db = await _openDb();
      await _putSegment(
        db,
        'a',
        start: DateTime(2026, 9, 8, 10, 0),
        end: DateTime(2026, 9, 8, 10, 30),
        chars: 300,
      );
      final StudySession session = (await _sessions(db)).single;
      expect(
        await _tickOnce(db, 'other-uid'),
        isNotEmpty,
        reason: '对照：没被退役的段照常写（否则本测试恒绿）',
      );

      await applyStudySessionEdit(
          db, session, const StudySessionEdit(chars: 42));

      expect(
        await _tickOnce(db, 'a'),
        isEmpty,
        reason: '退役之后再写就是把用户刚改完的段按旧绝对值弹回去',
      );
    });

    test('源码顺序守卫：retireStudySegmentUids 出现在 updateStudySession 之前', () {
      final String source =
          File('../packages/fushi_engine/lib/stats/study_sessions.dart').readAsStringSync();
      final int body = source.indexOf('Future<void> applyStudySessionEdit(');
      expect(body, greaterThan(0), reason: '入口改名了就来这里同步改');
      final int retire = source.indexOf('retireStudySegmentUids(', body);
      final int write = source.indexOf('db.updateStudySession(', body);
      expect(retire, greaterThan(0));
      expect(write, greaterThan(0));
      expect(
        retire,
        lessThan(write),
        reason: '顺序反了 = 退役与写库之间落下的 tick 会把旧绝对值写回去',
      );
    });
  });

  group('deleteStudySessions（清除全部会话）', () {
    test('整批清光：段写零、游戏骨架硬删、不立墓碑；空列表直接返回', () async {
      final FushiDatabase db = await _openDb();
      await _putGame(db, 'g1');
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: DateTime(2026, 9, 8, 20, 0).millisecondsSinceEpoch,
          endMs: DateTime(2026, 9, 8, 21, 0).millisecondsSinceEpoch,
          durationSeconds: 3600,
          dateKey: '2026-09-08',
        ),
      );
      await _putSegment(
        db,
        'a',
        start: DateTime(2026, 9, 8, 10, 0),
        end: DateTime(2026, 9, 8, 10, 30),
        chars: 300,
      );
      await _putSegment(
        db,
        'b',
        key: 'b2',
        start: DateTime(2026, 9, 7, 10, 0),
        end: DateTime(2026, 9, 7, 10, 30),
        chars: 700,
      );
      final List<StudySession> sessions = await _sessions(db);
      expect(sessions, hasLength(3));

      await deleteStudySessions(db, const <StudySession>[]);
      expect(await _sessions(db), hasLength(3), reason: '空列表是 no-op');

      await deleteStudySessions(db, sessions);

      expect(await _sessions(db), isEmpty);
      expect(await db.getStudySegments(), hasLength(2), reason: '写零不删行');
      expect(await db.getRecentGalgameSessions(), isEmpty, reason: '骨架行硬删');
      expect(
        await db.getStudySegmentTombstones(),
        isEmpty,
        reason: '不立墓碑：碑会压死这本书的全部历史',
      );
      expect(
        await _tickOnce(db, 'a'),
        isEmpty,
        reason: '批量清除同样要先退役，否则在跑的时钟把段复活',
      );
    });
  });
}
