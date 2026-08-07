import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('reader JavaScript routes image context menu and long press to Dart',
      () {
    final String source = readReaderPageSource();
    final String js = _functionSource(
      source,
      'function _fushiBlockImageUrl(target)',
      'window.fushiProgressDetails',
    );

    expect(js, contains("document.addEventListener('contextmenu'"));
    expect(js, contains("'onImageContextMenu'"));
    expect(js, contains('e.preventDefault()'));
    expect(js, contains("document.addEventListener('touchstart'"));
    expect(js, contains('setTimeout'));
    expect(js, contains("callHandler('onImageLongPress'"));
    expect(js, contains('clearImageLongPressTimer'));
    expect(js, contains('imageLongPressConsumed'));
    expect(js, contains('_fushiBlockImageUrl(e.target'));
  });

  test('reader resolves fushi.local image URLs to files before actions', () {
    final String source = readReaderPageSource();

    expect(source, contains('File? _readerImageFileForUrl(String imgUrl)'));
    final String helper = _functionSource(
      source,
      'File? _readerImageFileForUrl(String imgUrl)',
      'void _openImageViewer(String imgUrl)',
    );
    expect(helper, contains('ReaderFushiSource.kHost'));
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
    expect(source, contains('FushiShare.shareFiles'));
    expect(source, contains('XFile(file.path'));
    expect(source, contains('FushiChannels.clipboardImage'));
    expect(source, contains('invokeMethod<void>('));
    expect(source, contains("'copyImageFile'"));
    // NOTE(BUG-402): reader text-selection copy (Ctrl+C, caret.part.dart) legitimately
    // uses Clipboard.setData for TEXT. Image copy is still locked to the native
    // clipboardImage channel by the assertions above (clipboardImage/copyImageFile),
    // so the old corpus-wide isNot(Clipboard.setData) guard was over-broad and removed.
  });

  test('reader image context menu does not double-scale with ui scale', () {
    final String source = readReaderPageSource();

    // BUG-1438：本用例原先要求菜单尺寸乘 `_readerImageMenuScale`，方向是反的。
    // 菜单由 PopupMenuRoute 承载，挂在根 Overlay = 全局 FushiAppUiScale 的缩放画布
    // 内，画布→屏幕这一跳已按 scale 放大过一次；阅读器 chrome 之所以要手动乘，是因为
    // chrome 在 FushiAppUiScaleNeutralizer **之内**（净缩放=1）。把 chrome 的规则套到
    // 菜单上 → 视觉尺寸 scale²（实测 scale=2 时 chrome 文字 40px、菜单 80px）。
    // 现在菜单尺寸一律写常量，"随界面大小缩放"由它所在的画布负责。
    // 真行为断言见 test/pages/context_menu_ui_scale_guard_test.dart。
    expect(source, isNot(contains('double get _readerImageMenuScale')),
        reason: '双重缩放根源的 getter 必须保持删除状态');

    final String menu = _functionSource(
      source,
      'Future<void> _showReaderImageContextMenuAtGlobalPosition(',
      'Future<void> _shareReaderImage(String imgUrl)',
    );

    // 尺寸写常量，且不得再出现任何 menuScale 乘法。
    expect(menu, contains('minWidth: 112.0'));
    expect(menu, contains('maxWidth: 280.0'));
    expect(menu, contains('height: kMinInteractiveDimension,'));
    expect(menu, contains('horizontal: 16.0'));
    expect(menu, contains('size: 18.0'));
    expect(menu, contains('width: 12.0'));
    expect(menu, contains('fontSize: 14.0'));
    expect(
      containsCodeLine(menu, 'menuScale'),
      isFalse,
      reason: '菜单在缩放画布内已天然跟随界面大小，再乘一次得 scale²（BUG-1438）',
    );

    // The menu anchor must be mapped through the Overlay RenderBox so the global
    // FushiAppUiScale FittedBox transform is absorbed; scaling the menu must not
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
    // 锚点绝不能被任何缩放系数改写——它由 Overlay 的 render transform 负责换算。
    expect(menu, isNot(contains('anchor.dx *')));
    expect(menu, isNot(contains('anchor.dy *')));
    expect(menu, isNot(contains('globalPosition.dx *')));
    expect(menu, isNot(contains('globalPosition.dy *')));
    expect(menu, isNot(contains('webViewOffset *')));
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
    expect(runner, contains('"app.fushi.reader/clipboard_image"'));
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
