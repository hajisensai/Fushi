import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WPE imported pixels are copied without unrefing the borrowed GBytes', () {
    final File sourceFile = File(
      '../packages/flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc',
    );
    expect(
      sourceFile.existsSync(),
      isTrue,
      reason: 'expected WPE implementation at ${sourceFile.absolute.path}',
    );
    final String source = sourceFile.readAsStringSync();
    final int importStart = source.indexOf(
      'GBytes* pixels = wpe_buffer_import_to_pixels(buffer, &error);',
    );
    final int nextBufferHandler = source.indexOf(
      'if (!buffer_handled)',
      importStart + 1,
    );

    expect(importStart, isNonNegative);
    expect(nextBufferHandler, greaterThan(importStart));

    final String pixelImport = source.substring(importStart, nextBufferHandler);
    expect(
      pixelImport,
      contains('memcpy(pixel_buffer.data.data(), data, size);'),
    );
    expect(pixelImport, contains('returns a borrowed GBytes owned by'));
    expect(
      pixelImport,
      contains('WPEBuffer (WPEPlatform GIR transfer-ownership="none")'),
    );
    expect(pixelImport, isNot(contains('g_bytes_unref(pixels)')));
  });
}
