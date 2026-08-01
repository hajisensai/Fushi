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
