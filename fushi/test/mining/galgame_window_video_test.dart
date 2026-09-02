import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/mining/galgame_window_video.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';

/// galgame「视频片段」封面：录制帧 → concat 计划 → ffmpeg 参数 → mp4 的纯函数与
/// fail-open 契约。ffmpeg 用假后端（真编码只能在带 libx264 的桌面 ffmpeg 上验）。
class _FakeFfmpeg implements FfmpegBackend {
  _FakeFfmpeg({
    this.probeOutput = '',
    this.encodeReturnCode = 0,
    this.writeOutput = true,
  });

  final String probeOutput;
  final int? encodeReturnCode;
  final bool writeOutput;
  final List<List<String>> runs = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs.add(List<String>.of(args));
    if (args.contains('null')) {
      return FfmpegRunResult(returnCode: 1, output: probeOutput);
    }
    if (writeOutput && encodeReturnCode == 0) {
      await File(args.last).writeAsBytes(<int>[0, 0, 0, 0x18, 0x66, 0x74]);
    }
    return FfmpegRunResult(returnCode: encodeReturnCode, output: '');
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError();
}

WindowRecordingFrame _frame(String path, int tickMs) =>
    WindowRecordingFrame(path: path, tickMs: tickMs);

void main() {
  group('planGalWindowVideoFrames', () {
    test('每帧时长 = 与下一帧的 tick 差；最后一帧至少 200ms', () {
      final List<GalWindowVideoFrameEntry> plan = planGalWindowVideoFrames(
        frames: <WindowRecordingFrame>[
          _frame('a.jpg', 1000),
          _frame('b.jpg', 1100),
          _frame('c.jpg', 1350),
        ],
        fromTickMs: 1000,
        toTickMs: 1400,
        audioDurationMs: null,
      );
      expect(plan.map((GalWindowVideoFrameEntry e) => e.path), <String>[
        'a.jpg',
        'b.jpg',
        'c.jpg',
      ]);
      expect(plan.map((GalWindowVideoFrameEntry e) => e.durationMs), <int>[
        100,
        250,
        200,
      ]);
    });

    test('最后一帧拉长到覆盖音频：max(200, 音频时长 - 已覆盖时长)', () {
      final List<GalWindowVideoFrameEntry> plan = planGalWindowVideoFrames(
        frames: <WindowRecordingFrame>[
          _frame('a.jpg', 0),
          _frame('b.jpg', 500),
        ],
        fromTickMs: 0,
        toTickMs: 600,
        audioDurationMs: 3000,
      );
      expect(plan.last.durationMs, 2500);
      final int total = plan.fold<int>(
        0,
        (int sum, GalWindowVideoFrameEntry e) => sum + e.durationMs,
      );
      expect(
        total,
        greaterThanOrEqualTo(3000),
        reason: '视频长度必须 ≥ 音频长度，混流后画面不能先于声音结束',
      );
    });

    test('区间前最后一帧作为起点帧（tick 钉到 from），区间后帧丢弃', () {
      final List<GalWindowVideoFrameEntry> plan = planGalWindowVideoFrames(
        frames: <WindowRecordingFrame>[
          _frame('old.jpg', 100),
          _frame('lead.jpg', 900),
          _frame('in1.jpg', 1200),
          _frame('in2.jpg', 1500),
          _frame('after.jpg', 2500),
        ],
        fromTickMs: 1000,
        toTickMs: 2000,
        audioDurationMs: null,
      );
      expect(plan.map((GalWindowVideoFrameEntry e) => e.path), <String>[
        'lead.jpg',
        'in1.jpg',
        'in2.jpg',
      ]);
      expect(plan.first.durationMs, 200, reason: 'lead 钉到 1000，到 in1 差 200');
    });

    test('不足 2 帧 → 空计划（调用方降级）', () {
      expect(
        planGalWindowVideoFrames(
          frames: <WindowRecordingFrame>[_frame('a.jpg', 1000)],
          fromTickMs: 0,
          toTickMs: 2000,
          audioDurationMs: 1000,
        ),
        isEmpty,
      );
      expect(
        planGalWindowVideoFrames(
          frames: <WindowRecordingFrame>[
            _frame('a.jpg', 10),
            _frame('b.jpg', 20),
          ],
          fromTickMs: 1000,
          toTickMs: 2000,
          audioDurationMs: null,
        ),
        isEmpty,
        reason: '区间内只有 lead 一帧，凑不成片段',
      );
    });

    test('tick 相同 / 乱序的帧只留第一张（concat 不吃 0 时长）', () {
      final List<GalWindowVideoFrameEntry> plan = planGalWindowVideoFrames(
        frames: <WindowRecordingFrame>[
          _frame('b.jpg', 200),
          _frame('a.jpg', 100),
          _frame('dup.jpg', 200),
          _frame('c.jpg', 300),
        ],
        fromTickMs: 0,
        toTickMs: 400,
        audioDurationMs: null,
      );
      expect(plan.map((GalWindowVideoFrameEntry e) => e.path), <String>[
        'a.jpg',
        'b.jpg',
        'c.jpg',
      ]);
      expect(
        plan.every((GalWindowVideoFrameEntry e) => e.durationMs > 0),
        isTrue,
      );
    });
  });

  group('buildGalWindowConcatList', () {
    test('ffconcat 头 + file/duration 对 + 末尾重复最后一帧；反斜杠转正斜杠', () {
      final String text = buildGalWindowConcatList(<GalWindowVideoFrameEntry>[
        (path: r'C:\tmp\f0.jpg', durationMs: 100),
        (path: r'C:\tmp\f1.jpg', durationMs: 1250),
      ]);
      expect(
        text,
        'ffconcat version 1.0\n'
        "file 'C:/tmp/f0.jpg'\n"
        'duration 0.100\n'
        "file 'C:/tmp/f1.jpg'\n"
        'duration 1.250\n'
        "file 'C:/tmp/f1.jpg'\n",
      );
    });

    test("单引号按 concat 规则转义为 '\\''", () {
      final String text = buildGalWindowConcatList(<GalWindowVideoFrameEntry>[
        (path: "/a'b/f.jpg", durationMs: 100),
      ]);
      expect(text, contains(r"file '/a'\''b/f.jpg'"));
    });
  });

  group('buildGalWindowVideoArgs', () {
    test('带音频：concat 输入 + 音频输入 + libx264/aac + faststart', () {
      expect(
        buildGalWindowVideoArgs(
          listPath: 'list.txt',
          audioPath: 'a.aac',
          outputPath: 'out.mp4',
        ),
        <String>[
          '-y',
          '-f', 'concat', '-safe', '0', '-i', 'list.txt', //
          '-i', 'a.aac',
          '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26',
          '-pix_fmt', 'yuv420p',
          '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
          '-c:a', 'aac', '-b:a', '128k',
          '-movflags', '+faststart',
          'out.mp4',
        ],
      );
    });

    test('无音频：不带第二输入与音频编码参数', () {
      final List<String> args = buildGalWindowVideoArgs(
        listPath: 'list.txt',
        outputPath: 'out.mp4',
      );
      expect(args.where((String a) => a == '-i').length, 1);
      expect(args, isNot(contains('-c:a')));
      expect(args, isNot(contains('aac')));
    });
  });

  group('parseFfmpegDurationMs', () {
    test('优先取最后一条进度行 time=', () {
      const String log = 'Duration: 00:00:05.00, bitrate: 128 kb/s\n'
          'size=N/A time=00:00:01.50 bitrate=N/A speed=100x\n'
          'size=N/A time=00:00:03.42 bitrate=N/A speed=100x\n';
      expect(parseFfmpegDurationMs(log), 3420);
    });

    test('无进度行退回 Duration:', () {
      expect(
        parseFfmpegDurationMs('  Duration: 00:01:02.345, start: 0'),
        62345,
      );
    });

    test('都没有 / N/A → null', () {
      expect(parseFfmpegDurationMs('Duration: N/A'), isNull);
      expect(parseFfmpegDurationMs(''), isNull);
    });
  });

  group('fallbackGalWindowVideoFromTick', () {
    test('有音频：now - (音频时长 + 1s)；无音频：now - 6s；不早于 0', () {
      expect(
        fallbackGalWindowVideoFromTick(toTickMs: 10000, audioDurationMs: 2500),
        6500,
      );
      expect(
        fallbackGalWindowVideoFromTick(toTickMs: 10000, audioDurationMs: null),
        4000,
      );
      expect(
        fallbackGalWindowVideoFromTick(toTickMs: 3000, audioDurationMs: null),
        0,
      );
    });
  });

  group('buildGalWindowVideoClip', () {
    late Directory work;
    setUp(() async {
      work = await Directory.systemTemp.createTemp('gal_window_video_');
      for (final String name in <String>['f0.jpg', 'f1.jpg', 'f2.jpg']) {
        await File('${work.path}/$name').writeAsBytes(<int>[0xFF, 0xD8]);
      }
    });
    tearDown(() async {
      if (work.existsSync()) await work.delete(recursive: true);
    });

    WindowRecordingExport exportOf(List<int> ticks, {int nowTickMs = 10000}) =>
        WindowRecordingExport(
          frames: <WindowRecordingFrame>[
            for (int i = 0; i < ticks.length; i++)
              _frame('${work.path}/f$i.jpg', ticks[i]),
          ],
          nowTickMs: nowTickMs,
        );

    test('成功：探音频时长 → 写 concat 列表 → 编码 → 返回 mp4 字节', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg(
        probeOutput: 'time=00:00:02.00 bitrate=N/A',
      );
      final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
        export: exportOf(<int>[9000, 9100, 9300]),
        fromTickMs: 9000,
        toTickMs: 0,
        audioBytes: Uint8List.fromList(<int>[1, 2, 3]),
        audioExtension: 'aac',
        workDir: work,
        backend: ffmpeg,
      );
      expect(clip, isNotNull);
      expect(clip!.extension, 'mp4');
      expect(clip.bytes, isNotEmpty);
      expect(ffmpeg.runs, hasLength(2));
      expect(ffmpeg.runs.first, contains('null'), reason: '第一跑是时长探测');
      final List<String> encode = ffmpeg.runs.last;
      expect(encode, contains('libx264'));
      expect(encode[encode.indexOf('-i') + 1], endsWith('frames.ffconcat'));
      final String list = await File(
        '${work.path}/frames.ffconcat',
      ).readAsString();
      // 已覆盖 300ms，音频 2000ms → 最后一帧 1700ms。
      expect(list, contains('duration 1.700'));
      expect(File('${work.path}/sentence.aac').existsSync(), isTrue);
    });

    test('fromTickMs 为 null：按音频时长从 now 倒推起点', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg(
        probeOutput: 'time=00:00:01.00 bitrate=N/A',
      );
      // now=10000，音频 1s → from = 10000 - 2000 = 8000；tick 7000 的帧只作 lead。
      final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
        export: exportOf(<int>[7000, 8500, 9500]),
        fromTickMs: null,
        toTickMs: 0,
        audioBytes: Uint8List.fromList(<int>[1]),
        audioExtension: 'aac',
        workDir: work,
        backend: ffmpeg,
      );
      expect(clip, isNotNull);
      final String list = await File(
        '${work.path}/frames.ffconcat',
      ).readAsString();
      // lead 钉到 8000 → 到 8500 差 500ms。
      expect(list, contains('duration 0.500'));
    });

    test('无音频：不探时长、不带音频输入', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
        export: exportOf(<int>[9000, 9100]),
        fromTickMs: 9000,
        toTickMs: 0,
        audioBytes: null,
        audioExtension: 'aac',
        workDir: work,
        backend: ffmpeg,
      );
      expect(clip, isNotNull);
      expect(ffmpeg.runs, hasLength(1));
      expect(ffmpeg.runs.single, isNot(contains('-c:a')));
    });

    test('帧不足 2 张 → null，不跑 ffmpeg', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
        export: exportOf(<int>[9000]),
        fromTickMs: 9000,
        toTickMs: 0,
        audioExtension: 'aac',
        workDir: work,
        backend: ffmpeg,
      );
      expect(clip, isNull);
      expect(ffmpeg.runs, isEmpty);
    });

    test('区间内帧不足 2 张 → null', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
        export: exportOf(<int>[1000, 1100, 1200]),
        fromTickMs: 9000,
        toTickMs: 0,
        audioExtension: 'aac',
        workDir: work,
        backend: ffmpeg,
      );
      expect(clip, isNull);
      expect(ffmpeg.runs, isEmpty);
    });

    test('导出失败（error）→ null', () async {
      final _FakeFfmpeg ffmpeg = _FakeFfmpeg();
      final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
        export: const WindowRecordingExport(
          frames: <WindowRecordingFrame>[],
          nowTickMs: 10000,
          error: 'recording not started',
        ),
        fromTickMs: 9000,
        toTickMs: 0,
        audioExtension: 'aac',
        workDir: work,
        backend: ffmpeg,
      );
      expect(clip, isNull);
      expect(ffmpeg.runs, isEmpty);
    });

    test('ffmpeg 失败 / 超时 / 空产物 → null（fail-open）', () async {
      for (final _FakeFfmpeg ffmpeg in <_FakeFfmpeg>[
        _FakeFfmpeg(encodeReturnCode: 1),
        _FakeFfmpeg(encodeReturnCode: null),
        _FakeFfmpeg(writeOutput: false),
      ]) {
        final GalWindowVideoClip? clip = await buildGalWindowVideoClip(
          export: exportOf(<int>[9000, 9100]),
          fromTickMs: 9000,
          toTickMs: 0,
          audioExtension: 'aac',
          workDir: work,
          backend: ffmpeg,
        );
        expect(clip, isNull);
      }
    });
  });
}
