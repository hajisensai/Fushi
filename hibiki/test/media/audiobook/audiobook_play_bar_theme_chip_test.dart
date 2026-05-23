import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/utils.dart';

class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('reader settings custom theme chip uses selected ChoiceChip',
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

    final Finder chip = find.byType(ChoiceChip);

    expect(chip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
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
          body: AudiobookSettingsSheet(
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
    expect(find.text(t.section_typography), findsNothing);
    expect(find.text(t.section_layout), findsNothing);
    expect(find.text(t.display_settings), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);

    await tester.tap(find.text(t.display_settings));
    await tester.pumpAndSettle();

    expect(find.text(t.section_typography), findsNothing);
    expect(find.text(t.section_layout), findsNothing);
    expect(find.byType(AdaptiveSettingsSegmentedRow<String>), findsWidgets);
    expect(find.byType(AdaptiveSettingsStepperRow), findsWidgets);
    expect(find.byType(AdaptiveSettingsSwitchRow), findsWidgets);
    expect(find.byType(ListTile), findsNothing);
  });
}
