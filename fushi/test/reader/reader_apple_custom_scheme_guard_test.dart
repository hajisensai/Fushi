import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

void main() {
  test('Apple reader resources use WKURLSchemeHandler wiring', () {
    final String source = File(
      'lib/src/media/sources/reader_fushi_source.dart',
    ).readAsStringSync();
    final String reader = readReaderPageSource();

    expect(source, contains('static const String kResourceScheme'));
    // 资源 URL 的 scheme 与 WebView 的 resourceCustomSchemes 必须问同一个判据
    // （platform_utils.dart `webViewUsesCustomSchemeTransport`）：WKWebView 与
    // Linux 的 WPE WebKit 都只能注册自定义 scheme，拦不到 https。
    expect(source, contains('if (webViewUsesCustomSchemeTransport)'));
    final String platformUtils = File(
      'lib/src/utils/misc/platform_utils.dart',
    ).readAsStringSync();
    expect(
      platformUtils,
      contains('bool get webViewUsesCustomSchemeTransport =>\n'
          '    Platform.isMacOS || Platform.isIOS || Platform.isLinux;'),
    );
    expect(
      reader,
      contains('static bool get _usesReaderResourceCustomScheme =>\n'
          '      webViewUsesCustomSchemeTransport;'),
    );
    expect(source, contains(r"'$kResourceScheme://$kHost/epub/$encoded'"));
    expect(source, contains('fontUrlBuilder: fontUrl'));
    expect(source, contains('static String fontUrl(String path)'));

    expect(reader, contains('resourceCustomSchemes:'));
    expect(reader, contains('ReaderFushiSource.kResourceScheme'));
    expect(reader, contains('onLoadResourceWithCustomScheme'));
    expect(reader, contains('_loadResourceWithCustomScheme'));
    expect(reader, contains('_readerResourcePayload'));
    expect(reader, contains('ReaderFushi.customSchemeResource'));
    expect(reader, contains('ReaderFushi.interceptResource'));
    expect(reader, contains("path.startsWith('/fonts/')"));
    expect(
        reader,
        contains(
            'useShouldInterceptRequest: !_usesReaderResourceCustomScheme'));
  });
}
