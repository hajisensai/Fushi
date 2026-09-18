// TODO-1000 (BUG-529) 守卫：ffmpeg 抽取器的 inputPath 既可是本地路径也可是 http(s) 流
// URL（YouTube 分离流）。历史上三个抽取器都用 File.existsSync() 早退，会把 URL 输入误判为
// 「文件不存在」直接 return null，制卡从流 URL 抽 GIF/音频永远失败。此测试锁定：URL 被判为
// remote（跳过 existsSync），本地路径不受影响。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

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

    // TODO-1290: `-138` (mingw errno ETIMEDOUT) 是 connect 阶段的 TCP/TLS 网络错误，
    // `-reconnect`/`-reconnect_streamed` 只管流中断/EOF、不覆盖它 → 短音频段仍硬失败。
    // 守卫 `-reconnect_on_network_error 1` 存在且成对（值紧跟在开关后），且 remote-only。
    test('http(s) inputs reconnect on connect-stage network error (TODO-1290)',
        () {
      final List<String> args =
          buildFfmpegRemoteInputArgs('https://x.googlevideo.com/videoplayback');
      final int i = args.indexOf('-reconnect_on_network_error');
      expect(i, greaterThanOrEqualTo(0),
          reason: 'connect 阶段网络错误(含 -138)必须触发自动重连');
      expect(args[i + 1], '1');
    });
    test('local paths get no reconnect_on_network_error flag (TODO-1290)', () {
      expect(buildFfmpegRemoteInputArgs(r'D:\v\a.mkv'),
          isNot(contains('-reconnect_on_network_error')));
      expect(buildFfmpegRemoteInputArgs('/tmp/a.mp4'),
          isNot(contains('-reconnect_on_network_error')));
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
      // TODO-1290: connect 阶段网络错误(-138)的重连开关也要传到句子音频抽取命令，
      // 且置于 -i 之前（http 输入选项）——这正是用户日志里崩 -138 的那条命令。
      expect(args, contains('-reconnect_on_network_error'));
      expect(args.indexOf('-reconnect_on_network_error'),
          lessThan(args.indexOf('-i')));
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

  // BUG-2574：B 站 DASH 直链是防盗链的 —— 不带 Referer 时 CDN 直接回
  // `Server returned 403 Forbidden (access denied)`，ffmpeg 连输入都打不开，制卡只剩
  // 一句「失败」看不到根因。实测（番剧 ep815751 音轨 `cn-hbyc-ct-01-02.bilivideo.com`）：
  // 不带 403、带 `https://www.bilibili.com/` 即 206 并裁出 3 秒片段。
  group('buildFfmpegRemoteInputArgs 防盗链 Referer (BUG-2574)', () {
    test('B 站 CDN 直链一律带 -referer', () {
      for (final String url in <String>[
        'https://cn-hbyc-ct-01-02.bilivideo.com/upgcxcode/1/2/3.m4s?e=1',
        'https://upos-sz-estgoss.bilivideo.com/upgcxcode/1/2/3.m4s',
        'https://xy1x2x3xy.mcdn.bilivideo.cn:8082/v1/resource/a.m4s',
        'https://upos-hz-mirrorcos.acgvideo.com/a.m4s',
        'https://upos-hz-mirrorakam.akamaized.net/a.m4s',
      ]) {
        final List<String> args = buildFfmpegRemoteInputArgs(url);
        final int i = args.indexOf('-referer');
        expect(i, greaterThanOrEqualTo(0),
            reason: 'B 站直链必须带防盗链 Referer，否则 CDN 403：$url');
        expect(args[i + 1], kBilibiliCdnReferer);
      }
    });

    test('非 B 站流不带 -referer（YouTube 等不受影响）', () {
      expect(
        buildFfmpegRemoteInputArgs(
            'https://rr4---sn-x.googlevideo.com/videoplayback'),
        isNot(contains('-referer')),
      );
      expect(
        buildFfmpegRemoteInputArgs('https://cdn.example.com/a.m4s'),
        isNot(contains('-referer')),
      );
    });

    test('本地路径仍然什么网络开关都不加', () {
      expect(buildFfmpegRemoteInputArgs(r'D:\v\a.mkv'), isEmpty);
      expect(buildFfmpegRemoteInputArgs('/tmp/a.mp4'), isEmpty);
    });

    test('isBilibiliCdnHost 只认 B 站自家域与 upos-*.akamaized.net', () {
      expect(isBilibiliCdnHost('cn-hbyc-ct-01-02.bilivideo.com'), isTrue);
      expect(isBilibiliCdnHost('XY.MCDN.BILIVIDEO.CN'), isTrue); // 大小写不敏感
      expect(isBilibiliCdnHost('bilivideo.com'), isTrue);
      expect(isBilibiliCdnHost('upos-hz-mirrorakam.akamaized.net'), isTrue);
      // 后缀必须过点：不能把 `notbilivideo.com` 当 B 站。
      expect(isBilibiliCdnHost('notbilivideo.com'), isFalse);
      // Akamai 是共享域名，非 upos- 前缀不认。
      expect(isBilibiliCdnHost('someone.akamaized.net'), isFalse);
      expect(isBilibiliCdnHost(''), isFalse);
    });

    test('畸形 URL 不抛异常也不带 referer', () {
      expect(ffmpegRefererForRemoteInput('https://%%%bad'), isNull);
      expect(ffmpegRefererForRemoteInput(r'D:\v\a.mkv'), isNull);
    });

    test('句子音频命令把 -referer 放在 -i 之前（http 输入选项）', () {
      final List<String> args = buildFfmpegClipArgs(
        inputPath: 'https://cn-hbyc-ct-01-02.bilivideo.com/upgcxcode/a.m4s',
        startMs: 1000,
        endMs: 4000,
        outputPath: '/tmp/o.aac',
      );
      expect(args, contains('-referer'));
      expect(args.indexOf('-referer'), lessThan(args.indexOf('-i')),
          reason: 'Referer 是 http 协议的输入选项，放 -i 之后就不生效');
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
