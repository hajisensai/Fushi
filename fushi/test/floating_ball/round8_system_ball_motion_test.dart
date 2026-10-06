import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_floating_ball.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

class _MotionAppModel extends AppModel {
  _MotionAppModel() : super(testPlatformServices());

  bool eink = false;

  @override
  bool get isInitialised => true;

  @override
  bool get einkMode => eink;
}

void main() {
  late FushiDatabase database;
  late PreferencesRepository prefs;
  late _MotionAppModel model;
  late Directory store;
  late ValueNotifier<bool> reduced;
  late List<Map<Object?, Object?>> starts;
  late SettingsContext settingsContext;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    FloatingBallSceneRegistry.instance.debugReset();
    FloatingBallChannel.debugResetHandler();
    debugDesktopSystemBallPlatformOverride = true;
    debugLatestSystemBallSync = null;
    starts = <Map<Object?, Object?>>[];
    reduced = ValueNotifier<bool>(false);
    database = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    prefs = PreferencesRepository(database);
    await prefs.loadFromDb();
    store = Directory.systemTemp.createTempSync('fushi_ball_motion_');
    model = _MotionAppModel()
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: store)
      ..wireDatabaseForTesting(database);
  });

  tearDown(() async {
    debugDesktopSystemBallPlatformOverride = null;
    FloatingBallChannel.debugResetHandler();
    reduced.dispose();
    await database.close();
    if (store.existsSync()) store.deleteSync(recursive: true);
  });

  Future<void> pumpHost(WidgetTester tester, {bool themeEink = false}) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      FloatingBallChannel.channel,
      (MethodCall call) async {
        if (call.method == 'startSystemBall') {
          starts.add(call.arguments as Map<Object?, Object?>);
          return true;
        }
        if (call.method == 'takeSystemBallClosedByUser') return false;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        FloatingBallChannel.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => model)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: model.navigatorKey,
            theme: ThemeData(
              extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(themeEink)],
            ),
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? child) {
                settingsContext = SettingsContext(
                  context: context,
                  appModel: model,
                  ref: ref,
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                return const Scaffold(body: SizedBox());
              },
            ),
            builder: (BuildContext context, Widget? child) =>
                ValueListenableBuilder<bool>(
                  valueListenable: reduced,
                  builder:
                      (BuildContext context, bool disabled, Widget? host) =>
                          MediaQuery(
                            data: MediaQuery.of(
                              context,
                            ).copyWith(disableAnimations: disabled),
                            child: host!,
                          ),
                  child: Stack(
                    children: <Widget>[child!, const AppFloatingBallHost()],
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Native assets use real async PNG rendering. Alternate real work with
  // fake-clock pumps so neither async zone can strand the host's continuation.
  Future<void> expectStarts(WidgetTester tester, int count) async {
    for (int i = 0; i < 200 && starts.length < count; ++i) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(starts, hasLength(count));
    await tester.pump();
  }

  Future<void> enableSystemBall(WidgetTester tester) async {
    await tester.runAsync(() => prefs.setFloatingBallSystem(true));
    await expectStarts(tester, 1);
  }

  for (final String mode in <String>['system', 'appEink', 'themeEink']) {
    testWidgets('HBK051 initial $mode reaches the real native payload', (
      WidgetTester tester,
    ) async {
      reduced.value = mode == 'system';
      model.eink = mode == 'appEink';
      await pumpHost(tester, themeEink: mode == 'themeEink');
      await enableSystemBall(tester);
      expect(starts.single['animate'], isFalse);
      expect(starts.single['ballImage'], isA<Uint8List>());
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('HBK051 motion-only changes resync the existing host both ways', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    await enableSystemBall(tester);
    final Object originalHost = tester.state(find.byType(AppFloatingBallHost));
    final Object? originalColors = starts.single['colors'];
    expect(starts.single['animate'], isTrue);

    reduced.value = true;
    await tester.pump();
    await expectStarts(tester, 2);
    expect(tester.state(find.byType(AppFloatingBallHost)), same(originalHost));
    expect(starts.last['animate'], isFalse);
    expect(starts.last['colors'], equals(originalColors));

    reduced.value = false;
    await tester.pump();
    await expectStarts(tester, 3);
    expect(tester.state(find.byType(AppFloatingBallHost)), same(originalHost));
    expect(starts.last['animate'], isTrue);
    expect(starts.last['colors'], equals(originalColors));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'label setting updates both existing balls without changing actions',
    (WidgetTester tester) async {
      await pumpHost(tester);
      await enableSystemBall(tester);
      final SettingsSwitchItem setting = buildFloatingBallDestination().sections
          .expand((SettingsSection section) => section.items)
          .whereType<SettingsSwitchItem>()
          .singleWhere(
            (SettingsSwitchItem item) => item.id == 'floating_ball.show_labels',
          );
      final Object originalHost = tester.state(
        find.byType(AppFloatingBallHost),
      );
      final Object? originalLabels = starts.single['labels'];
      final Object? originalActions = starts.single['actions'];
      expect(setting.defaultValue, isTrue);
      expect(setting.value(settingsContext), isTrue);
      expect(starts.single['showLabels'], isTrue);
      expect(
        tester
            .widget<ReaderFloatingBall>(find.byType(ReaderFloatingBall))
            .showLabels,
        isTrue,
      );

      for (final bool shown in <bool>[false, true]) {
        final int count = starts.length;
        await tester.runAsync(
          () async => setting.onChanged(settingsContext, shown),
        );
        await expectStarts(tester, count + 1);
        expect(setting.value(settingsContext), shown);
        expect(
          tester.state(find.byType(AppFloatingBallHost)),
          same(originalHost),
        );
        expect(
          tester
              .widget<ReaderFloatingBall>(find.byType(ReaderFloatingBall))
              .showLabels,
          shown,
        );
        expect(starts.last['showLabels'], shown);
        expect(
          starts.last['labels'],
          equals(originalLabels),
          reason: 'Native tooltip/accessibility names remain available',
        );
        expect(starts.last['actions'], equals(originalActions));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
