import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('reader JavaScript routes image context menu and long press to Dart',
      () {
    final String source =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');
    final String js = _functionSource(
      source,
      'function _hoshiBlockImageUrl(target)',
      'window.hoshiProgressDetails',
    );

    expect(js, contains("document.addEventListener('contextmenu'"));
    expect(js, contains("'onImageContextMenu'"));
    expect(js, contains('e.preventDefault()'));
    expect(js, contains("document.addEventListener('touchstart'"));
    expect(js, contains('setTimeout'));
    expect(js, contains("callHandler('onImageLongPress'"));
    expect(js, contains('clearImageLongPressTimer'));
    expect(js, contains('imageLongPressConsumed'));
    expect(js, contains('_hoshiBlockImageUrl(e.target'));
  });

  test('reader resolves hoshi.local image URLs to files before actions', () {
    final String source =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');

    expect(source, contains('File? _readerImageFileForUrl(String imgUrl)'));
    final String helper = _functionSource(
      source,
      'File? _readerImageFileForUrl(String imgUrl)',
      'void _openImageViewer(String imgUrl)',
    );
    expect(helper, contains('ReaderHibikiSource.kHost'));
    expect(helper, contains("uri.path.startsWith('/epub/')"));
    expect(helper, contains('p.canonicalize(_extractDir!)'));
    expect(helper, contains('p.isWithin'));
    expect(helper, contains('File(filePath)'));
    expect(helper, contains('file.existsSync()'));

    final String viewer = _functionSource(
      source,
      'void _openImageViewer(String imgUrl)',
      '),',
    );
    expect(viewer, contains('_readerImageFileForUrl(imgUrl)'));
  });

  test('reader exposes desktop copy and mobile share image handlers', () {
    final String source =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');

    expect(source, contains("handlerName: 'onImageContextMenu'"));
    expect(source, contains("handlerName: 'onImageLongPress'"));
    expect(source, contains('Future<void> _showReaderImageContextMenu('));
    expect(source, contains('Future<void> _shareReaderImage(String imgUrl)'));
    expect(source, contains('Future<void> _copyReaderImageToClipboard('));
    expect(source, contains('Share.shareXFiles'));
    expect(source, contains('XFile(file.path'));
    expect(source, contains('HibikiChannels.clipboardImage'));
    expect(source, contains('invokeMethod<void>('));
    expect(source, contains("'copyImageFile'"));
    expect(source, isNot(contains('Clipboard.setData')));
  });

  test('Windows runner registers a native image clipboard channel', () {
    final String constants = read('lib/src/utils/misc/channel_constants.dart');
    final String header = read('windows/runner/flutter_window.h');
    final String runner = read('windows/runner/flutter_window.cpp');

    expect(constants, contains('clipboardImage'));
    expect(constants, contains("MethodChannel('\$_prefix/clipboard_image')"));
    expect(header, contains('clipboard_image_channel_'));
    expect(runner, contains('"app.hibiki.reader/clipboard_image"'));
    expect(runner, contains('copyImageFile'));
    expect(runner, contains('CopyImageFileToClipboard'));
    expect(runner, contains('CF_DIB'));
    expect(runner, contains('OpenClipboard'));
    expect(runner, contains('SetClipboardData'));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
