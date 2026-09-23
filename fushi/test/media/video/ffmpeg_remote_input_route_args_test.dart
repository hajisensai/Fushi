import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// BUG-2642 残留：在线视频源的制卡 ffmpeg 经宿主本机中继、并在 HLS 时放开分片扩展名
/// 检查——引擎按装配点 [ffmpegRemoteInputRouteResolver] 查输入地址的连接方式。
///
/// 纯函数断言（不跑 ffmpeg），锁四条：
/// ① 没装装配点 / 装配点对这条地址返回 null → 逐字节等于改动前（其余远端源零影响）；
/// ② 登记了代理 → `-http_proxy <端点>`，只出现在 `-i` 之前的输入选项里；
/// ③ 放开扩展名的三个选项**只**在 [FfmpegRemoteInputRoute.relaxHlsSegmentExtensions] 时出现
///    ——它们是 hls demuxer 私有选项，喂给 mp4 输入或老 ffmpeg 是致命的 `Option not found`；
/// ④ 本地路径根本不问装配点。
/// 真实 ffmpeg + 真中继的端到端见 `test/utils/net/ffmpeg_relay_route_e2e_test.dart`。
void main() {
  const String relayed = 'http://cdn.hoster.example:443/hls/index.m3u8';
  const String local = r'D:\videos\ep01.mkv';

  tearDown(() => ffmpegRemoteInputRouteResolver = null);

  test('① 没有装配点 / 未登记：参数与改动前逐字节相同', () {
    final List<String> before = buildFfmpegRemoteInputArgs(relayed);
    ffmpegRemoteInputRouteResolver = (String _) => null;
    expect(buildFfmpegRemoteInputArgs(relayed), before);
    expect(before, isNot(contains('-http_proxy')));
    expect(before, isNot(contains('-extension_picky')));
  });

  test('② 登记了中继：带 -http_proxy 端点，且不放开扩展名', () {
    ffmpegRemoteInputRouteResolver = (String input) => input == relayed
        ? const FfmpegRemoteInputRoute(httpProxy: 'http://fushi:s@127.0.0.1:9')
        : null;
    final List<String> args = buildFfmpegRemoteInputArgs(relayed);
    final int p = args.indexOf('-http_proxy');
    expect(p, greaterThanOrEqualTo(0));
    expect(args[p + 1], 'http://fushi:s@127.0.0.1:9');
    expect(args.contains('-i'), isFalse, reason: '只产出 -i 之前的输入选项');
    expect(args, isNot(contains('-allowed_segment_extensions')));
    expect(args, isNot(contains('-extension_picky')));
  });

  test('③ HLS 且 ffmpeg 认得：三个放开扩展名的选项成对出现', () {
    ffmpegRemoteInputRouteResolver = (String _) => const FfmpegRemoteInputRoute(
      httpProxy: 'http://fushi:s@127.0.0.1:9',
      relaxHlsSegmentExtensions: true,
    );
    final List<String> args = buildFfmpegRemoteInputArgs(relayed);
    for (final (String flag, String value) in <(String, String)>[
      ('-allowed_extensions', 'ALL'),
      ('-allowed_segment_extensions', 'ALL'),
      ('-extension_picky', '0'),
    ]) {
      final int i = args.indexOf(flag);
      expect(i, greaterThanOrEqualTo(0), reason: flag);
      expect(args[i + 1], value, reason: flag);
    }
  });

  test('④ 本地路径不问装配点', () {
    ffmpegRemoteInputRouteResolver = (String _) => fail('本地输入不该查远端连接方式');
    expect(buildFfmpegRemoteInputArgs(local), isEmpty);
  });
}
