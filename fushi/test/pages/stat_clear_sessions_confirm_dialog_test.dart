import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:fushi/utils.dart';

/// 「清除全部会话记录」的防呆确认（用户 2026-09-10：「再加个清除所有会话记录并且
/// 防呆」）。这颗按钮长在会话区块的标题行上、四个 tab 都有，一个纯确认框在这种位置
/// 等同于「点两下删光半年数据」——所以破坏性按钮**默认禁用**，必须先勾上复述条数的
/// 确认项才可点。另外 `count <= 0` 时连框都不弹（没有东西可清，弹框只是噪音）。
///
/// 实现是共享件 [FushiDestructiveConfirmDialog] + `requireCheckboxToConfirm`（勾选行
/// 是 `FushiListItem`，Checkbox 被 ExcludeFocus + IgnorePointer 包住，**整行 onTap**
/// 才是唯一停靠点）；防呆闸本身的契约在 test/widgets/fushi_destructive_confirm_dialog_test.dart。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Finder confirmButton() =>
      find.widgetWithText(FilledButton, t.stat_clear_all_confirm);

  bool ackChecked(WidgetTester tester) => tester
      .widget<Checkbox>(
        find.descendant(
          of: find.byKey(StatClearSessionsConfirmDialog.ackKey),
          matching: find.byType(Checkbox),
        ),
      )
      .value!;

  Future<void> tapAck(WidgetTester tester) async {
    await tester.tap(find.byKey(StatClearSessionsConfirmDialog.ackKey));
    await tester.pumpAndSettle();
  }

  /// 挂一个按钮，点它调 [confirmClearAllStatSessions]，结果写进 [sink]。
  Widget hostButton(int count, void Function(bool) sink) => TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async =>
                    sink(await confirmClearAllStatSessions(context, count)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  testWidgets('默认破坏性按钮禁用，勾上确认项后才可点（闸门双向）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(body: StatClearSessionsConfirmDialog(count: 37)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(t.stat_sessions_clear_all_title), findsOneWidget);
    expect(
      find.text(t.stat_sessions_clear_all_message(n: 37)),
      findsOneWidget,
      reason: '正文必须复述条数，用户至少得读到那个数字',
    );
    expect(find.text(t.stat_sessions_clear_all_ack(n: 37)), findsOneWidget);
    expect(ackChecked(tester), isFalse);
    expect(
      tester.widget<FilledButton>(confirmButton()).onPressed,
      isNull,
      reason: '防呆：没勾确认项之前一律禁用',
    );

    await tapAck(tester);
    expect(ackChecked(tester), isTrue, reason: '整行 onTap 驱动勾选');
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNotNull);

    // 再点一次取消勾选：闸门是双向的，不是一次性开关。
    await tapAck(tester);
    expect(ackChecked(tester), isFalse);
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull);
  });

  testWidgets('勾上 ack 后点清除 → true', (WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(hostButton(12, (bool r) => result = r));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(t.stat_sessions_clear_all_title), findsOneWidget);

    await tapAck(tester);
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.text(t.stat_sessions_clear_all_title), findsNothing);
  });

  testWidgets('取消 → false（勾了确认项也一样）', (WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(hostButton(12, (bool r) => result = r));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tapAck(tester);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(result, isFalse, reason: '取消 pop null，包装函数必须判成 false');
    expect(find.text(t.stat_sessions_clear_all_title), findsNothing);
  });

  testWidgets('count <= 0：不弹窗，直接 false', (WidgetTester tester) async {
    for (final int count in <int>[0, -1]) {
      bool? result;
      await tester.pumpWidget(hostButton(count, (bool r) => result = r));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text(t.stat_sessions_clear_all_title),
        findsNothing,
        reason: 'count=$count 没有东西可清，弹框只是噪音',
      );
      expect(result, isFalse, reason: 'count=$count');
    }
  });
}
