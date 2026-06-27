// HBK-AUDIT-143: the file-level @TestOn('windows') gate meant this whole file
// was silently skipped on the project's primary platform (Android) and on CI.
// The dialog-frame layout test is platform-independent, so it now runs
// everywhere; only the Windows file-filter test stays gated via `testOn`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/src/file_picker.dart';
import 'package:file_picker/src/windows/file_picker_windows.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(home: Scaffold(body: Center(child: child)));
  }

  testWidgets('book import dialog frame fits compact form content', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        BookImportDialogFrame(
          title: const Text('Import Book'),
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
    final String source =
        File('lib/src/media/audiobook/book_import_dialog.dart')
            .readAsStringSync();

    final int start = source.indexOf('Future<void> _importSubtitleBook(');
    expect(start, isNonNegative,
        reason: '_importSubtitleBook must exist in book_import_dialog.dart');
    // Inspect only the EPUB import try/catch region of _importSubtitleBook.
    final int regionEnd = source.indexOf('reportProgress(0.7', start);
    expect(regionEnd, greaterThan(start));
    final String region = source.substring(start, regionEnd);

    // The catch that logs the EPUB import failure must rethrow.
    final int logIdx = region
        .indexOf("ErrorLogService.instance.log('BookImportDialog.epubImport'");
    expect(logIdx, isNonNegative,
        reason: 'the bad-EPUB catch must still log for diagnostics');
    final String afterLog = region.substring(logIdx);
    expect(afterLog, contains('rethrow;'),
        reason:
            'a bad EPUB must abort the import (rethrow), not fall through to '
            'save an orphan SrtBook shell row with an empty bookKey (BUG-439).');
  });
}
