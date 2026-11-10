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

/// 忽略 Range、回答**部分区间**请求时整份响应是文件的多少遍（见
/// [_FakeDavServer._handle]）：远大于任何平台回环套接字的收发缓冲。
const int _ignoredRepeats = 64;

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

  /// 200 整文件响应的结局：true = 整个响应体成功交付；false = 客户端中途断开。
  /// 在服务端处理结束时完成，测试据此等待，不靠定时器。
  final Completer<bool> fullBodyDelivered = Completer<bool>();

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
      // 忽略 Range 的 200。`bytes=0-`（整文件）请求按原样回整份文件；部分区间请求
      // 回文件重复 [_ignoredRepeats] 遍——客户端若真把它读完（回归）就是下了远超
      // 所需的数据，客户端断开时也必然有写入落空（缓冲装不下）。
      //
      // 结局判定走摘下来的原始套接字：HttpResponse 对「对端已断」的写错误是吞掉的
      // （dart:io 忽略响应输出上的 SocketException，close() 照常完成），据它判会把
      // 断开报成「交付完」，结果随平台缓冲与时序飘。原始 Socket 的写错误会如实抛出，
      // 对端断开也会结束读侧。
      final bool wholeFile =
          m != null && m.group(1) == '0' && m.group(2)!.isEmpty;
      final int repeats = wholeFile ? 1 : _ignoredRepeats;
      final int total = file.length * repeats;
      response.statusCode = HttpStatus.ok;
      response.contentLength = total;
      final Socket socket = await response.detachSocket();
      bool peerGone = false;
      socket.listen(
        (_) {},
        onDone: () => peerGone = true,
        onError: (Object _) => peerGone = true,
        cancelOnError: true,
      );
      // 分块写，客户端取消后后续写入会失败：据此确认没把整文件读完。
      const int chunk = 64 * 1024;
      try {
        for (int i = 0; i < total; i += chunk) {
          if (peerGone) throw const SocketException('client disconnected');
          final int at = i % file.length;
          final int endExclusive = at + chunk > file.length
              ? file.length
              : at + chunk;
          socket.add(Uint8List.sublistView(file, at, endExclusive));
          await socket.flush();
        }
        await socket.close();
        fullBodyDelivered.complete(!peerGone);
      } on Object {
        // 客户端断开。
        socket.destroy();
        fullBodyDelivered.complete(false);
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
    // 客户端已断开：服务端后续写入失败，整文件交付不完。
    expect(
      await server.fullBodyDelivered.future.timeout(
        const Duration(seconds: 10),
      ),
      isFalse,
    );
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
