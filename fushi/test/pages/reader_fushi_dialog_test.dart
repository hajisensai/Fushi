import 'dart:async';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/srt_book_reimport_dialog.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 假 file_picker：选择器一直开着，直到测试把 [result] 完成（模拟用户还没选完 /
/// 取文件还没回来）。
class _PendingFilePicker extends FilePicker {
  final Completer<FilePickerResult?> result = Completer<FilePickerResult?>();

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) => result.future;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
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
      find.text(
        MaterialLocalizations.of(
          tester.element(find.byType(Dialog)),
        ).okButtonLabel,
      ),
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

  testWidgets('SRT book reimport dialog offers server subtitles only for '
      'Audiobookshelf-bound books', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    SrtBook bookFor(String uid) => SrtBook()
      ..uid = uid
      ..title = 'Book'
      ..srtPath = ''
      ..bookKey = '';
    await tester.runAsync(
      () => RemoteAudioBindingRepository(db).save(
        const RemoteAudioBinding(
          srtBookUid: 'srtbook_remote',
          provider: RemoteAudioBinding.providerAudiobookshelf,
          serverConfigId: 'srv',
          itemId: 'item_1',
          tracks: <RemoteAudioTrack>[
            RemoteAudioTrack(ino: '1', startOffsetMs: 0, durationMs: 1000),
          ],
          createdAt: 1,
          updatedAt: 1,
        ),
      ),
    );

    Future<void> open(String uid) async {
      await tester.pumpWidget(
        buildApp(
          ProviderScope(
            child: SrtBookReimportDialog(
              key: ValueKey<String>(uid),
              book: bookFor(uid),
              db: db,
              repo: SrtBookRepository(db),
            ),
          ),
        ),
      );
      // 绑定是 initState 里异步读出来的：等那次查询本身完成，再重建一帧。
      final SrtBookReimportDialogState state = tester
          .state<SrtBookReimportDialogState>(
            find.byType(SrtBookReimportDialog),
          );
      await tester.runAsync(() => state.serverBindingLoaded);
      await tester.pump();
    }

    await open('srtbook_remote');
    expect(
      find.byTooltip(t.srt_book_reimport_subtitle_from_server),
      findsOneWidget,
    );

    await open('srtbook_local');
    expect(
      find.byTooltip(t.srt_book_reimport_subtitle_from_server),
      findsNothing,
    );
  });

  testWidgets('SRT book reimport: import and cancel stay disabled while a '
      'subtitle pick is still in flight', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // 测试环境里 FilePicker.platform 没有默认实现（读它会 LateInitializationError），
    // 直接换成假的（与 picker_extension_filter_test 同做法）。
    final _PendingFilePicker picker = _PendingFilePicker();
    FilePicker.platform = picker;

    await tester.pumpWidget(
      buildApp(
        ProviderScope(
          child: SrtBookReimportDialog(
            book: SrtBook()
              ..uid = 'srtbook_pick'
              ..title = 'Book'
              ..srtPath = ''
              ..bookKey = '',
            db: db,
            repo: SrtBookRepository(db),
          ),
        ),
      ),
    );
    final SrtBookReimportDialogState state = tester
        .state<SrtBookReimportDialogState>(find.byType(SrtBookReimportDialog));
    await tester.runAsync(() => state.serverBindingLoaded);
    await tester.pump();

    // 导入是 filled 主操作，取消是 text 按钮（M3E 对话框动作）。
    VoidCallback? onPressedOf(String label) {
      final Widget button = tester.widget(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (Widget w) => w is FushiFilledButton || w is FushiTextButton,
          ),
        ),
      );
      return switch (button) {
        FushiFilledButton(:final VoidCallback? onPressed) => onPressed,
        FushiTextButton(:final VoidCallback? onPressed) => onPressed,
        _ => throw StateError('unexpected button $button'),
      };
    }

    expect(onPressedOf(t.dialog_import), isNotNull);
    await tester.tap(find.byTooltip(t.srt_import_pick_subtitle_files));
    await tester.pump();
    // 选择 / 取文件还没完：导入此时开跑，会拿着旧输入、又在选完时被改写。
    expect(onPressedOf(t.dialog_import), isNull);
    expect(onPressedOf(t.dialog_cancel), isNull);

    picker.result.complete(
      FilePickerResult(<PlatformFile>[
        PlatformFile(name: 'next.srt', size: 0, path: '/books/next.srt'),
      ]),
    );
    await tester.pump();
    await tester.pump();
    expect(onPressedOf(t.dialog_import), isNotNull);
    expect(find.text('next.srt'), findsOneWidget);
  });
}
