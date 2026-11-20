// BUG-4972 / video-34：互联实时转码分段的小 LRU（[TranscodeSegmentCache]）。
//
// 修前 host 对同一条流同一段的每次请求都起一个新 ffmpeg（4K HEVC 源一段实测
// 1.4～3.3 s 墙钟、占满多核）。这里钉住缓存本身的契约：命中不再计算、同键并发
// 合流、失败不入缓存、按字节 LRU 淘汰、流作废即清（含作废时还在途的段）。
import 'dart:async';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:test/test.dart';

Uint8List _bytes(int length, [int fill = 0x47]) =>
    Uint8List(length)..fillRange(0, length, fill);

void main() {
  group('TranscodeSegmentCache', () {
    test('同流同段第二次请求命中，不再计算', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      int computed = 0;
      Future<Uint8List> compute() async {
        computed++;
        return _bytes(10);
      }

      final Uint8List a = await cache.obtain(
        stream: 't1',
        index: 3,
        input: '/v.mkv',
        compute: compute,
      );
      final Uint8List b = await cache.obtain(
        stream: 't1',
        index: 3,
        input: '/v.mkv',
        compute: compute,
      );
      expect(computed, 1);
      expect(identical(a, b), isTrue);
      expect(cache.length, 1);
      expect(cache.bytes, 10);
    });

    test('键含流 / 段号 / 输入路径：任一不同都重新计算', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      int computed = 0;
      Future<Uint8List> compute() async {
        computed++;
        return _bytes(4);
      }

      await cache.obtain(stream: 't1', index: 0, input: '/a', compute: compute);
      await cache.obtain(stream: 't2', index: 0, input: '/a', compute: compute);
      await cache.obtain(stream: 't1', index: 1, input: '/a', compute: compute);
      await cache.obtain(stream: 't1', index: 0, input: '/b', compute: compute);
      expect(computed, 4);
    });

    test('同键并发合流：只计算一次，等待者拿到同一份结果', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      final Completer<Uint8List> gate = Completer<Uint8List>();
      int computed = 0;
      Future<Uint8List> compute() {
        computed++;
        return gate.future;
      }

      final Future<Uint8List> first = cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: compute,
      );
      final Future<Uint8List> second = cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: compute,
      );
      expect(cache.inflightCount, 1);
      gate.complete(_bytes(8));
      expect(await first, await second);
      expect(computed, 1);
      expect(cache.inflightCount, 0);
      expect(cache.length, 1);
    });

    test('失败原样传给每个等待者且不入缓存，下次请求重新计算', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      final Completer<Uint8List> gate = Completer<Uint8List>();
      final Future<Uint8List> a = cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: () => gate.future,
      );
      final Future<Uint8List> b = cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: () => throw StateError('不该被调用：应合流到在途那次'),
      );
      gate.completeError(TranscodeFailure(1, 'boom'));
      await expectLater(a, throwsA(isA<TranscodeFailure>()));
      await expectLater(b, throwsA(isA<TranscodeFailure>()));
      expect(cache.length, 0);
      expect(cache.inflightCount, 0);

      int computed = 0;
      await cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: () async {
          computed++;
          return _bytes(3);
        },
      );
      expect(computed, 1);
    });

    test('compute 同步抛出：收进 Future，不留在途登记', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      await expectLater(
        cache.obtain(
          stream: 't',
          index: 0,
          input: '/v',
          compute: () => throw const TranscodeCancelled(),
        ),
        throwsA(isA<TranscodeCancelled>()),
      );
      expect(cache.inflightCount, 0);
    });

    test('按字节 LRU 淘汰最久未用的段；命中刷新使用顺序', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache(maxBytes: 30);
      int computed = 0;
      Future<Uint8List> obtain(int index) => cache.obtain(
        stream: 't',
        index: index,
        input: '/v',
        compute: () async {
          computed++;
          return _bytes(10);
        },
      );

      await obtain(0);
      await obtain(1);
      await obtain(2);
      expect(cache.bytes, 30);
      await obtain(0); // 命中：0 变成最近使用
      expect(computed, 3);
      await obtain(3); // 超限：淘汰最久未用的 1
      expect(cache.bytes, 30);
      expect(cache.length, 3);
      await obtain(0);
      await obtain(2);
      expect(computed, 4, reason: '0、2 仍在缓存里');
      await obtain(1);
      expect(computed, 5, reason: '1 已被淘汰，要重新计算');
    });

    test('单段比上限还大的不入缓存', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache(maxBytes: 5);
      await cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: () async => _bytes(6),
      );
      expect(cache.length, 0);
      expect(cache.bytes, 0);
    });

    test('evictStream 只清该流的段，别的流不动', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      for (final String s in <String>['a', 'b']) {
        for (int i = 0; i < 3; i++) {
          await cache.obtain(
            stream: s,
            index: i,
            input: '/v',
            compute: () async => _bytes(7),
          );
        }
      }
      cache.evictStream('a');
      expect(cache.length, 3);
      expect(cache.bytes, 21);
    });

    test('作废时还在途的段：等待者照常拿到结果，但转完不入缓存', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      final Completer<Uint8List> gate = Completer<Uint8List>();
      final Future<Uint8List> pending = cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: () => gate.future,
      );
      cache.evictStream('t');
      expect(cache.inflightCount, 0);
      gate.complete(_bytes(9));
      expect((await pending).length, 9);
      expect(cache.length, 0, reason: '流已作废，转完的段不能再留在内存里');
    });

    test('clear 清空全部', () async {
      final TranscodeSegmentCache cache = TranscodeSegmentCache();
      await cache.obtain(
        stream: 't',
        index: 0,
        input: '/v',
        compute: () async => _bytes(2),
      );
      cache.clear();
      expect(cache.length, 0);
      expect(cache.bytes, 0);
    });
  });
}
