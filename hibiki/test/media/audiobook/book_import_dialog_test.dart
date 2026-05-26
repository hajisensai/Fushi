import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
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

  test('windows audio file filter includes an all files option', () {
    final String filter =
        FilePickerWindows().fileTypeToFileFilter(FileType.audio, null);

    expect(
      filter,
      'Audios (*.aac,*.midi,*.mp3,*.ogg,*.wav,*.m4a)\x00'
      '*.aac;*.midi;*.mp3;*.ogg;*.wav;*.m4a\x00'
      'All Files (*.*)\x00'
      '*.*\x00\x00',
    );
  });
}
