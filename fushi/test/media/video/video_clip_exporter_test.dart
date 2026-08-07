import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ffmpeg_backend.dart';
import 'package:fushi/src/media/video/video_clip_exporter.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

void main() {
  group('buildFfmpegVideoClipExportArgs', () {
    test(
        'maps video and the selected audio stream without subtitle/data streams',
        () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 1234,
        endMs: 6234,
        outputPath: '/video/clip.mkv',
        audioStreamIndex: 1,
      );

      expect(args, <String>[
        '-hide_banner',
        '-y',
        '-ss',
        '1.234',
        '-t',
        '5.000',
        '-i',
        '/video/source.mkv',
        '-map',
        '0:v:0',
        '-map',
        // 尾随 '?'：当 0:a:1 在真实 ffmpeg 流里越界（mpv 轨序号 != ffmpeg 0:a:N，
        // 挂外挂音频时常见），ffmpeg 不再 "Stream map matches no streams" 硬失败，
        // 而是降级回退默认轨（BUG-345）。
        '0:a:1?',
        '-sn',
        '-dn',
        '-c',
        'copy',
        '-avoid_negative_ts',
        'make_zero',
        '/video/clip.mkv',
      ]);
    });

    test('audio map always carries the optional "?" suffix', () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/video/clip.mkv',
        audioStreamIndex: 3,
      );
      // 守卫：任何拼出的 `-map 0:a:N` 都必须带 '?'，绝不会是裸 `0:a:N`。
      expect(args, contains('0:a:3?'));
      expect(args, isNot(contains('0:a:3')));
    });

    test('uses ffmpeg default audio selection when no explicit track is set',
        () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mp4',
        startMs: 0,
        endMs: 2000,
        outputPath: '/video/clip.mp4',
        audioStreamIndex: null,
      );

      expect(args.contains('-map'), isFalse);
      expect(args, contains('-sn'));
      expect(args, contains('-dn'));
      expect(args, isNot(contains('-filter_complex')));
      expect(args, isNot(contains('-vf')));
    });

    test('drops the audio map when the index is out of the known stream count',
        () {
      // audioStreamCount=2 → 合法下标只有 0/1；下标 2 越界（mpv 把外挂音频也算进
      // tracks.audio，但 ffmpeg 容器里只有 2 条），不加 -map，回退默认轨。
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/video/clip.mkv',
        audioStreamIndex: 2,
        audioStreamCount: 2,
      );
      expect(args.contains('-map'), isFalse);
      expect(args.any((String a) => a.startsWith('0:a:')), isFalse);
    });

    test('keeps the audio map when the index is within the known stream count',
        () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/video/clip.mkv',
        audioStreamIndex: 1,
        audioStreamCount: 2,
      );
      expect(args, contains('0:a:1?'));
    });
  });

  group('buildFfmpegVideoClipReencodeArgs (BUG-917 fallback)', () {
    test('re-encodes to libx264 + aac and always targets the given .mp4', () {
      final List<String> args = buildFfmpegVideoClipReencodeArgs(
        inputPath: '/video/source.mkv',
        startMs: 1000,
        endMs: 3000,
        outputPath: '/out/clip.mp4',
        audioStreamIndex: 1,
      );

      // libx264 + mp4 muxer are exactly what tool/ffmpeg-min provisioned for
      // clip export (TODO-1257); this path guarantees a muxable container even
      // when -c copy can't hold the source codecs.
      expect(
          args,
          containsAllInOrder(<String>[
            '-i',
            '/video/source.mkv',
            '-map',
            '0:v:0',
            '-map',
            '0:a:1?',
            '-sn',
            '-dn',
            '-c:v',
            'libx264',
          ]));
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
      expect(args, containsAllInOrder(<String>['-pix_fmt', 'yuv420p']));
      expect(args, containsAllInOrder(<String>['-movflags', '+faststart']));
      expect(args.last, '/out/clip.mp4');
      // Never a raw stream copy on this path.
      expect(args.contains('copy'), isFalse);
    });

    test('honours the same audio out-of-range drop as the copy path', () {
      final List<String> args = buildFfmpegVideoClipReencodeArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/out/clip.mp4',
        audioStreamIndex: 2,
        audioStreamCount: 2,
      );
      expect(args.contains('-map'), isFalse);
      expect(args.any((String a) => a.startsWith('0:a:')), isFalse);
    });
  });

  group('exportVideoClipViaFfmpeg', () {
    test(
        'falls back to re-encode when stream-copy fails, then succeeds '
        '(BUG-917)', () async {
      // Root cause: the bundled ffmpeg-min can only mux mp4/mov for video+audio.
      // When -c copy into .mp4 fails (codec not mp4-compatible), the exporter
      // must retry with libx264 + aac rather than surfacing exit -22.
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_fallback');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          final bool isReencode = args.contains('libx264');
          if (isReencode) {
            output.writeAsBytesSync(<int>[9, 8, 7]);
            return const FfmpegRunResult(returnCode: 0, output: 'ok');
          }
          // Stream-copy path fails the way an mkv-into-a-missing-muxer would.
          return const FfmpegRunResult(
            returnCode: 1,
            output: 'Error opening output files: Invalid argument',
          );
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 2000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.isSuccess, isTrue);
      expect(result.outputPath, output.path);
      // Both attempts ran: first stream-copy, then the libx264 fallback.
      expect(backend.calls.length, 2);
      expect(backend.calls.first.contains('copy'), isTrue);
      expect(backend.calls[1].contains('libx264'), isTrue);
      expect(output.existsSync(), isTrue);
    });

    test('reports ffmpegFailed only when BOTH copy and re-encode fail',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_bothfail');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) =>
            const FfmpegRunResult(returnCode: 1, output: 'boom'),
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 1000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.ffmpegFailed);
      expect(backend.calls.length, 2);
      expect(output.existsSync(), isFalse);
    });

    test('rejects invalid ranges without running ffmpeg and removes leftovers',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_invalid');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mp4')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend();

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 5000,
        endMs: 5000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.invalidRange);
      expect(result.outputPath, isNull);
      expect(backend.calls, isEmpty);
      expect(output.existsSync(), isFalse);
    });

    test('runs ffmpeg and returns the output path on success', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_success');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mkv');
      late List<String> observedArgs;
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          observedArgs = args;
          output.writeAsBytesSync(<int>[9, 8, 7]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 1000,
        endMs: 2500,
        outputPath: output.path,
        audioStreamIndex: 2,
        backend: backend,
      );

      expect(result.isSuccess, isTrue);
      expect(result.outputPath, output.path);
      expect(
          observedArgs,
          containsAllInOrder(<String>[
            '-map',
            '0:v:0',
            '-map',
            '0:a:2?',
            '-sn',
            '-dn',
            '-c',
            'copy',
          ]));
      expect(output.existsSync(), isTrue);
    });

    test('cleans partial output after ffmpeg failure', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_fail');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mkv');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          output.writeAsBytesSync(<int>[1, 2, 3]);
          return const FfmpegRunResult(returnCode: 1, output: 'boom');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 1000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.ffmpegFailed);
      expect(result.outputPath, isNull);
      expect(output.existsSync(), isFalse);
    });

    test('logs the ffmpeg stderr to ErrorLogService on failure (BUG-345)',
        () async {
      // C 修：ffmpeg 退出码非 0 时，真实 stderr 必须写进 ErrorLogService（设置
      // → 错误日志页能看到），不再被吞成黑盒。
      await ErrorLogService.instance.clear();
      addTearDown(() => ErrorLogService.instance.clear());
      final int before = ErrorLogService.instance.entries.length;

      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_log');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mkv');
      const String stderr =
          "Stream map '0:a:3' matches no streams. To ignore this, "
          "add a trailing '?' to the map.";
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) =>
            const FfmpegRunResult(returnCode: 1, output: stderr),
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 1000,
        outputPath: output.path,
        audioStreamIndex: 3,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.ffmpegFailed);
      // detail 仍携真实 stderr（给调用方拼 OSD）。
      expect(result.detail, contains('matches no streams'));
      // 关键：失败被记进错误日志服务，且包含真实 stderr。
      final List<ErrorLogEntry> added =
          ErrorLogService.instance.entries.skip(before).toList();
      expect(added, isNotEmpty);
      final ErrorLogEntry logged = added.firstWhere(
        (ErrorLogEntry e) => e.source == 'VideoClipExport',
        orElse: () => throw StateError(
            'no VideoClipExport entry logged: ${added.map((ErrorLogEntry e) => e.source).toList()}'),
      );
      expect(logged.error, contains('matches no streams'));
    });
  });
  group('soft-subtitle muxing', () {
    test('stream map stays untouched when there are no subtitle inputs', () {
      // 向后兼容守卫：不带字幕、且音轨未知时必须一个 -map 都不给，让 ffmpeg 走
      // 自动流选择（这是加字幕之前的既有行为）。
      expect(
        buildClipStreamMapArgs(explicitAudio: null, subtitleInputCount: 0),
        isEmpty,
      );
      expect(
        buildClipStreamMapArgs(explicitAudio: 2, subtitleInputCount: 0),
        <String>['-map', '0:v:0', '-map', '0:a:2?'],
      );
    });

    test('subtitle inputs force explicit video/audio maps', () {
      // ffmpeg 一见 -map 就关闭自动流选择；漏掉 v/a 的 map，输出只剩字幕。
      expect(
        buildClipStreamMapArgs(explicitAudio: 1, subtitleInputCount: 2),
        <String>[
          '-map',
          '0:v:0',
          '-map',
          '0:a:1?',
          '-map',
          '1:s:0',
          '-map',
          '2:s:0',
        ],
      );
    });

    test('unknown audio track maps ALL audio rather than gambling on 0:a:0',
        () {
      // 多音轨番剧的默认轨常常不是 0；赌 0:a:0 会导出错误语言的音频。
      expect(
        buildClipStreamMapArgs(explicitAudio: null, subtitleInputCount: 1),
        <String>['-map', '0:v:0', '-map', '0:a?', '-map', '1:s:0'],
      );
    });

    test('copy args add the subtitle input, its codec, and drop -sn', () {
      final List<String> args = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 1000,
        endMs: 3000,
        outputPath: '/video/clip.mp4',
        audioStreamIndex: 0,
        subtitlePaths: <String>['/tmp/a.srt', '/tmp/b.srt'],
        subtitleCodec: 'mov_text',
      );

      expect(args, <String>[
        '-hide_banner',
        '-y',
        // -ss/-t 只作用于紧随其后的源视频输入；字幕输入不带，它已被裁好并平移到 0。
        '-ss',
        '1.000',
        '-t',
        '2.000',
        '-i',
        '/video/source.mkv',
        '-i',
        '/tmp/a.srt',
        '-i',
        '/tmp/b.srt',
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-map',
        '1:s:0',
        '-map',
        '2:s:0',
        '-dn',
        '-c',
        'copy',
        '-c:s',
        'mov_text',
        '-avoid_negative_ts',
        'make_zero',
        '/video/clip.mp4',
      ]);
      // -sn 会把刚 map 进来的字幕流一起禁掉，带字幕时绝不能出现。
      expect(args, isNot(contains('-sn')));
    });

    test('re-encode args carry the subtitles too, so the fallback keeps them',
        () {
      // copy 轮失败降级到重编码时若丢字幕，用户拿到的就是没字幕的片段。
      final List<String> args = buildFfmpegVideoClipReencodeArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/video/clip.mp4',
        audioStreamIndex: 1,
        subtitlePaths: <String>['/tmp/a.srt'],
        subtitleCodec: 'mov_text',
      );

      expect(args, containsAllInOrder(<String>['-i', '/tmp/a.srt']));
      expect(args, containsAllInOrder(<String>['-map', '1:s:0']));
      expect(args, containsAllInOrder(<String>['-c:s', 'mov_text']));
      expect(args, contains('libx264'));
      expect(args, isNot(contains('-sn')));
    });

    test('subtitle args are inert without a codec (unsupported container)', () {
      // 容器封不下文本字幕时，命令必须与「加字幕功能不存在」时逐字节一致。
      final List<String> withPaths = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/video/clip.avi',
        audioStreamIndex: 1,
        subtitlePaths: <String>['/tmp/a.srt'],
        subtitleCodec: null,
      );
      final List<String> baseline = buildFfmpegVideoClipExportArgs(
        inputPath: '/video/source.mkv',
        startMs: 0,
        endMs: 1000,
        outputPath: '/video/clip.avi',
        audioStreamIndex: 1,
      );
      expect(withPaths, baseline);
      expect(withPaths, contains('-sn'));
    });

    test('writes cues to a temp SRT, feeds ffmpeg, then cleans it up',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_sub_ok');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4');

      final List<String> seenSubtitlePaths = <String>[];
      String? seenSubtitleContent;
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          for (final String a in args) {
            if (a.endsWith('.srt')) {
              seenSubtitlePaths.add(a);
              // ffmpeg 真跑的那一刻文件必须已经落盘且可读（flush: true）。
              seenSubtitleContent = File(a).readAsStringSync();
            }
          }
          output.writeAsBytesSync(<int>[9]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 2000,
        outputPath: output.path,
        backend: backend,
        subtitleContents: <String>[
          '1\n00:00:00,000 --> 00:00:01,000\n主字幕\n\n',
          '1\n00:00:00,000 --> 00:00:01,000\nsecondary\n\n',
        ],
      );

      expect(result.isSuccess, isTrue);
      expect(result.subtitleTrackCount, 2);
      expect(seenSubtitlePaths.length, 2);
      expect(seenSubtitleContent, isNotNull);
      // UTF-8 往返：日文字幕不能在落盘时变成 mojibake。
      expect(
        File(seenSubtitlePaths.first).existsSync(),
        isFalse,
        reason: '临时 SRT 必须在导出结束后清理，否则每导一次就留一份垃圾',
      );
    });

    test('UTF-8 subtitle content survives the round trip to disk', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_sub_utf8');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4');
      const String srt = '1\n00:00:00,000 --> 00:00:01,000\n日本語の字幕\n\n';

      String? readBack;
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          for (final String a in args) {
            if (a.endsWith('.srt')) readBack = File(a).readAsStringSync();
          }
          output.writeAsBytesSync(<int>[9]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 2000,
        outputPath: output.path,
        backend: backend,
        subtitleContents: <String>[srt],
      );

      expect(readBack, srt);
    });

    test(
        'falls back to a subtitle-less export when subtitle muxing keeps '
        'failing', () async {
      // 根因场景：旧的桌面精简 ffmpeg 没编入 movtext 编码器 → 'Unknown encoder'。
      // 加字幕这个增强绝不能把原本能成功的导出变成失败。
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_sub_degrade');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4');

      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          if (args.contains('-c:s')) {
            return const FfmpegRunResult(
              returnCode: 1,
              output: "Unknown encoder 'mov_text'",
            );
          }
          output.writeAsBytesSync(<int>[9]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 2000,
        outputPath: output.path,
        backend: backend,
        subtitleContents: <String>['1\n00:00:00,000 --> 00:00:01,000\nx\n\n'],
      );

      expect(result.isSuccess, isTrue);
      expect(result.subtitleTrackCount, 0, reason: '降级后不能谎称带了字幕');
      expect(output.existsSync(), isTrue);
      // 带字幕的 copy + 重编码两轮失败后，才重跑无字幕的 copy 轮。
      expect(backend.calls.length, 3);
      expect(backend.calls[0].contains('-c:s'), isTrue);
      expect(backend.calls[1].contains('-c:s'), isTrue);
      expect(backend.calls[2].contains('-c:s'), isFalse);
    });

    test('skips subtitles entirely for containers that cannot carry them',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_sub_avi');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.avi');

      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          output.writeAsBytesSync(<int>[9]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 2000,
        outputPath: output.path,
        backend: backend,
        subtitleContents: <String>['1\n00:00:00,000 --> 00:00:01,000\nx\n\n'],
      );

      expect(result.isSuccess, isTrue);
      expect(result.subtitleTrackCount, 0);
      expect(
          backend.calls.single.any((String a) => a.endsWith('.srt')), isFalse);
      expect(backend.calls.single.contains('-sn'), isTrue);
    });

    test('blank subtitle content is ignored', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_sub_blank');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mp4');

      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) {
          output.writeAsBytesSync(<int>[9]);
          return const FfmpegRunResult(returnCode: 0, output: 'ok');
        },
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 2000,
        outputPath: output.path,
        backend: backend,
        subtitleContents: <String>['', '   \n  '],
      );

      expect(result.isSuccess, isTrue);
      expect(result.subtitleTrackCount, 0);
      expect(backend.calls.single.contains('-c:s'), isFalse);
    });
  });

  group('extractFfmpegFailureReason (TODO-910)', () {
    // 真实形态：开头是 ffmpeg `-hide_banner` 仍保留的输入 banner（`Input #0 ...`
    // + `Metadata: encoder :...`），真正的失败行在 stderr **末尾**。
    const String realStderr = '''
Input #0, matroska,webm, from '/media/himoto/[Kamigami] Himouto! Umaru-chan - 11 [1920x1080 x264 AAC Sub(Chs,Cht,Jap)].mkv':
  Metadata:
    encoder         : libebml v1.3.0 + libmatroska v1.4.1
  Duration: 00:23:40.00, start: 0.000000, bitrate: 2543 kb/s
  Stream #0:0: Video: h264 (High), yuv420p(progressive), 1920x1080
  Stream #0:1(jpn): Audio: aac (LC), 48000 Hz, stereo, fltp
[matroska @ 0000020f] Could not find codec parameters for stream 2
Conversion failed!
''';

    test('returns the real error line from the tail, not the input banner', () {
      final String reason = extractFfmpegFailureReason(realStderr);
      // load-bearing：若改回从头截断，这里会拿到 `Input #0`/`encoder` banner → 红。
      expect(reason, 'Conversion failed!');
      expect(reason, isNot(contains('Input #0')));
      expect(reason, isNot(contains('encoder')));
    });

    test('prefers an error-keyword line over later non-error noise', () {
      const String stderr = '''
Input #0, matroska,webm, from 'a.mkv':
  Metadata:
    encoder         : libebml
Stream map '0:a:3' matches no streams.
frame=    1 fps=0.0 q=-1.0 size=       0kB time=00:00:00.00
''';
      final String reason = extractFfmpegFailureReason(stderr);
      expect(reason, contains('matches no streams'));
      expect(reason, isNot(contains('Input #0')));
    });

    test('degrades to the last non-noise line when no error keyword exists',
        () {
      // 退化输入：只有 banner / Metadata，无真错误行——绝不能返回 `Input #0` banner。
      const String bannerOnly = '''
Input #0, matroska,webm, from 'a.mkv':
  Metadata:
    encoder         : libebml v1.3.0
  Duration: 00:23:40.00, start: 0.000000, bitrate: 2543 kb/s
  Stream #0:0: Video: h264 (High), yuv420p, 1920x1080
''';
      final String reason = extractFfmpegFailureReason(bannerOnly);
      expect(reason, isNot(startsWith('Input #0')));
      expect(reason, isNot(contains('encoder')));
      expect(reason, isNotEmpty);
    });

    test('returns empty string for blank stderr', () {
      expect(extractFfmpegFailureReason(''), '');
      expect(extractFfmpegFailureReason('   \n  \n'), '');
    });

    test('exportVideoClipViaFfmpeg detail carries the tail error, not banner',
        () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('hibiki_clip_export_tail');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File input = File('${dir.path}/source.mkv')
        ..writeAsBytesSync(<int>[1]);
      final File output = File('${dir.path}/clip.mkv');
      final _FakeFfmpegBackend backend = _FakeFfmpegBackend(
        onRun: (List<String> args) =>
            const FfmpegRunResult(returnCode: 1, output: realStderr),
      );

      final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
        inputPath: input.path,
        startMs: 0,
        endMs: 1000,
        outputPath: output.path,
        backend: backend,
      );

      expect(result.failure, VideoClipExportFailure.ffmpegFailed);
      // detail = 尾段真因，不再是全量 stderr / 头部 banner。
      expect(result.detail, 'Conversion failed!');
      expect(result.detail, isNot(contains('Input #0')));
    });
  });
}

typedef _RunHandler = FutureOr<FfmpegRunResult> Function(List<String> args);

class _FakeFfmpegBackend implements FfmpegBackend {
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '{"format":{}}');

  _FakeFfmpegBackend({this.onRun});

  final _RunHandler? onRun;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(List<String>.from(args));
    final _RunHandler? handler = onRun;
    if (handler == null) {
      return const FfmpegRunResult(returnCode: 0, output: '');
    }
    return Future<FfmpegRunResult>.value(handler(args));
  }
}
