import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_online_services_banner.dart';
import 'package:fushi/src/media/video/video_online_services_preferences.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository preferences;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    preferences = PreferencesRepository(db);
  });
  tearDown(() async {
    preferences.dispose();
    await db.close();
  });

  test('reminder hides only when the optional video services are configured',
      () async {
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setPref(kVideoAniDbHashEnabledPref, true);
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setPref(kVideoAniDbUsernamePref, 'tester');
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setPref(kVideoAniDbPasswordPref, 'password');
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setJimakuApiKey('jimaku-key');
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: 'subtitle-key'),
    );
    expect(shouldShowVideoOnlineServicesReminder(preferences), isFalse);
    await preferences.setJimakuEnabled(false);
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setJimakuEnabled(true);
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: 'subtitle-key', enabled: false),
    );
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: 'subtitle-key'),
    );
    await preferences.setPref(kVideoAniDbHashEnabledPref, false);
    expect(shouldShowVideoOnlineServicesReminder(preferences), isTrue);
  });

  test('permanent dismissal survives reload and excludes profile snapshots',
      () async {
    await preferences.setPref(kVideoAniDbHashEnabledPref, true);
    await preferences.setPref(kVideoAniDbUsernamePref, 'tester');
    await preferences.setPref(kVideoAniDbPasswordPref, ' password ');
    await preferences.setJimakuApiKey('jimaku-key');
    await preferences.setVideoSubtitleOpenSubtitlesConfig(
      OpenSubtitlesConfig(apiKey: 'subtitle-key'),
    );
    await dismissVideoOnlineServicesReminder(preferences);
    final PreferencesRepository reloaded = PreferencesRepository(db);
    addTearDown(reloaded.dispose);
    await reloaded.loadFromDb();
    expect(shouldShowVideoOnlineServicesReminder(reloaded), isFalse);
    expect(reloaded.getPref(kVideoAniDbHashEnabledPref, defaultValue: false),
        isTrue);
    expect(
        reloaded.getPref(kVideoAniDbUsernamePref, defaultValue: ''), 'tester');
    expect(reloaded.getPref(kVideoAniDbPasswordPref, defaultValue: ''),
        ' password ');
    expect(reloaded.jimakuApiKey, 'jimaku-key');
    expect(reloaded.jimakuEnabled, isTrue);
    expect(reloaded.videoSubtitleOpenSubtitlesConfig?.apiKey, 'subtitle-key');
    expect(reloaded.videoSubtitleOpenSubtitlesConfig?.enabled, isTrue);
    expect(ProfileKeys.isExcludedPref(kVideoOnlineServicesSetupDismissedPref),
        isTrue);
    await reloaded.setPref(kVideoAniDbHashEnabledPref, false);
    expect(shouldShowVideoOnlineServicesReminder(reloaded), isFalse);
  });

  testWidgets('narrow banner actions and dismissal survive widget recreation',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    int registrations = 0;
    Widget buildBanner() => MaterialApp(
          home: Scaffold(
            body: VideoOnlineServicesBanner(
              preferences: preferences,
              onRegister: () async {
                registrations++;
              },
              onOpenSettings: () async {},
            ),
          ),
        );
    await tester.pumpWidget(buildBanner());
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(t.video_online_services_setup_register));
    expect(registrations, 1);
    final TextButton dismiss = tester.widget<TextButton>(find.ancestor(
      of: find.text(t.video_online_services_setup_dismiss),
      matching: find.byType(TextButton),
    ));
    await tester.runAsync(() async {
      await (dismiss.onPressed! as Future<void> Function())();
    });
    await tester.pumpAndSettle();
    expect(find.text(t.video_online_services_setup_title), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(buildBanner());
    expect(find.text(t.video_online_services_setup_title), findsNothing);
  });

  testWidgets('dismissal updates every mounted video section immediately',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: Column(children: <Widget>[
        for (final String section in <String>['home', 'series'])
          VideoOnlineServicesBanner(
            key: ValueKey<String>(section),
            preferences: preferences,
            onRegister: () async {},
            onOpenSettings: () async {},
          ),
      ]),
    ))));
    expect(find.text(t.video_online_services_setup_title), findsNWidgets(2));
    await tester
        .runAsync(() => dismissVideoOnlineServicesReminder(preferences));
    await tester.pumpAndSettle();
    expect(find.text(t.video_online_services_setup_title), findsNothing);
  });

  testWidgets('returning from settings immediately hides configured reminder',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoOnlineServicesBanner(
          preferences: preferences,
          onRegister: () async {},
          onOpenSettings: () async {
            await preferences.setPref(kVideoAniDbUsernamePref, 'tester');
            await preferences.setPref(kVideoAniDbPasswordPref, 'password');
            await preferences.setPref(kVideoAniDbHashEnabledPref, true);
            await preferences.setJimakuApiKey('jimaku-key');
            await preferences.setVideoSubtitleOpenSubtitlesConfig(
              OpenSubtitlesConfig(apiKey: 'subtitle-key'),
            );
          },
        ),
      ),
    ));
    final FilledButton settings = tester.widget<FilledButton>(find.ancestor(
      of: find.text(t.video_online_services_setup_settings),
      matching: find.byType(FilledButton),
    ));
    await tester.runAsync(() async {
      await (settings.onPressed! as Future<void> Function())();
    });
    await tester.pumpAndSettle();
    expect(find.text(t.video_online_services_setup_title), findsNothing);
  });
}
