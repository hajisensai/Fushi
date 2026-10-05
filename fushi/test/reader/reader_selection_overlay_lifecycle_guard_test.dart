import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// BUG-2960: route/bridge wiring guard. Actual DOM geometry and Android platform
// composition still require the device matrix; a source guard is not a UI test.
void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync();
  final String webview = File(
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
  ).readAsStringSync();

  for (final (String, String) route in <(String, String)>[
    ('Future<void> _presentSideSheet(', 'showReaderSettingsSideDialog'),
    ('Future<void> _presentSideSheet(', 'showReaderSideSheet'),
    ('Future<void> _openGallery(', 'Navigator.push'),
    ('Future<void> _openImageViewer(', 'Navigator.push'),
    ('Future<void> _openStatisticsCenter(', 'Navigator.of'),
  ]) {
    test('${route.$1} clears selection before ${route.$2}', () {
      final String body = maskComments(methodBody(chrome, route.$1));
      final int clear = body.indexOf('await _clearReaderAppSelection();');
      final int present = body.indexOf(route.$2);
      expect(clear, greaterThanOrEqualTo(0));
      expect(present, greaterThan(clear));
      expect(body.substring(clear, present), contains('if (!mounted) return;'));
    });
  }

  test('late selection menu is rejected while a covering route owns input', () {
    final String body = maskComments(
      methodBody(chrome, 'Future<void> _handleSelectionMenu('),
    );
    expect(body, contains('ModalRoute.of(context)'));
    expect(body, contains('_sideSheetOpen || _appearanceSheetOpen ||'));
    expect(body, contains('_studyClockModalDepth > 0'));
    final int guard = body.indexOf('!owner.isCurrent');
    final int insert = body.indexOf('overlay.insert(entry)');
    expect(guard, lessThan(insert));
    expect(
      body.substring(guard, insert),
      contains('await _clearReaderAppSelection();'),
    );
    expect(body.substring(guard, insert), contains('return;'));
  });

  test(
    'JS clear notification removes host controls without a JS clear loop',
    () {
      final String source = maskComments(webview);
      final int start = source.indexOf("handlerName: 'onSelectionCleared'");
      expect(start, greaterThanOrEqualTo(0));
      final int end = source.indexOf('controller.addJavaScriptHandler(', start);
      expect(end, greaterThan(start));
      final String handler = source.substring(start, end);
      expect(handler, contains('_removeSelectionActionBar()'));
      expect(handler, isNot(contains('_clearReaderAppSelection')));
      expect(handler, isNot(contains('evaluateJavascript')));
    },
  );

  test('host teardown clears both the entry and its cached action payload', () {
    final String body = maskComments(
      methodBody(chrome, 'void _removeSelectionActionBar('),
    );
    expect(body, contains('remove()'));
    expect(body, contains('dispose()'));
    expect(body, contains('_selectionActionBarEntry = null'));
    expect(body, contains('_selectionActionData = null'));
    expect(body, contains('_selectionActionSectionIndex = null'));
  });
  test('all audio modal routes await the shared selection boundary', () {
    final String navigation = File(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    ).readAsStringSync();
    final String audiobook = File(
      'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
    ).readAsStringSync();
    final String boundary = maskComments(
      methodBody(navigation, 'Future<T?> _withStudyClockPaused<T>('),
    );
    final int lock = boundary.indexOf('_studyClockModalDepth++');
    final int clear = boundary.indexOf('await _clearReaderAppSelection();');
    final int show = boundary.indexOf('return await body();');
    expect(lock, greaterThanOrEqualTo(0));
    expect(clear, greaterThan(lock));
    expect(show, greaterThan(clear));
    expect(
      boundary.substring(clear, show),
      contains('if (!mounted) return null;'),
    );
    expect(boundary, contains('finally'));
    expect(boundary, contains('_studyClockModalDepth--;'));
    for (final (String, String) route in <(String, String)>[
      (audiobook, 'Future<void> _openAudioImportDialog('),
      (audiobook, 'Future<void> _openSrtBookReimport('),
      (chrome, 'Future<void> _openAlignmentImportDialog('),
      (chrome, 'Future<void> _transcribeFromAudiobookPanel('),
      (chrome, 'Future<void> _showAppearanceSheet('),
    ]) {
      expect(
        maskComments(methodBody(route.$1, route.$2)),
        contains('_withStudyClockPaused('),
        reason: route.$2,
      );
    }
    // The unbound-audio branch must not bypass teardown in either input route.
    expect(audiobook, contains('await _openSrtBookReimport();'));
    final String caret = File(
      'lib/src/pages/implementations/reader_fushi/caret.part.dart',
    ).readAsStringSync();
    expect(caret, contains('_openAudioImportDialog()'));
    expect(chrome, contains(': _openAudioImportDialog,'));
  });

  test(
    'grip movement removes only the host bar, not the moving DOM target',
    () {
      final String source = maskComments(webview);
      final int start = source.indexOf("handlerName: 'onSelectionDragStarted'");
      expect(start, greaterThanOrEqualTo(0));
      final int end = source.indexOf('controller.addJavaScriptHandler(', start);
      expect(end, greaterThan(start));
      final String handler = source.substring(start, end);
      expect(handler, contains('_removeSelectionActionBar()'));
      expect(handler, isNot(contains('_clearReaderAppSelection')));
      expect(handler, isNot(contains('evaluateJavascript')));
    },
  );

  test('toolbar anchors on the text rect and dodges each grip box', () {
    final String bar = maskComments(
      methodBody(chrome, 'Widget _buildSelectionActionBar('),
    );
    // 锚点是选区正文（data.rect）；手柄盒只是**要避开的障碍**。两者不能合并成一个矩形：
    // 合并（`handlesRect ?? rect`）会让横排把手柄并集的 top（落在正文里）当锚点、竖排
    // 页顶翻到并集底端 —— 面板从选区头部掉到选区尾部下方。
    expect(bar, contains('mapToOverlay(data.rect)'));
    expect(bar, contains('mapToOverlay(data.handlesRect)'));
    expect(bar, isNot(contains('handlesRect ?? data.rect')));
    // 两个球的盒子各自映射后交给布局器（并集 bbox 会把两球之间的正文空白也算成障碍）。
    expect(bar, contains('data.handlesBoxes'));
    expect(bar, contains('gripBoxes: gripBoxes'));
    expect(bar, contains('selectionRect: selectionRect'));
    expect(bar, contains('webBox.localToGlobal('));
    expect(bar, contains('overlayBox.globalToLocal(topGlobal)'));
    expect(bar, contains('overlayBox.globalToLocal(bottomGlobal)'));
    expect(bar, contains('ReaderSelectionToolbarLayout('));
    expect(bar, contains('safeInsets: MediaQuery.paddingOf(overlayContext)'));
    // 定位必须完全交给布局器：不得回到「假定 48px 高度 + 首字顶边 + 手柄预留」那套手算
    // （上游 glass 分支仍会用到 `barHeight`，但那只服务胶囊形状，不参与定位）。
    expect(bar, isNot(contains('double top =')));
    expect(bar, isNot(contains('handleReserve')));
    expect(bar, isNot(contains('selectionTop')));
    expect(bar, isNot(contains('selectionBottom')));
  });
}
