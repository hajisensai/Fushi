import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/utils.dart';

class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('reader settings custom theme chip uses shared MD3 chip',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return buildReaderThemeChip(
                context: context,
                label: 'Custom Theme',
                selected: true,
                onSelected: (_) {},
                avatar: const Icon(Icons.palette),
              );
            },
          ),
        ),
      ),
    );

    final Finder chip = find.byType(HibikiSelectableChip);

    expect(chip, findsOneWidget);
    expect(tester.widget<HibikiSelectableChip>(chip).selected, isTrue);
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets('audiobook play bar keeps lyrics mode out of bottom bar',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.lyrics), findsNothing);
    expect(find.byIcon(Icons.auto_stories), findsNothing);
  });

  testWidgets('in-book settings sheet uses adaptive settings rows',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: ReaderQuickSettingsSheet(
            controller: null,
            toc: const [],
            readerProgress: const (1, 3),
            onJumpSection: (_) async {},
            onBookmark: () async {},
            onExitReader: () {},
            webViewController: _FakeInAppWebViewController(),
            appModel: AppModel(),
            isHibikiReader: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AdaptiveSettingsNavigationRow), findsWidgets);
    expect(find.text(t.settings_destination_appearance), findsOneWidget);
    expect(find.text(t.section_layout), findsOneWidget);
    expect(find.text(t.settings_destination_reading_controls), findsOneWidget);
    expect(find.text(t.section_navigation), findsOneWidget);
    expect(find.text(t.display_settings), findsNothing);
    expect(find.byType(ListTile), findsNothing);

    await tester.tap(find.text(t.settings_destination_appearance));
    await tester.pumpAndSettle();

    expect(find.text(t.settings_destination_appearance), findsOneWidget);
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(find.byType(AdaptiveSettingsSwitchRow), findsNothing);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.section_layout));
    await tester.pumpAndSettle();

    expect(find.byType(AdaptiveSettingsSegmentedRow<String>), findsWidgets);
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('in-book navigation lists avoid legacy Material tiles',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: ReaderQuickSettingsSheet(
            controller: null,
            toc: const [
              TtuTocEntry(index: 0, label: 'Opening'),
              TtuTocEntry(index: 1, label: 'Chapter 1'),
            ],
            readerProgress: const (1, 2),
            onJumpSection: (_) async {},
            onBookmark: () async {},
            onExitReader: () {},
            webViewController: _FakeInAppWebViewController(),
            appModel: AppModel(),
            bookmarks: [
              Bookmark(
                sectionIndex: 1,
                normCharOffset: 120,
                label: 'Saved page',
                createdAt: DateTime(2026, 5, 25, 12),
              ),
            ],
            favoriteSentences: [
              FavoriteSentence(
                text: 'A highlighted sentence from the current book.',
                bookTitle: 'Current Book',
                chapterLabel: 'Chapter 1',
                sectionIndex: 1,
                normCharOffset: 120,
                createdAt: DateTime(2026, 5, 25, 12),
              ),
            ],
            onJumpToBookmark: (_) async {},
            onDeleteBookmark: (_) async {},
            onJumpToFavorite: (_) async {},
            onDeleteFavorite: (_) async {},
            isHibikiReader: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.section_navigation));
    await tester.pumpAndSettle();

    expect(find.text('Opening'), findsOneWidget);
    expect(find.text('Saved page'), findsOneWidget);
    expect(find.textContaining('A highlighted sentence'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(AdaptiveSettingsSection), findsWidgets);
  });
}
