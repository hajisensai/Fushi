// 反馈视频的本机准备（feedback_video.dart）：魔数嗅探与服务端同口径、码率按时长装进
// 50 MB、转码参数（720p / libx264 / aac / faststart）、转码不可用时原样上传但仍受上限约束。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:path/path.dart' as p;

const List<int> _mp4Head = <int>[
  0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0, //
];
const List<int> _movHead = <int>[
  0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20, 0, 0, 0, 0, //
];
const List<int> _webmHead = <int>[0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86];

/// 假 ffmpeg：`-i` 探时长时回 [durationLine]；转码时按 [transcode] 决定产物。
class _FakeFfmpeg implements FfmpegBackend {
  _FakeFfmpeg({this.durationLine, this.transcode, this.throws = false});

  final String? durationLine;

  /// 返回 null = 转码失败（非零退出）；否则写这么多字节到输出。
  final int? Function()? transcode;
  final bool throws;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    if (throws) throw const ProcessException('ffmpeg', <String>[], 'missing');
    if (!args.contains('-c:v')) {
      return FfmpegRunResult(returnCode: 1, output: durationLine ?? '');
    }
    final int? bytes = transcode?.call();
    if (bytes == null) {
      return const FfmpegRunResult(returnCode: 1, output: 'Conversion failed!');
    }
    File(args.last).writeAsBytesSync(Uint8List(bytes));
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}

/// 假观察式后端：转码一直不结束，直到 [FfmpegWatch.cancel] 完成（模拟真会话被强杀：
/// 半成品已写了一部分，结果 `returnCode: null`）。
class _BlockingWatchedFfmpeg extends _FakeFfmpeg
    implements FfmpegWatchedRunner {
  _BlockingWatchedFfmpeg() : super(durationLine: 'Duration: 00:01:00.00');

  final Completer<void> started = Completer<void>();
  bool killed = false;

  @override
  Future<FfmpegRunResult> runWatched(
    List<String> args,
    FfmpegWatch watch,
  ) async {
    calls.add(args);
    File(args.last).writeAsBytesSync(Uint8List(100));
    watch.onProgress?.call(const Duration(seconds: 10));
    started.complete();
    await watch.cancel;
    killed = true;
    return const FfmpegRunResult(
      returnCode: null,
      output: kFfmpegCancelledMarker,
    );
  }
}

void main() {
  late Directory root;
  late Directory work;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_video_prep_');
    work = Directory(p.join(root.path, 'work'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  File source(List<int> head, {int length = 4096}) {
    final File f = File(p.join(root.path, 'src.bin'));
    final RandomAccessFile raf = f.openSync(mode: FileMode.write);
    raf.writeFromSync(head);
    raf.truncateSync(length);
    raf.closeSync();
    return f;
  }

  test('魔数嗅探：mp4 / mov(qt) / webm，别的不认', () {
    expect(sniffFeedbackVideoType(_mp4Head), 'video/mp4');
    expect(sniffFeedbackVideoType(_movHead), 'video/quicktime');
    expect(sniffFeedbackVideoType(_webmHead), 'video/webm');
    expect(sniffFeedbackVideoType(<int>[0x89, 0x50, 0x4e, 0x47]), isNull);
    expect(sniffFeedbackVideoType(const <int>[]), isNull);
  });

  test('码率：短视频封顶 2 Mbps；长视频压低到装进 50 MB；装不下返回 null', () {
    expect(feedbackVideoBitrateKbps(null), kFeedbackVideoMaxKbps);
    expect(feedbackVideoBitrateKbps(60 * 1000), kFeedbackVideoMaxKbps);
    final int tenMin = feedbackVideoBitrateKbps(10 * 60 * 1000)!;
    expect(tenMin, lessThan(kFeedbackVideoMaxKbps));
    // 10 分钟 × (视频 + 音频) 不超过上限。
    expect(
      (tenMin + kFeedbackVideoAudioKbps) * 1000 / 8 * 600,
      lessThanOrEqualTo(FeedbackLimits.videoMaxBytes),
    );
    expect(feedbackVideoBitrateKbps(60 * 60 * 1000), isNull);
  });

  test('转码参数：短边 ≤720、libx264 平均码率、aac、faststart、mp4', () {
    final List<String> args = buildFeedbackVideoTranscodeArgs(
      input: 'in.mov',
      output: 'out.mp4',
      videoKbps: 1500,
    );
    expect(args.sublist(args.indexOf('-i'), args.indexOf('-i') + 2), <String>[
      '-i',
      'in.mov',
    ]);
    expect(args[args.indexOf('-c:v') + 1], 'libx264');
    expect(args[args.indexOf('-b:v') + 1], '1500k');
    expect(args[args.indexOf('-c:a') + 1], 'aac');
    expect(args[args.indexOf('-movflags') + 1], '+faststart');
    expect(args[args.indexOf('-vf') + 1], contains('720'));
    expect(args, contains('0:a:0?'));
    expect(args.last, 'out.mp4');
  });

  test('时长解析', () {
    expect(
      parseFeedbackVideoDurationMs('  Duration: 00:01:02.50, start: 0'),
      62500,
    );
    expect(parseFeedbackVideoDurationMs('Duration: N/A'), isNull);
  });

  test('转码成功：用转码产物（mp4），原件不动', () async {
    final File src = source(_movHead, length: 8000);
    final PreparedFeedbackVideo v = await prepareFeedbackVideo(
      src,
      workDir: work,
      backend: _FakeFfmpeg(
        durationLine: 'Duration: 00:00:10.00',
        transcode: () => 3000,
      ),
    );
    expect(v.transcoded, isTrue);
    expect(v.contentType, 'video/mp4');
    expect(v.bytes, 3000);
    expect(p.isWithin(work.path, v.file.path), isTrue);
    expect(src.lengthSync(), 8000);
  });

  test('ffmpeg 不可用：原样上传（复制进工作目录，类型按魔数）', () async {
    final File src = source(_webmHead, length: 5000);
    final PreparedFeedbackVideo v = await prepareFeedbackVideo(
      src,
      workDir: work,
      backend: _FakeFfmpeg(throws: true),
    );
    expect(v.transcoded, isFalse);
    expect(v.contentType, 'video/webm');
    expect(v.bytes, 5000);
    expect(p.isWithin(work.path, v.file.path), isTrue);
    expect(src.existsSync(), isTrue);
  });

  test('转码失败且原件超 50 MB：报太大，不偷偷截断', () async {
    final File src = source(_mp4Head, length: FeedbackLimits.videoMaxBytes + 1);
    await expectLater(
      prepareFeedbackVideo(
        src,
        workDir: work,
        backend: _FakeFfmpeg(transcode: () => null),
      ),
      throwsA(isA<FeedbackVideoTooLargeException>()),
    );
  });

  test('不是视频且转不了：报不支持', () async {
    final File src = source(<int>[0x89, 0x50, 0x4e, 0x47]);
    await expectLater(
      prepareFeedbackVideo(
        src,
        workDir: work,
        backend: _FakeFfmpeg(transcode: () => null),
      ),
      throwsA(isA<FeedbackVideoUnsupportedException>()),
    );
  });

  test('一小时长视频：最低码率也装不下，不转码；原件超上限报太大', () async {
    final _FakeFfmpeg ffmpeg = _FakeFfmpeg(
      durationLine: 'Duration: 01:00:00.00',
      transcode: () => 1000,
    );
    await expectLater(
      prepareFeedbackVideo(
        source(_mp4Head, length: FeedbackLimits.videoMaxBytes + 1),
        workDir: work,
        backend: ffmpeg,
      ),
      throwsA(isA<FeedbackVideoTooLargeException>()),
    );
    expect(ffmpeg.calls.where((List<String> a) => a.contains('-c:v')), isEmpty);
  });

  test('一小时长视频但原件本身 ≤ 上限（低码率录屏）：原样上传', () async {
    final PreparedFeedbackVideo v = await prepareFeedbackVideo(
      source(_mp4Head, length: 6000),
      workDir: work,
      backend: _FakeFfmpeg(
        durationLine: 'Duration: 01:00:00.00',
        transcode: () => 1000,
      ),
    );
    expect(v.transcoded, isFalse);
    expect(v.bytes, 6000);
  });

  test('转码参数：画质与旧方案同档（veryfast + 双三次），提速靠高帧率源先降帧再缩放，低帧率不补帧', () {
    List<String> argsFor(double? fps) => buildFeedbackVideoTranscodeArgs(
      input: 'in.mp4',
      output: 'out.mp4',
      videoKbps: 2000,
      sourceFps: fps,
    );
    String vf(double? fps) {
      final List<String> a = argsFor(fps);
      return a[a.indexOf('-vf') + 1];
    }

    final List<String> args = argsFor(60);
    expect(args[args.indexOf('-preset') + 1], kFeedbackVideoPreset);
    // 画质门槛（BUG-3489 实测）：ultrafast / 双线性在密集小字上低于旧方案，不许换回去。
    expect(kFeedbackVideoPreset, 'veryfast');
    expect(kFeedbackVideoScaleFlags, 'bicubic');
    // 降帧必须在滤镜链最前面（先丢帧再缩放），不是输出端的 -fpsmax。
    expect(vf(60), startsWith('fps=$kFeedbackVideoMaxFps,scale='));
    expect(vf(60), endsWith(':flags=bicubic'));
    expect(args, isNot(contains('-fpsmax')));
    expect(vf(120), startsWith('fps=30,'));
    // 30 / 29.97 / 24 fps 与探不到帧率：不加 fps 滤镜（它会把低帧率补帧升上去）。
    expect(vf(30), startsWith('scale='));
    expect(vf(29.97), startsWith('scale='));
    expect(vf(24), startsWith('scale='));
    expect(vf(null), startsWith('scale='));
  });

  test('帧率解析：取第一条视频流的 fps', () {
    expect(
      parseFeedbackVideoFps(
        '  Stream #0:0[0x1](und): Video: h264 (avc1), yuv420p, 1080x2400, '
        '15128 kb/s, 60 fps, 60 tbr, 15360 tbn (default)\n'
        '  Stream #0:1: Audio: aac, 48000 Hz',
      ),
      60,
    );
    expect(
      parseFeedbackVideoFps('Stream #0:0: Video: h264, 1920x1080, 29.97 fps'),
      29.97,
    );
    expect(parseFeedbackVideoFps('Stream #0:0: Audio: aac'), isNull);
  });

  test('高帧率源：探到的帧率传进转码参数（先降帧）', () async {
    final _FakeFfmpeg ffmpeg = _FakeFfmpeg(
      durationLine:
          'Duration: 00:00:10.00\n  Stream #0:0: Video: h264, 1080x2400, 60 fps, 60 tbr',
      transcode: () => 3000,
    );
    await prepareFeedbackVideo(
      source(_movHead, length: 8000),
      workDir: work,
      backend: ffmpeg,
    );
    final List<String> args = ffmpeg.calls.firstWhere(
      (List<String> a) => a.contains('-c:v'),
    );
    expect(args[args.indexOf('-vf') + 1], startsWith('fps=30,'));
  });

  test('1080p：短边 1080、码率封顶 4 Mbps；太长自动退回 720p', () {
    final List<String> args = buildFeedbackVideoTranscodeArgs(
      input: 'in.mp4',
      output: 'out.mp4',
      videoKbps: 4000,
      quality: FeedbackVideoQuality.p1080,
    );
    expect(args[args.indexOf('-vf') + 1], contains('1080'));
    expect(args[args.indexOf('-vf') + 1], isNot(contains('720')));

    // 1 分钟：1080p 满码率。
    final ({FeedbackVideoQuality quality, int kbps}) short =
        planFeedbackVideoTranscode(60 * 1000, FeedbackVideoQuality.p1080)!;
    expect(short.quality, FeedbackVideoQuality.p1080);
    expect(short.kbps, FeedbackVideoQuality.p1080.maxKbps);
    // 2 分钟：仍是 1080p，码率压低到装进上限。
    final ({FeedbackVideoQuality quality, int kbps}) mid =
        planFeedbackVideoTranscode(120 * 1000, FeedbackVideoQuality.p1080)!;
    expect(mid.quality, FeedbackVideoQuality.p1080);
    expect(
      (mid.kbps + kFeedbackVideoAudioKbps) * 1000 / 8 * 120,
      lessThanOrEqualTo(FeedbackLimits.videoMaxBytes),
    );
    // 5 分钟：1080p 码率不够，退回 720p。
    final ({FeedbackVideoQuality quality, int kbps}) long =
        planFeedbackVideoTranscode(300 * 1000, FeedbackVideoQuality.p1080)!;
    expect(long.quality, FeedbackVideoQuality.p720);
    // 一小时：哪一档都装不下。
    expect(
      planFeedbackVideoTranscode(3600 * 1000, FeedbackVideoQuality.p1080),
      isNull,
    );
    // 默认 720p 不受影响。
    expect(
      planFeedbackVideoTranscode(60 * 1000, FeedbackVideoQuality.p720)!.kbps,
      kFeedbackVideoMaxKbps,
    );
  });

  test('选 1080p 但视频太长：按 720p 转并通知调用方', () async {
    final _FakeFfmpeg ffmpeg = _FakeFfmpeg(
      durationLine: 'Duration: 00:05:00.00',
      transcode: () => 3000,
    );
    int downgraded = 0;
    final PreparedFeedbackVideo v = await prepareFeedbackVideo(
      source(_movHead, length: 8000),
      workDir: work,
      backend: ffmpeg,
      quality: FeedbackVideoQuality.p1080,
      onDowngraded: () => downgraded++,
    );
    expect(downgraded, 1);
    expect(v.quality, FeedbackVideoQuality.p720);
    final List<String> args = ffmpeg.calls.firstWhere(
      (List<String> a) => a.contains('-c:v'),
    );
    expect(args[args.indexOf('-vf') + 1], contains('720'));
  });

  test('选 1080p 转完仍超上限：改转 720p 再来一次', () async {
    int round = 0;
    final _FakeFfmpeg ffmpeg = _FakeFfmpeg(
      durationLine: 'Duration: 00:01:00.00',
      transcode: () => ++round == 1 ? FeedbackLimits.videoMaxBytes + 1 : 3000,
    );
    int downgraded = 0;
    final PreparedFeedbackVideo v = await prepareFeedbackVideo(
      source(_movHead, length: FeedbackLimits.videoMaxBytes + 10),
      workDir: work,
      backend: ffmpeg,
      quality: FeedbackVideoQuality.p1080,
      onDowngraded: () => downgraded++,
    );
    expect(downgraded, 1);
    expect(v.quality, FeedbackVideoQuality.p720);
    expect(v.bytes, 3000);
    final List<List<String>> encodes = ffmpeg.calls
        .where((List<String> a) => a.contains('-c:v'))
        .toList();
    expect(encodes, hasLength(2));
    expect(encodes.first[encodes.first.indexOf('-vf') + 1], contains('1080'));
    expect(encodes.last[encodes.last.indexOf('-vf') + 1], contains('720'));
  });

  test('BUG-3489 取消：强杀转码、删半成品、抛取消，不退回原样上传', () async {
    final _BlockingWatchedFfmpeg ffmpeg = _BlockingWatchedFfmpeg();
    final Completer<void> cancel = Completer<void>();
    final List<double> progress = <double>[];
    final Future<PreparedFeedbackVideo> job = prepareFeedbackVideo(
      // 原件本身是 ≤ 上限的 mp4：没取消时转码失败会退回原样上传，取消必须不走这条。
      source(_mp4Head, length: 6000),
      workDir: work,
      backend: ffmpeg,
      onProgress: progress.add,
      cancel: cancel.future,
    );
    await ffmpeg.started.future;
    expect(progress, isNotEmpty);
    cancel.complete();
    await expectLater(job, throwsA(isA<FeedbackVideoCancelledException>()));
    expect(ffmpeg.killed, isTrue);
    expect(work.listSync(), isEmpty);
  });
}
