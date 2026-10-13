// 反馈视频的本机准备（feedback_video.dart）：魔数嗅探与服务端同口径、码率按时长装进
// 50 MB、转码参数（720p / libx264 / aac / faststart）、转码不可用时原样上传但仍受上限约束。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
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
}
