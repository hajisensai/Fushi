import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi/src/utils/net/ffmpeg_relay_route.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';
import 'package:path/path.dart' as p;

/// BUG-2692：Emby / Jellyfin 能播放、制不了卡（截图 / 动图 / 句子音频三条抽取全报
/// `ffmpeg exit 1; executable=ffmpeg-kit; ... stream?static=true&...: I/O error`）。
///
/// 播放器取流一直经 [nativePlaybackUri] 走本机中继（Dart 的 TLS + 应用代理），制卡
/// ffmpeg 却直连原始 https 地址——移动端 ffmpeg-kit 用自己编进去的 TLS、也不认应用
/// 代理。以前只有在线视频源（BUG-2642 残留）改道中继，媒体服务器被排除在外。
class _FakeMediaServerClient extends RemoteVideoClient
    implements MediaServerBrowser {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeOnlineClient extends RemoteVideoClient
    implements RemoteVideoStreamHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlainRemoteClient extends RemoteVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const String _embyStream =
    'https://emby.example.com/Videos/136641/stream?static=true'
    '&MediaSourceId=mediasource_136641&PlaySessionId=p&DeviceId=d&api_key=k';

void main() {
  // 截图抽取完会经 PaintingBinding 解码缩放；测试绑定默认把 HttpClient 换成一律回
  // 400 的桩，这里要的是真中继 + 真原点，撤掉它。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  group('videoMiningInputUsesPlaybackRelay', () {
    test('媒体服务器的网络流改走中继（BUG-2692）', () {
      expect(
        videoMiningInputUsesPlaybackRelay(
          remoteClient: _FakeMediaServerClient(),
          mediaSource: _embyStream,
        ),
        isTrue,
      );
    });

    test('在线视频源照旧改走中继（BUG-2642 残留）', () {
      expect(
        videoMiningInputUsesPlaybackRelay(
          remoteClient: _FakeOnlineClient(),
          mediaSource: 'https://cdn.example-hoster.net/hls/index',
        ),
        isTrue,
      );
    });

    test('其它远端 client（互联主机的形状）不改道：它有钉扎与 host 端裁音频两条专用通道', () {
      expect(
        videoMiningInputUsesPlaybackRelay(
          remoteClient: _FakePlainRemoteClient(),
          mediaSource: 'https://192.168.1.2:38765/api/library/videos/1/stream',
        ),
        isFalse,
      );
    });

    test('本地文件 / 没有远端 client 不改道', () {
      expect(
        videoMiningInputUsesPlaybackRelay(
          remoteClient: _FakeMediaServerClient(),
          mediaSource: r'C:\videos\ep01.mkv',
        ),
        isFalse,
      );
      expect(
        videoMiningInputUsesPlaybackRelay(
          remoteClient: null,
          mediaSource: _embyStream,
        ),
        isFalse,
      );
    });

    test('生产类型归属：Emby/Jellyfin client 命中，互联主机不命中', () {
      // 判据按能力接口判；这里钉住真实类型确实挂着 / 没挂着那两个接口，
      // 免得哪天改了 implements 清单而判据静默失效。
      expect(_implements<JellyfinVideoClient, MediaServerBrowser>(), isTrue);
      expect(
        _implements<UrlStreamVideoClient, RemoteVideoStreamHeaders>(),
        isTrue,
      );
      expect(
        _implements<InterconnectSyncBackend, MediaServerBrowser>(),
        isFalse,
      );
      expect(
        _implements<InterconnectSyncBackend, RemoteVideoStreamHeaders>(),
        isFalse,
      );
    });
  });

  // 端到端：真捆绑 ffmpeg-min + 真本机中继 + 自签 https 的 Emby 形状原点
  // （`/Videos/{id}/stream?static=true&…&api_key=`，mp4 整文件 + Range）。
  // ffmpeg 拿到的是中继的明文形式、只经 `-http_proxy` 取字节，TLS 全由中继做——
  // 与播放器同一条路径。
  final String? bundled = _bundledFfmpeg();
  test(
    'Emby 形状的 https 直出流：经中继后 ffmpeg 抽得出句子音频与截图',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync('emby_relay_');
      final String? oldOverride = ffmpegPathOverride;
      final String? oldProbeOverride = ffprobePathOverride;
      final String Function() oldMode = appUserProxyModeReader;
      final HttpClient Function() oldFactory =
          appNativeProxyUpstreamClientFactory;
      addTearDown(() {
        tmp.deleteSync(recursive: true);
        ffmpegPathOverride = oldOverride;
        ffprobePathOverride = oldProbeOverride;
        setFfmpegBackendForTesting(null);
        debugResetFfmpegHlsSegmentExtensionSupport();
        ffmpegRemoteInputRouteResolver = null;
        debugClearFfmpegRelayRoutes();
        appUserProxyModeReader = oldMode;
        appNativeProxyUpstreamClientFactory = oldFactory;
        clearPinnedNativeOriginsForTesting();
      });
      ffmpegPathOverride = bundled;
      ffprobePathOverride = p.join(
        p.dirname(bundled!),
        Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
      );
      setFfmpegBackendForTesting(null);
      debugResetFfmpegHlsSegmentExtensionSupport();
      appUserProxyModeReader = () => kProxyModeDirect;

      final List<int> video = File(
        p.join('..', 'docs', 'todo-524-video.mp4'),
      ).readAsBytesSync();
      final ({String certificatePem, String privateKeyPem}) cert =
          FushiSelfSignedCertGenerator.generate(
            commonName: 'fushi-test',
            sanIpAddresses: <String>['127.0.0.1'],
          );
      final SecurityContext ctx = SecurityContext()
        ..useCertificateChainBytes(cert.certificatePem.codeUnits)
        ..usePrivateKeyBytes(cert.privateKeyPem.codeUnits);
      final HttpServer origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        ctx,
      );
      addTearDown(() => origin.close(force: true));
      final List<String> seen = <String>[];
      origin.listen((HttpRequest request) async {
        final HttpResponse res = request.response;
        seen.add(request.uri.toString());
        if (request.uri.path != '/Videos/136641/stream' ||
            request.uri.queryParameters['api_key'] != 'k') {
          res.statusCode = HttpStatus.unauthorized;
          await res.close();
          return;
        }
        res.headers.contentType = ContentType('video', 'mp4');
        res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final String? range = request.headers.value(HttpHeaders.rangeHeader);
        final RegExpMatch? m = range == null
            ? null
            : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (m == null) {
          res.contentLength = video.length;
          res.add(video);
        } else {
          final int start = int.parse(m.group(1)!);
          final int end = m.group(2)!.isEmpty
              ? video.length - 1
              : int.parse(m.group(2)!);
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${video.length}',
          );
          res.contentLength = end - start + 1;
          res.add(video.sublist(start, end + 1));
        }
        await res.close();
      });
      // 系统信任根不认测试自签证书：测试里换成信任它的客户端；生产走默认工厂。
      appNativeProxyUpstreamClientFactory = () => createAppHttpClient()
        ..badCertificateCallback = (X509Certificate _, String __, int ___) =>
            true;
      ffmpegRemoteInputRouteResolver = ffmpegRelayRouteFor;

      final String source = _embyStream.replaceFirst(
        'emby.example.com',
        '127.0.0.1:${origin.port}',
      );
      final ({String url, Future<void> ready}) relayed = relayFfmpegRemoteInput(
        source,
        isHls: Future<bool>.value(false),
      );
      await relayed.ready;
      expect(
        relayed.url,
        startsWith('http://127.0.0.1:${origin.port}/Videos/136641/stream?'),
        reason: 'ffmpeg 拿到明文形式，不再自己做 TLS',
      );
      expect(ffmpegRelayRouteFor(relayed.url)?.httpProxy, isNotNull);

      final List<String> failures = <String>[];
      final String? audio = await extractAudioSegmentViaFfmpeg(
        inputPath: relayed.url,
        startMs: 500,
        endMs: 1500,
        outputPath: p.join(tmp.path, 'sentence.aac'),
        onFailure: failures.add,
      );
      expect(audio, isNotNull, reason: 'ffmpeg: $failures; origin saw $seen');
      expect(File(audio!).lengthSync(), greaterThan(0));

      final String? frame = await extractVideoFrameViaFfmpeg(
        inputPath: relayed.url,
        outputPath: p.join(tmp.path, 'still.jpg'),
        atSeconds: 1.0,
        onFailure: failures.add,
      );
      expect(frame, isNotNull, reason: 'ffmpeg: $failures; origin saw $seen');
      expect(File(frame!).lengthSync(), greaterThan(0));

      expect(seen, isNotEmpty, reason: '字节来自 https 原点（经中继升回 https）');
      expect(
        seen.every((String u) => u.contains('api_key=k')),
        isTrue,
        reason: '查询串（api_key / PlaySessionId）经中继原样送达',
      );
    },
    skip: bundled == null ? '只在带捆绑 ffmpeg-min 的平台跑（Windows / macOS）' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// [A] 是否是 [B] 的子类型（不用实例，生产 client 的构造要一堆依赖）。
bool _implements<A, B>() => <A>[] is List<B>;

String? _bundledFfmpeg() {
  final String? rel = Platform.isWindows
      ? p.join('..', 'third_party', 'ffmpeg-min', 'windows', 'ffmpeg.exe')
      : Platform.isMacOS
      ? p.join('..', 'third_party', 'ffmpeg-min', 'macos', 'ffmpeg')
      : null;
  if (rel == null) return null;
  return File(rel).existsSync() ? File(rel).absolute.path : null;
}
