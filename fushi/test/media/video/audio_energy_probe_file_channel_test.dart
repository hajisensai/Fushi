import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/audio_energy_probe.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

/// 字幕波形对轴全平台化：逐帧 RMS 走 `ametadata` 的 `file=` 文件通道，不再依赖 ffmpeg
/// 日志回传。移动端 ffmpeg-kit 的 `getOutput` 要把逐帧日志跨平台通道异步搬回来，拿到的
/// 输出不全或为空——波形对轴因此只在桌面可用。这里钉三件事：
/// 1. 转义函数经 ffmpeg 两层 `av_get_token` 解析后原样还原任意路径；
/// 2. 后端**不回任何日志**（ffmpeg-kit 的失败形态）时包络照样从文件拿到；
/// 3. 真 ffmpeg（随包 ffmpeg-min / FUSHI_FFMPEG / PATH）在含逗号、分号、方括号、单引号、
///    空格、中文的临时目录下真能把逐帧行写进文件（无 ffmpeg 时跳过）。

/// 复刻 libavutil `av_get_token` 的反转义语义（不带终止符集，整串一个 token）：
/// `\x` 取字面 x；`'...'` 内全是字面量、引号本身去掉。ffmpeg 解析 `-af` 选项值时先在
/// 滤镜图层、再在滤镜选项层各跑一遍。
String _avGetTokenUnescape(String s) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < s.length) {
    final String c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      out.write(s[i + 1]);
      i += 2;
    } else if (c == "'") {
      i++;
      while (i < s.length && s[i] != "'") {
        out.write(s[i]);
        i++;
      }
      i++;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

String _decodeFilterOptionValue(String escaped) =>
    _avGetTokenUnescape(_avGetTokenUnescape(escaped));

/// 从 `-af` 滤镜串里取出 `ametadata` 的 `file=` 选项值（原样，未反转义）。其后紧跟
/// 末尾的 `,asetnsamples=` 拼帧滤镜；路径里的逗号都已转义成 `\,`，不会误切。
String? _metadataFileArg(List<String> args) {
  final int af = args.indexOf('-af');
  if (af < 0) return null;
  final String graph = args[af + 1];
  final int at = graph.indexOf(':file=');
  if (at < 0) return null;
  final int end = graph.lastIndexOf(',asetnsamples=');
  return graph.substring(at + ':file='.length, end > at ? end : graph.length);
}

/// 模拟移动端 ffmpeg-kit：日志一行都不回（`getOutput` 空），只按参数把逐帧行写进
/// `file=` 指定的文件。
class _FileOnlyBackend implements FfmpegBackend {
  _FileOnlyBackend(this.lines);

  final String lines;
  String? decodedPath;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    final String? raw = _metadataFileArg(args);
    if (raw != null) {
      decodedPath = _decodeFilterOptionValue(raw);
      File(decodedPath!).writeAsStringSync(lines);
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '');
}

/// 16-bit 单声道 8kHz WAV：[segments] 依次为（秒数, 振幅 0..1）的 440Hz 正弦段。
Uint8List _wav(List<(double, double)> segments) {
  const int rate = 8000;
  final List<int> samples = <int>[];
  for (final (double seconds, double amp) in segments) {
    final int n = (seconds * rate).round();
    for (int i = 0; i < n; i++) {
      samples
          .add((math.sin(2 * math.pi * 440 * i / rate) * amp * 32767).round());
    }
  }
  final ByteData b = ByteData(44 + samples.length * 2);
  void ascii(int off, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, samples.length * 2, Endian.little);
  for (int i = 0; i < samples.length; i++) {
    b.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// 找一个真 ffmpeg：FUSHI_FFMPEG > 仓库随包 ffmpeg-min（Windows / macOS）> PATH。
String? _realFfmpeg() {
  final String? override = Platform.environment['FUSHI_FFMPEG'];
  if (override != null && override.isNotEmpty) return override;
  final String? bundled = Platform.isWindows
      ? '../third_party/ffmpeg-min/windows/ffmpeg.exe'
      : (Platform.isMacOS ? '../third_party/ffmpeg-min/macos/ffmpeg' : null);
  if (bundled != null && File(bundled).existsSync()) {
    return File(bundled).absolute.path;
  }
  try {
    final ProcessResult r = Process.runSync('ffmpeg', <String>['-version']);
    if (r.exitCode == 0) return 'ffmpeg';
  } catch (_) {}
  return null;
}

/// 按固定可执行文件跑的桌面 CLI 后端（不走进程级单例解析，免得依赖测试进程旁有无捆绑）。
class _FixedCliBackend implements FfmpegBackend {
  _FixedCliBackend(this.executable);

  final String executable;
  List<String>? lastArgs;
  String lastOutput = '';

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    lastArgs = args;
    final FfmpegRunResult r = await runFfmpegProcess(executable, args, timeout);
    lastOutput = r.output;
    return r;
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      runFfmpegProcess(executable, args, timeout);
}

void main() {
  tearDown(() => setFfmpegBackendForTesting(null));

  group('escapeFfmpegFilterOptionValue', () {
    const List<String> paths = <String>[
      r'C:\Users\me\AppData\Local\Temp\fushi_audio_energy_1\rms.txt',
      '/data/user/0/app.fushi/cache/fushi_audio_energy_x/rms.txt',
      "/tmp/a b,c;[x]'q 字/rms.txt",
      "''",
      r'\\server\share\a:b\c',
      '',
    ];
    for (final String p in paths) {
      test('round-trips through two av_get_token passes: "$p"', () {
        expect(_decodeFilterOptionValue(escapeFfmpegFilterOptionValue(p)), p);
      });
    }

    test('escaped value contains no bare graph/option separators', () {
      final String e = escapeFfmpegFilterOptionValue("C:\\a,b;c[d]:e'f");
      // 任一分隔符前必有反斜杠（滤镜图层），`:` 只可能出现在引号内。
      for (final String sep in <String>[',', ';', '[', ']']) {
        final int i = e.indexOf(sep);
        expect(i > 0 && e[i - 1] == r'\', isTrue, reason: '$sep in $e');
      }
    });
  });

  group('buildFfmpegPcmEnvelopeArgs metadataFilePath', () {
    test('appends escaped file= to ametadata only when a path is given', () {
      final List<String> without =
          buildFfmpegPcmEnvelopeArgs(inputPath: '/tmp/v.mkv');
      expect(_metadataFileArg(without), isNull);

      final List<String> withFile = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        metadataFilePath: "/tmp/a b,c/rms'.txt",
      );
      final String graph = withFile[withFile.indexOf('-af') + 1];
      expect(
        graph,
        startsWith('aresample=8000,asetnsamples=n=800:p=0,'
            'astats=metadata=1:reset=1:'
            'measure_perchannel=none:measure_overall=RMS_level,'
            'ametadata=print:key=lavfi.astats.Overall.RMS_level:file='),
      );
      expect(graph, endsWith(',asetnsamples=n=48000:p=0'));
      expect(_decodeFilterOptionValue(_metadataFileArg(withFile)!),
          "/tmp/a b,c/rms'.txt");
    });
  });

  group('extractAudioEnergyEnvelope file channel', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('energy_probe_test'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('reads per-frame RMS from file when the backend returns no logs',
        () async {
      final File input = File('${tmp.path}/v.mkv')..writeAsBytesSync(<int>[0]);
      final _FileOnlyBackend backend = _FileOnlyBackend(
        'frame:0    pts:0       pts_time:0\n'
        'lavfi.astats.Overall.RMS_level=-30.5\n'
        'frame:1    pts:160     pts_time:0.02\n'
        'lavfi.astats.Overall.RMS_level=-inf\n'
        'frame:2    pts:320     pts_time:0.04\n'
        'lavfi.astats.Overall.RMS_level=-12.25\n',
      );
      setFfmpegBackendForTesting(backend);

      final List<double> env = await extractAudioEnergyEnvelope(
        videoPath: input.path,
        windowMs: kSubtitleWaveformWindowMs,
      );

      expect(env, <double>[-30.5, -120.0, -12.25]);
      // 临时文件读完即删，不在缓存目录留垃圾。
      expect(backend.decodedPath, isNotNull);
      expect(File(backend.decodedPath!).existsSync(), isFalse);
      expect(File(backend.decodedPath!).parent.existsSync(), isFalse);
    });
  });

  group('extractAudioEnergyEnvelope real ffmpeg', () {
    final String? ffmpeg = _realFfmpeg();

    test('writes per-frame RMS to a file under a hostile path', () async {
      final Directory tmp =
          Directory.systemTemp.createTempSync("energy a b,c;[x]'q 字");
      try {
        // 1s 静音 + 1s 响 + 1s 静音：20ms 窗口 → ~150 帧，中段明显更响。
        final File wav = File('${tmp.path}${Platform.pathSeparator}in.wav')
          ..writeAsBytesSync(
              _wav(<(double, double)>[(1.0, 0.0), (1.0, 0.5), (1.0, 0.0)]));
        final _FixedCliBackend backend = _FixedCliBackend(ffmpeg!);
        setFfmpegBackendForTesting(backend);

        final List<double> env = await extractAudioEnergyEnvelope(
          videoPath: wav.path,
          windowMs: kSubtitleWaveformWindowMs,
        );

        expect(env.length, inInclusiveRange(140, 160),
            reason: backend.lastOutput);
        // 数据确实来自文件通道：stderr 里没有逐帧行。
        expect(parseAudioRmsEnvelopeFromFfmpegLog(backend.lastOutput), isEmpty);
        final double loud = env.sublist(60, 90).reduce(math.max);
        final double quiet = env.sublist(5, 40).reduce(math.max);
        expect(loud, greaterThan(-20.0));
        expect(quiet, lessThan(-60.0));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    }, skip: ffmpeg == null ? 'no ffmpeg available' : false);
  });
}
