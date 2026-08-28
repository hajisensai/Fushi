import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const Map<String, String> cssMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension asset': 'assets/browser_extension/vendor/popup.css',
    'extension source': '../tools/browser-extension/vendor/popup.css',
  };
  const Map<String, String> jsMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.js',
    'extension asset': 'assets/browser_extension/vendor/popup.js',
    'extension source': '../tools/browser-extension/vendor/popup.js',
  };

  for (final MapEntry<String, String> mirror in cssMirrors.entries) {
    test('${mirror.key}: static mine plus matches adjacent SVG height', () {
      final String css = File(mirror.value).readAsStringSync();
      expect(
        RegExp(
          r'\.mine-button:not\(\.duplicate\)\s*\{\s*font-size:\s*30px;\s*\}',
        ).hasMatch(css),
        isTrue,
        reason: 'BUG-1895: 24px text + was still visibly shorter than 18px SVG',
      );
    });
  }

  for (final MapEntry<String, String> mirror in jsMirrors.entries) {
    test('${mirror.key}: mine button reuses clickable action layout', () {
      final String js = File(mirror.value).readAsStringSync();
      expect(
        js,
        contains("className: 'inline-action-button mine-button'"),
        reason:
            'BUG-1895: shared class provides inline-flex centering and pointer cursor',
      );
    });
  }
}
