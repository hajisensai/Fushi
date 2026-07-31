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
    final JimakuFileInventory inventory = JimakuFileInventory.fromFiles(
      const <JimakuFile>[
        JimakuFile(name: 'Show S01E01.ja.srt', url: 'https://x/1'),
        JimakuFile(name: 'Show S01E02.zh-cn.ass', url: 'https://x/2'),
        JimakuFile(name: 'Show.zip', url: 'https://x/archive'),
      ],
    );
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
                        inventories: <int, JimakuFileInventory>{1: inventory},
                        failedEntryIds: const <int>{2},
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

    expect(find.text('Jimaku #1'), findsOneWidget);
    expect(find.text('Jimaku #2'), findsOneWidget);
    expect(
      find.text(t.video_jimaku_source_summary(
        files: 2,
        episodes: 2,
        languages: '日本語 / 中文',
      )),
      findsOneWidget,
    );
    expect(find.text(t.video_jimaku_source_failed), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('jimaku_entry_2')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsNothing,
    );
    await tester.tap(find.text('Complete season pack'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('jimaku_entry_2')),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('日本語'));
    await tester.pump();
    final ChoiceChip languageChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '日本語'),
    );
    expect(languageChip.selected, isTrue);
  });
}
