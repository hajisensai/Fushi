import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';

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
}
