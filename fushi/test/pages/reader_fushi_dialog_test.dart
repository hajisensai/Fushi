import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/srt_book_reimport_dialog.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('lyrics mode hint dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(ReaderLyricsModeHintDialog(onClose: () {})),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.lyrics_mode_hint_title), findsOneWidget);
    expect(
      find.text(MaterialLocalizations.of(tester.element(find.byType(Dialog)))
          .okButtonLabel),
      findsOneWidget,
    );
  });

  testWidgets('SRT book reimport dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    // 360 而不是上面那条的 240：本对话框走共享 [ImportDialogFrame]（与书/有声书
    // 两个导入对话框同一外框），它的固定 chrome（header + divider + 双按钮 footer）
    // 实测约 211 逻辑像素，而 frame 只肯占视口高的 0.86 —— 240 高的视口对**任何**
    // 导入对话框都不够（与本改动无关，把 body 换成 SizedBox.shrink 同样溢出 5px）。
    // 360 仍远小于任何真实桌面窗口，紧凑布局的守卫意图不变。
    tester.view.physicalSize = const Size(320, 360);
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrtBook book = SrtBook()
      ..uid = 'srtbook_1'
      ..title = 'Very long subtitle book title for compact layout'
      ..srtPath = '/persist/very-long-subtitle-file-name-for-compact.srt'
      ..bookKey = 'very-long-subtitle-book-title'
      ..audioPaths = <String>['/persist/01.m4a', '/persist/02.m4a'];

    await tester.pumpWidget(
      buildApp(
        ProviderScope(
          child: SrtBookReimportDialog(
            book: book,
            db: db,
            repo: SrtBookRepository(db),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.srt_book_reimport), findsOneWidget);
    // 音频与字幕两半都在——用户报的「导入音频导不了字幕文件」就是缺了第二行。
    expect(find.text(t.srt_import_pick_audio_files), findsOneWidget);
    expect(find.text(t.srt_import_pick_subtitle_files), findsOneWidget);
  });
}
