import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_capture_controller.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('app.hibiki.reader/process_audio_capture');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final GalgameAudioCaptureController controller =
      GalgameAudioCaptureController.instance;
  const ExternalWindowInfo game = ExternalWindowInfo(
    hwnd: 10,
    pid: 4242,
    title: 'Visual novel',
    executablePath: r'C:\Games\vn.exe',
  );

  setUp(() {
    controller.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = true;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    controller.debugReset();
    GalgameAudioCaptureController.debugIsSupportedOverride = null;
  });

  test('creates unique markers and exports the requested occurrence', () async {
    final List<MethodCall> calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'start':
        case 'mark':
          return <String, Object?>{'ok': true};
        case 'exportWav':
          final Map<Object?, Object?> args =
              call.arguments! as Map<Object?, Object?>;
          return <String, Object?>{
            'ok': true,
            'path': args['outputPath']! as String,
          };
      }
      return <String, Object?>{'ok': true};
    });

    expect(await controller.start(game), isTrue);
    final String first = controller.markClipboardOccurrence()!;
    final String second = controller.markClipboardOccurrence()!;
    expect(second, isNot(first));

    final GalgameAudioClip clip = await controller.exportOccurrence(
      first,
      postRoll: Duration.zero,
    );

    final MethodCall exportCall =
        calls.singleWhere((MethodCall call) => call.method == 'exportWav');
    final Map<Object?, Object?> exportArgs =
        exportCall.arguments! as Map<Object?, Object?>;
    expect(exportArgs['occurrenceId'], first);
    expect(exportArgs['preRollMs'], 450);
    expect(exportArgs['maxClipMs'], 30000);
    expect(clip.path, exportArgs['outputPath']);
  });

  test('a rejected marker prevents a later export', () async {
    int exportCalls = 0;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'start') return <String, Object?>{'ok': true};
      if (call.method == 'mark') {
        return <String, Object?>{'ok': false, 'error': 'capture stopped'};
      }
      if (call.method == 'exportWav') exportCalls++;
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
          'capture stopped',
        ),
      ),
    );
    expect(exportCalls, 0);
  });

  test('native expiration is surfaced instead of returning an empty clip',
      () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'start' || call.method == 'mark') {
        return <String, Object?>{'ok': true};
      }
      if (call.method == 'exportWav') {
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
}
