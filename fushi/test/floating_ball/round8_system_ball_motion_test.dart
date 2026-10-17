import 'dart:async';
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

  Future<void> pumpHost(
    WidgetTester tester, {
    bool themeEink = false,
    Future<Object?> Function(MethodCall call)? systemReply,
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      FloatingBallChannel.channel,
      (MethodCall call) async {
        if (call.method == 'startSystemBall') {
          starts.add(call.arguments as Map<Object?, Object?>);
          return systemReply == null ? true : await systemReply(call);
        }
        if (call.method == 'takeSystemBallClosedByUser') {
          return systemReply == null ? false : await systemReply(call);
        }
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

  Future<void> expectSyncFinished(
    WidgetTester tester,
    Future<void> sync,
  ) async {
    bool finished = false;
    Object? failure;
    unawaited(
      sync.then<void>(
        (_) {
          finished = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          finished = true;
        },
      ),
    );
    for (int i = 0; i < 200 && !finished; ++i) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finished, isTrue, reason: 'Every gated host sync must finish');
    expect(failure, isNull);
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

  testWidgets(
    'labels ABA before asset preparation discards the stale false request',
    (WidgetTester tester) async {
      final Completer<bool> closedReply = Completer<bool>();
      bool holdNextClosed = false;
      bool closedReadEntered = false;
      await pumpHost(
        tester,
        systemReply: (MethodCall call) async {
          if (call.method == 'startSystemBall') return true;
          if (holdNextClosed) {
            holdNextClosed = false;
            closedReadEntered = true;
            return closedReply.future;
          }
          return false;
        },
      );
      try {
        await enableSystemBall(tester);
        await expectSyncFinished(tester, debugLatestSystemBallSync!);
        holdNextClosed = true;
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(false));
        await tester.pump();
        expect(closedReadEntered, isTrue);
        final Future<void> falseSync = debugLatestSystemBallSync!;
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(true));
        final Future<void> trueSync = debugLatestSystemBallSync!;
        closedReply.complete(false);
        await expectSyncFinished(tester, falseSync);
        await expectSyncFinished(tester, trueSync);
        expect(
          starts.map((Map<Object?, Object?> args) => args['showLabels']),
          <bool>[true, true],
          reason: 'Only the latest generation may reach native start',
        );
        expect(prefs.floatingBallShowLabels, isTrue);
      } finally {
        if (!closedReply.isCompleted) closedReply.complete(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'labels ABA while native start reply is pending resends the latest true',
    (WidgetTester tester) async {
      final Completer<bool> startReply = Completer<bool>();
      bool holdNextStart = false;
      await pumpHost(
        tester,
        systemReply: (MethodCall call) async {
          if (call.method == 'takeSystemBallClosedByUser') return false;
          if (holdNextStart) {
            holdNextStart = false;
            return startReply.future;
          }
          return true;
        },
      );
      try {
        await enableSystemBall(tester);
        await expectSyncFinished(tester, debugLatestSystemBallSync!);
        holdNextStart = true;
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(false));
        await expectStarts(tester, 2);
        final Future<void> falseSync = debugLatestSystemBallSync!;
        expect(starts.last['showLabels'], isFalse);
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(true));
        final Future<void> trueSync = debugLatestSystemBallSync!;
        startReply.complete(true);
        await expectSyncFinished(tester, falseSync);
        await expectSyncFinished(tester, trueSync);
        expect(
          starts.map((Map<Object?, Object?> args) => args['showLabels']),
          <bool>[true, false, true],
          reason:
              'An older response must not preserve the false native setting',
        );
        expect(prefs.floatingBallShowLabels, isTrue);
      } finally {
        if (!startReply.isCompleted) startReply.complete(true);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'repeat sync with the in-flight signature does not open a new generation',
    (WidgetTester tester) async {
      final Completer<bool> startReply = Completer<bool>();
      bool holdNextStart = false;
      await pumpHost(
        tester,
        systemReply: (MethodCall call) async {
          if (call.method == 'takeSystemBallClosedByUser') return false;
          if (holdNextStart) {
            holdNextStart = false;
            return startReply.future;
          }
          return true;
        },
      );
      try {
        await enableSystemBall(tester);
        await expectSyncFinished(tester, debugLatestSystemBallSync!);
        holdNextStart = true;
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(false));
        await expectStarts(tester, 2);
        final Future<void> inFlight = debugLatestSystemBallSync!;
        // 在途期间任何偏好写入都会再进同步；与在途目标同签名就不能再开一代
        // （重渲染图标 + 作废在途那代），否则频繁写偏好会一直起不了球。
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(false));
        await tester.pump();
        expect(
          debugLatestSystemBallSync,
          same(inFlight),
          reason: 'same in-flight target must be deduplicated',
        );
        startReply.complete(true);
        await expectSyncFinished(tester, inFlight);
        expect(
          starts.map((Map<Object?, Object?> args) => args['showLabels']),
          <bool>[true, false],
        );
        // 在途那代收尾后签名落为稳态：同配置再同步仍不重发。
        await tester.runAsync(() => prefs.setFloatingBallShowLabels(false));
        await tester.pump();
        expect(debugLatestSystemBallSync, same(inFlight));
        expect(starts, hasLength(2));
      } finally {
        if (!startReply.isCompleted) startReply.complete(true);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
