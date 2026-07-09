import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// TODO-1365（BUG-678）守卫：YouTube 分离流的**回放 User-Agent 必须与 youtube_explode 铸造
/// 该流所用的 UA 一致**，且不得回退到残缺的裸 `Mozilla/5.0`。
///
/// 根因（见 BUG-678）：`androidVr` client 的 innertube context 不带 userAgent，youtube_explode
/// 全程用 [yt.YoutubeHttpClient.defaultHeaders] 的完整 Chrome UA 铸流 + HEAD 403 探测；旧代码用
/// 裸 `Mozilla/5.0` 回放 → googlevideo svpuc 对残缺 UA tarpit → libmpv/ffmpeg curl 超时打不开。
/// 本测锁死「回放 UA＝铸流 UA」这一不变量（三处 googlevideo 回放点一致），live 播放需真机验。
void main() {
  group('YouTube 回放 UA 与 youtube_explode 铸流 UA 一致（BUG-678）', () {
    test('kYoutubeStreamReplayUserAgent 等于 youtube_explode 默认 UA', () {
      final String? mintingUa =
          yt.YoutubeHttpClient.defaultHeaders['user-agent'];
      expect(mintingUa, isNotNull,
          reason: 'youtube_explode 默认头应带 user-agent（铸流/HEAD 探测用）');
      expect(kYoutubeStreamReplayUserAgent, mintingUa,
          reason: '回放 UA 必须与铸流 UA 一致，别硬编码成不同串');
    });

    test('回放 UA 是完整浏览器 UA，绝非残缺裸 Mozilla/5.0', () {
      expect(kYoutubeStreamReplayUserAgent, isNot('Mozilla/5.0'),
          reason: '裸 Mozilla/5.0 是 BUG-678 的 tarpit 根因，禁止回退');
      // 完整浏览器 UA 特征：带平台段 `(...)` + 浏览器/引擎 token。
      expect(kYoutubeStreamReplayUserAgent, contains('('),
          reason: '真实浏览器 UA 应含平台段（如 (Windows NT 10.0; ...)）');
      expect(
        kYoutubeStreamReplayUserAgent.contains('Chrome') ||
            kYoutubeStreamReplayUserAgent.contains('AppleWebKit') ||
            kYoutubeStreamReplayUserAgent.contains('Safari'),
        isTrue,
        reason: '真实浏览器 UA 应含引擎/浏览器 token',
      );
    });

    test('youtubeStreamReplayHeaders() 携带该 UA（video 主流 + audio-add 用）', () {
      final Map<String, String> h = youtubeStreamReplayHeaders();
      expect(h['User-Agent'], kYoutubeStreamReplayUserAgent);
    });

    test('制卡 ffmpeg -user_agent 与回放 UA 同源（三处一致）', () {
      final List<String> args =
          buildFfmpegRemoteInputArgs('https://x.googlevideo.com/videoplayback');
      final int i = args.indexOf('-user_agent');
      expect(i, greaterThanOrEqualTo(0),
          reason: 'googlevideo 远端输入必须显式设 -user_agent');
      expect(args[i + 1], kYoutubeStreamReplayUserAgent,
          reason: 'ffmpeg 回放 UA 必须与 libmpv 侧铸流 UA 同一常量');
    });
  });
}
