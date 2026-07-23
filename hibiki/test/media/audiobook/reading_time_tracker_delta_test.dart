import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

// BUG-1042：「每书/每日阅读时长」（reading_statistics.reading_time_ms）与「小时桶」
// （reading_hourly_logs）此前是**两个独立时钟**——前者拿 `now - _sessionStartTime` 的
// 墙钟差，后者走 ReadingTimeTracker 的 gap 守卫 tick。而 `_sessionStartTime` 被生命周期
// resumed / 章节恢复完成无条件重锚，重锚前那段前台阅读时长直接蒸发（`_flushReadingStats`
// 以 `_sessionCharsRead <= 0` 早退时压根不消费它）。生产库对账：同一天前者 84 分钟、
// 后者 345 分钟。
//
// 修复把两条账目并到**同一个** tick 上：tracker 每确认一段连续窗口，既写小时桶，也把
// 同一份增量经 onDelta 回吐给会话累计器。本测试锁定这个不变量。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

Future<int> _hourlyTotalMs(HibikiDatabase db) async {
  final List<ReadingHourlyLogRow> rows = await db.getAllReadingHourlyLogs();
  return rows.fold<int>(
      0, (int a, ReadingHourlyLogRow r) => a + r.readingTimeMs);
}

/// 建 tracker 并登记「先停表排空写入、再关库」的 teardown。
///
/// `_write` 是 fire-and-forget 的 DB 写；若测试结束时先关库，未落盘的写会撞
/// `This database has already been closed`。addTearDown 是 LIFO：本函数在
/// [_openDb] 之后登记，因此排空先于 close 执行。
ReadingTimeTracker _makeTracker(
  HibikiDatabase db, {
  ReadingTimeDelta? onDelta,
}) {
  final ReadingTimeTracker tracker = ReadingTimeTracker(db, onDelta: onDelta);
  addTearDown(() async {
    tracker.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  return tracker;
}

void main() {
  group('ReadingTimeTracker.onDelta（每书时长与小时桶同源）', () {
    test('sampleNow 结算的增量同时进小时桶和 onDelta，两者相等', () async {
      final HibikiDatabase db = await _openDb();
      int sessionMs = 0;
      final ReadingTimeTracker tracker =
          _makeTracker(db, onDelta: (int ms) => sessionMs += ms);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      tracker.sampleNow();
      // _write 是 fire-and-forget 的 DB 写，给它落盘的机会。
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(sessionMs, greaterThan(0),
          reason: 'onDelta 没回吐 → 每书时长恒 0（正是 BUG-1042 症状）');
      expect(sessionMs, await _hourlyTotalMs(db),
          reason: '两条账目必须来自同一个 tick，不得各算各的');
    });

    test('sampleNow 不停表：可以连续多次结算，增量累计不重复也不丢', () async {
      final HibikiDatabase db = await _openDb();
      int sessionMs = 0;
      final ReadingTimeTracker tracker =
          _makeTracker(db, onDelta: (int ms) => sessionMs += ms);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      tracker.sampleNow();
      final int first = sessionMs;
      expect(tracker.isRunning, isTrue, reason: 'sampleNow 不得停表');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      tracker.sampleNow();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(sessionMs, greaterThan(first));
      expect(sessionMs, await _hourlyTotalMs(db));
    });

    test('stop 的收尾结算也回吐 onDelta（失焦那一刻的部分窗口不丢）', () async {
      final HibikiDatabase db = await _openDb();
      int sessionMs = 0;
      final ReadingTimeTracker tracker =
          _makeTracker(db, onDelta: (int ms) => sessionMs += ms);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      tracker.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(tracker.isRunning, isFalse);
      expect(sessionMs, greaterThan(0), reason: 'BUG-1042：失焦瞬间的部分窗口必须结算进会话累计器');
      expect(sessionMs, await _hourlyTotalMs(db));
    });

    test('停表期间不产生任何增量（后台时长永不入账，BUG-892 不回归）', () async {
      final HibikiDatabase db = await _openDb();
      int sessionMs = 0;
      final ReadingTimeTracker tracker =
          _makeTracker(db, onDelta: (int ms) => sessionMs += ms);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      tracker.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final int afterStop = sessionMs;

      // 「后台」期间：表停着，无论过多久都不该再累加。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      tracker.sampleNow();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(sessionMs, afterStop, reason: '停表后 sampleNow 必须是 no-op');
      expect(sessionMs, await _hourlyTotalMs(db));
    });

    test('不传 onDelta 时行为不变（小时桶照常写，向后兼容）', () async {
      final HibikiDatabase db = await _openDb();
      final ReadingTimeTracker tracker = _makeTracker(db);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      tracker.stop();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(await _hourlyTotalMs(db), greaterThan(0));
    });
  });
}
