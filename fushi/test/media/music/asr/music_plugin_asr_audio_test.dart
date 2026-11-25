import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/asr/music_plugin_asr_audio.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

/// 在线音源插件曲目「生成日语字幕」的取音频一步（反馈 NXOjldMQZd）：取流走插件（与播放 /
/// 制卡同一个解析入口），ffmpeg 带上插件给的请求头解码成 16 kHz 单声道 WAV，落到按曲目
/// uid 命名的应用目录；已有副本直接复用；插件报错 / ffmpeg 失败 / 取消都明确报出来、不留
/// 半截文件。ffmpeg 是替身（按参数最后一项写出文件）。
class _Backend implements FfmpegBackend {
  _Backend({this.returnCode = 0, this.bytes = 1000, this.output = ''});

  final int returnCode;
  final int bytes;
  final String output;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    if (bytes > 0) {
      File(args.last).writeAsBytesSync(List<int>.filled(bytes, 0));
    }
    return FfmpegRunResult(returnCode: returnCode, output: output);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  late Directory root;

  final String path = musicPluginTrackPath('asmr', 'RJ01');
  final MusicPlayItem item = MusicPlayItem(
    trackUid: musicPluginTrackUid('asmr', 'RJ01'),
    path: path,
    title: 'トラック1',
    durationMs: 30 * 60 * 1000,
  );
  const MusicPluginStream stream = MusicPluginStream(
    url: 'https://cdn.example.invalid/a/track01.mp3?sig=x',
    headers: <String, String>{
      'Referer': 'https://example.invalid/',
      'X-Token': 'abc',
    },
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plugin_asr_audio_');
    root = musicPluginAsrAudioRootUnder(Directory(p.join(tmp.path, 'support')));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('副本目录与文件名：asr_jobs/music_subtitles/plugin_audio/<trackUid>.wav', () {
    expect(
      root.path,
      p.join(
        tmp.path,
        'support',
        'asr_jobs',
        'music_subtitles',
        'plugin_audio',
      ),
    );
    expect(
      musicPluginAsrAudioFileIn(root, item.trackUid).path,
      p.join(root.path, '${item.trackUid}.wav'),
    );
  });

  test('ffmpeg 参数：插件请求头下发、16 kHz 单声道 PCM WAV、输出在最后', () {
    final List<String> args = musicPluginAsrAudioArgs(
      stream: stream,
      outputPath: '/out/x.wav.part',
    );
    final int input = args.indexOf('-i');
    expect(args[input + 1], stream.url);
    final int referer = args.indexOf('-referer');
    expect(referer, isNonNegative);
    expect(referer, lessThan(input), reason: '请求头是输入选项，必须在 -i 前');
    expect(args[referer + 1], 'https://example.invalid/');
    final int headers = args.indexOf('-headers');
    expect(headers, lessThan(input));
    expect(args[headers + 1], 'X-Token: abc\r\n');
    expect(args, containsAllInOrder(<String>['-ac', '1', '-ar', '16000']));
    expect(
      args,
      containsAllInOrder(<String>['-c:a', 'pcm_s16le', '-f', 'wav']),
    );
    expect(args.last, '/out/x.wav.part');
  });

  test('取流 → 解码到 <uid>.wav（经 .part 改名）；再取直接复用、不再问插件', () async {
    int resolves = 0;
    final _Backend backend = _Backend();
    final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
      root: root,
      resolver: (String q) async {
        expect(q, path);
        resolves++;
        return stream;
      },
      backend: () => backend,
    );
    final List<double?> progress = <double?>[];
    final File f = await stager.stage(
      item,
      onProgress: progress.add,
      cancel: Completer<void>().future,
    );
    expect(f.path, stager.fileFor(item.trackUid).path);
    expect(f.existsSync(), isTrue);
    expect(File('${f.path}.part').existsSync(), isFalse);
    expect(backend.calls.single.last, '${f.path}.part');
    expect(progress.first, isNull, reason: '取流阶段是不定态');
    expect(progress.last, 1);

    final File again = await stager.stage(
      item,
      onProgress: (_) {},
      cancel: Completer<void>().future,
    );
    expect(again.path, f.path);
    expect(resolves, 1, reason: '已有完整副本不重新取流');
    expect(backend.calls, hasLength(1));
  });

  test('插件取流失败（试听 / 报错）→ MusicPluginAsrAudioUnavailable，带插件原因', () async {
    final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
      root: root,
      resolver: (String _) async =>
          throw const MusicPluginStreamUnavailable('该曲目只能试听片段'),
      backend: () => _Backend(),
    );
    await expectLater(
      stager.stage(item, onProgress: (_) {}, cancel: Completer<void>().future),
      throwsA(
        isA<MusicPluginAsrAudioUnavailable>().having(
          (MusicPluginAsrAudioUnavailable e) => e.message,
          'message',
          '该曲目只能试听片段',
        ),
      ),
    );
  });

  test('ffmpeg 失败 → Unavailable（带最后一行错误），不留半截文件', () async {
    final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
      root: root,
      resolver: (String _) async => stream,
      backend: () =>
          _Backend(returnCode: 1, bytes: 10, output: 'x\nHTTP error 403'),
    );
    await expectLater(
      stager.stage(item, onProgress: (_) {}, cancel: Completer<void>().future),
      throwsA(
        isA<MusicPluginAsrAudioUnavailable>().having(
          (MusicPluginAsrAudioUnavailable e) => e.message,
          'message',
          contains('HTTP error 403'),
        ),
      ),
    );
    expect(root.listSync(), isEmpty);
  });

  test('取流期间取消 → MusicPluginAsrAudioCancelled，不跑 ffmpeg', () async {
    final Completer<void> cancel = Completer<void>();
    final _Backend backend = _Backend();
    final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
      root: root,
      resolver: (String _) async {
        cancel.complete();
        await Future<void>.delayed(Duration.zero);
        return stream;
      },
      backend: () => backend,
    );
    await expectLater(
      stager.stage(item, onProgress: (_) {}, cancel: cancel.future),
      throwsA(isA<MusicPluginAsrAudioCancelled>()),
    );
    expect(backend.calls, isEmpty);
  });

  test('不是插件曲目 → Unavailable（不碰插件与 ffmpeg）', () async {
    final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
      root: root,
      resolver: (String _) async => fail('不该取流'),
      backend: () => _Backend(),
    );
    await expectLater(
      stager.stage(
        const MusicPlayItem(trackUid: 'x', path: '/m/a.flac', title: 'a'),
        onProgress: (_) {},
        cancel: Completer<void>().future,
      ),
      throwsA(isA<MusicPluginAsrAudioUnavailable>()),
    );
  });
}
