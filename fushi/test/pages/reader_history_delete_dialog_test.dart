import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(child: MaterialApp(home: home));
  }

  testWidgets('reader history delete dialog fits a compact desktop window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        ReaderHistoryDeleteDialog(
          title: t.epub_delete_title,
          message: t.srt_delete_confirm(
            title:
                'Very long EPUB title used to test compact Windows delete confirmation layout',
          ),
          onConfirm: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.dialog_delete), findsOneWidget);
  });

  group('「同时删除统计数据」（书架 / 漫画删除，与视频同一选项）', () {
    testWidgets('没给 statisticsSubtitle → 不摆该行，deleteStatistics 恒 false', (
      WidgetTester tester,
    ) async {
      DeleteDecision? got;
      await tester.pumpWidget(
        buildApp(
          ReaderHistoryDeleteDialog(
            title: t.epub_delete_title,
            message: 'm',
            onConfirm: (DeleteDecision d) => got = d,
          ),
        ),
      );
      expect(find.text(t.delete_statistics), findsNothing);
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.deleteStatistics, isFalse);
    });

    testWidgets('默认不勾；勾上后确认 deleteStatistics=true，披露随之翻面', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.reset);
      DeleteDecision? got;
      await tester.pumpWidget(
        buildApp(
          ReaderHistoryDeleteDialog(
            title: t.epub_delete_title,
            message: 'm',
            showSyncScope: false,
            statisticsSubtitle: t.delete_statistics_book_desc,
            disclosure: buildDeletionDisclosure(
              target: DeletionDisclosureTarget.shelfBook,
            ),
            onConfirm: (DeleteDecision d) => got = d,
          ),
        ),
      );
      expect(find.text(t.delete_statistics), findsOneWidget);
      expect(find.text(t.delete_statistics_book_desc), findsOneWidget);
      DeletionDisclosure shown() => tester
          .widget<DeletionDisclosureView>(find.byType(DeletionDisclosureView))
          .disclosure;
      expect(shown().willKeep, contains(t.delete_disclosure_stats_kept));
      expect(
        shown().willDelete,
        isNot(contains(t.delete_disclosure_stats_kept)),
      );

      await tester.tap(find.text(t.delete_statistics));
      await tester.pumpAndSettle();
      expect(shown().willDelete, contains(t.delete_disclosure_stats_kept));
      expect(shown().willKeep, isNot(contains(t.delete_disclosure_stats_kept)));

      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.deleteStatistics, isTrue);
      expect(got!.deleteLocalFiles, isFalse, reason: '与删本地文件正交');
    });
  });

  group('「保留已下载章节」（在线漫画删除，BUG-4702）', () {
    Widget dialog(
      void Function(DeleteDecision) onConfirm, {
      bool keep = true,
    }) => buildApp(
      ReaderHistoryDeleteDialog(
        title: t.epub_delete_title,
        message: 'm',
        showSyncScope: false,
        keepDownloadsSubtitle: keep ? t.delete_keep_downloads_desc : null,
        disclosure: buildDeletionDisclosure(
          target: DeletionDisclosureTarget.shelfBook,
        ),
        onConfirm: onConfirm,
      ),
    );

    DeletionDisclosure shown(WidgetTester tester) => tester
        .widget<DeletionDisclosureView>(find.byType(DeletionDisclosureView))
        .disclosure;

    testWidgets('默认勾上：确认 keepDownloadedFiles=true，披露把章节挪到「保留」', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.reset);
      DeleteDecision? got;
      await tester.pumpWidget(dialog((DeleteDecision d) => got = d));
      expect(find.text(t.delete_keep_downloads_title), findsOneWidget);
      expect(
        shown(tester).willKeep,
        contains(t.delete_disclosure_manga_downloads_kept),
      );
      expect(
        shown(tester).willDelete,
        isNot(contains(t.delete_disclosure_book_extracted)),
      );
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.keepDownloadedFiles, isTrue);
    });

    testWidgets('取消勾选：keepDownloadedFiles=false，披露回到「会删除」', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.reset);
      DeleteDecision? got;
      await tester.pumpWidget(dialog((DeleteDecision d) => got = d));
      await tester.tap(
        find.byKey(const ValueKey<String>('delete-keep-downloads')),
      );
      await tester.pumpAndSettle();
      expect(
        shown(tester).willKeep,
        isNot(contains(t.delete_disclosure_manga_downloads_kept)),
      );
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.keepDownloadedFiles, isFalse);
    });

    testWidgets('非在线漫画（没给副标题）不摆该行，恒 false', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.reset);
      DeleteDecision? got;
      await tester.pumpWidget(
        dialog((DeleteDecision d) => got = d, keep: false),
      );
      expect(find.text(t.delete_keep_downloads_title), findsNothing);
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.keepDownloadedFiles, isFalse);
    });
  });
}
