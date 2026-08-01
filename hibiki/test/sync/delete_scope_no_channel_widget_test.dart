/// TODO-2470 死角② 的 UI 侧守卫：本机没有删除传播通道时，两个删除确认框都不得再摆出
/// 那个兑现不了的「从所有设备删除」勾选框，且确认结果必须恒为 keepLocalOnly。
///
/// 两个框各测一遍是有意的：它们是**两份独立实现**（通用 `showDeleteScopeConfirm` 的
/// `_DeleteScopeConfirmDialog` 与书架专用 `ReaderHistoryDeleteDialog`），只修一个、
/// 另一个继续撒谎，正是这类死角最容易复发的方式。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki/src/sync/deletion_disclosure.dart';
import 'package:hibiki/src/sync/deletion_prompt.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart';

import '../pages/reader_history_source_corpus.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget app(Widget home) =>
      TranslationProvider(child: MaterialApp(home: home));

  group('ReaderHistoryDeleteDialog', () {
    testWidgets('有通道 → 渲染勾选框，不渲染无通道说明', (WidgetTester tester) async {
      await tester.pumpWidget(app(ReaderHistoryDeleteDialog(
        title: t.epub_delete_title,
        message: 'msg',
        onConfirm: (_) {},
      )));

      expect(find.text(t.delete_scope_sync_everywhere), findsOneWidget);
      expect(find.byType(DeleteScopeUnavailableNote), findsNothing);
    });

    testWidgets('无通道 → 勾选框消失，换成说明行', (WidgetTester tester) async {
      await tester.pumpWidget(app(ReaderHistoryDeleteDialog(
        title: t.epub_delete_title,
        message: 'msg',
        showSyncScope: false,
        onConfirm: (_) {},
      )));

      expect(find.text(t.delete_scope_sync_everywhere), findsNothing,
          reason: '没有任何同步通道时，这个选项勾了也不可能生效，不该出现');
      expect(find.byType(DeleteScopeUnavailableNote), findsOneWidget);
      expect(find.text(t.delete_scope_no_channel), findsOneWidget);
    });

    testWidgets('无通道时确认 → 恒 keepLocalOnly', (WidgetTester tester) async {
      DeleteScope? got;
      await tester.pumpWidget(app(ReaderHistoryDeleteDialog(
        title: t.epub_delete_title,
        message: 'msg',
        showSyncScope: false,
        onConfirm: (DeleteScope s) => got = s,
      )));

      await tester.tap(find.text(t.dialog_delete));
      await tester.pump();

      expect(got, DeleteScope.keepLocalOnly);
    });
  });

  /// 源码守卫：每一个会摆出「从所有设备删除」勾选框的入口，都必须先问过通道判据。
  ///
  /// 这条守卫是**被真实疏漏催生的**：初版修复只接了 `_confirmMediaDelete` 与三个
  /// `showDeleteScopeConfirm` 调用点，漏掉了书架批删 `_batchDeleteConfirm` 里第二个
  /// `ReaderHistoryDeleteDialog` 构造点——它继续无条件显示那个兑现不了的勾选框。
  /// 死角②的复发方式就是「又冒出一个没接线的入口」，所以按入口数量而非行为来钉。
  group('入口覆盖源码守卫（TODO-2470 死角②）', () {
    test('每个 ReaderHistoryDeleteDialog 构造点都显式传 showSyncScope', () {
      final String source = readReaderHistorySource();
      // 语料含 dialogs.part.dart 里的类声明本身（`const ReaderHistoryDeleteDialog({`），
      // 它不是调用点，要从计数里剔掉。
      final int ctorCount =
          'ReaderHistoryDeleteDialog('.allMatches(source).length -
              'const ReaderHistoryDeleteDialog('.allMatches(source).length;
      final int gatedCount = 'showSyncScope:'.allMatches(source).length;

      expect(ctorCount, greaterThan(0), reason: '书架页必须存在删除确认框构造点');
      expect(
        gatedCount,
        ctorCount,
        reason: '有 $ctorCount 个构造点但只有 $gatedCount 处传了 showSyncScope——'
            '漏接的那个入口会在没有任何同步通道时继续显示「从所有设备删除」，'
            '正是 TODO-2470 死角②的复发形态',
      );
    });

    test('每个 showDeleteScopeConfirm 调用点都显式传 db', () {
      final String source = readReaderHistorySource();
      // 书架页自身不用通用弹窗；断言写成「有调用就必须带 db」，防止将来
      // 有人在此页新引入一个不查判据的调用点。
      final int calls = 'showDeleteScopeConfirm('.allMatches(source).length;
      if (calls == 0) return;
      expect('db:'.allMatches(source).length, greaterThanOrEqualTo(calls),
          reason: '通用删除弹窗必须传 db，否则它无从得知本机有没有传播通道');
    });
  });

  group('通用 showDeleteScopeConfirm 弹窗', () {
    /// 不传 db → 判据不查、恒显示（既有调用点与老测试的兼容行为）。
    testWidgets('不传 db → 渲染勾选框', (WidgetTester tester) async {
      await tester.pumpWidget(app(Builder(
        builder: (BuildContext ctx) => TextButton(
          onPressed: () => showDeleteScopeConfirm(ctx,
              title: t.dialog_delete, message: 'msg'),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(t.delete_scope_sync_everywhere), findsOneWidget);
      expect(find.byType(DeleteScopeUnavailableNote), findsNothing);
    });

    /// 端到端：传一个零配置的真 DB，弹窗自己经 `hasDeletionPropagationChannel` 查出
    /// 「本机没有任何同步通道」并据此收起勾选框——这条覆盖的是用户真实遭遇的路径
    /// （全新装、从没配过同步，删书时勾了「从所有设备删除」）。
    testWidgets('传零配置的 db → 自动收起勾选框', (WidgetTester tester) async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(app(Builder(
        builder: (BuildContext ctx) => TextButton(
          onPressed: () => showDeleteScopeConfirm(ctx,
              title: t.dialog_delete, message: 'msg', db: db),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(t.delete_scope_sync_everywhere), findsNothing);
      expect(find.text(t.delete_scope_no_channel), findsOneWidget);
    });
  });
}
