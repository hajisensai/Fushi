import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/media_server/media_server_resumable_download.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// BUG-5117 / HBK-AUDIT-033：媒体服务器整片续传只在**强验证器**（强 ETag 或
/// Last-Modified，经 If-Range 送出、并在 206 上原样回显）证明同一版本时才续；
/// 「总长相同」不是版本身份，缺证据一律从 0 重下。
///
/// 真实本机 HTTP 服务端：可关掉 ETag / Last-Modified、可无视 If-Range、可在两次
/// 下载之间把文件换成**等长**的另一份字节。
void main() {
  const int size = 128 * 1024;
  const int half = 48 * 1024;
  final Uint8List v1 = Uint8List.fromList(
    List<int>.generate(size, (int i) => (i * 31 + 7) & 0xff),
  );
  // 等长替换：总长与 v1 完全一样，拼片只能靠内容看出来。
  final Uint8List v2 = Uint8List.fromList(
    List<int>.generate(size, (int i) => (i * 17 + 3) & 0xff),
  );

  late HttpServer server;
  late Directory temp;
  late http.Client client;
  final List<Map<String, String?>> requests = <Map<String, String?>>[];

  String? etag;
  String? lastModified;
  bool ignoreIfRange = false;
  bool stallFirstFullResponse = false;
  Uint8List served = v1;

  setUp(() async {
    requests.clear();
    etag = null;
    lastModified = null;
    ignoreIfRange = false;
    stallFirstFullResponse = false;
    served = v1;
    client = http.Client();
    temp = await Directory.systemTemp.createTemp('fushi-ms-validator-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      final String? ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      requests.add(<String, String?>{'range': range, 'ifRange': ifRange});
      final HttpResponse response = request.response;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag!);
      if (lastModified != null) {
        response.headers.set(HttpHeaders.lastModifiedHeader, lastModified!);
      }
      final RegExpMatch? m = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-$').firstMatch(range);
      // RFC 9110 §13.1.5：If-Range 只做强比较，弱 ETag 永不匹配。
      final bool ifRangeMatches =
          ifRange == null ||
          (ifRange == etag && !ifRange.startsWith('W/')) ||
          ifRange == lastModified;
      if (m != null && (ignoreIfRange || ifRangeMatches)) {
        final int start = int.parse(m.group(1)!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${served.length - 1}/${served.length}',
        );
        response.contentLength = served.length - start;
        response.add(served.sublist(start));
        await response.close();
        return;
      }
      response.contentLength = served.length;
      if (stallFirstFullResponse) {
        stallFirstFullResponse = false;
        response.add(served.sublist(0, half));
        await response.flush();
        return; // 挂住：不再送数据也不关。
      }
      response.add(served);
      await response.close();
    });
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> download(File dest, {Duration? stall}) =>
      downloadMediaServerFileResumable(
        client: client,
        url: 'http://127.0.0.1:${server.port}/Videos/abc/stream?static=true',
        headers: const <String, String>{},
        resumeKey: 'jellyfin:abc:src1',
        dest: dest,
        statusError: (int code) => HttpException('status $code'),
        cancelledError: () => const HttpException('cancelled'),
        stallTimeout: stall ?? kMediaServerDownloadStallTimeout,
      );

  /// 首个整份响应只送 [half] 字节就挂住，留下 `.part`（与侧车，若有强验证器）。
  Future<File> leavePart(String name) async {
    stallFirstFullResponse = true;
    final File dest = File('${temp.path}/$name');
    await expectLater(
      download(dest, stall: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
    expect(File('${dest.path}.part').lengthSync(), half);
    return dest;
  }

  List<String?> rangesSince(int before) => requests
      .sublist(before)
      .map((Map<String, String?> r) => r['range'])
      .toList();

  test('无 ETag / Last-Modified + 等长替换：不续传，从 0 重下不拼坏片', () async {
    final File dest = await leavePart('no-validator.mkv');
    served = v2;
    final int before = requests.length;
    await download(dest);
    expect(rangesSince(before), <String?>[null]);
    expect(dest.readAsBytesSync(), v2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('只有弱 ETag（不能作 If-Range）+ 等长替换：不续传，从 0 重下', () async {
    etag = 'W/"v1"';
    final File dest = await leavePart('weak-etag.mkv');
    served = v2;
    ignoreIfRange = true;
    final int before = requests.length;
    await download(dest);
    expect(rangesSince(before), <String?>[null]);
    expect(dest.readAsBytesSync(), v2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('续传 206 不回显 If-Range 用的 ETag、只剩相同总长：作废这条响应，从 0 重下', () async {
    etag = '"v1"';
    final File dest = await leavePart('etag-dropped.mkv');
    etag = null;
    served = v2;
    ignoreIfRange = true;
    final int before = requests.length;
    await download(dest);
    expect(requests[before]['ifRange'], '"v1"');
    expect(rangesSince(before), <String?>['bytes=$half-', null]);
    expect(dest.readAsBytesSync(), v2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('续传 206 不回显 Last-Modified、只剩相同总长：作废这条响应，从 0 重下', () async {
    lastModified = 'Wed, 21 Oct 2026 07:28:00 GMT';
    final File dest = await leavePart('lm-dropped.mkv');
    lastModified = null;
    served = v2;
    ignoreIfRange = true;
    final int before = requests.length;
    await download(dest);
    expect(rangesSince(before), <String?>['bytes=$half-', null]);
    expect(dest.readAsBytesSync(), v2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('强 ETag 未变：带 If-Range 续上，拼出完整文件', () async {
    etag = '"v1"';
    final File dest = await leavePart('strong-etag.mkv');
    final int before = requests.length;
    await download(dest);
    expect(rangesSince(before), <String?>['bytes=$half-']);
    expect(requests.last['ifRange'], '"v1"');
    expect(dest.readAsBytesSync(), v1);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('只有 Last-Modified 也算强验证器：带 If-Range 续上，拼出完整文件', () async {
    lastModified = 'Wed, 21 Oct 2026 07:28:00 GMT';
    final File dest = await leavePart('last-modified.mkv');
    final int before = requests.length;
    await download(dest);
    expect(rangesSince(before), <String?>['bytes=$half-']);
    expect(requests.last['ifRange'], lastModified);
    expect(dest.readAsBytesSync(), v1);
  }, timeout: const Timeout(Duration(seconds: 30)));

  group('MediaServerResumeSidecar', () {
    test('只有总长 / 只有弱 ETag 的旧侧车不构成续传身份', () {
      expect(
        const MediaServerResumeSidecar(
          resumeKey: 'k',
          totalBytes: size,
        ).hasStrongValidator,
        isFalse,
      );
      expect(
        const MediaServerResumeSidecar(
          resumeKey: 'k',
          etag: 'W/"x"',
          totalBytes: size,
        ).hasStrongValidator,
        isFalse,
      );
      expect(
        const MediaServerResumeSidecar(
          resumeKey: 'k',
          etag: '"x"',
        ).hasStrongValidator,
        isTrue,
      );
    });
  });
}
