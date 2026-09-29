// BUG-2686：移动端在 [FushiSearchField] 里输完按软键盘右下角的「搜索」，
// 查询照常提交，键盘却不收——BUG-2620 为了不让焦点被修复链还回来，给提交收尾
// 换成了只清 composing 的 onEditingComplete，焦点留在框里，软键盘也就一直挂着。
//
// 这里钉三件事：移动端提交后软键盘收起、焦点仍在框里（BUG-2620 的不变式不退）、
// 桌面端提交不去动软键盘。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

import 'widget_test_helpers.dart';

Future<List<String>> _pumpAndSubmit(WidgetTester tester) async {
  final TextEditingController controller = TextEditingController();
  final FocusNode focusNode = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focusNode.dispose);
  final List<String> submitted = <String>[];
  await tester.pumpWidget(buildTestApp(
    SizedBox(
      width: 600,
      child: FushiSearchField(
        controller: controller,
        focusNode: focusNode,
        hintText: 'Search',
        onChanged: (_) {},
        onSubmitted: submitted.add,
      ),
    ),
  ));
  await tester.showKeyboard(find.byType(TextField));
  await tester.enterText(find.byType(TextField), '猫');
  expect(tester.testTextInput.isVisible, isTrue, reason: '前提：键盘已弹起。');

  await tester.testTextInput.receiveAction(TextInputAction.search);
  // 收键盘排在 EditableText 重建输入连接之后的那一帧里。
  await tester.pump();

  expect(submitted, <String>['猫'], reason: '「搜索」键必须照常提交查询。');
  expect(
    focusNode.hasFocus,
    isTrue,
    reason: 'BUG-2620：提交不交出焦点，否则修复链会把焦点编程式还回来。',
  );
  return submitted;
}

void main() {
  testWidgets(
    '移动端按软键盘「搜索」：提交后收起软键盘，焦点仍在框里',
    (WidgetTester tester) async {
      await _pumpAndSubmit(tester);
      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason: '移动端按了「搜索」键盘还挂着，会挡住一半的结果（BUG-2686）。',
      );
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    '收起后再点一下搜索框：键盘重新弹起',
    (WidgetTester tester) async {
      await _pumpAndSubmit(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    '桌面端提交不去动软键盘',
    (WidgetTester tester) async {
      await _pumpAndSubmit(tester);
      expect(tester.testTextInput.isVisible, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
