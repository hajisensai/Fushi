import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_capture.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart'
    show GalAudioSlice, LoopbackGalAudioSource;

import 'fake_loopback_native.dart';

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
    expect(
      (s! as CrossAppAudioFileSnapshot).pcmPath,
      '/cache/cross_app_audio/lookup_9.pcm',
    );
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

  // 拍板 design-cross-app-audio-desktop：Windows 复用 galgame 的系统混音 loopback，两边
  // 各持一张租约，任何一方停都不能把另一方的环停掉。
  group('desktop (Windows loopback)', () {
    const MethodChannel loopback = MethodChannel('test/audio_loopback');
    late FakeLoopbackNative native;

    setUp(() {
      native = FakeLoopbackNative(loopback)..install();
    });

    tearDown(() => native.uninstall());

    CrossAppAudioCapture desktopCapture() => CrossAppAudioCapture.forTesting(
      channel,
      desktopLoopbackChannel: loopback,
    );

    test(
      'start holds its own lease; stop hands back exactly that one',
      () async {
        answer(
          (MethodCall call) async => fail('android channel must stay idle'),
        );
        final CrossAppAudioCapture capture = desktopCapture();
        expect(capture.isDesktop, isTrue);
        expect(await capture.isSupported(), isTrue);
        expect((await capture.start()).running, isTrue);
        expect(capture.running.value, isTrue);
        expect(await capture.status(), isTrue);
        // 重复 start 不再要第二张租约。
        expect((await capture.start()).running, isTrue);
        expect(native.leases, hasLength(1));
        await capture.stop();
        expect(capture.running.value, isFalse);
        expect(native.running, isFalse);
        final MethodCall stop = native.calls.lastWhere(
          (MethodCall c) => c.method == 'stop',
        );
        expect(stop.arguments, <String, Object?>{'lease': 1});
        expect(calls, isEmpty);
      },
    );

    test(
      'a galgame session stopping leaves the cross-app ring running',
      () async {
        final CrossAppAudioCapture capture = desktopCapture();
        final LoopbackGalAudioSource galgame = LoopbackGalAudioSource(
          channel: loopback,
        );
        expect(await galgame.start(), isNotNull);
        expect((await capture.start()).running, isTrue);
        await galgame.stop();
        expect(native.running, isTrue, reason: 'galgame 停只交回自己的租约');
        final CrossAppAudioSnapshot? snapshot = await capture.snapshot();
        expect(snapshot, isA<CrossAppAudioPinnedSnapshot>());
        await capture.stop();
        expect(native.running, isFalse);
      },
    );

    test(
      'cross-app capture stopping leaves the galgame ring running',
      () async {
        final CrossAppAudioCapture capture = desktopCapture();
        final LoopbackGalAudioSource galgame = LoopbackGalAudioSource(
          channel: loopback,
        );
        expect((await capture.start()).running, isTrue);
        expect(await galgame.start(), isNotNull);
        await capture.stop();
        expect(await galgame.grabRecent(3000), isNotNull);
        await galgame.stop();
        expect(native.running, isFalse);
      },
    );

    test(
      'a failed galgame start and its defensive stop never stop the cache',
      () async {
        final CrossAppAudioCapture capture = desktopCapture();
        expect((await capture.start()).running, isTrue);
        native.failNextStart = true;
        final LoopbackGalAudioSource galgame = LoopbackGalAudioSource(
          channel: loopback,
        );
        expect(await galgame.start(), isNull);
        // gal_hook_session_controller 的 _startLoopbackIfAllowed：start 失败后照样 stop。
        await galgame.stop();
        expect(native.running, isTrue);
        expect(await capture.snapshot(), isNotNull);
      },
    );

    test(
      'snapshots stay in native memory until mining materializes them',
      () async {
        final CrossAppAudioCapture capture = desktopCapture();
        await capture.start();
        final CrossAppAudioSnapshot? first = await capture.snapshot();
        final CrossAppAudioSnapshot? second = await capture.snapshot();
        expect(
          native.calls.where((MethodCall c) => c.method == 'saveSnapshot'),
          isEmpty,
          reason: '查词时只钉住、不落盘',
        );
        final Directory dir = await Directory.systemTemp.createTemp(
          'cap_test_',
        );
        addTearDown(() => dir.delete(recursive: true));
        expect(
          await first!.materialize(dir),
          isNull,
          reason: '被后来的查词顶替的快照绝不给出别的查词的声音',
        );
        final CrossAppAudioFileSnapshot? file = await second!.materialize(dir);
        expect(file, isNotNull);
        expect(File(file!.pcmPath).readAsBytesSync(), native.pcm);
        expect(file.format.sampleRate, 16000);
      },
    );

    test('no snapshot while the cache is off', () async {
      final CrossAppAudioCapture capture = desktopCapture();
      expect(await capture.snapshot(), isNull);
      expect(native.calls, isEmpty);
    });

    test(
      'prepareSentenceAudio cuts the last line and uses the desktop encoder',
      () async {
        String? encodedTo;
        final CrossAppAudioCapture capture = CrossAppAudioCapture.forTesting(
          channel,
          desktopLoopbackChannel: loopback,
          desktopEncoder: (GalAudioSlice clip, String outputPath) async {
            encodedTo = outputPath;
            await File(outputPath).writeAsBytes(<int>[1, 2, 3]);
            return true;
          },
        );
        await capture.start();
        final ({String path, Directory dir})? out = await capture
            .prepareSentenceAudio((await capture.snapshot())!);
        expect(out, isNotNull);
        expect(encodedTo, out!.path);
        expect(await File(out.path).exists(), isTrue);
        await deleteCrossAppAudioDir(out.dir);
        expect(await out.dir.exists(), isFalse, reason: '落盘的快照随临时目录一起删');
      },
    );
  });
}
