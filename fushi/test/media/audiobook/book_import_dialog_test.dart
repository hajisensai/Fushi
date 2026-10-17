// HBK-AUDIT-143: the file-level @TestOn('windows') gate meant this whole file
// was silently skipped on the project's primary platform (Android) and on CI.
// The dialog-frame layout test is platform-independent, so it now runs
// everywhere; only the Windows file-filter test stays gated via `testOn`.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/src/file_picker.dart';
import 'package:file_picker/src/windows/file_picker_windows.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('book import dialog frame fits compact form content', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        BookImportDialogFrame(
          title: 'Import Book',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              TextField(decoration: InputDecoration(labelText: 'EPUB')),
              TextField(decoration: InputDecoration(labelText: 'Subtitle')),
              TextField(decoration: InputDecoration(labelText: 'Audio')),
              TextField(decoration: InputDecoration(labelText: 'Cover')),
              TextField(decoration: InputDecoration(labelText: 'Title')),
              TextField(decoration: InputDecoration(labelText: 'Author')),
            ],
          ),
          actions: const [
            TextButton(onPressed: null, child: Text('Cancel')),
            FilledButton(onPressed: null, child: Text('Import')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Import'), findsWidgets);
  });

  test(
    'windows audio file filter includes an all files option',
    () {
      final String filter =
          FilePickerWindows().fileTypeToFileFilter(FileType.audio, null);

      expect(
        filter,
        'Audios (*.aac,*.ac3,*.eac3,*.flac,*.m4a,*.m4b,*.mp3,*.mp4,*.ogg,*.opus,*.wav,*.wma)\x00'
        '*.aac;*.ac3;*.eac3;*.flac;*.m4a;*.m4b;*.mp3;*.mp4;*.ogg;*.opus;*.wav;*.wma\x00'
        'All Files (*.*)\x00'
        '*.*\x00\x00',
      );
    },
    // HBK-AUDIT-143: this assertion exercises the Windows-only file picker.
    testOn: 'windows',
  );

  // BUG-439: a bad EPUB (FormatException) generated/imported inside
  // _importSubtitleBook must abort the whole import, NOT be swallowed while a
  // bookKey-less SrtBook shell row is still saved (orphan card that can't open
  // + later fakes a successful delete). Source guard: the EPUB import catch must
  // rethrow so the top-level handler reports the failure.
  test('subtitle-book bad-EPUB import rethrows instead of saving a shell row',
      () {
    // 字幕书导入的实现已抽到引擎（发现页自动入库与对话框共用一份）：对话框
    // 必须委托给它，守卫随实现一起看引擎那份。
    final String dialog =
        File('lib/src/media/audiobook/book_import_dialog.dart')
            .readAsStringSync();
    final int dialogStart = dialog.indexOf('Future<void> _importSubtitleBook(');
    expect(dialogStart, isNonNegative,
        reason: '_importSubtitleBook must exist in book_import_dialog.dart');
    expect(
      dialog.substring(dialogStart),
      contains('importStandaloneSubtitleBook('),
      reason: 'the dialog must delegate to the shared engine primitive, '
          'not grow a second copy that the guard below does not see',
    );

    final String source = File(
      '../packages/fushi_engine/lib/media/audiobook/'
      'standalone_subtitle_book.dart',
    ).readAsStringSync();

    final int start =
        source.indexOf('Future<SrtBook> importStandaloneSubtitleBook(');
    expect(start, isNonNegative,
        reason: 'importStandaloneSubtitleBook must exist in the engine');
    // Inspect only the EPUB import try/catch region.
    final int regionEnd = source.indexOf('report(0.7', start);
    expect(regionEnd, greaterThan(start));
    final String region = source.substring(start, regionEnd);

    // The catch that logs the EPUB import failure must rethrow.
    final int logIdx =
        region.indexOf("engineLog.log('importStandaloneSubtitleBook.epubImport'");
    expect(logIdx, isNonNegative,
        reason: 'the bad-EPUB catch must still log for diagnostics');
    final String afterLog = region.substring(logIdx);
    expect(afterLog, contains('rethrow;'),
        reason:
            'a bad EPUB must abort the import (rethrow), not fall through to '
            'save an orphan SrtBook shell row with an empty bookKey (BUG-439).');
  });
}
