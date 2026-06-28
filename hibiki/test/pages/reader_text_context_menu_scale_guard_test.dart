import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// TODO-954 守卫：阅读器**文字选区右键菜单**（查词 / 复制 / 导出）必须随界面大小缩放
/// （`menuScale = _readerImageMenuScale`，与图片右键同范式，落在 HibikiAppUiScale 内的
/// Overlay 渲染链上），且导出入口从查词弹窗 header 迁到选区右键（Windows Flutter 菜单 +
/// 移动端原生 ContextMenu），防止回退成「右键不吃界面大小」/「弹窗里塞导出按钮」。
void main() {
  String functionSource(String source, String start, String end) {
    final int startIndex = source.indexOf(start);
    expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
    final int endIndex = source.indexOf(end, startIndex + start.length);
    expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
    return source.substring(startIndex, endIndex);
  }

  test(
      'reader text context menu (search/copy/export) scales with reader chrome',
      () {
    final String source = readReaderPageSource();

    expect(
      source,
      contains(
          'Future<void> _showReaderTextContextMenu(Offset globalPosition)'),
    );
    final String menu = functionSource(
      source,
      'Future<void> _showReaderTextContextMenu(Offset globalPosition)',
      'Future<void> _exportAudiobookClipFromSelection()',
    );

    // Content scale: the menu must derive from _readerImageMenuScale (same
    // getter the image menu uses), never from a freshly read HibikiAppUiScale.
    expect(menu, contains('final double menuScale = _readerImageMenuScale'));

    // Anchor mapped through the Overlay RenderBox (FittedBox transform absorbed);
    // the Rect must use the mapped `anchor`, not raw globalPosition.
    expect(menu, contains('overlay.globalToLocal(globalPosition)'));
    expect(
      RegExp(r'Rect\.fromLTWH\(\s*anchor\.dx,\s*anchor\.dy').hasMatch(menu),
      isTrue,
      reason: 'menu Rect must anchor on overlay-local coords, not raw global',
    );
    expect(menu, isNot(contains('anchor.dx * menuScale')));
    expect(menu, isNot(contains('globalPosition.dx * menuScale')));

    // Every menu item dimension scales with menuScale.
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

    // Three actions present: search, copy, export.
    expect(menu, contains("value: 'search'"));
    expect(menu, contains('t.search'));
    expect(menu, contains("value: 'copy'"));
    expect(menu, contains('t.copy'));
    expect(menu, contains("value: 'export'"));
    expect(menu, contains('t.audiobook_export_clip'));
    // Copy uses the BUG-402 native-selection clipboard path for TEXT.
    expect(menu, contains('Clipboard.setData'));
    // Export item is gated on the book having audio cues.
    expect(menu, contains('if (hasAudio)'));
  });

  test('Windows reader WebView routes right-click to the Flutter text menu',
      () {
    final String source = readReaderPageSource();

    // Windows: native WebView2 context menu disabled, right-click captured by a
    // translucent GestureDetector onSecondaryTapDown -> Flutter menu.
    expect(source, contains('hideDefaultSystemContextMenuItems: true'));
    expect(source, contains('onSecondaryTapDown'));
    expect(
      source,
      contains('_showReaderTextContextMenu(details.globalPosition)'),
    );
    expect(source, contains('HitTestBehavior.translucent'));

    // Mobile keeps the native ContextMenu and now also carries an export item.
    final String webViewBuild = functionSource(
      source,
      'Widget _buildWebView()',
      'Future<void> _onChapterLoadComplete(',
    );
    expect(webViewBuild, contains('title: t.search'));
    expect(webViewBuild, contains('title: t.audiobook_export_clip'));
    expect(webViewBuild, contains('_exportAudiobookClipFromSelection()'));
  });

  test('export-from-selection resolves cue range without opening lookup popup',
      () {
    final String source = readReaderPageSource();

    expect(
      source,
      contains('Future<void> _exportAudiobookClipFromSelection()'),
    );
    final String selectionStateHelper = functionSource(
      source,
      'Future<ReaderSelectionData?> _fillLookupStateFromNativeSelection()',
      'Future<void> _exportAudiobookClipFromSelection()',
    );
    final String resolver = functionSource(
      source,
      'Future<void> _exportAudiobookClipFromSelection()',
      'Future<void> _shareReaderImage(String imgUrl)',
    );

    // Resolves the native selection -> sentence cue range via the shared JS
    // helper, NOT through _handleTextSelected (which would pop the lookup popup
    // and pause audio — the whole point of TODO-954 is to decouple export).
    expect(
      selectionStateHelper,
      contains(
          'ReaderSelectionScripts.nativeSelectionSentenceRangeInvocation()'),
    );
    expect(selectionStateHelper, isNot(contains('_handleTextSelected(')));
    expect(selectionStateHelper, contains('ReaderSelectionData.fromJson'));
    expect(selectionStateHelper, contains('_cachedSentenceRange'));
    expect(resolver, contains('_fillLookupStateFromNativeSelection()'));
    expect(resolver, contains('_exportAudiobookClip()'));
  });

  test('lookup popup header no longer carries the clip export button', () {
    final String source = readReaderPageSource();

    final String header = functionSource(
      source,
      'Widget? buildPopupAudioControls()',
      '// ── Helpers ',
    );
    // The movie_creation_outlined export button must be gone from the popup
    // header (it now lives in the selection right-click menu).
    expect(
      header,
      isNot(contains('Icons.movie_creation_outlined')),
      reason: 'clip export button must be removed from the lookup popup header',
    );
    expect(header, isNot(contains('onTap: hasCue ? _exportAudiobookClip')));
  });
}
