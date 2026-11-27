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
