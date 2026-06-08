import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:shelf/shelf.dart' as shelf;

// ── parseByteRange 纯函数单测 ─────────────────────────────────────────────────

void main() {
  group('parseByteRange', () {
    const int fileLen = 1000;

    test('null header → null（无 Range 头，调用方回 200）', () {
      expect(parseByteRange(null, fileLen), isNull);
    });

    test('empty header → null', () {
      expect(parseByteRange('', fileLen), isNull);
    });

    test('bytes=0-99 → start=0, end=99', () {
      final ByteRange? r = parseByteRange('bytes=0-99', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isFalse);
      expect(r.start, 0);
      expect(r.end, 99);
      expect(r.length, 100);
    });

    test('bytes=100- → start=100, end=999', () {
      final ByteRange? r = parseByteRange('bytes=100-', fileLen);
      expect(r, isNotNull);
      expect(r!.start, 100);
      expect(r.end, 999);
      expect(r.length, 900);
    });

    test('bytes=-50 → start=950, end=999', () {
      final ByteRange? r = parseByteRange('bytes=-50', fileLen);
      expect(r, isNotNull);
      expect(r!.start, 950);
      expect(r.end, 999);
      expect(r.length, 50);
    });

    test('bytes=-1100（suffix > fileLen）→ 钳制到 0..fileLen-1', () {
      final ByteRange? r = parseByteRange('bytes=-1100', fileLen);
      expect(r, isNotNull);
      expect(r!.start, 0);
      expect(r.end, 999);
    });

    test('end 超出 fileLen → 钳制到 fileLen-1', () {
      final ByteRange? r = parseByteRange('bytes=0-9999', fileLen);
      expect(r, isNotNull);
      expect(r!.end, 999);
    });

    test('start == fileLen → unsatisfiable', () {
      final ByteRange? r = parseByteRange('bytes=1000-', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isTrue);
    });

    test('start > end → unsatisfiable', () {
      final ByteRange? r = parseByteRange('bytes=500-100', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isTrue);
    });

    test('非 bytes= 前缀 → unsatisfiable', () {
      final ByteRange? r = parseByteRange('units=0-99', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isTrue);
    });

    test('缺少 "-" → unsatisfiable', () {
      final ByteRange? r = parseByteRange('bytes=100', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isTrue);
    });

    test('非数字 start → unsatisfiable', () {
      final ByteRange? r = parseByteRange('bytes=abc-200', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isTrue);
    });

    test('suffix=0 → unsatisfiable（RFC 7233: suffix=0 无意义）', () {
      final ByteRange? r = parseByteRange('bytes=-0', fileLen);
      expect(r, isNotNull);
      expect(r!.isUnsatisfiable, isTrue);
    });

    test('fileLength=0 任何 range → unsatisfiable', () {
      expect(parseByteRange('bytes=0-0', 0)!.isUnsatisfiable, isTrue);
      expect(parseByteRange('bytes=0-', 0)!.isUnsatisfiable, isTrue);
    });

    test('精确末字节 bytes=999-999', () {
      final ByteRange? r = parseByteRange('bytes=999-999', fileLen);
      expect(r, isNotNull);
      expect(r!.start, 999);
      expect(r.end, 999);
      expect(r.length, 1);
    });
  });

  // ── serveFileWithRange 行为测试 ──────────────────────────────────────────────

  group('serveFileWithRange', () {
    late Directory tmp;
    late File testFile;

    // 测试文件内容：100 字节，值为 0..99
    final Uint8List testBytes =
        Uint8List.fromList(List<int>.generate(100, (int i) => i));

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hbk_range_test');
      testFile = File('${tmp.path}/test.mp4')
        ..writeAsBytesSync(testBytes);
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    /// 辅助：把 shelf.Response body 读成字节列表。
    Future<List<int>> readBody(shelf.Response res) async {
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in res.read()) {
        bytes.addAll(chunk);
      }
      return bytes;
    }

    shelf.Request _makeRequest({String? range}) {
      final Map<String, String> headers = <String, String>{};
      if (range != null) headers['range'] = range;
      return shelf.Request(
        'GET',
        Uri.parse('http://localhost/test.mp4'),
        headers: headers,
      );
    }

    test('无 Range 头 → 200 + 全量字节 + Accept-Ranges', () async {
      final shelf.Response res =
          await serveFileWithRange(testFile, _makeRequest());
      expect(res.statusCode, 200);
      expect(res.headers['accept-ranges'], 'bytes');
      expect(res.headers['content-length'], '100');
      final List<int> body = await readBody(res);
      expect(body, testBytes);
    });

    test('bytes=0-9 → 206 + 前10字节 + 正确 Content-Range', () async {
      final shelf.Response res =
          await serveFileWithRange(testFile, _makeRequest(range: 'bytes=0-9'));
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 0-9/100');
      expect(res.headers['content-length'], '10');
      expect(res.headers['accept-ranges'], 'bytes');
      final List<int> body = await readBody(res);
      expect(body.length, 10);
      expect(body, List<int>.generate(10, (int i) => i));
    });

    test('bytes=90- → 206 + 最后10字节', () async {
      final shelf.Response res = await serveFileWithRange(
          testFile, _makeRequest(range: 'bytes=90-'));
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 90-99/100');
      final List<int> body = await readBody(res);
      expect(body.length, 10);
      expect(body, List<int>.generate(10, (int i) => 90 + i));
    });

    test('bytes=-20 → 206 + 最后20字节', () async {
      final shelf.Response res = await serveFileWithRange(
          testFile, _makeRequest(range: 'bytes=-20'));
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 80-99/100');
      final List<int> body = await readBody(res);
      expect(body.length, 20);
    });

    test('start 越界 → 416 + Content-Range: bytes */total', () async {
      final shelf.Response res = await serveFileWithRange(
          testFile, _makeRequest(range: 'bytes=200-'));
      expect(res.statusCode, 416);
      expect(res.headers['content-range'], 'bytes */100');
      expect(res.headers['accept-ranges'], 'bytes');
    });

    test('非法格式 → 416', () async {
      final shelf.Response res = await serveFileWithRange(
          testFile, _makeRequest(range: 'bytes=abc-'));
      expect(res.statusCode, 416);
    });

    test('文件不存在 → 404', () async {
      final File missing = File('${tmp.path}/missing.mp4');
      final shelf.Response res =
          await serveFileWithRange(missing, _makeRequest());
      expect(res.statusCode, 404);
    });

    test('Content-Type 按扩展名：.mp4 → video/mp4', () async {
      final shelf.Response res =
          await serveFileWithRange(testFile, _makeRequest());
      expect(res.headers['content-type'], contains('video/mp4'));
    });

    test('Content-Type：.mkv → video/x-matroska', () async {
      final File mkvFile = File('${tmp.path}/test.mkv')
        ..writeAsBytesSync(testBytes);
      final shelf.Response res =
          await serveFileWithRange(mkvFile, _makeRequest());
      expect(res.headers['content-type'], contains('video/x-matroska'));
    });
  });
}
