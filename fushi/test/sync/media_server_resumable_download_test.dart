import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/media/video/media_server/media_server_resumable_download.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:test/test.dart';

/// BUG-4912：Jellyfin / Emby / Plex 整片下载走 `.part` + Range 续传 + 空闲超时。
/// 真实本机 HTTP 服务端：支持 Range / If-Range / ETag，可按用例「送一半就停」。
void main() {
  const String token = 'SECRET-TOKEN-123';
  final Uint8List payload = Uint8List.fromList(
    List<int>.generate(256 * 1024, (int i) => (i * 31 + 7) & 0xff),
  );
  const int half = 96 * 1024;

  late HttpServer server;
  late Directory temp;
  final List<Map<String, String?>> requests = <Map<String, String?>>[];

  /// 当前服务端行为。
  String etag = '"v1"';
  bool honourRange = true;
  // 首个（不带 Range 的）请求只送 [half] 字节就挂住。
  bool stallFirstFullResponse = false;
  int statusOverride = 0;

  setUp(() async {
    requests.clear();
    etag = '"v1"';
    honourRange = true;
    stallFirstFullResponse = false;
    statusOverride = 0;
    temp = await Directory.systemTemp.createTemp('fushi-ms-resume-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      final String? ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      requests.add(<String, String?>{
        'range': range,
        'ifRange': ifRange,
        'query': request.uri.query,
        'token': request.headers.value('X-Plex-Token'),
      });
      final HttpResponse response = request.response;
      if (statusOverride != 0) {
        response.statusCode = statusOverride;
        await response.close();
        return;
      }
      response.headers
        ..set(HttpHeaders.etagHeader, etag)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      final RegExpMatch? m = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-$').firstMatch(range);
      final bool rangeValid = ifRange == null || ifRange == etag;
      if (m != null && honourRange && rangeValid) {
        final int start = int.parse(m.group(1)!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${payload.length - 1}/${payload.length}',
        );
        response.contentLength = payload.length - start;
        response.add(payload.sublist(start));
        await response.close();
        return;
      }
      response.contentLength = payload.length;
      if (stallFirstFullResponse) {
        stallFirstFullResponse = false;
        response.add(payload.sublist(0, half));
        await response.flush();
        return; // 挂住：不再送数据也不关。
      }
      response.add(payload);
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  String base() => 'http://127.0.0.1:${server.port}';

  JellyfinApi jellyfin() {
    final JellyfinApi api = JellyfinApi(serverUrl: base(), accessToken: token);
    addTearDown(api.close);
    return api;
  }

  String jellyfinUrl() => '${base()}/Videos/abc/stream?static=true&api_key=$token';

  test(
    '空闲超时后留 .part，下一次带 Range + If-Range 从断点接着拉，拼出完整文件',
    () async {
      stallFirstFullResponse = true;
      final File dest = File('${temp.path}/movie.mkv');
      final File part = File('${dest.path}.part');
      final File sidecar = File(
        '${dest.path}$kMediaServerResumeSidecarSuffix',
      );
      await expectLater(
        jellyfin().downloadResumable(
          jellyfinUrl(),
          dest,
          resumeKey: 'jellyfin:abc:src1',
          stallTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(dest.existsSync(), isFalse);
      expect(part.lengthSync(), half);
      // 侧车只记条目键与验证器，不落 URL / 令牌。
      final String side = sidecar.readAsStringSync();
      expect(side, contains('jellyfin:abc:src1'));
      expect(side, contains('v1'));
      expect(side, isNot(contains(token)));
      expect(side, isNot(contains('127.0.0.1')));

      final List<int> bytes = <int>[];
      await jellyfin().downloadResumable(
        jellyfinUrl(),
        dest,
        resumeKey: 'jellyfin:abc:src1',
        onBytes: (int received, int? total) => bytes.add(received),
      );
      expect(requests.last['range'], 'bytes=$half-');
      expect(requests.last['ifRange'], '"v1"');
      expect(dest.readAsBytesSync(), payload);
      expect(part.existsSync(), isFalse);
      expect(sidecar.existsSync(), isFalse);
      // 进度含续传前已有的字节（下载中心按它显示）。
      expect(bytes.first, half);
      expect(bytes.last, payload.length);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('暂停（cancelSignal）抛 RemoteDownloadCancelled 且保留 .part 供继续', () async {
    stallFirstFullResponse = true;
    final File dest = File('${temp.path}/paused.mkv');
    final Completer<void> pause = Completer<void>();
    await expectLater(
      jellyfin().downloadResumable(
        jellyfinUrl(),
        dest,
        resumeKey: 'jellyfin:abc:src1',
        cancelSignal: pause.future,
        onBytes: (int received, int? total) {
          if (received >= half && !pause.isCompleted) pause.complete();
        },
      ),
      throwsA(isA<RemoteDownloadCancelled>()),
    );
    expect(File('${dest.path}.part').lengthSync(), half);
    await jellyfin().downloadResumable(
      jellyfinUrl(),
      dest,
      resumeKey: 'jellyfin:abc:src1',
    );
    expect(requests.last['range'], 'bytes=$half-');
    expect(dest.readAsBytesSync(), payload);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('服务端（兼容层）不支持 Range：回 200 时丢弃旧 .part 从 0 重下，结果仍完整', () async {
    stallFirstFullResponse = true;
    final File dest = File('${temp.path}/norange.mkv');
    await expectLater(
      jellyfin().downloadResumable(
        jellyfinUrl(),
        dest,
        resumeKey: 'jellyfin:abc:src1',
        stallTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    honourRange = false;
    await jellyfin().downloadResumable(
      jellyfinUrl(),
      dest,
      resumeKey: 'jellyfin:abc:src1',
    );
    expect(requests.last['range'], 'bytes=$half-');
    expect(dest.readAsBytesSync(), payload);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('服务器上的文件换了（ETag 变）：If-Range 不符回 200，从 0 重下不拼坏片', () async {
    stallFirstFullResponse = true;
    final File dest = File('${temp.path}/changed.mkv');
    await expectLater(
      jellyfin().downloadResumable(
        jellyfinUrl(),
        dest,
        resumeKey: 'jellyfin:abc:src1',
        stallTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    etag = '"v2"';
    await jellyfin().downloadResumable(
      jellyfinUrl(),
      dest,
      resumeKey: 'jellyfin:abc:src1',
    );
    expect(dest.readAsBytesSync(), payload);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('断点键不同（别的条目 / 别的版本留下的 .part）：不续传，从 0 下', () async {
    stallFirstFullResponse = true;
    final File dest = File('${temp.path}/other.mkv');
    await expectLater(
      jellyfin().downloadResumable(
        jellyfinUrl(),
        dest,
        resumeKey: 'jellyfin:abc:src1',
        stallTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await jellyfin().downloadResumable(
      jellyfinUrl(),
      dest,
      resumeKey: 'jellyfin:abc:src2',
    );
    expect(requests.last['range'], isNull);
    expect(dest.readAsBytesSync(), payload);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('鉴权失败：抛 JellyfinApiException，错误文本不带令牌', () async {
    statusOverride = HttpStatus.unauthorized;
    final File dest = File('${temp.path}/denied.mkv');
    Object? error;
    try {
      await jellyfin().downloadResumable(
        jellyfinUrl(),
        dest,
        resumeKey: 'jellyfin:abc:src1',
      );
    } catch (e) {
      error = e;
    }
    expect(error, isA<JellyfinApiException>());
    expect(error.toString(), isNot(contains(token)));
    expect(dest.existsSync(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('Plex 同一条续传路：中断后带 Range 接着拉，令牌只走请求头', () async {
    stallFirstFullResponse = true;
    final PlexApi api = PlexApi(
      serverUrl: base(),
      token: token,
      clientInfo: const PlexClientInfo(clientIdentifier: 'test'),
    );
    addTearDown(api.close);
    final File dest = File('${temp.path}/plex.mkv');
    final String url = api.partUrl('/library/parts/9/file.mkv', download: true);
    await expectLater(
      api.downloadResumable(
        url,
        dest,
        resumeKey: 'plex:9',
        cancelledError: () => const RemoteDownloadCancelled(),
        stallTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      File(
        '${dest.path}$kMediaServerResumeSidecarSuffix',
      ).readAsStringSync(),
      isNot(contains(token)),
    );
    await api.downloadResumable(
      url,
      dest,
      resumeKey: 'plex:9',
      cancelledError: () => const RemoteDownloadCancelled(),
    );
    expect(requests.last['range'], 'bytes=$half-');
    expect(requests.last['token'], token);
    expect(dest.readAsBytesSync(), payload);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
