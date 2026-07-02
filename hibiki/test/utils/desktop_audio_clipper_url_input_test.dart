// TODO-1000 (BUG-529) 守卫：ffmpeg 抽取器的 inputPath 既可是本地路径也可是 http(s) 流
// URL（YouTube 分离流）。历史上三个抽取器都用 File.existsSync() 早退，会把 URL 输入误判为
// 「文件不存在」直接 return null，制卡从流 URL 抽 GIF/音频永远失败。此测试锁定：URL 被判为
// remote（跳过 existsSync），本地路径不受影响。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

void main() {
  group('debugIsRemoteFfmpegInput (BUG-529 URL input guard)', () {
    test('http(s) stream URLs are remote (skip existsSync)', () {
      expect(
        debugIsRemoteFfmpegInput(
            'https://rr4---sn-ipoxu.googlevideo.com/videoplayback?x=1'),
        isTrue,
      );
      expect(debugIsRemoteFfmpegInput('http://example.com/a.mp4'), isTrue);
    });

    test('local absolute paths are not remote (still existsSync-guarded)', () {
      expect(debugIsRemoteFfmpegInput(r'D:\video\dragon.mkv'), isFalse);
      expect(debugIsRemoteFfmpegInput('/home/u/clip.mp4'), isFalse);
      expect(debugIsRemoteFfmpegInput('relative/path.webm'), isFalse);
      // file:// 不是 ffmpeg 直吃的 http 输入，按本地对待（调用方传的是绝对路径）。
      expect(debugIsRemoteFfmpegInput('file:///tmp/x.mp4'), isFalse);
    });
  });

  group('buildFfmpegRemoteInputArgs (BUG-528 network resilience)', () {
    test('http(s) inputs get UA + reconnect flags before -i', () {
      final List<String> args =
          buildFfmpegRemoteInputArgs('https://x.googlevideo.com/videoplayback');
      expect(args, contains('-reconnect'));
      expect(args, contains('-reconnect_streamed'));
      expect(args, contains('-reconnect_delay_max'));
      expect(args, contains('-user_agent'));
    });
    test('local paths get no network flags', () {
      expect(buildFfmpegRemoteInputArgs(r'D:\v\a.mkv'), isEmpty);
      expect(buildFfmpegRemoteInputArgs('/tmp/a.mp4'), isEmpty);
    });
  });

  group('stream extractors embed reconnect flags for URL inputs (BUG-528)', () {
    test('GIF args reconnect on http input, before -i', () {
      final List<String> args = buildFfmpegClipGifArgs(
        inputPath: 'https://x.googlevideo.com/vp',
        startMs: 5000,
        endMs: 7000,
        outputPath: '/tmp/o.gif',
      );
      expect(args, contains('-reconnect'));
      expect(args.indexOf('-reconnect'), lessThan(args.indexOf('-i')));
    });
    test('audio args reconnect on http input, before -i', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: 'https://x.googlevideo.com/vp',
        startMs: 5000,
        endMs: 8000,
        outputPath: '/tmp/o.aac',
      );
      expect(args, contains('-reconnect'));
      expect(args.indexOf('-reconnect'), lessThan(args.indexOf('-i')));
    });
    test('frame args reconnect on http input, before -i', () {
      final List<String> args = buildFfmpegFrameArgs(
        inputPath: 'https://x.googlevideo.com/vp',
        outputPath: '/tmp/o.jpg',
        atSeconds: 6.0,
      );
      expect(args, contains('-reconnect'));
      expect(args.indexOf('-reconnect'), lessThan(args.indexOf('-i')));
    });
    test('local inputs keep original arg shape (no reconnect)', () {
      expect(
        buildFfmpegFrameArgs(inputPath: '/a/in.mp4', outputPath: '/a/t.jpg'),
        isNot(contains('-reconnect')),
      );
    });
  });

  test(
      'extractAudioSegmentViaFfmpeg no longer short-circuits URL as missing file',
      () async {
    String? summary;
    // 不可路由的 http 输入：不应报「does not exist」（那是本地路径守卫的话术），而是
    // 走到 ffmpeg 阶段再失败（进程异常/非零码/超时），或在无 ffmpeg 环境下进程异常。
    final String? out = await extractAudioSegmentViaFfmpeg(
      inputPath: 'http://127.0.0.1:9/nonroutable.m4a',
      startMs: 0,
      endMs: 1000,
      outputPath: '${Directory.systemTemp.path}/url_guard_probe.aac',
      onFailure: (String s) => summary = s,
    );
    expect(out, isNull); // 仍然失败（源不可达），但原因不是 existsSync 早退
    if (summary != null) {
      expect(summary!.contains('does not exist'), isFalse,
          reason: 'URL 输入不应被当作缺失本地文件早退');
    }
  });
}
