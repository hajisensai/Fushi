@Tags(<String>['ffmpeg'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_pcm_source.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';

/// 一次 fake ffmpeg 调用要做的事：往输出文件写 [bytes]（null = 不创建文件），返回
/// [returnCode] / [output]。
class _Scripted {
  const _Scripted({
    this.bytes = const <int>[],
    this.returnCode = 0,
    this.output = '',
  });

  final List<int>? bytes;
  final int? returnCode;
  final String output;
}

/// 记录参数、按脚本逐次响应的 fake [FfmpegBackend]。脚本用尽后返回「exit 0、空文件」
/// （= EOF）。
class _FakeFfmpegBackend implements FfmpegBackend {
  _FakeFfmpegBackend(
    this.script, {
    this.probeOutput = '',
    this.probeCode = 0,
    this.delays = const <Duration>[],
  });

  final List<_Scripted> script;
  final String probeOutput;
  final int? probeCode;

  /// 第 i 次调用在写文件前先等 `delays[i]`（越界不等），模拟并行块乱序完成。
  final List<Duration> delays;
  final List<List<String>> calls = <List<String>>[];
  final List<List<String>> probeCalls = <List<String>>[];
  final List<Duration> timeouts = <Duration>[];
  int active = 0;
  int maxActive = 0;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(List<String>.of(args));
    timeouts.add(timeout);
    final int callIndex = calls.length - 1;
    active++;
    if (active > maxActive) maxActive = active;
    final _Scripted step =
        callIndex < script.length ? script[callIndex] : const _Scripted();
    if (callIndex < delays.length) {
      await Future<void>.delayed(delays[callIndex]);
    }
    final List<int>? bytes = step.bytes;
    if (bytes != null) {
      await File(args.last).writeAsBytes(bytes, flush: true);
    }
    active--;
    return FfmpegRunResult(
      returnCode: step.returnCode,
      output: step.output,
      executable: 'fake-ffmpeg',
    );
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    probeCalls.add(List<String>.of(args));
    return FfmpegRunResult(returnCode: probeCode, output: probeOutput);
  }
}

/// `Process.start` 抛错的后端（ffmpeg 不存在）。
class _MissingFfmpegBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      throw const ProcessException('ffmpeg', <String>[], 'not found', 2);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw const ProcessException('ffprobe', <String>[], 'not found', 2);
}

/// 真 ffmpeg 后端：直接把参数交给 PATH（或指定路径）的可执行文件，绕开生产端的
/// 「覆盖 > 捆绑 > PATH」解析（那条链读 `Platform.environment`，测试里注入不了）。
class _ExecutableFfmpegBackend implements FfmpegBackend {
  const _ExecutableFfmpegBackend(this.ffmpeg, this.ffprobe);

  final String ffmpeg;
  final String ffprobe;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      runFfmpegProcess(ffmpeg, args, timeout);

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      runFfprobeProcess(ffprobe, args, timeout);
}

Uint8List _s16le(List<int> samples) {
  final ByteData bd = ByteData(samples.length * 2);
  for (int i = 0; i < samples.length; i++) {
    bd.setInt16(i * 2, samples[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

Uint8List _box(String type, List<int> payload) {
  final BytesBuilder b = BytesBuilder(copy: false);
  final ByteData size = ByteData(4)..setUint32(0, 8 + payload.length);
  b.add(size.buffer.asUint8List());
  b.add(type.codeUnits);
  b.add(payload);
  return b.toBytes();
}

Uint8List _largeBox(String type, List<int> payload) {
  final BytesBuilder b = BytesBuilder(copy: false);
  final ByteData head = ByteData(16)
    ..setUint32(0, 1)
    ..setUint64(8, 16 + payload.length);
  head.buffer.asUint8List().setRange(4, 8, type.codeUnits);
  b.add(head.buffer.asUint8List());
  b.add(payload);
  return b.toBytes();
}

/// 模拟 ffmpeg mov 输出：`ftyp` `wide` `mdat`(pcm) `moov`。
Uint8List _mov(List<int> pcm, {bool largesize = false, int tracks = 1}) {
  final BytesBuilder b = BytesBuilder(copy: false);
  b.add(_box('ftyp', 'qt  \x00\x00\x02\x00qt  '.codeUnits));
  b.add(_box('wide', const <int>[]));
  b.add(largesize ? _largeBox('mdat', pcm) : _box('mdat', pcm));
  // moov：mvhd 占位 + N 条 trak（ffmpeg 真输出里 trak 是 moov 的直接子盒）。
  final BytesBuilder moov = BytesBuilder(copy: false);
  moov.add(_box('mvhd', List<int>.filled(24, 0x11)));
  for (int i = 0; i < tracks; i++) {
    moov.add(_box('trak', _box('tkhd', List<int>.filled(8, 0x22))));
  }
  b.add(_box('moov', moov.toBytes()));
  return b.toBytes();
}

const String _kNoS16le = '[AVFormatContext @ 0x1] Requested output format '
    "'s16le' is not known.\nError opening output file x.pcm.\n"
    'Error opening output files: Invalid argument';

/// PATH 上的 ffmpeg / ffprobe（`-version` 跑得起来才算有）；没有则返回 null。
String? _findOnPath(String name) {
  try {
    final ProcessResult r = Process.runSync(name, <String>['-version']);
    return r.exitCode == 0 ? name : null;
  } on ProcessException {
    return null;
  }
}

/// 仓库里捆绑发布的最小化 ffmpeg-min（Windows 才有入库二进制）。
String? _bundledFfmpegMin() {
  if (!Platform.isWindows) return null;
  final File f = File('../third_party/ffmpeg-min/windows/ffmpeg.exe');
  return f.existsSync() ? f.absolute.path : null;
}

Future<Float32List> _decodeWhole(String ffmpeg, String input) async {
  final Directory dir = await Directory.systemTemp.createTemp('fushi_asr_ref_');
  try {
    final String out = '${dir.path}${Platform.pathSeparator}whole.pcm';
    final ProcessResult r = await Process.run(ffmpeg, <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      input,
      '-map',
      '0:a:0',
      '-vn',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-c:a',
      'pcm_s16le',
      '-f',
      's16le',
      out,
    ]);
    expect(r.exitCode, 0, reason: 'reference decode failed: ${r.stderr}');
    return pcmS16leToFloat32(await File(out).readAsBytes());
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<Float32List> _collect(
  Stream<AsrPcmChunk> stream, {
  required int expectedStart,
  required int chunkSamples,
}) async {
  final List<Float32List> parts = <Float32List>[];
  int next = expectedStart;
  int total = 0;
  await for (final AsrPcmChunk c in stream) {
    expect(c.startSample, next, reason: '块之间必须无重叠、无空洞');
    expect(c.samples.length, lessThanOrEqualTo(chunkSamples));
    parts.add(c.samples);
    next = c.endSample;
    total += c.samples.length;
  }
  final Float32List out = Float32List(total);
  int off = 0;
  for (final Float32List p in parts) {
    out.setAll(off, p);
    off += p.length;
  }
  return out;
}

/// 逐样本对照：返回 (最大 |diff|（以 1/32768 计）, 首个超阈值的下标)。
({int maxDiffLsb, int firstBadIndex, int badCount}) _compare(
  Float32List ref,
  Float32List got, {
  int toleranceLsb = 2,
  int ignoreTailSamples = 0,
}) {
  expect(got.length, ref.length, reason: '总样本数必须与整段解码一致');
  int maxDiff = 0;
  int firstBad = -1;
  int bad = 0;
  final int n = ref.length - ignoreTailSamples;
  for (int i = 0; i < n; i++) {
    final int d = ((ref[i] - got[i]).abs() * 32768).round();
    if (d > maxDiff) maxDiff = d;
    if (d > toleranceLsb) {
      bad++;
      if (firstBad < 0) firstBad = i;
    }
  }
  return (maxDiffLsb: maxDiff, firstBadIndex: firstBad, badCount: bad);
}

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('fushi_asr_pcm_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  List<Directory> leftovers() => tempRoot
      .listSync()
      .whereType<Directory>()
      .where((Directory d) => d.path.contains('fushi_asr_pcm_'))
      .toList();

  group('纯函数', () {
    test('buildAsrPcmChunkArgs：首块无 -ss，输出端参数齐全', () {
      final List<String> args = buildAsrPcmChunkArgs(
        inputPath: 'in.mp3',
        outputPath: 'out.pcm',
        startMs: 0,
        durationMs: 600000,
        container: AsrPcmContainer.s16le,
      );
      expect(args, isNot(contains('-ss')));
      expect(args.indexOf('-i'), lessThan(args.indexOf('-t')));
      expect(args.sublist(args.indexOf('-t')), <String>[
        '-t', '600.000', '-map', '0:a:0', '-vn', '-sn', '-dn', //
        '-map_chapters', '-1', '-map_metadata', '-1', '-ac', '1', //
        '-ar', '16000', '-c:a', 'pcm_s16le', '-f', 's16le', 'out.pcm',
      ]);
    });

    test('buildAsrPcmChunkArgs：预滚——输入端 -ss 在 -i 前、输出端 -ss 在 -i 后', () {
      final List<String> args = buildAsrPcmChunkArgs(
        inputPath: 'in.m4b',
        outputPath: 'out.mov',
        startMs: 7000,
        durationMs: 7000,
        container: AsrPcmContainer.mov,
      );
      final int i = args.indexOf('-i');
      expect(args.sublist(i - 2, i), <String>['-ss', '5.000']);
      expect(args.sublist(i + 2, i + 6), <String>[
        '-ss',
        '2.000',
        '-t',
        '7.000',
      ]);
      expect(args.sublist(args.length - 3), <String>['-f', 'mov', 'out.mov']);
    });

    test('buildAsrPcmChunkArgs：起点小于预滚时不做输入端 -ss，全部走输出端', () {
      final List<String> args = buildAsrPcmChunkArgs(
        inputPath: 'in.mp3',
        outputPath: 'out.pcm',
        startMs: 1500,
        durationMs: 1000,
        container: AsrPcmContainer.s16le,
      );
      final int i = args.indexOf('-i');
      expect(args.sublist(0, i), isNot(contains('-ss')));
      expect(args.sublist(i + 2, i + 4), <String>['-ss', '1.500']);
    });

    test('buildAsrPcmChunkArgs：输入端跳点取整秒', () {
      final List<String> args = buildAsrPcmChunkArgs(
        inputPath: 'in.mp3',
        outputPath: 'out.pcm',
        startMs: 10250,
        durationMs: 1000,
        container: AsrPcmContainer.s16le,
      );
      final int i = args.indexOf('-i');
      expect(args.sublist(i - 2, i), <String>['-ss', '8.000']);
      expect(args.sublist(i + 2, i + 4), <String>['-ss', '2.250']);
    });

    test('asrPcmChunkTimeout：chunk×2+30，下限 60 s', () {
      expect(asrPcmChunkTimeout(1), const Duration(seconds: 60));
      expect(asrPcmChunkTimeout(15), const Duration(seconds: 60));
      expect(asrPcmChunkTimeout(600), const Duration(seconds: 1230));
    });

    test('isMissingS16leMuxerFailure 只认 s16le 的 not-known 文案', () {
      expect(
        isMissingS16leMuxerFailure(
          const FfmpegRunResult(returnCode: 127, output: _kNoS16le),
        ),
        isTrue,
      );
      expect(
        isMissingS16leMuxerFailure(
          const FfmpegRunResult(returnCode: 0, output: _kNoS16le),
        ),
        isFalse,
      );
      expect(
        isMissingS16leMuxerFailure(
          const FfmpegRunResult(returnCode: null, output: _kNoS16le),
        ),
        isFalse,
      );
      expect(
        isMissingS16leMuxerFailure(
          const FfmpegRunResult(
            returnCode: 1,
            output: "Requested output format 'wav' is not known",
          ),
        ),
        isFalse,
      );
      expect(
        isMissingS16leMuxerFailure(
          const FfmpegRunResult(returnCode: 1, output: 'Invalid data found'),
        ),
        isFalse,
      );
    });

    test('pcmS16leToFloat32：小端、/32768、奇数尾字节丢弃', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        ..._s16le(<int>[0, 16384, -16384, 32767, -32768]),
        0x7f, // 尾巴上多一个字节
      ]);
      final Float32List f = pcmS16leToFloat32(bytes);
      expect(f, <double>[0.0, 0.5, -0.5, 32767 / 32768, -1.0]);
    });

    test('extractMovMdatPayload：moov 里多于一条轨（章节 text 轨混入）直接判坏', () {
      // BUG-2164：ffmpeg 默认复制章节，-f mov 时章节成 text 轨、样本交错进 mdat。
      final List<int> pcm = List<int>.generate(64, (int i) => i);
      expect(
        () => extractMovMdatPayload(_mov(pcm, tracks: 2)),
        throwsA(isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains('2 tracks'),
        )),
      );
      // 零轨（moov 里没有 trak）同样不是合法的单 PCM 轨输出。
      expect(
        () => extractMovMdatPayload(_mov(pcm, tracks: 0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('extractMovMdatPayload：缺 moov（ffmpeg 被中断、文件截断）判坏', () {
      final BytesBuilder b = BytesBuilder(copy: false);
      b.add(_box('ftyp', 'qt  '.codeUnits));
      b.add(_box('mdat', const <int>[1, 2, 3, 4]));
      expect(
        () => extractMovMdatPayload(b.toBytes()),
        throwsA(isA<FormatException>()),
      );
    });

    test('extractMovMdatPayload：32 位 size', () {
      final Uint8List pcm = _s16le(<int>[1, 2, 3]);
      expect(extractMovMdatPayload(_mov(pcm)), pcm);
    });

    test('extractMovMdatPayload：size==1 走 64 位 largesize', () {
      final Uint8List pcm = _s16le(<int>[7, 8, 9, 10]);
      expect(extractMovMdatPayload(_mov(pcm, largesize: true)), pcm);
    });

    test('extractMovMdatPayload：size==0 延伸到文件尾', () {
      final Uint8List pcm = _s16le(<int>[5, 6]);
      final BytesBuilder b = BytesBuilder(copy: false);
      b.add(_box('ftyp', 'qt  '.codeUnits));
      final ByteData zero = ByteData(4);
      b.add(zero.buffer.asUint8List());
      b.add('mdat'.codeUnits);
      b.add(pcm);
      expect(extractMovMdatPayload(b.toBytes()), pcm);
    });

    test('extractMovMdatPayload：无 mdat / 坏 size 抛 FormatException', () {
      expect(
        () => extractMovMdatPayload(_box('ftyp', 'qt  '.codeUnits)),
        throwsFormatException,
      );
      final Uint8List bad = _box('ftyp', 'qt  '.codeUnits);
      bad[3] = 4; // size 4 < 8 字节头
      expect(() => extractMovMdatPayload(bad), throwsFormatException);
      // largesize 越界
      final Uint8List tooLarge = _largeBox('mdat', <int>[1, 2]);
      tooLarge[15] = 0xff;
      expect(() => extractMovMdatPayload(tooLarge), throwsFormatException);
    });

    test('parseFfprobeDurationMs', () {
      expect(
        parseFfprobeDurationMs('{"format":{"duration":"30.000000"}}'),
        30000,
      );
      expect(parseFfprobeDurationMs('{"format":{"duration":12.3456}}'), 12346);
      expect(parseFfprobeDurationMs('{"format":{}}'), isNull);
      expect(parseFfprobeDurationMs('{"format":{"duration":"N/A"}}'), isNull);
      expect(parseFfprobeDurationMs('{"format":{"duration":"0"}}'), isNull);
      expect(parseFfprobeDurationMs('not json'), isNull);
      expect(parseFfprobeDurationMs(''), isNull);
    });

    test('buildAsrProbeDurationArgs', () {
      expect(buildAsrProbeDurationArgs(inputPath: 'a.m4b'), <String>[
        '-v', 'quiet', '-print_format', 'json', '-show_entries', //
        'format=duration', 'a.m4b',
      ]);
    });
  });

  group('FfmpegAsrPcmSource（fake 后端）', () {
    late File input;

    setUp(() {
      input = File('${tempRoot.path}${Platform.pathSeparator}book.mp3')
        ..writeAsBytesSync(<int>[0x49, 0x44, 0x33]);
    });

    test('s16le 直出：多块 startSample 递增、0 样本终止、参数含 -vn/-ac 1/-ar 16000', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        _Scripted(bytes: _s16le(List<int>.filled(16000, 1000))),
        _Scripted(bytes: _s16le(List<int>.filled(16000, -2000))),
        _Scripted(bytes: _s16le(List<int>.filled(4000, 3000))), // 短块
        const _Scripted(bytes: <int>[]), // EOF
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );

      final List<AsrPcmChunk> chunks =
          await source.decode(input.path, chunkSeconds: 1).toList();

      expect(chunks.map((AsrPcmChunk c) => c.startSample), <int>[
        0,
        16000,
        32000,
      ]);
      expect(chunks.map((AsrPcmChunk c) => c.samples.length), <int>[
        16000,
        16000,
        4000,
      ]);
      expect(chunks[0].samples[0], closeTo(1000 / 32768, 1e-7));
      expect(chunks[1].samples[15999], closeTo(-2000 / 32768, 1e-7));
      expect(chunks[2].samples[0], closeTo(3000 / 32768, 1e-7));
      expect(backend.calls, hasLength(4));
      for (final List<String> args in backend.calls) {
        expect(args, containsAllInOrder(<String>['-ac', '1']));
        expect(args, containsAllInOrder(<String>['-ar', '16000']));
        expect(args, containsAllInOrder(<String>['-c:a', 'pcm_s16le']));
        expect(args, containsAllInOrder(<String>['-map', '0:a:0']));
        expect(args, contains('-vn'));
        expect(args, containsAllInOrder(<String>['-f', 's16le']));
        expect(args[args.indexOf('-i') + 1], input.path);
      }
      // 第 4 块起点 3 s，预滚 2 s → 输入端 -ss 1.000、输出端 -ss 2.000。
      final List<String> a3 = backend.calls[3];
      final int i = a3.indexOf('-i');
      expect(a3.sublist(i - 2, i), <String>['-ss', '1.000']);
      expect(a3.sublist(i + 2, i + 6), <String>['-ss', '2.000', '-t', '1.000']);
      expect(source.resolvedContainer, AsrPcmContainer.s16le);
      expect(backend.timeouts.first, const Duration(seconds: 60));
      expect(leftovers(), isEmpty, reason: '临时目录须清理');
    });

    test('startSample 非整毫秒：向下取整寻址、多要 1 ms、丢头截尾后边界仍精确', () async {
      // 37 = 2 ms（32 样本）+ 5 样本。ffmpeg 会从样本 32 起给 1.001 s = 16016 个样本。
      final List<int> ramp = List<int>.generate(16016, (int i) => 32 + i);
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        _Scripted(bytes: _s16le(ramp)),
        _Scripted(bytes: _s16le(List<int>.filled(3, 9))), // 尾块只剩 3 个（≤ 丢头数）
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );

      final List<AsrPcmChunk> chunks = await source
          .decode(input.path, startSample: 37, chunkSeconds: 1)
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks[0].startSample, 37);
      expect(chunks[0].samples.length, 16000);
      expect(chunks[0].samples[0] * 32768, closeTo(37, 1e-3));
      expect(chunks[0].samples[15999] * 32768, closeTo(16036, 1e-3));
      final List<String> a0 = backend.calls[0];
      final int i0 = a0.indexOf('-i');
      expect(a0.sublist(i0 + 2, i0 + 6), <String>[
        '-ss',
        '0.002',
        '-t',
        '1.001',
      ]);
      final List<String> a1 = backend.calls[1];
      final int i1 = a1.indexOf('-i');
      // 第二块起点 16037 样本 = 1002.3125 ms → 1002 ms。
      expect(a1.sublist(i1 + 2, i1 + 6), <String>[
        '-ss',
        '1.002',
        '-t',
        '1.001',
      ]);
    });

    test('mov 回退：首块 s16le 报 not-known → 切 mov 重跑并缓存', () async {
      final Uint8List pcmA = _s16le(List<int>.filled(16000, 111));
      final Uint8List pcmB = _s16le(List<int>.filled(16000, -222));
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        const _Scripted(bytes: null, returnCode: 127, output: _kNoS16le),
        _Scripted(bytes: _mov(pcmA)),
        _Scripted(bytes: _mov(pcmB, largesize: true)),
        _Scripted(bytes: _mov(const <int>[])), // EOF：空 mdat
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );

      final List<AsrPcmChunk> chunks =
          await source.decode(input.path, chunkSeconds: 1).toList();

      expect(chunks.map((AsrPcmChunk c) => c.startSample), <int>[0, 16000]);
      expect(chunks[0].samples[0], closeTo(111 / 32768, 1e-7));
      expect(chunks[1].samples[0], closeTo(-222 / 32768, 1e-7));
      expect(backend.calls, hasLength(4));
      expect(backend.calls[0], containsAllInOrder(<String>['-f', 's16le']));
      expect(backend.calls[0].last, endsWith('.pcm'));
      for (final List<String> args in backend.calls.sublist(1)) {
        expect(args, containsAllInOrder(<String>['-f', 'mov']));
        expect(args, containsAllInOrder(<String>['-c:a', 'pcm_s16le']));
        expect(args.last, endsWith('.mov'));
      }
      // 重跑的是同一块（同样的 -t、无 -ss）。
      expect(backend.calls[1].where((String a) => a == '-ss'), isEmpty);
      expect(source.resolvedContainer, AsrPcmContainer.mov);

      // 第二次 decode 不再试探 s16le。
      backend.script
        ..clear()
        ..addAll(<_Scripted>[
          _Scripted(bytes: _mov(pcmA)),
          _Scripted(bytes: _mov(const <int>[])),
        ]);
      backend.calls.clear();
      await source.decode(input.path, chunkSeconds: 1).drain<void>();
      expect(backend.calls, hasLength(2));
      expect(backend.calls[0], containsAllInOrder(<String>['-f', 'mov']));
      expect(leftovers(), isEmpty);
    });

    test('mov 回退输出不是合法 BMFF → AsrPcmDecodeException', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        const _Scripted(bytes: null, returnCode: 127, output: _kNoS16le),
        const _Scripted(bytes: <int>[1, 2, 3, 4, 5, 6, 7, 8, 9]),
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      await expectLater(
        source.decode(input.path, chunkSeconds: 1).toList(),
        throwsA(
          isA<AsrPcmDecodeException>().having(
            (AsrPcmDecodeException e) => e.message,
            'message',
            contains('not parseable'),
          ),
        ),
      );
      expect(leftovers(), isEmpty);
    });

    test('非零退出码 → 抛 AsrPcmDecodeException 并带日志尾部', () async {
      final String longLog =
          '${'banner line\n' * 80}Invalid data found when processing input';
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        _Scripted(bytes: null, returnCode: 1, output: longLog),
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      await expectLater(
        source.decode(input.path).toList(),
        throwsA(
          isA<AsrPcmDecodeException>()
              .having(
                (AsrPcmDecodeException e) => e.audioPath,
                'audioPath',
                input.path,
              )
              .having(
                (AsrPcmDecodeException e) => e.message,
                'message',
                allOf(
                  contains('ffmpeg exit 1'),
                  contains('Invalid data found'),
                ),
              )
              .having(
                (AsrPcmDecodeException e) => e.message.length,
                'message length（日志只带尾部 500 字）',
                lessThan(kAsrPcmLogTailChars + 200),
              ),
        ),
      );
      expect(source.resolvedContainer, isNull, reason: '普通失败不该切容器');
      expect(leftovers(), isEmpty);
    });

    test('超时（returnCode null）→ AsrPcmDecodeException 指明超时', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        const _Scripted(bytes: null, returnCode: null),
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      await expectLater(
        source.decode(input.path, chunkSeconds: 600).toList(),
        throwsA(
          isA<AsrPcmDecodeException>().having(
            (AsrPcmDecodeException e) => e.message,
            'message',
            contains('timed out after 1230s'),
          ),
        ),
      );
      expect(backend.timeouts.single, const Duration(seconds: 1230));
    });

    test('exit 0 但没产出文件 → AsrPcmDecodeException', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        const _Scripted(bytes: null, returnCode: 0),
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      await expectLater(
        source.decode(input.path).toList(),
        throwsA(
          isA<AsrPcmDecodeException>().having(
            (AsrPcmDecodeException e) => e.message,
            'message',
            contains('no output file'),
          ),
        ),
      );
    });

    test('ffmpeg 不存在（ProcessException）→ 包成 AsrPcmDecodeException', () async {
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: _MissingFfmpegBackend(),
        tempDir: tempRoot,
        parallelism: 1,
      );
      await expectLater(
        source.decode(input.path).toList(),
        throwsA(
          isA<AsrPcmDecodeException>().having(
            (AsrPcmDecodeException e) => e.message,
            'message',
            contains('ffmpeg launch failed'),
          ),
        ),
      );
      expect(await source.probeDurationMs(input.path), isNull);
      expect(leftovers(), isEmpty);
    });

    test('输入文件不存在 → 抛且不建临时目录', () async {
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: _FakeFfmpegBackend(const <_Scripted>[]),
        tempDir: tempRoot,
        parallelism: 1,
      );
      await expectLater(
        source.decode('${tempRoot.path}/missing.mp3').toList(),
        throwsA(isA<AsrPcmDecodeException>()),
      );
      expect(leftovers(), isEmpty);
    });

    test('非法参数 → ArgumentError', () {
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: _FakeFfmpegBackend(const <_Scripted>[]),
        tempDir: tempRoot,
        parallelism: 1,
      );
      expect(
        () => source.decode(input.path, startSample: -1).toList(),
        throwsArgumentError,
      );
      expect(
        () => source.decode(input.path, chunkSeconds: 0).toList(),
        throwsArgumentError,
      );
    });

    test('Stream 中途取消：临时目录仍被清理、不再跑后续块', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        _Scripted(bytes: _s16le(List<int>.filled(16000, 1))),
        _Scripted(bytes: _s16le(List<int>.filled(16000, 2))),
        _Scripted(bytes: _s16le(List<int>.filled(16000, 3))),
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      int seen = 0;
      await for (final AsrPcmChunk _ in source.decode(
        input.path,
        chunkSeconds: 1,
      )) {
        seen++;
        if (seen == 1) break; // 取消订阅
      }
      expect(seen, 1);
      expect(backend.calls.length, lessThanOrEqualTo(2));
      expect(leftovers(), isEmpty);
    });

    test('并行：最多 parallelism 块同时在解，块乱序完成也按块序出、样本一致', () async {
      // 第 0 块最慢、第 2 块最快：若按完成顺序出就乱了。
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        <_Scripted>[
          _Scripted(bytes: _s16le(List<int>.filled(16000, 1))),
          _Scripted(bytes: _s16le(List<int>.filled(16000, 2))),
          _Scripted(bytes: _s16le(List<int>.filled(16000, 3))),
          _Scripted(bytes: _s16le(List<int>.filled(16000, 4))),
          _Scripted(bytes: _s16le(List<int>.filled(4000, 5))),
          const _Scripted(bytes: <int>[]), // EOF
        ],
        delays: const <Duration>[
          Duration(milliseconds: 60),
          Duration(milliseconds: 30),
          Duration(milliseconds: 5),
        ],
      );
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 3,
      );
      final List<AsrPcmChunk> chunks =
          await source.decode(input.path, chunkSeconds: 1).toList();
      expect(chunks.map((AsrPcmChunk c) => c.startSample), <int>[
        0,
        16000,
        32000,
        48000,
        64000,
      ]);
      expect(chunks.map((AsrPcmChunk c) => c.samples.length), <int>[
        16000,
        16000,
        16000,
        16000,
        4000,
      ]);
      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].samples[0], closeTo((i + 1) / 32768, 1e-7));
      }
      expect(backend.maxActive, 3, reason: '3 块真的同时在跑');
      // 每块的 -ss/-t 按块序算：第 i 块起点 i s（预滚 2 s：第 3 块输入端 -ss 1）。
      final List<String> a3 = backend.calls[3];
      final int i3 = a3.indexOf('-i');
      expect(a3.sublist(i3 - 2, i3), <String>['-ss', '1.000']);
      expect(a3.sublist(i3 + 2, i3 + 4), <String>['-ss', '2.000']);
      // EOF 之后最多再多发 parallelism−1 块（都解出空），不会无限发。
      expect(backend.calls.length, inInclusiveRange(6, 8));
      expect(leftovers(), isEmpty, reason: '在飞的块结束后才删目录');
    });

    test('并行 + 中途取消：在飞的块跑完后目录才清理，不再新发块', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        List<_Scripted>.generate(
          8,
          (int i) => _Scripted(bytes: _s16le(List<int>.filled(16000, i + 1))),
        ),
        delays: List<Duration>.filled(8, const Duration(milliseconds: 20)),
      );
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 3,
      );
      int seen = 0;
      await for (final AsrPcmChunk _ in source.decode(
        input.path,
        chunkSeconds: 1,
      )) {
        seen++;
        if (seen == 2) break;
      }
      expect(seen, 2);
      // 拉了 2 块：最多发 2 + parallelism 块。
      expect(backend.calls.length, lessThanOrEqualTo(5));
      expect(backend.active, 0, reason: '取消时等在飞的块结束');
      expect(leftovers(), isEmpty);
    });

    test('并行 + mov 回退：并行起跑的几块各自重跑一次，块序与样本不变', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(<_Scripted>[
        // 前两块并行、都按 s16le 起跑、都报缺 muxer。
        const _Scripted(bytes: null, returnCode: 127, output: _kNoS16le),
        const _Scripted(bytes: null, returnCode: 127, output: _kNoS16le),
        // 各自切 mov 重跑（顺序：谁先失败谁先重跑，这里两块同步失败按块序）。
        _Scripted(bytes: _mov(_s16le(List<int>.filled(16000, 7)))),
        _Scripted(bytes: _mov(_s16le(List<int>.filled(16000, 8)))),
        _Scripted(bytes: _mov(_s16le(List<int>.filled(16000, 9)))),
        // EOF（mov 模式下空块也是合法 mov）；并行多发的那块也要有。
        _Scripted(bytes: _mov(const <int>[])),
        _Scripted(bytes: _mov(const <int>[])),
      ]);
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 2,
      );
      final List<AsrPcmChunk> chunks =
          await source.decode(input.path, chunkSeconds: 1).toList();
      expect(chunks.map((AsrPcmChunk c) => c.startSample), <int>[
        0,
        16000,
        32000,
      ]);
      expect(chunks[0].samples[0], closeTo(7 / 32768, 1e-7));
      expect(chunks[1].samples[0], closeTo(8 / 32768, 1e-7));
      expect(chunks[2].samples[0], closeTo(9 / 32768, 1e-7));
      expect(source.resolvedContainer, AsrPcmContainer.mov);
      // 前两次 s16le，之后全是 mov。
      expect(backend.calls[0], containsAllInOrder(<String>['-f', 's16le']));
      expect(backend.calls[1], containsAllInOrder(<String>['-f', 's16le']));
      for (final List<String> args in backend.calls.skip(2)) {
        expect(args, containsAllInOrder(<String>['-f', 'mov']));
      }
      expect(leftovers(), isEmpty);
    });

    test('probeDurationMs 走 runProbe 并解析 JSON', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        const <_Scripted>[],
        probeOutput: '{"format":{"duration":"3723.456000"}}',
      );
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      expect(await source.probeDurationMs(input.path), 3723456);
      expect(backend.probeCalls.single, <String>[
        '-v', 'quiet', '-print_format', 'json', '-show_entries', //
        'format=duration', input.path,
      ]);
      expect(backend.calls, isEmpty, reason: '探时长不该跑 ffmpeg');
    });

    test('probeDurationMs：ffprobe 非零退出 / 文件不存在 → null', () async {
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        const <_Scripted>[],
        probeOutput: '',
        probeCode: 1,
      );
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: backend,
        tempDir: tempRoot,
        parallelism: 1,
      );
      expect(await source.probeDurationMs(input.path), isNull);
      expect(await source.probeDurationMs('${tempRoot.path}/nope.m4b'), isNull);
    });
  });

  group('真 ffmpeg 集成（PATH）', () {
    final String? ffmpeg = _findOnPath('ffmpeg');
    final String? ffprobe = _findOnPath('ffprobe');
    final String? skip = ffmpeg == null || ffprobe == null
        ? 'PATH 上没有 ffmpeg/ffprobe，跳过真解码对照'
        : null;

    late Directory fixtures;
    late String mp3Path;
    late String vbrMp3Path;
    late String coveredMp3Path;
    late String m4bPath;

    Future<void> gen(List<String> args) async {
      final ProcessResult r = await Process.run(ffmpeg!, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        ...args,
      ]);
      expect(r.exitCode, 0, reason: 'fixture generation failed: ${r.stderr}');
    }

    setUpAll(() async {
      if (skip != null) return;
      fixtures = Directory.systemTemp.createTempSync('fushi_asr_pcm_itest_');
      final String sep = Platform.pathSeparator;
      mp3Path = '${fixtures.path}${sep}tone.mp3';
      vbrMp3Path = '${fixtures.path}${sep}tone_vbr.mp3';
      coveredMp3Path = '${fixtures.path}${sep}tone_cover.mp3';
      m4bPath = '${fixtures.path}${sep}tone.m4b';
      final String cover = '${fixtures.path}${sep}cover.png';
      const String sine = 'sine=frequency=440:duration=30';
      await gen(<String>[
        '-f', 'lavfi', '-i', sine, '-c:a', 'libmp3lame', //
        '-b:a', '128k', mp3Path,
      ]);
      await gen(<String>[
        '-f', 'lavfi', '-i', sine, '-c:a', 'libmp3lame', //
        '-q:a', '5', vbrMp3Path,
      ]);
      await gen(<String>['-f', 'lavfi', '-i', sine, '-c:a', 'aac', m4bPath]);
      await gen(<String>[
        '-f', 'lavfi', '-i', 'color=red:size=64x64:duration=1', //
        '-frames:v', '1', cover,
      ]);
      // 带封面的有声书 mp3：attached_pic 视频流必须被 -map 0:a:0 / -vn 排除。
      await gen(<String>[
        '-f', 'lavfi', '-i', sine, '-i', cover, '-map', '0:a', '-map', '1:v', //
        '-c:a', 'libmp3lame', '-b:a', '128k', '-c:v', 'mjpeg', //
        '-disposition:v', 'attached_pic', '-id3v2_version', '3', coveredMp3Path,
      ]);
    });

    tearDownAll(() {
      if (skip != null) return;
      if (fixtures.existsSync()) fixtures.deleteSync(recursive: true);
    });

    test('probeDurationMs ≈ 30 s', () async {
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: _ExecutableFfmpegBackend(ffmpeg!, ffprobe!),
        tempDir: tempRoot,
        parallelism: 1,
      );
      expect(await source.probeDurationMs(mp3Path), closeTo(30000, 60));
      expect(await source.probeDurationMs(m4bPath), closeTo(30000, 60));
    }, skip: skip);

    for (final (String label, String Function() path, int tailLsb, int tail)
        in <(String, String Function(), int, int)>[
      ('mp3 CBR', () => mp3Path, 2, 0),
      ('mp3 VBR', () => vbrMp3Path, 2, 0),
      ('mp3 带封面', () => coveredMp3Path, 2, 0),
      // AAC：寻址后 EOF 冲洗的舍入不同，文件尾最后 ~240 个样本实测 ≤ 12/32768。
      ('m4b (aac)', () => m4bPath, 16, 512),
    ]) {
      test('$label：chunkSeconds=7 分块拼接与整段解码逐样本一致（|diff| ≤ 2/32768）', () async {
        final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
          backend: _ExecutableFfmpegBackend(ffmpeg!, ffprobe!),
          tempDir: tempRoot,
        );
        final Float32List ref = await _decodeWhole(ffmpeg, path());
        expect(ref.length, closeTo(30 * 16000, 16));
        final Float32List got = await _collect(
          source.decode(path(), chunkSeconds: 7),
          expectedStart: 0,
          chunkSamples: 7 * 16000,
        );
        final ({int maxDiffLsb, int firstBadIndex, int badCount}) body =
            _compare(ref, got, ignoreTailSamples: tail);
        expect(
          body.badCount,
          0,
          reason: '$label 块边界失真：首个坏样本 ${body.firstBadIndex}，'
              '最大 |diff| ${body.maxDiffLsb}/32768',
        );
        if (tail > 0) {
          final ({int maxDiffLsb, int firstBadIndex, int badCount}) tailCmp =
              _compare(
            Float32List.sublistView(ref, ref.length - tail),
            Float32List.sublistView(got, got.length - tail),
            toleranceLsb: tailLsb,
          );
          expect(
            tailCmp.badCount,
            0,
            reason: '$label 文件尾差异超 $tailLsb/32768：'
                '${tailCmp.maxDiffLsb}',
          );
        }
        expect(
          source.resolvedContainer,
          AsrPcmContainer.s16le,
          reason: '全量 ffmpeg 有 s16le muxer，不该回退 mov',
        );
        expect(leftovers(), isEmpty);
      }, skip: skip);
    }

    test('非整毫秒 startSample 续解：与整段解码的对应尾段逐样本一致', () async {
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: _ExecutableFfmpegBackend(ffmpeg!, ffprobe!),
        tempDir: tempRoot,
        parallelism: 1,
      );
      const int start = 16000 * 11 + 37; // 11 s + 37 样本（37 % 16 = 5）
      final Float32List ref = await _decodeWhole(ffmpeg, mp3Path);
      final Float32List got = await _collect(
        source.decode(mp3Path, startSample: start, chunkSeconds: 7),
        expectedStart: start,
        chunkSamples: 7 * 16000,
      );
      final ({int maxDiffLsb, int firstBadIndex, int badCount}) cmp = _compare(
        Float32List.sublistView(ref, start),
        got,
      );
      expect(
        cmp.badCount,
        0,
        reason: '首个坏样本 ${cmp.firstBadIndex}，最大 |diff| ${cmp.maxDiffLsb}',
      );
    }, skip: skip);

    test('捆绑 ffmpeg-min（缺 s16le muxer）真跑 mov 回退，与全量 ffmpeg 整段解码一致', () async {
      final String? min = _bundledFfmpegMin();
      if (min == null) {
        markTestSkipped('仓库里没有 Windows 入库的 third_party/ffmpeg-min 二进制');
        return;
      }
      final FfmpegAsrPcmSource source = FfmpegAsrPcmSource(
        backend: _ExecutableFfmpegBackend(min, ffprobe!),
        tempDir: tempRoot,
        parallelism: 1,
      );
      final Float32List ref = await _decodeWhole(ffmpeg!, coveredMp3Path);
      final Float32List got = await _collect(
        source.decode(coveredMp3Path, chunkSeconds: 7),
        expectedStart: 0,
        chunkSamples: 7 * 16000,
      );
      // 入库的 ffmpeg-min（n7.1.5）与 PATH 全量 ffmpeg 重采样器舍入实测差 ≤ 1/32768。
      final ({int maxDiffLsb, int firstBadIndex, int badCount}) cmp = _compare(
        ref,
        got,
      );
      expect(
        cmp.badCount,
        0,
        reason: '首个坏样本 ${cmp.firstBadIndex}，最大 |diff| ${cmp.maxDiffLsb}',
      );
      expect(got.length, 30 * 16000);
      // 入库二进制一旦重建带 s16le muxer，这条断言会翻红——那正是删除 mov 分支的信号。
      expect(
        source.resolvedContainer,
        AsrPcmContainer.mov,
        reason: '入库 ffmpeg-min 目前没有 s16le muxer，应走 mov 回退；'
            '若已重建带 s16le，请按 asr_pcm_source.dart 文件头说明删除 mov 分支',
      );
      expect(leftovers(), isEmpty);
    }, skip: skip);
  });
}
