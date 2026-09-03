import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

WebDavOps _ops(String baseUrl) =>
    WebDavOps(baseUrl: baseUrl, username: 'u', password: 'p');

void main() {
  group('WebDavOps.resolveHref cross-origin check includes the port', () {
    test('rejects an absolute href that drops the non-standard port', () {
      // Server on :8080 but PROPFIND returned a default-port (implicit :80)
      // absolute href — must NOT be accepted as same-origin (HBK-AUDIT-160).
      final WebDavOps ops = _ops('http://nas.local:8080/dav');
      expect(
        () => ops.resolveHref(
            'http://nas.local/dav/file', 'http://nas.local:8080/dav'),
        throwsA(isA<SyncBackendError>()),
      );
    });

    test('accepts an absolute href on the same host+scheme+port', () {
      final WebDavOps ops = _ops('http://nas.local:8080/dav');
      expect(
        ops.resolveHref(
            'http://nas.local:8080/dav/file', 'http://nas.local:8080/dav'),
        'http://nas.local:8080/dav/file',
      );
    });

    test('rejects a different host (existing behavior)', () {
      final WebDavOps ops = _ops('http://nas.local:8080/dav');
      expect(
        () => ops.resolveHref(
            'http://evil.example/dav/file', 'http://nas.local:8080/dav'),
        throwsA(isA<SyncBackendError>()),
      );
    });

    test('reconstructs a relative href preserving the non-standard port', () {
      final WebDavOps ops = _ops('http://nas.local:8080/dav');
      expect(
        ops.resolveHref('/dav/file', 'http://nas.local:8080/dav'),
        'http://nas.local:8080/dav/file',
      );
    });
  });

  group('BUG-1693 连接类失败通知（互联故障切换的失效信号）', () {
    test('拒连（SocketException）触发 onConnectivityError 并原样 rethrow', () async {
      // 绑定后立即关掉的端口：connect 必被拒，稳定复现 SocketException。
      final ServerSocket socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int deadPort = socket.port;
      await socket.close();

      bool notified = false;
      final WebDavOps ops = WebDavOps(
        baseUrl: 'http://127.0.0.1:$deadPort/dav',
        username: 'u',
        password: 'p',
        connectionTimeout: const Duration(seconds: 5),
        onConnectivityError: () => notified = true,
      );
      try {
        await expectLater(
          () => ops.collectionExists('http://127.0.0.1:$deadPort/dav/'),
          throwsA(isA<SocketException>()),
        );
        expect(notified, isTrue,
            reason: '连接类失败必须通知回调（互联据此复位已解析会话，'
                '下一次操作重探候选地址）');
      } finally {
        ops.close(force: true);
      }
    });
  });
}
