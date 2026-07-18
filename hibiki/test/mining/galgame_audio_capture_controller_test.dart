import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_capture_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel audioChannel =
      MethodChannel('app.hibiki.reader/process_audio_capture');
  const MethodChannel windowChannel =
      MethodChannel('app.hibiki.reader/window_capture');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final GalgameAudioCaptureController controller =
      GalgameAudioCaptureController.instance;
  final Uint8List screenshotBytes =
      Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  const ExternalWindowInfo game = ExternalWindowInfo(
    hwnd: 10,
    pid: 4242,
    title: 'Visual novel',
    executablePath: r'C:\Games\vn.exe',
  );

  setUp(() {
    controller.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = true;
    messenger.setMockMethodCallHandler(windowChannel, (MethodCall call) async {
      return <String, Object?>{'pngBytes': screenshotBytes};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(audioChannel, null);
    messenger.setMockMethodCallHandler(windowChannel, null);
    controller.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = null;
  });

  test('exports audio and the bound game window for one occurrence', () async {
    final List<MethodCall> audioCalls = <MethodCall>[];
    final List<MethodCall> windowCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(audioChannel, (MethodCall call) async {
      audioCalls.add(call);
      switch (call.method) {
        case 'start':
        case 'mark':
          return <String, Object?>{'ok': true};
        case 'exportAudio':
          final Map<Object?, Object?> args =
              call.arguments! as Map<Object?, Object?>;
          final String outputPath = args['outputPath']! as String;
          await File(outputPath).writeAsBytes(<int>[1, 2, 3], flush: true);
          return <String, Object?>{'ok': true, 'path': outputPath};
      }
      return <String, Object?>{'ok': true};
    });
    messenger.setMockMethodCallHandler(windowChannel, (MethodCall call) async {
      windowCalls.add(call);
      return <String, Object?>{'pngBytes': screenshotBytes};
    });

    expect(await controller.start(game), isTrue);
    final String first = controller.markClipboardOccurrence()!;
    final String second = controller.markClipboardOccurrence()!;
    expect(second, isNot(first));

    final GalgameMiningMedia media = await controller.exportOccurrence(
      first,
      postRoll: Duration.zero,
    );

    final MethodCall exportCall = audioCalls
        .singleWhere((MethodCall call) => call.method == 'exportAudio');
    final Map<Object?, Object?> exportArgs =
        exportCall.arguments! as Map<Object?, Object?>;
    expect(exportArgs['occurrenceId'], first);
    expect(exportArgs['preRollMs'], 450);
    expect(exportArgs['maxClipMs'], 30000);
    expect(exportArgs['outputPath'], endsWith('.mp3'));
    expect(media.audioPath, exportArgs['outputPath']);
    expect(await File(media.audioPath).exists(), isTrue);
    expect(await File(media.picturePath).readAsBytes(), screenshotBytes);
    expect(media.picturePath, endsWith('.png'));

    expect(windowCalls, hasLength(2));
    for (final MethodCall captureCall in windowCalls) {
      expect(captureCall.method, 'captureWindow');
      expect(
        captureCall.arguments,
        <String, Object?>{'hwnd': game.hwnd},
      );
    }

    await media.dispose();
    expect(await File(media.audioPath).exists(), isFalse);
    expect(await File(media.picturePath).exists(), isFalse);
  });

  test('a rejected marker prevents later media export', () async {
    int exportCalls = 0;
    int captureCalls = 0;
    messenger.setMockMethodCallHandler(audioChannel, (MethodCall call) async {
      if (call.method == 'start') return <String, Object?>{'ok': true};
      if (call.method == 'mark') {
        return <String, Object?>{'ok': false, 'error': 'capture stopped'};
      }
      if (call.method == 'exportAudio') exportCalls++;
      return <String, Object?>{'ok': true};
    });
    messenger.setMockMethodCallHandler(windowChannel, (MethodCall call) async {
      captureCalls++;
      return <String, Object?>{'pngBytes': screenshotBytes};
    });

    expect(await controller.start(game), isTrue);
    final String occurrence = controller.markClipboardOccurrence()!;

    await expectLater(
      controller.exportOccurrence(occurrence, postRoll: Duration.zero),
      throwsA(
        isA<GalgameAudioCaptureException>().having(
          (GalgameAudioCaptureException e) => e.message,
          'message',
          'capture stopped',
        ),
      ),
    );
    expect(exportCalls, 0);
    expect(captureCalls, 1);
  });

  test('uses the actual WAV path returned by the native fallback', () async {
    final File wav = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'hibiki-galgame-fallback-${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    messenger.setMockMethodCallHandler(audioChannel, (MethodCall call) async {
      if (call.method == 'start' || call.method == 'mark') {
        return <String, Object?>{'ok': true};
      }
      if (call.method == 'exportAudio') {
        await wav.writeAsBytes(<int>[4, 5, 6], flush: true);
        return <String, Object?>{'ok': true, 'path': wav.path};
      }
      return <String, Object?>{'ok': true};
    });

    expect(await controller.start(game), isTrue);
    final String occurrence = controller.markClipboardOccurrence()!;
    final GalgameMiningMedia media = await controller.exportOccurrence(
      occurrence,
      postRoll: Duration.zero,
    );

    expect(media.audioPath, wav.path);
    await media.dispose();
  });

  test('native expiration is surfaced instead of returning empty media',
      () async {
    messenger.setMockMethodCallHandler(audioChannel, (MethodCall call) async {
      if (call.method == 'start' || call.method == 'mark') {
        return <String, Object?>{'ok': true};
      }
      if (call.method == 'exportAudio') {
        return <String, Object?>{
          'ok': false,
          'error': 'audio marker has expired',
        };
      }
      return <String, Object?>{'ok': true};
    });

    expect(await controller.start(game), isTrue);
    final String occurrence = controller.markClipboardOccurrence()!;

    await expectLater(
      controller.exportOccurrence(occurrence, postRoll: Duration.zero),
      throwsA(
        isA<GalgameAudioCaptureException>().having(
          (GalgameAudioCaptureException e) => e.message,
          'message',
          'audio marker has expired',
        ),
      ),
    );
  });

  test('picture failure aborts export and removes completed audio', () async {
    String? outputPath;
    messenger.setMockMethodCallHandler(audioChannel, (MethodCall call) async {
      if (call.method == 'start' || call.method == 'mark') {
        return <String, Object?>{'ok': true};
      }
      if (call.method == 'exportAudio') {
        final Map<Object?, Object?> args =
            call.arguments! as Map<Object?, Object?>;
        outputPath = args['outputPath']! as String;
        await File(outputPath!).writeAsBytes(<int>[7, 8, 9], flush: true);
        return <String, Object?>{'ok': true, 'path': outputPath};
      }
      return <String, Object?>{'ok': true};
    });
    messenger.setMockMethodCallHandler(windowChannel, (MethodCall call) async {
      return <String, Object?>{'error': 'window closed'};
    });

    expect(await controller.start(game), isTrue);
    final String occurrence = controller.markClipboardOccurrence()!;

    await expectLater(
      controller.exportOccurrence(occurrence, postRoll: Duration.zero),
      throwsA(
        isA<GalgamePictureCaptureException>().having(
          (GalgamePictureCaptureException e) => e.message,
          'message',
          'window closed',
        ),
      ),
    );
    expect(outputPath, isNotNull);
    expect(await File(outputPath!).exists(), isFalse);
  });
}
