import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';

/// BUG-4219：互联配对的输入弹窗（PIN / 粘贴配对链接）在关窗动画期间输入框还在重建。
/// 旧实现在 `await showAppDialog` 返回后立刻释放调用方建的控制器，关窗那几帧撞上
/// 「A TextEditingController was used after being disposed」并拖垮元素树，配对一成功
/// 就红屏（`_dependents.isEmpty`）。这里走真实弹窗：输入 → 确认 → 把关窗动画放完，
/// 断言没有异常、返回值正确。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<Future<String?> Function()> pumpOpener(
    WidgetTester tester,
    Future<String?> Function(BuildContext context) open,
  ) async {
    Future<String?>? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () => result = open(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result!;
  }

  testWidgets('PIN 弹窗：确认后关窗动画放完不抛异常，返回去空白的 PIN', (WidgetTester tester) async {
    final Future<String?> Function() result = await pumpOpener(
      tester,
      promptInterconnectPairPin,
    );
    await tester.enterText(find.byType(EditableText), ' 160921 ');
    await tester.tap(find.text(t.sync_pair_continue));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(EditableText), findsNothing);
    expect(await result(), '160921');
  });

  testWidgets('PIN 弹窗：取消同样不抛异常，返回 null', (WidgetTester tester) async {
    final Future<String?> Function() result = await pumpOpener(
      tester,
      promptInterconnectPairPin,
    );
    await tester.enterText(find.byType(EditableText), '1');
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(await result(), isNull);
  });

  testWidgets('粘贴配对链接弹窗：确认后关窗不抛异常，非链接文本返回 null', (WidgetTester tester) async {
    Future<Object?>? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () => result = promptInterconnectPairLinkPaste(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'not a pair link');
    await tester.tap(find.text(t.sync_pair_continue));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(await result, isNull);
    // 提示条的计时器放完，测试结束时不留挂起的 Timer。
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });
}
