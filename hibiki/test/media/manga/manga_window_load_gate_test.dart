import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/reader/manga_window_load_gate.dart';

void main() {
  group('MangaWindowLoadGate', () {
    // BUG-1170：迟到的旧窗口回调跨过若干 await 才收尾，此时新窗口已经开始加载。
    test('迟到的旧窗口回调不能解开新窗口的 ready 锁', () async {
      final MangaWindowLoadGate gate = MangaWindowLoadGate();
      final MangaWindowLoadTicket first = gate.begin();
      // 旧回调在入口拿到自己的凭据（此时它确实是当前加载）。
      expect(gate.ticketFor(first.generation), same(first));

      // await 期间旧窗口被放弃、新窗口启动。
      final MangaWindowLoadTicket second = gate.begin();
      expect(second.generation, first.generation + 1);

      // 旧回调回来了：既不再持有归属，也不得解开任何锁。
      expect(gate.owns(first), isFalse);
      expect(gate.complete(first, MangaWindowLoadOutcome.ready), isFalse);

      bool secondSettled = false;
      final Future<void> watcher =
          second.outcome.then((_) => secondSettled = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        secondSettled,
        isFalse,
        reason: '新窗口的 ready 锁必须仍然锁着，导航锁不得被旧回调解除',
      );

      // 新窗口自己的回调才算数。
      expect(gate.complete(second, MangaWindowLoadOutcome.ready), isTrue);
      expect(await second.outcome, MangaWindowLoadOutcome.ready);
      await watcher;
      expect(secondSettled, isTrue);
    });

    test('文档 generation 不匹配（含缺失）时取不到凭据', () {
      final MangaWindowLoadGate gate = MangaWindowLoadGate();
      final MangaWindowLoadTicket ticket = gate.begin();
      expect(gate.ticketFor(ticket.generation - 1), isNull);
      expect(gate.ticketFor(ticket.generation + 1), isNull);
      expect(gate.ticketFor(null), isNull);
      expect(gate.ticketFor(ticket.generation), same(ticket));
    });

    // BUG-1171：页面在加载途中被销毁时锁必须以明确状态收尾，否则等待方挂满
    // 超时后从 unawaited 调用点抛出未捕获异步异常。
    test('销毁时在飞的加载立刻以 abandoned 收尾', () async {
      final MangaWindowLoadGate gate = MangaWindowLoadGate();
      final MangaWindowLoadTicket ticket = gate.begin();
      expect(gate.hasPendingLoad, isTrue);

      gate.abandon();

      expect(gate.hasPendingLoad, isFalse);
      expect(await ticket.outcome, MangaWindowLoadOutcome.abandoned);
      // 放弃之后迟到的就绪回调不得再改写结论。
      expect(gate.complete(ticket, MangaWindowLoadOutcome.ready), isFalse);
      expect(gate.ticketFor(ticket.generation), isNull);
    });

    test('finish 只清自己那把锁，不影响后开的加载', () {
      final MangaWindowLoadGate gate = MangaWindowLoadGate();
      final MangaWindowLoadTicket first = gate.begin();
      final MangaWindowLoadTicket second = gate.begin();
      gate.finish(first);
      expect(gate.owns(second), isTrue, reason: '旧加载的 finally 收尾不得把新加载的锁一起清掉');
      gate.finish(second);
      expect(gate.hasPendingLoad, isFalse);
    });
  });
}
