import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_game.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

// The hook engine and OS channel are boundaries. Schema callbacks, AppModel,
// persisted preferences and overlay controller are production implementations.
// This verifies live commands and later show payloads, not native text pixels.
class _TextOnlyEngine extends EngineHookGalAudioSource {
  _TextOnlyEngine()
    : super(targetPid: 0, launchExe: null, injectorPath: 'fake.exe');

  @override
  Future<PcmFormat?> start() async => const PcmFormat(
    sampleRate: 44100,
    channels: 1,
    bitsPerSample: 16,
    isFloat: false,
  );

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async =>
      const GalTextPoll(count: 0, lines: <GalHookedLine>[]);

  @override
  Future<bool> selectTextThread(int? threadId) async => true;

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
    int? textEventId,
    String? resourceId,
    bool allowLatestSessionFallback = true,
  }) async => null;

  @override
  Future<void> stop() async {}
}

Future<void> _waitUntil(bool Function() done) async {
  for (int i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'Production overlay did not finish showing.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.fushi.reader/gal_hook_text');
  const MethodChannel paths = MethodChannel('plugins.flutter.io/path_provider');
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel model;
  late Directory scratch;
  late List<MethodCall> calls;
  late List<({bool requested, bool persisted})> liveWrites;
  late bool showing;
  late int sequence;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    scratch = Directory.systemTemp.createTempSync('fushi_hook_label_pref_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    // Keep this test on the text overlay route; no injected game lookup surface.
    await prefs.setPref('gal_hook_ingame_lookup_enabled', false);
    model = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: scratch);
    calls = <MethodCall>[];
    liveWrites = <({bool requested, bool persisted})>[];
    showing = false;
    sequence = 0;
    GalHookTextOverlayChannel.platformOverride = true;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => scratch.path);
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'setToolbarLabels') {
        liveWrites.add((
          requested:
              (call.arguments as Map<Object?, Object?>)['enabled'] as bool,
          persisted: PrefCodec.decode(
            (await db.getPref('gal_hook_toolbar_labels'))!,
            true,
          ),
        ));
      }
      if (call.method == 'show') {
        showing = true;
        return true;
      }
      if (call.method == 'hide') showing = false;
      if (call.method == 'isShowing') return showing;
      if (call.method.startsWith('galLookup')) {
        return <String, Object?>{
          'ok': true,
          'requestSeq': ++sequence,
          'appliedSeq': sequence,
        };
      }
      return null;
    });
  });

  tearDown(() async {
    GalHookTextOverlayChannel.clearEventHandlers();
    GalHookTextOverlayChannel.platformOverride = null;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(paths, null);
    prefs.dispose();
    await db.close();
    scratch.deleteSync(recursive: true);
  });

  testWidgets('schema toolbar labels persist before each live native update', (
    WidgetTester tester,
  ) async {
    late SettingsContext settingsContext;
    int refreshes = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? child) {
              settingsContext = SettingsContext(
                context: context,
                appModel: model,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () => refreshes++,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final SettingsSwitchItem setting = buildGameDestination().sections
        .expand((SettingsSection section) => section.items)
        .whereType<SettingsSwitchItem>()
        .singleWhere(
          (SettingsSwitchItem item) =>
              item.id == 'game.gal_hook_toolbar_labels',
        );
    expect(setting.value(settingsContext), isTrue);
    for (final bool enabled in <bool>[false, true]) {
      await tester.runAsync(() async {
        await setting.onChanged(settingsContext, enabled);
      });
      expect(setting.value(settingsContext), enabled);
    }
    expect(liveWrites, <({bool requested, bool persisted})>[
      (requested: false, persisted: false),
      (requested: true, persisted: true),
    ]);
    expect(calls.map((MethodCall call) => call.method), <String>[
      'setToolbarLabels',
      'setToolbarLabels',
    ]);
    expect(refreshes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'new hook overlay sessions read persisted toolbar label preference',
    () async {
      List<Object?>? originalLabels;
      List<Object?>? originalTooltips;
      for (final bool enabled in <bool>[false, true]) {
        await prefs.setGalHookToolbarLabels(enabled);
        final TexthookerService textService = TexthookerService.test();
        final GalHookSessionController session = GalHookSessionController(
          textService: textService,
          isWindows: true,
          targetWow64Probe: (_) async => false,
          injectorResolver: ({required bool is32Bit}) async => 'fake.exe',
          engineSourceFactory:
              ({
                required int targetPid,
                required String? launchExe,
                required String injectorPath,
                required bool lunaPcHooks,
                int? lunaCodepage,
                List<String> launchArguments = const <String>[],
                String launchWorkdir = '',
                GalJapaneseLocaleMode japaneseLocaleMode =
                    kGalDefaultJapaneseLocaleMode,
                String? contentLanguage,
              }) => _TextOnlyEngine(),
          endpointStatusLoader: () => const [],
        );
        final GalHookTextOverlayController controller =
            GalHookTextOverlayController.test(session: session);
        try {
          calls.clear();
          await controller.start(appModel: model);
          await session.startAttachedCapture(
            const ExternalWindowInfo(hwnd: 77, pid: 1234, title: 'Test game'),
          );
          final TexthookerLineEntry line = textService.appendLine(
            '検証用の台詞',
            source: TexthookerLineSource.websocket,
          )!;
          await _waitUntil(() => controller.displayedLineId == line.id);
          expect(controller.isVisible, isTrue);
          final MethodCall show = calls.singleWhere(
            (MethodCall call) => call.method == 'show',
          );
          final Map<Object?, Object?> payload =
              show.arguments as Map<Object?, Object?>;
          expect(payload['toolbarLabels'], enabled);
          final List<Object?> labels = (payload['slotLabels'] as List)
              .cast<Object?>();
          final List<Object?> tooltips = (payload['slotTooltips'] as List)
              .cast<Object?>();
          expect(labels, isNotEmpty);
          expect(tooltips, hasLength(labels.length));
          originalLabels ??= labels;
          originalTooltips ??= tooltips;
          expect(labels, originalLabels);
          expect(
            tooltips,
            originalTooltips,
            reason: 'Hiding visible labels must keep native action names.',
          );
        } finally {
          await controller.stopForTesting();
          await session.close();
        }
      }
    },
  );
}
