// BUG-3102：整轨抽取按进度判活，而不是按体积估总超时。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:test/test.dart';

/// 可控的假 ffmpeg 进程：测试往 stdout 写进度行、决定何时退出；kill 记账并让进程退出。
class _FakeProcess implements Process {
  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final List<ProcessSignal> killed = <ProcessSignal>[];

  // 被杀之后真进程也不会再写；忽略即可。
  void progress(int outTimeUs) => _out.isClosed
      ? null
      : _out.add(utf8.encode('out_time_us=$outTimeUs\nprogress=continue\n'));

  void stderrLine(String line) => _err.add(utf8.encode('$line\n'));

  Future<void> finish(int code) async {
    await _out.close();
    await _err.close();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    unawaited(finish(-9));
    return true;
  }

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  IOSink get stdin => throw UnimplementedError();
}

void main() {
  group('parseFfmpegProgressLine', () {
    test('只认 out_time_us，N/A 与其它键返回 null', () {
      expect(
        parseFfmpegProgressLine('out_time_us=1500000'),
        const Duration(milliseconds: 1500),
      );
      expect(parseFfmpegProgressLine('  out_time_us=0\r'), Duration.zero);
      expect(parseFfmpegProgressLine('out_time_us=N/A'), isNull);
      expect(parseFfmpegProgressLine('out_time_ms=1500000'), isNull);
      expect(parseFfmpegProgressLine('progress=continue'), isNull);
    });
  });

  group('watchFfmpegProcess', () {
    test('一直推进就不杀，哪怕总耗时远超 stallTimeout', () async {
      final _FakeProcess process = _FakeProcess();
      final List<Duration> seen = <Duration>[];
      final Future<FfmpegRunResult> result = watchFfmpegProcess(
        process,
        FfmpegWatch(
          stallTimeout: const Duration(milliseconds: 200),
          onProgress: seen.add,
        ),
        executable: 'ffmpeg',
        checkInterval: const Duration(milliseconds: 20),
      );
      // 总共跑 ~800 ms（4 倍 stallTimeout），但每 100 ms 推进一次。
      for (int i = 1; i <= 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        process.progress(i * 1000000);
      }
      await process.finish(0);
      final FfmpegRunResult r = await result;
      expect(process.killed, isEmpty);
      expect(r.returnCode, 0);
      expect(seen.last, const Duration(seconds: 8));
      expect(seen, hasLength(8));
    });

    test('进度停住超过 stallTimeout：强杀并返回 null + 卡死标记', () async {
      final _FakeProcess process = _FakeProcess();
      final Future<FfmpegRunResult> result = watchFfmpegProcess(
        process,
        const FfmpegWatch(stallTimeout: Duration(milliseconds: 150)),
        executable: 'ffmpeg',
        checkInterval: const Duration(milliseconds: 20),
      );
      process.progress(1000000);
      // 之后只重复同一个时间（ffmpeg 主循环还活着、但读不动）：不算推进。
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        process.progress(1000000);
      }
      final FfmpegRunResult r = await result;
      expect(process.killed, <ProcessSignal>[ProcessSignal.sigkill]);
      expect(r.returnCode, isNull);
      expect(r.output, contains('stalled'));
      expect(r.failureSummary, contains('stalled'));
    });

    test('取消：强杀、返回 null + 取消标记，不等卡死', () async {
      final _FakeProcess process = _FakeProcess();
      final Completer<void> cancel = Completer<void>();
      final Future<FfmpegRunResult> result = watchFfmpegProcess(
        process,
        FfmpegWatch(
          stallTimeout: const Duration(minutes: 5),
          cancel: cancel.future,
        ),
        executable: 'ffmpeg',
      );
      process.progress(1000000);
      cancel.complete();
      final FfmpegRunResult r = await result;
      expect(process.killed, <ProcessSignal>[ProcessSignal.sigkill]);
      expect(r.returnCode, isNull);
      expect(r.output, contains(kFfmpegCancelledMarker));
    });

    test('失败退出：原样带回退出码与 stderr', () async {
      final _FakeProcess process = _FakeProcess();
      final Future<FfmpegRunResult> result = watchFfmpegProcess(
        process,
        const FfmpegWatch(stallTimeout: Duration(seconds: 30)),
        executable: 'ffmpeg',
      );
      process.stderrLine('Stream map 0:s:3 matches no streams.');
      await process.finish(1);
      final FfmpegRunResult r = await result;
      expect(process.killed, isEmpty);
      expect(r.returnCode, 1);
      expect(r.output, contains('matches no streams'));
    });
  });

  test('CLI 前缀：不读 stdin、机器可读进度写 stdout、stderr 不刷进度行', () {
    expect(kFfmpegWatchedCliPrefix, <String>[
      '-nostdin',
      '-progress',
      'pipe:1',
      '-nostats',
    ]);
  });
}
