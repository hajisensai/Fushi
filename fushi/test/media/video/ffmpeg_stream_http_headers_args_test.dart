import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// BUG-2625 守卫：远端流制卡时，抽取器必须把**播放器取到这条流用的同一组防盗链请求头**
/// 下发给 ffmpeg。
///
/// 真实故障：在线视频源扩展（Aniyomi）的 hoster 直链几乎都校验 Referer/User-Agent。
/// 播放器早就在带（`Media(httpHeaders:)` + libmpv `http-header-fields`），而制卡的 ffmpeg
/// 一直裸请求同一条 URL，于是 `Server returned 403 Forbidden (access denied)` → 句子音频
/// 抽不出来 → 制卡整条中止（`required audio missing`）。
///
/// 这些是纯函数断言（不跑 ffmpeg），锁死四条不变量：
/// ① 头非空 → 出现在 `-i` 之前（都是 http 协议的**输入**选项，放后面 ffmpeg 不认）；
/// ② 调用方给的 `User-Agent`/`Referer` 覆盖内置默认，且仍走各自的专用选项（不重复下发）；
/// ③ ffmpeg 自己管的头（Range / Accept-Encoding / Host …）不许被覆盖；
/// ④ 本地输入 / 空 map → 逐字节等于改动前。
/// 真正能不能取到流要真机验证（需要一个活的扩展源），见 BUG-2625。
void main() {
  const String remote = 'https://cdn.example-hoster.net/hls/master.m3u8';
  const String local = r'D:\videos\ep01.mkv';

  group('buildFfmpegRemoteInputArgs 的请求头透传（BUG-2625）', () {
    test('普通头 → 进 -headers，位置在 -i 之前', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{'Origin': 'https://site.example'},
      );
      final int h = args.indexOf('-headers');
      expect(h, greaterThanOrEqualTo(0), reason: '非空头必须下发 -headers');
      expect(args[h + 1], 'Origin: https://site.example\r\n',
          reason: 'ffmpeg 的 -headers 块以 CRLF 分隔且末尾也要带一个');
      // 本函数只产出 `-i` 之前的输入选项，故「都在 -i 之前」= 本列表里不含 `-i`。
      expect(args.contains('-i'), isFalse);
    });

    test('多个头合进同一个 -headers 块', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{
          'Origin': 'https://site.example',
          'Cookie': 'sid=abc',
        },
      );
      expect(args.where((String a) => a == '-headers').length, 1,
          reason: '多个头是一个块，不是多个 -headers');
      final String block = args[args.indexOf('-headers') + 1];
      expect(block, 'Origin: https://site.example\r\nCookie: sid=abc\r\n');
    });

    test('调用方的 User-Agent 覆盖内置默认，且不进 -headers', () {
      const String ua = 'Mozilla/5.0 (Aniyomi extension)';
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{'User-Agent': ua},
      );
      expect(args.where((String a) => a == '-user_agent').length, 1,
          reason: 'UA 只能下发一次，否则以哪个为准取决于选项解析顺序');
      expect(args[args.indexOf('-user_agent') + 1], ua);
      expect(args.contains('-headers'), isFalse,
          reason: 'UA 走专用选项，不该再进 -headers 块');
    });

    test('调用方的 Referer 走 -referer，大小写不敏感', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{'referer': 'https://site.example/'},
      );
      expect(args.where((String a) => a == '-referer').length, 1);
      expect(args[args.indexOf('-referer') + 1], 'https://site.example/');
      expect(args.contains('-headers'), isFalse);
    });

    test('调用方的 Referer 覆盖按 host 推出的 B 站 Referer（BUG-2574 不回退）', () {
      const String bilibili =
          'https://cn-hbyc-ct-01-02.bilivideo.com/upgcxcode/x-30280.m4s';
      // 不给头时仍按 host 推出 B 站 Referer——旧行为不许被本改动带走。
      final List<String> bare = buildFfmpegRemoteInputArgs(bilibili);
      expect(bare[bare.indexOf('-referer') + 1], kBilibiliCdnReferer);
      // 给了头则以调用方为准（它知道这条流是怎么取到的）。
      final List<String> overridden = buildFfmpegRemoteInputArgs(
        bilibili,
        httpHeaders: const <String, String>{
          'Referer': 'https://other.example/'
        },
      );
      expect(overridden.where((String a) => a == '-referer').length, 1);
      expect(overridden[overridden.indexOf('-referer') + 1],
          'https://other.example/');
    });

    test('ffmpeg 自己管的头被剔掉（Range/Accept-Encoding/Host 等）', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{
          'Range': 'bytes=0-1023',
          'Accept-Encoding': 'gzip',
          'Host': 'evil.example',
          'Connection': 'close',
          'Content-Length': '0',
          'Transfer-Encoding': 'chunked',
        },
      );
      expect(args.contains('-headers'), isFalse,
          reason: '这些头会打坏 ffmpeg 的分段读/解码，一条都不许下发');
    });

    test('值里带 CR/LF 的头被剔掉（不许注入额外头行）', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{
          'X-A': 'ok\r\nX-Injected: 1',
          'X-B': 'fine',
        },
      );
      final String block = args[args.indexOf('-headers') + 1];
      expect(block, 'X-B: fine\r\n');
      expect(block.contains('X-Injected'), isFalse);
    });

    test('名字里带 CR/LF / 冒号 / 空白的头被整条剔掉（不许借名字注入）', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{
          'X-A\r\nHost: evil.example': 'v',
          'X B': 'v',
          'X-C:': 'v',
          'X-D': 'fine',
        },
      );
      final String block = args[args.indexOf('-headers') + 1];
      expect(block, 'X-D: fine\r\n');
      expect(block.contains('evil.example'), isFalse);
    });

    test('空值/空名的头被跳过', () {
      final List<String> args = buildFfmpegRemoteInputArgs(
        remote,
        httpHeaders: const <String, String>{'X-A': '   ', '  ': 'v'},
      );
      expect(args.contains('-headers'), isFalse);
    });

    test('空 map 与本地输入 → 与改动前逐字节一致', () {
      expect(buildFfmpegRemoteInputArgs(remote),
          buildFfmpegRemoteInputArgs(remote, httpHeaders: const {}),
          reason: '空 map 不许改变既有远端参数');
      expect(
        buildFfmpegRemoteInputArgs(local,
            httpHeaders: const <String, String>{'Referer': 'https://x/'}),
        isEmpty,
        reason: '本地输入不加任何网络选项（头也一样）',
      );
    });
  });
}
