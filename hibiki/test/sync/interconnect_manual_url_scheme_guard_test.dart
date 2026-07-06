import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final File interconnectSource = File(
    'lib/src/sync/sync_settings_schema/interconnect.part.dart',
  );

  group('Hibiki interconnect manual URL scheme guard', () {
    test('manual URL hint matches the default plain HTTP LAN server', () {
      final String source = interconnectSource.readAsStringSync();

      expect(source, contains("hintText: 'http://192.168.1.100:38765'"));
      expect(
          source, isNot(contains("hintText: 'https://192.168.1.100:38765'")));
    });

    test('manual add/edit normalizes raw user text before storing it', () {
      final String source = interconnectSource.readAsStringSync();

      expect(source, contains('normalizeHibikiInterconnectManualUrl(result)'));
      expect(
        source,
        contains('copy.add(HibikiClientUrl(url: normalizedResult))'),
      );
    });
  });
}
