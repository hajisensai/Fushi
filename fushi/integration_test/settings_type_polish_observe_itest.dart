import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_recent_destinations.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// Settings › General on a custom-image page backdrop (wide two-pane layout):
/// before/after evidence for the settings title weight, the nav pane's
/// legibility over the wallpaper and the nav list's top edge under the search
/// bar. Image path comes from `FUSHI_PROBE_BACKDROP_IMAGE` (dart-define).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings type polish: General over a wallpaper', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: 'home within 90s');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);

    await windowManager.setSize(const Size(1200, 950));
    await tester.pump(const Duration(seconds: 1));

    const String image = String.fromEnvironment('FUSHI_PROBE_BACKDROP_IMAGE');
    if (image.isNotEmpty) {
      await appModel.themeNotifier.importPageBackdropImage(
        File(image),
        portrait: false,
      );
      await appModel.themeNotifier.setFollowPageBackdropAccent(true);
    }
    await tester.pump(const Duration(seconds: 2));

    HomePage.debugSelectTab?.call(HomeTab.settings);
    await tester.pump(const Duration(seconds: 2));
    settingsDestinationRequest.value = SettingsDestinationId.general;
    await tester.pump(const Duration(seconds: 3));

    final ObserveShot top = await captureFlutterFrame(tester, '01-general');
    expect(top.saved, isTrue);

    // Scroll the nav list a little: the first rows meet the search bar edge.
    final Finder navScroll = find.ancestor(
      of: find.byType(Md3SettingsNavList),
      matching: find.byType(Scrollable),
    );
    expect(navScroll, findsWidgets, reason: 'wide MD3 nav list on screen');
    tester.state<ScrollableState>(navScroll.first).position.jumpTo(70);
    await tester.pump(const Duration(seconds: 2));
    final ObserveShot scrolled = await captureFlutterFrame(
      tester,
      '02-nav-scrolled',
    );
    expect(scrolled.saved, isTrue);
  });
}
