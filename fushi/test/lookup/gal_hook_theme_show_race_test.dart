import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

import '../helpers/test_platform_services.dart';

// HBK-AUDIT-047 regression: only synthetic text and a mock MethodChannel are used.
// The delayed show response exposes the real controller's creation boundary;
// no game, native overlay window, audio capture, or user database is opened.
class _SyntheticEngine extends EngineHookGalAudioSource {
  _SyntheticEngine()
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

Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'synthetic overlay did not reach the gate');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'theme change during show reaches the newly visible native toolbar',
    () async {
      const MethodChannel channel = MethodChannel(
        'app.fushi.reader/gal_hook_text',
      );
      final Completer<bool> showGate = Completer<bool>();
      final List<MethodCall> calls = <MethodCall>[];
      int requestSeq = 0;
      bool nativeShowing = false;
      int? nativeToolbarColor;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            if (call.method == 'show') {
              nativeToolbarColor =
                  (call.arguments as Map<Object?, Object?>)['toolbarBgColor']
                      as int;
              final bool shown = await showGate.future;
              nativeShowing = shown;
              return shown;
            }
            if (call.method == 'updateStyle') {
              nativeToolbarColor =
                  (call.arguments as Map<Object?, Object?>)['toolbarBgColor']
                      as int;
            }
            if (call.method == 'hide') nativeShowing = false;
            if (call.method == 'isShowing') return nativeShowing;
            if (call.method.startsWith('galLookup')) {
              return <String, Object?>{
                'ok': true,
                'requestSeq': ++requestSeq,
                'appliedSeq': requestSeq,
              };
            }
            return null;
          });
      GalHookTextOverlayChannel.platformOverride = true;
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
            }) => _SyntheticEngine(),
        endpointStatusLoader: () => const [],
      );
      final GalHookTextOverlayController controller =
          GalHookTextOverlayController.test(
            session: session,
            preferenceReader: (String key, {required Object? defaultValue}) =>
                defaultValue,
            preferenceWriter: (String key, Object? value) async {},
          );
      addTearDown(() async {
        if (!showGate.isCompleted) showGate.complete(false);
        await controller.stopForTesting();
        await session.close();
        GalHookTextOverlayChannel.platformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final ThemeData before = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final ThemeData after = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.orange,
          brightness: Brightness.dark,
        ),
      );
      controller.applyTheme(before);
      await controller.start(appModel: AppModel(testPlatformServices()));
      await session.startAttachedCapture(
        const ExternalWindowInfo(hwnd: 77, pid: 1234, title: 'Synthetic game'),
      );
      textService.appendLine('合成テキスト', source: TexthookerLineSource.websocket);
      await _until(() => calls.any((MethodCall c) => c.method == 'show'));
      expect(controller.isVisible, isFalse);
      expect(nativeToolbarColor, galHookToolbarPalette(before).toolbarBgColor);

      controller.applyTheme(after);
      showGate.complete(true);
      await _until(() => controller.isVisible);
      // This is the next ordinary theme build after the window is visible. A
      // desired-palette cache must not mistake it for a successfully sent one.
      controller.applyTheme(after);
      await Future<void>.delayed(Duration.zero);

      expect(
        nativeToolbarColor,
        galHookToolbarPalette(after).toolbarBgColor,
        reason:
            'show completed with the old palette; the theme changed while '
            '_visible was false and no current palette was reconciled afterward',
      );
    },
  );
}
