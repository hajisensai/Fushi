import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/platform/desktop/desktop_close_prompt.dart';
import 'package:fushi/src/platform/desktop/desktop_tray.dart';

/// 「每次询问」关闭框：三个出口（托盘 / 退出 / 取消）与「记住我的选择」。
void main() {
  Future<Future<DesktopClosePromptResult?>> pumpPrompt(
    WidgetTester tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final Future<DesktopClosePromptResult?> result = showDesktopClosePrompt(
      captured,
    );
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('默认焦点在「最小化到托盘」：Enter 收进托盘且不记住', (WidgetTester tester) async {
    final Future<DesktopClosePromptResult?> result = await pumpPrompt(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final DesktopClosePromptResult? picked = await result;
    expect(picked?.action, DesktopCloseAction.tray);
    expect(picked?.remember, isFalse);
  });

  testWidgets('勾「记住我的选择」后选退出', (WidgetTester tester) async {
    final Future<DesktopClosePromptResult?> result = await pumpPrompt(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('desktop-close-remember')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('desktop-close-exit')));
    await tester.pumpAndSettle();
    final DesktopClosePromptResult? picked = await result;
    expect(picked?.action, DesktopCloseAction.exit);
    expect(picked?.remember, isTrue);
  });

  testWidgets('Esc 取消：返回 null，什么都不做', (WidgetTester tester) async {
    final Future<DesktopClosePromptResult?> result = await pumpPrompt(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });
}
