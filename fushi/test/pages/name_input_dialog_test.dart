import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/name_input_dialog.dart';

import '../widgets/widget_test_helpers.dart';

/// 共享改名弹窗原语的行为契约。
///
/// 这个原语是库内全部改名入口的唯一实现（合集 / 视频 / 书 / 扫描根 / 词典），
/// 所以它的每一条行为都会同时作用在五个域上——空名怎么处理、trim 在哪一层、
/// controller 谁释放，只在这里定一次。
Future<String?> _open(
  WidgetTester tester, {
  String initialName = '',
}) async {
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
  return tester.widget<TextButton>(ok).onPressed;
}

void main() {
  testWidgets('预填非空时确认键可用', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');
    expect(find.text('重命名'), findsOneWidget);
    expect(
      _okOnPressed(tester),
      isNotNull,
      reason: '有名字就该能确认',
    );
  });

  testWidgets('清空后确认键置灰，而不是可点却毫无反应', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(
      _okOnPressed(tester),
      isNull,
      reason: '空名不可提交这件事必须**看得见**。这个原语第一版是让按钮照常可点、'
          '按下去弹窗不关也无提示——用户只会以为程序卡住了。',
    );
  });

  testWidgets('只有空白也算空名', (WidgetTester tester) async {
    await _open(tester, initialName: '旧名');

    await tester.enterText(find.byType(TextField), '    ');
    await tester.pumpAndSettle();

    expect(
      _okOnPressed(tester),
      isNull,
      reason: 'trim 在原语这一层做，调用方不必各自判空',
    );
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
    expect(
      _okOnPressed(tester),
      isNull,
      reason: '「组合成合集」那条路径预填就是空串，进来时就该是灰的',
    );
  });
}
