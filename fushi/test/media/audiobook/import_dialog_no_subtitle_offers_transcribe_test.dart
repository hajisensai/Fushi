import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2266：选了音频没字幕 / 对齐文件就点「导入」，本机能转录时必须弹「字幕来源」
/// （选文件 / 转录），而不是一句提示把用户堵死——转录入口只是行尾一枚无字图标，
/// 用户是「下载了语音模型 → 选 EPUB + 音频 → 点导入」一路走来的。
///
/// 两个对话框（导入书 / 给现有 EPUB 附加有声书）同一条纪律。`isAsrSupported` 是
/// 平台闸门，测试宿主（Windows / Linux / macOS）恒真；不能转录的平台仍走原提示。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('导入书：EPUB + 音频、无字幕，点导入弹出字幕来源而不是提示', (WidgetTester tester) async {
    expect(isAsrSupported, isTrue, reason: '测试宿主平台必须在 ASR 闸门内');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      buildApp(
        BookImportDialog(
          repo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          db: db,
          initialEpubPath: r'C:\b\My Novel.epub',
          initialAudioPaths: const <String>[r'C:\b\My Novel.m4b'],
          imageArchiveProbe: (String _) => false,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.dialog_import));
    await tester.pumpAndSettle();

    expect(find.text(t.audiobook_subtitle_source_title), findsOneWidget);
    expect(find.text(t.audiobook_transcribe_action), findsOneWidget);
    // 不断言「没弹旧提示」：`FushiToast` 要有全局 navigatorKey 才画得出 overlay，
    // widget 测试里没设，toast 从来进不了树——那种 `findsNothing` 恒真、守不住
    // 任何东西。旧行为已被上面「来源选择真的出现了」正面钉住。
    // 用户关掉来源选择 = 取消：什么都不导入。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  testWidgets('附加有声书：音频、无对齐文件，点导入弹出字幕来源而不是「导入失败」', (WidgetTester tester) async {
    expect(isAsrSupported, isTrue, reason: '测试宿主平台必须在 ASR 闸门内');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final AudiobookRepository repo = AudiobookRepository(db);

    await tester.pumpWidget(
      buildApp(
        AudiobookImportDialog(
          bookKey: 'bug-2266-book',
          repo: repo,
          initialAudioPaths: const <String>[r'C:\b\My Novel.m4b'],
        ),
      ),
    );
    // `_initExisting` 是一次 DB 往返：显式 pump 排空，等导入表单出现。
    for (int i = 0;
        i < 20 && find.text(t.dialog_import).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(t.dialog_import), findsOneWidget);

    await tester.tap(find.text(t.dialog_import));
    await tester.pumpAndSettle();

    expect(find.text(t.audiobook_subtitle_source_title), findsOneWidget);
    expect(find.text(t.audiobook_transcribe_action), findsOneWidget);
    // 同上：toast 进不了 widget 树，不写恒真的 findsNothing。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(await repo.findByBookKey('bug-2266-book'), isNull);
  });
}
