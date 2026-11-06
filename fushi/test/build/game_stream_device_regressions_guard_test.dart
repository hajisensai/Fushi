import 'dart:io';

import 'package:test/test.dart';

/// Pins two fixes found on a real dual-screen device (AYN Thor) that widget
/// tests cannot reach: both only fail on Android with real WebViews.
void main() {
  test('companion process uses its own WebView data directory', () {
    // Android forbids two processes sharing one WebView data directory; the
    // main process already owns the default one, so the `:companion`
    // dictionary stayed an empty box until it set its own suffix.
    final String source = File(
      'android/app/src/main/java/app/fushi/reader/'
      'GameStreamCompanionActivity.java',
    ).readAsStringSync();
    expect(source, contains('WebView.setDataDirectorySuffix("companion")'));
    final int configure = source.indexOf('configureWebViewDataDir();');
    final int superCreate = source.indexOf('super.onCreate(');
    expect(configure, isNonNegative);
    expect(
      configure,
      lessThan(superCreate),
      reason: 'The suffix must be set before the engine creates any WebView',
    );
  });

  test('stream page route renders at net UI scale 1', () {
    // The lookup rail's DictionaryPopupWebView asserts net scale 1; without
    // the neutralizer, single-screen lookups threw under app UI scaling.
    final String source = File(
      'lib/src/pages/implementations/game_stream_session_opener.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'FushiAppUiScaleNeutralizer\(\s*child:\s*GameStreamPage\(',
      ).hasMatch(source),
      isTrue,
    );
  });
}
