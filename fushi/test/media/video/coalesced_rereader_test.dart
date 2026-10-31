import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/coalesced_rereader.dart';

/// BUG-3315 审查：比值订阅下一次变化只来一次事件。蓝光菜单采样在途时来的事件若直接
/// 复用在途读取（读到的是变化之前的值），这次变化就丢了。[CoalescedRereader] 保证
/// 在途请求换来一次补读，且请求者等到的是请求之后开始的那次读取。
void main() {
  group('CoalescedRereader', () {
    late List<Completer<void>> reads;
    late CoalescedRereader rereader;
    late bool wanted;

    Future<void> read() {
      final Completer<void> c = Completer<void>();
      reads.add(c);
      return c.future;
    }

    Future<void> request() => rereader.request(read, stillWanted: () => wanted);

    setUp(() {
      reads = <Completer<void>>[];
      rereader = CoalescedRereader();
      wanted = true;
    });

    test('空闲时请求立即开读，读完即完成', () async {
      bool done = false;
      unawaited(request().then((_) => done = true));
      expect(reads, hasLength(1));
      expect(rereader.isReading, isTrue);
      reads[0].complete();
      await pumpEventQueue();
      expect(done, isTrue);
      expect(reads, hasLength(1), reason: '没有在途请求就不补读');
      expect(rereader.isReading, isFalse);
    });

    test('在途时来的请求不丢：当前读完后补读一次，请求者等到补读完成', () async {
      unawaited(request());
      bool lateDone = false;
      unawaited(request().then((_) => lateDone = true));
      expect(reads, hasLength(1), reason: '不并发读');

      reads[0].complete();
      await pumpEventQueue();
      expect(reads, hasLength(2), reason: '在途期间的请求必须换来一次补读');
      expect(lateDone, isFalse, reason: '补读之前的那次读取可能是旧值，不能算数');

      reads[1].complete();
      await pumpEventQueue();
      expect(lateDone, isTrue);
      expect(reads, hasLength(2));
    });

    test('一次读取期间的多次请求只合并成一次补读', () async {
      unawaited(request());
      unawaited(request());
      unawaited(request());
      unawaited(request());
      reads[0].complete();
      await pumpEventQueue();
      expect(reads, hasLength(2));
      reads[1].complete();
      await pumpEventQueue();
      expect(reads, hasLength(2));
      expect(rereader.isReading, isFalse);
    });

    test('补读期间再来请求会再补读一次', () async {
      unawaited(request());
      unawaited(request());
      reads[0].complete();
      await pumpEventQueue();
      unawaited(request());
      reads[1].complete();
      await pumpEventQueue();
      expect(reads, hasLength(3));
      reads[2].complete();
      await pumpEventQueue();
      expect(rereader.isReading, isFalse);
    });

    test('不再需要时（换片 / 销毁）不补读', () async {
      bool done = false;
      unawaited(request());
      unawaited(request().then((_) => done = true));
      wanted = false;
      reads[0].complete();
      await pumpEventQueue();
      expect(reads, hasLength(1));
      expect(done, isTrue, reason: '等待者照常完成，由调用方自己按世代判过期');
    });

    test('reset 后的请求开新的一轮，不被旧轮吞掉', () async {
      unawaited(request());
      rereader.reset();
      expect(rereader.isReading, isFalse);
      bool done = false;
      unawaited(request().then((_) => done = true));
      expect(reads, hasLength(2), reason: '新一轮立即开读');
      reads[0].complete();
      await pumpEventQueue();
      expect(reads, hasLength(2), reason: '旧轮不会因为新请求而补读');
      reads[1].complete();
      await pumpEventQueue();
      expect(done, isTrue);
    });

    test('读取抛错传给本轮全部等待者，之后的请求开新一轮', () async {
      final Future<void> first = request();
      final Future<void> second = request();
      reads[0].completeError(StateError('boom'));
      await expectLater(first, throwsStateError);
      await expectLater(second, throwsStateError);
      expect(rereader.isReading, isFalse);
      unawaited(request());
      expect(reads, hasLength(2));
      reads[1].complete();
      await pumpEventQueue();
    });

    test('等待者恢复后立刻发起的请求开新一轮（本轮已摘除）', () async {
      final List<int> seen = <int>[];
      unawaited(
        request().then((_) {
          seen.add(reads.length);
          unawaited(request());
          seen.add(reads.length);
        }),
      );
      reads[0].complete();
      await pumpEventQueue();
      expect(seen, <int>[1, 2]);
      reads[1].complete();
      await pumpEventQueue();
    });
  });

  test('蓝光菜单采样走 CoalescedRereader，不再复用在途 Future（源码接线）', () {
    final String part = File(
      'lib/src/media/video/video_disc_menu.part.dart',
    ).readAsStringSync();
    final String controller = File(
      'lib/src/media/video/video_player_controller.dart',
    ).readAsStringSync();
    expect(part, contains('_discSampler.request('));
    expect(part, contains('_discSampler.reset()'));
    expect(
      '$part\n$controller',
      isNot(contains('_discSampleFuture')),
      reason: '「在途就复用在途 Future」会丢掉撞上在途读取的那次变化',
    );
    expect(
      controller,
      contains('final CoalescedRereader _discSampler = CoalescedRereader();'),
    );
  });
}
