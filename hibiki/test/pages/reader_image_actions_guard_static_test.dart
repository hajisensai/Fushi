import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('reader JavaScript routes image context menu and long press to Dart',
      () {
    final String source = readReaderPageSource();
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
    final String source = readReaderPageSource();

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
    final String source = readReaderPageSource();

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
    // NOTE(BUG-402): reader text-selection copy (Ctrl+C, caret.part.dart) legitimately
    // uses Clipboard.setData for TEXT. Image copy is still locked to the native
    // clipboardImage channel by the assertions above (clipboardImage/copyImageFile),
    // so the old corpus-wide isNot(Clipboard.setData) guard was over-broad and removed.
  });

  test('reader image context menu scales with reader chrome only', () {
    final String source = readReaderPageSource();

    expect(source, contains('double get _readerImageMenuScale'));
    final String menu = _functionSource(
      source,
      'Future<void> _showReaderImageContextMenuAtGlobalPosition(',
      'Future<void> _shareReaderImage(String imgUrl)',
    );

    expect(menu, contains('final double menuScale = _readerImageMenuScale'));
    expect(
      RegExp(r'minWidth:\s*112(?:\.0)?\s*\*\s*menuScale').hasMatch(menu),
      isTrue,
    );
    expect(
      RegExp(r'maxWidth:\s*280(?:\.0)?\s*\*\s*menuScale').hasMatch(menu),
      isTrue,
    );
    expect(
      RegExp(r'height:\s*kMinInteractiveDimension\s*\*\s*menuScale')
          .hasMatch(menu),
      isTrue,
    );
    expect(
      RegExp(r'horizontal:\s*16(?:\.0)?\s*\*\s*menuScale').hasMatch(menu),
      isTrue,
    );
    expect(
      RegExp(r'size:\s*18(?:\.0)?\s*\*\s*menuScale').hasMatch(menu),
      isTrue,
    );
    expect(
      RegExp(r'width:\s*12(?:\.0)?\s*\*\s*menuScale').hasMatch(menu),
      isTrue,
    );
    expect(
      RegExp(r'fontSize:\s*14(?:\.0)?\s*\*\s*menuScale').hasMatch(menu),
      isTrue,
    );

    // The menu anchor must be mapped through the Overlay RenderBox so the global
    // HibikiAppUiScale FittedBox transform is absorbed; scaling the menu must not
    // also scale or rebase the anchor (BUG-381 — same fix family as BUG-129/261).
    expect(menu, contains('Rect.fromLTWH('));
    // Anchor is mapped from real screen coords into the menu host Overlay's local
    // space via globalToLocal; the Rect must use the mapped `anchor`, not the raw
    // global position (which would offset the menu by factor≈scale when ui scale
    // ≠ 100%).
    expect(menu, contains('overlay.globalToLocal(globalPosition)'));
    expect(
      RegExp(r'Rect\.fromLTWH\(\s*anchor\.dx,\s*anchor\.dy').hasMatch(menu),
      isTrue,
      reason: 'menu Rect must anchor on overlay-local coords, not raw global',
    );
    // The anchor mapping must NOT read/scale by menuScale (content scale only).
    expect(menu, isNot(contains('anchor.dx * menuScale')));
    expect(menu, isNot(contains('anchor.dy * menuScale')));
    expect(menu, isNot(contains('globalPosition.dx * menuScale')));
    expect(menu, isNot(contains('globalPosition.dy * menuScale')));
    expect(menu, isNot(contains('webViewOffset *')));
    expect(menu, isNot(contains('webViewOffset.dx * menuScale')));
    expect(menu, isNot(contains('webViewOffset.dy * menuScale')));
  });

  test('expanded reader image viewer exposes Windows right-click copy menu',
      () {
    final String source = readReaderPageSource();
    final String viewer = _functionSource(
      source,
      'void _openImageViewer(String imgUrl)',
      'void _toggleChrome(',
    );

    expect(viewer, contains('_readerImageFileForUrl(imgUrl)'));
    expect(viewer, contains('onSecondaryTapDown'));
    expect(viewer, contains('isWindowsPlatform'));
    expect(viewer, contains('details.globalPosition'));
    expect(viewer, contains('_showReaderImageContextMenuAtGlobalPosition'));
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
