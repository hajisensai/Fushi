import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/display_settings_page.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comprehensive settings controls persist real preference changes',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[comprehensive-settings] ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      await appModel.prefsRepo.refreshFromDb();
      final Map<String, String> before =
          Map<String, String>.from(appModel.prefsRepo.prefsSnapshot);

      await _openDisplaySettingsPage(tester);
      final _ExerciseCounts counts = await _exerciseVisibleControls(tester);
      expect(counts.segmentedButtons, greaterThan(0));
      expect(counts.steppers, greaterThan(0));

      final _HarnessState harness = await _exerciseHarnessControls(tester);
      expect(harness.switchValue, isTrue);
      expect(harness.segmentValue, 'right');
      expect(harness.sliderValue, greaterThan(0.5));
      expect(harness.stepperValue, 11);
      expect(harness.pickerValue, 'beta');

      await _exerciseSyncSettings(tester, appModel);

      final double originalFontSize = appModel.prefsRepo.dictionaryFontSize;
      appModel.setDictionaryFontSize(originalFontSize + 1);
      await tester.pump(const Duration(milliseconds: 500));
      await appModel.prefsRepo.refreshFromDb();
      final Map<String, String> after =
          Map<String, String>.from(appModel.prefsRepo.prefsSnapshot);
      expect(_mapsEqual(before, after), isFalse);
      appModel.setDictionaryFontSize(originalFontSize);
      await tester.pump(const Duration(milliseconds: 500));

      await takeScreenshot(binding, 'comprehensive_settings');
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _openDisplaySettingsPage(WidgetTester tester) async {
  final NavigatorState nav = Navigator.of(
    tester.element(find.byType(Scaffold).first),
  );
  unawaited(nav.push(
    MaterialPageRoute<void>(
      builder: (_) => const DisplaySettingsPage(),
    ),
  ));
  await tester.pump(const Duration(seconds: 2));
}

Future<_ExerciseCounts> _exerciseVisibleControls(WidgetTester tester) async {
  int switches = 0;
  int sliders = 0;
  int segmented = 0;
  int steppers = 0;

  for (int pass = 0; pass < 16; pass++) {
    if (steppers == 0) {
      steppers += await _exerciseFirstStepper(tester);
    }
    if (segmented == 0) {
      segmented += await _exerciseFirstSegmentedButton(tester);
    }
    if (switches == 0) {
      switches += await _exerciseFirstSwitch(tester);
    }
    if (sliders == 0) {
      sliders += await _exerciseFirstSlider(tester);
    }
    if (switches > 0 && segmented > 0 && steppers > 0) break;
    if (!await _scrollBy(tester, -260)) break;
  }

  return _ExerciseCounts(
    switches: switches,
    sliders: sliders,
    segmentedButtons: segmented,
    steppers: steppers,
  );
}

Future<int> _exerciseFirstStepper(WidgetTester tester) async {
  final Finder stepperFinder = find.byType(AdaptiveSettingsStepperRow);
  if (stepperFinder.evaluate().isEmpty) return 0;
  final AdaptiveSettingsStepperRow row =
      tester.widget<AdaptiveSettingsStepperRow>(stepperFinder.first);
  row.onChanged((row.value + row.step).clamp(row.min, row.max).toDouble());
  await tester.pump(const Duration(milliseconds: 500));
  return 1;
}

Future<int> _exerciseFirstSegmentedButton(WidgetTester tester) async {
  final Finder segmentedFinder = find.byWidgetPredicate(
    (Widget widget) =>
        widget.runtimeType.toString().startsWith('AdaptiveSettingsSegmentedRow'),
  );
  for (int i = 0; i < segmentedFinder.evaluate().length; i++) {
    final dynamic row = tester.widget(segmentedFinder.at(i));
    for (final ButtonSegment<dynamic> segment
        in row.segments as List<ButtonSegment<dynamic>>) {
      if (segment.value == row.selected) continue;
      row.onChanged(segment.value);
      await tester.pump(const Duration(milliseconds: 500));
      return 1;
    }
  }
  return 0;
}

Future<int> _exerciseFirstSwitch(WidgetTester tester) async {
  final Finder switchFinder = find.byType(Switch);
  for (int i = 0; i < switchFinder.evaluate().length; i++) {
    final Finder current = switchFinder.at(i);
    final Switch value = tester.widget<Switch>(current);
    if (value.onChanged == null) continue;
    await tester.tap(current, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(current, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));
    return 1;
  }
  return 0;
}

Future<int> _exerciseFirstSlider(WidgetTester tester) async {
  final Finder sliderFinder = find.byType(Slider);
  if (sliderFinder.evaluate().isEmpty) return 0;
  await tester.drag(sliderFinder.first, const Offset(16, 0));
  await tester.pump(const Duration(milliseconds: 500));
  return 1;
}

Future<_HarnessState> _exerciseHarnessControls(WidgetTester tester) async {
  final _HarnessState state = _HarnessState();
  await _pushSettingsDestination(
    tester,
    _buildHarnessDestination(state),
  );

  final Finder switchFinder = find.byType(Switch);
  expect(switchFinder, findsOneWidget);
  await tester.tap(switchFinder.first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 500));

  await tester.tap(find.text('Right').first);
  await tester.pump(const Duration(milliseconds: 500));

  final Finder sliderFinder = find.byType(Slider);
  expect(sliderFinder, findsOneWidget);
  await tester.drag(sliderFinder.first, const Offset(80, 0));
  await tester.pump(const Duration(milliseconds: 500));

  final Finder addButton = find.byIcon(Icons.add);
  expect(addButton, findsOneWidget);
  await tester.tap(addButton.first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 500));

  await tester.tap(find.text('Alpha').first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text('Beta').last, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 500));

  Navigator.of(tester.element(find.byType(SettingsDetailPage).first)).pop();
  await tester.pump(const Duration(milliseconds: 500));
  return state;
}

Future<void> _exerciseSyncSettings(
  WidgetTester tester,
  AppModel appModel,
) async {
  final SyncRepository repo = SyncRepository(appModel.database);
  final SyncBackendType originalBackend = await repo.getBackendType();
  final bool originalContent = await repo.isSyncContentEnabled();
  final bool originalStats = await repo.isSyncStatsEnabled();
  final bool nextContent = !originalContent;

  try {
    await _pushSettingsDestination(tester, buildSyncBackupDestination());
    await repo.setBackendType(SyncBackendType.webDav);
    await repo.setSyncContentEnabled(nextContent);
    await repo.setSyncStatsEnabled(!originalStats);
    await tester.pump(const Duration(milliseconds: 500));

    expect(await repo.getBackendType(), SyncBackendType.webDav);
    expect(await repo.isSyncContentEnabled(), nextContent);
    expect(await repo.isSyncStatsEnabled(), !originalStats);
  } finally {
    await repo.setBackendType(originalBackend);
    await repo.setSyncContentEnabled(originalContent);
    await repo.setSyncStatsEnabled(originalStats);
    final Finder detailPage = find.byType(SettingsDetailPage);
    if (detailPage.evaluate().isNotEmpty) {
      Navigator.of(tester.element(detailPage.first)).pop();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }
}

Future<void> _pushSettingsDestination(
  WidgetTester tester,
  SettingsDestination destination,
) async {
  final NavigatorState nav = Navigator.of(
    tester.element(find.byType(Scaffold).first),
  );
  unawaited(nav.push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsDetailPage(destination: destination),
    ),
  ));
  await tester.pump(const Duration(seconds: 2));
}

SettingsDestination _buildHarnessDestination(_HarnessState state) {
  return SettingsDestination(
    id: SettingsDestinationId.diagnostics,
    title: 'Harness',
    icon: Icons.tune,
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'harness.switch',
            title: 'Switch',
            value: (_) => state.switchValue,
            onChanged: (_, bool value) => state.switchValue = value,
          ),
          SettingsSegmentedItem<String>(
            id: 'harness.segment',
            title: 'Segment',
            options: const <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(value: 'left', label: 'Left'),
              SettingsSegmentOption<String>(value: 'right', label: 'Right'),
            ],
            selected: (_) => state.segmentValue,
            onChanged: (_, String value) => state.segmentValue = value,
          ),
          SettingsSliderItem(
            id: 'harness.slider',
            title: 'Slider',
            value: (_) => state.sliderValue,
            onChanged: (_, double value) => state.sliderValue = value,
          ),
          SettingsStepperItem(
            id: 'harness.stepper',
            title: 'Stepper',
            value: (_) => state.stepperValue.toDouble(),
            step: 1,
            min: 0,
            max: 20,
            format: (double value) => value.round().toString(),
            onChanged: (_, double value) =>
                state.stepperValue = value.round(),
          ),
          SettingsCustomItem(
            id: 'harness.picker',
            builder: (_) => AdaptiveSettingsPickerRow<String>(
              title: 'Picker',
              options: const <AdaptiveSettingsPickerOption<String>>[
                AdaptiveSettingsPickerOption<String>(
                  value: 'alpha',
                  label: 'Alpha',
                ),
                AdaptiveSettingsPickerOption<String>(
                  value: 'beta',
                  label: 'Beta',
                ),
              ],
              selected: state.pickerValue,
              onChanged: (String value) => state.pickerValue = value,
            ),
          ),
        ],
      ),
    ],
  );
}

Future<bool> _scrollBy(WidgetTester tester, double dy) async {
  final Finder scrollables = find.byType(Scrollable);
  if (scrollables.evaluate().isEmpty) return false;
  await tester.drag(
    scrollables.last,
    Offset(0, dy),
    warnIfMissed: false,
  );
  await tester.pump(const Duration(milliseconds: 300));
  return true;
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

class _ExerciseCounts {
  const _ExerciseCounts({
    required this.switches,
    required this.sliders,
    required this.segmentedButtons,
    required this.steppers,
  });

  final int switches;
  final int sliders;
  final int segmentedButtons;
  final int steppers;
}

class _HarnessState {
  bool switchValue = false;
  String segmentValue = 'left';
  double sliderValue = 0.5;
  int stepperValue = 10;
  String pickerValue = 'alpha';
}
