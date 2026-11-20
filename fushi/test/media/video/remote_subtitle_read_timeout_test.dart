import 'dart:async';
import 'dart:io';

import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/utils/net/deadline_get.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// BUG-5037：远端起播的默认字幕下载挡在开流之前，没有读超时时字幕站「接了连接却
/// 不回数据」会让页面永远停在「正在下载字幕」。这里用真实的本机 HTTP 服务端模拟
/// 两种卡法：连响应头都不回、回了响应头和半截正文后不再送数据。
void main() {
  late HttpServer server;
  late Directory temp;
  final List<HttpRequest> held = <HttpRequest>[];

  /// 每个请求按路径决定怎么卡：`/silent*` 什么都不回；`/stall*` 回响应头 + 一小段
  /// 正文后不再送数据；其余正常回 `WEBVTT`。
  Future<void> serve() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      if (path.startsWith('/silent')) {
        held.add(request);
        return;
      }
      if (path.startsWith('/stall')) {
        held.add(request);
        request.response.contentLength = 1000;
        request.response.add(List<int>.filled(10, 65));
        await request.response.flush();
        return;
      }
      request.response.write('WEBVTT');
      await request.response.close();
    });
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  setUp(() async {
    await serve();
    temp = await Directory.systemTemp.createTemp('fushi-sub-timeout-');
  });

  tearDown(() async {
    held.clear();
    await server.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('getWithDeadline：服务端不回响应头时到点抛 TimeoutException，不挂住', () async {
    final http.Client client = http.Client();
    addTearDown(client.close);
    final Stopwatch watch = Stopwatch()..start();
    await expectLater(
      getWithDeadline(
        client,
        Uri.parse(url('/silent.vtt')),
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    // 正常响应照常返回。
    final http.Response ok = await getWithDeadline(
      client,
      Uri.parse(url('/ok.vtt')),
      timeout: const Duration(seconds: 5),
    );
    expect(ok.body, 'WEBVTT');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('getWithDeadline：回了响应头但正文卡住同样到点放弃（总预算覆盖读正文）', () async {
    final http.Client client = http.Client();
    addTearDown(client.close);
    await expectLater(
      getWithDeadline(
        client,
        Uri.parse(url('/stall.vtt')),
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('直链流的外挂字幕：字幕站不回数据时 getRemoteVideoSubtitle 到点失败，不留文件', () async {
    final UrlStreamVideoClient client = UrlStreamVideoClient(
      streamUrl: url('/video.mp4'),
      subtitleUrl: url('/silent.srt'),
      subtitleFetchTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(client.close);
    final File dest = File('${temp.path}/sub.srt');
    await expectLater(
      client.getRemoteVideoSubtitle('id', dest),
      throwsA(isA<TimeoutException>()),
    );
    expect(dest.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('Jellyfin downloadToFile：回了响应头后不再送数据，空闲超时抛出并删半截文件', () async {
    final JellyfinApi api = JellyfinApi(
      serverUrl: url(''),
      accessToken: 'token',
    );
    addTearDown(api.close);
    final File dest = File('${temp.path}/jellyfin.srt');
    await expectLater(
      api.downloadToFile(
        url('/stall.srt'),
        dest,
        idleTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(dest.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('Plex downloadToFile：回了响应头后不再送数据，空闲超时抛出并删半截文件', () async {
    final PlexApi api = PlexApi(
      serverUrl: url(''),
      token: 'token',
      clientInfo: const PlexClientInfo(clientIdentifier: 'test'),
    );
    addTearDown(api.close);
    final File dest = File('${temp.path}/plex.srt');
    await expectLater(
      api.downloadToFile(
        url('/stall.srt'),
        dest,
        idleTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(dest.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
