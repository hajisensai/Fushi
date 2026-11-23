// BUG-5262（反馈 w8sFMyflft）：互联对端离线时，选路每轮对同一台 host 的全部候选地址
// 并发 ping，旧实现在 probeFushiPing 里逐地址、逐轮写一条诊断，随反馈上传的日志尾巴
// 几乎全是同样的 Ping 超时 / No route to host。改后 probeFushiPing 不自己记日志，
// 选路探测只在某条地址的状态切换（首次失败 / 分型变了 / 恢复）时记一条。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart' show FushiClientUrl;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/pairing/fushi_ping_client.dart';

class _CapturingSink implements EngineLogSink {
  final List<(String, String)> diagnostics = <(String, String)>[];
  final List<(String, String)> errors = <(String, String)>[];

  @override
  void log(String source, Object error, [StackTrace? stack]) =>
      errors.add((source, '$error'));

  @override
  void logDiagnostic(String source, Object info) =>
      diagnostics.add((source, '$info'));

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) =>
      errors.add((source, '$error'));
}

void main() {
  late EngineLogSink previousSink;
  late _CapturingSink sink;
  late HttpServer server;
  late String baseUrl;

  setUp(() async {
    previousSink = engineLog;
    sink = _CapturingSink();
    engineLog = sink;
    resetInterconnectAddressProbeStates();
    // 一个「连得上、但不是 Fushi」的端点：失败分型确定（notFushi HTTP 500），不受本机
    // 网络栈对拒连 / 超时的差异影响。
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      req.response.statusCode = 500;
      unawaited(req.response.close());
    });
    baseUrl = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    engineLog = previousSink;
    resetInterconnectAddressProbeStates();
    await server.close(force: true);
  });

  test('probeFushiPing 不自己记日志，失败原因随结果交回', () async {
    final FushiPingOutcome outcome = await probeFushiPing(baseUrl);
    expect(outcome.failure, FushiPingFailure.notFushi);
    expect(outcome.failureDetail, 'notFushi: HTTP 500');
    expect(sink.diagnostics, isEmpty);
    expect(sink.errors, isEmpty);

    final FushiPingOutcome refused = await probeFushiPing(
      'http://127.0.0.1:1',
      timeout: const Duration(seconds: 5),
    );
    expect(refused.isOk, isFalse);
    expect(refused.cause, isNotNull, reason: '传输层异常原文要留给调用方写诊断');
    expect(sink.diagnostics, isEmpty);
  });

  test('选路探测同一地址连续失败：只在第一次记一条诊断', () async {
    final FushiClientUrl candidate = FushiClientUrl(url: baseUrl);
    for (int i = 0; i < 4; i++) {
      expect(
        await defaultInterconnectAddressProbe(candidate, 'host-a'),
        isFalse,
      );
    }
    expect(sink.diagnostics, <(String, String)>[
      ('Ping:$baseUrl', 'notFushi: HTTP 500'),
    ]);
    expect(sink.errors, isEmpty);
  });

  test('状态切换才记：失败 → 分型变了 → 恢复 → 再失败', () {
    const String url = 'https://192.168.1.30:38765';
    noteInterconnectAddressProbe(url, null);
    expect(sink.diagnostics, isEmpty, reason: '首次就探通不是状态切换');

    noteInterconnectAddressProbe(url, 'timeout', detail: 'timeout: t1');
    noteInterconnectAddressProbe(url, 'timeout', detail: 'timeout: t2');
    noteInterconnectAddressProbe(url, 'unreachable', detail: 'unreachable: x');
    noteInterconnectAddressProbe(url, 'unreachable', detail: 'unreachable: y');
    noteInterconnectAddressProbe(url, null);
    noteInterconnectAddressProbe(url, null);
    noteInterconnectAddressProbe(url, 'timeout');
    expect(sink.diagnostics, <(String, String)>[
      ('Ping:$url', 'timeout: t1'),
      ('Ping:$url', 'unreachable: x'),
      ('Ping:$url', 'reachable again (was unreachable)'),
      ('Ping:$url', 'timeout'),
    ]);
  });
}
