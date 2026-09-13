import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';

class _Process implements Process {
  final StreamController<List<int>> output = StreamController<List<int>>();
  final StreamController<List<int>> errors = StreamController<List<int>>();
  final Completer<int> exited = Completer<int>();
  bool killed = false;
  @override
  int get pid => 9876;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  IOSink get stdin => throw UnsupportedError('No stdin used');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exited.isCompleted) exited.complete(0);
    return true;
  }

  Future<void> send(String text) async {
    output.add(text.codeUnits);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> dispose() async {
    await output.close();
    await errors.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.fushi.reader/voice_hook');
  const Duration budget = Duration(milliseconds: 150);
  late Directory directory;
  late _Process process;
  late EngineHookGalAudioSource source;
  late Completer<void> started;
  late int opens;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('fushi_launcher_wait_');
    await File('${directory.path}/injector.exe').writeAsBytes(<int>[0]);
    await File('${directory.path}/game.exe').writeAsBytes(<int>[0]);
  });
  tearDownAll(() => directory.delete(recursive: true));
  setUp(() {
    process = _Process();
    started = Completer<void>();
    opens = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          switch (call.method) {
            case 'open':
              opens++;
              expect(call.arguments, <String, Object?>{'pid': 3333});
              return <String, Object?>{'ok': true};
            case 'requestNativeLoopbackPolicy':
              return <String, Object?>{
                'nativeLoopbackRequested': 0,
                'nativeLoopbackRequestSeq': 1,
                'nativeLoopbackState': 0,
                'nativeLoopbackAppliedSeq': 1,
              };
            case 'status':
              return <String, Object?>{
                'hooked': true,
                'textHooked': true,
                'audioHooksReady': true,
                'ready': false,
              };
          }
          return null;
        });
  });
  EngineHookGalAudioSource create({bool attach = false}) {
    return source = EngineHookGalAudioSource(
      launchExe: attach ? null : '${directory.path}/game.exe',
      targetPid: attach ? 3333 : 0,
      injectorPath: '${directory.path}/injector.exe',
      japaneseLocaleMode: GalJapaneseLocaleMode.off,
      capabilitiesProbe: (_) async => GalHookCapabilityProbeResult.supported,
      processStarter: (_, __) async {
        started.complete();
        return process;
      },
      readyTimeout: budget,
      pollInterval: Duration.zero,
    );
  }

  tearDown(() async {
    await source.stop();
    await process.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'interactive menu outlives handshake budget then game receives fresh budget',
    () async {
      final Future<PcmFormat?> result = create().start();
      await started.future;
      await process.send(
        'LAUNCH pid=1111 arch=x86 role=launcher locale=1 wait=launcher\n',
      );
      await Future<void>.delayed(budget * 2);
      expect(process.killed, isFalse);
      expect(opens, 0);
      await process.send('LAUNCH pid=3333 arch=x86 role=game locale=1\n');
      await Future<void>.delayed(budget ~/ 3);
      await process.send('OK hooked pid=3333 mode=launch\n');
      expect(await result, isNull);
      expect(opens, 1);
      expect(source.gameLaunchConfirmed, isTrue);
      expect(source.launchedPid, 3333);
      expect(process.killed, isFalse);
    },
  );

  for (final String record in <String>[
    'LAUNCH pid=1111 arch=x86\n',
    'LAUNCH pid=1111 arch=x86 role=launcher\n',
    'LAUNCH pid=1111 arch=x86 role=unknown wait=launcher\n',
    'LAUNCH pid=1111 arch=x86 role=game role=launcher wait=launcher\n',
    'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher wait=launcher\n',
    'LAUNCH pid=1111 arch=x86 role=game locale=1\n',
  ]) {
    test(
      'unknown, old and direct-game records retain deadline: $record',
      () async {
        final Future<PcmFormat?> result = create().start();
        await started.future;
        await process.send(record);
        expect(await result, isNull);
        expect(process.killed, isTrue);
        expect(opens, 0);
        expect(source.lastFailure.failure, GalHookInjectorFailure.readyTimeout);
      },
    );
  }

  test('attach cannot adopt an interactive-launch record', () async {
    final Future<PcmFormat?> result = create(attach: true).start();
    await started.future;
    await process.send(
      'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n',
    );
    expect(await result, isNull);
    expect(process.killed, isTrue);
    expect(opens, 0);
  });

  test('game deadline cannot be renewed or reverted to menu waiting', () async {
    final Future<PcmFormat?> result = create().start();
    await started.future;
    await process.send(
      'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n',
    );
    await process.send('LAUNCH pid=3333 arch=x86 role=game\n');
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(budget ~/ 3);
      await process.send(
        'LAUNCH pid=3333 arch=x86 role=game\n'
        'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n',
      );
    }
    expect(await result, isNull);
    expect(process.killed, isTrue);
    expect(opens, 0);
  });

  test(
    'helper exit ends menu wait even if inherited stdout remains open',
    () async {
      final Future<PcmFormat?> result = create().start();
      await started.future;
      await process.send(
        'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n',
      );
      process.exited.complete(1);
      expect(await result.timeout(const Duration(seconds: 2)), isNull);
      expect(source.lastFailure.exitCode, 1);
      expect(opens, 0);
    },
  );

  test('stop cancels menu wait and ignores a late game record', () async {
    final Future<PcmFormat?> result = create().start();
    await started.future;
    await process.send(
      'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n',
    );
    await source.stop();
    await process.send(
      'LAUNCH pid=3333 arch=x86 role=game\nOK hooked pid=3333\n',
    );
    expect(await result.timeout(const Duration(seconds: 2)), isNull);
    expect(process.killed, isTrue);
    expect(opens, 0);
  });

  test('hooked launcher without a game transition is rejected', () async {
    final Future<PcmFormat?> result = create().start();
    await started.future;
    await process.send(
      'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n'
      'OK hooked pid=1111\n',
    );
    expect(await result, isNull);
    expect(opens, 0);
    expect(source.gameLaunchConfirmed, isFalse);
  });

  test('EOF cannot accept an OK record while still waiting for game', () async {
    final Future<PcmFormat?> result = create().start();
    await started.future;
    await process.send(
      'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n'
      'LAUNCH pid=3333 arch=x86\n'
      'OK hooked pid=3333',
    );
    await process.output.close();
    expect(await result, isNull);
    expect(opens, 0);
    expect(source.gameLaunchConfirmed, isFalse);
  });

  test(
    'game confirmation is monotonic within and across output chunks',
    () async {
      final Future<PcmFormat?> result = create().start();
      await started.future;
      await process.send(
        'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n'
        'LAUNCH pid=3333 arch=x86 role=game\n'
        'LAUNCH pid=1111 arch=x86 role=launcher wait=launcher\n',
      );
      expect(source.gameLaunchConfirmed, isTrue);
      expect(source.launchedPid, 3333);
      await process.send('LAUNCH pid=1111 arch=x86\n');
      expect(source.gameLaunchConfirmed, isTrue);
      expect(source.launchedPid, 3333);
      await process.send('OK hooked pid=3333\n');
      expect(await result, isNull);
      expect(opens, 1);
    },
  );
}
