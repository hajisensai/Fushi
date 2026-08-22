import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/tls/fushi_tofu_probe.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

import '../../helpers/source_guard.dart';

/// BUG-1741 收尾（PR#912 审查）：TOFU 探测的失败分型此前**零测试**，而它的
/// `timeout` 分支根本走不到——`SecureSocket.connect(timeout:)` 超时抛的是
/// `SocketException: Connection timed out`，不是 [TimeoutException]，于是被归成
/// `unreachable`，UI 把「对端没在时限内应答」说成「连接失败」，正是本 bug 要
/// 消灭的那类误导文案。
void main() {
  group('classifyFushiTofuFailure（分型纯函数）', () {
    test('TlsException → notTls（端口上有东西，只是不讲 TLS）', () {
      expect(
        classifyFushiTofuFailure(const TlsException('boom')),
        FushiTofuFailure.notTls,
      );
    });

    test('HandshakeException（implements TlsException）→ notTls', () {
      expect(
        classifyFushiTofuFailure(const HandshakeException('bad record')),
        FushiTofuFailure.notTls,
      );
    });

    test('TimeoutException → timeout（本分型只有外包 .timeout() 才可达）', () {
      expect(
        classifyFushiTofuFailure(
          TimeoutException('x', const Duration(milliseconds: 1)),
        ),
        FushiTofuFailure.timeout,
      );
    });

    test('SocketException → unreachable', () {
      expect(
        classifyFushiTofuFailure(const SocketException('refused')),
        FushiTofuFailure.unreachable,
      );
    });

    test('其它任意 Object → unreachable（兜底，不抛）', () {
      expect(
        classifyFushiTofuFailure(const FormatException('nonsense')),
        FushiTofuFailure.unreachable,
      );
      expect(classifyFushiTofuFailure('裸字符串'), FushiTofuFailure.unreachable);
    });
  });

  group('probeFingerprint（真 socket）', () {
    test('对端接受 TCP 但从不讲 TLS → timeout，而不是 unreachable', () async {
      // 这台「服务器」只 accept，一个字节都不回：TCP 连得上，TLS 握手永远不完成。
      // 旧实现把超时交给 SecureSocket.connect 的 timeout: 参数，那个参数只管 TCP
      // connect 阶段——握手阶段无人计时，本用例会一直挂到测试框架超时。
      final ServerSocket server = await ServerSocket.bind('127.0.0.1', 0);
      final List<Socket> accepted = <Socket>[];
      final StreamSubscription<Socket> sub =
          server.listen(accepted.add, onError: (Object _) {});
      try {
        final FushiTofuOutcome outcome = await FushiTofuProbe.probeFingerprint(
          '127.0.0.1',
          server.port,
          timeout: const Duration(milliseconds: 300),
        );
        expect(outcome.fingerprint, isNull);
        expect(outcome.speaksTls, isFalse);
        expect(
          outcome.failure,
          FushiTofuFailure.timeout,
          reason: '超时被归成 unreachable，UI 会把「没应答」说成「连接失败」',
        );
      } finally {
        await sub.cancel();
        for (final Socket s in accepted) {
          s.destroy();
        }
        await server.close();
      }
    });

    test('端口没人监听 → unreachable', () async {
      // 先 bind 拿一个确定空闲的端口，再立刻关掉。
      final ServerSocket probe = await ServerSocket.bind('127.0.0.1', 0);
      final int deadPort = probe.port;
      await probe.close();

      // 超时给得足够宽：实测本机（Windows + 安全软件的 WFP 过滤）连回环上的
      // 空端口要 ~2s 才回 WSAECONNREFUSED，不是教科书里的「立刻 RST」。给 2s
      // 会让超时反过来抢在拒绝之前，测出个假的 timeout——那是在测环境，不是
      // 在测分型。
      final FushiTofuOutcome outcome = await FushiTofuProbe.probeFingerprint(
        '127.0.0.1',
        deadPort,
        timeout: const Duration(seconds: 20),
      );
      expect(outcome.failure, FushiTofuFailure.unreachable);
      expect(outcome.speaksTls, isFalse);
    });

    test('明文服务（回非 TLS 字节）→ notTls，且失败只进诊断段不进错误计数', () async {
      final ServerSocket server = await ServerSocket.bind('127.0.0.1', 0);
      final List<Socket> accepted = <Socket>[];
      final StreamSubscription<Socket> sub = server.listen((Socket s) {
        accepted.add(s);
        // 首字节 0x48（H）不是任何合法 TLS record type，握手立刻失败。
        s.write('HTTP/1.1 400 Bad Request');
      }, onError: (Object _) {});
      try {
        await ErrorLogService.instance.clear();
        final int errorsBefore = ErrorLogService.instance.entries.length;
        final int diagBefore =
            ErrorLogService.instance.diagnosticEntries.length;

        final FushiTofuOutcome outcome = await FushiTofuProbe.probeFingerprint(
          '127.0.0.1',
          server.port,
          timeout: const Duration(seconds: 5),
        );
        expect(outcome.failure, FushiTofuFailure.notTls);
        expect(outcome.speaksTls, isFalse);

        // 明文 host 上的 https 候选**每次配对都会**抛一次 HandshakeException：
        // 这是多候选 failover 的预期路径，计进用户可见错误计数就是纯噪声。
        expect(
          ErrorLogService.instance.entries.length,
          errorsBefore,
          reason: '瞬时探测失败灌进了用户可见错误列表（应走 logDiagnostic）',
        );
        expect(
          ErrorLogService.instance.diagnosticEntries.length,
          greaterThan(diagBefore),
          reason: '探测失败连诊断留痕都没有，事后无从排查',
        );
        expect(
          ErrorLogService.instance.diagnosticEntries.last.source,
          startsWith('TofuProbe:'),
        );
      } finally {
        await sub.cancel();
        for (final Socket s in accepted) {
          s.destroy();
        }
        await server.close();
        await ErrorLogService.instance.clear();
      }
    });
  });

  group('源码不变式', () {
    test('TOFU 探测不得再把超时交给 SecureSocket.connect 的 timeout: 参数', () {
      final String src =
          File('lib/src/sync/tls/fushi_tofu_probe.dart').readAsStringSync();
      // 锚点字面量：.timeout( / timeout: timeout / unawaited( / destroy()
      expect(
        containsCodeLine(src, '.timeout('),
        isTrue,
        reason: '外包的 .timeout() 没了，TimeoutException 分型重新变成死代码',
      );
      expect(
        containsCodeLine(src, 'timeout: timeout'),
        isFalse,
        reason: 'connect 又收回了 timeout: —— 双重超时，超时会重新被归成 unreachable',
      );
      // 超时后底层 connect 仍可能 resolve 出 socket，必须有兜底 destroy。
      expect(
        containsCodeLine(src, 'unawaited('),
        isTrue,
        reason: '超时后的 socket 兜底回收没了（句柄泄漏）',
      );
      expect(containsCodeLine(src, 'destroy()'), isTrue);
    });

    test('两个探测层的瞬时失败走 logDiagnostic，不进用户可见错误日志', () {
      for (final String path in <String>[
        'lib/src/sync/tls/fushi_tofu_probe.dart',
        'lib/src/sync/pairing/fushi_ping_client.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        // 锚点字面量：ErrorLogService.instance.logDiagnostic(
        expect(
          containsCodeLine(src, 'ErrorLogService.instance.logDiagnostic('),
          isTrue,
          reason: '未把瞬时探测失败记为诊断：$path',
        );
        expect(
          containsCodeLine(src, 'ErrorLogService.instance.log('),
          isFalse,
          reason: '把 failover 的预期失败灌进用户可见错误计数 + 持久化日志：$path',
        );
      }
    });

    test('丢失败原因的薄封装不得复活（删掉错误入口，而不是加守卫查调用点）', () {
      final String ping = File(
        'lib/src/sync/pairing/fushi_ping_client.dart',
      ).readAsStringSync();
      final String probe = File(
        'lib/src/sync/pairing/discovered_pairing_probe.dart',
      ).readAsStringSync();
      final String tofu =
          File('lib/src/sync/tls/fushi_tofu_probe.dart').readAsStringSync();
      // 锚点标识符：fetchFushiPing / probeDiscoveredPairingEndpoint /
      // captureFingerprint（末者在 probe 里仍是**测试注入缝的参数名**，所以只对
      // tofu 文件断言它不再是个入口）。
      expect(containsIdentifier(ping, 'fetchFushiPing'), isFalse);
      expect(
        containsIdentifier(probe, 'probeDiscoveredPairingEndpoint'),
        isFalse,
        reason: 'Detailed 版是更长标识符，containsIdentifier 不会假阳性命中',
      );
      expect(containsIdentifier(tofu, 'captureFingerprint'), isFalse);
    });
  });
}
