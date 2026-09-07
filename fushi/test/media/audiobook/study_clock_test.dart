import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

// v92 统计域重构：StudyClock 是学习时长 / 字数 / 页数的唯一计时器兼累计器，写法
// 只有「按 uid 绝对值 upsert」。本测试锁定它的结构性不变量：
//  * 重复 flush / 并发 stop 不可能翻倍（同 uid 同值）；
//  * 断档 / 活跃态 / 空闲三道守卫任一拒绝即整窗丢弃 + 封段；
//  * 段不跨小时边界；
//  * 写失败保持 dirty、下次用绝对值重写（重试不累加）。
// 时钟、uid、落库全部注入，不依赖真实定时器。

class _Sink {
  final List<StudySegmentsCompanion> writes = <StudySegmentsCompanion>[];
  int failuresLeft = 0;

  Future<void> call(StudySegmentsCompanion row) async {
    if (failuresLeft > 0) {
      failuresLeft--;
      throw StateError('injected write failure');
    }
    writes.add(row);
  }

  StudySegmentsCompanion get last => writes.last;
  Iterable<String> get uids => writes.map((w) => w.uid.value);
}

class _Harness {
  _Harness({
    Duration? idleTimeout,
    bool Function()? isActive,
    DateTime? start,
    StudyAccrual accrual = StudyAccrual.wallClock,
  }) : now = start ?? DateTime(2026, 8, 29, 12, 0, 0) {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    clock = StudyClock(
      database: db,
      mediaKind: kActivityMediaBook,
      mediaKey: 'book-1',
      title: 'T',
      format: 'epub',
      accrual: accrual,
      idleTimeout: idleTimeout,
      isActive: isActive,
      sink: sink.call,
      deviceId: () async => 'dev-A',
      now: () => now,
      uidFactory: () => 'u${++_uidSeq}',
    );
    addTearDown(() => clock.stop());
  }

  late final FushiDatabase db;
  late final StudyClock clock;
  final _Sink sink = _Sink();
  DateTime now;
  int _uidSeq = 0;

  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('显式记账模式（BUG-2108：视频面时长由 addActiveMs 推入，tick 不按墙钟计）', () {
    test('tick 不再整窗计时：只有 addActiveMs 推入的毫秒进段', () async {
      final _Harness h = _Harness(accrual: StudyAccrual.explicit);
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(h.sink.writes, isEmpty, reason: '没推入过时长，60s 墙钟不该变成段');

      h.clock.addActiveMs(900);
      h.clock.addActiveMs(1100);
      h.advance(const Duration(seconds: 60));
      await h.clock.stop();
      expect(h.sink.writes, hasLength(1));
      expect(h.sink.last.durationMs.value, 2000);
    });

    test('一整个 tick 窗口没有记账 = 封段；再记账开新 uid', () async {
      final _Harness h = _Harness(accrual: StudyAccrual.explicit);
      h.clock.start();
      h.clock.addActiveMs(3000);
      // 第一个 tick：本窗有记账，段保持打开。
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      // 用 _accrue 走一遍 tick 裁决：flushNow 与 tick 共用 _accrue，等价。
      final String? first = h.clock.debugOpenUid;
      expect(first, isNotNull);
      // 第二个窗口一次都没记账（用户暂停 / 回放）→ 封段。
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(h.clock.debugOpenUid, isNull, reason: '无记账窗口封段');
      h.clock.addActiveMs(1000);
      expect(h.clock.debugOpenUid, isNot(first), reason: '再记账开新段');
      await h.clock.stop();
      expect(h.sink.uids.toSet(), hasLength(2));
    });

    test('跨小时的记账落到新段（段不跨小时边界）', () async {
      final _Harness h = _Harness(
        accrual: StudyAccrual.explicit,
        start: DateTime(2026, 8, 29, 12, 59, 59),
      );
      h.clock.start();
      // 各推 1.5s：落库门槛是「≥ 1s 或有内容账」，两段都得过门槛才能断言小时分布。
      h.clock.addActiveMs(1500);
      h.advance(const Duration(seconds: 2)); // 13:00:01
      h.clock.addActiveMs(1500);
      await h.clock.stop();
      expect(h.sink.writes.map((w) => w.hour.value).toSet(), <int>{12, 13});
    });

    test('显式模式下传 isActive / idleTimeout 是构造期断言错误', () {
      expect(
        () => _Harness(accrual: StudyAccrual.explicit, isActive: () => true),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('StudyClock 绝对值 upsert（重复计数在结构上不可能）', () {
    test('两次 flushNow 同 uid 同值：第二次不产生新行、不翻倍', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1), reason: '同值不脏 → 第二次 flush 不写');
      expect(h.sink.last.durationMs.value, 30000);
      expect(h.sink.last.uid.value, 'u1');

      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(2));
      expect(h.sink.last.uid.value, 'u1', reason: '同一小时内仍是同一段');
      expect(h.sink.last.durationMs.value, 60000, reason: '写的是段的绝对累计值，不是增量');
      expect(h.sink.last.deviceId.value, 'dev-A');
      expect(h.sink.last.mediaKey.value, 'book-1');
      expect(h.sink.last.format.value, 'epub');
    });

    test('两条并发 stop（dispose 与进程退出）只落一份终值', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.advance(const Duration(seconds: 45));
      final Future<void> a = h.clock.stop();
      final Future<void> b = h.clock.stop();
      await Future.wait(<Future<void>>[a, b]);
      expect(
        h.sink.writes,
        hasLength(1),
        reason: '第二条 stop 看到的是已清空的状态，不重复写（旧 VideoWatchTracker '
            '在 await 之后才清零累计器，两条 stop 各写一条活动行）',
      );
      expect(h.sink.last.durationMs.value, 45000);
      expect(h.clock.isRunning, isFalse);
      expect(h.clock.debugOpenUid, isNull);
    });

    test('写失败保持 dirty，下次 flush 用绝对值重写（重试不累加）', () async {
      final _Harness h = _Harness();
      h.sink.failuresLeft = 1;
      h.clock.start();
      h.advance(const Duration(seconds: 20));
      await h.clock.flushNow();
      expect(h.sink.writes, isEmpty, reason: '第一次写被注入失败');
      h.advance(const Duration(seconds: 20));
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1));
      expect(
        h.sink.last.durationMs.value,
        40000,
        reason: '绝对值 = 两个窗口之和，而不是「失败那份 + 重试那份」再加一遍',
      );
    });
  });

  group('三道守卫', () {
    test('断档（> kMaxReadingGap）整窗丢弃并封段', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      expect(h.clock.debugOpenUid, 'u1');
      h.advance(const Duration(hours: 3)); // 睡眠 / 挂起后补发
      await h.clock.flushNow();
      expect(h.sink.last.durationMs.value, 30000, reason: '3 小时一毫秒都没进');
      expect(h.clock.debugOpenUid, isNull, reason: '拒绝即封段');
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      expect(h.clock.debugOpenUid, 'u2', reason: '下一个被接受的窗口开新段');
      expect(h.sink.last.durationMs.value, 30000);
    });

    test('isActive=false 的窗口不入账（视频暂停态）', () async {
      bool playing = true;
      final _Harness h = _Harness(isActive: () => playing);
      h.clock.start();
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      playing = false;
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      expect(h.sink.last.durationMs.value, 30000);
      playing = true;
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      expect(h.sink.uids.toSet(), <String>{'u1', 'u2'});
      expect(h.sink.last.durationMs.value, 30000);
    });

    test('阅读空闲门：超时无 touch 的窗口不入账，touch 后恢复', () async {
      final _Harness h = _Harness(idleTimeout: const Duration(minutes: 10));
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(h.sink.last.durationMs.value, 60000);
      // 11 分钟没有任何输入（挂机）：期间的每个窗口都被拒。
      for (int i = 0; i < 11; i++) {
        h.advance(const Duration(minutes: 1));
        await h.clock.flushNow();
      }
      final int beforeTouch = h.sink.writes
          .map((w) => w.durationMs.value)
          .fold<int>(0, (int a, int b) => a > b ? a : b);
      expect(
        beforeTouch,
        lessThanOrEqualTo(10 * 60000 + 60000),
        reason: '超过空闲门之后的分钟不入账',
      );
      h.clock.touch();
      h.advance(const Duration(seconds: 30));
      await h.clock.flushNow();
      expect(h.sink.last.durationMs.value, 30000, reason: '重新有输入 → 新段');
    });

    test('BUG-2211：挂机超时 → stop → start 后首个 tick 入账（start 重锚空闲基准）', () async {
      final _Harness h = _Harness(idleTimeout: const Duration(minutes: 10));
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(h.sink.last.durationMs.value, 60000);
      // 挂机 11 分钟后切走（stop）。
      h.advance(const Duration(minutes: 11));
      await h.clock.stop();
      final int writesBefore = h.sink.writes.length;
      // 一小时后回前台：start 本身是用户输入，空闲基准必须重锚到此刻。
      h.advance(const Duration(hours: 1));
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(
        h.sink.writes.length,
        writesBefore + 1,
        reason: '回前台后的首个 tick 必须入账（旧 `_lastTouch ??= now` 会按陈旧基准判空闲）',
      );
      expect(h.sink.last.durationMs.value, 60000);
      h.advance(const Duration(seconds: 1));
      expect(
        h.clock.sessionTotals().active,
        isTrue,
        reason: '回前台后处于计时态（空闲基准 = start 时刻）',
      );
    });

    test('停表期间不产生任何增量（后台时长永不入账，BUG-892 不回归）', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.advance(const Duration(seconds: 30));
      await h.clock.stop();
      h.advance(const Duration(hours: 1));
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1));
      expect(h.sink.last.durationMs.value, 30000);
    });
  });

  group('sessionTotals：阅读器底部状态行的只读会话累计', () {
    test('未 start / 已 stop：零值 + 未计时；stop 后读数冻结不再增长', () async {
      final _Harness h = _Harness();
      expect(
        h.clock.sessionTotals(),
        (durationMs: 0, chars: 0, active: false),
      );
      h.clock.start();
      h.advance(const Duration(seconds: 30));
      await h.clock.stop();
      final StudySessionTotals stopped = h.clock.sessionTotals();
      expect(stopped.durationMs, 30000);
      expect(stopped.active, isFalse);
      h.advance(const Duration(hours: 1));
      expect(
        h.clock.sessionTotals().durationMs,
        30000,
        reason: '停表期间（后台）读数不动，与落库口径同律',
      );
    });

    test('未结算的部分窗口实时计入（秒表连续跳动，不是 60s 一跳）', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.advance(const Duration(seconds: 7));
      final StudySessionTotals live = h.clock.sessionTotals();
      expect(live.durationMs, 7000);
      expect(live.active, isTrue);
      expect(h.sink.writes, isEmpty, reason: '只读：不结算、不写库');
      expect(h.clock.debugOpenUid, isNull, reason: '只读：不开段');
    });

    test('跨段累计不清零：封段（小时边界）后会话读数继续累加', () async {
      final _Harness h = _Harness(start: DateTime(2026, 8, 29, 12, 59, 30));
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(h.sink.uids.toSet(), <String>{'u1', 'u2'}, reason: '跨小时切两段');
      h.advance(const Duration(seconds: 15));
      expect(h.clock.sessionTotals().durationMs, 75000);
    });

    test('字数随 addChars 累计；chars/h 由 UI 按 durationMs 派生', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addChars(120);
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      h.clock.addChars(30);
      final StudySessionTotals t = h.clock.sessionTotals();
      expect(t.chars, 150);
      expect(t.durationMs, 60000);
    });

    test('空闲 / 断档：当前窗口被拒时读数回落且 active=false（与入账同判据）', () async {
      final _Harness h = _Harness(idleTimeout: const Duration(minutes: 10));
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      // 挂机 11 分钟：本窗口此刻会被空闲门拒绝 → 不计入、暂停态。
      h.advance(const Duration(minutes: 11));
      final StudySessionTotals idle = h.clock.sessionTotals();
      expect(idle.durationMs, 60000);
      expect(idle.active, isFalse);
      // 有输入后下一窗口恢复计时。
      h.clock.touch();
      await h.clock.flushNow();
      h.advance(const Duration(seconds: 5));
      final StudySessionTotals back = h.clock.sessionTotals();
      expect(back.active, isTrue);
      expect(back.durationMs, 65000);
    });

    test('显式记账模式：时长只随 addActiveMs，active 随本窗口是否记过账', () async {
      final _Harness h = _Harness(accrual: StudyAccrual.explicit);
      h.clock.start();
      h.advance(const Duration(seconds: 30));
      expect(h.clock.sessionTotals(), (durationMs: 0, chars: 0, active: false));
      h.clock.addActiveMs(900);
      final StudySessionTotals t = h.clock.sessionTotals();
      expect(t.durationMs, 900);
      expect(t.active, isTrue);
    });
  });

  group('段边界与量纲', () {
    test('跨小时边界切两段，各归各的 (dateKey, hour)', () async {
      final _Harness h = _Harness(start: DateTime(2026, 8, 29, 12, 59, 30));
      h.clock.start();
      h.advance(const Duration(seconds: 60));
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(2));
      final StudySegmentsCompanion first = h.sink.writes[0];
      final StudySegmentsCompanion second = h.sink.writes[1];
      expect(first.hour.value, 12);
      expect(first.durationMs.value, 30000);
      expect(second.hour.value, 13);
      expect(second.durationMs.value, 30000);
      expect(first.uid.value, isNot(second.uid.value));
      expect(
        second.startAt.value,
        DateTime(2026, 8, 29, 13).millisecondsSinceEpoch,
        reason: '第二段从整点开始',
      );
    });

    test('跨午夜切两天', () async {
      final _Harness h = _Harness(start: DateTime(2026, 8, 29, 23, 59, 40));
      h.clock.start();
      h.advance(const Duration(seconds: 40));
      await h.clock.flushNow();
      expect(h.sink.writes.map((w) => w.dateKey.value), <String>[
        '2026-08-29',
        '2026-08-30',
      ]);
    });

    test('字数 / 页数记到当前段，与时长同一行；起表后无段时以 0 时长开段', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addChars(120);
      h.clock.addPages(2);
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1));
      expect(h.sink.last.chars.value, 120);
      expect(h.sink.last.pages.value, 2);
      expect(h.sink.last.durationMs.value, 0);
      h.advance(const Duration(seconds: 10));
      h.clock.addChars(30);
      await h.clock.flushNow();
      expect(
        h.sink.last.uid.value,
        h.sink.writes.first.uid.value,
        reason: '同一小时内时长并进同一段',
      );
      expect(h.sink.last.chars.value, 150);
      expect(h.sink.last.durationMs.value, 10000);
    });

    test('BUG-2210：停表期间 addChars / addPages 不入账、不开段', () async {
      final _Harness h = _Harness();
      // 从未 start：翻页产生的字数没有「在学习」的时钟可归属，直接丢弃。
      h.clock.addChars(50);
      h.clock.addPages(1);
      expect(h.clock.debugOpenUid, isNull, reason: '未起表不得以 0 时长开段');
      await h.clock.flushNow();
      expect(h.sink.writes, isEmpty);

      h.clock.start();
      h.advance(const Duration(seconds: 30));
      await h.clock.stop();
      expect(h.sink.writes, hasLength(1));
      expect(h.sink.last.durationMs.value, 30000);
      // 手动暂停 / 切屏后翻页：字数页数一并不计（停表 = 不在学习）。
      h.advance(const Duration(seconds: 5));
      h.clock.addChars(400);
      h.clock.addPages(3);
      expect(h.clock.debugOpenUid, isNull, reason: '停表期间不得开段');
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1), reason: '没有新段落库');
      expect(h.sink.last.chars.value, 0);
      expect(h.sink.last.pages.value, 0);
      expect(
        h.clock.sessionTotals().chars,
        0,
        reason: '会话累计同样不计，UI 字/时不被 0 时长字数推高',
      );
    });

    test('BUG-2217：跨小时瞬间 addChars 先结算待定窗口，不产出 0 时长字数段', () async {
      final _Harness h = _Harness(start: DateTime(2026, 8, 29, 12, 59, 50));
      h.clock.start();
      h.advance(const Duration(seconds: 5));
      await h.clock.flushNow();
      expect(h.clock.debugOpenUid, isNotNull, reason: '12 点段已打开');
      final String hour12 = h.clock.debugOpenUid!;
      // 13:00:10 翻页：待定窗口 12:59:55..13:00:10 先按小时拆桶结算，字数落 13 点段。
      h.advance(const Duration(seconds: 15));
      h.clock.addChars(100);
      expect(h.clock.debugOpenUid, isNot(hour12), reason: '字数落新小时段');
      expect(h.clock.debugOpenTotals, (
        durationMs: 10000,
        chars: 100,
        pages: 0,
      ));
      await h.clock.stop();
      expect(
        h.sink.writes.where((w) => w.durationMs.value == 0),
        isEmpty,
        reason: '不得出现 0 时长的纯字数段',
      );
      final Map<int, StudySegmentsCompanion> byHour =
          <int, StudySegmentsCompanion>{
            for (final StudySegmentsCompanion w in h.sink.writes)
              w.hour.value: w,
          };
      expect(byHour[12]!.durationMs.value, 10000);
      expect(byHour[12]!.chars.value, 0);
      expect(byHour[13]!.durationMs.value, 10000);
      expect(byHour[13]!.chars.value, 100);
      expect(h.sink.uids.toSet(), hasLength(2), reason: '恰两段：旧小时段不被重开第二次');
    });

    test('不足 1 秒且无字数 / 页数的段不落库：stop 丢弃、flushNow 留到下次', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.advance(const Duration(milliseconds: 300));
      await h.clock.flushNow();
      expect(h.sink.writes, isEmpty, reason: '300ms 生命周期抖动不值一行');
      h.advance(const Duration(milliseconds: 900));
      await h.clock.flushNow();
      expect(
        h.sink.last.durationMs.value,
        1200,
        reason: 'flushNow 不丢：两个窗口累计过门槛后一起落',
      );
      await h.clock.stop();

      final _Harness h2 = _Harness();
      h2.clock.start();
      h2.advance(const Duration(milliseconds: 5));
      await h2.clock.stop();
      expect(h2.sink.writes, isEmpty, reason: '开书秒关：dispose 路径零 DB 写（旧页面同一判据）');

      final _Harness h3 = _Harness();
      h3.clock.start();
      h3.advance(const Duration(milliseconds: 5));
      h3.clock.addPages(1);
      await h3.clock.stop();
      expect(h3.sink.last.pages.value, 1, reason: '有页数就落，不看时长');
    });

    test('非正数字数 / 页数忽略', () async {
      final _Harness h = _Harness();
      h.clock.addChars(0);
      h.clock.addPages(-1);
      await h.clock.flushNow();
      expect(h.sink.writes, isEmpty);
    });
  });

  group('撤回（回翻）：retractChars / retractPages 从最新的段往前扣，会话级夹 0', () {
    /// 第 1 小时段记 [charsFirst] 字 / [pagesFirst] 页，跨整点后第 2 小时段记
    /// [charsSecond] 字 / [pagesSecond] 页。返回两段 uid（第 1 段已封并落库）。
    Future<(String, String)> twoHourSegments(
      _Harness h, {
      int charsFirst = 0,
      int charsSecond = 0,
      int pagesFirst = 0,
      int pagesSecond = 0,
    }) async {
      h.clock.start();
      if (charsFirst > 0) h.clock.addChars(charsFirst);
      if (pagesFirst > 0) h.clock.addPages(pagesFirst);
      final String first = h.clock.debugOpenUid!;
      h.advance(const Duration(seconds: 60)); // 13:00:00，窗口整段落 12 点
      await h.clock.flushNow();
      expect(h.clock.debugOpenUid, first, reason: '恰到整点仍是 12 点段');
      // 13:00:30 记内容账：BUG-2217 先结算待定窗口 → 封 12 点段、开 13 点段。
      h.advance(const Duration(seconds: 30));
      if (charsSecond > 0) h.clock.addChars(charsSecond);
      if (pagesSecond > 0) h.clock.addPages(pagesSecond);
      final String second = h.clock.debugOpenUid!;
      expect(second, isNot(first));
      await h.clock.flushNow();
      return (first, second);
    }

    /// [uid] 在 sink 收到的最后一份绝对值。
    StudySegmentsCompanion lastWriteOf(_Harness h, String uid) =>
        h.sink.writes.lastWhere((w) => w.uid.value == uid);

    test('打开段内撤回：只改内存，下次 flush 写绝对值；会话字数跟着降', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addChars(300);
      expect(h.clock.retractChars(100), 100);
      expect(h.clock.debugOpenTotals!.chars, 200);
      expect(h.clock.sessionTotals().chars, 200);
      expect(h.sink.writes, isEmpty, reason: '打开段的撤回不立刻写库');
      h.advance(const Duration(seconds: 10));
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1));
      expect(h.sink.last.chars.value, 200);
      expect(h.sink.last.durationMs.value, 10000);
    });

    test('跨段撤回：先扣当前段、再扣本会话之前封掉的段，已封段重新写库', () async {
      final _Harness h = _Harness(start: DateTime(2026, 8, 29, 12, 59, 0));
      final (String first, String second) = await twoHourSegments(
        h,
        charsFirst: 200,
        charsSecond: 50,
      );
      expect(lastWriteOf(h, first).chars.value, 200);
      final int writesBefore = h.sink.writes.length;

      expect(h.clock.retractChars(120), 120);
      expect(h.clock.debugOpenTotals!.chars, 0, reason: '13 点段 50 先扣光');
      expect(h.clock.sessionTotals().chars, 130);
      await h.clock.flushNow();
      expect(
        lastWriteOf(h, first).chars.value,
        130,
        reason: '已封的 12 点段被扣后必须重新排队落库（绝对值 upsert）',
      );
      expect(
        lastWriteOf(h, first).durationMs.value,
        60000,
        reason: '重写只改字数，时长原样',
      );
      expect(lastWriteOf(h, second).chars.value, 0);
      expect(h.sink.writes.length, writesBefore + 2, reason: '两段各重写一次');
      expect(h.sink.uids.toSet(), <String>{first, second}, reason: '不开新段');
    });

    test('会话级夹 0：撤回额超过本会话已记字数时只扣到 0，之后再记正常', () async {
      final _Harness h = _Harness(start: DateTime(2026, 8, 29, 12, 59, 0));
      final (String first, String second) = await twoHourSegments(
        h,
        charsFirst: 200,
        charsSecond: 50,
      );
      expect(h.clock.retractChars(999), 250, reason: '总共只记了 250');
      expect(h.clock.sessionTotals().chars, 0);
      expect(h.clock.debugOpenTotals!.chars, 0);
      await h.clock.flushNow();
      expect(lastWriteOf(h, first).chars.value, 0);
      expect(lastWriteOf(h, second).chars.value, 0);
      expect(h.clock.retractChars(1), 0, reason: '已空，再撤回无可扣');

      h.clock.addChars(10);
      expect(h.clock.debugOpenUid, second, reason: '仍是同一打开段');
      expect(h.clock.sessionTotals().chars, 10);
      await h.clock.flushNow();
      expect(lastWriteOf(h, second).chars.value, 10);
    });

    test('已落库的段被撤回到 0 字 0 时长仍重写为 0（_worthWriting 门槛不适用于已在库的行）', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addChars(300);
      await h.clock.flushNow();
      expect(h.sink.last.chars.value, 300);
      expect(h.sink.last.durationMs.value, 0);
      expect(h.clock.retractChars(300), 300);
      await h.clock.stop();
      expect(h.sink.writes, hasLength(2), reason: '停表封段必须把 0 写穿，不能按抖动段丢弃');
      expect(
        h.sink.last.uid.value,
        h.sink.writes.first.uid.value,
        reason: '同 uid 重写，不删行',
      );
      expect(h.sink.last.chars.value, 0);
      expect(h.sink.last.durationMs.value, 0);
    });

    test('停表期间 retractChars / retractPages 返回 0 且不改任何段（BUG-2210 对称）', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addChars(100);
      h.clock.addPages(2);
      h.advance(const Duration(seconds: 5));
      await h.clock.stop();
      expect(h.sink.writes, hasLength(1));
      expect(h.clock.retractChars(50), 0);
      expect(h.clock.retractPages(1), 0);
      expect(h.clock.sessionTotals().chars, 100);
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1), reason: '没有任何段被改、没有新写');
      expect(h.sink.last.chars.value, 100);
      expect(h.sink.last.pages.value, 2);
    });

    test('非正数撤回额忽略', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addChars(10);
      expect(h.clock.retractChars(0), 0);
      expect(h.clock.retractPages(-3), 0);
      expect(h.clock.sessionTotals().chars, 10);
    });

    test('retractPages：打开段内与跨段同型，页数没有会话累计器只改段', () async {
      final _Harness h = _Harness();
      h.clock.start();
      h.clock.addPages(5);
      expect(h.clock.retractPages(2), 2);
      expect(h.clock.debugOpenTotals!.pages, 3);
      await h.clock.flushNow();
      expect(h.sink.last.pages.value, 3);
      await h.clock.stop();

      final _Harness h2 = _Harness(start: DateTime(2026, 8, 29, 12, 59, 0));
      final (String first, String second) = await twoHourSegments(
        h2,
        pagesFirst: 3,
        pagesSecond: 1,
      );
      expect(h2.clock.retractPages(3), 3);
      expect(h2.clock.debugOpenTotals!.pages, 0);
      await h2.clock.flushNow();
      expect(lastWriteOf(h2, first).pages.value, 1, reason: '已封段被扣 2 页并重写');
      expect(lastWriteOf(h2, second).pages.value, 0);
      expect(h2.clock.retractPages(5), 1, reason: '只剩 1 页可扣：会话级夹 0');
    });

    test('撤回不是输入：不续空闲门（对照 touch）', () async {
      final _Harness h = _Harness(idleTimeout: const Duration(minutes: 10));
      h.clock.start();
      h.clock.addChars(100);
      // 每分钟一个窗口推到 9:30：离空闲门到期还剩 30s。
      for (int i = 0; i < 9; i++) {
        h.advance(const Duration(minutes: 1));
        await h.clock.flushNow();
      }
      h.advance(const Duration(seconds: 30));
      expect(h.clock.sessionTotals().active, isTrue);
      expect(h.clock.retractChars(30), 30);
      h.advance(const Duration(minutes: 1)); // 10:30 > 10 分钟
      expect(
        h.clock.sessionTotals().active,
        isFalse,
        reason: '撤回不 touch，空闲基准仍是 addChars 那一刻，此刻已过门',
      );
      expect(h.clock.debugOpenUid, isNotNull, reason: '撤回不封段、不开段');
      h.clock.touch();
      expect(h.clock.sessionTotals().active, isTrue, reason: '对照：真输入才续命');
    });
  });

  group('真库 round-trip', () {
    test('默认 sink 写进 study_segments，重复 upsert 仍一行', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      DateTime now = DateTime(2026, 8, 29, 9);
      final StudyClock clock = StudyClock(
        database: db,
        mediaKind: kActivityMediaVideo,
        mediaKey: 'vid-1',
        title: 'V',
        now: () => now,
      );
      clock.start();
      now = now.add(const Duration(seconds: 30));
      await clock.flushNow();
      now = now.add(const Duration(seconds: 30));
      await clock.stop();
      final List<StudySegmentRow> rows = await db.getStudySegments();
      expect(rows, hasLength(1));
      expect(rows.single.durationMs, 60000);
      expect(rows.single.deviceId, await db.getOrCreateStudyDeviceId());
      expect(rows.single.updatedAt, now.millisecondsSinceEpoch);
      // Companion 的 Value 语义：未 present 的列不覆盖——这里全列 present。
      expect(rows.single.chars, 0);
      expect(const Value<int>(0).present, isTrue);
    });
  });
}
