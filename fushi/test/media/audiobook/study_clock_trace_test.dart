import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// `StudyClock.trace`（统计诊断流水的时钟侧，用户 2026-09-12 导出日志排查读速异常）
/// 行为测试：起停表、开 / 封段、守卫拒窗（带原因）、字数入账 / 撤回、停表期间丢弃、
/// 落库失败，每一件都得留一行，前缀 `kind:key`；sink 为 null 时零开销、不抛。
void main() {
  late List<String> lines;
  late FushiDatabase db;
  late DateTime now;
  int uidSeq = 0;

  StudyClock make({Duration? idleTimeout, bool failWrite = false}) {
    return StudyClock(
      database: db,
      mediaKind: kActivityMediaBook,
      mediaKey: 'book-1',
      title: 'T',
      format: 'epub',
      idleTimeout: idleTimeout,
      sink: (StudySegmentsCompanion row) async {
        if (failWrite) throw StateError('injected');
      },
      deviceId: () async => 'dev-A',
      now: () => now,
      uidFactory: () => 'uid-${++uidSeq}-abcdefgh',
    );
  }

  setUp(() {
    lines = <String>[];
    StudyClock.trace = lines.add;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    now = DateTime(2026, 9, 12, 10, 0, 0);
    uidSeq = 0;
  });

  tearDown(() async {
    StudyClock.trace = null;
    await db.close();
  });

  test('起表 → 入账开段 → 撤回 → 停表封段，每步一行且带身份前缀', () async {
    final StudyClock clock = make(idleTimeout: const Duration(minutes: 10));
    clock.start();
    clock.addChars(120);
    now = now.add(const Duration(seconds: 30));
    clock.addChars(80);
    expect(clock.retractChars(50), 50);
    await clock.stop();

    expect(lines, isNotEmpty);
    expect(lines.every((String l) => l.startsWith('book:book-1 ')), isTrue);
    expect(lines.first, contains('start accrual=wallClock idle=600s'));
    expect(
      lines.any((String l) => l.contains('open seg uid-1-ab 2026-09-12@10')),
      isTrue,
    );
    expect(lines.any((String l) => l.contains('+120c → seg uid-1-ab')), isTrue);
    expect(
      lines.any((String l) => l.contains('session=200c')),
      isTrue,
      reason: '第二笔后会话累计 200',
    );
    expect(
      lines.any((String l) => l.contains('-50c taken=50 session=150c')),
      isTrue,
    );
    expect(lines.last, contains('stop session='));
    expect(lines.last, contains('/150c seal seg uid-1-ab'));
  });

  test('停表期间的字数 / 页数丢弃也留痕', () {
    final StudyClock clock = make();
    clock.addChars(300);
    clock.addPages(2);
    expect(lines, <String>[
      'book:book-1 drop +300c (not running)',
      'book:book-1 drop +2p (not running)',
    ]);
  });

  test('空闲门拒窗：reject window 带原因与空闲秒数，随后封段', () async {
    final StudyClock clock = make(idleTimeout: const Duration(minutes: 1));
    clock.start();
    clock.addChars(10);
    now = now.add(const Duration(minutes: 2));
    await clock.flushNow();
    final String reject = lines.firstWhere((String l) => l.contains('reject'));
    expect(reject, contains('reject window 120000ms (idle 120s)'));
    final int rejectAt = lines.indexOf(reject);
    expect(lines[rejectAt + 1], contains('seal seg'), reason: '拒窗后封段');
    await clock.stop();
  });

  test('落库失败留一行 write error', () async {
    final StudyClock clock = make(failWrite: true);
    clock.start();
    clock.addChars(10);
    now = now.add(const Duration(seconds: 5));
    await clock.stop();
    expect(
      lines.any((String l) => l.contains('write error seg uid-1-ab')),
      isTrue,
    );
  });

  test('sink 为 null 时静默', () async {
    StudyClock.trace = null;
    final StudyClock clock = make();
    clock.start();
    clock.addChars(10);
    await clock.stop();
    expect(lines, isEmpty);
  });
}
