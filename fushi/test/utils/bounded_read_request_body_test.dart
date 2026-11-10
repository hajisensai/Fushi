import 'dart:async';
import 'dart:typed_data';

import 'package:fushi_engine/utils/net/bounded_read.dart';
import 'package:test/test.dart';

/// BUG（interconnect-unbounded-request-body）：host 读请求体的统一有界入口。
void main() {
  test('声明的 Content-Length 超限：不等正文直接抛，订阅停在暂停', () async {
    // 正文永远不来（慢速攻击）：实现若去等数据，这里会挂到超时。
    bool cancelled = false;
    final StreamController<List<int>> body = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    await expectLater(
      readBoundedRequestBody(
        body.stream,
        declaredLength: 100000000,
        maxBytes: 1024,
      ),
      throwsA(isA<BodyTooLargeException>()),
    );
    // dart:io 边界：从未订阅 → 写响应头前整份 drain；取消 → 连接被直接关掉、
    // 413 写不出去。只能订阅后暂停。
    expect(body.hasListener, isTrue);
    expect(body.isPaused, isTrue);
    expect(cancelled, isFalse);
  });

  test('未声明长度（chunked）：按块累计，超限立即抛并停止读后续块', () async {
    int pulled = 0;
    Stream<List<int>> chunks() async* {
      for (int i = 0; i < 1000; i++) {
        pulled++;
        yield Uint8List(400);
      }
    }

    await expectLater(
      readBoundedRequestBody(chunks(), declaredLength: null, maxBytes: 1000),
      throwsA(isA<BodyTooLargeException>()),
    );
    // 第 3 块（累计 1200 > 1000）就该停下，绝不把 1000 块全读完。
    expect(pulled, lessThan(10));
  });

  test('声明长度与实际字节都恰好等于上限：放行并返回全部字节', () async {
    final Uint8List bytes = await readBoundedRequestBody(
      Stream<List<int>>.fromIterable(<List<int>>[
        List<int>.filled(600, 1),
        List<int>.filled(424, 2),
      ]),
      declaredLength: 1024,
      maxBytes: 1024,
    );
    expect(bytes.length, 1024);
    expect(bytes.first, 1);
    expect(bytes.last, 2);
  });

  test('声明长度在限内但实际超发：仍按实际字节封顶', () async {
    await expectLater(
      readBoundedRequestBody(
        Stream<List<int>>.value(Uint8List(2048)),
        declaredLength: 10,
        maxBytes: 1024,
      ),
      throwsA(isA<BodyTooLargeException>()),
    );
  });
}
