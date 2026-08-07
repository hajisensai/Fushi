import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// TODO-954 守卫：阅读器**文字选区右键菜单**（查词 / 复制 / 收藏 / 导出）随界面大小
/// 缩放，且导出入口从查词弹窗 header 迁到选区右键（Windows Flutter 菜单 + 移动端原生
/// ContextMenu），防止回退成「弹窗里塞导出按钮」。
///
/// BUG-1438 修正了本守卫原来的方向：它曾要求菜单尺寸乘 `menuScale =
/// _readerImageMenuScale`。那是**双重缩放**——菜单挂在根 Overlay，即全局
/// FushiAppUiScale 的缩放画布内，画布→屏幕这一跳已经按 scale 放大过一次；
/// 而阅读器 chrome 需要手动乘，是因为它在 FushiAppUiScaleNeutralizer **之内**
/// （净缩放=1）。两者在中和器的两侧，规则不能互抄。实测 scale=2 时同样写
/// `fontSize: 14 * menuScale`，chrome 渲染 40px 而菜单 80px。
/// 「菜单随界面大小缩放」这个诉求本身没变，只是由画布负责，代码写常量即可。
/// 真行为断言（线性而非平方）见 test/pages/context_menu_ui_scale_guard_test.dart。
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

    // Anchor mapped through the Overlay RenderBox (FittedBox transform absorbed);
    // the Rect must use the mapped `anchor`, not raw globalPosition.
    expect(menu, contains('overlay.globalToLocal(globalPosition)'));
    expect(
      RegExp(r'Rect\.fromLTWH\(\s*anchor\.dx,\s*anchor\.dy').hasMatch(menu),
      isTrue,
      reason: 'menu Rect must anchor on overlay-local coords, not raw global',
    );
    expect(menu, isNot(contains('anchor.dx *')));
    expect(menu, isNot(contains('globalPosition.dx *')));

    // BUG-1438：尺寸写常量，不得再乘任何界面缩放系数（否则 scale²）。
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
