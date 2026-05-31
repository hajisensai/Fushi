import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Static guard: DictionaryPopupWebView must NOT manually dispose its
  // InAppWebViewController. The InAppWebView widget owns the controller and
  // disposes it during its own (child) unmount; a manual dispose in this State
  // is a double dispose. It is a harmless no-op on Android/iOS but a hard
  // FlutterError on the Windows fork ("WindowsInAppWebViewController was used
  // after being disposed"), thrown during widget-tree finalization when a
  // dictionary popup closes. A behavioral test would need a real WebView2
  // native layer, so this locks the contract at the source level instead.
  //
  // Comments are stripped first so the explanatory comment in the production
  // file (which names the forbidden call to document why it's gone) doesn't
  // trip the guard.
  test('dictionary popup does not double-dispose its webview controller', () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final String code = _stripLineComments(source);

    expect(
      code,
      isNot(contains('_controller?.dispose()')),
      reason: 'popup must not manually dispose the webview controller — the '
          'InAppWebView widget owns it (see Windows double-dispose crash)',
    );
    expect(
      code,
      isNot(contains('_controller!.dispose()')),
      reason: 'popup must not manually dispose the webview controller — the '
          'InAppWebView widget owns it (see Windows double-dispose crash)',
    );
    expect(
      code,
      isNot(contains('_controller.dispose()')),
      reason: 'popup must not manually dispose the webview controller — the '
          'InAppWebView widget owns it (see Windows double-dispose crash)',
    );
  });
}

/// Drops `//` line comments so source-text assertions match real code, not
/// the explanatory prose that documents the removed call.
String _stripLineComments(String source) {
  return source
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
