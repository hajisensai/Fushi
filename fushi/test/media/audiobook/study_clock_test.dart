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
        reason:
            '第二条 stop 看到的是已清空的状态，不重复写（旧 VideoWatchTracker '
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

    test('字数 / 页数记到当前段，与时长同一行；无段时以 0 时长开段', () async {
      final _Harness h = _Harness();
      h.clock.addChars(120);
      h.clock.addPages(2);
      await h.clock.flushNow();
      expect(h.sink.writes, hasLength(1));
      expect(h.sink.last.chars.value, 120);
      expect(h.sink.last.pages.value, 2);
      expect(h.sink.last.durationMs.value, 0);
      h.clock.start();
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
