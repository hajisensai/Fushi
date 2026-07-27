import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart' as ffmpeg;
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

void main() {
  Future<bool> ffmpegAvailable() async {
    try {
      final ProcessResult result = await Process.run(
        resolveFfmpegExecutable(),
        <String>['-version'],
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  group('buildFfmpegClipArgs', () {
    test('formats seek/duration in seconds and orders flags', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.m4b',
        startMs: 1000,
        endMs: 2500,
        outputPath: '/a/out.aac',
      );
      expect(args, <String>[
        '-y',
        '-ss',
        '1.000',
        '-t',
        '1.500',
        '-i',
        '/a/in.m4b',
        '-vn',
        '-c:a',
        'aac',
        // TODO-646 近无损压缩：单声道 64k AAC。
        '-ac',
        '1',
        '-b:a',
        '64k',
        '/a/out.aac',
      ]);
    });

    test('TODO-646: mono 64k AAC for near-lossless sentence audio', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.m4b',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
      );
      // 单声道下混 + 64k 比特率（人声短片段听感近透明、省一半以上体积）。
      final int acIndex = args.indexOf('-ac');
      expect(acIndex, greaterThanOrEqualTo(0));
      expect(args[acIndex + 1], '1');
      final int brIndex = args.indexOf('-b:a');
      expect(brIndex, greaterThanOrEqualTo(0));
      expect(args[brIndex + 1], '64k');
      // 比特率/声道必须在编码器之后（对输出流生效，而非输入）。
      expect(args.indexOf('-c:a') < acIndex, isTrue);
      expect(args.indexOf('-c:a') < brIndex, isTrue);
    });

    test('TODO-757 high-fidelity profile: stereo 128k AAC', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.m4b',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        // 高保真档（关闭压缩时）由调用点传入。
        audioChannels: 2,
        audioBitrate: '128k',
      );
      final int acIndex = args.indexOf('-ac');
      expect(acIndex, greaterThanOrEqualTo(0));
      expect(args[acIndex + 1], '2');
      final int brIndex = args.indexOf('-b:a');
      expect(brIndex, greaterThanOrEqualTo(0));
      expect(args[brIndex + 1], '128k');
      // 编码器仍在前（对输出流生效）。
      expect(args.indexOf('-c:a') < acIndex, isTrue);
      expect(args.indexOf('-c:a') < brIndex, isTrue);
    });

    test('TODO-757 defaults stay on the compressed profile (mono 64k)', () {
      // 不传 audioChannels/audioBitrate 时必须等价于压缩档（= 现状）。
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.m4b',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
      );
      expect(args[args.indexOf('-ac') + 1], '1');
      expect(args[args.indexOf('-b:a') + 1], '64k');
    });

    test('no -map when audioStreamIndex is null (default audio selection)', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        audioStreamIndex: null,
      );
      expect(args.contains('-map'), isFalse);
    });

    test('no -map when audioStreamIndex is negative', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        audioStreamIndex: -1,
      );
      expect(args.contains('-map'), isFalse);
    });

    test('maps 0:a:<idx> for the selected audio track', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 1000,
        endMs: 2500,
        outputPath: '/a/out.aac',
        audioStreamIndex: 1,
      );
      expect(args, <String>[
        '-y',
        '-ss',
        '1.000',
        '-t',
        '1.500',
        '-i',
        '/a/in.mkv',
        '-vn',
        '-map',
        // 尾随 '?'：越界时降级回退默认轨而非硬失败（BUG-345）。
        '0:a:1?',
        '-c:a',
        'aac',
        // TODO-646 近无损压缩：单声道 64k AAC。
        '-ac',
        '1',
        '-b:a',
        '64k',
        '/a/out.aac',
      ]);
    });

    test('audio map always carries the optional "?" suffix', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        audioStreamIndex: 2,
      );
      expect(args, contains('0:a:2?'));
      expect(args, isNot(contains('0:a:2')));
    });

    test('drops the audio map when index is out of the known stream count', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: '/a/in.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/a/out.aac',
        audioStreamIndex: 3,
        audioStreamCount: 2,
      );
      expect(args.contains('-map'), isFalse);
      expect(args.any((String a) => a.startsWith('0:a:')), isFalse);
    });
  });

  group('extractAudioSegmentViaFfmpeg', () {
    tearDown(() {
      ffmpeg.setFfmpegBackendForTesting(null);
    });

    test('returns null for a non-positive range without running ffmpeg',
        () async {
      expect(
        await extractAudioSegmentViaFfmpeg(
          inputPath: 'whatever',
          startMs: 1000,
          endMs: 1000,
          outputPath: 'x.aac',
        ),
        isNull,
      );
    });

    // TODO-1005 / BUG-472：「ffmpeg 还没跑就失败」此前静默 return null，in-app 日志页
    // 空白。现在这两条早返回必须经 onFailure 回传可诊断摘要（同时也写 ErrorLogService）。
    test('TODO-1005: non-positive range reports diagnostics via onFailure',
        () async {
      final List<String> failures = <String>[];
      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: 'whatever',
        startMs: 1000,
        endMs: 1000,
        outputPath: 'x.aac',
        onFailure: failures.add,
      );
      expect(result, isNull);
      expect(failures, hasLength(1),
          reason: 'zero/negative-length range must no longer fail silently — '
              'the «无任何错误日志» bug (TODO-1005/BUG-472).');
      expect(failures.single, contains('non-positive range'));
      expect(failures.single, contains('endMs=1000'));
    });

    test('returns null when the input file does not exist', () async {
      expect(
        await extractAudioSegmentViaFfmpeg(
          inputPath: '/no/such/input.m4b',
          startMs: 0,
          endMs: 1000,
          outputPath: 'x.aac',
        ),
        isNull,
      );
    });

    test('TODO-1005: missing input reports diagnostics via onFailure',
        () async {
      final List<String> failures = <String>[];
      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: '/no/such/input.m4b',
        startMs: 0,
        endMs: 1000,
        outputPath: 'x.aac',
        onFailure: failures.add,
      );
      expect(result, isNull);
      expect(failures, hasLength(1),
          reason: 'missing input audio must no longer fail silently '
              '(TODO-1005/BUG-472).');
      expect(failures.single, contains('does not exist'));
      expect(failures.single, contains('/no/such/input.m4b'));
    });

    test('cuts a real clip when ffmpeg is available', () async {
      // Environment-dependent: skip cleanly if ffmpeg is not installed.
      if (!await ffmpegAvailable()) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping real-clip extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.m4a';
      final String output = '${dir.path}/out.aac';

      // Generate a 3s tone to cut from.
      final ProcessResult gen =
          await Process.run(resolveFfmpegExecutable(), <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-c:a',
        'aac',
        input,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
      );

      expect(result, output);
      expect(File(output).existsSync(), isTrue);
      expect(File(output).lengthSync(), greaterThan(0));
    });

    test('reports invalid-image diagnostics when audio clipping fails',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_fail_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.mkv';
      final String output = '${dir.path}/out.aac';
      File(input).writeAsBytesSync(<int>[0, 1, 2, 3]);
      final List<String> failures = <String>[];

      ffmpeg.setFfmpegBackendForTesting(_FakeFfmpegBackend(
        const ffmpeg.FfmpegRunResult(
          returnCode: -1073741701,
          output: 'The application was unable to start correctly.',
          executable: r'C:\Hibiki\ffmpeg.exe',
          attemptedExecutables: <String>[
            r'C:\Hibiki\ffmpeg.exe',
            'ffmpeg',
          ],
          fallbackReason: 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT',
        ),
      ));

      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
        onFailure: failures.add,
      );

      expect(result, isNull);
      expect(File(output).existsSync(), isFalse);
      expect(failures, hasLength(1));
      expect(failures.single, contains('0xC000007B'));
      expect(failures.single, contains('STATUS_INVALID_IMAGE_FORMAT'));
      expect(failures.single, contains(r'C:\Hibiki\ffmpeg.exe -> ffmpeg'));
      expect(failures.single, contains('The application was unable'));
    });

    test('writes a real clip after bundled invalid-image fallback', () async {
      if (!await ffmpegAvailable()) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping invalid-image fallback clip test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_fallback_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.m4a';
      final String output = '${dir.path}/sentence.aac';

      final ProcessResult gen =
          await Process.run(resolveFfmpegExecutable(), <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=3',
        '-c:a',
        'aac',
        input,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final _InvalidBundledThenPathFfmpegBackend backend =
          _InvalidBundledThenPathFfmpegBackend(
        pathExecutable: resolveFfmpegExecutable(),
      );
      ffmpeg.setFfmpegBackendForTesting(backend);
      final List<String> failures = <String>[];

      final String? result = await extractAudioSegmentViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
        onFailure: failures.add,
      );

      expect(result, output);
      expect(File(output).existsSync(), isTrue);
      expect(File(output).lengthSync(), greaterThan(0));
      expect(failures, isEmpty);
      expect(
        backend.attemptedExecutables,
        containsAllInOrder(<String>[
          _InvalidBundledThenPathFfmpegBackend.bundledPath,
          'ffmpeg',
        ]),
      );
    });
  });

  group('extractClipGifViaFfmpeg', () {
    tearDown(() {
      ffmpeg.setFfmpegBackendForTesting(null);
    });

    test('reports invalid-image diagnostics when GIF clipping fails', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_gif_fail_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.mkv';
      final String output = '${dir.path}/out.gif';
      File(input).writeAsBytesSync(<int>[0, 1, 2, 3]);
      final List<String> failures = <String>[];

      ffmpeg.setFfmpegBackendForTesting(_FakeFfmpegBackend(
        const ffmpeg.FfmpegRunResult(
          returnCode: -1073741701,
          output: '',
          executable: r'C:\Hibiki\ffmpeg.exe',
          attemptedExecutables: <String>[
            r'C:\Hibiki\ffmpeg.exe',
            'ffmpeg',
          ],
          fallbackReason: 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT',
        ),
      ));

      final String? result = await extractClipGifViaFfmpeg(
        inputPath: input,
        startMs: 1000,
        endMs: 2000,
        outputPath: output,
        onFailure: failures.add,
      );

      expect(result, isNull);
      expect(File(output).existsSync(), isFalse);
      expect(failures, hasLength(1));
      expect(failures.single, contains('0xC000007B'));
      expect(failures.single, contains(r'C:\Hibiki\ffmpeg.exe -> ffmpeg'));
    });

    test('writes a real GIF after bundled invalid-image fallback', () async {
      if (!await ffmpegAvailable()) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping invalid-image fallback GIF test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_gif_fallback_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.mp4';
      final String output = '${dir.path}/clip.gif';

      final ProcessResult gen =
          await Process.run(resolveFfmpegExecutable(), <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=duration=2:size=160x90:rate=12',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=660:duration=2',
        '-c:v',
        'mpeg4',
        '-c:a',
        'aac',
        '-shortest',
        input,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final _InvalidBundledThenPathFfmpegBackend backend =
          _InvalidBundledThenPathFfmpegBackend(
        pathExecutable: resolveFfmpegExecutable(),
      );
      ffmpeg.setFfmpegBackendForTesting(backend);
      final List<String> failures = <String>[];

      final String? result = await extractClipGifViaFfmpeg(
        inputPath: input,
        startMs: 100,
        endMs: 1100,
        outputPath: output,
        onFailure: failures.add,
      );

      expect(result, output);
      expect(File(output).existsSync(), isTrue);
      expect(File(output).lengthSync(), greaterThan(0));
      expect(failures, isEmpty);
      expect(
        backend.attemptedExecutables,
        containsAllInOrder(<String>[
          _InvalidBundledThenPathFfmpegBackend.bundledPath,
          'ffmpeg',
        ]),
      );
    });
  });

  group('buildFfmpegCoverArgs', () {
    test('extracts a single video frame with audio dropped', () {
      expect(
        buildFfmpegCoverArgs(inputPath: '/a/in.m4b', outputPath: '/a/c.jpg'),
        <String>[
          '-y',
          '-i',
          '/a/in.m4b',
          '-an',
          '-frames:v',
          '1',
          '-update',
          '1',
          '/a/c.jpg',
        ],
      );
    });
  });

  group('buildFfmpegFrameArgs', () {
    test('grabs one frame at the given second with audio dropped', () {
      expect(
        buildFfmpegFrameArgs(
          inputPath: '/a/in.mkv',
          outputPath: '/a/thumb.jpg',
          atSeconds: 10,
        ),
        <String>[
          '-y',
          '-ss',
          '10.000',
          '-i',
          '/a/in.mkv',
          '-an',
          '-frames:v',
          '1',
          '-update',
          '1',
          '/a/thumb.jpg',
        ],
      );
    });

    test('defaults to t=0 and clamps a negative seek to 0', () {
      expect(
        buildFfmpegFrameArgs(inputPath: '/a/in.mp4', outputPath: '/a/t.jpg'),
        <String>[
          '-y', '-ss', '0.000', '-i', '/a/in.mp4', //
          '-an', '-frames:v', '1', '-update', '1', '/a/t.jpg',
        ],
      );
      expect(
        buildFfmpegFrameArgs(
          inputPath: '/a/in.mp4',
          outputPath: '/a/t.jpg',
          atSeconds: -5,
        ),
        contains('0.000'),
      );
    });
  });

  group('extractVideoFrameViaFfmpeg', () {
    tearDown(() {
      ffmpeg.setFfmpegBackendForTesting(null);
    });

    test('returns null when the input file does not exist', () async {
      expect(
        await extractVideoFrameViaFfmpeg(
          inputPath: '/no/such/video.mkv',
          outputPath: 'x.jpg',
        ),
        isNull,
      );
    });

    test('TODO-816 ④: reports diagnostics via onFailure when frame grab fails',
        () async {
      // 根因（TODO-816 ④）：制卡封面降级链路需要拿到失败摘要才能给用户可感知提示。
      // 旧 extractVideoFrameViaFfmpeg 只往 ErrorLogService 记日志、不回调 onFailure，
      // 调用方无从向用户解释「为什么降级成静态图」。本守卫钉住失败摘要经 onFailure 回传。
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_frame_fail_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String input = '${dir.path}/in.mkv';
      final String output = '${dir.path}/frame.jpg';
      File(input).writeAsBytesSync(<int>[0, 1, 2, 3]);
      final List<String> failures = <String>[];

      ffmpeg.setFfmpegBackendForTesting(_FakeFfmpegBackend(
        const ffmpeg.FfmpegRunResult(
          returnCode: -1073741701,
          output: 'The application was unable to start correctly.',
          executable: r'C:\Hibiki\ffmpeg.exe',
          attemptedExecutables: <String>[
            r'C:\Hibiki\ffmpeg.exe',
            'ffmpeg',
          ],
          fallbackReason: 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT',
        ),
      ));

      final String? result = await extractVideoFrameViaFfmpeg(
        inputPath: input,
        outputPath: output,
        atSeconds: 2,
        onFailure: failures.add,
      );

      expect(result, isNull);
      expect(File(output).existsSync(), isFalse);
      expect(failures, hasLength(1), reason: '抽帧失败必须经 onFailure 回传给制卡降级提示路径。');
      expect(failures.single, contains('0xC000007B'));
      expect(failures.single, contains('STATUS_INVALID_IMAGE_FORMAT'));
    });

    test('grabs a real frame when ffmpeg is available', () async {
      bool ffmpegPresent;
      try {
        final ProcessResult v =
            await Process.run(resolveFfmpegExecutable(), <String>['-version']);
        ffmpegPresent = v.exitCode == 0;
      } catch (_) {
        ffmpegPresent = false;
      }
      if (!ffmpegPresent) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping real-frame extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_frame_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String video = '${dir.path}/clip.mp4';
      final String out = '${dir.path}/thumb.jpg';
      final String ff = resolveFfmpegExecutable();

      // 生成一段 5s 彩色测试视频。
      final ProcessResult gen = await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc=duration=5:size=64x64:rate=10',
        '-pix_fmt',
        'yuv420p',
        video,
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());

      final String? result = await extractVideoFrameViaFfmpeg(
        inputPath: video,
        outputPath: out,
        atSeconds: 2,
      );

      expect(result, out);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
    });
  });

  group('buildFfmpegSubtitleArgs', () {
    test('maps the Nth subtitle stream to the output path', () {
      expect(
        buildFfmpegSubtitleArgs(
          inputPath: '/a/in.mkv',
          streamIndex: 0,
          outputPath: '/a/sub.ass',
        ),
        <String>['-y', '-i', '/a/in.mkv', '-map', '0:s:0', '/a/sub.ass'],
      );
    });

    test('uses the requested stream index', () {
      expect(
        buildFfmpegSubtitleArgs(
          inputPath: '/a/in.mkv',
          streamIndex: 2,
          outputPath: '/a/sub.ass',
        ),
        <String>['-y', '-i', '/a/in.mkv', '-map', '0:s:2', '/a/sub.ass'],
      );
    });
  });

  group('extractEmbeddedSubtitleViaFfmpeg', () {
    test('returns null when the input file does not exist', () async {
      expect(
        await extractEmbeddedSubtitleViaFfmpeg(
          inputPath: '/no/such/input.mkv',
          streamIndex: 0,
          outputPath: 'x.ass',
        ),
        isNull,
      );
    });

    test('extracts an embedded subtitle track when ffmpeg is available',
        () async {
      bool ffmpegPresent;
      try {
        final ProcessResult v =
            await Process.run(resolveFfmpegExecutable(), <String>['-version']);
        ffmpegPresent = v.exitCode == 0;
      } catch (_) {
        ffmpegPresent = false;
      }
      if (!ffmpegPresent) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping real-subtitle extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_sub_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String srt = '${dir.path}/src.srt';
      final String video = '${dir.path}/withsub.mkv';
      final String out = '${dir.path}/extracted.ass';
      final String ff = resolveFfmpegExecutable();

      // 写一条最小 SRT，再 mux 进 mkv 的字幕轨（ffmpeg 转成 ASS）。
      File(srt).writeAsStringSync(
        '1\n00:00:00,500 --> 00:00:02,000\n吾輩は猫である。\n\n'
        '2\n00:00:02,500 --> 00:00:04,000\n名前はまだない。\n',
      );
      final ProcessResult mux = await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=black:s=64x64:d=5',
        '-i',
        srt,
        '-map',
        '0:v',
        '-map',
        '1',
        '-c:v',
        'libx264',
        '-c:s',
        'ass',
        video,
      ]);
      expect(mux.exitCode, 0, reason: mux.stderr.toString());

      final String? result = await extractEmbeddedSubtitleViaFfmpeg(
        inputPath: video,
        streamIndex: 0,
        outputPath: out,
      );

      expect(result, out);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
    });
  });

  group('buildFfmpegMultiSubtitleArgs (BUG-104 单趟多轨)', () {
    test('单 -i + 每轨一对 -map 0:s:N out，按 streamIndex 升序', () {
      final List<String> args = buildFfmpegMultiSubtitleArgs(
        inputPath: '/v/movie.mkv',
        outputs: <int, String>{
          3: '/c/sub_3.srt',
          0: '/c/sub_0.srt',
          1: '/c/sub_1.ass',
        },
      );
      expect(args, <String>[
        '-y',
        '-i',
        '/v/movie.mkv',
        '-map',
        '0:s:0',
        '/c/sub_0.srt',
        '-map',
        '0:s:1',
        '/c/sub_1.ass',
        '-map',
        '0:s:3',
        '/c/sub_3.srt',
      ]);
      // 关键：整批只有一个 -i（单次 demux 读穿容器），不是每轨一个输入。
      expect(args.where((String a) => a == '-i').length, 1);
    });

    test('空 outputs → 只剩 -y -i（无 -map）', () {
      final List<String> args = buildFfmpegMultiSubtitleArgs(
        inputPath: '/v/x.mkv',
        outputs: const <int, String>{},
      );
      expect(args, <String>['-y', '-i', '/v/x.mkv']);
    });
  });

  group('extractEmbeddedSubtitlesViaFfmpeg (BUG-104 单趟全轨缓存)', () {
    test('returns empty when the input file does not exist', () async {
      expect(
        await extractEmbeddedSubtitlesViaFfmpeg(
          inputPath: '/no/such/input.mkv',
          outputs: <int, String>{0: 'x.srt'},
        ),
        isEmpty,
      );
    });

    test('returns empty when no outputs requested', () async {
      expect(
        await extractEmbeddedSubtitlesViaFfmpeg(
          inputPath: '/no/such/input.mkv',
          outputs: const <int, String>{},
        ),
        isEmpty,
      );
    });

    test('extracts MULTIPLE embedded tracks in one pass when ffmpeg available',
        () async {
      bool ffmpegPresent;
      try {
        final ProcessResult v =
            await Process.run(resolveFfmpegExecutable(), <String>['-version']);
        ffmpegPresent = v.exitCode == 0;
      } catch (_) {
        ffmpegPresent = false;
      }
      if (!ffmpegPresent) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping multi-subtitle extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_multisub_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String srtA = '${dir.path}/a.srt';
      final String srtB = '${dir.path}/b.srt';
      final String video = '${dir.path}/twosubs.mkv';
      final String ff = resolveFfmpegExecutable();

      File(srtA).writeAsStringSync(
        '1\n00:00:00,500 --> 00:00:02,000\n吾輩は猫である。\n',
      );
      File(srtB).writeAsStringSync(
        '1\n00:00:00,500 --> 00:00:02,000\n名前はまだない。\n',
      );
      // 一个视频 + 两条字幕轨（相对序号 0/1）。
      final ProcessResult mux = await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=black:s=64x64:d=5',
        '-i',
        srtA,
        '-i',
        srtB,
        '-map',
        '0:v',
        '-map',
        '1',
        '-map',
        '2',
        '-c:v',
        'libx264',
        '-c:s',
        'srt',
        video,
      ]);
      expect(mux.exitCode, 0, reason: mux.stderr.toString());

      final String out0 = '${dir.path}/sub_0.srt';
      final String out1 = '${dir.path}/sub_1.srt';
      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: <int, String>{0: out0, 1: out1},
      );

      // 单趟抽出两条轨，二者都落盘且非空。
      expect(written.keys.toSet(), <int>{0, 1});
      expect(File(out0).existsSync(), isTrue);
      expect(File(out0).lengthSync(), greaterThan(0));
      expect(File(out1).existsSync(), isTrue);
      expect(File(out1).lengthSync(), greaterThan(0));
    });
  });

  group('extractEmbeddedSubtitlesViaFfmpeg 毒轨逐轨回退 (BUG-863)', () {
    tearDown(() => ffmpeg.setFfmpegBackendForTesting(null));

    test('单遍被一条 output-open 毒轨整批击穿时，逐轨回退保住其余好轨', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_poison_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String video = '${dir.path}/in.mkv';
      // 只需存在（extractEmbeddedSubtitlesViaFfmpeg 用 existsSync 门控输入）。
      File(video).writeAsStringSync('fake-container');
      final _FakePoisonFfmpegBackend fake =
          _FakePoisonFfmpegBackend(poisonIndex: 1);
      ffmpeg.setFfmpegBackendForTesting(fake);

      final Map<int, String> outputs = <int, String>{
        0: '${dir.path}/sub_0.srt',
        1: '${dir.path}/sub_1.srt', // 毒轨：ffmpeg 在 output-open 阶段 EINVAL
        2: '${dir.path}/sub_2.ass',
      };
      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: outputs,
      );

      // 好轨 0/2 保住；毒轨 1 只损失自己（不再整批 0 条）。
      expect(written.keys.toSet(), <int>{0, 2});
      expect(File(outputs[0]!).existsSync(), isTrue);
      expect(File(outputs[2]!).existsSync(), isTrue);
      expect(File(outputs[1]!).existsSync(), isFalse);

      // 第一趟单遍全轨（含毒轨→整批失败），随后对 3 条缺失轨各跑一次逐轨。
      expect(fake.passes.first.keys.toSet(), <int>{0, 1, 2},
          reason: '第一趟必须是单遍全轨');
      expect(fake.passes.length, 4, reason: '单遍 + 3 条逐轨回退');
      for (final Map<int, String> p in fake.passes.skip(1)) {
        expect(p.length, 1, reason: '回退每趟只抽一条轨');
      }
    });

    test('单遍全部成功时不触发逐轨回退（common path 零开销）', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clean_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String video = '${dir.path}/in.mkv';
      File(video).writeAsStringSync('fake-container');
      final _FakePoisonFfmpegBackend fake =
          _FakePoisonFfmpegBackend(poisonIndex: -1); // 无毒轨
      ffmpeg.setFfmpegBackendForTesting(fake);

      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: <int, String>{
          0: '${dir.path}/s0.srt',
          1: '${dir.path}/s1.srt',
        },
      );
      expect(written.keys.toSet(), <int>{0, 1});
      expect(fake.passes.length, 1, reason: '单遍成功 → 不跑逐轨回退');
    });
  });

  group('extractEmbeddedSubtitlesViaFfmpeg per-track fallback (BUG-863)', () {
    late Directory dir;
    late String video;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('hibiki_bug818');
      video = '${dir.path}/in.mkv';
      File(video).writeAsStringSync('fake container');
    });

    tearDown(() {
      ffmpeg.setFfmpegBackendForTesting(null);
      dir.deleteSync(recursive: true);
    });

    test(
        'one undecodable track no longer sinks the good tracks '
        '(batch EINVAL → per-track fallback)', () async {
      // idx 0/2 decodable (subrip/ass); idx 1 undecodable by the bundled
      // min-ffmpeg (ttml / eia_608 / teletext …). The single batch command
      // aborts with EINVAL and writes nothing; the fallback must still land 0/2.
      ffmpeg.setFfmpegBackendForTesting(
        _MinBuildFakeFfmpegBackend(decodableIndices: <int>{0, 2}),
      );
      final String out0 = '${dir.path}/sub_0.srt';
      final String out1 = '${dir.path}/sub_1.srt';
      final String out2 = '${dir.path}/sub_2.ass';

      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: <int, String>{0: out0, 1: out1, 2: out2},
      );

      // Good tracks survive; only the undecodable one is dropped.
      expect(written.keys.toSet(), <int>{0, 2});
      expect(File(out0).existsSync(), isTrue);
      expect(File(out0).lengthSync(), greaterThan(0));
      expect(File(out2).existsSync(), isTrue);
      expect(File(out2).lengthSync(), greaterThan(0));
      // The undecodable track leaves no (empty stub) file behind.
      expect(File(out1).existsSync(), isFalse);
    });

    test('all-good batch succeeds in a single pass (no per-track fallback)',
        () async {
      final _MinBuildFakeFfmpegBackend backend =
          _MinBuildFakeFfmpegBackend(decodableIndices: <int>{0, 1});
      ffmpeg.setFfmpegBackendForTesting(backend);
      final String out0 = '${dir.path}/sub_0.srt';
      final String out1 = '${dir.path}/sub_1.srt';

      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: <int, String>{0: out0, 1: out1},
      );

      expect(written.keys.toSet(), <int>{0, 1});
      // Exactly one ffmpeg invocation (the batch); fallback must not fire.
      expect(backend.runCount, 1);
    });

    test('every track undecodable → empty result and no output files',
        () async {
      ffmpeg.setFfmpegBackendForTesting(
        _MinBuildFakeFfmpegBackend(decodableIndices: const <int>{}),
      );
      final String out0 = '${dir.path}/sub_0.srt';
      final String out1 = '${dir.path}/sub_1.srt';

      final Map<int, String> written = await extractEmbeddedSubtitlesViaFfmpeg(
        inputPath: video,
        outputs: <int, String>{0: out0, 1: out1},
      );

      expect(written, isEmpty);
      expect(File(out0).existsSync(), isFalse);
      expect(File(out1).existsSync(), isFalse);
    });
  });

  group('extractEmbeddedCoverViaFfmpeg', () {
    test('returns null when the audio file does not exist', () async {
      expect(
        await extractEmbeddedCoverViaFfmpeg(
          audioPath: '/no/such/input.m4b',
          outputPath: 'x.jpg',
        ),
        isNull,
      );
    });

    test('extracts an embedded cover when ffmpeg is available', () async {
      bool ffmpegPresent;
      try {
        final ProcessResult v =
            await Process.run(resolveFfmpegExecutable(), <String>['-version']);
        ffmpegPresent = v.exitCode == 0;
      } catch (_) {
        ffmpegPresent = false;
      }
      if (!ffmpegPresent) {
        // ignore: avoid_print
        print('ffmpeg not present; skipping real-cover extraction test');
        return;
      }

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_cover_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String cover = '${dir.path}/cover.png';
      final String audio = '${dir.path}/withcover.m4a';
      final String out = '${dir.path}/extracted.jpg';
      final String ff = resolveFfmpegExecutable();

      await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=red:s=48x48',
        '-frames:v',
        '1',
        cover,
      ]);
      await Process.run(ff, <String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=d=1',
        '-i',
        cover,
        '-map',
        '0:a',
        '-map',
        '1:v',
        '-c:a',
        'aac',
        '-c:v',
        'mjpeg',
        '-disposition:v',
        'attached_pic',
        audio,
      ]);

      final String? result = await extractEmbeddedCoverViaFfmpeg(
        audioPath: audio,
        outputPath: out,
      );

      expect(result, out);
      expect(File(out).existsSync(), isTrue);
      expect(File(out).lengthSync(), greaterThan(0));
    });
  });

  group('MiningMediaCompression (TODO-757 压缩档位)', () {
    test('compressed profile = TODO-646 现状（零行为破坏）', () {
      const MiningMediaCompression c = MiningMediaCompression.compressed;
      expect(c.audioChannels, 1);
      expect(c.audioBitrate, '64k');
      expect(c.gifFps, 8);
      expect(c.gifWidth, 480);
      expect(c.screenshotMaxLongEdge, 1000);
      expect(c.screenshotQuality, 90);
    });

    test('highFidelity profile = 更清晰更大', () {
      const MiningMediaCompression h = MiningMediaCompression.highFidelity;
      expect(h.audioChannels, 2);
      expect(h.audioBitrate, '128k');
      expect(h.gifFps, 12);
      expect(h.gifWidth, 720);
      expect(h.screenshotMaxLongEdge, 2000);
      expect(h.screenshotQuality, 95);
    });

    test('resolve(标准档 1 + 音频档 0) = compressed 现状（零行为破坏）', () {
      final MiningMediaCompression r = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.defaultImageTier,
        audioTier: MiningMediaCompression.defaultAudioTier,
      );
      const MiningMediaCompression c = MiningMediaCompression.compressed;
      expect(r.gifFps, c.gifFps);
      expect(r.gifWidth, c.gifWidth);
      expect(r.screenshotMaxLongEdge, c.screenshotMaxLongEdge);
      expect(r.screenshotQuality, c.screenshotQuality);
      expect(r.audioChannels, c.audioChannels);
      expect(r.audioBitrate, c.audioBitrate);
    });

    test('resolve(高清档 2 + 音频档 1) = highFidelity', () {
      final MiningMediaCompression r = MiningMediaCompression.resolve(
        imageTier: 2,
        audioTier: 1,
      );
      const MiningMediaCompression h = MiningMediaCompression.highFidelity;
      expect(r.gifFps, h.gifFps);
      expect(r.gifWidth, h.gifWidth);
      expect(r.screenshotMaxLongEdge, h.screenshotMaxLongEdge);
      expect(r.screenshotQuality, h.screenshotQuality);
      expect(r.audioChannels, h.audioChannels);
      expect(r.audioBitrate, h.audioBitrate);
    });

    test('原片档（满档）截图用 0 哨兵不缩放，GIF 走封顶档（BUG-1039）', () {
      final MiningMediaCompression r = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.imageTierMax,
        audioTier: MiningMediaCompression.audioTierCount - 1,
      );
      expect(r.screenshotMaxLongEdge, 0, reason: '0 = 不缩放（截图原图直通，语义不变）');
      expect(r.gifFps, MiningMediaCompression.gifMaxTierFps);
      expect(r.gifWidth, MiningMediaCompression.gifMaxTierWidth);
      expect(r.audioChannels, 2);
      expect(r.audioBitrate, '192k');
    });

    // BUG-1039 回归守卫：GIF 无帧间压缩，「源分辨率+源帧率」会线性爆炸（1080p 源 4 秒
    // 区间实测 48.9 秒 / 54 MB，Anki 收到后主线程解析直接无响应）。**任何**档位都不得
    // 再把 0 哨兵（=不限制）传给 GIF 抽取。截图侧的 0（不缩放）不受此约束。
    test('BUG-1039：没有任何图片档把 GIF 参数留成 0（不限制）哨兵', () {
      for (int t = 0; t < MiningMediaCompression.imageTierCount; t++) {
        final MiningMediaCompression c =
            MiningMediaCompression.resolve(imageTier: t, audioTier: 0);
        expect(c.gifFps, greaterThan(0), reason: '档 $t 的 gifFps 不得为 0（源帧率）');
        expect(c.gifWidth, greaterThan(0),
            reason: '档 $t 的 gifWidth 不得为 0（源分辨率）');
      }
    });

    test('图片档单调递增（清晰度越高，分辨率/质量/GIF 越大）', () {
      // 原片档 maxLongEdge=0 是「不缩放」哨兵（语义上最大），单独排除在截图数值比较外；
      // GIF 侧 BUG-1039 后全档都是有限值，故 gif 参数覆盖到满档一起校单调。
      for (int t = 1; t < MiningMediaCompression.imageTierCount; t++) {
        final MiningMediaCompression lo =
            MiningMediaCompression.resolve(imageTier: t - 1, audioTier: 0);
        final MiningMediaCompression hi =
            MiningMediaCompression.resolve(imageTier: t, audioTier: 0);
        if (t < MiningMediaCompression.imageTierMax) {
          expect(hi.screenshotMaxLongEdge,
              greaterThanOrEqualTo(lo.screenshotMaxLongEdge));
        }
        expect(hi.gifWidth, greaterThanOrEqualTo(lo.gifWidth));
        expect(hi.gifFps, greaterThanOrEqualTo(lo.gifFps));
      }
    });

    test('resolve 越界档位自动夹取（防损坏偏好值）', () {
      final MiningMediaCompression under =
          MiningMediaCompression.resolve(imageTier: -5, audioTier: -3);
      final MiningMediaCompression zero =
          MiningMediaCompression.resolve(imageTier: 0, audioTier: 0);
      expect(under.gifWidth, zero.gifWidth);
      expect(under.audioBitrate, zero.audioBitrate);

      final MiningMediaCompression over =
          MiningMediaCompression.resolve(imageTier: 99, audioTier: 99);
      final MiningMediaCompression top = MiningMediaCompression.resolve(
        imageTier: MiningMediaCompression.imageTierMax,
        audioTier: MiningMediaCompression.audioTierCount - 1,
      );
      expect(over.screenshotMaxLongEdge, top.screenshotMaxLongEdge);
      expect(over.audioBitrate, top.audioBitrate);
    });
  });

  group('buildFfmpegClipGifArgs 原片档滤镜', () {
    test('fps>0 & width>0：含 fps 与 scale 滤镜（压缩/高清档）', () {
      final List<String> args = buildFfmpegClipGifArgs(
        inputPath: '/tmp/in.mkv',
        startMs: 1000,
        endMs: 3000,
        outputPath: '/tmp/out.gif',
        fps: 8,
        width: 480,
      );
      final int fi = args.indexOf('-filter_complex');
      final String filter = args[fi + 1];
      expect(filter, contains('fps=8'));
      expect(filter, contains('scale=480:-2:flags=lanczos'));
      expect(filter, contains('palettegen'));
    });

    test('fps<=0 & width<=0：省略 fps/scale 滤镜（原片档=源帧率+源分辨率）', () {
      final List<String> args = buildFfmpegClipGifArgs(
        inputPath: '/tmp/in.mkv',
        startMs: 1000,
        endMs: 3000,
        outputPath: '/tmp/out.gif',
        fps: 0,
        width: 0,
      );
      final int fi = args.indexOf('-filter_complex');
      final String filter = args[fi + 1];
      expect(filter, isNot(contains('fps=')));
      expect(filter, isNot(contains('scale=')));
      expect(filter, startsWith('split[s0][s1]'),
          reason: '原片档滤镜链只剩 palettegen/paletteuse 双遍');
      expect(filter, contains('palettegen'));
    });
  });
}

class _FakeFfmpegBackend implements ffmpeg.FfmpegBackend {
  const _FakeFfmpegBackend(this.result);

  final ffmpeg.FfmpegRunResult result;

  @override
  Future<ffmpeg.FfmpegRunResult> run(
    List<String> args,
    Duration timeout,
  ) async =>
      result;

  @override
  Future<ffmpeg.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      result;
}

/// Simulates Hibiki's bundled `--disable-everything` min-ffmpeg for BUG-863.
///
/// Any `-map 0:s:N out` whose subtitle index N is not in [decodableIndices]
/// makes the WHOLE command abort with AVERROR(EINVAL) and write NOTHING —
/// mirroring real ffmpeg, which binds every output before decoding a packet, so
/// one undecodable track ("no decoder found" → "Error opening output files:
/// Invalid argument", exit -22) sinks the entire batch. A command whose every
/// mapped index is decodable writes each output file and exits 0.
class _MinBuildFakeFfmpegBackend implements ffmpeg.FfmpegBackend {
  _MinBuildFakeFfmpegBackend({required this.decodableIndices});

  final Set<int> decodableIndices;
  int runCount = 0;

  @override
  Future<ffmpeg.FfmpegRunResult> run(
    List<String> args,
    Duration timeout,
  ) async {
    runCount++;
    final Map<int, String> maps = <int, String>{};
    for (int i = 0; i + 2 < args.length; i++) {
      if (args[i] != '-map') continue;
      final RegExpMatch? m = RegExp(r'^0:s:(\d+)$').firstMatch(args[i + 1]);
      if (m != null) maps[int.parse(m.group(1)!)] = args[i + 2];
    }
    final bool allDecodable = maps.keys.every(decodableIndices.contains);
    if (maps.isEmpty || !allDecodable) {
      return const ffmpeg.FfmpegRunResult(
        returnCode: -22,
        output: 'Error opening output files: Invalid argument',
      );
    }
    maps.forEach((int idx, String out) {
      File(out)
          .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\ncue $idx\n');
    });
    return const ffmpeg.FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<ffmpeg.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      const ffmpeg.FfmpegRunResult(returnCode: 0, output: '');
}

class _InvalidBundledThenPathFfmpegBackend implements ffmpeg.FfmpegBackend {
  _InvalidBundledThenPathFfmpegBackend({required this.pathExecutable});

  static const String bundledPath = r'C:\App\Hibiki\ffmpeg.exe';

  final String pathExecutable;
  final List<String> attemptedExecutables = <String>[];

  @override
  Future<ffmpeg.FfmpegRunResult> run(
    List<String> args,
    Duration timeout,
  ) {
    return ffmpeg.runCliFfmpegForTesting(
      override: null,
      bundledPath: bundledPath,
      isWindows: true,
      args: args,
      timeout: timeout,
      runner: (
        String executable,
        List<String> args,
        Duration timeout,
      ) async {
        attemptedExecutables.add(executable);
        if (executable == bundledPath) {
          return const ffmpeg.FfmpegRunResult(
            returnCode: -1073741701,
            output: 'STATUS_INVALID_IMAGE_FORMAT',
          );
        }
        return ffmpeg.runFfmpegProcess(pathExecutable, args, timeout);
      },
    );
  }

  @override
  Future<ffmpeg.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      const ffmpeg.FfmpegRunResult(returnCode: 0, output: '{"format":{}}');
}

/// Simulates the BUG-863 defect: ffmpeg initialises EVERY output encoder before
/// writing any packet, so a demux pass that includes a track whose codec it
/// cannot transcode ([poisonIndex]) aborts at output-open with EINVAL (-22) and
/// writes NOTHING (all-or-nothing). A pass WITHOUT the poison track demuxes every
/// requested track to a non-empty file. [passes] records the `0:s:N`→outputPath
/// map of each invocation so a test can assert the single pass ran first, then
/// per-track fallback for the still-missing tracks.
class _FakePoisonFfmpegBackend implements ffmpeg.FfmpegBackend {
  _FakePoisonFfmpegBackend({required this.poisonIndex});

  final int poisonIndex;
  final List<Map<int, String>> passes = <Map<int, String>>[];

  Map<int, String> _parseMaps(List<String> args) {
    final Map<int, String> map = <int, String>{};
    final RegExp mapPattern = RegExp(r'^0:s:(\d+)$');
    for (int i = 0; i + 2 < args.length; i++) {
      if (args[i] != '-map') continue;
      final RegExpMatch? m = mapPattern.firstMatch(args[i + 1]);
      if (m == null) continue;
      map[int.parse(m.group(1)!)] = args[i + 2];
    }
    return map;
  }

  @override
  Future<ffmpeg.FfmpegRunResult> run(
    List<String> args,
    Duration timeout,
  ) async {
    final Map<int, String> pass = _parseMaps(args);
    passes.add(pass);
    if (pass.containsKey(poisonIndex)) {
      // Output-open abort: batch dies before any packet lands.
      return const ffmpeg.FfmpegRunResult(
        returnCode: -22,
        output: 'Error opening output files: Invalid argument',
      );
    }
    pass.forEach((int idx, String out) {
      File(out)
        ..createSync(recursive: true)
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nx\n');
    });
    return const ffmpeg.FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<ffmpeg.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      throw UnimplementedError('runProbe not used by subtitle extraction');
}
