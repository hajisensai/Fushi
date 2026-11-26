import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_url.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi_engine/sync/pairing/discovered_pairing_probe.dart';

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
  // BUG-5519：裸地址的 `http://` 只是占位，不是对端的事实——配对前要先探 https。
  group('parseFushiInterconnectManualAddress', () {
    test('bare address is normalized to http but marked scheme-less', () {
      final FushiInterconnectManualAddress a =
          parseFushiInterconnectManualAddress(' 192.0.2.10:48765/ ');
      expect(a.url, 'http://192.0.2.10:48765');
      expect(a.schemeExplicit, isFalse);
    });

    test('explicit http and https are kept and marked explicit', () {
      expect(parseFushiInterconnectManualAddress('http://192.0.2.10:48765'), (
        url: 'http://192.0.2.10:48765',
        schemeExplicit: true,
      ));
      expect(parseFushiInterconnectManualAddress('HTTPS://192.0.2.10:48765/'), (
        url: 'HTTPS://192.0.2.10:48765',
        schemeExplicit: true,
      ));
    });
  });

  group('fushiInterconnectManualPairingCandidates', () {
    test('bare address probes https first, then http, on the same port', () {
      final List<FushiPairingCandidate>? c =
          fushiInterconnectManualPairingCandidates(
            parseFushiInterconnectManualAddress('192.0.2.10:48765'),
          );
      expect(c, isNotNull);
      expect(c!.map((FushiPairingCandidate e) => e.baseUrl), <String>[
        'https://192.0.2.10:48765',
        'http://192.0.2.10:48765',
      ]);
      expect(c.first.host, '192.0.2.10');
      expect(c.first.port, 48765);
    });

    test('an explicit scheme is authoritative: no scheme probing', () {
      expect(
        fushiInterconnectManualPairingCandidates(
          parseFushiInterconnectManualAddress('http://192.0.2.10:48765'),
        ),
        isNull,
      );
      expect(
        fushiInterconnectManualPairingCandidates(
          parseFushiInterconnectManualAddress('https://192.0.2.10:48765'),
        ),
        isNull,
      );
    });
  });
}
