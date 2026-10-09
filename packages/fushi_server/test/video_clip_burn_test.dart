/// `video clip --burn-subs` 契约：libass 滤镜的两级转义纯函数、时间轴对齐的滤镜链、
/// 烧录命令必然重编码；缺 `subtitles` 滤镜时在烧录前判 69；真 ffmpeg 端到端烧一次并
/// 用像素检查字幕确实落在片段里正确的时刻（本机没有 ffmpeg / libass 时 skip）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/commands/video_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ArgResults _parse(List<String> args) {
  final ArgParser parser = ArgParser();
  buildVideoParser(parser);
  return parser.parse(args).command!;
}

/// 本机 ffmpeg 是否带 libass 的 `subtitles` 滤镜（端到端测试的前提）。
bool _hasLibassFfmpeg() {
  try {
    final ProcessResult r = Process.runSync('ffmpeg', <String>['-hide_banner', '-filters']);
    if (r.exitCode != 0 || !RegExp(r'^\s*\S+\s+subtitles\s', multiLine: true).hasMatch('${r.stdout}')) return false;
    // 端到端量时长要 ffprobe：只有 ffmpeg 没有 ffprobe 的机器（常见于只装了单个 ffmpeg.exe）
    // 照样 skip，而不是跑到一半抛 ProcessException。
    return Process.runSync('ffprobe', <String>['-version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// 只回放失败结果的 ffmpeg 后端，记录每次调用的参数。
class _ScriptedFfmpeg implements FfmpegBackend {
  /// 查询类命令（BUG-2938 新增原语）：本假件不区分，交给 [run]。
  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      run(args, timeout);

  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    return const FfmpegRunResult(returnCode: 1, output: 'Conversion failed!');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 1, output: '');
}

void main() {
  group('滤镜转义纯函数', () {
    test('选项值一级转义：反斜杠 / 单引号 / 冒号', () {
      expect(escapeFfmpegFilterOptionValue(r"a:b\c'd"), r"a\:b\\c\'d");
      expect(escapeFfmpegFilterOptionValue('plain,[x];y'), 'plain,[x];y');
    });

    test('滤镜图二级转义：反斜杠 / 单引号 / 方括号 / 逗号 / 分号', () {
      expect(escapeFfmpegFiltergraphText(r"a\b'c[d]e,f;g:h"), r"a\\b\'c\[d\]e\,f\;g:h");
    });

    test('POSIX 路径：两级叠加', () {
      expect(ffmpegSubtitlesFilenameArg("/tmp/it's [v1], a:b.srt", windows: false), r"/tmp/it\\\'s \[v1\]\, a\\:b.srt");
    });

    test('Windows 路径：反斜杠换正斜杠，盘符冒号照转', () {
      expect(ffmpegSubtitlesFilenameArg(r'C:\Users\neko\字幕 1.ass', windows: true), r'C\\:/Users/neko/字幕 1.ass');
      // 不当 Windows 处理时反斜杠原样保留并逐级加倍。
      expect(ffmpegSubtitlesFilenameArg(r'C:\a.srt', windows: false), r'C\\:\\\\a.srt');
    });

    test('滤镜链：起点非 0 时先挪回源时间轴、烧完归零；起点 0 不加 setpts', () {
      expect(
        buildLibassSubtitlesFilter(subtitlePath: '/s/a.srt', startMs: 83500, windows: false),
        'setpts=PTS+83.500/TB,subtitles=filename=/s/a.srt,setpts=PTS-STARTPTS',
      );
      expect(
        buildLibassSubtitlesFilter(subtitlePath: '/s/a.srt', startMs: 0, windows: false),
        'subtitles=filename=/s/a.srt',
      );
    });

    test('烧录命令：输入 seek + 重编码视频（绝无 -c copy）+ 显式 map 音频', () {
      final List<String> args = buildFfmpegVideoClipLibassBurnArgs(
        inputPath: '/v/in.mkv',
        startMs: 1000,
        endMs: 3500,
        outputPath: '/v/out.mp4',
        subtitlePath: '/v/s.ass',
        windows: false,
        audioStreamIndex: 1,
      );
      expect(args.sublist(0, 8), <String>['-hide_banner', '-y', '-ss', '1.000', '-t', '2.500', '-i', '/v/in.mkv']);
      expect(args[args.indexOf('-vf') + 1], 'setpts=PTS+1.000/TB,subtitles=filename=/v/s.ass,setpts=PTS-STARTPTS');
      expect(args[args.indexOf('-c:v') + 1], 'libx264');
      expect(args, isNot(contains('copy')));
      expect(args, containsAllInOrder(<String>['-map', '0:v:0', '-map', '0:a:1?']));
      expect(args, containsAllInOrder(<String>['-movflags', '+faststart', '/v/out.mp4']));
      expect(ffmpegHasLibassSubtitlesFilter(<String>{'overlay', 'subtitles'}), isTrue);
      expect(ffmpegHasLibassSubtitlesFilter(<String>{}), isFalse);
    });
  });

  group('video clip --burn-subs（注入后端）', () {
    late Directory temp;
    late File video;
    late File srt;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('fushi_burn_');
      video = File(p.join(temp.path, 'src.mkv'))..writeAsStringSync('x');
      srt = File(p.join(temp.path, 's.srt'))..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n\n');
    });
    tearDown(() => temp.delete(recursive: true));

    Future<int> burn(List<String> extra, _ScriptedFfmpeg backend, StringBuffer err, Set<String> filters) => videoClip(
      _parse(<String>['clip', video.path, '--from', '0', '--to', '1', '-o', p.join(temp.path, 'o.mp4'), ...extra]),
      io: CliIo(out: StringBuffer(), err: err),
      deps: VideoDeps(
        ffmpegProblem: ({required bool probe}) async => null,
        ffmpegBackend: () => backend,
        ffmpegFilters: () async => filters,
      ),
    );

    test('ffmpeg 没有 subtitles 滤镜 → 69，且不跑烧录；滤镜探测失败同样 69', () async {
      final _ScriptedFfmpeg backend = _ScriptedFfmpeg();
      final StringBuffer err = StringBuffer();
      expect(await burn(<String>['--burn-subs', srt.path], backend, err, <String>{'overlay'}), kExitUnavailable);
      expect(err.toString(), contains('libass'));
      expect(await burn(<String>['--burn-subs', srt.path], backend, err, <String>{}), kExitUnavailable);
      expect(backend.calls, isEmpty);
    });

    test('与 --subs 互斥 64；格式不认识 64；烧录失败 1 且不留残缺输出', () async {
      final _ScriptedFfmpeg backend = _ScriptedFfmpeg();
      final StringBuffer err = StringBuffer();
      final Set<String> ok = <String>{'subtitles'};
      expect(await burn(<String>['--burn-subs', srt.path, '--subs', srt.path], backend, err, ok), kExitUsage);
      final File txt = File(p.join(temp.path, 's.txt'))..writeAsStringSync('x');
      expect(await burn(<String>['--burn-subs', txt.path], backend, err, ok), kExitUsage);
      expect(await burn(<String>['--burn-subs', srt.path], backend, err, ok), kExitFailure);
      expect(backend.calls.last, contains('-vf'));
      expect(File(p.join(temp.path, 'o.mp4')).existsSync(), isFalse);
    });
  });

  group('真 ffmpeg 端到端', () {
    late Directory temp;
    late File src;

    setUpAll(() async {
      if (!_hasLibassFfmpeg()) return;
      temp = await Directory.systemTemp.createTemp('fushi_burn_e2e_');
      src = File(p.join(temp.path, 'black.mkv'));
      final ProcessResult made = await Process.run('ffmpeg', <String>[
        '-y', '-v', 'error', //
        '-f', 'lavfi', '-i', 'color=c=black:s=320x240:r=10:d=4',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
        '-c:v', 'mpeg4', '-c:a', 'aac', '-shortest',
        src.path,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
    });

    tearDownAll(() async {
      if (_hasLibassFfmpeg()) await temp.delete(recursive: true);
    });

    /// 输出片段第 [atSeconds] 秒那一帧的最大灰度值（全黑底上烧了白字 → 远大于 0）。
    Future<int> maxLuma(String path, double atSeconds) async {
      final ProcessResult r = await Process.run('ffmpeg', <String>[
        '-v', 'error', '-ss', atSeconds.toStringAsFixed(2), '-i', path, //
        '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'gray', '-',
      ], stdoutEncoding: null);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final Uint8List bytes = Uint8List.fromList(r.stdout as List<int>);
      expect(bytes, isNotEmpty);
      return bytes.reduce((int a, int b) => a > b ? a : b);
    }

    Future<double> durationSeconds(String path) async {
      final ProcessResult r = await Process.run('ffprobe', <String>[
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'csv=p=0',
        path, //
      ]);
      return double.parse('${r.stdout}'.trim());
    }

    Future<Map<String, Object?>> clipBurn(String subsName, String content, String outName) async {
      final File subs = File(p.join(temp.path, subsName))..writeAsStringSync(content);
      final String out = p.join(temp.path, outName);
      final StringBuffer json = StringBuffer();
      final StringBuffer err = StringBuffer();
      final int code = await videoClip(
        _parse(<String>['clip', src.path, '--from', '1', '--to', '3', '-o', out, '--burn-subs', subs.path, '--json']),
        io: CliIo(out: json, err: err, json: true),
        deps: const VideoDeps(),
      );
      expect(code, kExitOk, reason: '$json\n$err');
      expect(File(out).lengthSync(), greaterThan(0));
      return jsonDecode(json.toString()) as Map<String, Object?>;
    }

    test('滤镜探测读得到 stdout 上的滤镜表（含 subtitles）', () async {
      expect(await probeFfmpegFilterNames(), containsAll(<String>['subtitles', 'setpts']));
    }, skip: _hasLibassFfmpeg() ? false : '本机 PATH 上没有带 libass（subtitles 滤镜）的 ffmpeg');

    test(
      '裁 1–3 秒并硬烧：源时间 1.5–2.5 的台词落在片段 0.5–1.5 秒，区间外的台词不出现，时长 2 秒',
      () async {
        // 文件名带空格 / 单引号 / 逗号 / 方括号，顺带验证转义在真 ffmpeg 上成立。
        final Map<String, Object?> body = await clipBurn(
          "it's [a], b.srt",
          '1\n00:00:00,000 --> 00:00:00,900\nOUTSIDE\n\n'
              '2\n00:00:01,500 --> 00:00:02,500\nINSIDE INSIDE\n\n',
          'burned.mp4',
        );
        final String out = body['output']! as String;
        expect(body['subtitleTracks'], 0);
        expect((await durationSeconds(out) - 2.0).abs(), lessThan(0.15));
        // 片段 1.0 秒 = 源 2.0 秒：台词在屏。
        expect(await maxLuma(out, 1.0), greaterThan(128));
        // 片段 0.2 秒 = 源 1.2 秒：两条台词都不在（OUTSIDE 只在源 0–0.9 秒）。若时间轴
        // 没对齐（字幕按片段时间 0 起算），这里会烧出 OUTSIDE。
        expect(await maxLuma(out, 0.2), lessThan(40));
        // 片段 1.8 秒 = 源 2.8 秒：台词已结束。
        expect(await maxLuma(out, 1.8), lessThan(40));
      },
      skip: _hasLibassFfmpeg() ? false : '本机 PATH 上没有带 libass（subtitles 滤镜）的 ffmpeg，跳过端到端烧录',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
