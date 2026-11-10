// 反馈 toPvLQcpex：WebDAV 同步后端按 `Range` 读资产区间（云端旧名漫画包判型、
// 云盘视频流播共用）。用本机回环 HttpServer 扮 WebDAV 服务器：
//  (1) 206：按 Content-Range 交出这一段，请求带 Range 与 identity 编码、带凭据；
//  (2) 200（服务器无视 Range）：部分区间请求抛 SyncAssetRangeUnsupported、不把整文件
//      读完；`[0, 文件尾]` 请求时 200 就是答案；
//  (3) 416 → SyncAssetRangeNotSatisfiable（带总长）；206 缺 Content-Range → 报错；
//  (4) WebDAV / SFTP 同步后端都暴露区间读能力（plainAssetRangeReaderOf 非 null）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';

/// 服务器行为：honor = 正常 206；ignore = 无视 Range 回 200 整文件；
/// noContentRange = 回 206 却不带 Content-Range。
enum _Mode { honor, ignore, noContentRange }

class _FakeDavServer {
  _FakeDavServer._(this._server, this.file);

  static Future<_FakeDavServer> start(Uint8List file) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeDavServer fake = _FakeDavServer._(server, file);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final Uint8List file;
  _Mode mode = _Mode.honor;
  final List<HttpHeaders> requests = <HttpHeaders>[];

  /// 200 整文件响应实际写进 socket 的字节数（客户端中途断开时写不完）。
  int fullBodyBytesWritten = 0;

  String get base => 'http://127.0.0.1:${_server.port}/dav';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.headers);
    final HttpResponse response = request.response;
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    final RegExpMatch? m = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (mode == _Mode.ignore || m == null) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = file.length;
      // 分块写，客户端取消后后续写入会失败：据此确认没把整文件读完。
      const int chunk = 64 * 1024;
      try {
        for (int i = 0; i < file.length; i += chunk) {
          final int endExclusive = i + chunk > file.length
              ? file.length
              : i + chunk;
          response.add(Uint8List.sublistView(file, i, endExclusive));
          await response.flush();
          fullBodyBytesWritten = endExclusive;
        }
        await response.close();
      } on Object {
        // 客户端断开。
      }
      return;
    }
    final int start = int.parse(m.group(1)!);
    final String endRaw = m.group(2)!;
    if (start >= file.length) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${file.length}',
      );
      await response.close();
      return;
    }
    int end = endRaw.isEmpty ? file.length - 1 : int.parse(endRaw);
    if (end >= file.length) end = file.length - 1;
    response.statusCode = HttpStatus.partialContent;
    response.headers.contentType = ContentType('video', 'mp4');
    if (mode != _Mode.noContentRange) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${file.length}',
      );
    }
    response.contentLength = end - start + 1;
    response.add(Uint8List.sublistView(file, start, end + 1));
    await response.close();
  }
}

Future<Uint8List> _collect(SyncAssetRange range) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in range.bytes) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  // 4 MiB，远大于一次判型读的 16 KiB。
  final Uint8List file = Uint8List.fromList(
    List<int>.generate(4 * 1024 * 1024, (int i) => (i * 31 + 7) & 0xff),
  );
  late _FakeDavServer server;
  late WebDavOps ops;
  late String url;

  setUp(() async {
    server = await _FakeDavServer.start(file);
    ops = WebDavOps(baseUrl: server.base, username: 'u', password: 'p');
    url = '${server.base}/fushi-data/Book/Book.epub';
  });

  tearDown(() async {
    ops.close(force: true);
    await server.close();
  });

  test('206: returns exactly the requested slice with total length', () async {
    final SyncAssetRange range = await ops.openRange(
      url,
      start: file.length - 16 * 1024,
    );
    expect(range.start, file.length - 16 * 1024);
    expect(range.end, file.length - 1);
    expect(range.totalBytes, file.length);
    expect(range.contentType, startsWith('video/mp4'));
    expect(
      await _collect(range),
      Uint8List.sublistView(file, file.length - 16 * 1024),
    );

    final HttpHeaders sent = server.requests.single;
    expect(
      sent.value(HttpHeaders.rangeHeader),
      'bytes=${file.length - 16 * 1024}-',
    );
    expect(sent.value(HttpHeaders.acceptEncodingHeader), 'identity');
    expect(
      sent.value(HttpHeaders.authorizationHeader),
      'Basic ${base64Encode(utf8.encode('u:p'))}',
    );
  });

  test('206 with a closed range', () async {
    final SyncAssetRange range = await ops.openRange(url, start: 10, end: 19);
    expect((range.start, range.end, range.totalBytes), (10, 19, file.length));
    expect(await _collect(range), Uint8List.sublistView(file, 10, 20));
  });

  test('200 to a partial request: SyncAssetRangeUnsupported, the whole file '
      'is not downloaded', () async {
    server.mode = _Mode.ignore;
    await expectLater(
      ops.openRange(url, start: file.length - 16 * 1024),
      throwsA(isA<SyncAssetRangeUnsupported>()),
    );
    // 客户端已断开：服务端后续写入失败，整文件写不完。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.fullBodyBytesWritten, lessThan(file.length));
  });

  test('200 to a [0, EOF] request is the requested range itself', () async {
    server.mode = _Mode.ignore;
    final SyncAssetRange range = await ops.openRange(url, start: 0);
    expect(
      (range.start, range.end, range.totalBytes),
      (0, file.length - 1, file.length),
    );
    expect((await _collect(range)).length, file.length);
  });

  test('a 1-byte probe answered with 200 is unsupported too', () async {
    server.mode = _Mode.ignore;
    await expectLater(
      ops.openRange(url, start: 0, end: 0),
      throwsA(isA<SyncAssetRangeUnsupported>()),
    );
  });

  test('416 maps to SyncAssetRangeNotSatisfiable with the total', () async {
    await expectLater(
      ops.openRange(url, start: file.length + 5),
      throwsA(
        isA<SyncAssetRangeNotSatisfiable>().having(
          (SyncAssetRangeNotSatisfiable e) => e.totalBytes,
          'totalBytes',
          file.length,
        ),
      ),
    );
  });

  test('206 without a Content-Range is an error, not a guess', () async {
    server.mode = _Mode.noContentRange;
    await expectLater(
      ops.openRange(url, start: 100, end: 199),
      throwsA(isA<SyncBackendError>()),
    );
  });

  test('WebDAV and SFTP sync backends expose range reads', () {
    expect(WebDavSyncBackend.instance, isA<SyncAssetRangeReader>());
    expect(SftpSyncBackend.instance, isA<SyncAssetRangeReader>());
    expect(plainAssetRangeReaderOf(WebDavSyncBackend.instance), isNotNull);
    expect(plainAssetRangeReaderOf(SftpSyncBackend.instance), isNotNull);
  });
}
