import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/fake_engine.dart';

const String kP = 'profile-uid';
const int kT0 = 1700000000000;
const int kDayMs = 86400000;
const SrsDayContext kDayCtx = SrsDayContext(utcOffsetMin: 0, rolloverHour: 4);

int _seq = 0;

SrsReviewLog _log({
  required String card,
  required String kind,
  required int at,
  int? rating,
  String? revokes,
  String origin = SrsLogOrigin.fushi,
  String reviewType = SrsReviewType.review,
  SrsScheduleResult? result,
  int? ankiId,
  String writer = 'w',
  int counter = 0,
}) => SrsReviewLog(
  id: 'log-${_seq++}'.padLeft(12, '0'),
  profileUid: kP,
  cardId: card,
  kind: kind,
  rating: rating,
  revokesId: revokes,
  hlc: Hlc(at, counter, writer),
  occurredAt: at,
  timeSource: SrsTimeSource.anchored,
  origin: origin,
  reviewType: reviewType,
  ankiRevlogId: ankiId,
  result:
      result ??
      (kind == SrsLogKind.undo
          ? null
          : const SrsScheduleResult(queue: SrsQueue.review, dueDay: 1)),
);

/// 「恢复到备份时间点」照抄状态的 manual 日志（判据在 native/fushi_fsrs/src/projection.rs
/// `is_restore_state`；测试只用它断言恢复计划写出的日志形状）。
bool _isRestoreState(SrsReviewLog l) =>
    l.kind == SrsLogKind.manual &&
    l.result != null &&
    l.extra[srsRestoreLogExtraKey] != null &&
    !(l.result!.queue == SrsQueue.newCard && l.result!.reps == 0);

void main() {
  group('确定性 ID', () {
    test('UUIDv5 与 RFC 测试向量一致', () {
      expect(
        uuidV5('6ba7b810-9dad-11d1-80b4-00c04fd430c8', 'python.org'),
        '886313e1-3b8a-5372-9b90-0c9aee199e5d',
      );
    });

    test('同一来源在两台设备上派生出同一 ID，与本机状态无关', () {
      final String nt = SrsIds.noteType(kP, 12345);
      expect(SrsIds.noteType(kP, 12345), nt);
      expect(SrsIds.fieldByName(nt, 'Front'), SrsIds.fieldByName(nt, 'Front'));
      final String note = SrsIds.note(kP, 'abc');
      final String tpl = SrsIds.template(nt, 7);
      expect(SrsIds.card(note, tpl, 0), SrsIds.card(note, tpl, 0));
      expect(SrsIds.card(note, tpl, 1), isNot(SrsIds.card(note, tpl, 2)));
    });

    test('内置笔记类型走通用规则：导出 → 导入回到同一 ID（第六轮审查第 8 条）', () {
      final int lapisNum = SrsIds.builtinNoteTypeAnkiNum('lapis');
      // 导出写进 .apkg 的笔记类型 id 就是 ankiNum；回导时按通用规则派生。
      expect(SrsIds.noteType(kP, lapisNum), SrsIds.noteType(kP, lapisNum));
      expect(lapisNum, greaterThan(0));
      expect(lapisNum, lessThan(1 << 53));
    });

    test('fushi-ext 跨 profile 导入：日志与 revokesId 用同一函数重映射', () {
      expect(
        SrsIds.remappedLog(SrsIds.note(kP, 'g'), 'orig-1'),
        SrsIds.remappedLog(SrsIds.note(kP, 'g'), 'orig-1'),
      );
    });

    test('UUIDv7 单调前缀', () {
      final String a = uuidV7(nowMs: 1000);
      final String b = uuidV7(nowMs: 2000);
      expect(a.compareTo(b), lessThan(0));
      expect(a[14], '7');
    });
  });

  group('因果上下文', () {
    test('cloud 并入连续前缀；JSON 往返', () {
      SrsCausalContext c = SrsCausalContext.empty();
      c = c.add(const SrsDot('A', 2)).add(const SrsDot('A', 3));
      expect(c.vv['A'], isNull);
      c = c.add(const SrsDot('A', 1));
      expect(c.vv['A'], 3);
      expect(c.cloud, isEmpty);
      final SrsCausalContext d = SrsCausalContext.fromJson(
        c.add(const SrsDot('B', 5)).toJson(),
      );
      expect(d.contains(const SrsDot('B', 5)), isTrue);
      expect(d.contains(const SrsDot('B', 4)), isFalse);
      expect(d.covers(c), isTrue);
    });
  });

  group('有效日志（铁律 B）', () {
    test('撤销最后一条后状态回到前一条；撤销到无日志 = 新卡', () {
      final SrsReviewLog l1 = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 10),
      );
      final SrsReviewLog u1 = _log(
        card: 'c',
        kind: SrsLogKind.undo,
        at: kT0 + 1,
        revokes: l1.id,
      );
      expect(
        SrsCardHistory(<SrsReviewLog>[l1, u1]).state,
        SrsScheduleResult.initial,
      );
      final SrsReviewLog l2 = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 2,
        rating: 3,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 20),
      );
      final SrsReviewLog u2 = _log(
        card: 'c',
        kind: SrsLogKind.undo,
        at: kT0 + 3,
        revokes: l2.id,
      );
      final SrsCardHistory h = SrsCardHistory(
        <SrsReviewLog>[l1, u1, l2, u2].reversed,
      );
      expect(h.state, SrsScheduleResult.initial);
      expect(h.effectiveRatings, isEmpty);
    });

    test('并发：A 撤销 L，B 已基于 L 写了 M → M 仍有效且是最后一条，不级联', () {
      final SrsReviewLog l = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
        writer: 'A',
      );
      final SrsReviewLog m = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 5000,
        rating: 3,
        writer: 'B',
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 42),
      );
      final SrsReviewLog u = _log(
        card: 'c',
        kind: SrsLogKind.undo,
        at: kT0 + 3000,
        revokes: l.id,
        writer: 'A',
      );
      final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[m, u, l]);
      expect(h.lastEffective!.id, m.id);
      expect(h.effectiveRatings.map((SrsReviewLog x) => x.id), <String>[m.id]);
    });

    test('同一组日志不论收到顺序，选取结果相同', () {
      final List<SrsReviewLog> logs = <SrsReviewLog>[
        for (int i = 0; i < 6; i++)
          _log(
            card: 'c',
            kind: SrsLogKind.review,
            at: kT0 + i * 1000,
            rating: 1 + i % 4,
            writer: i.isEven ? 'A' : 'B',
            result: SrsScheduleResult(queue: SrsQueue.review, dueDay: i),
          ),
      ];
      final String first = SrsCardHistory(logs).lastEffective!.id;
      expect(SrsCardHistory(logs.reversed).lastEffective!.id, first);
    });

    test('不认识的 kind 原样保留但不参与状态', () {
      final SrsReviewLog a = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
      );
      final SrsReviewLog z = _log(card: 'c', kind: 'futureKind', at: kT0 + 1);
      final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[a, z]);
      expect(h.lastEffective!.id, a.id);
      expect(h.all, hasLength(2));
      final SrsReviewLog round = SrsReviewLog.fromJson(<String, Object?>{
        ...z.toJson(),
        'newField': 'kept',
      });
      expect(round.toJson()['newField'], 'kept');
    });

    test('导入复习与原生复习等价：1 秒内、同卡同评分；只比评分类', () {
      final SrsReviewLog native = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
      );
      final SrsReviewLog imported = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 1,
        rating: 3,
        origin: SrsLogOrigin.anki,
        ankiId: kT0 + 1,
        writer: 'anki',
      );
      final SrsReviewLog manualImport = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 1,
        rating: 3,
        origin: SrsLogOrigin.anki,
        ankiId: kT0 + 1,
        writer: 'anki',
        reviewType: SrsReviewType.manual,
      );
      final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[
        native,
        imported,
        manualImport,
      ]);
      expect(h.equivalentImports, <String>{imported.id});
      expect(h.effectiveRatings.map((SrsReviewLog x) => x.id), <String>[
        native.id,
      ]);
    });

    test('scheduler 只由移交事件决定：导入锚点不改归属', () {
      final SrsReviewLog r = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
      );
      final SrsReviewLog hand = _log(
        card: 'c',
        kind: SrsLogKind.handOff,
        at: kT0 + 1,
        result: const SrsScheduleResult(
          queue: SrsQueue.review,
          scheduler: SrsScheduler.anki,
        ),
      );
      final SrsReviewLog anchor = _log(
        card: 'c',
        kind: SrsLogKind.importAnchor,
        at: kT0 + 2,
        writer: 'anki',
        origin: SrsLogOrigin.anki,
        reviewType: SrsReviewType.manual,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 3),
      );
      final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[r, hand, anchor]);
      expect(h.scheduler, SrsScheduler.anki);
      expect(h.state.scheduler, SrsScheduler.anki);
      expect(h.state.dueDay, 3);
    });
  });

  group('S/D 输入（铁律 A）', () {
    test('历史完整：从新卡算起，忽略锚点；FSRS-7 用小数天', () {
      final SrsReviewLog a = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
        reviewType: SrsReviewType.learn,
      );
      final SrsReviewLog anchor = _log(
        card: 'c',
        kind: SrsLogKind.importAnchor,
        at: kT0 + kDayMs,
        reviewType: SrsReviewType.manual,
      );
      final SrsReviewLog b = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + kDayMs * 3 ~/ 2,
        rating: 3,
      );
      final SrsMemoryInput input = srsCollectMemoryInput(
        SrsCardHistory(<SrsReviewLog>[a, anchor, b]),
        algorithm: SrsAlgorithm.fsrs7,
        day: kDayCtx,
      );
      expect(input.complete, isTrue);
      expect(input.reviews.map((SrsFsrsReview r) => r.deltaDays), <double>[
        0,
        1.5,
      ]);
      final SrsMemoryInput six = srsCollectMemoryInput(
        SrsCardHistory(<SrsReviewLog>[a, anchor, b]),
        algorithm: SrsAlgorithm.fsrs6,
        day: kDayCtx,
      );
      expect(
        six.reviews.last.deltaDays,
        (kDayCtx.dayIndexOf(kT0 + kDayMs * 3 ~/ 2) - kDayCtx.dayIndexOf(kT0))
            .toDouble(),
        reason: 'FSRS-6 按翻日后的日序号取整',
      );
    });

    test('历史不完整：从锚点 SM-2 换算，接上锚点之后的评分', () {
      final SrsReviewLog anchor = _log(
        card: 'c',
        kind: SrsLogKind.importAnchor,
        at: kT0,
        reviewType: SrsReviewType.manual,
        result: SrsScheduleResult(
          queue: SrsQueue.review,
          scheduledDays: 20,
          lastReviewedAt: kT0 - 20 * kDayMs,
        ),
      );
      final SrsReviewLog r = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 5 * kDayMs,
        rating: 3,
      );
      final SrsMemoryInput input = srsCollectMemoryInput(
        SrsCardHistory(<SrsReviewLog>[anchor, r]),
        algorithm: SrsAlgorithm.fsrs7,
        day: kDayCtx,
      );
      expect(input.complete, isFalse);
      expect(input.sm2Start, isNotNull);
      expect(input.reviews.single.deltaDays, 25.0);
    });

    test('重置之后从新起点算', () {
      final SrsReviewLog a = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 1,
        reviewType: SrsReviewType.learn,
      );
      final SrsReviewLog reset = _log(
        card: 'c',
        kind: SrsLogKind.manual,
        at: kT0 + 1000,
        reviewType: SrsReviewType.manual,
        result: const SrsScheduleResult(queue: SrsQueue.newCard),
      );
      final SrsReviewLog b = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 2000,
        rating: 4,
        reviewType: SrsReviewType.learn,
      );
      final SrsMemoryInput input = srsCollectMemoryInput(
        SrsCardHistory(<SrsReviewLog>[a, reset, b]),
        algorithm: SrsAlgorithm.fsrs7,
        day: kDayCtx,
      );
      expect(input.reviews.map((SrsFsrsReview r) => r.rating), <int>[4]);
    });
  });

  group('评分（PR1 策略）', () {
    SrsLogContext ctx(int Function() now) => SrsLogContext(
      profileUid: kP,
      clock: HlcClock('dev#1'),
      now: () => (now(), SrsTimeSource.anchored),
      day: kDayCtx,
    );
    const SrsCardOps ops = SrsCardOps(engine: FakeFsrsEngine());

    test('新卡按学习步走：Again→步 0，Good→步 1，再 Good 毕业', () {
      int now = kT0;
      final List<SrsReviewLog> logs = <SrsReviewLog>[];
      SrsReviewLog rate(int r) {
        final SrsReviewLog l = ops.answer(
          cardId: 'card',
          history: SrsCardHistory(logs),
          rating: r,
          config: const SrsSchedulingConfig(),
          ctx: ctx(() => now),
        );
        logs.add(l);
        return l;
      }

      expect(rate(1).result!.queue, SrsQueue.learning);
      expect(logs.last.reviewType, SrsReviewType.learn);
      now += 60000;
      final SrsReviewLog g = rate(3);
      expect(g.result!.queue, SrsQueue.learning);
      expect(g.result!.learningStep, 1);
      now += 600000;
      final SrsReviewLog grad = rate(3);
      expect(grad.result!.queue, SrsQueue.review);
      expect(grad.result!.reps, 3);
      expect(grad.result!.dueDay, greaterThan(kDayCtx.dayIndexOf(now)));
    });

    test('elapsed = 评分时刻 − lastReviewedAt：中间导入 / 改期不改变它（13 天的例子）', () {
      const int oct1 = kT0;
      const SrsScheduleResult reviewed = SrsScheduleResult(
        queue: SrsQueue.review,
        dueDay: 1,
        scheduledDays: 5,
        lastReviewedAt: oct1,
        reps: 3,
      );
      final SrsScheduleResult moved = srsManualSetDue(
        reviewed,
        dueDay: 99,
        today: 50,
      );
      expect(moved.lastReviewedAt, oct1);
      final SrsAnswerContext a = SrsAnswerContext(
        cardId: 'c',
        current: moved,
        nowMs: oct1 + 13 * kDayMs,
        day: kDayCtx,
        config: const SrsSchedulingConfig(),
      );
      expect(a.elapsedDaysFor(SrsAlgorithm.fsrs7), 13.0);
      expect(a.elapsedDaysFor(SrsAlgorithm.fsrs6), 13.0);
    });

    test('复习卡：hard < good < easy，Again 记一次 lapse 并进重学', () {
      final SrsAnswerContext a = SrsAnswerContext(
        cardId: 'c',
        current: const SrsScheduleResult(
          queue: SrsQueue.review,
          scheduledDays: 10,
          lastReviewedAt: kT0,
          reps: 5,
          dueDay: 10,
        ),
        nowMs: kT0 + 10 * kDayMs,
        day: kDayCtx,
        config: const SrsSchedulingConfig(),
      );
      final SrsAnswerPlan plan = srsPlanAnswer(
        a,
        const FakeFsrsEngine().nextStates(
          algorithm: SrsAlgorithm.fsrs7,
          params: const <double>[],
          desiredRetention: 0.9,
          memory: const SrsMemory(stability: 10, difficulty: 5),
          elapsedDays: 10,
        ),
      );
      expect(plan[1].queue, SrsQueue.relearning);
      expect(plan[1].lapses, 1);
      expect(plan[2].scheduledDays, lessThan(plan[3].scheduledDays));
      expect(plan[3].scheduledDays, lessThan(plan[4].scheduledDays));
      expect(plan[3].scheduledDays, greaterThanOrEqualTo(10), reason: '#4431');
    });

    test('fuzz 确定性', () {
      expect(srsFuzzFactor('card-x', 3), srsFuzzFactor('card-x', 3));
      expect(srsFuzzFactor('card-x', 3), isNot(srsFuzzFactor('card-x', 4)));
      final ({int min, int max}) r = srsFuzzRange(30, 1, 36500);
      expect(r.min, lessThan(30));
      expect(r.max, greaterThan(30));
    });

    test('步长只允许当天以内', () {
      expect(srsValidateSteps(<double>[1, 10]), isTrue);
      expect(srsValidateSteps(<double>[1, 1440]), isFalse);
      expect(srsSanitizeSteps(<double>[1440, 4320], <double>[1, 10]), <double>[
        1,
        10,
      ]);
      expect(srsSanitizeSteps(<double>[5, 1440], <double>[1]), <double>[5]);
    });

    test('撤销只允许最后一条有效日志', () {
      final SrsReviewLog a = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
      );
      final SrsReviewLog b = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 10,
        rating: 3,
      );
      final SrsCardHistory h = SrsCardHistory(<SrsReviewLog>[a, b]);
      expect(
        ops.undo(
          cardId: 'c',
          history: h,
          targetLogId: a.id,
          ctx: ctx(() => kT0 + 20),
        ),
        isNull,
      );
      expect(
        ops
            .undo(
              cardId: 'c',
              history: h,
              targetLogId: b.id,
              ctx: ctx(() => kT0 + 20),
            )!
            .revokesId,
        b.id,
      );
    });
  });

  group('翻日', () {
    test('凌晨 4 点前算前一天', () {
      final int day = srsDateToDay(2026, 10, 14);
      final int at3am = DateTime.utc(2026, 10, 14, 3).millisecondsSinceEpoch;
      final int at5am = DateTime.utc(2026, 10, 14, 5).millisecondsSinceEpoch;
      expect(kDayCtx.dayIndexOf(at3am), day - 1);
      expect(kDayCtx.dayIndexOf(at5am), day);
    });
  });

  group('新卡预算', () {
    test('数据不足按上限 × 10；超 2 倍预算暂停；中间按比例', () {
      SrsNewCardBudget b = srsComputeNewCardBudget(
        newPerDayLimit: 20,
        dueReviews: 100,
        reviewsPerDayLast30: <int>[50],
      );
      expect(b.allowed, 20);
      b = srsComputeNewCardBudget(
        newPerDayLimit: 20,
        dueReviews: 401,
        reviewsPerDayLast30: <int>[50],
      );
      expect(b.reason, SrsNewCardBudgetReason.paused);
      b = srsComputeNewCardBudget(
        newPerDayLimit: 20,
        dueReviews: 300,
        reviewsPerDayLast30: <int>[50],
      );
      expect(b.reason, SrsNewCardBudgetReason.reduced);
      expect(b.allowed, 10);
      b = srsComputeNewCardBudget(
        newPerDayLimit: 20,
        dueReviews: 250,
        reviewsPerDayLast30: <int>[
          for (int i = 0; i < 30; i++) i.isEven ? 300 : 0,
        ],
      );
      expect(b.reviewBudget, 450, reason: '只按有复习的天平均');
      expect(b.allowed, 20);
    });

    final List<int> steady = <int>[for (int i = 0; i < 30; i++) 100];

    test('关掉按复习量调整：到期再多也按基数出', () {
      final SrsNewCardBudget b = srsComputeNewCardBudget(
        newPerDayLimit: 20,
        dueReviews: 5000,
        reviewsPerDayLast30: steady,
        plan: const SrsNewCardPlan(autoLoad: false),
      );
      expect(b.allowed, 20);
      expect(b.reason, isNull);
    });

    test('预算百分比：100% 时日均 100 → 预算 = max(100, 上限 × 10)', () {
      final SrsNewCardBudget b = srsComputeNewCardBudget(
        newPerDayLimit: 5,
        dueReviews: 150,
        reviewsPerDayLast30: steady,
        plan: const SrsNewCardPlan(budgetPercent: 100),
      );
      expect(b.reviewBudget, 100);
      expect(b.reason, SrsNewCardBudgetReason.reduced);
      expect(b.allowed, 2);
    });

    test('复习少时多出：0 到期时 +boost%，一半预算处不加', () {
      SrsNewCardBudget b = srsComputeNewCardBudget(
        newPerDayLimit: 10,
        dueReviews: 0,
        reviewsPerDayLast30: steady,
        plan: const SrsNewCardPlan(boostPercent: 50),
      );
      expect(b.reason, SrsNewCardBudgetReason.increased);
      expect(b.allowed, 15);
      b = srsComputeNewCardBudget(
        newPerDayLimit: 10,
        dueReviews: 75,
        reviewsPerDayLast30: steady,
        plan: const SrsNewCardPlan(boostPercent: 50),
      );
      expect(b.allowed, 10);
      expect(b.reason, isNull);
    });

    test('新卡计划值对象：缺省 / 坏值回落，越界夹住，往返不变', () {
      expect(SrsNewCardPlan.fromValue(null), const SrsNewCardPlan());
      expect(
        SrsNewCardPlan.fromValue(<String, Object?>{
          'auto': 'x',
          'budget': 5,
          'boost': 99999,
        }),
        const SrsNewCardPlan(
          budgetPercent: SrsNewCardPlan.minBudgetPercent,
          boostPercent: SrsNewCardPlan.maxBoostPercent,
        ),
      );
      const SrsNewCardPlan p = SrsNewCardPlan(
        autoLoad: false,
        budgetPercent: 200,
        boostPercent: 30,
      );
      expect(SrsNewCardPlan.fromValue(p.toValue()), p);
    });
  });

  group('Anki 导入规则', () {
    test('遗忘过的卡（来源新卡但有重置 revlog）照常写锚点', () {
      final SrsAnchorDecision d = srsDecideAnchor(
        sourceIsNew: true,
        revlogs: const <SrsAnkiRevlogRow>[
          SrsAnkiRevlogRow(id: 100, ease: 3, type: 1, ivl: 5, factor: 2500),
          SrsAnkiRevlogRow(id: 200, ease: 0, type: 4, ivl: 0, factor: 0),
        ],
        collectionCreatedMs: 1,
        equivalentToNative: (_) => false,
      );
      expect(d.write, isTrue);
      expect(d.anchorMs, 200);
    });

    test('从没学过的新卡不写；Filtered 不算排程相关；往返无变化不写；历史被裁用 crt', () {
      expect(
        srsDecideAnchor(
          sourceIsNew: true,
          revlogs: const <SrsAnkiRevlogRow>[],
          collectionCreatedMs: 1,
          equivalentToNative: (_) => false,
        ).write,
        isFalse,
      );
      expect(
        srsDecideAnchor(
          sourceIsNew: false,
          revlogs: const <SrsAnkiRevlogRow>[
            SrsAnkiRevlogRow(id: 9, ease: 3, type: 3, ivl: 1, factor: 2500),
          ],
          collectionCreatedMs: 7,
          equivalentToNative: (_) => false,
        ).anchorMs,
        7,
      );
      expect(
        srsDecideAnchor(
          sourceIsNew: false,
          revlogs: const <SrsAnkiRevlogRow>[
            SrsAnkiRevlogRow(id: 9, ease: 3, type: 1, ivl: 1, factor: 2500),
          ],
          collectionCreatedMs: 7,
          equivalentToNative: (_) => true,
        ).write,
        isFalse,
      );
    });
  });

  group('物化', () {
    test('内置定义跟随代码，改过的项由修改记录决定', () {
      const String nt = 'nt';
      const SrsBuiltinNoteType builtin = SrsBuiltinNoteType(
        key: 'lapis',
        name: 'Lapis',
        kind: SrsNoteTypeKind.standard,
        fields: <SrsFieldDef>[
          SrsFieldDef(id: 'f1', name: 'Expression', ord: 0),
          SrsFieldDef(id: 'f2', name: 'Sentence', ord: 1),
        ],
        templates: <SrsTemplateDef>[
          SrsTemplateDef(
            id: 't1',
            name: 'Card 1',
            ord: 0,
            front: 'v2 front',
            back: 'b',
          ),
        ],
        css: 'code css',
      );
      final SrsEditWriter w = SrsEditWriter(writerId: 'w');
      final SrsFieldEdit rename = w.create(
        profileUid: kP,
        entityKind: SrsEntityKind.noteType,
        entityId: nt,
        fieldKey: SrsFieldKeys.fieldDef('f2'),
        value: const SrsFieldDef(id: 'f2', name: '例句', ord: 1).toValue(),
        hlc: const Hlc(1, 0, 'w'),
        timeSource: SrsTimeSource.wall,
      );
      final SrsNoteTypeView v = srsMaterializeNoteTypes(
        <(SrsEntitySource, SrsBuiltinNoteType?)>[
          (
            SrsEntitySource.record(
              const SrsEntityRecord(
                id: nt,
                profileUid: kP,
                kind: SrsEntityKind.noteType,
                payload: <String, Object?>{'ankiNum': 1, 'builtin': 'lapis'},
              ),
              <SrsEditItem>[SrsEditItem.of(rename, null)],
            ),
            builtin,
          ),
        ],
      ).single;
      expect(v.fields.map((SrsFieldDef f) => f.name), <String>[
        'Expression',
        '例句',
      ]);
      expect(v.templates.single.front, 'v2 front');
      expect(v.css, 'code css');
      expect(v.name, 'Lapis');
    });

    test('牌组树：成环确定性打破；参数继承', () {
      SrsDeckView deck(String id, String? parent, {bool own = false}) {
        final SrsEditWriter w = SrsEditWriter(writerId: 'w$id');
        final List<SrsFieldEdit> e = <SrsFieldEdit>[
          w.create(
            profileUid: kP,
            entityKind: SrsEntityKind.deck,
            entityId: id,
            fieldKey: SrsFieldKeys.name,
            value: id,
            hlc: const Hlc(1, 0, 'w'),
            timeSource: SrsTimeSource.wall,
          ),
          if (parent != null)
            w.create(
              profileUid: kP,
              entityKind: SrsEntityKind.deck,
              entityId: id,
              fieldKey: SrsFieldKeys.deckParent,
              value: parent,
              hlc: const Hlc(1, 0, 'w'),
              timeSource: SrsTimeSource.wall,
            ),
          if (own)
            w.create(
              profileUid: kP,
              entityKind: SrsEntityKind.deck,
              entityId: id,
              fieldKey: SrsFieldKeys.deckParamsMode,
              value: 'own',
              hlc: const Hlc(1, 0, 'w'),
              timeSource: SrsTimeSource.wall,
            ),
        ];
        return srsMaterializeDecks(<SrsEntitySource>[
          SrsEntitySource.record(
            SrsEntityRecord(
              id: id,
              profileUid: kP,
              kind: SrsEntityKind.deck,
              payload: const <String, Object?>{},
            ),
            <SrsEditItem>[
              for (final SrsFieldEdit x in e) SrsEditItem.of(x, null),
            ],
          ),
        ]).single;
      }

      final SrsDeckTree cyc = SrsDeckTree(<SrsDeckView>[
        deck('b', 'a'),
        deck('a', 'b'),
      ]);
      expect(cyc.parentOf('a'), isNull);
      expect(cyc.parentOf('b'), 'a');
      expect(cyc.cycleBroken, <String>{'a'});

      final SrsDeckTree t = SrsDeckTree(<SrsDeckView>[
        deck('root', null),
        deck('child', 'root'),
        deck('own', 'root', own: true),
        deck('grand', 'own'),
      ]);
      expect(t.paramsOwner('child').id, 'root');
      expect(t.paramsOwner('grand').id, 'own');
      expect(t.paramsScope('root'), unorderedEquals(<String>['root', 'child']));
      expect(t.fullName('grand'), 'root::own::grand');
    });
  });

  group('词状态', () {
    test('termKey 去 HTML / 注音；同形异读由读音区分（第六轮审查第 20 条）', () {
      expect(srsTermKey('<b>上手</b>'), '上手');
      expect(srsTermKey('上手[じょうず]'), '上手');
      expect(
        const SrsTermQuery('上手', 'じょうず').readingKey,
        isNot(const SrsTermQuery('上手', 'うわて').readingKey),
      );
      expect(srsTermKey('ＡＢＣ'), 'abc');
    });
  });

  group('恢复计划（重放副本优先，旧版本客户端不分歧）', () {
    SrsLogContext ctx() => SrsLogContext(
      profileUid: kP,
      clock: HlcClock('dev#9'),
      now: () => (kT0 + 30 * kDayMs, SrsTimeSource.anchored),
      day: kDayCtx,
    );
    List<(int, double)> shape(SrsMemoryInput m) => <(int, double)>[
      for (final SrsFsrsReview r in m.reviews) (r.rating, r.deltaDays),
    ];
    SrsMemoryInput memory(SrsCardHistory h) =>
        srsCollectMemoryInput(h, algorithm: SrsAlgorithm.fsrs7, day: kDayCtx);

    test('被撤销的是备份时有效历史的尾巴：重放副本，有效历史与备份逐条同构、不需要 ③′', () {
      final SrsReviewLog r1 = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
        reviewType: SrsReviewType.learn,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 2),
      );
      final SrsReviewLog r2 = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 2 * kDayMs,
        rating: 3,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 9),
      );
      final SrsReviewLog u = _log(
        card: 'c',
        kind: SrsLogKind.undo,
        at: kT0 + 3 * kDayMs,
        revokes: r2.id,
      );
      final SrsCardHistory backup = SrsCardHistory(<SrsReviewLog>[r1, r2]);
      final SrsCardHistory current = SrsCardHistory(<SrsReviewLog>[r1, r2, u]);
      expect(current.state, isNot(backup.state));

      final List<SrsReviewLog> plan = srsPlanStateRestore(
        cardId: 'c',
        current: current,
        backupLogIds: <String>{r1.id, r2.id},
        ctx: ctx(),
        backupId: 'bk',
      );
      expect(plan, hasLength(1));
      final SrsReviewLog copy = plan.single;
      expect(copy.kind, SrsLogKind.review);
      expect(copy.id, isNot(r2.id));
      expect(copy.rating, r2.rating);
      expect(copy.occurredAt, r2.occurredAt);
      expect(copy.result, r2.result);
      expect(copy.extra[srsReplayOfLogExtraKey], r2.id);
      expect(copy.extra[srsRestoreLogExtraKey], 'bk');

      final SrsCardHistory after = SrsCardHistory(<SrsReviewLog>[
        ...current.all,
        ...plan,
      ]);
      expect(after.state, backup.state);
      expect(srsSameEffectiveShape(after.effective, backup.effective), isTrue);
      // 不靠 ③′：没有任何一条是「照抄状态」日志，旧版本按原规则算出的记忆输入与备份时相同。
      expect(after.all.any(_isRestoreState), isFalse);
      expect(shape(memory(after)), shape(memory(backup)));
      expect(memory(after).complete, memory(backup).complete);
    });

    test('不是尾巴（备份时有效的导入日志后来被判等价）：兜底写照抄状态的 manual 日志', () {
      final SrsReviewLog imp = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
        origin: SrsLogOrigin.anki,
        ankiId: kT0,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 7),
      );
      final SrsReviewLog native = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0 + 500,
        rating: 3,
        result: const SrsScheduleResult(queue: SrsQueue.review, dueDay: 8),
      );
      final SrsReviewLog undoNative = _log(
        card: 'c',
        kind: SrsLogKind.undo,
        at: kT0 + 1000,
        revokes: native.id,
      );
      final SrsCardHistory current = SrsCardHistory(<SrsReviewLog>[
        imp,
        native,
        undoNative,
      ]);
      expect(current.equivalentImports, contains(imp.id));

      final List<SrsReviewLog> plan = srsPlanStateRestore(
        cardId: 'c',
        current: current,
        backupLogIds: <String>{imp.id},
        ctx: ctx(),
        backupId: 'bk',
      );
      expect(plan, hasLength(1));
      expect(plan.single.kind, SrsLogKind.manual);
      expect(_isRestoreState(plan.single), isTrue);
      expect(plan.single.result, imp.result);
    });

    test('状态已一致：不写任何日志', () {
      final SrsReviewLog r1 = _log(
        card: 'c',
        kind: SrsLogKind.review,
        at: kT0,
        rating: 3,
      );
      expect(
        srsPlanStateRestore(
          cardId: 'c',
          current: SrsCardHistory(<SrsReviewLog>[r1]),
          backupLogIds: <String>{r1.id},
          ctx: ctx(),
          backupId: 'bk',
        ),
        isEmpty,
      );
    });
  });
}
