import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'package:fushi_engine/sync/fushi_sync_server.dart';

shelf.Request _get(Map<String, String> headers) => shelf.Request(
  'GET',
  Uri.parse('http://127.0.0.1/api/library/videos/v1/stream'),
  headers: headers,
);

void main() {
  late Directory tmp;
  late File file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_engine_ifrange');
    file = File('${tmp.path}/sample.mp4')
      ..writeAsBytesSync(List<int>.generate(1000, (int i) => i & 0xff));
    file.setLastModifiedSync(DateTime.utc(2026, 1, 1));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('videoFileEtag', () {
    test('强验证器，随文件体积 / 修改时间变化', () {
      final String first = videoFileEtag(file);
      expect(first, startsWith('"vid-'));
      expect(first, endsWith('"'));
      expect(videoFileEtag(file), first);

      file.setLastModifiedSync(DateTime.utc(2026, 1, 2));
      final String touched = videoFileEtag(file);
      expect(touched, isNot(first));

      file.writeAsBytesSync(List<int>.filled(2000, 1));
      file.setLastModifiedSync(DateTime.utc(2026, 1, 2));
      expect(videoFileEtag(file), isNot(touched));
    });
  });

  group('serveFileWithRange(ifRangeRequired: false)', () {
    Future<shelf.Response> serve(Map<String, String> headers) =>
        serveFileWithRange(
          file,
          _get(headers),
          etag: videoFileEtag(file),
          ifRangeRequired: false,
        );

    test('无 Range：200 带 ETag', () async {
      final shelf.Response res = await serve(const <String, String>{});
      expect(res.statusCode, 200);
      expect(res.headers['etag'], videoFileEtag(file));
    });

    test('盲 Range（播放器 seek，无 If-Range）照常 206', () async {
      final shelf.Response res = await serve(<String, String>{
        'range': 'bytes=10-',
      });
      expect(res.statusCode, 206);
      expect(res.headers['content-range'], 'bytes 10-999/1000');
    });

    test('If-Range 匹配：206', () async {
      final shelf.Response res = await serve(<String, String>{
        'range': 'bytes=10-',
        'if-range': videoFileEtag(file),
      });
      expect(res.statusCode, 206);
    });

    test('If-Range 不匹配（文件已换）：降级 200 全量', () async {
      final shelf.Response res = await serve(<String, String>{
        'range': 'bytes=10-',
        'if-range': '"vid-1000-1"',
      });
      expect(res.statusCode, 200);
      expect(res.headers['content-length'], '1000');
    });
  });

  test('默认 ifRangeRequired: true（导出包）仍拒绝盲 Range', () async {
    final shelf.Response res = await serveFileWithRange(
      file,
      _get(<String, String>{'range': 'bytes=10-'}),
      etag: '"pkg-0-1000-1"',
    );
    expect(res.statusCode, 200);
  });
}
