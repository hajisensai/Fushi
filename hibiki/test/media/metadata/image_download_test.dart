import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/metadata/image_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('looksLikeImageBytes', () {
    test('Content-Type image/* 直接判是', () {
      expect(looksLikeImageBytes(const <int>[], 'image/jpeg'), isTrue);
      expect(looksLikeImageBytes(const <int>[], 'IMAGE/PNG'), isTrue);
    });

    test('字节魔数：JPEG/PNG/GIF/WebP', () {
      expect(looksLikeImageBytes(const <int>[0xFF, 0xD8, 0xFF, 0x00], null),
          isTrue); // JPEG
      expect(looksLikeImageBytes(const <int>[0x89, 0x50, 0x4E, 0x47], null),
          isTrue); // PNG
      expect(looksLikeImageBytes(const <int>[0x47, 0x49, 0x46, 0x38], null),
          isTrue); // GIF
      expect(
        looksLikeImageBytes(<int>[...utf8.encode('RIFF'), 0, 0, 0, 0, ...utf8.encode('WEBP')], null),
        isTrue,
      );
    });

    test('非图片（html 错误页）判否', () {
      expect(
        looksLikeImageBytes(utf8.encode('<html>oops</html>'), 'text/html'),
        isFalse,
      );
      expect(looksLikeImageBytes(const <int>[1, 2], null), isFalse);
    });
  });

  group('downloadImageToTempFile', () {
    late Directory tempDir;
    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('hibiki_img_download_test');
    });
    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('成功：写出图片文件、内容为响应字节', () async {
      final List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];
      final MockClient client = MockClient(
        (http.Request req) async => http.Response.bytes(png, 200,
            headers: <String, String>{'content-type': 'image/png'}),
      );
      final File file = await downloadImageToTempFile(
        'https://example.invalid/cover.png',
        client: client,
        tempDir: tempDir,
      );
      expect(await file.exists(), isTrue);
      expect(p.isWithin(tempDir.path, file.path), isTrue);
      expect(await file.readAsBytes(), png);
    });

    test('非图片响应 → 抛 ImageDownloadException，不落文件', () async {
      final MockClient client = MockClient((http.Request req) async =>
          http.Response('<html/>', 200,
              headers: <String, String>{'content-type': 'text/html'}));
      await expectLater(
        downloadImageToTempFile('https://example.invalid/x',
            client: client, tempDir: tempDir),
        throwsA(isA<ImageDownloadException>()),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('404 → 抛 ImageDownloadException(statusCode=404)', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('x', 404));
      await expectLater(
        downloadImageToTempFile('https://example.invalid/x',
            client: client, tempDir: tempDir),
        throwsA(isA<ImageDownloadException>().having(
            (ImageDownloadException e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });
}
