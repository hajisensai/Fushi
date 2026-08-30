/// 删除确认框「同时删除本地文件」勾选框：两个弹窗（通用 showDeleteScopeConfirm /
/// 书架 ReaderHistoryDeleteDialog）只在给了 localFilesSubtitle 时渲染、默认不勾、
/// 勾了才把 DeleteDecision.deleteLocalFiles 置真；勾选后披露把「原始音频」挪进删除
/// 区，而「会保留」那条同时收窄成「书籍与字幕原件」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/sync/deletion_prompt.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget app(Widget home) =>
      TranslationProvider(child: MaterialApp(home: home));

  group('showDeleteScopeConfirm', () {
    testWidgets('没给 localFilesSubtitle → 不渲染勾选框，决定恒不删文件', (
      WidgetTester tester,
    ) async {
      DeleteDecision? got;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (BuildContext ctx) => TextButton(
              onPressed: () async {
                got = await showDeleteScopeConfirm(
                  ctx,
                  title: t.video_delete_title,
                  message: 'msg',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(t.delete_local_files), findsNothing);
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got, const DeleteDecision(scope: DeleteScope.keepLocalOnly));
    });

    testWidgets('给了副标题 → 默认不勾；勾了才 deleteLocalFiles=true', (
      WidgetTester tester,
    ) async {
      DeleteDecision? got;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (BuildContext ctx) => TextButton(
              onPressed: () async {
                got = await showDeleteScopeConfirm(
                  ctx,
                  title: t.video_delete_title,
                  message: 'msg',
                  localFilesSubtitle: t.delete_local_files_video_desc,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(t.delete_local_files), findsOneWidget);
      expect(
        find.text(t.delete_local_files_video_desc),
        findsOneWidget,
        reason: '视频入口用带「下载任务一并清除」的说明',
      );

      // 不勾直接删 → false。
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.deleteLocalFiles, isFalse);

      // 勾了再删 → true。
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await tester.pumpAndSettle();
      expect(got!.deleteLocalFiles, isTrue);
      expect(
        got!.scope,
        DeleteScope.keepLocalOnly,
        reason: '两个勾选框正交：删文件不代表同步删除',
      );
    });
  });

  group('ReaderHistoryDeleteDialog', () {
    testWidgets('勾选后披露只承诺删音频，书与字幕原件仍在「会保留」里', (
      WidgetTester tester,
    ) async {
      // 披露 + 两个勾选行比默认 800×600 视口高，按钮会被挤到屏幕外；这条测的是
      // 披露语义，不是紧凑布局（那由 reader_history_delete_dialog_test 守）。
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1400);
      addTearDown(tester.view.reset);
      DeleteDecision? got;
      await tester.pumpWidget(
        app(
          ReaderHistoryDeleteDialog(
            title: t.epub_delete_title,
            message: 'msg',
            localFilesSubtitle: t.delete_local_files_audio_desc,
            disclosure: buildDeletionDisclosure(
              target: DeletionDisclosureTarget.shelfBook,
            ),
            onConfirm: (DeleteDecision d) => got = d,
          ),
        ),
      );

      DeletionDisclosure shown() => tester
          .widget<DeletionDisclosureView>(find.byType(DeletionDisclosureView))
          .disclosure;
      expect(shown().willKeep, contains(t.delete_disclosure_source_kept));
      expect(
        shown().willDelete,
        isNot(contains(t.delete_disclosure_source_kept)),
      );

      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      expect(
        shown().willDelete,
        contains(t.delete_disclosure_audio_source_files),
        reason: '勾选后加进「会被删除」的必须是只讲音频的那条',
      );
      expect(
        shown().willDelete,
        isNot(contains(t.delete_disclosure_source_kept)),
        reason: 'EPUB/PDF/字幕原件路径根本没入库，绝不能在破坏性确认框里承诺删它们',
      );
      expect(
        shown().willKeep,
        contains(t.delete_disclosure_book_source_kept),
        reason: '「会保留」那条要收窄成「书籍与字幕原件」，而不是整条消失',
      );
      expect(
        shown().willKeep,
        isNot(contains(t.delete_disclosure_source_kept)),
      );

      await tester.tap(find.text(t.dialog_delete));
      await tester.pump();
      expect(got!.deleteLocalFiles, isTrue);
    });

    testWidgets('没给 localFilesSubtitle → 无勾选框', (WidgetTester tester) async {
      await tester.pumpWidget(
        app(
          ReaderHistoryDeleteDialog(
            title: t.epub_delete_title,
            message: 'msg',
            onConfirm: (_) {},
          ),
        ),
      );
      expect(find.text(t.delete_local_files), findsNothing);
    });
  });

  group('DeletionDisclosure.withLocalFilesDeleted', () {
    test('有声书目标：原件条目从保留挪到删除（同一句措辞，本来就只讲音频）', () {
      final DeletionDisclosure audiobook = buildDeletionDisclosure(
        target: DeletionDisclosureTarget.attachedAudiobook,
      );
      final DeletionDisclosure moved = audiobook.withLocalFilesDeleted();
      expect(moved.willDelete, contains(t.delete_disclosure_audio_source_files));
      expect(moved.willKeep, <String>[t.delete_disclosure_audiobook_book_kept]);
    });

    test('结果保留 localFiles 字段（早先版本在这里静默丢掉它）', () {
      final DeletionDisclosure moved = buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ).withLocalFilesDeleted();
      expect(moved.localFiles, isNotNull);
    });

    test('幂等：反复应用不会把删除条目叠加两次', () {
      final DeletionDisclosure once = buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ).withLocalFilesDeleted();
      final DeletionDisclosure twice = once.withLocalFilesDeleted();
      expect(twice.willDelete, once.willDelete);
      expect(twice.willKeep, once.willKeep);
    });

    test('没有可删原件的披露原样返回', () {
      const DeletionDisclosure plain = DeletionDisclosure(
        willDelete: <String>['a'],
        willKeep: <String>['b'],
      );
      expect(identical(plain.withLocalFilesDeleted(), plain), isTrue);
    });
  });
}
