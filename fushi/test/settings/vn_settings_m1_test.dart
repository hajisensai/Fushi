import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  late FushiDatabase db;
  late ReaderSettings readerSettings;
  late SettingsContext settingsContext;
  late SettingsSection vnSection;
  late int layoutReloads;

  SettingsItem item(String id) => vnSection.items.singleWhere(
    (SettingsItem candidate) => candidate.id == id,
  );

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderFushiSource.readerSettings = readerSettings;
    layoutReloads = 0;
    ReaderFushiSource.onLayoutReloadLive = () => layoutReloads++;
  });

  tearDown(() async {
    ReaderFushiSource.onLayoutReloadLive = null;
    ReaderFushiSource.readerSettings = null;
    await db.close();
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              vnSection = buildReadingDestination().sections.singleWhere(
                (SettingsSection section) => section.items.any(
                  (SettingsItem candidate) =>
                      candidate.id == 'reading_vn.reveal_speed',
                ),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  testWidgets('all six VN controls are exposed only in VN mode', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    expect(vnSection.items.map((SettingsItem item) => item.id), <String>[
      'reading_vn.reveal_speed',
      'reading_vn.screen_mode',
      'reading_vn.sentences_per_screen',
      'reading_vn.preserve_dialogue',
      'reading_vn.click_advance',
      'reading_vn.merge_spoken_sentence',
    ]);
    expect(vnSection.isVisible(settingsContext), isFalse);
    expect(
      vnSection.items.any(
        (SettingsItem item) => item.isVisible(settingsContext),
      ),
      isFalse,
      reason:
          'quick-settings projection drops section visibility, so every '
          'VN item also needs its own runtime gate',
    );

    await readerSettings.setViewMode('vn');
    expect(vnSection.isVisible(settingsContext), isTrue);
    expect(
      vnSection.items
          .where((SettingsItem item) => item.isVisible(settingsContext))
          .map((SettingsItem item) => item.id),
      <String>[
        'reading_vn.reveal_speed',
        'reading_vn.screen_mode',
        'reading_vn.click_advance',
        'reading_vn.merge_spoken_sentence',
      ],
      reason: 'sentence-only controls stay hidden in block mode',
    );
    expect(
      vnSection.items.every((SettingsItem item) => item.reader != null),
      isTrue,
      reason: 'VN controls must also be reachable from in-reader settings',
    );

    await readerSettings.setViewMode('continuous');
    expect(vnSection.isVisible(settingsContext), isFalse);
  });

  testWidgets('controls persist every VN engine input and request one reload', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await readerSettings.setViewMode('vn');

    await (item('reading_vn.reveal_speed') as SettingsSliderItem).onChanged(
      settingsContext,
      60,
    );
    await (item('reading_vn.screen_mode') as SettingsSegmentedItem<String>)
        .onChanged(settingsContext, 'sentences');

    final SettingsStepperItem sentenceCount =
        item('reading_vn.sentences_per_screen') as SettingsStepperItem;
    final SettingsSwitchItem preserveDialogue =
        item('reading_vn.preserve_dialogue') as SettingsSwitchItem;
    expect(sentenceCount.isVisible(settingsContext), isTrue);
    expect(preserveDialogue.isVisible(settingsContext), isTrue);
    await sentenceCount.onChanged(settingsContext, 4);
    await preserveDialogue.onChanged(settingsContext, true);
    await (item('reading_vn.click_advance') as SettingsSwitchItem).onChanged(
      settingsContext,
      true,
    );
    await (item('reading_vn.merge_spoken_sentence') as SettingsSwitchItem)
        .onChanged(settingsContext, true);

    expect(readerSettings.visualNovelRevealSpeed, 60);
    expect(readerSettings.visualNovelScreenMode, 'sentences');
    expect(readerSettings.visualNovelSentencesPerScreen, 4);
    expect(readerSettings.visualNovelPreserveDialogueBubbles, isTrue);
    expect(readerSettings.visualNovelClickAdvance, isTrue);
    expect(readerSettings.visualNovelMergeCrossScreenSentenceAudioCues, isTrue);
    expect(
      layoutReloads,
      6,
      reason: 'each committed setting change must rebuild the VN screen map',
    );

    await (item('reading_vn.screen_mode') as SettingsSegmentedItem<String>)
        .onChanged(settingsContext, 'block');
    expect(sentenceCount.isVisible(settingsContext), isFalse);
    expect(preserveDialogue.isVisible(settingsContext), isFalse);
  });
}
