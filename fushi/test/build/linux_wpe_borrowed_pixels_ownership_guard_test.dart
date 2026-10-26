import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final File sourceFile = File(
    '../packages/flutter_inappwebview_linux/linux/in_app_webview/in_app_webview.cc',
  );
  late final String source;

  setUpAll(() {
    expect(
      sourceFile.existsSync(),
      isTrue,
      reason: 'expected WPE implementation at ${sourceFile.absolute.path}',
    );
    source = sourceFile.readAsStringSync();
  });

  test('WPE imported pixels are copied with the actual row stride', () {
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
      contains('const size_t source_stride = size / buf_height;'),
    );
    expect(
      pixelImport,
      contains('pixel_buffer.data.resize(row_bytes * buf_height);'),
    );
    expect(pixelImport, contains('buf_height, source_stride)'));
    expect(
      pixelImport,
      isNot(contains('memcpy(pixel_buffer.data.data(), data, size);')),
    );
    expect(
      source,
      contains('WPE returns a borrowed GBytes owned by the buffer'),
    );
    expect(pixelImport, isNot(contains('g_bytes_unref(pixels)')));
  });

  test('WPE view resize invalidation clears retained rendered buffers', () {
    expect(source, contains('buffers_changed_handler_ = g_signal_connect'));
    expect(source, contains('void InAppWebView::OnWpePlatformBuffersChanged'));
    expect(
      source,
      contains('release_buffer_after_copy && wpe_view_ != nullptr'),
    );
  });
}
