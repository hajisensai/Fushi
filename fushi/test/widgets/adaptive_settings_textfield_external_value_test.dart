import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 XyTPrbdKSZ：制卡设置切换 Profile 后，标签框（`initialValue` 形态的
/// [AdaptiveSettingsTextField]）仍显示上一个 Profile 的值。外部值变了且输入框没
/// 焦点时要跟着变；正在输入时不能被冲掉；父级没改值的普通重建不能回退用户输入。
void main() {
  Future<void> pump(WidgetTester tester, String value) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AdaptiveSettingsTextField(
          initialValue: value,
          hintText: 'tags',
          onChanged: (_) {},
        ),
      ),
    ),
  );

  String fieldText(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  testWidgets('follows an external value change while unfocused', (
    WidgetTester tester,
  ) async {
    await pump(tester, 'profile-a');
    expect(fieldText(tester), 'profile-a');
    await pump(tester, 'profile-b');
    expect(fieldText(tester), 'profile-b');
  });

  testWidgets('does not clobber in-progress typing', (
    WidgetTester tester,
  ) async {
    await pump(tester, 'old');
    await tester.tap(find.byType(EditableText));
    await tester.enterText(find.byType(EditableText), 'typing');
    await pump(tester, 'lagging-save');
    expect(fieldText(tester), 'typing');
  });

  testWidgets('plain rebuild with an unchanged value keeps user input', (
    WidgetTester tester,
  ) async {
    await pump(tester, 'old');
    await tester.enterText(find.byType(EditableText), 'edited');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await pump(tester, 'old');
    expect(fieldText(tester), 'edited');
  });
}
