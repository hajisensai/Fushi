import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('source image timeout is extended beyond the old fixed 45 seconds', () {
    expect(
      kMihonSourceImageHeaderTimeout,
      greaterThan(const Duration(seconds: 45)),
    );
    expect(
      kMihonSourceImageIdleTimeout,
      greaterThan(const Duration(seconds: 45)),
    );
  });

  test('each received image chunk refreshes the idle timeout', () async {
    // 虚拟时间驱动 Stream.timeout 的计时器：块间隔 400ms < 500ms 超时，但三段
    // 累计 1200ms 远超一个超时窗口——只有「每块重置计时」才能读完。真实
    // sleep 在 CI 并发负载下会被拉长到超过超时，所以这里不用真实时间。
    const Duration idleTimeout = Duration(milliseconds: 500);
    const Duration gap = Duration(milliseconds: 400);
    final FakeAsync fake = FakeAsync();
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    Uint8List? result;
    Object? error;
    fake.run((FakeAsync async) {
      readMihonSourceImageBytes(
        controller.stream,
        idleTimeout: idleTimeout,
      ).then(
        (Uint8List bytes) => result = bytes,
        onError: (Object e) {
          error = e;
        },
      );

      controller.add(<int>[1]);
      async.elapse(gap);
      controller.add(<int>[2]);
      async.elapse(gap);
      controller.add(<int>[3]);
      async.elapse(gap);
      expect(error, isNull);
      controller.close();
    });
    await _drainUntil(fake, () => result != null || error != null);

    expect(fake.elapsed, gap * 3);
    expect(error, isNull);
    expect(result, Uint8List.fromList(<int>[1, 2, 3]));
  });

  test(
    'a gap longer than the idle timeout fails even after earlier chunks',
    () async {
      const Duration idleTimeout = Duration(milliseconds: 500);
      final FakeAsync fake = FakeAsync();
      final StreamController<List<int>> controller =
          StreamController<List<int>>();
      addTearDown(controller.close);
      Object? error;
      fake.run((FakeAsync async) {
        readMihonSourceImageBytes(
          controller.stream,
          idleTimeout: idleTimeout,
        ).then(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        controller.add(<int>[1]);
        async.elapse(const Duration(milliseconds: 400));
        controller.add(<int>[2]);
        async.elapse(idleTimeout - const Duration(milliseconds: 1));
      });
      await _drainUntil(fake, () => error != null);
      expect(error, isNull, reason: '上一块之后还没满一个超时窗口');

      fake.run((FakeAsync async) {
        async.elapse(const Duration(milliseconds: 1));
      });
      await _drainUntil(fake, () => error != null);
      expect(error, isA<TimeoutException>());
    },
  );

  test(
    'source image still fails after a real interval without progress',
    () async {
      final StreamController<List<int>> controller =
          StreamController<List<int>>();
      addTearDown(controller.close);
      final Future<Uint8List> reading = readMihonSourceImageBytes(
        controller.stream,
        idleTimeout: const Duration(milliseconds: 80),
      );
      controller.add(<int>[1]);

      await expectLater(reading, throwsA(isA<TimeoutException>()));
    },
  );

  // BUG-2450 第 4 点：漫画页图原来是从请求开始固定 45 秒的整请求超时。
  group('page image (fetchMihonPageImageBytes)', () {
    const Duration headerTimeout = Duration(milliseconds: 500);
    const Duration idleTimeout = Duration(milliseconds: 500);
    final Uri url = Uri.parse('http://127.0.0.1:1/image/1');

    test('慢速但持续出数据的页图不被整请求计时砍掉；请求头原样带上', () async {
      const Duration gap = Duration(milliseconds: 400);
      final FakeAsync fake = FakeAsync();
      final StreamController<List<int>> body = StreamController<List<int>>();
      http.BaseRequest? seen;
      Uint8List? result;
      Object? error;
      fake.run((FakeAsync async) {
        final MockClient client = MockClient.streaming((
          http.BaseRequest request,
          http.ByteStream _,
        ) async {
          seen = request;
          return http.StreamedResponse(body.stream, 200);
        });
        fetchMihonPageImageBytes(
          client,
          url,
          headers: const <String, String>{'Authorization': 'Bearer t'},
          headerTimeout: headerTimeout,
          idleTimeout: idleTimeout,
        ).then(
          (Uint8List bytes) => result = bytes,
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        for (int i = 0; i < 4; i++) {
          body.add(<int>[i]);
          async.elapse(gap);
        }
        expect(error, isNull, reason: '累计 1600ms 超过三个超时窗口，但每块都在续期');
        body.close();
      });
      await _drainUntil(fake, () => result != null || error != null);

      expect(error, isNull);
      expect(result, Uint8List.fromList(<int>[0, 1, 2, 3]));
      expect(seen!.method, 'GET');
      expect(seen!.url, url);
      expect(seen!.headers['Authorization'], 'Bearer t');
    });

    test('响应头迟迟不来按首响应超时失败', () async {
      final FakeAsync fake = FakeAsync();
      final Completer<http.StreamedResponse> never =
          Completer<http.StreamedResponse>();
      Object? error;
      fake.run((FakeAsync async) {
        final MockClient client = MockClient.streaming(
          (http.BaseRequest _, http.ByteStream _) => never.future,
        );
        fetchMihonPageImageBytes(
          client,
          url,
          headers: const <String, String>{},
          headerTimeout: headerTimeout,
          idleTimeout: idleTimeout,
        ).then(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        async.elapse(headerTimeout - const Duration(milliseconds: 1));
        expect(error, isNull);
        async.elapse(const Duration(milliseconds: 1));
      });
      await _drainUntil(fake, () => error != null);
      expect(error, isA<TimeoutException>());
    });

    test('出过数据后连续一个窗口没动静仍然超时', () async {
      final FakeAsync fake = FakeAsync();
      final StreamController<List<int>> body = StreamController<List<int>>();
      addTearDown(body.close);
      Object? error;
      fake.run((FakeAsync async) {
        final MockClient client = MockClient.streaming(
          (http.BaseRequest _, http.ByteStream _) async =>
              http.StreamedResponse(body.stream, 200),
        );
        fetchMihonPageImageBytes(
          client,
          url,
          headers: const <String, String>{},
          headerTimeout: headerTimeout,
          idleTimeout: idleTimeout,
        ).then(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        async.flushMicrotasks();
        body.add(<int>[1]);
        async.elapse(idleTimeout + const Duration(milliseconds: 1));
      });
      await _drainUntil(fake, () => error != null);
      expect(error, isA<TimeoutException>());
    });

    test('非 200 与空响应体保留原错误码', () async {
      Future<Uint8List> fetch(int status, List<int> bytes) =>
          fetchMihonPageImageBytes(
            MockClient(
              (http.Request _) async => http.Response.bytes(bytes, status),
            ),
            url,
            headers: const <String, String>{},
          );
      await expectLater(
        fetch(503, <int>[1]),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'IMAGE_HTTP_503',
          ),
        ),
      );
      await expectLater(
        fetch(200, <int>[]),
        throwsA(
          isA<MihonRuntimeException>().having(
            (MihonRuntimeException e) => e.code,
            'code',
            'EMPTY_IMAGE',
          ),
        ),
      );
    });

    test('页图不套封面的 32 MiB 上限', () async {
      final Uint8List bytes = await readMihonSourceImageBytes(
        Stream<List<int>>.value(<int>[1, 2, 3]),
        maxBytes: null,
      );
      expect(bytes, hasLength(3));
      await expectLater(
        readMihonSourceImageBytes(
          Stream<List<int>>.value(<int>[1, 2, 3]),
          maxBytes: 2,
        ),
        throwsA(isA<MihonRuntimeException>()),
      );
    });
  });
}

/// 把 fake-async 下已经能进行的异步收尾全部跑完（不推进虚拟时间）。
///
/// [Stream.timeout] 取消上游订阅时拿到的是根 zone 的已完成 Future，`await for`
/// 退出时的 done / cancel 续体因此排进**真实**微任务队列，[FakeAsync.flushMicrotasks]
/// 冲不到；续体回到 fake zone 后又会排进 fake 队列。所以交替让出真实事件循环、
/// 冲 fake 队列，直到 [done] 成立；轮数上限只防死循环，与墙钟无关。
Future<void> _drainUntil(FakeAsync fake, bool Function() done) async {
  for (int round = 0; round < 10 && !done(); round++) {
    await pumpEventQueue();
    fake.flushMicrotasks();
  }
}
