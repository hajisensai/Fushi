import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/app_model.dart' show youtubeMineAbortMessage;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// 反馈 vhW6OpRy2H（Windows，香港网络）：浏览器扩展 YouTube 制卡，句子音频先由 Dart
/// range 物化（走 app 代理），失败后回退 ffmpeg 直读 googlevideo——而 ffmpeg 那一程从不
/// 带 app 的代理设置，两程一起失败（`HandshakeException` → `ffmpeg exit -138`），
/// requireAudio=true 让整张卡中止，扩展里只看见一句读不懂的
/// `required audio missing (HandshakeException…)`。
///
/// 锁：ffmpeg 远端输入与 Dart 出站用**同一份** app 代理裁决（手动 → 带凭据的
/// `-http_proxy`；直连 / 本机目标 → 不传；中继优先），SOCKS 环境变量代理不冒充支持；
/// 网络类中止原因翻成用户看得懂、指向代理设置的一句话。
void main() {
  const String googlevideo =
      'https://rr3---sn-a5mekn6s.googlevideo.com/videoplayback?itag=140';

  late String Function() savedMode;
  late String Function() savedProxy;
  late String Function() savedUser;
  late String Function() savedPass;

  setUp(() {
    savedMode = appUserProxyModeReader;
    savedProxy = appUserProxyReader;
    savedUser = appUserProxyUsernameReader;
    savedPass = appUserProxyPasswordReader;
  });
  tearDown(() {
    appUserProxyModeReader = savedMode;
    appUserProxyReader = savedProxy;
    appUserProxyUsernameReader = savedUser;
    appUserProxyPasswordReader = savedPass;
    ffmpegRemoteInputRouteResolver = null;
  });

  String? proxyArg(List<String> args) {
    final int i = args.indexOf('-http_proxy');
    return i < 0 ? null : args[i + 1];
  }

  test('手动代理：ffmpeg 远端输入带 -http_proxy，与 Dart findProxy 同一端点', () {
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => 'http://127.0.0.1:7890';
    appUserProxyUsernameReader = () => '';
    final List<String> args = buildFfmpegRemoteInputArgs(googlevideo);
    expect(proxyArg(args), 'http://127.0.0.1:7890');
    expect(
      resolveAppProxyDirective(Uri.parse(googlevideo)),
      'PROXY 127.0.0.1:7890',
      reason: 'Dart 出站与 ffmpeg 必须是同一个出口',
    );
    expect(args.contains('-i'), isFalse, reason: '只产出 -i 之前的输入选项');
  });

  test('手动代理带凭据：userinfo 百分号编码后进 -http_proxy', () {
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => 'proxy.example.com:3128';
    appUserProxyUsernameReader = () => 'me@corp';
    appUserProxyPasswordReader = () => 'p:w/d';
    expect(
      proxyArg(buildFfmpegRemoteInputArgs(googlevideo)),
      'http://me%40corp:p%3Aw%2Fd@proxy.example.com:3128',
    );
  });

  test('直连模式 / 手动地址非法：不传 -http_proxy', () {
    appUserProxyModeReader = () => kProxyModeDirect;
    appUserProxyReader = () => '127.0.0.1:7890';
    expect(proxyArg(buildFfmpegRemoteInputArgs(googlevideo)), isNull);

    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => 'not a proxy';
    expect(proxyArg(buildFfmpegRemoteInputArgs(googlevideo)), isNull);
  });

  test('本机 / 局域网目标不被代理（与 isDirectProxyTarget 同闸门）', () {
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => '127.0.0.1:7890';
    expect(
      proxyArg(buildFfmpegRemoteInputArgs('http://192.168.1.20:8080/a.mp4')),
      isNull,
    );
    expect(buildFfmpegRemoteInputArgs(r'D:\videos\ep01.mkv'), isEmpty);
  });

  test('登记了宿主中继：中继端点优先于 app 代理', () {
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => '127.0.0.1:7890';
    ffmpegRemoteInputRouteResolver = (String _) =>
        const FfmpegRemoteInputRoute(httpProxy: 'http://fushi:s@127.0.0.1:9');
    final List<String> args = buildFfmpegRemoteInputArgs(googlevideo);
    expect(proxyArg(args), 'http://fushi:s@127.0.0.1:9');
    expect(
      args.where((String a) => a == '-http_proxy').length,
      1,
      reason: '只能有一个 -http_proxy',
    );
  });

  test('中继只登记了 HLS 选项（无端点）：仍走 app 代理', () {
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => '127.0.0.1:7890';
    ffmpegRemoteInputRouteResolver = (String _) =>
        const FfmpegRemoteInputRoute(disableHlsSegmentPrefetch: true);
    expect(
      proxyArg(buildFfmpegRemoteInputArgs(googlevideo)),
      'http://127.0.0.1:7890',
    );
  });

  test('SOCKS 环境变量代理：判定按 Dart 的查找顺序，ffmpeg 不冒充支持', () {
    final Uri https = Uri.parse(googlevideo);
    final Uri http = Uri.parse('http://example.com/a.mp4');
    expect(
      envProxySchemeIsSocks(https, <String, String>{
        'HTTPS_PROXY': 'socks5://127.0.0.1:1080',
      }),
      isTrue,
    );
    expect(
      envProxySchemeIsSocks(https, <String, String>{
        'https_proxy': 'http://127.0.0.1:7890',
      }),
      isFalse,
    );
    expect(
      envProxySchemeIsSocks(http, <String, String>{
        'https_proxy': 'socks5://127.0.0.1:1080',
      }),
      isFalse,
      reason: 'http 目标只看 http_proxy',
    );
    expect(envProxySchemeIsSocks(https, const <String, String>{}), isFalse);
  });

  group('网络类失败判定与给用户的话', () {
    // 本进程平台上 ffmpeg 的 ETIMEDOUT（Windows 捆绑构建 138，macOS/iOS 60，其余 110）。
    final int etimedout = Platform.isWindows
        ? 138
        : (Platform.isMacOS || Platform.isIOS)
        ? 60
        : 110;

    test('反馈日志里的两种根因都判为网络失败', () {
      expect(
        isRemoteFetchNetworkFailure(
          'required audio missing (HandshakeException: Connection terminated '
          'during handshake)',
        ),
        isTrue,
      );
      expect(
        isRemoteFetchNetworkFailure(
          'ffmpeg exit -$etimedout; executable=ffmpeg; stderr=Error opening '
          'input files: Error number -$etimedout occurred',
        ),
        isTrue,
      );
      expect(
        isRemoteFetchNetworkFailure(
          'SocketException: Connection timed out (OS Error: errno = 121)',
        ),
        isTrue,
      );
    });

    test('本机问题不算网络失败', () {
      expect(
        isRemoteFetchNetworkFailure(
          'required audio missing (ffmpeg launch failed: executable=ffmpeg; '
          'errorCode=2; message=No such file or directory)',
        ),
        isFalse,
      );
      expect(
        isRemoteFetchNetworkFailure(
          "ffmpeg exit 1; stderr=Unknown encoder 'png'",
        ),
        isFalse,
      );
      expect(isRemoteFetchNetworkFailure('required audio missing'), isFalse);
    });

    test('YouTube 中止消息：网络失败指向代理设置并保留原因；其余原样', () {
      const String netAbort =
          'required audio missing (HandshakeException: Connection terminated '
          'during handshake)';
      final String msg = youtubeMineAbortMessage(netAbort);
      expect(msg, startsWith('YouTube 制卡失败：'));
      expect(msg, contains('YouTube 的视频服务器'));
      expect(msg, contains('网络代理'));
      expect(msg, contains(netAbort), reason: '技术原因仍随消息带回，便于排查');

      const String localAbort =
          'required audio missing (ffmpeg launch failed: errorCode=2)';
      expect(youtubeMineAbortMessage(localAbort), 'YouTube 制卡失败：$localAbort');
      expect(youtubeMineAbortMessage(null), 'YouTube 制卡失败：媒体抽取失败');
    });
  });
}
