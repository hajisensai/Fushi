/// BUG-2938：ffmpeg 查询类命令（`-filters` 等）的输出写在 **stdout**，而
/// [FfmpegBackend.run] 只收 stderr——片段导出的滤镜探测曾经走 `run`，桌面 CLI 上
/// 恒为空表、硬字幕静默退成无字幕。本文件钉住两层：
/// ① 探测点 [queryFfmpegFilterNames] 只走 [FfmpegBackend.runQuery]，不走 `run`；
/// ② 真实 CLI 后端的 `runQuery` 确实把 stdout 收进 output（本机没有 ffmpeg 时 skip）。
library;

import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/media/video/video_clip_subtitle_burn.dart';
import 'package:test/test.dart';

/// 真实 ffmpeg `-filters` 表的一小段（含 overlay / subtitles）。
const String _kFiltersTable = '''
Filters:
  T.. = Timeline support
  .S. = Slice threading
 TSC overlay           VV->V      Overlay a video source on top of the input.
 ... subtitles         V->V       Render text subtitles onto input video using the libass library.
 ..C scale             V->V       Scale the input video size and/or convert the image format.
''';

/// 模拟桌面 CLI 的流分工：`run` 只交 stderr（查询表在 stdout，被丢掉 → 空），
/// `runQuery` 交 stdout+stderr。
class _StdoutSplitBackend implements FfmpegBackend {
  _StdoutSplitBackend({this.queryReturnCode = 0});

  final int queryReturnCode;
  final List<List<String>> runCalls = <List<String>>[];
  final List<List<String>> queryCalls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runCalls.add(args);
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) async {
    queryCalls.add(args);
    return FfmpegRunResult(returnCode: queryReturnCode, output: _kFiltersTable);
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '');
}

/// 本机 PATH 上的 ffmpeg 自己打印的滤镜表（stdout），没有 ffmpeg 返回 null。
String? _systemFiltersStdout() {
  try {
    final ProcessResult r = Process.runSync('ffmpeg', <String>[
      '-hide_banner',
      '-filters',
    ]);
    if (r.exitCode != 0) return null;
    return '${r.stdout}';
  } on ProcessException {
    return null;
  }
}

void main() {
  group('queryFfmpegFilterNames 走查询契约', () {
    test('滤镜表从 runQuery 取，run 一次都不调', () async {
      final _StdoutSplitBackend backend = _StdoutSplitBackend();
      final Set<String> filters = await queryFfmpegFilterNames(
        backend,
        const Duration(seconds: 5),
      );
      expect(filters, containsAll(<String>['overlay', 'subtitles', 'scale']));
      expect(ffmpegCanBurnClipSubtitles(filters), isTrue);
      expect(ffmpegHasLibassSubtitlesFilter(filters), isTrue);
      expect(backend.runCalls, isEmpty);
      expect(backend.queryCalls, <List<String>>[
        <String>['-hide_banner', '-filters'],
      ]);
    });

    test('非零退出按探测失败处理（空集合 = 不烧）', () async {
      final Set<String> filters = await queryFfmpegFilterNames(
        _StdoutSplitBackend(queryReturnCode: 1),
        const Duration(seconds: 5),
      );
      expect(filters, isEmpty);
    });

    test('蓝光包装后端把查询原样转给底层后端', () async {
      final _StdoutSplitBackend inner = _StdoutSplitBackend();
      final Set<String> filters = await queryFfmpegFilterNames(
        BlurayFfmpegBackend(inner),
        const Duration(seconds: 5),
      );
      expect(filters, contains('overlay'));
      expect(inner.queryCalls, hasLength(1));
      expect(inner.runCalls, isEmpty);
    });
  });

  group('真实 CLI 后端（本机 ffmpeg）', () {
    final String? systemTable = _systemFiltersStdout();
    final String? skip = systemTable == null ? '本机 PATH 上没有可用的 ffmpeg' : null;

    test('runFfmpegQueryProcess 收到 stdout 里的滤镜表', () async {
      final FfmpegRunResult r = await runFfmpegQueryProcess(
        'ffmpeg',
        const <String>['-hide_banner', '-filters'],
        const Duration(seconds: 30),
      );
      expect(r.returnCode, 0);
      final Set<String> names = parseFfmpegFilterNames(r.output);
      expect(names, contains('overlay'));
      expect(names, parseFfmpegFilterNames(systemTable!));
    }, skip: skip);

    test('CliFfmpegBackend 探测结果与 ffmpeg 自己打印的表一致', () async {
      // 显式覆盖到 PATH 的 ffmpeg，避免测试机上碰巧有捆绑 ffmpeg 影响结论。
      final String? previous = ffmpegPathOverride;
      ffmpegPathOverride = 'ffmpeg';
      addTearDown(() => ffmpegPathOverride = previous);
      final Set<String> filters = await queryFfmpegFilterNames(
        const CliFfmpegBackend(),
        const Duration(seconds: 30),
      );
      final Set<String> expected = parseFfmpegFilterNames(systemTable!);
      expect(filters, expected);
      expect(filters, contains('overlay'));
      // overlay 是 ffmpeg 内置滤镜，恒在 → 桌面片段导出能烧硬字幕。
      expect(ffmpegCanBurnClipSubtitles(filters), isTrue);
      if (expected.contains('subtitles')) {
        expect(filters, contains('subtitles'));
      }
    }, skip: skip);

    test('run 的契约不变：仍只收 stderr（stdout 留给 pipe:1 二进制输出）', () async {
      final FfmpegRunResult r = await runFfmpegProcess('ffmpeg', const <String>[
        '-hide_banner',
        '-filters',
      ], const Duration(seconds: 30));
      expect(parseFfmpegFilterNames(r.output), isEmpty);
    }, skip: skip);
  });
}
