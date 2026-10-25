import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 「导出有声书（M4B）」原先只挂在制作页上：离开制作页后，已附加有声书的书就再也
/// 找不到导出出口。导出对任何已附加的有声书都成立（TTS 制作的或用户导入的），所以
/// 「已附加有声书」对话框必须带这个入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('已附加有声书对话框提供「导出有声书」入口', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AudiobookRepository repo = AudiobookRepository(db);
    const String bookKey = 'attached-export-book';
    await tester.runAsync(() async {
      await repo.replaceAudio(
        bookKey: bookKey,
        audioPaths: const <String>[r'C:\b\tts_000.m4a', r'C:\b\tts_001.m4a'],
      );
      await repo.replaceAlignment(
        bookKey: bookKey,
        format: 'srt',
        path: r'C:\b\tts_audiobook.srt',
      );
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: AudiobookImportDialog(bookKey: bookKey, repo: repo),
            ),
          ),
        ),
      ),
    );
    // `_initExisting` 是一次 DB 往返：显式 pump 排空，等只读视图出现。
    for (
      int i = 0;
      i < 20 && find.text(t.audiobook_attached).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(t.audiobook_attached), findsOneWidget);

    final Finder exportRow = find.byKey(
      const ValueKey<String>('audiobook-attached-export-run'),
    );
    expect(exportRow, findsOneWidget);
    expect(
      find.descendant(
        of: exportRow,
        matching: find.text(t.audiobook_studio_export),
      ),
      findsOneWidget,
    );
  });
}
