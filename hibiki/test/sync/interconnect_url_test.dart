import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_url.dart';
import 'package:fushi/src/sync/sync_backend.dart';

void main() {
  group('normalizeHibikiInterconnectManualUrl', () {
    test('adds http scheme to a bare LAN host and strips trailing slash', () {
      expect(
        normalizeHibikiInterconnectManualUrl(' 192.168.1.88:38765/ '),
        'http://192.168.1.88:38765',
      );
    });

    test('adds http scheme to a bare hostname with a port', () {
      expect(
        normalizeHibikiInterconnectManualUrl('hibiki-pc.local:38765'),
        'http://hibiki-pc.local:38765',
      );
    });

    test('preserves an explicit https scheme for pinned TLS hosts', () {
      expect(
        normalizeHibikiInterconnectManualUrl('https://host.example:38765/'),
        'https://host.example:38765',
      );
    });

    test('rejects unsupported schemes instead of rewriting them', () {
      expect(
        () => normalizeHibikiInterconnectManualUrl('ftp://host:38765'),
        throwsA(isA<SyncBackendError>()),
      );
    });
  });
}
