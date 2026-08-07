import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_url.dart';
import 'package:fushi/src/sync/sync_backend.dart';

void main() {
  group('normalizeFushiInterconnectManualUrl', () {
    test('adds http scheme to a bare LAN host and strips trailing slash', () {
      expect(
        normalizeFushiInterconnectManualUrl(' 192.168.1.88:38765/ '),
        'http://192.168.1.88:38765',
      );
    });

    test('adds http scheme to a bare hostname with a port', () {
      expect(
        normalizeFushiInterconnectManualUrl('hibiki-pc.local:38765'),
        'http://hibiki-pc.local:38765',
      );
    });

    test('preserves an explicit https scheme for pinned TLS hosts', () {
      expect(
        normalizeFushiInterconnectManualUrl('https://host.example:38765/'),
        'https://host.example:38765',
      );
    });

    test('rejects unsupported schemes instead of rewriting them', () {
      expect(
        () => normalizeFushiInterconnectManualUrl('ftp://host:38765'),
        throwsA(isA<SyncBackendError>()),
      );
    });
  });
}
