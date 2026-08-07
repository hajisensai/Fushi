import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/utils/components/hibiki_destructive_confirm_dialog.dart';
import 'package:path/path.dart' as p;

/// BUG-1305：删除确认文案与真实删除范围对不上。
///
/// 三层守卫，各锁一段契约：
///   1) widget —— 披露真的渲染出来；勾选框翻转时正文跟着变（合集那处说反话的
///      结构性根因就是正文不跟随勾选）。
///   2) 源码扫描 —— 会递归删磁盘目录的那几个删除入口，必须挂结构化披露。
///   3) i18n —— 合集确认正文不得再是视频专属句（书库/游戏库也弹同一个框）；
///      有声书移除措辞必须已改成删除。
/// 另加一条行为锚：披露里写的会删解压目录不是空话，deleteBookDir 真递归删。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget wrap(Widget child) =>
      TranslationProvider(child: MaterialApp(home: Scaffold(body: child)));

  String readSource(String relative) {
    final File file = File(relative);
    expect(file.existsSync(), isTrue, reason: 'missing source: $relative');
    return file.readAsStringSync();
  }

  group('BUG-1305 layer1 disclosure rendering', () {
    testWidgets('shelf book disclosure lists both delete and keep sets',
        (WidgetTester tester) async {
      final DeletionDisclosure disclosure = buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      );

      await tester.pumpWidget(
        wrap(DeletionDisclosureView(disclosure: disclosure)),
      );

      expect(find.textContaining(t.delete_disclosure_book_records),
          findsOneWidget);
      expect(find.textContaining(t.delete_disclosure_book_extracted),
          findsOneWidget);
      expect(find.textContaining(t.delete_disclosure_book_audiobook),
          findsOneWidget);
      expect(
          find.textContaining(t.delete_disclosure_source_kept), findsOneWidget);
      expect(find.text(t.delete_disclosure_will_delete_label), findsOneWidget);
      expect(find.text(t.delete_disclosure_will_keep_label), findsOneWidget);
    });

    testWidgets('audiobook disclosure never claims the extracted dir goes away',
        (WidgetTester tester) async {
      final DeletionDisclosure disclosure = buildDeletionDisclosure(
        target: DeletionDisclosureTarget.attachedAudiobook,
      );
      await tester.pumpWidget(
        wrap(DeletionDisclosureView(disclosure: disclosure)),
      );

      expect(find.textContaining(t.delete_disclosure_audiobook_files),
          findsOneWidget);
      expect(find.textContaining(t.delete_disclosure_audiobook_book_kept),
          findsOneWidget);
      expect(find.textContaining(t.delete_disclosure_book_extracted),
          findsNothing);
    });

    testWidgets('collection body follows the also-delete-members checkbox',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          FushiDestructiveConfirmDialog(
            title: t.delete_collection,
            message: t.delete_collection_confirm,
            checkboxLabel: t.delete_collection_also_books,
            checkedDisclosure: buildDeletionDisclosure(
              target: DeletionDisclosureTarget.shelfBook,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining(t.delete_disclosure_book_extracted),
          findsNothing);

      await tester.tap(find.text(t.delete_collection_also_books));
      await tester.pumpAndSettle();

      expect(find.textContaining(t.delete_disclosure_book_extracted),
          findsOneWidget);
      expect(find.textContaining(t.delete_disclosure_book_audiobook),
          findsOneWidget);
    });
  });

  group('BUG-1305 layer2 every destructive entry must carry a disclosure', () {
    test('shelf single/batch delete and collection member delete are wired',
        () {
      final String books = readSource(
          'lib/src/pages/implementations/reader_history/books.part.dart');
      expect(
        'buildDeletionDisclosure'.allMatches(books).length,
        3,
        reason: 'shelf has 3 delete confirm entries (single SRT, single EPUB, '
            'batch); each must build a structured disclosure',
      );

      final String historyPage = readSource(
          'lib/src/pages/implementations/reader_hibiki_history_page.dart');
      expect(
        historyPage
            .contains('deleteMembersDisclosure: buildDeletionDisclosure'),
        isTrue,
        reason: 'book collection member delete recursively removes the extract '
            'dir and the audiobook dir, so it must disclose',
      );

      final String gridDetail = readSource(
          'lib/src/pages/implementations/media_collection_grid_detail_page.dart');
      expect(
        gridDetail.contains('checkedDisclosure: canDeleteMembers'),
        isTrue,
        reason: 'collection detail page deletes the same dirs, must disclose',
      );

      final String audiobook =
          readSource('lib/src/media/audiobook/audiobook_import_dialog.dart');
      expect(
        audiobook.contains('DeletionDisclosureTarget.attachedAudiobook'),
        isTrue,
        reason: 'deleting an attached audiobook wipes the whole persist dir',
      );
    });

    test('checked-state disclosure is gated on the checkbox state', () {
      final String dialog = readSource(
          'lib/src/utils/components/hibiki_destructive_confirm_dialog.dart');
      expect(
        dialog.contains('if (_checked && widget.checkedDisclosure != null)'),
        isTrue,
        reason: 'the body must repaint with the checkbox, otherwise the body '
            'and the checkbox contradict each other again',
      );
    });
  });

  group('BUG-1305 layer3 the copy itself must not contradict behaviour', () {
    test('collection confirm body is domain-neutral in all 17 locales', () {
      final Directory dir = Directory('lib/i18n');
      final List<File> files = dir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.i18n.json'))
          .toList();
      expect(files.length, 17, reason: 'Slang requires all 17 locale files');

      for (final File f in files) {
        final Map<String, dynamic> json =
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final String? message = json['delete_collection_confirm'] as String?;
        expect(message, isNotNull,
            reason: 'missing delete_collection_confirm in ${f.path}');
        expect(
          message!.toLowerCase().contains('video') ||
              message.contains('\u89c6\u9891'),
          isFalse,
          reason: 'the collection delete body is shared by the book, video and '
              'game libraries, so it must not be video-specific: ${f.path}',
        );
      }
    });

    test('audiobook wording moved from remove to delete', () {
      final Map<String, dynamic> en =
          jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(en.containsKey('audiobook_delete'), isTrue);
      expect(en.containsKey('audiobook_delete_confirm'), isTrue);
      expect(en.containsKey('audiobook_remove'), isFalse);
      expect(en.containsKey('audiobook_remove_confirm'), isFalse);
      expect(
        (en['audiobook_delete_confirm'] as String).toLowerCase(),
        contains('delete'),
      );
    });
  });

  group('BUG-1305 behaviour anchor', () {
    test('deleteBookDir wipes the extract tree and spares files outside it',
        () async {
      final Directory root =
          Directory.systemTemp.createTempSync('hibiki_disclosure_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final Directory extractDir =
          Directory(p.join(root.path, 'fushi_books', 'bookA'))
            ..createSync(recursive: true);
      final File nested = File(p.join(extractDir.path, 'OEBPS', 'ch1.xhtml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('chapter');

      final File userOriginal = File(p.join(root.path, 'MyBook.epub'))
        ..writeAsStringSync('original');

      await EpubStorage.deleteBookDir(extractDir.path);

      expect(extractDir.existsSync(), isFalse);
      expect(nested.existsSync(), isFalse);
      expect(userOriginal.existsSync(), isTrue,
          reason: 'the disclosure promises the original import is kept');
    });
  });
}
