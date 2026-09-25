import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/ffmpeg_relay_route.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';
import 'package:path/path.dart' as p;

/// BUG-2642 残留的端到端证据：真捆绑 ffmpeg-min + 真本机中继 + 伪装分片的 HLS。
///
/// 上游形状照抄在线 hoster：播放列表里的分片叫 `seg0.jpg`，响应 `image/png`，正文先是
/// 一张 PNG（垫到 252 字节，AnimeKai / MegaPlay 的实测长度）再接 MPEG-TS。
///
/// 播放列表挂在一个**解析不了的域名**上，只有中继（经用户代理出网，本地服务就是那个
/// 代理）能取到——所以「本地服务收到了请求」本身就证明 ffmpeg 走了中继，而不是碰巧
/// 直连成功。三组对照：
///  - 不改道：直连解析不了域名，失败（改动前制卡的样子）；
///  - 改道但不放开扩展名：FFmpeg 7.1 按白名单拒掉 `.jpg` 分片（`Invalid data`）；
///  - 改道 + 放开：抽出句子音频，本地服务先后收到播放列表与分片。
///
/// 只在带捆绑 ffmpeg-min 的平台跑（Windows / macOS）；它是 BUG-2642 那条配方产物。
void main() {
  final String? bundled = _bundledFfmpeg();

  test(
    '在线源 HLS 伪装分片：经中继 + 放开扩展名后 ffmpeg 抽得出句子音频',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync('relay_hls_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final String? oldOverride = ffmpegPathOverride;
      final String? oldProbeOverride = ffprobePathOverride;
      final String Function() oldMode = appUserProxyModeReader;
      final String Function() oldProxy = appUserProxyReader;
      addTearDown(() {
        ffmpegPathOverride = oldOverride;
        ffprobePathOverride = oldProbeOverride;
        setFfmpegBackendForTesting(null);
        debugResetFfmpegHlsSegmentExtensionSupport();
        ffmpegRemoteInputRouteResolver = null;
        debugClearFfmpegRelayRoutes();
        appUserProxyModeReader = oldMode;
        appUserProxyReader = oldProxy;
      });
      // ffmpeg 与 ffprobe 都钉到捆绑的那一对：能力探测问的是 ffprobe，不钉就会落到
      // PATH 上另一个 FFmpeg 构建，测试会因为别人的版本碰巧通过。
      ffmpegPathOverride = bundled;
      ffprobePathOverride = p.join(
        p.dirname(bundled!),
        Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
      );
      setFfmpegBackendForTesting(null);
      debugResetFfmpegHlsSegmentExtensionSupport();

      // 3 秒 MPEG-TS 分片（从仓库自带的样片无损转封装）。
      final String ts = p.join(tmp.path, 'seg0.ts');
      final ProcessResult mux = await Process.run(bundled, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        p.join('..', 'docs', 'todo-524-video.mp4'),
        '-t',
        '3',
        '-c',
        'copy',
        '-f',
        'mpegts',
        ts,
      ]);
      expect(mux.exitCode, 0, reason: '${mux.stderr}');
      final Uint8List png = Uint8List.fromList(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
      ]);
      final Uint8List disguised = Uint8List.fromList(<int>[
        ...png,
        ...List<int>.filled(252 - png.length, 0),
        ...File(ts).readAsBytesSync(),
      ]);

      // 用户代理 = 本地服务：收 absolute-form 请求，只认那个解析不了的域名。
      final List<String> seen = <String>[];
      final HttpServer upstream = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => upstream.close(force: true));
      upstream.listen((HttpRequest request) async {
        final HttpResponse res = request.response;
        if (request.requestedUri.host != 'native-source.invalid') {
          res.statusCode = HttpStatus.badGateway;
          await res.close();
          return;
        }
        seen.add(request.requestedUri.path);
        switch (request.requestedUri.path) {
          case '/hls/index':
            // 不带 .m3u8 后缀：在线源的播放列表常这样，判 HLS 靠播放器识别的容器。
            res.headers.contentType = ContentType.parse(
              'application/vnd.apple.mpegurl',
            );
            res.write(
              '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n'
              '#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:3.0,\nseg0.jpg\n'
              '#EXT-X-ENDLIST\n',
            );
          case '/hls/seg0.jpg':
            res.headers.contentType = ContentType('image', 'png');
            res.contentLength = disguised.length;
            res.add(disguised);
          default:
            res.statusCode = HttpStatus.notFound;
        }
        await res.close();
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${upstream.port}';
      ffmpegRemoteInputRouteResolver = ffmpegRelayRouteFor;

      const String source = 'http://native-source.invalid/hls/index';
      final List<String> failures = <String>[];
      Future<String?> cut(String input, String name) =>
          extractAudioSegmentViaFfmpeg(
            inputPath: input,
            startMs: 100,
            endMs: 900,
            outputPath: p.join(tmp.path, '$name.aac'),
            onFailure: failures.add,
          );

      // 不改道：直连解析不了域名。
      expect(await cut(source, 'direct'), isNull);
      expect(seen, isEmpty, reason: '直连不该经过中继');

      // 改道但不放开扩展名：`.jpg` 分片被白名单拒掉。
      final ({String url, Future<void> ready}) strict = relayFfmpegRemoteInput(
        source,
        isHls: Future<bool>.value(false),
      );
      await strict.ready;
      expect(await cut(strict.url, 'strict'), isNull);
      expect(seen, contains('/hls/index'), reason: '播放列表已经经中继取到');
      expect(
        seen,
        isNot(contains('/hls/seg0.jpg')),
        reason: '分片在请求前就被扩展名白名单拒掉',
      );

      // 改道 + 放开：抽出句子音频。
      seen.clear();
      final ({String url, Future<void> ready}) relaxed = relayFfmpegRemoteInput(
        source,
        isHls: Future<bool>.value(true),
      );
      await relaxed.ready;
      failures.clear();
      final String? out = await cut(relaxed.url, 'relaxed');
      expect(out, isNotNull, reason: 'ffmpeg: $failures; upstream saw $seen');
      expect(File(out!).lengthSync(), greaterThan(0));
      expect(seen, containsAllInOrder(<String>['/hls/index', '/hls/seg0.jpg']));
    },
    skip: bundled == null ? '只在带捆绑 ffmpeg-min 的平台跑（Windows / macOS）' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // 制卡提速：在线源常直接给 master。ffmpeg 读 master 时 hls demuxer 把**每一档**的
  // 播放列表和开头分片都拉下来探测（限速实测三档 master：音频 + 动图两路 7.3 秒，直接
  // 读变体 4.5 秒）。登记时预先经中继取 master、选播放器默认那一档，ffmpeg 只碰那一档。
  test(
    '在线源 HLS master：登记时选好那一档，ffmpeg 只读它（对照：直接读 master 会拉每一档）',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync(
        'relay_master_',
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final String? oldOverride = ffmpegPathOverride;
      final String? oldProbeOverride = ffprobePathOverride;
      final String Function() oldMode = appUserProxyModeReader;
      final String Function() oldProxy = appUserProxyReader;
      addTearDown(() {
        ffmpegPathOverride = oldOverride;
        ffprobePathOverride = oldProbeOverride;
        setFfmpegBackendForTesting(null);
        debugResetFfmpegHlsSegmentExtensionSupport();
        ffmpegRemoteInputRouteResolver = null;
        debugClearFfmpegRelayRoutes();
        appUserProxyModeReader = oldMode;
        appUserProxyReader = oldProxy;
      });
      ffmpegPathOverride = bundled;
      ffprobePathOverride = p.join(
        p.dirname(bundled!),
        Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
      );
      setFfmpegBackendForTesting(null);
      debugResetFfmpegHlsSegmentExtensionSupport();

      final String ts = p.join(tmp.path, 'seg0.ts');
      final ProcessResult mux = await Process.run(bundled, <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        p.join('..', 'docs', 'todo-524-video.mp4'),
        '-t',
        '3',
        '-c',
        'copy',
        '-f',
        'mpegts',
        ts,
      ]);
      expect(mux.exitCode, 0, reason: '${mux.stderr}');
      final Uint8List segment = File(ts).readAsBytesSync();

      final List<String> seen = <String>[];
      String? masterReferer;
      final HttpServer upstream = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => upstream.close(force: true));
      upstream.listen((HttpRequest request) async {
        final HttpResponse res = request.response;
        if (request.requestedUri.host != 'native-source.invalid') {
          res.statusCode = HttpStatus.badGateway;
          await res.close();
          return;
        }
        final String path = request.requestedUri.path;
        seen.add(path);
        const String mpegurl = 'application/vnd.apple.mpegurl';
        if (path == '/m/master') {
          masterReferer = request.headers.value(HttpHeaders.refererHeader);
          // 最高码率那档排在中间：选档看 BANDWIDTH，不看先后。
          res.headers.contentType = ContentType.parse(mpegurl);
          res.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
            'lo/index\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
            'hi/index\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\n'
            'mid/index\n',
          );
        } else if (path.endsWith('/index')) {
          res.headers.contentType = ContentType.parse(mpegurl);
          res.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n'
            '#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:3.0,\nseg0.ts\n'
            '#EXT-X-ENDLIST\n',
          );
        } else if (path.endsWith('/seg0.ts')) {
          res.headers.contentType = ContentType('video', 'mp2t');
          res.contentLength = segment.length;
          res.add(segment);
        } else {
          res.statusCode = HttpStatus.notFound;
        }
        await res.close();
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${upstream.port}';
      ffmpegRemoteInputRouteResolver = ffmpegRelayRouteFor;

      final ({String url, Future<void> ready}) relayed = relayFfmpegRemoteInput(
        'http://native-source.invalid/m/master',
        isHls: Future<bool>.value(true),
        headers: const <String, String>{'Referer': 'https://site.example/'},
      );
      await relayed.ready;
      final String input = ffmpegRemoteInputFor(relayed.url);
      expect(input, endsWith('/m/hi/index'));
      expect(seen, <String>['/m/master'], reason: '登记只取 master 本身');
      expect(
        masterReferer,
        'https://site.example/',
        reason: '与 ffmpeg 同一组防盗链头',
      );

      final List<String> failures = <String>[];
      Future<String?> cut(String inputPath, String name) =>
          extractAudioSegmentViaFfmpeg(
            inputPath: inputPath,
            startMs: 100,
            endMs: 900,
            outputPath: p.join(tmp.path, '$name.aac'),
            onFailure: failures.add,
          );

      seen.clear();
      final String? out = await cut(input, 'variant');
      expect(out, isNotNull, reason: 'ffmpeg: $failures; upstream saw $seen');
      expect(File(out!).lengthSync(), greaterThan(0));
      expect(seen, containsAll(<String>['/m/hi/index', '/m/hi/seg0.ts']));
      expect(
        seen.where((String s) => s.startsWith('/m/lo/') || s.contains('/mid/')),
        isEmpty,
        reason: '只碰选中的那一档',
      );

      // 对照：同一条中继路径直接读 master，ffmpeg 会把每一档都拉下来探测。
      seen.clear();
      failures.clear();
      ffmpegRemoteInputRouteResolver = (String inputPath) {
        final FfmpegRemoteInputRoute? route = ffmpegRelayRouteFor(inputPath);
        return route == null
            ? null
            : FfmpegRemoteInputRoute(
                httpProxy: route.httpProxy,
                disableHlsSegmentPrefetch: route.disableHlsSegmentPrefetch,
                relaxHlsSegmentExtensions: route.relaxHlsSegmentExtensions,
              );
      };
      expect(await cut(relayed.url, 'master'), isNotNull, reason: '$failures');
      expect(
        seen,
        containsAll(<String>['/m/lo/index', '/m/mid/index', '/m/hi/index']),
      );
    },
    skip: bundled == null ? '只在带捆绑 ffmpeg-min 的平台跑（Windows / macOS）' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

String? _bundledFfmpeg() {
  final String? rel = Platform.isWindows
      ? p.join('..', 'third_party', 'ffmpeg-min', 'windows', 'ffmpeg.exe')
      : Platform.isMacOS
      ? p.join('..', 'third_party', 'ffmpeg-min', 'macos', 'ffmpeg')
      : null;
  if (rel == null) return null;
  final File file = File(p.normalize(p.absolute(rel)));
  return file.existsSync() ? file.path : null;
}
