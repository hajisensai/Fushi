import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/host_request_observer.dart';
import 'package:shelf/shelf.dart' as shelf;

/// BUG-5606：host 慢请求 / 请求频率进诊断日志。
void main() {
  shelf.Request get(String path) =>
      shelf.Request('GET', Uri.parse('http://127.0.0.1:1$path'));

  test('处理期间事件循环被同步占住：记一行 slow（路由 + 状态码 + loopLag），'
      '请求结束后不留计时器', () async {
    final List<String> lines = <String>[];
    final HostRequestObserver observer = HostRequestObserver(
      log: lines.add,
      slowThreshold: const Duration(minutes: 1),
      lagThreshold: const Duration(milliseconds: 60),
    );
    final shelf.Handler handler = observer.middleware()((
      shelf.Request _,
    ) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final Stopwatch busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 200) {}
      return shelf.Response.ok('x');
    });
    await handler(get('/api/library/collections'));
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('slow GET /api/library/collections '));
    expect(lines.single, contains('status=200'));
    final int lag = int.parse(
      RegExp(r'loopLag=(\d+)ms').firstMatch(lines.single)!.group(1)!,
    );
    expect(lag, greaterThanOrEqualTo(60));
    expect(observer.debugTimerActive, isFalse);
  });

  test('快请求不记 slow；到汇总周期记一行各路由次数', () async {
    final List<String> lines = <String>[];
    DateTime now = DateTime(2026, 11, 28);
    final HostRequestObserver observer = HostRequestObserver(
      log: lines.add,
      summaryInterval: const Duration(minutes: 10),
      clock: () => now,
    );
    final shelf.Handler handler = observer.middleware()(
      (shelf.Request _) => shelf.Response.ok('x'),
    );
    await handler(get('/api/library/collections'));
    await handler(get('/api/library/collections'));
    await handler(get('/api/library/books/某本书/cover'));
    expect(lines, isEmpty);
    now = now.add(const Duration(minutes: 11));
    await handler(get('/api/ping'));
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('requests in last 11min: '));
    expect(lines.single, contains('GET /api/library/collections x2'));
    expect(lines.single, contains('GET /api/library/books/* x1'));
    expect(lines.single, isNot(contains('某本书')), reason: '书名不进日志');
  });

  test('handler 抛异常：照样记账（status=500）并原样抛出', () async {
    final List<String> lines = <String>[];
    final HostRequestObserver observer = HostRequestObserver(
      log: lines.add,
      slowThreshold: Duration.zero,
    );
    final shelf.Handler handler = observer.middleware()(
      (shelf.Request _) => throw StateError('boom'),
    );
    await expectLater(handler(get('/api/x')), throwsStateError);
    expect(lines.single, contains('status=500'));
    expect(observer.debugTimerActive, isFalse);
  });

  test('长轮询挂着：不判慢、不让计时器常驻、不分摊同时段普通请求的 loopLag，'
      '只进频率汇总（标 hold）', () async {
    final List<String> lines = <String>[];
    DateTime now = DateTime(2026, 11, 28);
    final HostRequestObserver observer = HostRequestObserver(
      log: lines.add,
      slowThreshold: const Duration(milliseconds: 50),
      lagThreshold: const Duration(milliseconds: 60),
      clock: () => now,
    );
    final Completer<void> release = Completer<void>();
    final shelf.Handler handler = observer.middleware()((
      shelf.Request request,
    ) async {
      if (request.url.path == 'api/srs/changes') {
        await release.future;
        return shelf.Response.ok('{}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final Stopwatch busy = Stopwatch()..start();
      while (busy.elapsedMilliseconds < 200) {}
      return shelf.Response.ok('x');
    });

    final Future<shelf.Response> poll = Future<shelf.Response>.value(
      handler(get('/api/srs/changes?after=3')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(observer.debugTimerActive, isFalse, reason: '只挂着长轮询时不留计时器');

    // 长轮询挂着时来一条普通请求：计时器只为它跑，跑完即停。
    await handler(get('/api/library/collections'));
    expect(observer.debugTimerActive, isFalse);
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('slow GET /api/library/collections '));

    release.complete();
    await poll;
    expect(lines, hasLength(1), reason: '挂了 300+ ms 的长轮询不记 slow');
    expect(observer.debugTimerActive, isFalse);

    now = now.add(const Duration(minutes: 11));
    await handler(get('/api/srs/changes'));
    expect(lines.last, startsWith('requests in last 11min: '));
    expect(lines.last, contains('GET /api/srs/changes (hold) x2'));
  });

  test('isHostSuspendingRequest：srs 长轮询与带 wait 的助手会话读', () {
    expect(isHostSuspendingRequest(get('/api/srs/changes?after=1')), isTrue);
    expect(
      isHostSuspendingRequest(
        shelf.Request('POST', Uri.parse('http://127.0.0.1:1/api/srs/changes')),
      ),
      isFalse,
    );
    expect(
      isHostSuspendingRequest(
        get('/api/assistant/sessions/s1?after=2&wait=25'),
      ),
      isTrue,
    );
    expect(
      isHostSuspendingRequest(get('/api/assistant/sessions/s1?wait=0')),
      isFalse,
    );
    expect(isHostSuspendingRequest(get('/api/assistant/sessions/s1')), isFalse);
    expect(
      isHostSuspendingRequest(get('/api/assistant/sessions/s1/actions?wait=9')),
      isFalse,
    );
    expect(isHostSuspendingRequest(get('/api/srs/sync-status')), isFalse);
    expect(isHostSuspendingRequest(get('/api/library/collections')), isFalse);
  });

  test('hostRequestRouteKey：/api 取前三段，其余归 WebDAV', () {
    expect(hostRequestRouteKey(get('/api/ping')), '/api/ping');
    expect(
      hostRequestRouteKey(get('/api/library/books/a/b')),
      '/api/library/books/*',
    );
    expect(hostRequestRouteKey(get('/books/a.epub')), '/(dav)');
    expect(hostRequestRouteKey(get('/')), '/(dav)');
  });
}
