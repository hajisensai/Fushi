import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_pcm_bridge.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// BUG-2197：PCM 解码留在根 isolate，转录 isolate 经 [RemoteAsrPcmSource] 按块拉。
/// 这里真起一个 isolate：宿主在测试 isolate（扮根 isolate），远端在子 isolate。
class _FakePcm implements AsrPcmSource {
  _FakePcm({this.chunks = 3, this.failAt});
  final int chunks;
  final int? failAt;
  final List<({String path, int start, int chunkSeconds})> decodes =
      <({String path, int start, int chunkSeconds})>[];
  int cancelled = 0;

  @override
  Future<int?> probeDurationMs(String audioPath) async =>
      audioPath == 'missing' ? null : 12345;

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) {
    decodes
        .add((path: audioPath, start: startSample, chunkSeconds: chunkSeconds));
    final StreamController<AsrPcmChunk> c = StreamController<AsrPcmChunk>(
      onCancel: () => cancelled++,
    );
    Future<void>(() async {
      for (int i = 0; i < chunks; i++) {
        if (failAt == i) {
          c.addError(AsrPcmDecodeException(audioPath, 'boom at $i'));
          await c.close();
          return;
        }
        final Float32List s = Float32List(4);
        for (int k = 0; k < 4; k++) {
          s[k] = (i * 10 + k).toDouble();
        }
        c.add(AsrPcmChunk(startSample: startSample + i * 4, samples: s));
      }
      await c.close();
    });
    return c.stream;
  }
}

/// 子 isolate：经桥解码 `path`，把 (startSample, samples) 与探测结果回传。
Future<void> _remoteMain(List<Object> args) async {
  final SendPort host = args[0] as SendPort;
  final SendPort results = args[1] as SendPort;
  final String path = args[2] as String;
  final RemoteAsrPcmSource pcm = RemoteAsrPcmSource(host);
  try {
    final int? ms = await pcm.probeDurationMs(path);
    final List<List<double>> got = <List<double>>[];
    final List<int> starts = <int>[];
    await for (final AsrPcmChunk c in pcm.decode(
      path,
      startSample: 100,
      chunkSeconds: 7,
    )) {
      starts.add(c.startSample);
      got.add(c.samples.toList());
    }
    results.send(<Object?>['ok', ms, starts, got]);
  } catch (e) {
    results.send(<Object?>['err', '$e']);
  } finally {
    pcm.close();
  }
}

Future<List<Object?>> _runRemote(AsrPcmBridgeHost host, String path) async {
  final ReceivePort results = ReceivePort();
  await Isolate.spawn<List<Object>>(_remoteMain, <Object>[
    host.port,
    results.sendPort,
    path,
  ]);
  final List<Object?> r = (await results.first) as List<Object?>;
  results.close();
  return r;
}

void main() {
  test('跨 isolate：块按序、零拷贝到达，startSample / chunkSeconds 原样传给真源', () async {
    final _FakePcm pcm = _FakePcm(chunks: 3);
    final AsrPcmBridgeHost host = AsrPcmBridgeHost(pcm);
    final List<Object?> r = await _runRemote(host, 'a.mp3');
    expect(r[0], 'ok');
    expect(r[1], 12345);
    expect(r[2], <int>[100, 104, 108]);
    expect(r[3], <List<double>>[
      <double>[0, 1, 2, 3],
      <double>[10, 11, 12, 13],
      <double>[20, 21, 22, 23],
    ]);
    expect(pcm.decodes.single, (path: 'a.mp3', start: 100, chunkSeconds: 7));
    await host.close();
  });

  test('解码异常原样以 AsrPcmDecodeException 在远端抛出；探不出时长回 null', () async {
    final _FakePcm pcm = _FakePcm(chunks: 3, failAt: 1);
    final AsrPcmBridgeHost host = AsrPcmBridgeHost(pcm);
    final List<Object?> r = await _runRemote(host, 'missing');
    expect(r[0], 'err');
    expect(r[1], contains('AsrPcmDecodeException(missing): boom at 1'));
    await host.close();
  });
}
