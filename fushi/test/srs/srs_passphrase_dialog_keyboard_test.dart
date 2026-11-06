// 反馈 TfvowyuJ15：复习数据位置「开启加密」口令弹窗，手机上键盘弹出后下半部分
// 没跟着动——说明很长 + 两个口令框，内容区不可滚，可用高度只剩一半时被压缩溢出、
// 第二个输入框被裁掉。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_history_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('encrypt passphrase dialog stays usable with the keyboard up', (
    WidgetTester tester,
  ) async {
    LocaleSettings.setLocale(AppLocale.en);
    // 典型手机 360×740 dp，软键盘占 320 dp。
    const Size screen = Size(360, 740);
    const double keyboard = 320;
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog<String>(
                    context: context,
                    builder: (_) => const SrsPassphraseDialog(confirm: true),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 不可滚时这里是 RenderFlex overflow。
    expect(tester.takeException(), isNull);

    final Finder second = find.byKey(
      const ValueKey<String>('srs_timeline_passphrase_again'),
    );
    expect(second, findsOneWidget);
    await tester.showKeyboard(second);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 聚焦的第二个口令框完整落在键盘上方的可见区内。
    final Rect field = tester.getRect(second);
    expect(field.top, greaterThanOrEqualTo(0));
    expect(field.bottom, lessThanOrEqualTo(screen.height - keyboard));
    // 确认按钮也在键盘上方。
    final Rect ok = tester.getRect(
      find.byKey(const ValueKey<String>('srs_timeline_passphrase_ok')),
    );
    expect(ok.bottom, lessThanOrEqualTo(screen.height - keyboard));
  });
}
