import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/popup_dictionary_page.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

import 'widget_test_helpers.dart';

/// 查词输入框的输入法语言提示（Android `EditorInfo.hintLocales`）必须真的走到
/// 输入栈底部的 [EditableText]——只断言 [TextField] 的构造参数会漏掉「组件收下了
/// 但没往下传」这一类接线错误。
EditableText _editableOf(WidgetTester tester) {
  return tester.widget<EditableText>(find.byType(EditableText));
}

void main() {
  group('FushiCompactSearchRow 输入法语言提示', () {
    testWidgets('传入的语言提示一路到达 EditableText', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        buildTestApp(
          FushiCompactSearchRow(
            controller: controller,
            focusNode: focusNode,
            hintText: 'Search',
            onSubmit: (_) {},
            hintLocales: const <Locale>[Locale('ja')],
          ),
        ),
      );
      await tester.pump();

      expect(_editableOf(tester).hintLocales, const <Locale>[Locale('ja')]);
    });

    testWidgets('没设置时不发提示（null，而不是空列表）', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        buildTestApp(
          FushiCompactSearchRow(
            controller: controller,
            focusNode: focusNode,
            hintText: 'Search',
            onSubmit: (_) {},
          ),
        ),
      );
      await tester.pump();

      // 空列表在 Flutter 契约里是「明确不要任何提示」，会压掉输入法自己的语言记忆；
      // 用户没设过时必须保持 null。
      expect(_editableOf(tester).hintLocales, isNull);
    });
  });

  group('PopupDictionarySearchBar 输入法语言提示', () {
    testWidgets('弹窗词典搜索栏把语言提示透传给输入框', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        buildTestApp(
          PopupDictionarySearchBar(
            controller: controller,
            focusNode: focusNode,
            onSubmit: (_) {},
            hintLocales: const <Locale>[
              Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(_editableOf(tester).hintLocales, const <Locale>[
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ]);
    });
  });
}
