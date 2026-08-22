import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_native.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../widgets/widget_test_helpers.dart';

void main() {
  testWidgets('native popup mine action uses an MD3 icon button', (
    WidgetTester tester,
  ) async {
    Map<String, String>? minedFields;

    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 320,
          height: 240,
          child: DictionaryPopupNative(
            result: DictionarySearchResult(
              searchTerm: '猫',
              entries: <DictionaryEntry>[
                DictionaryEntry(
                  word: '猫',
                  reading: 'ねこ',
                  meaning: 'cat',
                  dictionaryName: 'Test Dictionary',
                ),
              ],
            ),
            onMineEntry: (Map<String, String> fields) {
              minedFields = fields;
            },
          ),
        ),
      ),
    );

    final Finder mineButton = find.byIcon(Icons.add_circle_outline);
    expect(mineButton, findsOneWidget);
    expect(find.text('+'), findsNothing);

    await tester.tap(mineButton);
    await tester.pumpAndSettle();

    expect(minedFields, <String, String>{
      'expression': '猫',
      'reading': 'ねこ',
    });
  });

  /// extra 里的 deinflectionTrace 已经是 buildDeinflectionTags 的**成品**
  /// （顺序已反转成接续顺序），原生弹窗只负责渲染与展示说明。
  DictionarySearchResult resultWithTrace(List<Map<String, String>> trace) =>
      DictionarySearchResult(
        searchTerm: '当たっていた',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            word: '当たる',
            reading: 'あたる',
            meaning: 'to hit',
            dictionaryName: 'JMdict',
            extra: jsonEncode(<String, dynamic>{
              'matched': '当たっていた',
              'deinflected': '当たる',
              'deinflectionTrace': trace,
            }),
          ),
        ],
      );

  testWidgets('变形标签按接续顺序渲染，点开能看到该层的语法说明', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 400,
          height: 480,
          child: DictionaryPopupNative(
            result: resultWithTrace(<Map<String, String>>[
              <String, String>{'name': '-て', 'description': 'て-form.'},
              <String, String>{
                'name': '-いる',
                'description': 'Indicates continuation.',
              },
              <String, String>{
                'name': '-た',
                'description': 'Indicates the past.',
              },
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 三层变形都要出现，中间用「«」分隔（与 Yomitan / WebView 弹窗同一读法）。
    expect(find.text('-て'), findsOneWidget);
    expect(find.text('-いる'), findsOneWidget);
    expect(find.text('-た'), findsOneWidget);
    expect(find.text('«'), findsNWidgets(2));

    // 语法说明在点开之前不该出现在弹窗里。
    expect(find.text('て-form.'), findsNothing);

    await tester.tap(find.text('-て'));
    await tester.pumpAndSettle();

    expect(find.text('て-form.'), findsOneWidget);
    expect(find.text('Indicates the past.'), findsNothing);
  });

  testWidgets('没有语法说明的回落标签不可点（点了也不弹空框）', (
    WidgetTester tester,
  ) async {
    // 文本变体归一（colour→color）没有经过任何变形规则，因此没有语法说明。
    await tester.pumpWidget(
      buildTestApp(
        SizedBox(
          width: 400,
          height: 480,
          child: DictionaryPopupNative(
            result: resultWithTrace(<Map<String, String>>[
              <String, String>{
                'name': '当たっていた → 当たる',
                'description': '',
              },
            ]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当たっていた → 当たる'), findsOneWidget);
    // 单条标签不需要分隔符。
    expect(find.text('«'), findsNothing);

    await tester.tap(find.text('当たっていた → 当たる'));
    await tester.pumpAndSettle();

    // 没有对话框弹出——标签根本不可点。
    expect(find.byType(Dialog), findsNothing);
  });
}
