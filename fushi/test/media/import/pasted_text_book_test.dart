import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/pasted_text_book.dart';
import 'package:fushi/src/media/import/pasted_text_book_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';

// 反馈 f2k9m1oU0j：粘贴剪贴板文本直接阅读。文本经 TextToEpub.convertText →
// EpubImporter.import 落成书库里的一本普通书（阅读器原生点词查词），对话框打开
// 时用剪贴板预填正文。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('pastedTextBookTitle', () {
    test('取第一行非空行，折叠空白（含全角空格）与 BOM', () {
      expect(
        pastedTextBookTitle('﻿\n  \r\n  吾輩は　 猫である。 \n名前はまだ無い。'),
        '吾輩は 猫である。',
      );
    });

    test('超长按码点截断并补省略号，不切开代理对', () {
      final String long = '𠮷' * 50;
      final String? title = pastedTextBookTitle(long, maxChars: 10);
      expect(title, '${'𠮷' * 10}…');
      expect(title!.runes.length, 11);
    });

    test('全空白没有标题，也不算有内容', () {
      expect(pastedTextBookTitle(' \n\t　\n'), isNull);
      expect(pastedTextHasContent(' \n\t'), isFalse);
      expect(pastedTextHasContent('あ'), isTrue);
    });
  });

  group('importPastedTextBook', () {
    late Directory root;
    late FushiDatabase db;

    setUp(() {
      root = Directory.systemTemp.createTempSync('pasted_text_book_');
      EpubStorage.debugBaseDirectoryOverride = root.path;
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      EpubStorage.debugBaseDirectoryOverride = null;
      root.deleteSync(recursive: true);
    });

    testWidgets('落成书库里的一本书，书名取自参数；同名自动加后缀而非跳过', (WidgetTester tester) async {
      late String first;
      late String second;
      await tester.runAsync(() async {
        first = await importPastedTextBook(
          db: db,
          text: '一段目。\n\n二段目。',
          title: '貼り付け/テスト',
        );
        second = await importPastedTextBook(
          db: db,
          text: '別の本文。',
          title: '貼り付け/テスト',
        );
      });
      final EpubBookRow? a = await db.getEpubBook(first);
      final EpubBookRow? b = await db.getEpubBook(second);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!.title, '貼り付け/テスト');
      expect(b!.title, isNot(a.title), reason: '同名粘贴文本是两本独立的书');
      expect(first, isNot(second));
    });
  });

  group('PastedTextBookDialog', () {
    Future<void> pumpDialog(
      WidgetTester tester, {
      required PastedTextClipboardReader readClipboard,
    }) async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              splashFactory: NoSplash.splashFactory,
            ),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => TextButton(
                  onPressed: () => showDialog<String>(
                    context: context,
                    builder: (BuildContext _) => PastedTextBookDialog(
                      db: db,
                      readClipboard: readClipboard,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('打开时用剪贴板文本预填正文，标题提示取第一行', (WidgetTester tester) async {
      await pumpDialog(tester, readClipboard: () async => '今日は晴れ。\n明日は雨。');
      expect(find.text('今日は晴れ。\n明日は雨。'), findsOneWidget);
      expect(find.text('今日は晴れ。'), findsOneWidget, reason: '标题框提示 = 实际书名');
      expect(tester.takeException(), isNull);
    });

    testWidgets('剪贴板读回前用户已输入的正文不被覆盖', (WidgetTester tester) async {
      final Completer<String?> clipboard = Completer<String?>();
      await pumpDialog(tester, readClipboard: () => clipboard.future);
      final Finder body = find.byWidgetPredicate(
        (Widget w) => w is EditableText && w.maxLines == 12,
      );
      expect(body, findsOneWidget);
      await tester.enterText(body, '自分で入力');
      clipboard.complete('剪贴板内容');
      await tester.pumpAndSettle();
      // 标题框的提示取正文第一行，所以「自分で入力」也会出现在提示里；断言正文框本身。
      expect(tester.widget<EditableText>(body).controller.text, '自分で入力');
      expect(find.text('剪贴板内容'), findsNothing);
    });

    testWidgets('剪贴板没有文本时正文为空，标题提示用兜底名', (WidgetTester tester) async {
      await pumpDialog(tester, readClipboard: () async => null);
      expect(find.text(t.book_paste_text_default_title), findsOneWidget);
      // 空正文点「阅读」不落库也不关窗。
      await tester.tap(find.text(t.book_paste_text_read));
      await tester.pumpAndSettle();
      expect(find.byType(PastedTextBookDialog), findsOneWidget);
    });
  });
}
