import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

/// galgame 一键制卡（docs/specs/galgame-mining）纯逻辑契约：
/// - WAV 头拼装 / PCM 时长（编码 helper 的可单测部分）。
/// - loopback MethodChannel 的格式解析与 fail-open 降级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PcmFormat', () {
    test('blockAlign / byteRate 计算', () {
      const fmt = PcmFormat(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      );
      expect(fmt.blockAlign, 4); // 2ch * 2byte
      expect(fmt.byteRate, 192000); // 48000 * 4
    });

    test('float32 立体声 byteRate', () {
      const fmt = PcmFormat(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 32,
        isFloat: true,
      );
      expect(fmt.blockAlign, 8);
      expect(fmt.byteRate, 384000);
    });
  });

  group('pcmDurationMs', () {
    test('一秒混音字节 -> 1000ms', () {
      expect(pcmDurationMs(192000, 192000), 1000);
    });
    test('半秒', () {
      expect(pcmDurationMs(96000, 192000), 500);
    });
    test('byteRate<=0 或 空 PCM -> 0（不炸）', () {
      expect(pcmDurationMs(1000, 0), 0);
      expect(pcmDurationMs(0, 192000), 0);
    });
  });

  group('slicePcmByMs', () {
    // 48k 立体声 16bit：byteRate=192000，blockAlign=4。1000ms=192000 字节。
    const fmt = PcmFormat(
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 16,
      isFloat: false,
    );
    // 造 1000ms 的可辨识 PCM：每字节 = (index % 251)，便于断言切片边界。
    final Uint8List oneSec =
        Uint8List.fromList(List<int>.generate(192000, (i) => i % 251));

    test('中段切片按 byteRate 对齐取正确字节区间', () {
      final s = slicePcmByMs(oneSec, fmt, 250, 500); // [48000,96000)
      expect(s.length, 48000);
      expect(s.first, 48000 % 251);
      expect(s.last, 95999 % 251);
    });

    test('帧对齐：非整帧的 ms 起点向下对齐到 blockAlign', () {
      // 1ms=192 字节（已是 4 的倍数）；用一个会产生非对齐偏移的 byteRate 场景：
      const monoFmt = PcmFormat(
        sampleRate: 44100,
        channels: 2,
        bitsPerSample: 16,
        isFloat: false,
      ); // blockAlign=4, byteRate=176400
      final pcm = Uint8List.fromList(List<int>.filled(176400, 9));
      final s = slicePcmByMs(pcm, monoFmt, 3, 7);
      // 起止字节都必须是 blockAlign(4) 的倍数。
      expect(s.length % monoFmt.blockAlign, 0);
    });

    test('endMs 超总长 -> clamp 到末尾', () {
      final s = slicePcmByMs(oneSec, fmt, 500, 5000); // end clamp 到 192000
      expect(s.length, 96000); // [96000,192000)
      expect(s.last, 191999 % 251);
    });

    test('start>=end / 空区间 -> 空 Uint8List', () {
      expect(slicePcmByMs(oneSec, fmt, 500, 500).isEmpty, true);
      expect(slicePcmByMs(oneSec, fmt, 600, 500).isEmpty, true);
      expect(slicePcmByMs(oneSec, fmt, 5000, 6000).isEmpty, true); // 全越界
    });

    test('空 PCM / 非法格式 -> 空（不炸）', () {
      expect(slicePcmByMs(Uint8List(0), fmt, 0, 100).isEmpty, true);
      const bad = PcmFormat(
        sampleRate: 0,
        channels: 0,
        bitsPerSample: 0,
        isFloat: false,
      );
      expect(slicePcmByMs(oneSec, bad, 0, 100).isEmpty, true);
    });

    test('返回的是拷贝，不与入参共享底层', () {
      final s = slicePcmByMs(oneSec, fmt, 0, 250);
      s[0] = 200;
      expect(oneSec[0], 0); // 原始未被改
    });
  });

  group('buildWavBytes', () {
    const fmt = PcmFormat(
      sampleRate: 48000,
      channels: 2,
      bitsPerSample: 16,
      isFloat: false,
    );

    test('总长 = 44 头 + PCM', () {
      final pcm = Uint8List.fromList(List<int>.filled(200, 7));
      final wav = buildWavBytes(pcm, fmt);
      expect(wav.length, 244);
    });

    test('RIFF/WAVE/fmt/data 魔数与关键小端字段', () {
      final pcm = Uint8List.fromList(List<int>.filled(100, 0));
      final wav = buildWavBytes(pcm, fmt);
      final bd = ByteData.sublistView(wav);
      String tag(int o) => String.fromCharCodes(wav.sublist(o, o + 4));
      expect(tag(0), 'RIFF');
      expect(bd.getUint32(4, Endian.little), 36 + 100); // ChunkSize
      expect(tag(8), 'WAVE');
      expect(tag(12), 'fmt ');
      expect(bd.getUint32(16, Endian.little), 16); // Subchunk1Size
      expect(bd.getUint16(20, Endian.little), 1); // PCM 整型
      expect(bd.getUint16(22, Endian.little), 2); // channels
      expect(bd.getUint32(24, Endian.little), 48000); // sampleRate
      expect(bd.getUint32(28, Endian.little), 192000); // byteRate
      expect(bd.getUint16(32, Endian.little), 4); // blockAlign
      expect(bd.getUint16(34, Endian.little), 16); // bitsPerSample
      expect(tag(36), 'data');
      expect(bd.getUint32(40, Endian.little), 100); // data size
    });

    test('float 格式 -> WAVE 格式码 3', () {
      const ff = PcmFormat(
        sampleRate: 48000,
        channels: 2,
        bitsPerSample: 32,
        isFloat: true,
      );
      final wav = buildWavBytes(Uint8List(8), ff);
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint16(20, Endian.little), 3);
    });

    test('PCM 数据原样附在头之后', () {
      final pcm = Uint8List.fromList([10, 20, 30, 40]);
      final wav = buildWavBytes(pcm, fmt);
      expect(wav.sublist(44), [10, 20, 30, 40]);
    });
  });

  group('LoopbackGalAudioSource', () {
    const channelName = 'app.hibiki.reader/audio_loopback';

    void setHandler(Future<Object?>? Function(MethodCall)? h) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), h);
    }

    tearDown(() => setHandler(null));

    test('start 返回格式 map -> 解析成 PcmFormat', () async {
      setHandler((call) async {
        if (call.method == 'start') {
          return <String, Object?>{
            'sampleRate': 48000,
            'channels': 2,
            'bitsPerSample': 32,
            'isFloat': true,
          };
        }
        return null;
      });
      final src = LoopbackGalAudioSource();
      final fmt = await src.start();
      expect(fmt, isNotNull);
      expect(fmt!.sampleRate, 48000);
      expect(fmt.channels, 2);
      expect(fmt.bitsPerSample, 32);
      expect(fmt.isFloat, true);
    });

    test('start 返回 error map -> null（降级）', () async {
      setHandler((call) async => <String, Object?>{'error': 'no device'});
      expect(await LoopbackGalAudioSource().start(), isNull);
    });

    test('native 缺失（MissingPluginException）-> 所有方法 fail-open', () async {
      setHandler(null); // 无 handler = MissingPluginException
      final src = LoopbackGalAudioSource();
      expect(await src.start(), isNull);
      expect(await src.grabRecent(3000), isNull);
      await src.stop(); // 不抛
    });

    test('grabRecent 返回 pcm+格式 -> GalAudioSlice', () async {
      setHandler((call) async {
        if (call.method == 'grabRecent') {
          expect(call.arguments, {'backMs': 3000});
          return <String, Object?>{
            'pcm': Uint8List.fromList([1, 2, 3, 4]),
            'sampleRate': 48000,
            'channels': 2,
            'bitsPerSample': 16,
            'isFloat': false,
          };
        }
        return null;
      });
      final slice = await LoopbackGalAudioSource().grabRecent(3000);
      expect(slice, isNotNull);
      expect(slice!.pcm, [1, 2, 3, 4]);
      expect(slice.format.sampleRate, 48000);
      expect(slice.isEmpty, false);
    });

    test('grabRecent backMs<=0 -> null（不打 native）', () async {
      var called = false;
      setHandler((call) async {
        called = true;
        return null;
      });
      expect(await LoopbackGalAudioSource().grabRecent(0), isNull);
      expect(called, false);
    });

    test('grabRecent 缺 pcm 字段 -> null', () async {
      setHandler((call) async => <String, Object?>{
            'sampleRate': 48000,
            'channels': 2,
            'bitsPerSample': 16,
          });
      expect(await LoopbackGalAudioSource().grabRecent(3000), isNull);
    });
  });

  group('EngineHookGalAudioSource', () {
    const channelName = 'app.hibiki.reader/voice_hook';

    void setHandler(Future<Object?>? Function(MethodCall)? h) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), h);
    }

    tearDown(() => setHandler(null));

    test('无 injectorPath -> start 返回 null（降级回 loopback，不拉子进程）', () async {
      final src = EngineHookGalAudioSource(targetPid: 1234, injectorPath: null);
      expect(await src.start(), isNull);
    });

    test('targetPid<=0 -> start null', () async {
      final src =
          EngineHookGalAudioSource(targetPid: 0, injectorPath: 'C:/nope.exe');
      expect(await src.start(), isNull);
    });

    test('grabRecent 返回 pcm+格式 -> 干净语音 GalAudioSlice', () async {
      setHandler((call) async {
        if (call.method == 'grabRecent') {
          expect(call.arguments, {'backMs': 5000});
          return <String, Object?>{
            'pcm': Uint8List.fromList([9, 8, 7, 6]),
            'sampleRate': 48000,
            'channels': 1,
            'bitsPerSample': 16,
            'isFloat': false,
            'hooked': true,
            'ready': true,
          };
        }
        return null;
      });
      final slice = await EngineHookGalAudioSource(
        targetPid: 1,
        injectorPath: null,
      ).grabRecent(5000);
      expect(slice, isNotNull);
      expect(slice!.pcm, [9, 8, 7, 6]);
      expect(slice.format.channels, 1);
    });

    test('grabRecent error map -> null', () async {
      setHandler(
          (call) async => <String, Object?>{'error': 'no voice buffered'});
      expect(
        await EngineHookGalAudioSource(targetPid: 1, injectorPath: null)
            .grabRecent(5000),
        isNull,
      );
    });

    test('grabRecent backMs<=0 -> null（不打 native）', () async {
      var called = false;
      setHandler((call) async {
        called = true;
        return null;
      });
      expect(
        await EngineHookGalAudioSource(targetPid: 1, injectorPath: null)
            .grabRecent(0),
        isNull,
      );
      expect(called, false);
    });

    test('native 缺失 -> grabRecent/stop fail-open 不抛', () async {
      setHandler(null);
      final src = EngineHookGalAudioSource(targetPid: 1, injectorPath: null);
      expect(await src.grabRecent(3000), isNull);
      await src.stop();
    });
  });
}
