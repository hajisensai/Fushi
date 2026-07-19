import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/src/sync/texthooker_ws_client.dart';

void main() {
  test('window binding is app-level state and stop keeps binding by default',
      () async {
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    const ExternalWindowInfo window = ExternalWindowInfo(
      hwnd: 77,
      pid: 1234,
      title: 'Test Game',
    );

    await controller.bindWindow(window);
    expect(controller.state.boundWindow, window);
    expect(controller.state.gamePid, 1234);
    expect(
      controller.events.map((event) => event.code),
      contains('window.bound'),
    );

    await controller.stopCapture();
    expect(controller.state.phase, GalHookSessionPhase.idle);
    expect(controller.state.boundWindow, window);

    await controller.close();
    endpoints.dispose();
  });

  test('new external line is observed after the text ring buffer is full',
      () async {
    final TexthookerService service = TexthookerService.test();
    for (int i = 0; i < TexthookerService.maxLines; i++) {
      service.appendLine('line $i');
    }
    final ChangeNotifier endpoints = ChangeNotifier();
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: false,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );
    expect(controller.state.hasText, isTrue);

    service.appendLine(
      'newest',
      source: TexthookerLineSource.websocket,
      sourceLabel: 'ws://localhost:6677',
    );

    expect(service.entries, hasLength(TexthookerService.maxLines));
    expect(
      controller.events.map((event) => event.code),
      contains('text.external_line_received'),
    );

    await controller.close();
    endpoints.dispose();
  });

  test('captureAudioBytes asks paired voice even without a text timestamp',
      () async {
    final TexthookerService service = TexthookerService.test();
    final TexthookerLineEntry entry = service.appendLine('siglus line')!;
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => true,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) =>
          engine,
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    expect(await controller.launchGame(r'D:\anemoi\SiglusEngine.exe'), isTrue);
    final Uint8List? bytes = await controller.captureAudioBytes(
      lineId: entry.id,
      sentence: entry.text,
      outputExtension: 'aac',
    );

    expect(bytes, <int>[1, 2, 3, 4]);
    expect(engine.pairedTimestamps, <int>[0]);
    expect(
        service.entries.single.audioStatus, TexthookerLineAudioStatus.encoded);
    expect(service.entries.single.audioBackend, 'paired_voice_ogg');

    await controller.close();
    endpoints.dispose();
  });

  test('launchGame passes Luna PC hooks for manosaba Unity target', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('gal_manosaba_');
    final File exe = File('${dir.path}${Platform.pathSeparator}manosaba.exe');
    await exe.writeAsBytes(<int>[0], flush: true);
    final TexthookerService service = TexthookerService.test();
    final ChangeNotifier endpoints = ChangeNotifier();
    final _FakeEngineSource engine = _FakeEngineSource(
      pairedBytes: Uint8List(0),
    );
    bool? capturedLunaPcHooks;
    final GalHookSessionController controller = GalHookSessionController(
      textService: service,
      isWindows: true,
      exe32BitProbe: (_) async => false,
      injectorResolver: ({required bool is32Bit}) => 'injector.exe',
      engineSourceFactory: ({
        required int targetPid,
        required String? launchExe,
        required String injectorPath,
        required bool lunaPcHooks,
        int? lunaCodepage,
      }) {
        capturedLunaPcHooks = lunaPcHooks;
        return engine;
      },
      windowListLoader: () async => const <ExternalWindowInfo>[],
      windowPollAttempts: 1,
      endpointListenable: endpoints,
      endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
    );

    try {
      expect(await controller.launchGame(exe.path), isTrue);
      expect(capturedLunaPcHooks, isTrue);
      final GalHookEvent launch = controller.events.firstWhere(
        (GalHookEvent event) => event.code == 'game.launch_started',
      );
      expect(launch.details['lunaPcHooks'], isTrue);
      expect(launch.details['arch'], 'x64');
    } finally {
      await controller.close();
      endpoints.dispose();
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });
}

class _FakeEngineSource extends EngineHookGalAudioSource {
  _FakeEngineSource({required this.pairedBytes})
      : super(targetPid: 0, launchExe: 'fake.exe', injectorPath: 'fake.exe');

  final Uint8List pairedBytes;
  final List<int> pairedTimestamps = <int>[];

  @override
  int? get gamePid => 4242;

  @override
  Future<PcmFormat?> start() async {
    return const PcmFormat(
      sampleRate: 44100,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
    );
  }

  @override
  Future<Uint8List?> grabPairedVoiceBytes(
    int textTsMs, {
    required String outputExtension,
  }) async {
    pairedTimestamps.add(textTsMs);
    return pairedBytes;
  }

  @override
  Future<GalTextPoll?> pollText(int sinceSeq) async {
    return const GalTextPoll(count: 0, lines: <GalHookedLine>[]);
  }

  @override
  Future<void> stop() async {}
}
