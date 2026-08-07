import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

String _ruleBody(String css, RegExp selector) {
  final RegExpMatch? match = selector.firstMatch(css);
  expect(match, isNotNull, reason: 'missing CSS root rule: $selector');
  return match!.group(1)!;
}

void main() {
  test('shared popup document pins its inherited text alignment to the left',
      () {
    final String css = _read('assets/popup/popup.css');
    final String body = _ruleBody(
      css,
      RegExp(r'html\s*,\s*body\s*\{([^}]*)\}', multiLine: true),
    );

    expect(body, contains('direction: ltr;'));
    expect(body, contains('text-align: left;'),
        reason:
            'Shadow DOM does not block inherited text-align from host pages');
  });

  for (final String path in <String>[
    'assets/browser_extension/vendor/content.css',
    '../tools/browser-extension/vendor/content.css',
  ]) {
    test('$path resets host-page alignment at the shadow popup root', () {
      final String css = _read(path);
      final String body = _ruleBody(
        css,
        RegExp(r':where\(#entries-container\)\s*\{([^}]*)\}', multiLine: true),
      );

      expect(body, contains('text-align: left;'),
          reason: 'generated content.css must isolate the inherited alignment');
    });
  }

  test('extension still renders the popup inside a shadow root', () {
    final String source = _read('../tools/browser-extension/content.js');
    expect(source, contains("fushiHost.attachShadow({ mode: 'open' })"));
    expect(source, contains("c.id = 'entries-container'"));
  });
}
