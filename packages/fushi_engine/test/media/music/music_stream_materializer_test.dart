// 互联音乐库的截段 / 转码缓存（design-imusic-q5 / q6）：并发同一输入只跑一次 ffmpeg、
// 失败不留半截文件、超出总量按最久没用淘汰。
import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/music/host/music_stream_materializer.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('music_mz_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('并发同一输入只跑一次；缓存命中不再跑', () async {
    int runs = 0;
    final Completer<void> gate = Completer<void>();
    final MusicStreamMaterializer m = MusicStreamMaterializer(
      cacheDir: Directory('${tmp.path}/c'),
      ffmpeg: (List<String> a) async {
        runs++;
        await gate.future;
        File(a.last).writeAsStringSync('x');
        return (code: 0, output: '');
      },
    );
    const MusicFfmpegInput input = MusicFfmpegInput('in.flac', version: '1');
    final Future<File> a = m.materialize(input, startMs: 1000, endMs: 2000);
    final Future<File> b = m.materialize(input, startMs: 1000, endMs: 2000);
    gate.complete();
    expect((await a).path, (await b).path);
    await m.materialize(input, startMs: 1000, endMs: 2000);
    expect(runs, 1);
    expect((await a).path, endsWith('.flac'));
    expect(
      (await m.materialize(input, bitrateKbps: 128)).path,
      endsWith('.m4a'),
    );
  });

  test('ffmpeg 失败抛 MusicMaterializeException，不留 .part', () async {
    final MusicStreamMaterializer m = MusicStreamMaterializer(
      cacheDir: Directory('${tmp.path}/c'),
      ffmpeg: (List<String> a) async {
        File(a.last).writeAsStringSync('half');
        return (code: 1, output: 'boom');
      },
    );
    await expectLater(
      m.materialize(const MusicFfmpegInput('in', version: '1')),
      throwsA(isA<MusicMaterializeException>()),
    );
    expect(Directory('${tmp.path}/c').listSync(), isEmpty);
  });

  test('超出总量淘汰最久没用的，刚产出的留下', () async {
    final MusicStreamMaterializer m = MusicStreamMaterializer(
      cacheDir: Directory('${tmp.path}/c'),
      capacityBytes: 150,
      ffmpeg: (List<String> a) async {
        File(a.last).writeAsBytesSync(List<int>.filled(100, 1));
        return (code: 0, output: '');
      },
    );
    final File first = await m.materialize(
      const MusicFfmpegInput('a', version: '1'),
    );
    first.setLastModifiedSync(DateTime(2000));
    final File second = await m.materialize(
      const MusicFfmpegInput('b', version: '1'),
    );
    // 淘汰是异步的：等它跑完。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(first.existsSync(), isFalse);
    expect(second.existsSync(), isTrue);
  });
}
