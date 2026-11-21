import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_hdr_tone_map.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart';
import 'package:test/test.dart';

/// 假后端：`-h filter=scale` 回 [scaleHelp]，ffprobe 按路径回 [transfers]。
class _ProbeBackend implements FfmpegBackend {
  _ProbeBackend({required this.scaleHelp, required this.transfers});

  final String scaleHelp;
  final Map<String, String> transfers;
  final List<List<String>> probeCalls = <List<String>>[];
  final List<List<String>> queryCalls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '');

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    probeCalls.add(args);
    return FfmpegRunResult(returnCode: 0, output: transfers[args.last] ?? '');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) async {
    queryCalls.add(args);
    return FfmpegRunResult(returnCode: 0, output: scaleHelp);
  }
}

const String _kNewScaleHelp = '''
Filter scale
  out_transfer      <int>  set output color transfer
  out_primaries     <int>  set output primaries
SWScaler AVOptions:
  -intent           <int>  color mapping intent
     perceptual     0      perceptual tone mapping
''';

const String _kOldScaleHelp = '''
Filter scale
  out_color_matrix  <string> set output YCbCr type
  out_range         <int>    set output color range
''';

/// 本机 PATH 上的 ffmpeg 是否带 swscale 色彩管理（老版本 / 没装时为 false）。
bool _systemFfmpegSupportsToneMap() {
  try {
    final ProcessResult r = Process.runSync('ffmpeg', <String>[
      '-hide_banner',
      '-h',
      'filter=scale',
    ]);
    return r.exitCode == 0 && ffmpegScaleHelpSupportsToneMap('${r.stdout}');
  } on ProcessException {
    return false;
  }
}

/// 用 ffmpeg 自己的 signalstats 量一张图的平均饱和度（8-bit 刻度）。
double _saturation(String imagePath) {
  final ProcessResult r = Process.runSync('ffmpeg', <String>[
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    imagePath,
    '-vf',
    'format=rgb24,format=yuv444p,signalstats,metadata=print:file=-',
    '-f',
    'null',
    '-',
  ]);
  final RegExpMatch? m = RegExp(
    r'lavfi\.signalstats\.SATAVG=([0-9.]+)',
  ).firstMatch('${r.stdout}');
  if (m == null) throw StateError('no SATAVG: ${r.stdout} ${r.stderr}');
  return double.parse(m.group(1)!);
}

void main() {
  setUp(debugResetFfmpegHdrToneMapState);
  tearDown(() {
    setFfmpegBackendForTesting(null);
    debugResetFfmpegHdrToneMapState();
  });

  group('纯函数', () {
    test('只有 PQ / HLG 算 HDR', () {
      expect(ffprobeTransferIsHdr('smpte2084\n'), isTrue);
      expect(ffprobeTransferIsHdr('arib-std-b67\r\n'), isTrue);
      expect(ffprobeTransferIsHdr('bt709\n'), isFalse);
      expect(ffprobeTransferIsHdr('unknown\n'), isFalse);
      expect(ffprobeTransferIsHdr(''), isFalse);
    });

    test('scale 帮助文本缺任一选项就不支持', () {
      expect(ffmpegScaleHelpSupportsToneMap(_kNewScaleHelp), isTrue);
      expect(ffmpegScaleHelpSupportsToneMap(_kOldScaleHelp), isFalse);
    });

    test('ffprobe 参数：远端协议选项在输入前，只看首条视频流', () {
      expect(
        buildFfprobeVideoTransferArgs(
          inputPath: 'https://h/v.m3u8',
          inputArgs: const <String>['-user_agent', 'UA'],
        ),
        <String>[
          '-user_agent',
          'UA',
          '-v',
          'error',
          '-select_streams',
          'v:0',
          '-show_entries',
          'stream=color_transfer',
          '-of',
          'default=nw=1:nk=1',
          'https://h/v.m3u8',
        ],
      );
    });
  });

  group('参数构建', () {
    test('抽帧：映射段排在缩放之后；默认逐字不变', () {
      final List<String> plain = buildFfmpegFrameArgs(
        inputPath: 'a.mkv',
        outputPath: 'a.jpg',
        scaleWidth: 320,
      );
      expect(plain[plain.indexOf('-vf') + 1], 'scale=320:-2');
      final List<String> mapped = buildFfmpegFrameArgs(
        inputPath: 'a.mkv',
        outputPath: 'a.jpg',
        scaleWidth: 320,
        toneMapToSdr: true,
      );
      expect(
        mapped[mapped.indexOf('-vf') + 1],
        'scale=320:-2,$kFfmpegHdrToSdrScaleFilter',
      );
      final List<String> noScale = buildFfmpegFrameArgs(
        inputPath: 'a.mkv',
        outputPath: 'a.jpg',
        toneMapToSdr: true,
      );
      expect(noScale[noScale.indexOf('-vf') + 1], kFfmpegHdrToSdrScaleFilter);
    });

    test('动图：GIF 调色板之前映射，WebP 单链末尾映射', () {
      final List<String> gif = buildFfmpegClipAnimatedArgs(
        format: MiningAnimatedFormat.gif,
        inputPath: 'a.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: 'a.gif',
        toneMapToSdr: true,
      );
      expect(
        gif[gif.indexOf('-filter_complex') + 1],
        'fps=8,scale=320:-2:flags=lanczos,$kFfmpegHdrToSdrScaleFilter,'
        'split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse',
      );
      final List<String> webp = buildFfmpegClipAnimatedArgs(
        format: MiningAnimatedFormat.webp,
        inputPath: 'a.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: 'a.webp',
        toneMapToSdr: true,
      );
      expect(
        webp[webp.indexOf('-vf') + 1],
        'fps=8,scale=320:-2:flags=lanczos,$kFfmpegHdrToSdrScaleFilter',
      );
      final List<String> plain = buildFfmpegClipAnimatedArgs(
        format: MiningAnimatedFormat.webp,
        inputPath: 'a.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: 'a.webp',
      );
      expect(plain.join(' '), isNot(contains('out_transfer')));
    });

    test('片段：缩放之后、转 yuv420p 之前映射', () {
      final List<String> args = buildSynchronizedVideoClipArgs(
        videoPath: 'a.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: 'a.mp4',
        toneMapToSdr: true,
      );
      final String vf = args[args.indexOf('-vf') + 1];
      expect(vf, endsWith('h=-2,$kFfmpegHdrToSdrScaleFilter,format=yuv420p'));
      final List<String> plain = buildSynchronizedVideoClipArgs(
        videoPath: 'a.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: 'a.mp4',
      );
      expect(plain[plain.indexOf('-vf') + 1], isNot(contains('out_transfer')));
    });
  });

  group('判定', () {
    test('HDR 源 + 支持的后端 → 映射；同一路径只探一次', () async {
      final _ProbeBackend backend = _ProbeBackend(
        scaleHelp: _kNewScaleHelp,
        transfers: <String, String>{'hdr.mkv': 'smpte2084\n'},
      );
      setFfmpegBackendForTesting(backend);
      expect(await ffmpegShouldToneMapToSdr('hdr.mkv'), isTrue);
      expect(await ffmpegShouldToneMapToSdr('hdr.mkv'), isTrue);
      expect(backend.probeCalls, hasLength(1));
      expect(backend.queryCalls, <List<String>>[
        <String>['-hide_banner', '-h', 'filter=scale'],
      ]);
    });

    test('SDR 源不映射', () async {
      setFfmpegBackendForTesting(
        _ProbeBackend(
          scaleHelp: _kNewScaleHelp,
          transfers: <String, String>{'sdr.mkv': 'bt709\n'},
        ),
      );
      expect(await ffmpegShouldToneMapToSdr('sdr.mkv'), isFalse);
    });

    test('老 ffmpeg（scale 不认色彩管理选项）不映射，命令不会因此失败', () async {
      setFfmpegBackendForTesting(
        _ProbeBackend(
          scaleHelp: _kOldScaleHelp,
          transfers: <String, String>{'hdr.mkv': 'arib-std-b67\n'},
        ),
      );
      expect(await ffmpegShouldToneMapToSdr('hdr.mkv'), isFalse);
    });
  });

  group('真实 ffmpeg（PATH 上带 swscale 色彩管理的版本）', () {
    final String? skip = _systemFfmpegSupportsToneMap()
        ? null
        : '本机 PATH 上没有带 swscale 色彩管理的 ffmpeg';

    test('PQ 源：映射后的截帧饱和度明显高于原命令', () async {
      final Directory dir = await Directory.systemTemp.createTemp('hdr_tm_');
      addTearDown(() => dir.delete(recursive: true));
      final String sdr = '${dir.path}/sdr.png';
      final String pq = '${dir.path}/pq.mkv';
      // SDR 参考帧，再用 swscale 自己转成 PQ / BT.2020 的 10-bit 无损片源（ffv1）。
      expect(
        Process.runSync('ffmpeg', <String>[
          '-hide_banner', '-loglevel', 'error', '-y', //
          '-f', 'lavfi', '-i', 'testsrc2=s=320x180:r=1:d=1',
          '-frames:v', '1', sdr,
        ]).exitCode,
        0,
      );
      final ProcessResult make = Process.runSync('ffmpeg', <String>[
        '-hide_banner', '-loglevel', 'error', '-y', //
        '-i', sdr,
        '-vf',
        'scale=in_transfer=bt709:in_primaries=bt709:'
            'out_transfer=smpte2084:out_primaries=bt2020:'
            'out_color_matrix=bt2020nc,format=yuv420p10le',
        '-c:v', 'ffv1',
        '-color_trc', 'smpte2084', '-color_primaries', 'bt2020',
        '-colorspace', 'bt2020nc',
        pq,
      ]);
      expect(make.exitCode, 0, reason: '${make.stderr}');

      final String before = '${dir.path}/before.png';
      final String after = '${dir.path}/after.png';
      for (final (String out, bool map) in <(String, bool)>[
        (before, false),
        (after, true),
      ]) {
        final ProcessResult r = Process.runSync(
          'ffmpeg',
          buildFfmpegFrameArgs(
            inputPath: pq,
            outputPath: out,
            toneMapToSdr: map,
          ),
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }
      final double ref = _saturation(sdr);
      final double sBefore = _saturation(before);
      final double sAfter = _saturation(after);
      // 改前把 PQ 码值直接当 SDR：饱和度只剩一小半；映射后要明显回升。
      expect(sBefore, lessThan(ref * 0.4));
      expect(sAfter, greaterThan(sBefore * 1.8));
    }, skip: skip);
  });
}
