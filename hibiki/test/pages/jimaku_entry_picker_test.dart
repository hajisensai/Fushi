import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/pages/implementations/jimaku_entry_picker.dart';
import 'package:hibiki/utils.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('user can choose one Jimaku entry and a language',
      (WidgetTester tester) async {
    int selectedEntry = 1;
    String? selectedLanguage;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return SingleChildScrollView(
                  child: Column(
                    children: <Widget>[
                      JimakuEntryPicker(
                        entries: const <JimakuEntry>[
                          JimakuEntry(id: 1, name: 'Episode releases'),
                          JimakuEntry(id: 2, name: 'Complete season pack'),
                        ],
                        selectedEntryId: selectedEntry,
                        onSelected: (JimakuEntry entry) {
                          setState(() => selectedEntry = entry.id);
                        },
                      ),
                      JimakuLanguagePicker(
                        selectedLanguage: selectedLanguage,
                        onSelected: (String? language) {
                          setState(() => selectedLanguage = language);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    ChoiceChip entryChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Complete season pack'),
    );
    expect(entryChip.selected, isFalse);
    await tester.tap(find.text('Complete season pack'));
    await tester.pump();
    entryChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Complete season pack'),
    );
    expect(entryChip.selected, isTrue);

    await tester.tap(find.text('日本語'));
    await tester.pump();
    final ChoiceChip languageChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '日本語'),
    );
    expect(languageChip.selected, isTrue);
  });
}
