import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/name_input_dialog.dart';

import '../widgets/widget_test_helpers.dart';
import '../helpers/glass_unwrap.dart';

/// 共享改名弹窗原语的行为契约。
///
/// 这个原语是库内全部改名入口的唯一实现（合集 / 视频 / 书 / 扫描根 / 词典），
/// 所以它的每一条行为都会同时作用在五个域上——空名怎么处理、trim 在哪一层、
/// controller 谁释放，只在这里定一次。
Future<String?> _open(WidgetTester tester, {String initialName = ''}) async {
  String? result;
  bool returned = false;
  await tester.pumpWidget(
    buildTestApp(
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async {
            result = await showNameInputDialog(
              context: context,
              title: '重命名',
              labelText: '名称',
              initialName: initialName,
            );
            returned = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  addTearDown(() => returned);
  return result;
}

/// 取「确认」按钮的 onPressed —— null 即置灰。
VoidCallback? _okOnPressed(WidgetTester tester) {
  final Finder ok = find.ancestor(
    of: find.text('OK'),
    matching: find.byType(TextButton),
  );
  if (ok.evaluate().isEmpty) {
    // 平台自适应按钮可能不是 TextButton，退回按文本找可点祖先。
    final Finder any = find.byWidgetPredicate(
      (Widget w) => w is ButtonStyleButton && w.child is Text,
    );
    for (final Element e in any.evaluate()) {
      final ButtonStyleButton b = e.widget as ButtonStyleButton;
      if ((b.child as Text).data == 'OK') return b.onPressed;
    }
    return null;
  }
  return tester.widget<TextButton>(glassUnwrap<TextButton>(ok)).onPressed;
}

void main() {
  testWidgets('预填非空时确认键可用', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');
    expect(find.text('重命名'), findsOneWidget);
    expect(_okOnPressed(tester), isNotNull, reason: '有名字就该能确认');
  });

  testWidgets('清空后确认键置灰，而不是可点却毫无反应', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(
      _okOnPressed(tester),
      isNull,
      reason:
          '空名不可提交这件事必须**看得见**。这个原语第一版是让按钮照常可点、'
          '按下去弹窗不关也无提示——用户只会以为程序卡住了。',
    );
  });

  testWidgets('只有空白也算空名', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');

    await tester.enterText(find.byType(TextField), '    ');
    await tester.pumpAndSettle();

    expect(_okOnPressed(tester), isNull, reason: 'trim 在原语这一层做，调用方不必各自判空');
  });

  testWidgets('重新输入后确认键恢复可用', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(_okOnPressed(tester), isNull);

    await tester.enterText(find.byType(TextField), '新名');
    await tester.pumpAndSettle();
    expect(
      _okOnPressed(tester),
      isNotNull,
      reason: '置灰必须是双向的——只在 initState 算一次就会永久卡住',
    );
  });

  testWidgets('初始就为空时确认键一开始就是灰的', (WidgetTester tester) async {
    await _open(tester);
    expect(_okOnPressed(tester), isNull, reason: '「组合成合集」那条路径预填就是空串，进来时就该是灰的');
  });

  testWidgets('焦点导航开着、键盘 Enter 打开时焦点落在输入框，而不是框尾的屏幕键盘钮', (
    WidgetTester tester,
  ) async {
    // 真机集成跑（隐藏 Windows runner、实验性焦点导航开、MD3）记到过：词典详情
    // Rename 钮上按 Enter 打开本弹窗后，主焦点停在 `fushi-icon-button-…`——
    // 桌面端输入框尾部「屏幕键盘」钮（对话框里唯一登记进焦点引擎的目标，被动
    // 修复只会落到它）。挂上 FushiFocusRoot + Windows 平台的 widget 测试复现
    // 不出来（焦点稳定在输入框），这条用例守住 widget 层的契约。
    final FocusNode trigger = FocusNode(debugLabel: 'open-trigger');
    addTearDown(trigger.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiFallbackTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.windows),
        builder: (BuildContext context, Widget? child) =>
            FushiFocusRoot(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              focusNode: trigger,
              onPressed: () => showNameInputDialog(
                context: context,
                title: '重命名',
                labelText: '名称',
                initialName: '旧名',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    trigger.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final EditableText field = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(
      field.focusNode.hasPrimaryFocus,
      isTrue,
      reason:
          'autofocus 的输入框应持有主焦点；实际主焦点是 '
          '${FocusManager.instance.primaryFocus}',
    );
  });
}
