import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

void main() {
  test('Apple reader resources use WKURLSchemeHandler wiring', () {
    final String source = File(
      'lib/src/media/sources/reader_hibiki_source.dart',
    ).readAsStringSync();
    final String reader = readReaderPageSource();

    expect(source, contains('static const String kResourceScheme'));
    expect(source, contains('Platform.isMacOS || Platform.isIOS'));
    expect(source, contains(r"'$kResourceScheme://$kHost/epub/$encoded'"));
    expect(source, contains('fontUrlBuilder: fontUrl'));
    expect(source, contains('static String fontUrl(String path)'));

    expect(reader, contains('resourceCustomSchemes:'));
    expect(reader, contains('ReaderHibikiSource.kResourceScheme'));
    expect(reader, contains('onLoadResourceWithCustomScheme'));
    expect(reader, contains('_loadResourceWithCustomScheme'));
    expect(reader, contains('_readerResourcePayload'));
    expect(reader, contains('ReaderHibiki.customSchemeResource'));
    expect(reader, contains('ReaderHibiki.interceptResource'));
    expect(reader, contains("path.startsWith('/fonts/')"));
    expect(
        reader,
        contains(
            'useShouldInterceptRequest: !_usesReaderResourceCustomScheme'));
  });
}
