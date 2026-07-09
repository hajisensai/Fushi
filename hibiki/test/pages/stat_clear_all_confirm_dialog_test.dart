import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_delete_confirm_dialog.dart';
import 'package:hibiki/utils.dart';

/// TODO-1322: 「清空全部统计」危险操作确认弹窗——必须先弹确认框，只有用户点破坏性
/// 「清空」按钮才返回 true（点「取消」/ 关窗返回 false），防误触把统计一键清光。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  const String marker = 'CLEAR_ALL_BODY_MARKER';

  /// 挂一个按钮，点它调 [confirmClearAllStatistics]，把结果写进 [sink]。
  Widget hostButton(void Function(bool) sink) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => ElevatedButton(
              onPressed: () async {
                final bool result =
                    await confirmClearAllStatistics(context, marker);
                sink(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the destructive title + passed message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(body: StatClearAllConfirmDialog(message: marker)),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(t.stat_clear_all_title), findsOneWidget);
    expect(find.text(marker), findsOneWidget);
    expect(find.text(t.stat_clear_all_confirm), findsOneWidget);
    expect(find.text(t.dialog_cancel), findsOneWidget);
  });

  testWidgets('tapping "Clear" returns true', (WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(hostButton((bool r) => result = r));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Confirmation is shown before anything is cleared.
    expect(find.text(marker), findsOneWidget);

    await tester.tap(find.text(t.stat_clear_all_confirm));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.text(marker), findsNothing, reason: 'dialog dismissed');
  });

  testWidgets('tapping "Cancel" returns false', (WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(hostButton((bool r) => result = r));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(marker), findsOneWidget);

    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(find.text(marker), findsNothing);
  });
}
