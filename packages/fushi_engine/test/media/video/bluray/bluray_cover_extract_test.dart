// BUG-5312：蓝光标题（含分集虚拟路径 `00001.p01.mpls`）的封面按标题自己的时间轴、
// 经 ffmpeg 后端的蓝光输入链（concat + AACS 解密）抽帧，不再把第一段 m2ts 直接交给
// ffmpeg——加密盘的 m2ts 是密文，各集一律没有封面；第一集的第一段还常是几秒的厂标。
import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_cover_extractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bluray_episode_fixture.dart';

/// 记下每条 `run` 命令的假后端；从不产出文件（抽帧一律「失败」）。
class _RecordingFfmpeg implements FfmpegBackend {
  final List<List<String>> runs = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs.add(List<String>.of(args));
    return const FfmpegRunResult(returnCode: 1, output: 'stub');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: 'stub');
}

void main() {
  late Directory temp;
  late String disc;
  late _RecordingFfmpeg ffmpeg;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fushi-bd-cover-');
    disc = p.join(temp.path, 'Show [BDMV]', 'Disc 1');
    writeEpisodicDisc(disc, episodes: 2);
    enginePaths = FixedEnginePaths(documents: temp, support: temp, temp: temp);
    ffmpeg = _RecordingFfmpeg();
    setFfmpegBackendForTesting(ffmpeg);
  });

  tearDown(() {
    setFfmpegBackendForTesting(null);
    enginePaths = const UninstalledEnginePaths();
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄占用；临时目录留给系统清。
    }
  });

  List<String> inputs() => <String>[
    for (final List<String> args in ffmpeg.runs)
      for (int i = 0; i + 1 < args.length; i++)
        if (args[i] == '-i') args[i + 1],
  ];

  test('分集封面抽帧的输入是分集播放列表本身，不是第一段 m2ts', () async {
    final String episode = episodePath(disc, 1);
    expect(
      await extractVideoCover(
        videoPath: episode,
        bookUid: 'ep1',
        diagnosticOnly: true,
      ),
      isNull,
    );
    // 虚拟分集路径不是磁盘上的文件，也要真的去抽（按背后的 00001.mpls 判在不在）。
    expect(ffmpeg.runs, isNotEmpty);
    expect(inputs().toSet(), <String>{episode});
    expect(
      ffmpeg.runs
          .expand((List<String> a) => a)
          .where((String arg) => arg.toLowerCase().endsWith('.m2ts')),
      isEmpty,
    );
  });

  test('整条播放列表标题同样按 .mpls 抽帧', () async {
    final String extra = p.join(disc, 'BDMV', 'PLAYLIST', '00002.mpls');
    await extractVideoCover(
      videoPath: extra,
      bookUid: 'extra',
      diagnosticOnly: true,
    );
    expect(inputs().toSet(), <String>{extra});
  });

  test('盘读不出来（播放列表不在）不起 ffmpeg', () async {
    await extractVideoCover(
      videoPath: p.join(disc, 'BDMV', 'PLAYLIST', '00009.mpls'),
      bookUid: 'missing',
      diagnosticOnly: true,
    );
    expect(ffmpeg.runs, isEmpty);
  });
}
