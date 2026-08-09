// TODO-1000 诊断脚本（不入库长期用）：测 youtube_explode androidVr 解析在本机是 direct 挂死
// 还是要走代理。分别用直连 client 和代理 client 跑 videos.get + getManifest，打印各步耗时/错误。
// 运行：dart run tool/yt_probe.dart
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

Future<void> probe(String label, {String? proxy}) async {
  final Stopwatch sw = Stopwatch()..start();
  late yt.YoutubeExplode client;
  if (proxy != null) {
    final Uri u = Uri.parse(proxy);
    final HttpClient io = HttpClient();
    io.findProxy = (_) => 'PROXY ${u.host}:${u.port}';
    client = yt.YoutubeExplode(yt.YoutubeHttpClient(IOClient(io)));
  } else {
    client = yt.YoutubeExplode();
  }
  try {
    final yt.Video v = await client.videos
        .get('https://www.youtube.com/watch?v=dQw4w9WgXcQ')
        .timeout(const Duration(seconds: 30));
    stdout.writeln(
        '$label: videos.get OK ${sw.elapsedMilliseconds}ms "${v.title}"');
    final yt.StreamManifest m = await client.videos.streamsClient
        .getManifest(v.id, ytClients: <yt.YoutubeApiClient>[
      yt.YoutubeApiClient.androidVr
    ]).timeout(const Duration(seconds: 30));
    stdout.writeln('$label: manifest OK ${sw.elapsedMilliseconds}ms '
        'muxed=${m.muxed.length} videoOnly=${m.videoOnly.length} audioOnly=${m.audioOnly.length}');
  } catch (e) {
    stdout.writeln('$label: FAIL ${sw.elapsedMilliseconds}ms  $e');
  } finally {
    client.close();
  }
}

// 只测 getManifest（VideoId 直构，跳过 videos.get）——制卡新路径的真实耗时。
Future<void> manifestOnly(String label) async {
  final Stopwatch sw = Stopwatch()..start();
  final yt.YoutubeExplode client = yt.YoutubeExplode();
  try {
    final yt.StreamManifest m = await client.videos.streamsClient.getManifest(
        yt.VideoId('dQw4w9WgXcQ'),
        ytClients: <yt.YoutubeApiClient>[
          yt.YoutubeApiClient.androidVr
        ]).timeout(const Duration(seconds: 40));
    stdout.writeln(
        '$label: manifest-only OK ${sw.elapsedMilliseconds}ms muxed=${m.muxed.length}');
  } catch (e) {
    stdout
        .writeln('$label: manifest-only FAIL ${sw.elapsedMilliseconds}ms  $e');
  } finally {
    client.close();
  }
}

Future<void> main() async {
  await manifestOnly('run1');
  await manifestOnly('run2');
  await manifestOnly('run3');
}
