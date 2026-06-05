import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// Comprehensive settings, focus-driven (synthetic key events only — no
/// coordinate taps), on the REAL app.
///
/// Tab-traverses the REAL [DisplaySettingsPage] and drives each settings row it
/// lands on by its kind — Switch is activated with Space, Slider/Stepper/
/// Segmented are nudged with the D-pad (each is a single `_GamepadAdjustable`
/// focus stop). Tabbing also scrolls the lazy list into view and builds rows on
/// demand, so this reaches controls past the first screenful without coordinate
/// scrolling. Then it asserts the changes wrote through to the prefs DB and
/// restores every pref it touched.
///
/// The old version pushed a SYNTHETIC harness page on top of DisplaySettings to
/// cover every control type; that depended on the under-route going off-stage,
/// which only holds on mobile — on the desktop two-pane the pushed route does
/// not render, so the harness saw 0 controls. Control-TYPE coverage already
/// lives in the platform-agnostic widget test
/// `test/settings/settings_schema_coverage_test.dart` (full focus-driven schema
/// + effect probes), so this integration test focuses on the unique value: the
/// REAL app's REAL settings page driven by focus. Runs on emulator + desktop
/// (Windows/Mac hidden runner).
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'comprehensive settings: focus-driven real controls persist real changes',
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

      final FocusDriver driver = FocusDriver(tester);
      final int driven =
          await _focusDriveSettingsRows(tester, driver, target: 3);
      debugPrint('[comprehensive-settings] focus-driven rows=$driven');
      expect(driven, greaterThanOrEqualTo(2),
          reason: 'focus must drive at least two real settings controls '
              '(Switch/Slider/Stepper/Segmented) on DisplaySettingsPage');

      await appModel.prefsRepo.refreshFromDb();
      final Map<String, String> after =
          Map<String, String>.from(appModel.prefsRepo.prefsSnapshot);
      expect(_mapsEqual(before, after), isFalse,
          reason: 'focus-driven control changes must write through to prefs');

      await _exerciseSyncSettings(tester, appModel);

      // Restore every pref this test changed back to its pre-test value so the
      // user's real settings are untouched.
      for (final MapEntry<String, String> e in before.entries) {
        if (after[e.key] != e.value) {
          await appModel.database.setPref(e.key, e.value);
        }
      }
      for (final String k in after.keys) {
        if (!before.containsKey(k)) {
          await appModel.database.deletePref(k);
        }
      }
      await appModel.prefsRepo.refreshFromDb();

      await takeScreenshot(binding, 'comprehensive_settings');
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

/// Tab through the current page; whenever focus lands on a settings row, drive
/// it by its kind (Switch → Space activate; Slider/Stepper/Segmented → D-pad
/// arrow). Tabbing scrolls + builds lazy rows. Stops after [target] rows driven.
Future<int> _focusDriveSettingsRows(
  WidgetTester tester,
  FocusDriver driver, {
  required int target,
}) async {
  int driven = 0;
  final Set<FocusNode> seen = <FocusNode>{};
  for (int step = 0; step < 150 && driven < target; step++) {
    final FocusNode? node = FocusManager.instance.primaryFocus;
    if (node != null && seen.add(node)) {
      final _RowKind? kind = _focusedRowKind();
      if (kind == _RowKind.switchRow) {
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 250));
        driven++;
      } else if (kind != null) {
        await driver.adjust(steps: 2);
        await tester.pump(const Duration(milliseconds: 250));
        driven++;
      }
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 60));
  }
  return driven;
}

enum _RowKind { switchRow, slider, stepper, segmented }

_RowKind? _focusedRowKind() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  _RowKind? found;
  ctx.visitAncestorElements((Element el) {
    final Widget w = el.widget;
    if (w is AdaptiveSettingsSwitchRow) {
      found = _RowKind.switchRow;
      return false;
    }
    if (w is AdaptiveSettingsSliderRow) {
      found = _RowKind.slider;
      return false;
    }
    if (w is AdaptiveSettingsStepperRow) {
      found = _RowKind.stepper;
      return false;
    }
    if (w is AdaptiveSettingsSegmentedRow) {
      found = _RowKind.segmented;
      return false;
    }
    return true;
  });
  return found;
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

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
