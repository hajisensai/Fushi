import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_native.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

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
}
