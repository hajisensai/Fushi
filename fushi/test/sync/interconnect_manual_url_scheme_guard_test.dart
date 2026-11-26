import 'dart:io';

import 'package:test/test.dart';

void main() {
  final File interconnectSource = File(
    'lib/src/sync/sync_settings_schema/interconnect.part.dart',
  );

  group('Fushi interconnect manual URL scheme guard', () {
    test('manual URL hint matches the default plain HTTP LAN server', () {
      final String source = interconnectSource.readAsStringSync();

      expect(source, contains("hintText: 'http://192.168.1.100:38765'"));
      expect(
        source,
        isNot(contains("hintText: 'https://192.168.1.100:38765'")),
      );
    });

    test('manual add/edit normalizes raw user text before storing it', () {
      final String source = interconnectSource.readAsStringSync();

      expect(source, contains('parseFushiInterconnectManualAddress(result)'));
      expect(
        source,
        contains('copy.add(FushiClientUrl(url: normalizedResult))'),
      );
    });

    // BUG-5482：裸地址补的 `http://` 只是占位。新增时必须先探明 scheme（https 先）
    // 再落库 + 配对，否则 TLS host 被明文 ping 挂到超时，UI 说「对端没应答」。
    test('schemeless add probes https/http before storing and pairing', () {
      final String source = interconnectSource.readAsStringSync();

      expect(
        source,
        contains('fushiInterconnectManualPairingCandidates(address)'),
      );
      expect(
        source,
        contains('await _attemptSchemelessManualPair(schemelessCandidates);'),
      );
      final int start = source.indexOf(
        'Future<void> _attemptSchemelessManualPair(',
      );
      expect(start, isNonNegative);
      final int end = source.indexOf('Future<void> _attemptManualPair(', start);
      expect(end, greaterThan(start));
      final String body = source.substring(start, end);
      final int probe = body.indexOf('probeFushiPairingCandidates(candidates)');
      final int store = body.indexOf('FushiClientUrl(url: saved)');
      final int pair = body.indexOf('await _runPairingV2(');
      expect(probe, isNonNegative, reason: '裸地址没有先探测 scheme');
      expect(store, greaterThan(probe), reason: '落库的必须是探明的地址');
      expect(pair, greaterThan(store));
      expect(body, contains('baseUrl: probe.baseUrl,'));
      expect(body, contains('if (_pairingManual) return;'));
      expect(body, contains('_setPairV2Busy(false);'));
    });
  });
}
