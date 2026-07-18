import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/process_audio_capture_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel('app.hibiki.reader/process_audio_capture');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('start sends the target process and ring-buffer duration', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'start');
      expect(
        call.arguments,
        <String, Object?>{'pid': 4242, 'bufferSeconds': 90},
      );
      return <String, Object?>{
        'ok': true,
        'sampleRate': 48000,
        'channels': 2,
      };
    });

    final ProcessAudioCaptureResult result =
        await ProcessAudioCaptureChannel.start(pid: 4242, bufferSeconds: 90);

    expect(result.ok, isTrue);
    expect(result.sampleRate, 48000);
    expect(result.channels, 2);
  });

  test('mark and exportAudio preserve occurrence and clip bounds', () async {
    final List<MethodCall> calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'mark') {
        return <String, Object?>{'ok': true, 'startFrame': 100};
      }
      return <String, Object?>{
        'ok': true,
        'path': r'C:\temp\line.mp3',
        'startFrame': 80,
        'endFrame': 280,
      };
    });

    final ProcessAudioCaptureResult marked =
        await ProcessAudioCaptureChannel.mark('line-7');
    final ProcessAudioCaptureResult exported =
        await ProcessAudioCaptureChannel.exportAudio(
      occurrenceId: 'line-7',
      outputPath: r'C:\temp\line.mp3',
      preRollMs: 300,
      maxClipMs: 12000,
    );

    expect(marked.startFrame, 100);
    expect(exported.path, r'C:\temp\line.mp3');
    expect(exported.startFrame, 80);
    expect(exported.endFrame, 280);
    expect(calls[0].arguments, <String, Object?>{'occurrenceId': 'line-7'});
    expect(calls[1].arguments, <String, Object?>{
      'occurrenceId': 'line-7',
      'outputPath': r'C:\temp\line.mp3',
      'preRollMs': 300,
      'maxClipMs': 12000,
    });
  });

  test('status decodes native buffer state', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'status');
      return <String, Object?>{
        'running': true,
        'pid': 99,
        'sampleRate': 44100,
        'channels': 2,
        'bufferedSeconds': 18,
      };
    });

    final ProcessAudioCaptureStatus status =
        await ProcessAudioCaptureChannel.status();

    expect(status.running, isTrue);
    expect(status.pid, 99);
    expect(status.sampleRate, 44100);
    expect(status.channels, 2);
    expect(status.bufferedSeconds, 18);
  });

  test('platform and missing-plugin failures become typed failures', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      throw PlatformException(code: 'capture_failed', message: 'expired');
    });
    expect((await ProcessAudioCaptureChannel.mark('old')).error, 'expired');

    messenger.setMockMethodCallHandler(channel, null);
    expect((await ProcessAudioCaptureChannel.stop()).ok, isFalse);
    expect(
      (await ProcessAudioCaptureChannel.status()).error,
      'process audio capture unavailable',
    );
  });
}
