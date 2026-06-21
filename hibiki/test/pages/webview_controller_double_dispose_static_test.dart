import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'reader_hibiki_page_source_corpus.dart';

/// Codebase-wide invariant guard (all platforms).
///
/// An `InAppWebView` *widget* owns its `InAppWebViewController` and disposes it
/// during the widget's own unmount. Application `State` code must therefore
/// NEVER call `_controller.dispose()` itself — that is a double dispose. It is a
/// harmless no-op on Android/iOS/macOS, but a hard FlutterError on the Windows
/// fork, whose `disposeChannel()` asserts the channel isn't already disposed
/// ("WindowsInAppWebViewController was used after being disposed"), thrown
/// during widget-tree finalization when the view closes.
///
/// In every one of these files the webview controller is the field named
/// `_controller`. Other disposes in the same files (e.g. the reader's
/// `controller.dispose()` for AudiobookPlayerController, or
/// `_audiobookController?.dispose()`) are NOT the webview controller and are
/// fine. A real behavioral test would need a live WebView2 native layer, so we
/// lock the contract at the source level across all `InAppWebView` widget sites.
///
/// `HeadlessInAppWebView` is the opposite case: it has no widget, so it MUST be
/// disposed manually — those sites are intentionally excluded here.
void main() {
  // Every file that builds an `InAppWebView` *widget* (not headless).
  const List<String> widgetSites = <String>[
    'lib/src/pages/implementations/dictionary_popup_webview.dart',
    'lib/src/pages/implementations/dictionary_structured_content_page.dart',
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ];

  for (final String relativePath in widgetSites) {
    test('$relativePath does not double-dispose its InAppWebView controller',
        () {
      final File file = File(relativePath);
      expect(file.existsSync(), isTrue,
          reason: 'guarded file moved or renamed: $relativePath — update this '
              'test to keep covering every InAppWebView widget site');

      // TODO-589 batch8: reader_hibiki_page.dart 的 InAppWebView 构建(_buildWebView)
      // 已搬到 reader_hibiki/webview.part.dart。该站点改读「主壳 + 全部 part」合并
      // 语料，使 InAppWebView( 哨兵与 _controller.dispose() 负向检查都覆盖 part；
      // 其余 widget 站点仍逐文件读取。
      final String rawSource = relativePath ==
              'lib/src/pages/implementations/reader_hibiki_page.dart'
          ? readReaderPageSource()
          : file.readAsStringSync();
      final String code = _stripLineComments(rawSource);

      // Sanity: confirm this really is an InAppWebView widget site, so the test
      // fails loudly (rather than silently passing) if a file stops using it.
      expect(code, contains('InAppWebView('),
          reason: '$relativePath no longer builds an InAppWebView widget — '
              'remove it from widgetSites');

      for (final String call in <String>[
        '_controller?.dispose()',
        '_controller!.dispose()',
        '_controller.dispose()',
      ]) {
        expect(code, isNot(contains(call)),
            reason: '$relativePath manually disposes its webview controller '
                '($call). The InAppWebView widget owns it — remove the call '
                '(see the Windows double-dispose crash).');
      }
    });
  }
}

/// Drops `//` line comments so source-text assertions match real code, not the
/// explanatory prose that documents the removed call.
String _stripLineComments(String source) {
  return source
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
