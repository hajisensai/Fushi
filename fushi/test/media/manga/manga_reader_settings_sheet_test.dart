import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_sheet.dart';

void main() {
  test('descriptor list gates device settings and preserves every mode', () {
    final List<MangaReaderPreferenceDescriptor> descriptors =
        mangaReaderPreferenceDescriptors(<String>{});
    expect(
      descriptors.any(
        (MangaReaderPreferenceDescriptor d) => d.key == 'fullscreen',
      ),
      isFalse,
    );
    final MangaReaderPreferenceDescriptor mode = descriptors.firstWhere(
      (MangaReaderPreferenceDescriptor d) => d.key == 'mode',
    );
    expect(
      mode.choices,
      containsAll(<String>[
        'spread',
        'paged_vertical',
        'webtoon',
        'webtoon_gaps',
      ]),
    );
    expect(
      mangaReaderPreferenceDescriptors(<String>{
        'fullscreen',
      }).any((MangaReaderPreferenceDescriptor d) => d.key == 'fullscreen'),
      isTrue,
    );
  });

  testWidgets('sheet shows inherited state and reset clears sparse override', (
    WidgetTester tester,
  ) async {
    Map<String, Object?> saved = <String, Object?>{'showPageNumber': false};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaReaderSettingsSheet(
            globalDefaults: const MangaReaderPreferences(),
            overrides: saved,
            onChanged: (Map<String, Object?> next) async => saved = next,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This title'), findsOneWidget);
    expect(find.text('Restore all global defaults'), findsOneWidget);
    await tester.tap(find.text('Restore all global defaults'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.text('Use global default'), findsOneWidget);
  });
}
