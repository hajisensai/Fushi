import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_capture.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;

/// 跨应用语音缓存（拍板 oqk37s3QFL）Dart 门面与原生通道的契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('test/cross_app_audio');
  final List<MethodCall> calls = <MethodCall>[];

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the production channel name matches the native registration', () {
    expect(
      CrossAppAudioCapture.kChannel.name,
      'app.fushi.reader/cross_app_audio',
    );
  });

  test('snapshot asks for the lookback window and parses the reply', () async {
    answer(
      (MethodCall call) async => <String, Object?>{
        'path': '/cache/cross_app_audio/lookup_9.pcm',
        'sampleRate': 48000,
        'channels': 1,
        'bitsPerSample': 16,
        'isFloat': false,
      },
    );
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    final CrossAppAudioSnapshot? s = await capture.snapshot();
    expect(calls.single.method, 'snapshot');
    expect(calls.single.arguments, <String, Object?>{
      'backMs': kCrossAppAudioLookbackMs,
    });
    expect(s!.pcmPath, '/cache/cross_app_audio/lookup_9.pcm');
  });

  test('not capturing (null reply) means no snapshot', () async {
    answer((MethodCall call) async => null);
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    expect(await capture.snapshot(), isNull);
  });

  test('missing native side degrades to unavailable, not a crash', () async {
    // 没装 mock handler：MissingPluginException。
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    expect(await capture.snapshot(), isNull);
    expect(await capture.status(), isFalse);
    expect(await capture.isSupported(), isFalse);
    final CrossAppAudioStartResult r = await capture.start();
    expect(r.running, isFalse);
    expect(r.error, 'missing_plugin');
  });

  test('other platforms never touch the channel', () async {
    answer((MethodCall call) async => fail('channel must not be called'));
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
      platformAvailable: false,
    );
    expect(await capture.snapshot(), isNull);
    expect((await capture.start()).error, 'unsupported');
    await capture.init();
    expect(calls, isEmpty);
  });

  test('start passes notification labels and reports refusal', () async {
    answer(
      (MethodCall call) async => <String, Object?>{
        'running': false,
        'error': 'denied',
      },
    );
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    final CrossAppAudioStartResult r = await capture.start(
      labels: const <String, String>{'notification': 'n', 'stop': 's'},
    );
    expect(calls.single.method, 'start');
    expect(calls.single.arguments, <String, Object?>{
      'labels': <String, String>{'notification': 'n', 'stop': 's'},
    });
    expect(r.running, isFalse);
    expect(r.error, 'denied');
    expect(capture.running.value, isFalse);
  });

  test('a successful start flips running; stop clears it', () async {
    answer(
      (MethodCall call) async =>
          call.method == 'start' ? <String, Object?>{'running': true} : null,
    );
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    expect((await capture.start()).running, isTrue);
    expect(capture.running.value, isTrue);
    await capture.stop();
    expect(capture.running.value, isFalse);
  });

  test('init reads current state and follows native onState pushes', () async {
    answer((MethodCall call) async => call.method == 'status' ? true : null);
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    await capture.init();
    expect(capture.running.value, isTrue);
    // 通知栏「停止」：原生推 onState{running:false}。
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('onState', <String, Object?>{'running': false}),
          ),
          (ByteData? _) {},
        );
    expect(capture.running.value, isFalse);
  });

  test('encodeAac sends 16-bit PCM and rejects float input', () async {
    answer((MethodCall call) async => true);
    final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
      channel,
    );
    final Uint8List pcm = Uint8List.fromList(<int>[1, 0, 2, 0]);
    final bool ok = await capture.encodeAac(
      GalAudioSlice(
        pcm: pcm,
        format: const PcmFormat(
          sampleRate: 48000,
          channels: 1,
          bitsPerSample: 16,
          isFloat: false,
        ),
      ),
      '/tmp/out.m4a',
    );
    expect(ok, isTrue);
    expect(calls.single.method, 'encodeAac');
    expect(calls.single.arguments, <String, Object?>{
      'pcm': pcm,
      'sampleRate': 48000,
      'channels': 1,
      'outputPath': '/tmp/out.m4a',
    });
    calls.clear();
    final bool floatOk = await capture.encodeAac(
      GalAudioSlice(
        pcm: Uint8List(8),
        format: const PcmFormat(
          sampleRate: 48000,
          channels: 2,
          bitsPerSample: 32,
          isFloat: true,
        ),
      ),
      '/tmp/out.m4a',
    );
    expect(floatOk, isFalse);
    expect(calls, isEmpty);
  });
}
