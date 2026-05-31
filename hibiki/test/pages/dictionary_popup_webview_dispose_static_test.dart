import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // Static guard: DictionaryPopupWebView must NOT manually dispose its
  // InAppWebViewController. The InAppWebView widget owns the controller and
  // disposes it during its own unmount; a manual _controller.dispose() in the
  // State is a double dispose. It is a harmless no-op on Android/iOS but a hard
  // FlutterError on the Windows fork ("WindowsInAppWebViewController was used
  // after being disposed"), thrown during widget-tree finalization when a
  // dictionary popup closes. This test fails if anyone re-adds the manual
  // dispose, since a behavioral test would need a real WebView2 native layer.
  test('dictionary popup does not double-dispose its webview controller', () {
    final File source = File(p.join(
      'lib',
      'src',
      'pages',
      'implementations',
      'dictionary_popup_webview.dart',
    ));
    final String code = source.readAsStringSync();

    expect(
      code.contains('_controller?.dispose()'),
      isFalse,
      reason: 'popup must not manually dispose the webview controller '
          '(the InAppWebView widget owns it) — see Windows double-dispose crash',
    );
    expect(
      code.contains('_controller!.dispose()'),
      isFalse,
      reason: 'popup must not manually dispose the webview controller '
          '(the InAppWebView widget owns it) — see Windows double-dispose crash',
    );
  });
}
